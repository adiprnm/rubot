# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "rbconfig"

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

  # A question must not leave anything behind either. Opening the lock file for
  # writing made it, and the directory it lives in, for a loop nobody had ever
  # run -- a file that answers "free" forever plus a `loops` directory born of a
  # question. Nobody can hold a lease that was never taken, so the answer is free
  # without anything being opened for writing.
  def test_asking_about_a_loop_that_never_ran_creates_nothing
    dir = File.join(@tmp, "never")

    refute Rubot::LoopLease.held?(dir, ID), "no lease was ever taken, so none is held"
    refute File.exist?(dir), "the question must not create the loops directory"
    refute File.exist?(Rubot::LoopLease.path_for(dir, ID)), "nor the lock file inside it"
  end

  # A reader is not a run. The footer's loop mark asks this every three seconds
  # while the panel is open, and an exclusive probe made two askers look like
  # holders to each other: the ring turned over a loop whose run had died, which
  # is the one thing the lease exists to be able to tell apart.
  def test_a_reader_is_not_seen_as_a_run
    path = Rubot::LoopLease.path_for(@dir, ID)
    reader = File.open(path, File::RDONLY | File::CREAT, 0o600)
    reader.flock(File::LOCK_SH)

    refute Rubot::LoopLease.held?(@dir, ID), "a shared read is not somebody working"
    refute Rubot::LoopLease.held?(@dir, ID), "and two readers do not make one"

    assert_nil Rubot::LoopLease.hold(@dir, ID), "a real lease still does not get it"
  ensure
    reader&.close
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

  # rubot forks for tool execution, and a forked child inherits the parent's
  # open file descriptions -- and the locks on them. close_on_exec is what keeps
  # the lease with the process that took it: without it an exec'd child outlives
  # the parent as a loop nobody is working, and every resume of that loop answers
  # "already active" until the child happens to go away. The child here takes the
  # lease and replaces itself with another program, which is the only place the
  # boundary can be seen: after an exec the lock must be gone.
  def test_a_lease_does_not_survive_an_exec_in_a_forked_child
    skip "fork is not available here" unless Process.respond_to?(:fork)
    skip "flock is not honoured on this filesystem" unless leases_conflict?

    marker = File.join(@tmp, "exec")
    child = fork do
      Rubot::LoopLease.hold(@dir, ID)
      exec(RbConfig.ruby, "-e", "File.write(#{marker.inspect}, '1'); sleep 30")
    end

    begin
      wait_for(marker)
      refute_nil hold, "the child that replaced itself holds nothing, so the lease is free"
    ensure
      Process.kill("KILL", child)
      Process.waitpid(child)
    end
  end

  # A lock file that cannot be opened is neither free nor held, and the caller
  # cannot be told which. Answering "held" is the conservative half: the run that
  # asks again inside LoopRunner#run answers in words ("could not be leased",
  # with the file's own message), so nothing here has to guess a sentence. What
  # must not happen is an EACCES escaping this method, which is what the resume
  # path and the cron route used to get.
  def test_held_answers_conservatively_when_the_lock_file_cannot_be_opened
    path = Rubot::LoopLease.path_for(@dir, ID)
    File.write(path, "")
    begin
      File.chmod(0o000, path)
      probe = begin
        File.open(path, File::RDWR)
      rescue SystemCallError
        nil
      end
      if probe
        probe.close
        skip "this user can open an unreadable file, so the failure cannot be staged"
      end

      assert Rubot::LoopLease.held?(@dir, ID),
             "a question that cannot be answered must not answer \"free\""
    ensure
      File.chmod(0o600, path)
    end
  end

  # The other half of the same failure: a run that cannot take the lease because
  # the file is unreadable has to be a refusal, not an exception. A root-owned
  # lock file after a privileged run is the ordinary way this happens.
  def test_hold_raises_for_the_caller_that_answers_in_words
    path = Rubot::LoopLease.path_for(@dir, ID)
    File.write(path, "")
    begin
      File.chmod(0o000, path)
      probe = begin
        File.open(path, File::RDWR)
      rescue SystemCallError
        nil
      end
      if probe
        probe.close
        skip "this user can open an unreadable file, so the failure cannot be staged"
      end

      assert_raises(SystemCallError) { Rubot::LoopLease.hold(@dir, ID) }
    ensure
      File.chmod(0o600, path)
    end
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
