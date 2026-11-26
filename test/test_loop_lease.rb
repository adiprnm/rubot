# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

require "rubot/loop_lease"

# The lease is the only thing that tells a loop somebody is working from a loop
# whose run died with its process, so these hold it to exactly three promises:
# one holder at a time, a question that does not steal the answer it is asking
# about, and a release that happens however the holder goes away -- including a
# SIGKILL, which is the whole reason a lock was chosen over a pid.
class TestLoopLease < Minitest::Test
  ID = "20260101-000000-abcd"

  def setup
    @tmp = Dir.mktmpdir("rubot-loop-lease")
    @dir = File.join(@tmp, "loops")
    FileUtils.mkdir_p(@dir)
    @leases = []
  end

  def teardown
    @leases.each(&:release)
    FileUtils.remove_entry(@tmp) if File.exist?(@tmp)
  end

  def hold(id = ID)
    lease = Rubot::LoopLease.hold(@dir, id)
    @leases << lease if lease
    lease
  end

  # flock belongs to the open file description, not to the process, so a second
  # File.open in the same process is a second description and gets nothing. If
  # this ever passed, two channels of one process could work the same worktree
  # and share its index and its iteration number.
  def test_a_second_handle_in_the_same_process_cannot_take_the_lease
    first = hold
    refute_nil first, "the first holder takes the lease"

    second = Rubot::LoopLease.hold(@dir, ID)

    assert_nil second, "a second open file description must not get the lock"
  end

  # The question must not change the thing it asks about: asked while a run is in
  # flight -- which is every time the loop tool is asked to resume an active
  # loop -- a lease that took the lock would take it out of a live run's hands.
  def test_held_answers_true_without_stealing_the_lease
    refute Rubot::LoopLease.held?(@dir, ID), "nobody holds it yet"
    holder = hold

    assert Rubot::LoopLease.held?(@dir, ID), "the holder is seen"
    assert_nil Rubot::LoopLease.hold(@dir, ID), "and asked while it holds, the lease stays its own"

    holder.release

    refute Rubot::LoopLease.held?(@dir, ID), "a released lease is free again"
  end

  # It runs in an ensure, so a second call is normal rather than a bug: an ensure
  # that raised on the second release would hide whatever was already leaving.
  def test_release_twice_does_not_raise_and_frees_the_lease
    first = hold

    assert_same first, first.release
    first.release

    second = hold
    refute_nil second, "the next run can take what the first one let go"
  end

  # The whole point of a lease over a pid: the holder dies however it dies, and
  # the kernel still frees the lock. A restart is exactly this, and the loop it
  # was working has to be resumable afterwards.
  def test_a_killed_holder_releases_the_lease
    skip "fork is not available here" unless Process.respond_to?(:fork)
    skip "flock is not honoured on this filesystem" unless leases_conflict?

    marker = File.join(@tmp, "held")
    child = fork do
      Rubot::LoopLease.hold(@dir, ID)
      File.write(marker, "1")
      sleep 30
      exit!(0)
    end

    begin
      wait_for(marker)
      assert Rubot::LoopLease.held?(@dir, ID), "the child holds the lease"

      Process.kill("KILL", child)
    ensure
      Process.waitpid(child)
    end

    lease = hold
    refute_nil lease, "a killed holder takes nothing with it: the lock is the kernel's to drop"
  end

  private

  def wait_for(path, seconds: 10)
    deadline = Time.now + seconds
    sleep 0.01 until File.exist?(path) || Time.now > deadline
  end

  # Probed rather than assumed: a filesystem that does not honour flock would
  # otherwise fail the kill test for being what it is, and the lock it cannot
  # keep is a property of the machine, not of this code.
  def leases_conflict?
    first = Rubot::LoopLease.hold(@dir, "probe")
    second = Rubot::LoopLease.hold(@dir, "probe")
    second&.release
    first&.release
    !first.nil? && second.nil?
  end
end
