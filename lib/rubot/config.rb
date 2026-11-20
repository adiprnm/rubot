# frozen_string_literal: true

require "yaml"
require "fileutils"
require "pathname"
require "digest"
require_relative "provider"

module Rubot
  class Config
    DEFAULT_CONFIG_DIR  = File.expand_path("~/.rubot")
    DEFAULT_CONFIG_FILE = File.join(DEFAULT_CONFIG_DIR, "config.yml")
    DEFAULT_WORKSPACE   = File.join(DEFAULT_CONFIG_DIR, "workspace")
    # Maximum number of agent rounds per user message. A round is one trip
    # through the agent loop: running the tools the model asked for, re-asking
    # after an empty reply, or asking for the rest of a cut-off answer. It is
    # not a tool-call count: one round can run several tools.
    #
    # It is a last-resort net, not a workflow. At 50 it was neither: a real
    # piece of work — read, edit, test, fix, test again — spent it, and the turn
    # then ended with a notice asking the reader to type "continue", sometimes
    # several turns in a row. A runaway loop is stopped by the reader's own
    # Stop button and by the turn's cost figure; this number only exists to
    # catch a model that would otherwise loop forever with nobody watching.
    DEFAULT_MAX_ROUNDS = 1000
    # Old constant name, kept so existing callers keep working.
    DEFAULT_MAX_TOOL_ITERATIONS = DEFAULT_MAX_ROUNDS
    DEFAULT_AUTO_COMPACT = true
    DEFAULT_COMPACT_THRESHOLD_PERCENT = 60.0
    # Messages kept verbatim next to the summary. Six was a caption's worth: a
    # turn reads four files and runs two commands in that many messages, so a
    # compaction in the middle of it left the summary describing work the model
    # could no longer see. Forty holds a real stretch of a tool-heavy turn, and
    # still leaves the summary doing its job (the prompt is a fraction of the
    # transcript it replaces).
    DEFAULT_COMPACT_KEEP_RECENT = 40
    DEFAULT_COMPACT_KEEP_RECENT_TOKENS = 20_000
    DEFAULT_TOOL_RESULT_KEEP = 3
    DEFAULT_TOOL_RESULT_MAX_CHARS = 2_000
    # Used for the compaction threshold when the model's real window cannot be
    # resolved, so an unknown model still gets a bound instead of no compaction.
    DEFAULT_CONTEXT_WINDOW = 128_000
    # Memory extraction used to run on every user message, one extra provider
    # request per turn. Batching it over a few turns keeps the same coverage
    # for a fraction of the cost (0 disables extraction).
    DEFAULT_MEMORY_EXTRACT_EVERY = 3
    # Delegation lets one agent hand a task to another persona. Off by default
    # so an existing install never starts spawning extra provider requests it
    # did not ask for. The limits are a net against a runaway chain: a sub agent
    # cannot delegate again (depth 1), and one turn cannot fan out past a few.
    DEFAULT_DELEGATION_ENABLED = false
    DEFAULT_DELEGATION_MAX_PER_TURN = 4
    DEFAULT_DELEGATION_MAX_DEPTH = 1

    attr_reader :config_path, :data

    def initialize(config_path = nil)
      @config_path = config_path || ENV["RUBOT_CONFIG"] || DEFAULT_CONFIG_FILE
      @data = load_config
    end

    # Build a Config around already-loaded data (used to hand a plain-data
    # snapshot to a Ractor). The data is not copied here: the Ractor message
    # boundary already deep-copies unshareable objects.
    def self.from_data(data, config_path: nil)
      config = allocate
      config.instance_variable_set(:@config_path, config_path || DEFAULT_CONFIG_FILE)
      config.instance_variable_set(:@data, data || {})
      config
    end

    # Plain, Ractor-sendable snapshot of the underlying configuration.
    def snapshot
      Marshal.load(Marshal.dump(@data))
    end

    # The settings a form owns, and what they are called in the data: the
    # provider, the one key for it, and the default model. A page that could
    # reach the rest of the file would be a config editor wearing a form's
    # labels, with none of the review.
    SETTINGS = { "provider" => "provider", "api_key" => "api_key", "default_model" => "model", "auxiliary_model" => "auxiliary_model" }.freeze

    # Lay saved settings over what config.yml says.
    #
    # An empty value deletes the key rather than writing "": a cleared field
    # means "whatever the file says", which is the only reading that lets an
    # install go back to its config.yml without editing the database by hand.
    def apply_settings(settings)
      (settings || {}).each do |key, value|
        target = SETTINGS[key.to_s]
        next unless target

        text = value.to_s.strip
        text.empty? ? @data.delete(target) : @data[target] = text
      end
      self
    end

    def agent_defaults
      data.dig("agents", "defaults") || {}
    end

    def models
      data["models"] || []
    end

    alias model_list models

    def providers
      raw = data["providers"]
      raw.is_a?(Hash) ? raw : {}
    end

    def selected_provider
      name = (data["provider"] || agent_defaults["provider"]).to_s.strip
      name = "openai" if name.empty?
      entry = providers[name]
      entry.is_a?(Hash) ? entry : {}
    end

    def provider
      return data["provider"] if data["provider"]
      return agent_defaults["provider"] if agent_defaults["provider"]
      model_str = active_model_entry["model"] || "openai/#{name}"
      model_str.split("/").first
    end

    def name
      agent_defaults["name"] || "gpt-4o-mini"
    end

    def model
      return data["model"] if data["model"]
      return agent_defaults["model"] if agent_defaults["model"]
      entry = active_model_entry
      model_str = entry["model"] || "openai/#{name}"
      model_str.split("/").last
    end

    alias model_name model

    def active_model_entry
      return {} if models.empty?
      models.find { |m| m["name"] == name } || models.first
    end

    def model_entry_by_name(model_name)
      return nil if models.empty?
      models.find { |m| m["name"] == model_name }
    end

    def api_key
      global_api_key || selected_provider["api_key"] || active_model_entry["api_key"] || agent_defaults["api_key"] || ENV["RUBOT_API_KEY"] || ENV["OPENAI_API_KEY"]
    end

    # A key set for the whole install, in front of the per-model ones.
    #
    # This is the field the settings page writes. It is deliberately the last
    # thing consulted *after* the entry only in the sense that it is one key for
    # every provider: an install that switched provider would otherwise keep
    # using the old entry's credential and fail with a 401 nobody could explain
    # from the form they just saved.
    def global_api_key
      text = data["api_key"].to_s.strip
      text.empty? ? nil : text
    end

    def api_base
      selected_provider["api_base"] || active_model_entry["api_base"] || agent_defaults["api_base"] || data["api_base"] || ENV["RUBOT_API_BASE"] || ENV["OPENAI_API_BASE"]
    end

    # Build an immutable ProviderSettings snapshot for the given model
    # (or the active model when nil). This replaces the old approach of
    # temporarily mutating config.data during provider rebuilds.
    #
    # A model name that is not a config.yml entry is treated as a raw provider
    # model id (e.g. a model from the provider's /models catalog), using the
    # active entry's credentials and base URL.
    def provider_settings(model_name = nil)
      entry = model_name ? model_entry_by_name(model_name) : active_model_entry
      dynamic = !model_name.nil? && entry.nil?
      base_entry = dynamic ? active_model_entry : entry
      base_entry ||= {}
      entry ||= {}

      model_str = entry["model"] || "openai/#{name}"
      model_id = if dynamic
        model_name.to_s
      else
        data["model"] || model_str.split("/").last
      end
      provider_name = if data["provider"]
        data["provider"]
      elsif dynamic
        provider
      else
        model_str.split("/").first
      end

      ProviderSettings.new(
        provider: provider_name,
        model: model_id,
        api_key: global_api_key || base_entry["api_key"] || api_key,
        api_base: base_entry["api_base"] || api_base,
        max_tokens: max_tokens,
        temperature: temperature,
        debug: debug?,
        extra_headers: base_entry["extra_headers"].is_a?(Hash) ? base_entry["extra_headers"] : {},
        reasoning_effort: reasoning_effort
      )
    end

    # Global default reasoning effort ("minimal", "low", "medium", "high").
    # Presets may override it with their own `reasoning_effort`.
    def reasoning_effort
      raw = agent_defaults["reasoning_effort"] || agent_defaults["reasoningEffort"]
      text = raw.to_s.strip.downcase
      text.empty? ? nil : text
    end

    def max_tokens
      agent_defaults["max_tokens"] || 4096
    end

    def temperature
      agent_defaults["temperature"] || 0.3
    end

    # The model for the requests that are not the conversation: naming a
    # session, extracting memory. They ask for a title or a JSON object, not
    # for an answer, so the persona's model is waste — a fast, cheap one costs
    # a fifth as much and answers in a fraction of the time. Unset means "the
    # same model as the conversation", which is what every build did before.
    def auxiliary_model
      raw = data["auxiliary_model"] || agent_defaults["auxiliary_model"] || agent_defaults["auxiliaryModel"]
      text = raw.to_s.strip
      text.empty? ? nil : text
    end

    # Settings for the auxiliary model, or nil when it is not configured. A
    # name that matches a `model_presets` entry takes that preset whole
    # (model, credentials, pricing), so one line of config can point at a
    # preset that already exists; anything else is read as a model name the
    # provider knows, borrowing the conversation's credentials.
    def auxiliary_settings
      name = auxiliary_model
      return nil if name.nil?

      model_preset(name) ? provider_settings_for_preset(name) : provider_settings(name)
    end

    # Command the TUI runs on ctrl+g to edit the prompt before sending it.
    # Resolved from config first; the TUI falls back to $VISUAL, $EDITOR and
    # then `vi`. The command has to block until the file is written (use
    # `code --wait`, not `code`).
    def external_editor
      raw = data["external_editor"] || agent_defaults["external_editor"] || agent_defaults["externalEditor"]
      text = raw.to_s.strip
      text.empty? ? nil : text
    end

    # --- Model presets ---------------------------------------------------
    #
    # A preset is a named, complete model configuration:
    #
    #   model_presets:
    #     fast:
    #       model: deepseek-v4.1-flash
    #       max_tokens: 4096
    #       temperature: 0.2
    #
    # `model` may be a provider model id or a config `models` entry name.
    # Credentials and api_base are inherited from that entry (or the active
    # entry) unless the preset overrides them.

    def model_presets
      raw = data["model_presets"] || data["modelPresets"]
      raw.is_a?(Hash) ? raw : {}
    end

    def model_preset_names
      names = model_presets.keys.map(&:to_s).reject(&:empty?)
      primary = primary_model_preset_name
      names = names.sort_by do |name|
        [ name.casecmp?(primary) ? 0 : 1, name.downcase ]
      end
      return names unless primary.casecmp?("default")

      names.unshift("default") unless names.any? { |name| name.casecmp?("default") }
      names
    end

    def model_preset(name)
      return nil if name.nil?

      wanted = name.to_s.strip
      return nil if wanted.empty?

      key, raw = model_presets.find { |candidate, _| candidate.to_s.casecmp?(wanted) }
      return normalize_model_preset(key.to_s, raw) if raw.is_a?(Hash)
      return default_model_preset if wanted.casecmp?("default") || wanted.casecmp?("primary")

      nil
    end

    def default_model_preset_name
      value = agent_defaults["model_preset"] || agent_defaults["modelPreset"]
      value = value.to_s.strip
      value.empty? ? nil : value
    end

    def default_model_preset
      name = default_model_preset_name
      if name && !name.casecmp?("default")
        explicit_primary = model_presets.keys.any? { |key| key.to_s.casecmp?("primary") }
        unless name.casecmp?("primary") && !explicit_primary
          preset = model_preset(name)
          return preset if preset
        end
      end

      implicit_default_preset
    end

    # The preset followed by sessions that have no explicit selection. Always
    # exists: it is either agents.defaults.model_preset or the implicit
    # `default` built from the direct model fields.
    def primary_model_preset_name
      name = default_model_preset_name
      return name if name && !name.casecmp?("default") && model_preset(name)

      "default"
    end

    def implicit_default_preset
      entry = active_model_entry || {}
      entry_model = entry["model"].to_s
      {
        "name" => "default",
        "model" => model,
        "provider" => data["provider"] || (entry_model.include?("/") ? entry_model.split("/").first : provider),
        "api_key" => entry["api_key"] || ENV["RUBOT_API_KEY"] || ENV["OPENAI_API_KEY"],
        "api_base" => entry["api_base"] || ENV["RUBOT_API_BASE"] || ENV["OPENAI_API_BASE"],
        "max_tokens" => max_tokens,
        "temperature" => temperature,
        "reasoning_effort" => nil,
        "context_window_tokens" => entry["context_window_tokens"] || entry["contextWindowTokens"],
        "pricing" => entry["pricing"],
        "extra_headers" => entry["extra_headers"].is_a?(Hash) ? entry["extra_headers"] : {},
        "implicit" => true
      }
    end

    def provider_settings_for_preset(preset_or_name)
      preset = if preset_or_name.is_a?(Hash)
        raw = preset_or_name.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
        normalize_model_preset(raw["name"] || "custom", raw)
      else
        model_preset(preset_or_name)
      end

      return provider_settings if preset.nil?

      ProviderSettings.new(
        provider: preset["provider"],
        model: preset["model"],
        api_key: preset["api_key"] || api_key,
        api_base: preset["api_base"] || api_base,
        max_tokens: preset["max_tokens"] || max_tokens,
        temperature: preset["temperature"] || temperature,
        debug: debug?,
        extra_headers: preset["extra_headers"].is_a?(Hash) ? preset["extra_headers"] : {},
        reasoning_effort: preset["reasoning_effort"]
      )
    end

    # Safe, plain-data view for chat commands (never includes credentials).
    def public_model_preset(preset)
      return nil unless preset.is_a?(Hash)

      preset.slice(
        "name", "model", "provider", "max_tokens", "temperature",
        "reasoning_effort", "context_window_tokens", "pricing", "implicit"
      )
    end

    # Create or update a preset. Only explicitly supplied fields are written
    # to config.yml; inherited credentials are resolved at runtime.
    def set_model_preset(name, attributes)
      name = name.to_s.strip
      raise ArgumentError, "preset name is required" if name.empty?
      if name.casecmp?("default")
        raise ArgumentError, "'default' is reserved for the implicit config preset"
      end
      unless name.match?(/\A[A-Za-z0-9_.-]+\z/)
        raise ArgumentError, "preset name may only contain letters, numbers, dot, dash and underscore"
      end

      allowed = %w[
        model provider api_base api_key extra_headers max_tokens temperature
        reasoning_effort context_window_tokens pricing
      ]
      attrs = attributes.each_with_object({}) do |(key, value), acc|
        key = key.to_s
        next unless allowed.include?(key)
        next if value.nil? || value.to_s.strip.empty?

        acc[key] = value
      end
      attrs["max_tokens"] = attrs["max_tokens"].to_i if attrs.key?("max_tokens")
      attrs["temperature"] = attrs["temperature"].to_f if attrs.key?("temperature")
      attrs["context_window_tokens"] = attrs["context_window_tokens"].to_i if attrs.key?("context_window_tokens")

      presets = model_presets.dup
      existing = presets[name].is_a?(Hash) ? presets[name] : {}
      merged = existing.merge(attrs)

      preset = normalize_model_preset(name, merged)
      raise ArgumentError, "preset requires a model" if preset.nil?

      presets[name] = merged
      data["model_presets"] = presets
      data.delete("modelPresets")
      preset
    end

    def delete_model_preset(name)
      name = name.to_s.strip
      presets = model_presets.dup
      key = presets.keys.find { |candidate| candidate.to_s.casecmp?(name) }
      return false unless key

      presets.delete(key)
      data["model_presets"] = presets
      data.delete("modelPresets")

      if default_model_preset_name.to_s.casecmp?(key.to_s)
        defaults = data["agents"] && data["agents"]["defaults"]
        if defaults.is_a?(Hash)
          defaults.delete("model_preset")
          defaults.delete("modelPreset")
        end
      end

      true
    end

    def set_default_model_preset(name)
      defaults = data["agents"] && data["agents"]["defaults"]
      defaults = data["agents"] = { "defaults" => {} } unless defaults.is_a?(Hash)

      value = name.to_s.strip
      if value.empty? || value.casecmp?("default")
        defaults.delete("model_preset")
        defaults.delete("modelPreset")
        return nil
      end
      if value.casecmp?("primary") && model_presets.keys.none? { |key| key.to_s.casecmp?("primary") }
        defaults.delete("model_preset")
        defaults.delete("modelPreset")
        return nil
      end

      preset = model_preset(value)
      raise ArgumentError, "unknown model preset: #{value}" unless preset

      defaults["model_preset"] = preset["name"]
      defaults.delete("modelPreset")
      preset["name"]
    end

    def system_prompt
      agent_defaults["system_prompt"] || default_system_prompt
    end

    def workspace
      ws = agent_defaults["workspace"] || DEFAULT_WORKSPACE
      ws.start_with?("~") ? File.expand_path(ws) : ws
    end

    # A copy of this config whose agent workspace is `path`, leaving the
    # loaded file untouched. The TUI uses it to take the directory it was
    # launched from as its workspace instead of the configured default.
    #
    # `assets_workspace` keeps pointing at the configured workspace, so the
    # SOUL.md, MEMORY.md, AGENTS.md and skills/ that were set up there are
    # still loaded while code work happens in the project directory.
    def with_workspace(path, sessions_cwd: nil)
      original = workspace
      copy = self.class.from_data(snapshot, config_path: config_path)
      agents = copy.data["agents"]
      agents = copy.data["agents"] = {} unless agents.is_a?(Hash)
      defaults = agents["defaults"]
      defaults = agents["defaults"] = {} unless defaults.is_a?(Hash)
      defaults["workspace"] = File.expand_path(path)
      # The directory the TUI was launched from. Sessions are stored centrally
      # (see #sessions_dir), so this marker is what lets /resume show only the
      # conversations that belong to the project the user is standing in. It
      # is independent of the workspace now: files go to the configured
      # workspace, while /resume still filters on where rubot was launched.
      defaults["sessions_cwd"] = File.expand_path(sessions_cwd) if sessions_cwd
      copy
    end

    # A copy whose agent reads its identity from a persona's own directory.
    #
    # Unlike #with_workspace this *overwrites* `assets_workspace`. A specialist
    # persona must load its own SOUL.md and AGENTS.md instead of inheriting the
    # main workspace's, and `||=` there would silently keep the old path and
    # hand the persona someone else's identity. Its memory moves into that
    # directory too (see #workspace_memory_path), so a persona carries its
    # facts, preferences and context with it. Sessions stay in the central
    # directory (see #sessions_dir); only the working root moves.
    #
    # Skills are the exception: they stay in the shared skills directory (see
    # #skills_workspace), which the persona workspace does not move, so every
    # persona reads one copy and updating a skill updates it everywhere.
    def with_persona_workspace(path)
      copy = self.class.from_data(snapshot, config_path: config_path)
      agents = copy.data["agents"]
      agents = copy.data["agents"] = {} unless agents.is_a?(Hash)
      defaults = agents["defaults"]
      defaults = agents["defaults"] = {} unless defaults.is_a?(Hash)

      full = File.expand_path(path)
      # The skills fallbacks are pinned before the workspace moves: `workspace`
      # is re-rooted at the persona and would otherwise take the old tree out
      # of the list, hiding the skills an upgrade left behind.
      previous = legacy_skills_workspaces
      defaults["workspace"] = full
      defaults["assets_workspace"] = full
      defaults["sessions_cwd"] = full
      defaults["legacy_skills_workspaces"] = previous unless previous.empty?
      defaults["memory_in_workspace"] = true
      copy
    end

    # Where persona metadata and per-persona workspaces live. Next to
    # config.yml, never inside `workspace`: a persona's files must not be
    # mistaken for the main agent's, and a custom config directory should take
    # its personas along.
    def personas_dir
      File.join(File.dirname(config_path), "personas")
    end

    def personas_file
      File.join(File.dirname(config_path), "personas.json")
    end

    # The directory the current session was started from, or nil when the
    # channel has no notion of one (Telegram). Read from the config file data,
    # never from the live working directory, so a resumed session keeps the
    # origin it was created with.
    def sessions_cwd
      raw = agent_defaults["sessions_cwd"]
      raw && !raw.to_s.strip.empty? ? File.expand_path(raw.to_s) : nil
    end

    # Where session files live. Next to config.yml (~/.rubot/sessions by
    # default), not in the workspace: sessions belong to the bot, and the TUI
    # re-roots the workspace to whatever project it is launched from. Keeping
    # them one level up also means a custom config directory takes its sessions
    # with it.
    def sessions_dir
      File.join(File.dirname(config_path), "sessions")
    end

    # --- Memory -----------------------------------------------------------
    #
    # Memory has two layers. The global file sits next to config.yml and
    # holds what is true everywhere (who the user is, how they want the bot to
    # behave). The second layer holds what belongs to one place: a project for
    # the TUI, a persona for a specialist. A project's file is keyed by the
    # workspace path, so the TUI — which re-roots the workspace to the
    # directory it was launched from — keeps a separate memory per project; a
    # persona's file lives inside the persona's own directory.
    def global_memory_path
      File.join(File.dirname(config_path), "MEMORY.md")
    end

    def memory_dir
      File.join(File.dirname(config_path), "memory")
    end

    # A persona keeps its memory inside its own directory, so the folder the
    # reader sees for a specialist holds everything that specialist is.
    def memory_in_workspace?
      agent_defaults["memory_in_workspace"] == true
    end

    # What the tools and the prompt call this memory layer. A persona's layer
    # belongs to that persona, not to a project, and the label is what the
    # model is told when it reads or writes.
    def memory_scope_label
      memory_in_workspace? ? "persona" : "workspace"
    end

    # Path of the workspace memory file for `path` (default: this config's
    # workspace). The name is readable and carries a short digest of the full
    # path, so two projects with the same basename cannot collide. A persona
    # (see #with_persona_workspace) keeps its file inside its own directory
    # instead: there it belongs to the persona, not to a path.
    def workspace_memory_path(path = workspace)
      full = File.expand_path(path.to_s)
      return File.join(full, "MEMORY.md") if memory_in_workspace?

      File.join(memory_dir, "#{memory_slug(full)}.md")
    end

    # Where the model catalog and the pricing cache live.
    #
    # Shared, not per workspace: what a model costs is the same answer for
    # every persona, and a per-workspace copy meant one network refresh per
    # specialist and one file to keep in step in each of them. It sits next to
    # config.yml, beside the sessions and the global memory.
    def catalog_dir
      File.dirname(config_path)
    end

    # Where SOUL.md, MEMORY.md, AGENTS.md and skills/ are read from. Normally
    # the workspace itself; a channel that re-roots the workspace (the TUI
    # takes the launch directory) leaves this at the configured workspace so
    # the agent keeps its identity and memory.
    def assets_workspace
      raw = agent_defaults["assets_workspace"]
      raw && !raw.to_s.strip.empty? ? File.expand_path(raw.to_s) : catalog_dir
    end

    # Where skills live: next to config.yml (~/.rubot/skills by default), not
    # inside the workspace. A persona re-roots its workspace at its own
    # directory and the TUI re-roots it at whatever project it was launched
    # from, so a workspace-relative skills tree would be copied once per
    # persona or lost in a project. One directory serves every persona and
    # every project; a persona's prompt says which of them it may use.
    #
    # Like a workspace, this is the *root* the registry appends `skills/` to,
    # so the default lands on ~/.rubot/skills; a config that still names one
    # keeps it.
    def skills_workspace
      raw = agent_defaults["skills_workspace"]
      raw && !raw.to_s.strip.empty? ? File.expand_path(raw.to_s) : catalog_dir
    end

    # The shared skills directory itself: `~/.rubot/skills`, the sibling of
    # config.yml, so a custom config directory takes its skills along.
    def global_skills_dir
      File.join(skills_workspace, SkillRegistry::SKILLS_DIR_NAME)
    end

    # Directories an install may still keep skills in: before the shared
    # directory, skills were read from the workspace (and, for a channel that
    # re-roots it, from the assets workspace). Leaving those out would make
    # every existing skill vanish on upgrade, so they are read after the
    # shared one — nothing is moved, and a skill dropped in the old place
    # keeps working.
    def legacy_skills_workspaces
      extra = Array(agent_defaults["legacy_skills_workspaces"])
      roots = [workspace, assets_workspace, *extra].compact
      roots.map { |path| File.expand_path(path.to_s) }.uniq - [skills_workspace]
    end

    def restrict_to_workspace
      val = agent_defaults["restrict_to_workspace"]
      # Default to true for security (matches PicoClaw default)
      return true if val.nil?
      !!val
    end

    def allow_read_outside_workspace
      val = agent_defaults["allow_read_outside_workspace"]
      !!val
    end

    # Auto mode. When on, the agent runs any action the safety guard allows
    # without asking first. The guard's own destructive patterns (rm -rf /,
    # mkfs, dd onto a device, ...) are checked inside the tool itself and are
    # still refused, so auto mode is not a bypass — it only skips the prompt.
    def auto_approve
      agent_defaults["auto_approve"] == true
    end

    # Set auto mode and write it back to config.yml, so the next launch starts
    # in the same mode instead of forgetting the choice.
    def set_auto_approve(value)
      agents = data["agents"]
      agents = data["agents"] = {} unless agents.is_a?(Hash)
      defaults = agents["defaults"]
      defaults = agents["defaults"] = {} unless defaults.is_a?(Hash)
      defaults["auto_approve"] = !!value
      save
      defaults["auto_approve"]
    end

    def max_rounds
      limit = agent_defaults["max_rounds"]
      # `max_tool_iterations` is the old name; still accepted so existing
      # config files keep working.
      limit = agent_defaults["max_tool_iterations"] if limit.nil?
      limit = limit.to_i
      limit.positive? ? limit : DEFAULT_MAX_ROUNDS
    end

    # Deprecated alias for callers that still use the old name.
    alias max_tool_iterations max_rounds

    # --- History window --------------------------------------------------
    #
    #   agents:
    #     defaults:
    #       history:
    #
    # Flat aliases are accepted.
    def history
      raw = agent_defaults["history"]
      raw.is_a?(Hash) ? raw : {}
    end

    # Approximate token budget for the history block. 0 disables the cap, so
    # the message-count limit is the only bound (the old behaviour).

    # --- Context compaction ----------------------------------------------
    #
    #   agents:
    #     defaults:
    #       compaction:
    #         auto: true              # summarize old turns automatically
    #         threshold_percent: 60   # ...when the context is 60% full
    #         keep_recent_messages: 10 # turns kept verbatim after compaction
    #
    # Flat aliases (`auto_compact`, `compact_threshold_percent`,
    # `compact_keep_recent_messages`) are accepted for convenience.
    def compaction
      raw = agent_defaults["compaction"] || agent_defaults["compact"]
      raw.is_a?(Hash) ? raw : {}
    end

    def auto_compact?
      raw = compaction
      value = if raw.key?("auto")
        raw["auto"]
      elsif raw.key?("auto_compact")
        raw["auto_compact"]
      elsif agent_defaults.key?("auto_compact")
        agent_defaults["auto_compact"]
      else
        DEFAULT_AUTO_COMPACT
      end

      return DEFAULT_AUTO_COMPACT if value.nil?

      value = value.to_s.downcase if value.is_a?(String)
      ![ false, 0, "0", "false", "no", "off" ].include?(value)
    end

    # Share of the model's context window (1..100) that triggers compaction.
    # A value between 0 and 1 is treated as a fraction (0.8 == 80%).
    def compact_threshold_percent
      raw = compaction["threshold_percent"] || compaction["threshold"] ||
            agent_defaults["compact_threshold_percent"] || agent_defaults["compact_threshold"]
      value = raw.to_f
      return DEFAULT_COMPACT_THRESHOLD_PERCENT unless value.positive?

      value *= 100.0 if value <= 1.0
      value.clamp(1.0, 100.0)
    end

    def compact_keep_recent_messages
      raw = compaction["keep_recent_messages"] || compaction["keep_recent"] ||
            agent_defaults["compact_keep_recent_messages"]
      value = raw.to_i
      value.positive? ? value : DEFAULT_COMPACT_KEEP_RECENT
    end

    # Token-based equivalent of `compact_keep_recent_messages`: keep this many
    # tokens of the newest transcript verbatim and summarize the rest.
    def compact_keep_recent_tokens
      raw = compaction["keep_recent_tokens"] || compaction["keep_recent"]
      value = raw.to_i
      value.positive? ? value : DEFAULT_COMPACT_KEEP_RECENT_TOKENS
    end

    def token_based_compaction?
      compaction.key?("keep_recent_tokens") || compaction.key?("keep_recent")
    end

    # How many messages live in the session file before the oldest are dropped.
    # Purely a file-size guard: the task statement is stored separately, so
    # trimming cannot delete the user's goal.

    # Absolute token ceiling for compaction, independent of the model's
    # window. A 1M-token model at `threshold_percent: 50` otherwise never
    # compacts, because the threshold lands at 500k. 0 disables the cap.
    def compact_threshold_tokens
      raw = compaction["threshold_tokens"] || agent_defaults["compact_threshold_tokens"]
      value = raw.to_i
      value.positive? ? value : 0
    end

    # --- Memory ----------------------------------------------------------
    #
    #   agents:
    #     defaults:
    #       memory:
    #         extract_every: 3   # user messages per extraction request (0 = off)
    #         consolidate: true  # merge duplicates and cap section size
    #
    # Flat aliases (`memory_extract_every`, `memory_consolidate`) are accepted.
    def memory
      raw = agent_defaults["memory"]
      raw.is_a?(Hash) ? raw : {}
    end

    # How many user messages to collect before asking the model to extract
    # memory. 0 disables automatic extraction entirely.
    def memory_extract_every
      raw = memory["extract_every"] || agent_defaults["memory_extract_every"]
      return DEFAULT_MEMORY_EXTRACT_EVERY if raw.nil?

      value = raw.to_i
      value.negative? ? 0 : value
    end

    def memory_consolidate?
      raw = memory.key?("consolidate") ? memory["consolidate"] : agent_defaults["memory_consolidate"]
      return true if raw.nil?

      raw = raw.to_s.downcase if raw.is_a?(String)
      ![ false, 0, "0", "false", "no", "off" ].include?(raw)
    end

    # Delegation settings live under `delegation:` at the top level, next to
    # `tools:`. Kept separate from the tool toggle on purpose: enabling the
    # `delegate` tool alone should not silently turn on a feature that spends
    # provider requests on other personas.
    def delegation
      raw = data["delegation"]
      raw.is_a?(Hash) ? raw : {}
    end

    def delegation_enabled?
      raw = delegation["enabled"]
      return DEFAULT_DELEGATION_ENABLED if raw.nil?

      raw = raw.to_s.downcase if raw.is_a?(String)
      ![ false, 0, "0", "false", "no", "off" ].include?(raw)
    end

    def delegation_max_per_turn
      value = delegation["max_per_turn"].to_i
      value.positive? ? value : DEFAULT_DELEGATION_MAX_PER_TURN
    end

    def delegation_max_depth
      value = delegation["max_depth"].to_i
      value.positive? ? value : DEFAULT_DELEGATION_MAX_DEPTH
    end

    def tool_enabled?(name)
      return false unless tools_enabled
      tools = data["tools"] || {}
      tool = tools[name.to_s]
      return true if tool.nil?
      tool.is_a?(Hash) && tool["enabled"] != false
    end

    def tools_enabled
      tools = data["tools"]
      return true if tools.nil?
      return false if tools == false
      return true if tools.respond_to?(:empty?) && tools.empty?
      return false unless tools.is_a?(Hash)
      tools.values.any? { |t| t.is_a?(Hash) && t["enabled"] != false }
    end

    def enabled_tools
      tools = data["tools"]
      return [] unless tools.is_a?(Hash)
      tools.select { |_, t| t.is_a?(Hash) && t["enabled"] != false }.keys
    end

    def debug?
      data["debug"] == true || ENV["RUBOT_DEBUG"] == "1"
    end

    def ensure_workspace
      FileUtils.mkdir_p(workspace)
    end

    def save
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, data.to_yaml)
    end

    private

    # A filesystem-safe, human-readable name for a workspace path, suffixed
    # with a short digest so that two different paths that slugify the same
    # ("~/a/b c" and "~/a/b-c") still get their own file.
    def memory_slug(path)
      readable = path.sub(%r{\A/+}, "").gsub(/[^A-Za-z0-9._-]+/, "-").gsub(/-{2,}/, "-").sub(/-\z/, "")
      readable = readable[0, 60].sub(/-\z/, "")
      readable = "workspace" if readable.empty?
      "#{readable}-#{Digest::SHA1.hexdigest(path)[0, 8]}"
    end

    def normalize_model_preset(name, raw)
      raw = raw.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
      model_value = raw["model"] || raw["model_id"] || raw["modelId"]
      return nil if model_value.nil? || model_value.to_s.strip.empty?

      model_value = model_value.to_s.strip
      entry = model_entry_by_name(model_value)

      if entry
        entry_model = entry["model"].to_s
        model_id = entry_model.include?("/") ? entry_model.split("/").last : entry_model
        model_id = model_value if model_id.nil? || model_id.empty?
        provider_name = raw["provider"] || data["provider"] ||
                        (entry_model.include?("/") ? entry_model.split("/").first : provider)
        api_base = raw["api_base"] || entry["api_base"] ||
                   ENV["RUBOT_API_BASE"] || ENV["OPENAI_API_BASE"]
        api_key = raw["api_key"] || entry["api_key"] ||
                  ENV["RUBOT_API_KEY"] || ENV["OPENAI_API_KEY"]
        extra_headers = raw["extra_headers"] || entry["extra_headers"]
      else
        base = active_model_entry || {}
        model_id = model_value
        provider_name = raw["provider"] || data["provider"] || provider
        api_base = raw["api_base"] || base["api_base"] ||
                   ENV["RUBOT_API_BASE"] || ENV["OPENAI_API_BASE"]
        api_key = raw["api_key"] || base["api_key"] ||
                  ENV["RUBOT_API_KEY"] || ENV["OPENAI_API_KEY"]
        extra_headers = raw["extra_headers"] || base["extra_headers"]
      end

      {
        "name" => name.to_s,
        "model" => model_id,
        "provider" => provider_name,
        "api_key" => api_key,
        "api_base" => api_base,
        "max_tokens" => (raw["max_tokens"] || max_tokens).to_i,
        "temperature" => (raw["temperature"] || temperature).to_f,
        "reasoning_effort" => raw["reasoning_effort"] || raw["reasoningEffort"],
        "context_window_tokens" => raw["context_window_tokens"] || raw["contextWindowTokens"] ||
                                   (entry && (entry["context_window_tokens"] || entry["contextWindowTokens"])),
        "pricing" => normalize_pricing(raw["pricing"] || raw["price"] || (entry && entry["pricing"])),
        "extra_headers" => extra_headers.is_a?(Hash) ? extra_headers : {},
        "implicit" => false
      }
    end

    # Keep pricing as a plain string-keyed hash. Field aliases are resolved by
    # Rubot::ModelInfo when the report is built.
    def normalize_pricing(raw)
      return nil unless raw.is_a?(Hash)

      normalized = raw.each_with_object({}) do |(key, value), acc|
        acc[key.to_s] = value
      end
      normalized.empty? ? nil : normalized
    end

    def load_config
      return {} unless File.exist?(config_path)
      # FIX (VULN-14): Remove Symbol from permitted_classes to prevent
      # YAML-based symbol table exhaustion DoS attacks. All config access
      # in this codebase uses string keys, so symbols are unnecessary.
      YAML.safe_load(File.read(config_path), permitted_classes: []) || {}
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse config file: #{e.message}"
      {}
    end

    def default_system_prompt
      <<~PROMPT.chomp
        You are Rubot, a helpful AI assistant running in the terminal.
        You are written in Ruby and powered by the Rubot framework.

        You can execute shell commands, read/write files, and search the web
        using the tools available to you. Be concise and helpful.

        When you execute commands, explain what you're doing briefly before
        executing them. After executing, summarize the results.
      PROMPT
    end
  end
end
