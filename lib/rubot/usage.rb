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
  # cache_hit_rate and cost can be computed uniformly. This mirrors Pi's
  # `input + cacheRead + cacheWrite` while keeping a single field.
  class Usage
    # Anthropic charges 1.25x the input rate for a 5-minute cache write and
    # 2x for a 1-hour write. Providers that report the 1-hour subset land in
    # `cache_write_1h_tokens` and are priced at the higher rate.
    CACHE_WRITE_MULTIPLIER = 1.25
    CACHE_WRITE_1H_MULTIPLIER = 2.0

    attr_reader :prompt_tokens, :completion_tokens, :cached_tokens,
                :cache_creation_tokens, :cache_write_1h_tokens,
                :reasoning_tokens, :requests

    def initialize(prompt_tokens: 0, completion_tokens: 0, cached_tokens: 0,
                   cache_creation_tokens: 0, cache_write_1h_tokens: 0,
                   reasoning_tokens: 0, requests: 0)
      @prompt_tokens = prompt_tokens.to_i
      @completion_tokens = completion_tokens.to_i
      @cached_tokens = cached_tokens.to_i
      @cache_creation_tokens = cache_creation_tokens.to_i
      @cache_write_1h_tokens = cache_write_1h_tokens.to_i
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
        # OpenAI-compatible gateways disagree on where cache reads live;
        # DeepSeek reports `prompt_cache_hit_tokens`, others `cached_tokens`.
        cached = number(
          details["cached_tokens"], hash["cached_tokens"], hash["prompt_cache_hit_tokens"]
        )
        cache_creation = number(details["cache_write_tokens"], hash["cache_write_tokens"])
        cache_write_1h = number(details["cache_write_1h_tokens"], hash["cache_write_1h_tokens"])
        reasoning = number(hash["reasoning_tokens"], completion_details["reasoning_tokens"])
      elsif hash.key?("input_tokens") || hash.key?("output_tokens") ||
            hash.key?("cache_read_input_tokens") || hash.key?("cache_creation_input_tokens")
        creation_details = stringify(hash["cache_creation"])
        input = hash["input_tokens"].to_i
        cached = hash["cache_read_input_tokens"].to_i
        cache_creation = hash["cache_creation_input_tokens"].to_i
        cache_write_1h = number(
          creation_details["ephemeral_1h_input_tokens"], hash["cache_write_1h_tokens"]
        )
        prompt = input + cached + cache_creation
        completion = hash["output_tokens"].to_i
        reasoning = 0
      elsif hash.key?("prompt_eval_count") || hash.key?("eval_count")
        prompt = hash["prompt_eval_count"].to_i
        completion = hash["eval_count"].to_i
        cached = 0
        cache_creation = 0
        cache_write_1h = 0
        reasoning = 0
      else
        return nil
      end

      cache_write_1h = [ cache_write_1h, cache_creation ].min

      return nil if prompt.zero? && completion.zero?

      new(
        prompt_tokens: prompt,
        completion_tokens: completion,
        cached_tokens: cached,
        cache_creation_tokens: cache_creation,
        cache_write_1h_tokens: cache_write_1h,
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
        cache_write_1h_tokens: hash["cache_write_1h_tokens"],
        reasoning_tokens: hash["reasoning_tokens"],
        requests: hash["requests"]
      )
    end

    def self.stringify(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) { |(key, val), acc| acc[key.to_s] = val }
    end

    # First present value, coerced to an integer. Providers omit fields they
    # do not support, so a missing key must stay 0 rather than nil.
    def self.number(*values)
      value = values.compact.first
      value.nil? ? 0 : value.to_i
    end

    def merge(other)
      return self if other.nil?

      self.class.new(
        prompt_tokens: prompt_tokens + other.prompt_tokens,
        completion_tokens: completion_tokens + other.completion_tokens,
        cached_tokens: cached_tokens + other.cached_tokens,
        cache_creation_tokens: cache_creation_tokens + other.cache_creation_tokens,
        cache_write_1h_tokens: cache_write_1h_tokens + other.cache_write_1h_tokens,
        reasoning_tokens: reasoning_tokens + other.reasoning_tokens,
        requests: requests + other.requests
      )
    end
    alias + merge

    def total_tokens
      prompt_tokens + completion_tokens
    end

    # Share of input tokens served from the provider's prompt cache (0.0..1.0).
    #
    # Like Pi, the number that matters is computed from the *latest* request
    # (Session#last_usage), not from the session totals: a cumulative figure
    # dilutes a cache regression behind the tokens of earlier turns.
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
        "cache_write_1h_tokens" => cache_write_1h_tokens,
        "reasoning_tokens" => reasoning_tokens,
        "requests" => requests
      }
    end

    # Cost in USD for this usage under the given rates (USD per 1M tokens).
    # Returns nil when no rates are available.
    def self.cost(usage, rates)
      return nil unless rates.is_a?(Hash) && !rates.empty?

      rates = effective_rates(rates, usage.prompt_tokens)
      input_rate = rates["input"].to_f
      output_rate = rates["output"].to_f
      cached_rate = (rates["cached_input"] || input_rate).to_f
      cache_creation_rate = (rates["cache_creation_input"] || input_rate * CACHE_WRITE_MULTIPLIER).to_f

      uncached = [ usage.prompt_tokens - usage.cached_tokens - usage.cache_creation_tokens, 0 ].max
      long_write = [ usage.cache_write_1h_tokens, usage.cache_creation_tokens ].min
      short_write = usage.cache_creation_tokens - long_write
      cache_creation_cost =
        (short_write * cache_creation_rate + long_write * input_rate * CACHE_WRITE_1H_MULTIPLIER) /
        1_000_000.0

      breakdown = {
        "input" => uncached / 1_000_000.0 * input_rate,
        "cached_input" => usage.cached_tokens / 1_000_000.0 * cached_rate,
        "cache_creation" => cache_creation_cost,
        "output" => usage.completion_tokens / 1_000_000.0 * output_rate
      }
      total = breakdown.values.sum
      # Not part of the total: this is the money the cache kept from being
      # spent, which is what makes a hit rate mean something in $.
      breakdown["saved"] = cached_savings(usage, rates)
      breakdown["total"] = total
      breakdown["cache_price_unknown"] = true if rates["cached_input_unknown"]
      breakdown
    end

    # What reading `cached_tokens` from the cache saved over paying the input
    # rate for them. nil when there are no rates to compare.
    def self.cached_savings(usage, rates)
      return nil unless rates.is_a?(Hash) && !rates.empty?

      rates = effective_rates(rates, usage.prompt_tokens)
      input_rate = rates["input"].to_f
      cached_rate = (rates["cached_input"] || input_rate).to_f
      [ input_rate - cached_rate, 0 ].max * usage.cached_tokens / 1_000_000.0
    end

    # Pi selects a pricing tier from the request's full input size (cached
    # tokens included). Tiers with a `input_tokens_above` at or below the
    # prompt are candidates; the highest one wins.
    def self.effective_rates(rates, input_tokens)
      tiers = rates["tiers"]
      return rates unless tiers.is_a?(Array) && !tiers.empty?

      best = nil
      matched = -1
      tiers.each do |tier|
        next unless tier.is_a?(Hash)

        tier = tier.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
        threshold = (tier["input_tokens_above"] || tier["inputTokensAbove"] || 0).to_i
        next unless input_tokens > threshold && threshold > matched

        best = tier
        matched = threshold
      end
      return rates if best.nil?

      rates.reject { |key, _| key.to_s == "tiers" }.merge(best)
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
      lines << "   Cache:    #{tokens(report[:cached_tokens])} cached total#{hit_rate(report)}"
      lines << "   Re-read:  #{tokens(report[:last_re_read_tokens])} token dibayar penuh (turn terakhir)"

      cost = report[:cost]
      if cost
        source = report[:price_source] ? " [#{report[:price_source]}]" : ""
        bound = cost["cache_price_unknown"] ? " (batas atas)" : ""
        lines << "   Cost:     $#{money(cost['total'])}#{bound} " \
                 "(in $#{money(cost['input'])}, cache read $#{money(cost['cached_input'])}, " \
                 "cache write $#{money(cost['cache_creation'])}, out $#{money(cost['output'])})#{source}"
        if cost["saved"].to_f.positive?
          lines << "   Hemat:    $#{money(cost['saved'])} dari #{tokens(report[:cached_tokens])} token cache"
        end
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

      format(" (hit rate %.1f%% on the latest request)", report[:cache_hit_rate].to_f * 100)
    end

    # One-line metrics for the TUI footer, e.g.
    #
    #   $0.001 · cache 60% · ctx 8.2%
    #
    # Always renders all three parts. A launch has nothing spent yet, and a
    # blank status row reads as a missing feature rather than as a zero, so a
    # fresh session shows `$0.000 · cache — · ctx 2.4%` instead.
    def footer(report)
      [ price(report), cache(report), context(report) ].join(" · ")
    end

    # The same three figures without their words, for a channel that draws a
    # glyph and keeps the label in a tooltip. `nil` means there is nothing
    # honest to show yet — a caller must not print a zero in its place.
    def metrics(report)
      {
        cost: cost_value(report),
        cache: cache_value(report),
        context: context_value(report)
      }
    end

    def price(report)
      value = cost_value(report)
      value ? value : "cost n/a"
    end

    def cost_value(report)
      cost = report[:cost]
      return nil unless cost

      # A provisional figure is part estimate: the request it prices has not
      # come back yet. Marking it keeps the moving number honest instead of
      # passing an estimate off as a measurement.
      value = format("$%s", decimals(cost["total"].to_f))
      report[:provisional] ? "~#{value}" : value
    end

    # Precision follows the size of the number: three decimals would sit at
    # $0.000 for a whole cheap turn and never appear to move, which is exactly
    # the opposite of what a live figure is for.
    def decimals(total)
      return format("%.4f", total) if total.positive? && total < 0.01

      format("%.3f", total)
    end

    def cache(report)
      # No request yet: a hit rate would be a claim about nothing.
      return "cache —" if report[:requests].to_i.zero?

      pct = cache_value(report)
      pct ? "cache #{pct}" : "cache n/a"
    end

    def cache_value(report)
      return nil if report[:requests].to_i.zero?
      return nil if report[:prompt_tokens].to_i.zero?

      pct = format("%.1f", report[:cache_hit_rate].to_f * 100).sub(/\.0\z/, "")
      "#{pct}%"
    end

    # Share of the window in use. Falls back to the raw token count when the
    # window is unknown; the footer stays short so it never elbows the
    # session block on an 80-column terminal.
    def context(report)
      "ctx #{context_value(report)}"
    end

    def context_value(report)
      if report[:context_percent] && report[:context_window].to_i.positive?
        format("%.1f%%", report[:context_percent])
      else
        compact_tokens(report[:context_used])
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
