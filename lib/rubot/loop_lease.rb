# frozen_string_literal: true

require "fileutils"

module Rubot
  # One run per loop, proved by the kernel instead of by a number in a file.
  #
  # The loop's markdown says what a loop *should* be doing: `status: active` is
  # what a resume, a schedule and the tool all read as "somebody is working on
  # this". Nothing in that file changes when the process holding the run goes
  # away, so a run that died with its process leaves a loop that looks alive and
  # refuses every wake ("it is already active and iterating"). A pid written
  # beside the status would not settle it either: pids are reused, and inside a
  # container the pid that wrote the number is not the pid that reads it.
  #
  # A lease does settle it. flock belongs to the open file description, so "is
  # anyone running this loop?" has an answer the kernel keeps and drops when the
  # process dies, however it dies: nothing to clean up, no heartbeat to time out,
  # and no way for a stale claim to survive the process that made it.
  #
  # What this does NOT buy: the iteration in flight still dies with the process,
  # and so does the money already spent on it. A lease makes the loop resumable
  # from its file; it does not make the run survive a restart. Keeping the run
  # alive would take a process of its own -- a transient systemd unit, or a child
  # that outlives the parent and is findable again at boot -- and that is
  # deliberately not attempted here: it is a supervisor's job, and the two facts
  # this class does provide are what such a supervisor would need anyway.
  class LoopLease
    # How many takeovers a loop may take without finishing a single iteration
    # before the run itself is the suspect. Enforced in LoopRunner#resume, which
    # is the one place that decides whether a wake is allowed to become a run.
    MAX_TAKEOVERS = 3

    # The lock file for one loop.
    #
    # A file of its own, and it is NEVER unlinked or renamed over: LoopStore#save
    # lands a temp file with File.rename, so a lock taken on the data file would
    # keep an inode the next save had already replaced, and two processes would
    # then hold locks on two different files that both look like one loop. The
    # lock is the inode, not the path, so the inode has to stay where it is.
    def self.path_for(dir, id) = File.join(dir, ".#{id}.run")

    # The lease, or nil when somebody else holds it. Never waits: a run that is
    # already in flight is an answer the caller has to give, not a line to stand
    # in.
    def self.hold(dir, id)
      path = path_for(dir, id)
      FileUtils.mkdir_p(dir)
      io = File.open(path, File::RDWR | File::CREAT, 0o600)
      # rubot forks for tool execution, and a forked child inherits the parent's
      # open file descriptions, and with them the lock. Closing this one on exec
      # keeps the lease with the process that took it, so a child that outlives
      # its parent is not a loop nobody is working.
      io.close_on_exec = true
      begin
        return new(io) if io.flock(File::LOCK_EX | File::LOCK_NB)
      rescue StandardError
        # A `flock` that raises would otherwise leave this description open for
        # the garbage collector to close whenever it got round to it, which is
        # one file descriptor per failure until the process runs out.
        io.close
        raise
      end

      io.close
      nil
    end

    # Whether somebody holds the lease. It must not steal one on the way to the
    # answer, and it must not look like a holder to anything else that asks.
    #
    # A shared lock is what buys the second half. A run takes the lease
    # exclusively (see .hold); a reader takes it shared -- LOCK_SH -- and gives it
    # straight back. Two shared locks coexist, so two pages asking at the same
    # moment both read "free", which is the answer the loop's file already gives.
    # Asked of an exclusive lock instead -- which is what this was -- the second
    # asker took the first asker for a run: a dead loop wore a turning ring, and
    # a resume landing in that window was refused as already active.
    #
    # A reader still brushes against a real run for the instant it holds the
    # file, because an exclusive lock cannot land while a shared one is open.
    # That is why the question is one non-blocking call and nothing more: the
    # shorter it is, the smaller the window two readers of the same loop can
    # widen between them.
    #
    # Nor may asking leave anything behind. A lock file that is not there is a
    # lease nobody has taken, and the directory it would live in need not exist
    # either: opening the file for writing made both, so every question left a
    # `loops` directory and an empty `.id.run` behind. The file is opened
    # read-only instead, and a missing one is answered by that same open rather
    # than by a look at whether the path exists in front of it -- one question to
    # the kernel, with no window between two.
    def self.held?(dir, id)
      io = File.open(path_for(dir, id), File::RDONLY)
      begin
        return true unless io.flock(File::LOCK_SH | File::LOCK_NB)
      ensure
        # The lock lives in the open file description, so closing is releasing;
        # a probe that left a description behind would be one descriptor per ask,
        # and there is an ask every three seconds a panel is open.
        io.close
      end
      false
    rescue Errno::ENOENT
      # Nothing to open is nothing held: the lock file is the lease, so a file
      # that was never made is a loop that was never run.
      false
    rescue SystemCallError, IOError
      # A lock file that cannot be opened cannot be proved free either, so the
      # answer is the conservative one. Nothing is guessed into words here: the
      # caller that goes on to run the loop asks for the lease again inside
      # LoopRunner#run, where the failure is answered as "could not be leased"
      # with the file's own message rather than as "already active".
      true
    end

    def initialize(io)
      @io = io
    end

    # Idempotent, because it runs in an `ensure` and an ensure that raises on a
    # second call is an exception that hides the one being raised. Closing the
    # description would release the lock anyway; LOCK_UN first is what says so
    # plainly, and keeps the order true if close is ever expected to fail.
    def release
      io = @io
      return self if io.nil?

      @io = nil
      begin
        io.flock(File::LOCK_UN)
      rescue IOError, SystemCallError
        nil
      ensure
        io.close unless io.closed?
      end
      self
    end
  end
end
