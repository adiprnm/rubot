# frozen_string_literal: true

module Rubot
  class Config
    # Named bundles of model settings: what a preset is called, which one a
    # session starts with, and how one is written back.
    #
    # A preset is what `/preset` and the settings page edit, and the precedence
    # between it, the session's own choice and the config default is the part
    # that decides which model actually answers. It lives here rather than in
    # config.rb so the fallbacks can be read in one place.
    #
    # Moved as it was, comments included: normalize_model_preset is what keeps a
    # hand-edited YAML usable, and its accepted keys are a contract.
    module ModelPresets
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

      private

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
    end
  end
end
