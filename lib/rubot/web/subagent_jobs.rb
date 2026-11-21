# frozen_string_literal: true

require_relative "../formatting"
require_relative "subagent_line"

module Rubot
  module Web
    # The delegated runs a conversation owns, as seen from the main Ractor.
    #
    # A background run has no turn to report into: the turn that asked for it
    # has already answered the reader and closed its event stream. So the state
    # lives here instead — what is running, what it is doing, what it came back
    # with — and the footer is drawn from it, not from the turn.
    #
    # Thread-safe because the executor threads write while the renderer reads,
    # and because a single page asks for it on every event.
    class SubagentJobs
      RUNNING_PHASES = %w[started thinking tool].freeze
      # How long the mark on the footer's toggle stays after the last run ends.
      # Just long enough to register that the run finished; after that the row
      # goes back to being facts about the conversation rather than a history of
      # what ran. Nothing fires when it runs out, so the channel schedules the
      # hiding itself (see Web#hide_subagents_later): left to the next event, a
      # finished batch would sit in the corner until something unrelated moved.
      DONE_MARK_SECONDS = 3
      # Runs are kept so a finished one can still be read after its turn is
      # gone; past this the oldest finished ones are dropped. A conversation
      # that delegates a hundred times does not need a hundred rows in memory.
      KEEP_RUNS = 20

      def initialize(clock: nil)
        @mutex = Mutex.new
        @runs = {}
        @listeners = []
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      end

      # Whether the footer's sheet is worth a place in the row at all.
      #
      # A conversation that has never delegated should not carry a control for
      # it, and neither should one whose runs finished long ago — the tick on
      # the toggle is the only thing that still means anything after that. What
      # keeps it: a run still working, or one that ended inside the window the
      # tick is drawn for. Both the page (drawn once) and the stream (every
      # event) ask this same question, so they cannot disagree about it.
      def self.visible?(runs)
        list = Array(runs)
        return true if list.any? { |run| RUNNING_PHASES.include?(run[:phase].to_s) }

        list.any? do |run|
          %w[done failed].include?(run[:phase].to_s) && run[:finished_at] &&
            (Time.now - run[:finished_at]).to_f <= DONE_MARK_SECONDS
        end
      end

      # Called after any change, with the session id the run belongs to. The
      # channel uses it to move the footer without a reload.
      def on_change(&block)
        @mutex.synchronize { @listeners << block }
        self
      end

      def start(session_id:, run_id:, agent:, task:)
        sid = session_id.to_s
        rid = run_id.to_s
        return nil if sid.empty? || rid.empty?

        change(sid) do
          runs = (@runs[sid] ||= {})
          runs[rid] = {
            run_id: rid,
            agent: agent.to_s,
            task: task.to_s,
            phase: "started",
            detail: task.to_s,
            calls: 0,
            line: SubagentLine.line(calls: 0, phase: "started", detail: task),
            result: nil,
            error: nil,
            started: @clock.call,
            elapsed: nil
          }
          prune(runs)
        end
      end

      # A tool call, or a passage of text, from the run itself.
      def update(session_id:, run_id:, phase:, detail: nil)
        sid = session_id.to_s
        change(sid) do
          run = @runs.dig(sid, run_id.to_s)
          next unless run

          phase = phase.to_s
          run[:phase] = phase
          run[:detail] = detail.to_s unless detail.nil?
          run[:calls] = run[:calls].to_i + 1 if phase == "tool"
          run[:line] = SubagentLine.line(calls: run[:calls], phase: phase, detail: run[:detail])
        end
      end

      def finish(session_id:, run_id:, status:, result: nil, error: nil)
        sid = session_id.to_s
        change(sid) do
          run = @runs.dig(sid, run_id.to_s)
          next unless run

          run[:phase] = status.to_s
          run[:result] = result
          run[:error] = error
          run[:elapsed] = (@clock.call - run[:started].to_f).round(1)
          run[:finished_at] = Time.now
          run[:detail] = status.to_s == "failed" ? error.to_s : elapsed_label(run[:elapsed])
          run[:line] = SubagentLine.line(calls: run[:calls], phase: status, detail: run[:detail])
        end
      end

      # Newest first, as the footer draws them.
      def runs(session_id)
        @mutex.synchronize do
          (@runs[session_id.to_s] || {}).values.reverse.map(&:dup)
        end
      end

      def running_count(session_id)
        @mutex.synchronize do
          (@runs[session_id.to_s] || {}).values.count { |run| RUNNING_PHASES.include?(run[:phase]) }
        end
      end

      def forget(session_id)
        @mutex.synchronize { @runs.delete(session_id.to_s) }
      end

      private

      # The change and the notification happen under the same lock, so two
      # events cannot reach the listener out of order and leave the footer
      # showing a state the run already left.
      def change(sid)
        listeners = nil
        @mutex.synchronize do
          yield
          listeners = @listeners.dup
        end
        listeners.each { |listener| listener.call(sid) }
      end

      def prune(runs)
        return if runs.size <= KEEP_RUNS

        doomed = runs.values
                    .reject { |run| RUNNING_PHASES.include?(run[:phase]) }
                    .sort_by { |run| run[:started].to_f }
                    .first(runs.size - KEEP_RUNS)
        doomed.each { |run| runs.delete(run[:run_id]) }
      end

      def elapsed_label(seconds)
        Rubot::Formatting.precise_duration(seconds)
      end
    end
  end
end
