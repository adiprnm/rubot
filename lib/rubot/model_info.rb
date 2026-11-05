# frozen_string_literal: true

module Rubot
  # Static metadata for well-known models: context window sizes and
  # indicative token prices (USD per 1M tokens).
  #
  # Prices change often. Treat this table as a convenience default only:
  # anything set under `pricing:` in a model preset or model entry in
  # config.yml takes precedence. Local models (Ollama) are free.
  module ModelInfo
    # Keyed by a fragment of the model id. The longest matching key wins, so
    # "gpt-4o-mini" is matched before "gpt-4o".
    PRICES = {
      "gpt-4o-mini"             => { "input" => 0.15,  "cached_input" => 0.075, "output" => 0.60 },
      "gpt-4o"                  => { "input" => 2.50,  "cached_input" => 1.25,  "output" => 10.00 },
      "gpt-4.1-mini"            => { "input" => 0.40,  "cached_input" => 0.10,  "output" => 1.60 },
      "gpt-4.1-nano"            => { "input" => 0.10,  "cached_input" => 0.025, "output" => 0.40 },
      "gpt-4.1"                 => { "input" => 2.00,  "cached_input" => 0.50,  "output" => 8.00 },
      "o4-mini"                 => { "input" => 1.10,  "cached_input" => 0.275, "output" => 4.40 },
      "o3-mini"                 => { "input" => 1.10,  "cached_input" => 0.55,  "output" => 4.40 },
      "o3"                      => { "input" => 2.00,  "cached_input" => 0.50,  "output" => 8.00 },
      "claude-3-5-haiku"        => { "input" => 0.80,  "cached_input" => 0.08,  "output" => 4.00 },
      "claude-3-5-sonnet"       => { "input" => 3.00,  "cached_input" => 0.30,  "output" => 15.00 },
      "claude-3-opus"           => { "input" => 15.00, "cached_input" => 1.50,  "output" => 75.00 },
      "claude-sonnet-4"         => { "input" => 3.00,  "cached_input" => 0.30,  "output" => 15.00 },
      "claude-opus-4"           => { "input" => 15.00, "cached_input" => 1.50,  "output" => 75.00 },
      "claude-haiku-4"          => { "input" => 1.00,  "cached_input" => 0.10,  "output" => 5.00 },
      "deepseek-reasoner"       => { "input" => 0.55,  "cached_input" => 0.14,  "output" => 2.19 },
      "deepseek-chat"           => { "input" => 0.27,  "cached_input" => 0.07,  "output" => 1.10 },
      "gemini-2.5-flash"        => { "input" => 0.30,  "cached_input" => 0.075, "output" => 2.50 },
      "gemini-2.0-flash"        => { "input" => 0.10,  "cached_input" => 0.025, "output" => 0.40 },
      "gemini-1.5-flash"        => { "input" => 0.075, "cached_input" => 0.018, "output" => 0.30 }
    }.transform_values(&:freeze).freeze

    CONTEXT_WINDOWS = {
      "gpt-4o-mini"      => 128_000,
      "gpt-4o"           => 128_000,
      "gpt-4.1"          => 1_047_576,
      "o4-mini"          => 200_000,
      "o3"               => 200_000,
      "claude"           => 200_000,
      "deepseek"         => 128_000,
      "gemini-2.5-flash" => 1_048_576,
      "gemini-2.0-flash" => 1_048_576,
      "gemini-1.5-flash" => 1_048_576,
      "llama3"           => 8_192,
      "llama"            => 8_192
    }.freeze

    class << self
      # "openai/gpt-4o-mini" -> "gpt-4o-mini"
      def normalize(model)
        model.to_s.downcase.strip.sub(%r{\A[a-z0-9_.-]+/}, "")
      end

      def lookup(table, model)
        id = normalize(model)
        return nil if id.empty?
        return table[id] if table[id]

        key = table.keys.sort_by { |candidate| -candidate.length }.find { |candidate| id.include?(candidate) }
        key ? table[key] : nil
      end

      # Returns {"input" =>, "output" =>, "cached_input" =>,
      # "cache_creation_input" =>} in USD per 1M tokens, or nil when unknown.
      def rates(model, provider: nil, override: nil)
        normalized = normalize_rates(override)
        return normalized if normalized

        return { "input" => 0.0, "output" => 0.0, "cached_input" => 0.0, "cache_creation_input" => 0.0 } if provider.to_s == "ollama"

        lookup(PRICES, model)&.transform_values(&:to_f)
      end

      def context_window(model, override: nil)
        value = override.to_i
        return value if value.positive?

        lookup(CONTEXT_WINDOWS, model)
      end

      # Accepts both the canonical keys and common aliases:
      #   input / input_per_mtok / prompt
      #   output / output_per_mtok / completion
      #   cached_input / cached_input_per_mtok / cached
      def normalize_rates(raw)
        return nil unless raw.is_a?(Hash)

        hash = raw.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
        aliases = {
          "input" => %w[input input_per_mtok prompt prompt_per_mtok],
          "output" => %w[output output_per_mtok completion completion_per_mtok],
          "cached_input" => %w[cached_input cached_input_per_mtok cached cached_per_mtok],
          "cache_creation_input" => %w[cache_creation_input cache_creation_input_per_mtok cache_creation cache_creation_per_mtok]
        }

        result = {}
        aliases.each do |canonical, names|
          value = names.filter_map { |name| hash[name] }.first
          result[canonical] = value.to_f if value
        end
        result.empty? ? nil : result
      end
    end
  end
end
