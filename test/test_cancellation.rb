# frozen_string_literal: true

require_relative "test_helper"

class TestCancellation < Minitest::Test
  def test_an_idle_token_ignores_a_cancel_request
    token = Rubot::Cancellation.new

    refute token.cancel!, "nothing is running, so there is nothing to stop"
    refute token.cancelled?
  end

  def test_cancel_marks_a_running_turn
    token = Rubot::Cancellation.new.start!

    assert token.running?
    assert token.cancel!
    assert token.cancelled?
  end

  def test_starting_a_turn_drops_an_earlier_request
    token = Rubot::Cancellation.new.start!
    token.cancel!

    token.finish!
    token.start!

    refute token.cancelled?
    assert token.running?
  end

  def test_finishing_a_turn_clears_the_request
    token = Rubot::Cancellation.new.start!
    token.cancel!

    token.finish!

    refute token.cancelled?
    refute token.running?
  end

  def test_cancel_kills_a_tracked_process_group
    token = Rubot::Cancellation.new.start!
    pid = Process.spawn("sleep 30", pgroup: true)
    token.track(pid)
    reaper = Thread.new { Process.waitpid(pid) }

    assert token.cancel!
    assert reaper.join(5), "the tracked command must be killed on /stop"
    token.untrack(pid)
  ensure
    begin
      Process.kill("KILL", -pid) if pid
    rescue StandardError
      nil
    end
  end

  def test_tracking_after_cancel_kills_the_command_immediately
    token = Rubot::Cancellation.new.start!
    token.cancel!

    pid = Process.spawn("sleep 30", pgroup: true)
    reaper = Thread.new { Process.waitpid(pid) }
    token.track(pid)

    assert reaper.join(5), "a command spawned after the stop must not run"
  ensure
    begin
      Process.kill("KILL", -pid) if pid
    rescue StandardError
      nil
    end
  end
end

class TestCancellationChecks < Minitest::Test
  # Stands in for the started Net::HTTP session a provider registers.
  class FakeConnection
    attr_reader :closed

    def initialize
      @started = true
      @closed = false
    end

    def started?
      @started
    end

    def finish
      @started = false
      @closed = true
    end
  end

  def teardown
    Thread.current[:rubot_cancellation] = nil
  end

  def test_check_raises_only_when_the_turn_was_stopped
    token = Rubot::Cancellation.new.start!
    assert_nil token.check!

    token.cancel!

    assert_raises(Rubot::Cancelled) { token.check! }
  end

  def test_current_is_the_token_set_on_the_thread
    token = Rubot::Cancellation.new.start!
    Thread.current[:rubot_cancellation] = token

    assert_same token, Rubot::Cancellation.current

    token.cancel!
    assert_raises(Rubot::Cancelled) { Rubot::Cancellation.check! }
  end

  def test_check_without_a_running_turn_does_nothing
    assert_nil Rubot::Cancellation.current
    assert_nil Rubot::Cancellation.check!
  end

  def test_cancel_closes_a_tracked_connection
    connection = FakeConnection.new
    token = Rubot::Cancellation.new.start!
    token.track_connection(connection)

    token.cancel!

    assert connection.closed, "a stop must close the session a provider is blocked on"
  end

  def test_tracking_after_cancel_closes_the_connection_immediately
    connection = FakeConnection.new
    token = Rubot::Cancellation.new.start!
    token.cancel!

    token.track_connection(connection)

    assert connection.closed
  end
end
