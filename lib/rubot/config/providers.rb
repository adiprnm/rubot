# frozen_string_literal: true

module Rubot
  class Config
    # Which provider answers, and the settings one request needs: the endpoint,
    # the key, the output budget, and the smaller model a side task may use.
    #
    # The precedence runs one way only — the active model entry, then the
    # provider it names, then the global defaults — and #provider_settings is
    # where that order is written down.
    #
    # Moved as it was, comments included. The key never leaves this object except
    # into a request header.
    module Providers
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

      # The model for delegated sub agents. A bare model name (a config.yml
      # entry or a provider catalog id), never a preset: the sub agent builder
      # writes it straight into the persona's `model` field so the conversation
      # uses that model instead of the built-in `flash` preset. Unset means the
      # sub agents keep their preset, which is the behaviour before this setting.
      def subagent_model
        raw = data["subagent_model"] || agent_defaults["subagent_model"] || agent_defaults["subagentModel"]
        text = raw.to_s.strip
        text.empty? ? nil : text
      end

      # Per-sub-agent overrides, keyed by slug. Each value is a Hash with
      # "model" and/or "thinking". A missing key means the sub agent keeps the
      # model and thinking from its built-in definition.
      def subagent_settings(slug)
        raw = data["subagents"]
        return {} unless raw.is_a?(Hash)

        entry = raw[slug.to_s] || raw[slug.to_sym]
        entry.is_a?(Hash) ? entry.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v } : {}
      end

      def set_subagent_settings(slug, attributes)
        raw = data["subagents"].is_a?(Hash) ? data["subagents"] : {}
        key = raw.keys.find { |candidate| candidate.to_s.casecmp?(slug.to_s) } || slug.to_s
        entry = raw[key].is_a?(Hash) ? raw[key] : {}
        attributes.each do |name, value|
          text = value.to_s.strip
          text.empty? ? entry.delete(name.to_s) : entry[name.to_s] = text
        end
        if entry.empty?
          raw.delete(key)
        else
          raw[key] = entry
        end
        data["subagents"] = raw
        subagent_settings(slug)
      end
    end
  end
end
