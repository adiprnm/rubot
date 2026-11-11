# frozen_string_literal: true

require "time"

module Rubot
  # Why did the last request miss the cache?
  #
  # The records say what happened; this says what it means. Everything here is
  # derived from two records and nothing is guessed at beyond that: the model,
  # the prompt digest, the tool digest, the size of the window, the block the
  # fingerprint broke on, and how long ago the request before it was made. A
  # label that cannot be established from those is `unknown`, not a guess —
  # a wrong cause is worse than none, because it sends the fix to the wrong
  # place.
  #
  # The order of the checks is the order in which a cause invalidates what
  # follows it: a different model discards everything, a different system
  # prompt discards the system and the messages, a different tool catalog
  # discards the messages, and only then does the history itself get a say.
  module CacheDiagnosis
    # The minimum cacheable prefix, per the provider docs. Anthropic varies by
    # model (512 to 4096); OpenAI is 1024 everywhere. A wrong number here only
    # mislabels a miss — it never changes what is sent.
    MIN_PROMPT_TOKENS = {
      %r{claude-(fable|mythos|opus-5|sonnet-5-5|haiku-5-5)} => 512,
      /claude-opus-4-7/ => 2_048,
      %r{claude-(opus-4-6|opus-4-5|haiku-4-5)} => 4_096
    }.freeze
    DEFAULT_MIN_PROMPT_TOKENS = 1_024

    # The 5-minute lifetime both providers use by default. A gap longer than
    # this between two requests with the same prefix is the one case where a
    # miss is nobody's fault and nothing needs fixing.
    DEFAULT_TTL_SECONDS = 300

    # How many requests in a row may read nothing from an unchanged prefix
    # before it stops looking like bad luck. One is a lost entry or a gateway
    # that routed the request to a replica without the cache; three is a
    # pattern, and a pattern is worth saying out loud while the session is
    # still open instead of a week later in a report.
    STREAK_ALERT = 3

    module_function

    # The cause of the latest request's result, as a Symbol, or nil when there
    # is nothing to explain.
    #
    # `records` is the session's record list, oldest first (the shape
    # Session#cache_records returns). The comparison is against the previous
    # record *of the same kind*: a cron run and a conversation turn do not share
    # a prefix, so measuring one against the other would invent a divergence.
    def cause(records)
      records = Array(records)
      latest = records.last
      return nil if latest.nil?

      return nil if latest["cached_tokens"].to_i.positive?

      previous = records[0..-2].reverse.find do |record|
        record["auxiliary"] == latest["auxiliary"]
      end
      return :cold if previous.nil?

      divergent(latest, previous) || intact(latest, previous)
    end

    # A one-line reading of the cause, for a footer or a command output.
    def describe(cause)
      case cause
      when :hit then "hit"
      when :cold then "request pertama di sesi ini"
      when :model_switch then "model berganti"
      when :compaction then "compaction membuat ringkasan baru"
      when :prompt_epoch then "system prompt berubah (memory/skill/persona/repin)"
      when :tools_change then "katalog tool berubah"
      when :trim_boundary then "jendela history bergeser (trim)"
      when :tool_result_shrink then "hasil tool lama dipotong"
      when :reasoning_tail then "reasoning turn lama dibuang"
      when :history_rewrite then "satu pesan lama ditulis ulang"
      when :below_min_length then "prefix di bawah minimum cache provider"
      when :ttl_expiry then "cache kedaluwarsa (jeda > 5 menit)"
      when :effort_change then "level thinking berubah (dugaan)"
      when :uncached then "prefix utuh tapi provider tidak melaporkan cache read"
      when :unknown then "tidak bisa dipastikan dari record"
      end
    end

    # The causes that invalidate part of the prefix, in invalidation order.
    # Returns nil when nothing about the request's identity moved.
    def divergent(latest, previous)
      return :model_switch if latest["model"].to_s != previous["model"].to_s
      # A summary being created rewrites the prompt because the transcript grew
      # past the budget, not because anyone edited it — the same digest moves in
      # both cases, so the summary is compared first.
      return :compaction if latest["summary"].to_s != previous["summary"].to_s
      return :prompt_epoch if latest["epoch"].to_s != previous["epoch"].to_s
      return :tools_change if latest["tools"].to_s != previous["tools"].to_s

      # The window moved: the front of the transcript is not the front it was,
      # so everything behind it has a new position. Block-aligned trimming makes
      # this rare, not impossible.
      return :trim_boundary if latest["turns"].to_i < previous["turns"].to_i

      # No fingerprint to compare (the previous record predates the probe, or
      # this is the first request after a restart that lost it): the digests
      # above said nothing moved, and there is no index to point at.
      diverged_at = latest["diverged_at"]
      return nil if diverged_at.nil? || diverged_at.to_i.negative?

      case latest["diverged_kind"].to_s
      when "s" then :prompt_epoch
      when "t" then :tools_change
      else divergent_message(latest)
      end
    end

    # A message block changed while the window stayed the same size: the
    # rewrite was in place, so the role of the block says which rewrite it was.
    def divergent_message(latest)
      case latest["diverged_role"].to_s
      when "tool" then :tool_result_shrink
      when "assistant" then :reasoning_tail
      when "" then :unknown
      else :history_rewrite
      end
    end

    # The prefix was intact and the request still got nothing back: either the
    # prompt was too short to cache, or the entry had expired, or the provider
    # simply did not report a read.
    def intact(latest, previous)
      return :below_min_length if latest["prompt_tokens"].to_i < min_prompt_tokens(latest["model"])

      gap = seconds_between(previous["at"], latest["at"])
      return :ttl_expiry if gap && gap > DEFAULT_TTL_SECONDS

      # A suspect, not a cause: no provider keys the prompt cache on the
      # thinking level, but a gateway that does would look exactly like this —
      # same prefix, same minute, nothing read. The label says "dugaan" so a
      # reader knows which of the two they are looking at.
      return :effort_change if latest["effort"].to_s != previous["effort"].to_s

      :uncached
    end

    # How many requests in a row read nothing from a prefix nobody changed.
    #
    # Only zero reads on an *unchanged* prefix count: same model, same epoch,
    # same tool catalog, and no divergence index (the probe compared the two
    # payloads and found them identical). A miss caused by trimming or a
    # rewrite is a different story — it is explained, and explained misses do
    # not repeat on their own.
    def miss_streak(records)
      records = Array(records)
      latest = records.last
      return 0 if latest.nil?

      streak = 0
      records.reverse_each do |record|
        break unless record["cached_tokens"].to_i.zero?
        break unless same_prefix?(record, latest)

        streak += 1
      end
      streak
    end

    def same_prefix?(record, latest)
      return false unless record["model"].to_s == latest["model"].to_s
      return false unless record["epoch"].to_s == latest["epoch"].to_s
      return false unless record["tools"].to_s == latest["tools"].to_s

      diverged_at = record["diverged_at"]
      diverged_at.nil? || diverged_at.to_i.negative?
    end

    def min_prompt_tokens(model)
      key = model.to_s.downcase.tr(".", "-")
      MIN_PROMPT_TOKENS.each do |pattern, tokens|
        return tokens if key.match?(pattern)
      end
      DEFAULT_MIN_PROMPT_TOKENS
    end

    def seconds_between(earlier, later)
      return nil if earlier.to_s.empty? || later.to_s.empty?

      Time.iso8601(later.to_s) - Time.iso8601(earlier.to_s)
    rescue ArgumentError
      nil
    end
  end
end
