# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "model_catalog"
require_relative "persona"

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
  #   * "chat:thread" — a Telegram forum topic (model + prompt only)
  #   * "slug"        — a web persona, which also gets a workspace directory
  #
  # The file is read on every lookup instead of being cached: the channels and
  # the SessionPool own separate store instances, and a persona saved by one
  # must be visible to the others immediately.
  class PersonaStore
    FILENAME = "personas.json"
    SLUG_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,31}\z/
    KEY_PATTERN = /\A(?:-?\d+:\d+|[a-z0-9][a-z0-9_-]{0,31})\z/
    RESERVED_SLUGS = %w[default general all new none].freeze

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

    # Where a slug's agent files (SOUL.md, AGENTS.md, skills/, working files)
    # live, or nil for a key that does not own a workspace.
    def workspace_for(key)
      slug = self.class.slug_for_key(key)
      slug && File.join(dir, "personas", slug)
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

    def [](key)
      all[key.to_s]
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

      # The slug is part of the key; keep the record self-describing.
      persona = normalize_persona(persona_with_slug(persona, self.class.slug_for_key(key)))

      @mutex.synchronize do
        data = load_from_disk
        data[key] = persona
        write!(data)
      end

      persona
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
    #   "tg_<chat>_<thread>" -> "<chat>:<thread>"
    #   "web_<slug>"         -> "<slug>"
    def self.key_for_session(session_id)
      id = session_id.to_s

      if (match = /\Atg_(-?\d+)_(\d+)\z/.match(id))
        return "#{match[1]}:#{match[2]}"
      end
      if (match = /\Aweb_([a-z0-9][a-z0-9_-]{0,31})\z/.match(id))
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
        created_at: persona.created_at
      )
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
