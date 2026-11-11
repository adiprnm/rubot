# frozen_string_literal: true

require_relative "test_helper"

class TestCacheDiagnosis < Minitest::Test
  def record(overrides = {})
    {
      "at" => "2026-11-11T04:00:00Z",
      "provider" => "anthropic",
      "model" => "claude-sonnet-5",
      "prompt_tokens" => 10_000,
      "cached_tokens" => 0,
      "cache_creation_tokens" => 0,
      "epoch" => "epoch-1",
      "tools" => "tools-1",
      "blocks" => 20,
      "turns" => 10,
      "auxiliary" => false,
      "fingerprint" => "saaa,tbbb",
      "diverged_at" => -1,
      "diverged_kind" => nil,
      "diverged_role" => nil
    }.merge(overrides)
  end

  def cause(*records)
    Rubot::CacheDiagnosis.cause(records)
  end

  def test_a_hit_has_nothing_to_explain
    assert_nil cause(record("cached_tokens" => 9_000))
  end

  def test_the_first_request_of_a_session_is_cold
    assert_equal :cold, cause(record)
  end

  def test_a_changed_model_invalidates_everything
    previous = record("cached_tokens" => 9_000)

    assert_equal :model_switch, cause(previous, record("model" => "claude-opus-5"))
  end

  def test_a_changed_prompt_is_reported_as_the_prompt
    previous = record("cached_tokens" => 9_000, "diverged_at" => nil)

    assert_equal :prompt_epoch, cause(previous, record("epoch" => "epoch-2", "diverged_at" => 0))
  end

  # A summary is written because the transcript outgrew the budget, not because
  # anyone edited the prompt — the same digest moves in both cases, so the
  # summary has to be compared before the prompt.
  def test_a_new_summary_is_a_compaction_not_a_prompt_edit
    previous = record("cached_tokens" => 9_000, "summary" => "sum-1", "diverged_at" => nil)
    latest = record("summary" => "sum-2", "epoch" => "epoch-2", "diverged_at" => 0)

    assert_equal :compaction, cause(previous, latest)
  end

  # No provider keys the cache on the thinking level, so this is the one label
  # that admits it is a guess.
  def test_a_changed_thinking_level_is_a_suspect_when_nothing_else_moved
    previous = record("cached_tokens" => 9_000, "effort" => "low", "diverged_at" => nil)
    latest = record("effort" => "high")

    assert_equal :effort_change, cause(previous, latest)
  end

  def test_a_changed_thinking_level_does_not_hide_a_prompt_change
    previous = record("cached_tokens" => 9_000, "effort" => "low", "diverged_at" => nil)
    latest = record("effort" => "high", "epoch" => "epoch-2", "diverged_at" => 0)

    assert_equal :prompt_epoch, cause(previous, latest)
  end

  def test_a_changed_tool_catalog_is_reported_as_the_tools
    previous = record("cached_tokens" => 9_000, "diverged_at" => nil)

    assert_equal :tools_change,
                 cause(previous, record("tools" => "tools-2", "diverged_at" => 1))
  end

  def test_a_shrinking_window_is_a_trim
    previous = record("cached_tokens" => 9_000, "turns" => 40, "diverged_at" => nil)

    assert_equal :trim_boundary,
                 cause(previous, record("turns" => 30, "diverged_at" => 2, "diverged_kind" => "m"))
  end

  def test_a_shortened_tool_result_is_named_as_one
    previous = record("cached_tokens" => 9_000, "diverged_at" => nil)

    assert_equal :tool_result_shrink,
                 cause(previous, record("turns" => 11, "diverged_at" => 5,
                                        "diverged_kind" => "m", "diverged_role" => "tool"))
  end

  def test_a_dropped_reasoning_block_is_named_as_one
    previous = record("cached_tokens" => 9_000, "diverged_at" => nil)

    assert_equal :reasoning_tail,
                 cause(previous, record("turns" => 11, "diverged_at" => 6,
                                        "diverged_kind" => "m", "diverged_role" => "assistant"))
  end

  def test_a_rewritten_user_message_is_a_history_rewrite
    previous = record("cached_tokens" => 9_000, "diverged_at" => nil)

    assert_equal :history_rewrite,
                 cause(previous, record("turns" => 11, "diverged_at" => 4,
                                        "diverged_kind" => "m", "diverged_role" => "user"))
  end

  def test_an_intact_prefix_under_the_minimum_is_below_min_length
    previous = record("cached_tokens" => 0, "prompt_tokens" => 600)

    assert_equal :below_min_length, cause(previous, record("prompt_tokens" => 700))
  end

  def test_an_intact_prefix_after_a_long_pause_expired
    previous = record("cached_tokens" => 9_000, "at" => "2026-11-11T04:00:00Z")

    assert_equal :ttl_expiry, cause(previous, record("at" => "2026-11-11T04:09:00Z"))
  end

  def test_an_intact_prefix_with_no_explanation_is_left_unexplained
    previous = record("cached_tokens" => 9_000, "at" => "2026-11-11T04:00:00Z")

    assert_equal :uncached, cause(previous, record("at" => "2026-11-11T04:00:30Z")),
                 "an intact prefix, above the minimum, one minute later: the provider's routing, not ours"
  end

  # A cron run and a conversation turn do not share a prefix. Measuring one
  # against the other would label every cron run as a broken prompt.
  def test_a_comparison_stays_within_the_same_kind_of_request
    conversation = record("cached_tokens" => 9_000, "diverged_at" => nil)
    cron = record("auxiliary" => true, "prompt_tokens" => 400, "diverged_at" => nil)

    assert_equal :below_min_length, cause(conversation, cron, cron),
                 "the previous auxiliary record is the comparison, not the turn before it"
  end

  def test_a_record_without_any_predecessor_is_cold_even_when_auxiliary
    assert_equal :cold, cause(record("auxiliary" => true))
  end

  def test_the_minimum_follows_the_model_family
    assert_equal 4_096, Rubot::CacheDiagnosis.min_prompt_tokens("claude-opus-4-6")
    assert_equal 2_048, Rubot::CacheDiagnosis.min_prompt_tokens("claude-opus-4-7")
    assert_equal 512, Rubot::CacheDiagnosis.min_prompt_tokens("claude-sonnet-5.5")
    assert_equal 1_024, Rubot::CacheDiagnosis.min_prompt_tokens("openai/gpt-5.1")
    assert_equal 1_024, Rubot::CacheDiagnosis.min_prompt_tokens(nil)
  end

  # The cause is only ever read in the log now (a reader looking at a
  # conversation does not need "cache kedaluwarsa (>5 menit)" in the status
  # row), but the wording still has to name the cause instead of printing the
  # symbol.
  def test_every_cause_has_a_label_a_log_reader_can_read
    causes = %i[cold model_switch prompt_epoch tools_change trim_boundary tool_result_shrink
                reasoning_tail history_rewrite below_min_length ttl_expiry uncached unknown]

    causes.each do |label|
      rendered = Rubot::CacheDiagnosis.describe(label)

      refute_nil rendered, "#{label} would print nothing"
      refute_includes rendered, label.to_s, "#{label} would print its own symbol"
    end
  end

  # A prefix nobody touched that still reads nothing, three requests running:
  # that is the one miss no rule on our side explains, and the only one worth
  # a warning while the session is open.
  def test_a_streak_of_zero_reads_on_an_unchanged_prefix_is_counted
    records = [
      record("cached_tokens" => 0),
      record("cached_tokens" => 0),
      record("cached_tokens" => 0)
    ]

    assert_equal 3, Rubot::CacheDiagnosis.miss_streak(records)
  end

  def test_a_streak_stops_at_the_first_read
    records = [
      record("cached_tokens" => 0),
      record("cached_tokens" => 8_000),
      record("cached_tokens" => 0),
      record("cached_tokens" => 0)
    ]

    assert_equal 2, Rubot::CacheDiagnosis.miss_streak(records)
  end

  # An explained miss is not part of a streak: the prompt moved, so the next
  # request had nothing to reuse by design.
  def test_a_trim_does_not_extend_a_streak
    records = [
      record("cached_tokens" => 0),
      record("cached_tokens" => 0, "diverged_at" => 10, "diverged_role" => "assistant"),
      record("cached_tokens" => 0)
    ]

    assert_equal 1, Rubot::CacheDiagnosis.miss_streak(records)
  end

  def test_a_new_epoch_does_not_extend_a_streak
    records = [
      record("cached_tokens" => 0),
      record("cached_tokens" => 0, "epoch" => "epoch-0"),
      record("cached_tokens" => 0)
    ]

    assert_equal 1, Rubot::CacheDiagnosis.miss_streak(records)
  end

  def test_an_empty_history_has_no_streak
    assert_equal 0, Rubot::CacheDiagnosis.miss_streak([])
  end
end
