# frozen_string_literal: true

require "time"

module Rubot
  # A persona: one agent specialised in one field.
  #
  # Two kinds share this value object. A Telegram forum topic is keyed by
  # "<chat>:<thread>" and either carries its own model + prompt or points at an
  # existing persona through `ref` (so a topic borrows a specialist's memory
  # without borrowing its conversation). A web persona is keyed by a slug and
  # owns a workspace (see PersonaStore#workspace_for), which is where its
  # SOUL.md, MEMORY.md and working files live.
  #
  # Plain data (a value object), so it can be handed to a session Ractor without
  # sharing mutable state. The workspace path is deliberately *not* stored here:
  # it is derived from the store's directory and the slug, so the file stays
  # portable and cannot point an agent at an arbitrary path.
  class Persona
    attr_reader :slug, :name, :emoji, :accent, :preset, :model, :thinking, :system_prompt,
                :skills, :disabled_skills, :ref, :created_at, :internal

    # The reasoning efforts a model understands, in the order the pickers show
    # them. A level outside this list is not a preference, it is a typo.
    THINKING_LEVELS = %w[minimal low medium high].freeze

    # How this persona's turns draw their tool calls. `verbose` is the timeline
    # as it happened; `compact` keeps only the call the agent is on right now,
    # which is what a busy turn needs when the calls are not the answer.
    TOOL_OUTPUT_MODES = %w[verbose compact].freeze
    DEFAULT_TOOL_OUTPUT = "verbose"

    # The faces a persona form offers. It is a suggestion, not a rule — the form
    # has a field for a face that is not here — but the roster is what makes the
    # choice a glance instead of a search through an emoji keyboard. The first
    # entry is the one a new persona wears when the form names none.
    EMOJI_CHOICES = %w[
      🤖 🧭 ✍️ 📚 🧪 🎨 🛠️ 🔍
      🧠 💼 🧑‍💻 📝 🎧 📷 💬 🧩
      🌱 🚀 🧾 🗂️ 🛰️ 🔮 🎯 🧵
      🥷 🦉 🐙 🍀 ☕ ⚡ 🌙 🎓
    ].freeze

    def initialize(slug: nil, name: nil, emoji: nil, accent: nil, preset: nil, model: nil,
                   thinking: nil, system_prompt: nil, skills: nil, disabled_skills: nil,
                   ref: nil, created_at: nil, tool_output: nil, internal: false)
      @slug = normalize_string(slug)
      @name = normalize_string(name)
      @emoji = normalize_string(emoji)
      @accent = normalize_string(accent)
      @preset = normalize_string(preset)
      @model = normalize_string(model)
      @thinking = normalize_thinking(thinking)
      @system_prompt = normalize_string(system_prompt)
      @skills = normalize_list(skills)
      @disabled_skills = normalize_list(disabled_skills)
      @ref = normalize_string(ref)
      # Only a mode that differs from the default is stored, so a persona that
      # never chose stays out of the file (and an older file reads as verbose).
      @tool_output = normalize_tool_output(tool_output)
      @created_at = created_at || Time.now.utc.iso8601
      @internal = internal == true || internal.to_s == "true"
    end

    # Build a Persona from a Hash (string or symbol keys) or return the
    # Persona unchanged. Returns nil when the value carries no persona data.
    def self.from(value)
      return value if value.is_a?(Persona)
      return nil unless value.is_a?(Hash)

      fetch = lambda do |key|
        value[key] || value[key.to_sym]
      end

      persona = new(
        slug: fetch.call("slug"),
        name: fetch.call("name"),
        emoji: fetch.call("emoji"),
        accent: fetch.call("accent"),
        preset: fetch.call("preset"),
        model: fetch.call("model"),
        thinking: fetch.call("thinking"),
        system_prompt: fetch.call("system_prompt"),
        skills: fetch.call("skills"),
        disabled_skills: fetch.call("disabled_skills"),
        ref: fetch.call("ref"),
        tool_output: fetch.call("tool_output"),
        created_at: fetch.call("created_at"),
        internal: fetch.call("internal")
      )
      persona.empty? ? nil : persona
    end

    def to_h
      {
        "slug" => @slug,
        "name" => @name,
        "emoji" => @emoji,
        "accent" => @accent,
        "preset" => @preset,
        "model" => @model,
        "thinking" => @thinking,
        "system_prompt" => @system_prompt,
        "skills" => @skills,
        "disabled_skills" => @disabled_skills,
        "ref" => @ref,
        "tool_output" => @tool_output,
        "created_at" => @created_at,
        "internal" => @internal
      }
    end

    def empty?
      [ @slug, @name, @emoji, @accent, @preset, @model, @thinking, @system_prompt, @ref,
        @tool_output ].all? { |value| value.nil? || value.to_s.empty? }
    end

    # A topic that borrows another persona instead of defining one.
    def reference?
      !@ref.nil? && !@ref.empty?
    end

    # What the chat header shows. Falls back to the slug so a persona without a
    # display name is never rendered as a blank row.
    def label
      @name || @slug
    end

    def emoji_or(default = "🤖")
      @emoji || default
    end

    # How this persona's turns draw their tool calls. The default is a mode
    # nobody had to choose, which is why it is answered here rather than
    # stored: a persona that never touched the setting says nothing in the
    # file and still reads as verbose.
    def tool_output
      @tool_output || DEFAULT_TOOL_OUTPUT
    end

    # True when a turn should show only the call it is on, not the log of every
    # call it made.
    def compact_tool_output?
      tool_output == "compact"
    end

    # Skills are shared by the whole install; this persona is the place that
    # says which of them it leaves switched off. A skill it *requires* (see
    # #skills) always stays on, so the two lists can never contradict each
    # other in the prompt.
    def skill_enabled?(name)
      key = name.to_s
      @skills.include?(key) || !@disabled_skills.include?(key)
    end

    # `names` narrowed to the skills this persona may use.
    def enabled_skills(names)
      Array(names).map(&:to_s).select { |name| skill_enabled?(name) }
    end

    private

    def normalize_string(value)
      return nil if value.nil?

      text = value.to_s.strip
      text.empty? ? nil : text
    end

    # Only a level the model understands is a default; anything else is
    # dropped rather than sent as a request argument the provider rejects.
    def normalize_thinking(value)
      text = normalize_string(value)&.downcase
      return nil if text.nil?

      THINKING_LEVELS.include?(text) ? text : nil
    end

    # A stored mode, or nil for the default. Anything the picker cannot produce
    # is a typo in a hand-edited file, so it is dropped rather than carried
    # around as a third mode nothing implements.
    def normalize_tool_output(value)
      text = normalize_string(value)&.downcase
      return nil if text.nil? || text == DEFAULT_TOOL_OUTPUT

      TOOL_OUTPUT_MODES.include?(text) ? text : nil
    end

    # Skill names the persona always works with. A plain string is accepted so
    # `"skills: kanyaah-brand"` in a hand-edited personas.json is not ignored.
    def normalize_list(value)
      list = case value
      when Array then value
      when String then value.split(",")
      else []
      end

      list.map { |entry| normalize_string(entry) }.compact.uniq
    end
  end
end
