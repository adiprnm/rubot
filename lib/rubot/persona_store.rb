# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "model_catalog"
require_relative "persona"
require_relative "subagent_registry"

module Rubot
  # File-backed store for personas.
  #
  # Metadata lives at `<dir>/personas.json`, where `<dir>` is next to
  # config.yml — not inside the agent workspace, because a web persona owns a
  # workspace of its own and would otherwise try to read its own registry out of
  # it. A legacy file (`<workspace>/personas.json`) is still read when the new
  # one does not exist yet.
  #
  # Two key shapes share the file:
  #   * "chat:thread" — a Telegram forum topic. It either carries its own
  #                     model + prompt, or points at a persona that already
  #                     exists (`ref`), which is how a topic shares a
  #                     specialist's memory without sharing its conversations.
  #   * "slug"        — a web persona, which also gets a workspace directory
  #                     holding its SOUL.md, MEMORY.md and working files.
  #
  # The file is read on every lookup instead of being cached: the channels and
  # the SessionPool own separate store instances, and a persona saved by one
  # must be visible to the others immediately.
  class PersonaStore
    FILENAME = "personas.json"
    SLUG_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,31}\z/
    KEY_PATTERN = /\A(?:-?\d+:\d+|[a-z0-9][a-z0-9_-]{0,31})\z/
    RESERVED_SLUGS = %w[default general all new none].freeze
    # A topic points at a persona; a chain of pointers is a mistake, not a
    # feature. Three hops is enough to notice one and stop.
    MAX_REF_DEPTH = 3

    attr_reader :dir, :available_models, :available_presets

    def initialize(dir: nil, workspace: nil, legacy_workspace: nil, available_models: nil,
                   available_presets: nil)
      # `workspace:` is the pre-web name for this argument: back then the file
      # lived in the agent workspace. Callers that still pass it keep working.
      base = dir || workspace || File.join(Dir.home, ".rubot")
      @dir = File.expand_path(base)
      @legacy_workspace = legacy_workspace && File.expand_path(legacy_workspace)
      @available_models = Array(available_models)
        .map { |name| name.to_s.strip }
        .reject(&:empty?)
      @available_presets = Array(available_presets)
        .map { |name| name.to_s.strip }
        .reject(&:empty?)
      @mutex = Mutex.new
    end

    def path
      File.join(dir, FILENAME)
    end

    # Where a persona's agent files (SOUL.md, MEMORY.md, working files) live,
    # or nil for a key that owns none.
    #
    # A slug owns a directory of its own. A Telegram topic owns none unless it
    # points at an existing persona (`ref`), in which case it borrows that
    # persona's directory: one memory, two conversations.
    def workspace_for(key)
      slug = self.class.slug_for_key(key)
      return File.join(dir, "personas", slug) if slug

      target = resolved_slug(key)
      target && File.join(dir, "personas", target)
    end

    # The slug a key ultimately names: the key itself when it is a slug, or the
    # persona a topic points at. Nil for a topic that carries its own prompt.
    def resolved_slug(key)
      resolve(key.to_s, all)&.slug
    end

    # Create the persona's workspace, seeding a SOUL.md from the main workspace
    # on first use so a new persona starts with a usable identity instead of an
    # empty one. Returns the path.
    def prepare_workspace(key, seed_from: nil)
      path = workspace_for(key)
      return nil unless path

      FileUtils.mkdir_p(path)
      soul = File.join(path, "SOUL.md")
      if !File.exist?(soul) && seed_from
        source = File.join(seed_from, "SOUL.md")
        FileUtils.cp(source, soul) if File.file?(source)
      end
      path
    end

    # Returns a Hash of key => Persona.
    def all
      @mutex.synchronize { load_from_disk }
    end

    # Every persona that owns a workspace, oldest first. What the web sidebar
    # lists.
    def specialists
      all
        .select { |key, _persona| self.class.slug_for_key(key) }
        .sort_by { |_key, persona| persona.created_at.to_s }
        .map { |key, persona| [ self.class.slug_for_key(key), persona ] }
    end

    # A persona by key. A key that points at another persona resolves to that
    # persona: the topic gets the specialist's model, prompt, skills and
    # memory, while its conversations stay its own.
    #
    # Built-in sub agents are looked up here too, so `delegate` can target
    # them, but they are deliberately absent from `all` and `specialists`:
    # they are not user personas and must never show up in a sidebar, a
    # /delegates list or a topic picker.
    def [](key)
      text = key.to_s
      builtin = SubagentRegistry[text]
      return Persona.from(builtin) if builtin

      data = all
      resolve(text, data)
    end

    # The built-in sub agents, as slug => Persona. Kept out of `all` on purpose.
    def subagents
      SubagentRegistry.slugs.each_with_object({}) do |slug, result|
        definition = SubagentRegistry[slug]
        result[slug] = Persona.from(definition) if definition
      end
    end

    def get(chat_id, thread_id)
      key = self.class.key_for(chat_id, thread_id)
      key && self[key]
    end

    def get_by_session(session_id)
      key = self.class.key_for_session(session_id)
      key && self[key]
    end

    def key_for(chat_id, thread_id)
      self.class.key_for(chat_id, thread_id)
    end

    def set(key, persona)
      key = key.to_s
      raise ArgumentError, "invalid persona key: #{key.inspect}" unless valid_key?(key)

      persona = Persona.from(persona)
      raise ArgumentError, "invalid persona" unless persona

      # A reference is stored as written: it names another key, and validating
      # its (absent) model would only strip it back to nothing.
      unless persona.reference?
        # The slug is part of the key; keep the record self-describing.
        persona = normalize_persona(persona_with_slug(persona, self.class.slug_for_key(key)))
      end

      @mutex.synchronize do
        data = load_from_disk
        data[key] = persona
        write!(data)
      end

      # What a caller wants back is the persona that will actually run.
      persona.reference? ? self[key] : persona
    end

    def delete(key)
      key = key.to_s
      # The workspace is left on disk on purpose: deleting a persona must not
      # silently destroy its SOUL.md, memory and files.
      @mutex.synchronize do
        data = load_from_disk
        removed = data.delete(key)
        write!(data) if removed
        removed
      end
    end

    # "chat:thread", or nil for non-topic sessions (Telegram's General topic
    # uses the global/default persona).
    def self.key_for(chat_id, thread_id)
      return nil if chat_id.nil? || thread_id.nil?

      chat = chat_id.to_s
      thread = thread_id.to_s
      return nil unless chat.match?(/\A-?\d+\z/) && thread.match?(/\A\d+\z/)

      "#{chat}:#{thread}"
    end

    # Maps a channel session id to a persona key:
    #   "tg_<chat>_<thread>"    -> "<chat>:<thread>"
    #   "web_<slug>"            -> "<slug>"   (the persona's first session)
    #   "web_<slug>~<stamp>"    -> "<slug>"   (a session opened later)
    #
    # "~" is the separator because a slug may contain "-" and "_", so the
    # boundary would otherwise be ambiguous. Several sessions share one persona,
    # which is why the suffix is ignored here: the persona is what owns the
    # workspace and the SOUL, not the individual conversation.
    def self.key_for_session(session_id)
      id = session_id.to_s

      if (match = /\Atg_(-?\d+)_(\d+)\z/.match(id))
        return "#{match[1]}:#{match[2]}"
      end
      if (match = /\Aweb_([a-z0-9][a-z0-9_-]{0,31})(?:~[a-z0-9-]+)?\z/.match(id))
        return match[1]
      end
      # A terminal has no topics and no pages, so a fired persona job gets a
      # conversation of its own rather than reusing the browser's.
      if (match = /\Atui_([a-z0-9][a-z0-9_-]{0,31})(?:~[a-z0-9-]+)?\z/.match(id))
        return match[1]
      end

      nil
    end

    # The slug part of a key, or nil when the key is a Telegram topic.
    def self.slug_for_key(key)
      text = key.to_s
      SLUG_PATTERN.match?(text) ? text : nil
    end

    def self.valid_slug?(slug)
      text = slug.to_s
      SLUG_PATTERN.match?(text) && !RESERVED_SLUGS.include?(text)
    end

    private

    def valid_key?(key)
      KEY_PATTERN.match?(key) && (self.class.slug_for_key(key).nil? || self.class.valid_slug?(key))
    end

    def persona_with_slug(persona, slug)
      return persona if slug.nil? || persona.slug == slug

      rebuild(persona, slug: slug)
    end

    # A persona whose model disappeared from config.yml must fall back to
    # the default model rather than breaking the topic.
    def normalize_persona(persona)
      if persona.preset
        alias_preset = persona.preset.casecmp?("default") || persona.preset.casecmp?("primary")
        valid_preset = alias_preset || available_presets.empty? ||
                       available_presets.any? { |name| name.casecmp?(persona.preset) }
        return persona if valid_preset

        warn "[persona] model preset '#{persona.preset}' is not configured — using the session default"
        return rebuild(persona, preset: nil)
      end

      model = persona.model
      return persona if model.nil? || available_models.empty?
      return persona if available_models.include?(model)
      return persona if ModelCatalog.cached_model_ids(dir).include?(model)

      warn "[persona] model '#{model}' is not in config.yml — using the default model"
      rebuild(persona, model: nil)
    end

    def rebuild(persona, slug: persona.slug, preset: persona.preset, model: persona.model)
      Persona.new(
        slug: slug,
        name: persona.name,
        emoji: persona.emoji,
        accent: persona.accent,
        preset: preset,
        model: model,
        system_prompt: persona.system_prompt,
        skills: persona.skills,
        disabled_skills: persona.disabled_skills,
        tool_output: persona.tool_output,
        ref: persona.ref,
        created_at: persona.created_at,
        internal: persona.internal
      )
    end

    # Follow `ref` until it lands on a persona that names itself. A dangling or
    # circular reference resolves to nil, which is what a missing persona looks
    # like to every caller.
    def resolve(key, data)
      persona = data[key]
      depth = 0

      while persona&.reference? && depth < MAX_REF_DEPTH
        persona = data[persona.ref]
        depth += 1
      end

      persona&.reference? ? nil : persona
    end

    def load_from_disk
      readable = source_path
      return {} unless File.exist?(readable)

      raw = File.read(readable)
      return {} if raw.strip.empty?

      parsed = JSON.parse(raw)
      return {} unless parsed.is_a?(Hash)

      parsed.each_with_object({}) do |(key, value), personas|
        unless valid_key?(key)
          warn "[persona] ignoring invalid key #{key.inspect} in #{readable}"
          next
        end

        persona = Persona.from(value)
        next unless persona
        # An internal persona is a built-in sub agent, not a user persona. It
        # must never leak into the sidebar, /delegates or a topic picker.
        next if persona.internal

        personas[key] = normalize_persona(persona)
      end
    rescue JSON::ParserError => e
      warn "[persona] ignoring unreadable #{readable}: #{e.message}"
      {}
    end

    # New location first, then the pre-web file that lived in the workspace.
    def source_path
      return path if File.exist?(path)

      legacy = @legacy_workspace && File.join(@legacy_workspace, FILENAME)
      legacy && File.exist?(legacy) ? legacy : path
    end

    def write!(data)
      FileUtils.mkdir_p(File.dirname(path))
      payload = JSON.pretty_generate(data.transform_values(&:to_h))
      tmp = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"

      File.write(tmp, payload)
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end
  end
end
