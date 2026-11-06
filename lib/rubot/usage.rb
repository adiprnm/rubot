# frozen_string_literal: true

module Rubot
  # Normalized token accounting for a session.
  #
  # Every provider reports usage differently:
  #   OpenAI     prompt_tokens / completion_tokens (+ prompt_tokens_details.cached_tokens)
  #   Anthropic  input_tokens / output_tokens / cache_read_input_tokens / cache_creation_input_tokens
  #   Ollama     prompt_eval_count / eval_count
  #
  # `prompt_tokens` here always means the *full* input side, cache included, so
  # cache_hit_rate and cost can be computed uniformly.
  class Usage
    attr_reader :prompt_tokens, :completion_tokens, :cached_tokens,
                :cache_creation_tokens, :reasoning_tokens, :requests

    def initialize(prompt_tokens: 0, completion_tokens: 0, cached_tokens: 0,
                   cache_creation_tokens: 0, reasoning_tokens: 0, requests: 0)
      @prompt_tokens = prompt_tokens.to_i
      @completion_tokens = completion_tokens.to_i
      @cached_tokens = cached_tokens.to_i
      @cache_creation_tokens = cache_creation_tokens.to_i
      @reasoning_tokens = reasoning_tokens.to_i
      @requests = requests.to_i
    end

    def self.zero
      new
    end

    # Build a Usage from a provider usage hash. Returns nil when the hash has
    # no recognizable token counts.
    def self.from(raw, provider: nil)
      return nil unless raw.is_a?(Hash)

      hash = raw.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }

      if hash.key?("prompt_tokens") || hash.key?("completion_tokens")
        details = stringify(hash["prompt_tokens_details"])
        completion_details = stringify(hash["completion_tokens_details"])
        prompt = hash["prompt_tokens"].to_i
        completion = hash["completion_tokens"].to_i
        cached = (hash["cached_tokens"] || details["cached_tokens"]).to_i
        reasoning = (hash["reasoning_tokens"] || completion_details["reasoning_tokens"]).to_i
        cache_creation = 0
      elsif hash.key?("input_tokens") || hash.key?("output_tokens") ||
            hash.key?("cache_read_input_tokens") || hash.key?("cache_creation_input_tokens")
        input = hash["input_tokens"].to_i
        cached = hash["cache_read_input_tokens"].to_i
        cache_creation = hash["cache_creation_input_tokens"].to_i
        prompt = input + cached + cache_creation
        completion = hash["output_tokens"].to_i
        reasoning = 0
      elsif hash.key?("prompt_eval_count") || hash.key?("eval_count")
        prompt = hash["prompt_eval_count"].to_i
        completion = hash["eval_count"].to_i
        cached = 0
        cache_creation = 0
        reasoning = 0
      else
        return nil
      end

      return nil if prompt.zero? && completion.zero?

      new(
        prompt_tokens: prompt,
        completion_tokens: completion,
        cached_tokens: cached,
        cache_creation_tokens: cache_creation,
        reasoning_tokens: reasoning,
        requests: 1
      )
    end

    def self.from_h(raw)
      return zero unless raw.is_a?(Hash)

      hash = raw.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
      new(
        prompt_tokens: hash["prompt_tokens"],
        completion_tokens: hash["completion_tokens"],
        cached_tokens: hash["cached_tokens"],
        cache_creation_tokens: hash["cache_creation_tokens"],
        reasoning_tokens: hash["reasoning_tokens"],
        requests: hash["requests"]
      )
    end

    def self.stringify(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, val), acc| acc[key.to_s] = val }
    end

    def merge(other)
      return self if other.nil?

      self.class.new(
        prompt_tokens: prompt_tokens + other.prompt_tokens,
        completion_tokens: completion_tokens + other.completion_tokens,
        cached_tokens: cached_tokens + other.cached_tokens,
        cache_creation_tokens: cache_creation_tokens + other.cache_creation_tokens,
        reasoning_tokens: reasoning_tokens + other.reasoning_tokens,
        requests: requests + other.requests
      )
    end
    alias + merge

    def total_tokens
      prompt_tokens + completion_tokens
    end

    # Share of input tokens served from the provider's prompt cache (0.0..1.0).
    def cache_hit_rate
      return 0.0 if prompt_tokens.zero?

      cached_tokens.to_f / prompt_tokens
    end

    def to_h
      {
        "prompt_tokens" => prompt_tokens,
        "completion_tokens" => completion_tokens,
        "cached_tokens" => cached_tokens,
        "cache_creation_tokens" => cache_creation_tokens,
        "reasoning_tokens" => reasoning_tokens,
        "requests" => requests
      }
    end

    # Cost in USD for this usage under the given rates (USD per 1M tokens).
    # Returns nil when no rates are available.
    def self.cost(usage, rates)
      return nil unless rates.is_a?(Hash) && !rates.empty?

      input_rate = rates["input"].to_f
      output_rate = rates["output"].to_f
      cached_rate = (rates["cached_input"] || input_rate).to_f
      cache_creation_rate = (rates["cache_creation_input"] || input_rate * 1.25).to_f

      uncached = [ usage.prompt_tokens - usage.cached_tokens - usage.cache_creation_tokens, 0 ].max

      breakdown = {
        "input" => uncached / 1_000_000.0 * input_rate,
        "cached_input" => usage.cached_tokens / 1_000_000.0 * cached_rate,
        "cache_creation" => usage.cache_creation_tokens / 1_000_000.0 * cache_creation_rate,
        "output" => usage.completion_tokens / 1_000_000.0 * output_rate
      }
      breakdown["total"] = breakdown.values.sum
      breakdown
    end
  end

  # Shared plain-text renderer for the /context command.
  module UsageReport
    module_function

    def render(report)
      lines = []
      lines << "📊 Usage — #{report[:model]} (#{report[:provider]})"
      lines << "   Context:  #{tokens(report[:context_used])} / #{window(report)} tokens#{context_pct(report)}"
      lines << "   Messages: #{report[:messages]} | Requests: #{report[:requests]}"
      lines << "   Tokens:   #{tokens(report[:prompt_tokens])} in / #{tokens(report[:completion_tokens])} out"
      lines << "   Cache:    #{tokens(report[:cached_tokens])} cached#{hit_rate(report)}"

      cost = report[:cost]
      if cost
        source = report[:price_source] ? " [#{report[:price_source]}]" : ""
        lines << "   Cost:     $#{money(cost['total'])} " \
                 "(in $#{money(cost['input'])}, cached $#{money(cost['cached_input'])}, " \
                 "out $#{money(cost['output'])})#{source}"
      else
        lines << "   Cost:     unknown — set `pricing` on the model preset in config.yml"
      end

      lines.join("\n")
    end

    def tokens(value)
      value.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    def window(report)
      report[:context_window] ? tokens(report[:context_window]) : "?"
    end

    def context_pct(report)
      pct = report[:context_percent]
      pct ? format(" (%.1f%%)", pct) : ""
    end

    def hit_rate(report)
      return " (hit rate n/a)" if report[:prompt_tokens].to_i.zero?

      format(" (hit rate %.1f%%)", report[:cache_hit_rate].to_f * 100)
    end

    # One-line metrics for the TUI footer, e.g.
    #
    #   $0.001 · cache 60% · ctx 8.2%
    #
    # Returns "" while the session has no accounted request, so the footer
    # stays out of the way before the first turn.
    def footer(report)
      return "" if report[:requests].to_i.zero?

      [ price(report), cache(report), context(report) ].join(" · ")
    end

    def price(report)
      cost = report[:cost]
      cost ? format("$%.3f", cost["total"].to_f) : "cost n/a"
    end

    def cache(report)
      return "cache n/a" if report[:prompt_tokens].to_i.zero?

      pct = format("%.1f", report[:cache_hit_rate].to_f * 100).sub(/\.0\z/, "")
      "cache #{pct}%"
    end

    # Share of the window in use. Falls back to the raw token count when the
    # window is unknown; the footer stays short so it never elbows the
    # session block on an 80-column terminal.
    def context(report)
      if report[:context_percent] && report[:context_window].to_i.positive?
        format("ctx %.1f%%", report[:context_percent])
      else
        "ctx #{compact_tokens(report[:context_used])}"
      end
    end

    # 1_500 -> "1.5k", 128_000 -> "128k", 2_000_000 -> "2M".
    def compact_tokens(value)
      n = value.to_i
      return n.to_s if n < 1_000

      if n < 1_000_000
        format("%.1fk", n / 1_000.0).sub(/\.0k\z/, "k")
      else
        format("%.1fM", n / 1_000_000.0).sub(/\.0M\z/, "M")
      end
    end

    def money(value)
      format("%.6f", value.to_f).sub(/0+\z/, "").sub(/\.\z/, "")
    end
  end
end
