# frozen_string_literal: true

module Rubot
  class Agent
    # The phases of one turn, moved out of #process one at a time.
    #
    # #process used to be one 400-line method because the state of a turn lived
    # in its local variables and nowhere else. Turn (agent/turn.rb) holds the
    # state now, so a phase can be a method that is handed the turn and the few
    # things that are not part of it, and #process can read as the order the
    # phases run in.
    #
    # Every phase here is moved as it was, keeping its comments and its order of
    # side effects: the callbacks a channel receives must fire in the same
    # sequence, and a turn must ask the provider the same number of times.
    module TurnLoop
      private

      # Everything that happens before the first provider round: due cron jobs,
      # the cancellation token, the tool registry stamped with this turn's
      # persona, the callbacks this turn reports through, the point in the
      # transcript where it starts, and the user's own words.
      #
      # Returns [turn, cron_results]: the turn being opened, and the cron output
      # that is folded into the answer once the turn ends.
      def prepare_turn(message, on_subagent: nil, on_delegate: nil, on_compaction: nil,
                       on_compaction_start: nil, on_compaction_failed: nil)
        # Fire any due cron jobs and collect their results
        cron_results = fire_due_cron_jobs
        warn "[cron] fire_due_cron_jobs returned #{cron_results.size} result(s)" if Rubot.debug?

        # This turn can now be stopped with /stop (or Ctrl+C in the REPL).
        @cancellation.start!
        Thread.current[:rubot_cancellation] = @cancellation
        turn = Turn.new(limit: max_rounds)
        # The tool registry is shared across sessions, so the persona that owns
        # this turn has to be stamped on it now — not at boot, where a second
        # persona's actor would silently overwrite the first one's scope.
        inject_tool_persona
        inject_tool_delegate
        @subagent_count = 0
        @on_subagent = on_subagent
        @on_delegate = on_delegate
        @on_compaction = on_compaction
        @on_compaction_start = on_compaction_start
        @on_compaction_failed = on_compaction_failed

        # Reasoning from earlier turns is dropped from the request; only what is
        # produced inside this turn is kept, because a tool loop needs it.
        @turn_start_index = @session.messages.size

        # A steer that arrived just as the previous turn was ending still
        # belongs to the user: it enters ahead of this message instead of
        # being replayed in the middle of the new turn.
        stray = take_steering
        while stray
          @session.add("user", stray)
          stray = take_steering
        end

        # Add user message to session
        @session.add("user", message)
        # Queue it for extraction; the provider call happens in #flush_learning,
        # after the channel has delivered the answer.
        @session.push_memory_backlog(message) if @memory_extractor && @memory.enabled?

        [ turn, cron_results ]
      end
    end
  end
end
