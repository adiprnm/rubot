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
