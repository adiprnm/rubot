# frozen_string_literal: true

require "test_helper"
require "rubot"

# The text shapes shared by more than one channel. These are characterization
# tests: they pin what the channels already showed, so moving the code into one
# place cannot quietly change a label a reader has seen before.
class TestFormatting < Minitest::Test
  def test_duration_reads_like_the_turn_footer
    assert_equal "0s", Rubot::Formatting.duration(0.4)
    assert_equal "4s", Rubot::Formatting.duration(4.9)
    assert_equal "1m 5s", Rubot::Formatting.duration(65)
    assert_equal "1h 2m", Rubot::Formatting.duration(3720)
  end

  def test_precise_duration_keeps_a_tenth_below_a_minute
    assert_equal "0.4s", Rubot::Formatting.precise_duration(0.42)
    assert_equal "59.8s", Rubot::Formatting.precise_duration(59.75)
    assert_equal "2m", Rubot::Formatting.precise_duration(120)
    assert_equal "1m 5s", Rubot::Formatting.precise_duration(65.2)
  end

  def test_age_counts_in_the_units_a_reader_uses
    now = Time.utc(2026, 3, 10, 12, 0, 0)

    assert_equal "baru saja", Rubot::Formatting.age(now.to_f - 30, now: now)
    assert_equal "5 mnt", Rubot::Formatting.age(now.to_f - 300, now: now)
    assert_equal "2 jam", Rubot::Formatting.age(now.to_f - 7200, now: now)
    assert_equal "2 hr", Rubot::Formatting.age(now.to_f - 172_800, now: now)
  end

  def test_age_falls_back_to_a_date_past_a_month
    now = Time.utc(2026, 3, 10, 12, 0, 0)

    assert_equal "10 Jan lalu", Rubot::Formatting.age(Time.utc(2026, 1, 10).to_f, now: now)
  end

  def test_shorten_breaks_on_a_word_boundary
    assert_equal "hello…", Rubot::Formatting.shorten("hello world", 8)
    assert_equal "abcd…", Rubot::Formatting.shorten("abcdefghij", 5)
    assert_equal "short", Rubot::Formatting.shorten("short", 10)
    assert_equal "", Rubot::Formatting.shorten(nil, 10)
  end

  def test_truncate_is_a_hard_cut
    assert_equal "abc…", Rubot::Formatting.truncate("abcdef", 3)
    assert_equal "abc", Rubot::Formatting.truncate("abc", 5)
    assert_nil Rubot::Formatting.truncate(nil, 5)
  end
end

# One reader for the `data: {...}` framing both providers stream in. The point of
# the tests is the two edges the provider code used to get wrong on its own: a
# frame split across chunks, and a last frame with no trailing newline.
class TestSse < Minitest::Test
  class FakeResponse
    attr_reader :code

    def initialize(code, body = "")
      @code = code.to_s
      @body = body
    end

    def read_body
      yield @body
    end
  end

  def test_feed_waits_for_a_whole_frame
    reader = Rubot::Sse::Reader.new

    assert_empty reader.feed("data: {\"a\":")
    assert_equal [ "{\"a\":1}" ], reader.feed("1}\n")
  end

  def test_feed_answers_every_complete_frame_in_a_chunk
    reader = Rubot::Sse::Reader.new

    frames = reader.feed("data: one\n\ndata: two\n\n")

    assert_equal %w[one two], frames
  end

  def test_feed_ignores_lines_that_are_not_frames
    reader = Rubot::Sse::Reader.new

    assert_equal [ "one" ], reader.feed("event: ping\n:comment\ndata: one\n")
  end

  def test_feed_passes_the_done_sentinel_through
    reader = Rubot::Sse::Reader.new

    assert_equal [ "[DONE]" ], reader.feed("data: [DONE]\n")
  end

  def test_tail_hands_back_a_frame_with_no_newline
    reader = Rubot::Sse::Reader.new
    reader.feed("data: partial")

    assert_equal "partial", reader.tail
    assert_nil reader.tail
  end

  def test_tail_ignores_a_trailing_fragment_that_is_not_a_frame
    reader = Rubot::Sse::Reader.new
    reader.feed("half a line")

    assert_nil reader.tail
  end

  def test_a_successful_response_is_left_alone
    assert_nil Rubot::Sse.raise_for_response(FakeResponse.new(200)) { flunk "not called" }
  end

  def test_a_rate_limited_response_carries_the_hint
    error = assert_raises(Rubot::RateLimitError) do
      Rubot::Sse.raise_for_response(FakeResponse.new(429)) { 12 }
    end

    assert_equal 12, error.retry_after
  end

  def test_an_exhausted_quota_response_is_classified
    error = assert_raises(Rubot::QuotaExhaustedError) do
      Rubot::Sse.raise_for_response(FakeResponse.new(403, '{"error":"insufficient_quota"}'))
    end

    assert_match(/insufficient_quota/, error.message)
  end

  def test_any_other_error_keeps_the_body
    error = assert_raises(RuntimeError) do
      Rubot::Sse.raise_for_response(FakeResponse.new(500, "boom"))
    end

    assert_equal "API error 500: boom", error.message
  end
end
