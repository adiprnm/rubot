# frozen_string_literal: true

module Rubot
  # Cooperative cancellation for one agent turn.
  #
  # A turn calls #start! when it begins and #finish! when it ends (both from
  # the thread that runs the turn). Any other thread — the REPL prompt, a
  # Telegram update thread, or the watcher thread inside a session Ractor —
  # may call #cancel!.
  #
  # The agent checks #cancelled? before every provider call and before every
  # tool execution. Running shell commands are killed through #track/#untrack,
  # which the shell tool uses to register the process group it spawned.
  class Cancellation
    def initialize
      @mutex = Mutex.new
      @cancelled = false
      @running = false
      @children = {}
    end

    def running?
      @mutex.synchronize { @running }
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end

    # Begin a turn. Any stop request that arrived while nothing was running is
    # dropped, so it cannot cancel the next task.
    def start!
      @mutex.synchronize do
        @cancelled = false
        @running = true
        @children.clear
      end
      self
    end

    def finish!
      @mutex.synchronize do
        @running = false
        @cancelled = false
        @children.clear
      end
      self
    end

    # Request cancellation. Returns true when a turn was actually running.
    def cancel!
      pids, was_running = @mutex.synchronize do
        running = @running
        @cancelled = true if running
        [ @children.keys, running ]
      end

      pids.each { |pid| kill(pid) }
      was_running
    end

    # Register a child process that must die if the turn is cancelled.
    # A cancellation that landed between the agent's check and the spawn is
    # honoured here instead of running the command to completion.
    def track(pid)
      kill_now = @mutex.synchronize do
        @children[pid] = true
        @cancelled
      end
      kill(pid) if kill_now
      pid
    end

    def untrack(pid)
      @mutex.synchronize { @children.delete(pid) }
      nil
    end

    private

    # Terminate the child's whole process group, then force it after a grace
    # period so a shell that ignores TERM cannot keep the turn alive.
    def kill(pid)
      Process.kill("TERM", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      begin
        Process.kill("TERM", pid)
      rescue StandardError
        nil
      end
    ensure
      Thread.new do
        sleep 2
        begin
          Process.kill("KILL", -pid)
        rescue StandardError
          nil
        end
      end
    end
  end
end
