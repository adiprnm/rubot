# frozen_string_literal: true

module Rubot
  class Agent
    # Which model answers, and which preset put it there.
    #
    # A session can override the model and the thinking level, a persona can
    # carry its own, and a preset can set both for a named purpose; the
    # precedence between those four is the whole of this module. It used to be
    # interleaved with the turn itself, which made "why did this turn go to that
    # model" a question you answered by reading agent.rb top to bottom.
    #
    # Moved as it was, comments included: the same four-step precedence, in the
    # same order, because a different order silently changes which model a
    # restored session runs on.
    module ModelSelection
      # Switch the current session to a named model preset. The choice is saved
      # on the session and survives actor/process restarts. A full preset hash
      # may be supplied when the caller's config snapshot is newer than ours.
      def use_model_preset(name, preset: nil)
        source = preset || @config.model_preset(name)
        return nil unless source.is_a?(Hash)

        apply_preset_source(source, name: name, session_name: name)
      end

      def active_model_preset
        return nil unless @active_preset

        @config.public_model_preset(@active_preset)
      end

      def model_presets
        @config.model_preset_names.filter_map do |name|
          preset = @config.model_preset(name)
          next unless preset

          @config.public_model_preset(preset)
        end
      end

      # Switch to a different model for the current session (legacy entry-based
      # API). Prefer #use_model_preset.
      # Model ids reported by the provider's /models endpoint, cached for the
      # lifetime of this agent. Used as a fallback when config.yml does not list
      # any models, and merged into the TUI model picker.
      def provider_model_entries
        @provider_model_entries ||= begin
          ids = @provider.respond_to?(:list_models) ? @provider.list_models : []
          Array(ids).filter_map do |id|
            text = id.to_s.strip
            next if text.empty?

            { "name" => text, "model" => text }
          end
        rescue StandardError
          []
        end
      end

      def use_model(model_name)
        model_name = model_name.to_s.strip
        return nil if model_name.empty?

        entry = @config.model_entry_by_name(model_name)
        dynamic = entry.nil? && provider_model_id?(model_name)
        return nil if entry.nil? && !dynamic

        settings = @config.provider_settings(model_name)
        @active_preset = legacy_model_preset(model_name)
        @session_model = settings.model
        @session.model_override = model_name
        @session.model_preset = nil
        @active_preset_name = "default"
        @session.save!
        @provider = routed(settings.with_effort(thinking_level))
        @session_model
      end

      # Switch the reasoning effort ("thinking level") for this session. nil or
      # "" drops the session's own choice, so the persona's default — or the
      # effort its preset carries — takes over again. The provider is rebuilt so
      # the very next request carries the new effort.
      def use_thinking(level)
        text = level.to_s.strip.downcase
        text = nil if text.empty?
        return nil if text && !Persona::THINKING_LEVELS.include?(text)

        before = thinking_level
        @session.thinking_level = text
        @session.save!
        # Only rebuild when the effort actually moves. A rebuild builds a new
        # provider, and with it a new routing identity for the gateway's prompt
        # cache: paying that on a setting that did not change is a full cache
        # miss for a no-op, which is how a form that re-submits the current
        # level wiped the prefix on every turn.
        @provider = build_provider(preset: @active_preset, effort: thinking_level) unless thinking_level == before
        text
      end

      # The reasoning effort this session runs on: its own choice first, then the
      # persona's default, then the effort its preset or the config carries.
      # nil means "send no effort at all", which is what the providers did before
      # the choice existed.
      def thinking_level
        @session.thinking_level || @persona&.thinking ||
          @active_preset&.dig("reasoning_effort") || @config.reasoning_effort
      end

      # The models the provider supports, from its /models catalog. The list is
      # cached (in memory and on disk), so an unreachable provider does not
      # empty the picker. Providers that cannot list models return [].
      def provider_models
        model_catalog.entries
      end

      # The memoized provider catalog.
      def model_catalog
        @model_catalog ||= ModelCatalog.new(config: @config)
      end

      # Returns the active model name (session override or config default)
      def active_model_name
        @session_model || @config.name
      end

      private

      # Resolution order for the preset a session starts with:
      #   1. preset saved on the session (/model <preset>)
      #   2. topic persona preset
      #   3. legacy persona model
      #   4. configured default/primary preset (or the implicit `default`)
      def resolve_initial_preset
        if @session.model_preset
          preset = @config.model_preset(@session.model_preset)
          return preset if preset
        end

        if @session.model_override
          name = @session.model_override.to_s
          if @config.model_entry_by_name(name) || provider_model_id?(name)
            return legacy_model_preset(name)
          end
        end

        if @persona&.preset
          preset = @config.model_preset(@persona.preset)
          return preset if preset
        end

        if @persona&.model
          model_name = persona_model_name
          if model_name
            settings = @config.provider_settings(model_name)
            return {
              "name" => "default",
              "model" => settings.model,
              "provider" => settings.provider,
              "api_key" => settings.api_key,
              "api_base" => settings.api_base,
              "max_tokens" => settings.max_tokens,
              "temperature" => settings.temperature,
              "extra_headers" => settings.extra_headers,
              "implicit" => true
            }
          end
        end

        @config.default_model_preset
      end

      def legacy_model_preset(model_name)
        settings = @config.provider_settings(model_name)
        entry = @config.model_entry_by_name(model_name) || @config.active_model_entry || {}
        {
          "name" => "default",
          "model" => settings.model,
          "provider" => settings.provider,
          "api_key" => settings.api_key,
          "api_base" => settings.api_base,
          "max_tokens" => settings.max_tokens,
          "temperature" => settings.temperature,
          "context_window_tokens" => entry["context_window_tokens"] || entry["contextWindowTokens"],
          "pricing" => entry["pricing"],
          "extra_headers" => settings.extra_headers,
          "implicit" => true
        }
      end

      def apply_initial_preset!
        @active_preset = resolve_initial_preset || @config.default_model_preset
        @active_preset_name = @active_preset["name"]
        @session_model = @active_preset["model"]
        @provider = build_provider(preset: @active_preset, effort: thinking_level)
      end

      def apply_preset_source(source, name: nil, session_name: nil)
        settings = @config.provider_settings_for_preset(source)
        preset_name = (source["name"] || source[:name] || name || "default").to_s

        @active_preset = {
          "name" => preset_name,
          "model" => settings.model,
          "provider" => settings.provider,
          "api_key" => settings.api_key,
          "api_base" => settings.api_base,
          "max_tokens" => settings.max_tokens,
          "temperature" => settings.temperature,
          "extra_headers" => settings.extra_headers,
          "reasoning_effort" => source["reasoning_effort"] || source[:reasoning_effort],
          "context_window_tokens" => source["context_window_tokens"] || source[:context_window_tokens],
          "pricing" => source["pricing"] || source[:pricing],
          "implicit" => source["implicit"] || source[:implicit] || false
        }
        @active_preset_name = preset_name
        @session_model = settings.model
        @session.model_preset = session_name || preset_name
        @session.model_override = nil
        @session.save!
        @provider = routed(settings.with_effort(thinking_level))
        active_model_preset
      end

      def apply_agents_overrides
        ag = @agents_file

        # Override config values if set in AGENTS.md frontmatter
        if ag.name
          @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
          @config.data.dig("agents", "defaults")["name"] = ag.name
        end

        if ag.model
          @config.data["model"] = ag.model
        end

        if ag.max_tokens
          @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
          @config.data.dig("agents", "defaults")["max_tokens"] = ag.max_tokens
        end

        if ag.temperature
          @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
          @config.data.dig("agents", "defaults")["temperature"] = ag.temperature
        end

        if ag.max_rounds
          @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
          @config.data.dig("agents", "defaults")["max_rounds"] = ag.max_rounds
        end

        # Apply tool overrides from AGENTS.md
        return if ag.tools_config.empty?
        tools = @config.data["tools"] || {}
        ag.tools_config.each do |tool_name, enabled|
          tools[tool_name.to_s] = { "enabled" => enabled }
        end
        @config.data["tools"] = tools unless ag.tools_config.empty?
      end

      # Build a provider from an immutable settings snapshot. No config
      # mutation is performed, so this is safe to call from any Ractor.
      def build_provider(model_name = nil, preset: nil, effort: nil)
        settings = if preset
          @config.provider_settings_for_preset(preset)
        else
          @config.provider_settings(model_name)
        end
        settings = settings.with_effort(effort) unless effort.nil?
        routed(settings)
      end

      # Build a provider that belongs to this session.
      #
      # The gateway keys its prompt cache on the routing header the provider
      # sends, and a provider built from config alone had no conversation to
      # stamp it with, so it invented one. Every rebuild therefore looked like a
      # brand-new conversation to the cache, even though the model was answering
      # the same one — the measured cost was a prompt that fell back to the
      # pinned prefix alone (4,480 tokens) in the middle of a session.
      def routed(settings)
        settings = settings.with_session_key(@session.id) if settings.respond_to?(:with_session_key) && @session
        Provider.build(settings)
      end

      # A model from the provider's /models catalog rather than config.yml.
      def provider_model_id?(name)
        id = name.to_s
        return true if ModelCatalog.cached_model_ids(@config.catalog_dir).include?(id)
        return true if provider_model_entries.any? { |entry| entry["name"].to_s == id }

        # The catalog loaded in this process knows its ids without a fetch.
        @model_catalog&.cached_ids.to_a.include?(id)
      end

      # Persona model name. Config entries and provider catalog ids are valid;
      # anything else falls back to the default model.
      def persona_model_name
        name = @persona&.model
        return nil if name.nil? || name.empty?

        if @config.model_entry_by_name(name).nil? && !provider_model_id?(name)
          warn "[persona] model '#{name}' is not in config.yml or the provider catalog — using the default model"
          return nil
        end

        name
      end
    end
  end
end
