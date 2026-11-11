# frozen_string_literal: true

module Rubot
  # The work that happens after an answer is already on screen: naming the
  # conversation, extracting memory, learning from a correction. Every job here
  # is a provider request, and none of them has anything to add to the answer
  # the user already has.
  #
  # Running them on the turn's own thread means the reader waits for them
  # anyway — the "still working" badge stays up, the stop button stays a stop
  # button, and a four-second answer feels like twelve. So they run here
  # instead: one worker, one job at a time, in the order the turns happened. A
  # single worker is deliberate, because two extractions writing the same
  # MEMORY.md at once would race.
  #
  # The owner gets told when a session is done, which is the moment a name
  # written here can be drawn.
  class Learning
    # How long #drain waits between looks at the queue.
    IDLE = 0.05

    def initialize(&on_done)
      @on_done = on_done
      @mutex = Mutex.new
      @queue = Queue.new
      @worker = nil
      @busy = false
    end

    # Hand a job over. The block runs on the worker; nothing here blocks the
    # caller, so a turn can end the moment its answer is complete.
    def submit(session_id = nil, &job)
      raise ArgumentError, "learning needs a job" unless job

      @queue << [ session_id, job ]
      start_worker
      self
    end

    def pending?
      @mutex.synchronize { @busy || !@queue.empty? }
    end

    # Wait for the queue to be worked off. For tests, and for a shutdown that
    # would rather not cut an extraction in half.
    def drain(timeout: 30)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep IDLE while pending? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      self
    end

    def stop(timeout: 10)
      worker = @mutex.synchronize { @worker }
      return self unless worker&.alive?

      drain(timeout: timeout)
      @queue << nil
      worker.join(timeout) || worker.kill
      self
    end

    private

    def start_worker
      @mutex.synchronize do
        return if @worker&.alive?

        @worker = Thread.new do
          Thread.current.report_on_exception = false
          loop do
            job = @queue.pop
            break if job.nil?

            session_id, work = job
            @mutex.synchronize { @busy = true }
            begin
              work.call
            rescue StandardError => e
              # A failure here must never cost the user an answer they already
              # have, so it is a debug line and nothing more.
              warn "[learning] #{e.class}: #{e.message}" if Rubot.debug?
            ensure
              @mutex.synchronize { @busy = false }
              notify_done(session_id)
            end
          end
        end
      end
    end

    def notify_done(session_id)
      @on_done&.call(session_id)
    rescue StandardError => e
      warn "[learning] after_learning failed: #{e.class}: #{e.message}" if Rubot.debug?
    end
  end
end
