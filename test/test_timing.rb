# frozen_string_literal: true

require "test_helper"
require "rubot"
require "tmpdir"

# Where a provider request spends its time. The point of these is that a slow
# round is not one number: the wait for the first byte and the rest of the
# answer are recorded separately, because only one of them grows with the size
# of the answer.
class TestTiming < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rubot-timing")
    @log = File.join(@dir, "timing.jsonl")
    @saved_enabled = ENV["RUBOT_TIMING"]
    @saved_path = ENV["RUBOT_TIMING_PATH"]
    ENV["RUBOT_TIMING"] = "1"
    ENV["RUBOT_TIMING_PATH"] = @log
  end

  def teardown
    ENV["RUBOT_TIMING"] = @saved_enabled
    ENV["RUBOT_TIMING_PATH"] = @saved_path
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def rows
    File.readlines(@log).map { |line| JSON.parse(line) }
  end

  def test_nothing_is_written_unless_asked_for
    ENV["RUBOT_TIMING"] = nil

    Rubot::Timing.record(model: "m", prompt_bytes: 10, total: 1.0)

    refute File.exist?(@log), "a chat should not write a log line per request"
  end

  def test_a_request_records_both_halves_of_the_wait
    Rubot::Timing.record(model: "m", prompt_bytes: 1234, first_byte: 1.5,
                         total: 4.25, tool_calls: 3)

    row = rows.last
    assert_equal "m", row["model"]
    assert_equal 1234, row["prompt_bytes"]
    assert_in_delta 1.5, row["first_byte_s"], 0.001
    assert_in_delta 4.25, row["total_s"], 0.001
    assert_equal 3, row["tool_calls"]
  end

  def test_the_report_separates_the_first_byte_from_the_rest
    Rubot::Timing.record(model: "fast", prompt_bytes: 100, first_byte: 0.8, total: 1.2)
    Rubot::Timing.record(model: "fast", prompt_bytes: 100, first_byte: 1.0, total: 1.4)
    Rubot::Timing.record(model: "slow", prompt_bytes: 900, first_byte: 4.0, total: 9.0)

    report = Rubot::Timing.report

    assert_includes report, "fast"
    assert_includes report, "slow"
    assert_match(/fast\s+n=\s+2/, report)
  end

  def test_a_missing_log_is_said_so_instead_of_raising
    FileUtils.rm_f(@log)

    assert_includes Rubot::Timing.report, "no timing log"
  end

  # A provider request runs inside a session Ractor, where only shareable
  # constants may be read. A non-frozen path constant raised
  # Ractor::IsolationError there, and because the recorder swallows its own
  # errors the symptom was silence: no line, no message.
  def test_a_record_from_inside_a_ractor_reaches_the_log
    port = Ractor::Port.new
    Ractor.new(port) do |reply|
      Rubot::Timing.record(model: "inside-ractor", prompt_bytes: 7, total: 0.5)
      reply.send(:done)
    rescue Exception => e # rubocop:disable Lint/RescueException
      reply.send(e.class.to_s)
    end

    assert_equal :done, port.receive
    assert_equal "inside-ractor", rows.last["model"]
  end
end
