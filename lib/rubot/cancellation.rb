# frozen_string_literal: true

module Rubot
  # Raised to unwind a turn the moment the user stops it. Providers call
  # Cancellation.check! between network chunks, so raising from inside the
  # response body loop aborts the HTTP request instead of reading the rest of
  # the answer before noticing.
  class Cancelled < StandardError
    def initialize(message = "turn cancelled by user")
      super
    end
  end

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
  #
  # A blocked network read cannot check a flag, so providers register their
  # started HTTP session with #track_connection: a stop closes it from the
  # watcher thread, which interrupts the read immediately.
  class Cancellation
    # The token for the turn running on the current thread, if any. The agent
    # sets this at the start of a turn; providers read it from #check!.
    def self.current
      Thread.current[:rubot_cancellation]
    end

    # Raise Cancelled when the turn on this thread has been stopped.
    def self.check!
      current&.check!
    end

    def initialize
      @mutex = Mutex.new
      @cancelled = false
      @running = false
      @children = {}
      @connections = {}
    end

    def running?
      @mutex.synchronize { @running }
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end

    # Raise Cancelled when the turn has been stopped. This is the edge a
    # provider can act on mid-stream, where a boolean check would only be
    # read after the response body finished.
    def check!
      raise Cancelled if cancelled?

      nil
    end

    # Begin a turn. Any stop request that arrived while nothing was running is
    # dropped, so it cannot cancel the next task.
    def start!
      @mutex.synchronize do
        @cancelled = false
        @running = true
        @children.clear
        @connections.clear
      end
      self
    end

    def finish!
      @mutex.synchronize do
        @running = false
        @cancelled = false
        @children.clear
        @connections.clear
      end
      self
    end

    # Request cancellation. Returns true when a turn was actually running.
    def cancel!
      pids, connections, was_running = @mutex.synchronize do
        running = @running
        @cancelled = true if running
        [ @children.keys, @connections.keys, running ]
      end

      # Closing first releases a provider read that would otherwise keep the
      # turn blocked until the answer arrived.
      connections.each { |connection| close(connection) }
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

    # Register a started network session (Net::HTTP) that a stop must close.
    # A cancellation that landed between the agent's check and the connect is
    # honoured here instead of waiting for the response to finish.
    def track_connection(connection)
      close_now = @mutex.synchronize do
        @connections[connection] = true
        @cancelled
      end
      close(connection) if close_now
      connection
    end

    def untrack_connection(connection)
      @mutex.synchronize { @connections.delete(connection) }
      nil
    end

    private

    def close(connection)
      connection.finish if connection.respond_to?(:started?) && connection.started?
    rescue StandardError
      nil
    end

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
