# frozen_string_literal: true

require "rbconfig"
require_relative "test_helper"

# What is guarded here is drain itself: a read the kernel has parked and that
# close does not wake is the case release has to end with a kill, and a reader
# that outlives its command holds a pipe and a 64KB buffer for the life of the
# process. Where the readers that accumulated on a long lived server came from
# was never traced, so nothing here claims to reproduce that. The background
# child case, where a finished command's pipe stays open, is covered in
# test_tools.rb. The launcher tests at the end are here because the arena cap is
# set for a child rather than for this process.
class TestShellPipeReader < Minitest::Test
  PipeReader = Rubot::Tools::Shell::PipeReader

  # Seconds the launcher tests give their child to answer and to be reaped. A
  # child that wedges has to fail the test quickly instead of holding the shard
  # it runs in open.
  CHILD_READ_TIMEOUT = 10
  CHILD_EXIT_TIMEOUT = 10

  # Stands in for a read the kernel has parked and that close does not wake,
  # so only the kill can end that thread.
  class UnwakeableSource
    def initialize
      @gate = Queue.new
    end

    def readpartial(_size)
      @gate.pop
    end

    def close
      nil
    end
  end

  # A pipe whose descriptor is closed under the reader: the read ends with
  # IOError rather than EOF, and a close from release raises as well, which
  # release has to absorb on its second call.
  class ClosedUnderReaderSource
    def readpartial(_size)
      raise IOError, "closed stream"
    end

    def close
      raise IOError, "closed stream"
    end
  end

  # --- PipeReader#drain ---

  def test_a_pipe_that_never_reaches_eof_is_forced_and_leaves_no_reader_thread
    reader, writer = IO.pipe
    writer.write("partial output")
    writer.flush
    pipe_reader = PipeReader.new(reader)
    wait_for_text(pipe_reader, "partial output")

    text, forced = pipe_reader.drain(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.2)

    assert forced, "a pipe that never reaches EOF has to be reported as cut"
    assert_includes text, "partial output"
    refute pipe_reader.alive?, "drain must not return while its reader is still running"

    # The caller's ensure releases again on the way out; that second release
    # has to stay quiet and leave nothing running.
    pipe_reader.release
    refute pipe_reader.alive?, "release must leave no reader thread behind"
  ensure
    writer.close unless writer.closed?
    reader.close unless reader.closed?
  end

  # A reader whose io is closed under it stops without reaching EOF. A join
  # says nothing about that, so drain has to ask the reader how it ended: a
  # partial text reported as complete is the failure a caller has no way to
  # notice on its own.
  def test_a_pipe_closed_under_the_reader_is_reported_as_cut
    pipe_reader = PipeReader.new(ClosedUnderReaderSource.new)

    _, forced = pipe_reader.drain(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5)

    assert forced, "output from a pipe closed under the reader is not complete"
    pipe_reader.release
    refute pipe_reader.alive?
  end

  # This reader stopped at EOF, so drain returned without releasing anything
  # and the caller's ensure is the first release. A later release may follow as
  # well: neither may raise or leave a thread.
  def test_release_after_a_finished_reader_is_quiet_and_leaves_no_thread
    reader, writer = IO.pipe
    writer.write("done")
    writer.close
    pipe_reader = PipeReader.new(reader)
    wait_for_text(pipe_reader, "done")

    text, forced = pipe_reader.drain(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1)

    refute forced, "a pipe that reached EOF is complete output"
    assert_equal "done", text
    pipe_reader.release
    pipe_reader.release

    refute pipe_reader.alive?, "release must leave no reader thread behind"
  ensure
    reader.close unless reader.closed?
  end

  # The real path through the tool, so the ensure that releases both readers
  # runs with nothing raised above it. The output is what a caller reads, and
  # a complete command must not be reported as cut.
  def test_a_normal_command_is_reported_as_complete
    output = Rubot::Tools::Shell.new.execute({ "command" => "echo hi" })

    assert_includes output, "hi"
    refute_includes output, "output may be incomplete"
  end

  def test_a_reader_that_close_cannot_wake_is_killed_instead_of_left_behind
    pipe_reader = PipeReader.new(UnwakeableSource.new)

    _, forced = pipe_reader.drain(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05)

    assert forced
    refute pipe_reader.alive?, "a reader that close could not wake has to be killed"
  end

  # --- Launcher environment ---

  # The launcher builds this hash before the child exists, which is the only
  # moment the value can still do anything: glibc reads MALLOC_ARENA_MAX at the
  # first allocation, so a Ruby that is already running cannot apply it.
  def test_the_launcher_defaults_the_malloc_arena_cap_for_its_child
    assert_equal "2", Rubot::LaunchEnv.child_env({})["MALLOC_ARENA_MAX"]
  end

  def test_an_operator_set_arena_cap_is_not_overwritten
    kept = Rubot::LaunchEnv.child_env({ "MALLOC_ARENA_MAX" => "8" })

    # An absent key is how spawn keeps the parent's value, so this is the
    # operator's 8 reaching the child untouched rather than a silent 2.
    refute kept.key?("MALLOC_ARENA_MAX"), "an operator set cap must not be replaced by the default"
    assert_equal "2", Rubot::LaunchEnv.child_env({ "MALLOC_ARENA_MAX" => "  " })["MALLOC_ARENA_MAX"],
                 "a blank value is no value at all, so the default belongs there"
  end

  # The value only exists before the child's Ruby starts, so it is checked on a
  # real child rather than read out of the launcher's source: an env hash handed
  # to spawn as its first argument, which is exactly what bin/web-restart does.
  def test_the_default_arena_cap_reaches_a_spawned_child
    with_arena_env(nil) { assert_equal "2", arena_seen_by_child }
  end

  def test_an_operator_set_arena_cap_reaches_the_child_unchanged
    with_arena_env("8") { assert_equal "8", arena_seen_by_child }
  end

  private

  # One short lived child that prints the cap it was started with. The env
  # hash is the launcher's own, RUBOT_DEBUG included, so this is the value the
  # web child would get.
  def arena_seen_by_child
    env = Rubot::LaunchEnv.child_env.merge("RUBOT_DEBUG" => "1")
    reader, writer = IO.pipe
    pid = Process.spawn(env, RbConfig.ruby, "-e", 'print ENV["MALLOC_ARENA_MAX"]', out: writer)
    writer.close
    read_child(reader)
  ensure
    writer.close unless writer.nil? || writer.closed?
    reader.close unless reader.nil? || reader.closed?
    wait_child(pid) if pid
  end

  # Reads until the child closes the pipe, with a deadline on every wait: a
  # child that never writes has to fail this test rather than block the shard.
  def read_child(reader, timeout = CHILD_READ_TIMEOUT)
    output = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      flunk "the child wrote nothing within #{timeout}s" if left <= 0
      next unless IO.select([ reader ], nil, nil, left)

      begin
        output << reader.readpartial(4096)
      rescue EOFError
        return output
      end
    end
  end

  # Reaping is part of the test: a child left running is a stray process, and
  # this one only prints a value and exits. Every wait before the kill is
  # bounded for the same reason the read is, so a child that never exits is
  # killed at the deadline instead of stalling the shard. The reap that follows
  # the kill is deliberately left unbounded: SIGKILL cannot be caught or
  # ignored, so the only child still there after it is one stuck in an
  # uninterruptible wakeup, and no timeout here would shorten that wait.
  # Bounding it would buy nothing and would give up reaping a process this test
  # started, which is the stray it exists to prevent.
  def wait_child(pid, timeout = CHILD_EXIT_TIMEOUT)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      reaped = Process.wait(pid, Process::WNOHANG)
      return reaped if reaped

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill("KILL", pid)
        return Process.wait(pid)
      end

      sleep 0.01
    end
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end

  def with_arena_env(value)
    previous = ENV["MALLOC_ARENA_MAX"]
    if value.nil?
      ENV.delete("MALLOC_ARENA_MAX")
    else
      ENV["MALLOC_ARENA_MAX"] = value
    end
    yield
  ensure
    if previous.nil?
      ENV.delete("MALLOC_ARENA_MAX")
    else
      ENV["MALLOC_ARENA_MAX"] = previous
    end
  end

  # The reader works on its own thread, so the text can take a moment to land.
  # The bound keeps a broken reader from sleeping out the whole drain grace.
  def wait_for_text(pipe_reader, expected)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    until pipe_reader.text.include?(expected)
      flunk "the reader never picked up #{expected.inspect}" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
