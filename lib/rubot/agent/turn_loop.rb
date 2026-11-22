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

      # Everything that happens once the last round is over: the assistant's
      # closing text is stored, a truncated answer says it was cut off, cron
      # output and the stop notice are folded in ahead of the answer, and a turn
      # that produced nothing at all still gets a summary rather than silence.
      #
      # Returns the text the channel delivers.
      def finish_turn(turn, cron_results:, response:, reasoning_content:, on_stopped: nil)
        # Add final assistant response to session (only if not already added via tool-call branch).
        # A silent tool's answer is the UI it produced, so no assistant text is
        # stored — and no fallback summary is invented for it either.
        @session.add("assistant", response, reasoning_content: reasoning_content) if !turn.stopped && !response.to_s.empty?

        # Ran out of continuations: say so rather than ending mid-sentence with
        # no explanation.
        if turn.truncated && !turn.answer.to_s.strip.empty?
          turn.answer << "\n\n[the model's answer was cut off at the output limit — " \
                    "reply \"continue\" to get the rest]"
        end

        # Prepend cron results to the user's response
        # Skip inline processing if a callback is registered (Telegram handles it)
        parts = []
        cron_tool = @tools.get("cron")
        has_callback = cron_tool && cron_tool.respond_to?(:has_fire_callback?) && cron_tool.has_fire_callback?

        unless has_callback || turn.stopped
          cron_results.each do |cr|
            warn "[cron] Processing job #{cr[:job_id]} mode=#{cr[:mode]}" if Rubot.debug?
            case cr[:mode]
            when "agent_turn"
              cron_response = process_cron(cr[:result][:agent_message])
              warn "[cron] agent_turn response: #{(cron_response || '(nil)')[0..100]}" if Rubot.debug?
              parts << cron_response if cron_response && !cron_response.empty?
            when "deliver"
              warn "[cron] deliver message: #{(cr[:result][:deliver_message] || '(nil)')[0..100]}" if Rubot.debug?
              parts << cr[:result][:deliver_message]
            when "command"
              output = cr[:result][:output] || "(no output)"
              warn "[cron] command output: #{output[0..100]}" if Rubot.debug?
              parts << "⏰ Cron job fired: #{cr[:result][:output]}"
            end
          end
        end

        on_stopped&.call if turn.stopped

        if turn.stopped
          turn.answer << "\n\n" unless turn.answer.empty?
          turn.answer << STOP_NOTICE
        end

        parts << turn.answer if turn.answer && !turn.answer.empty?

        combined = parts.join("\n\n---\n\n")

        # Guard: if the LLM produced only tool calls with no text content
        # (e.g. read_file → grep → etc.), return the cron/tool summary or
        # a fallback so the user never gets a silent drop.
        if combined.empty? && !turn.silent_answer
          fallback = build_fallback_response(turn.rounds, tool_rounds: turn.tool_rounds)
          combined = fallback if fallback && !fallback.empty?
        end

        # Say so when the run was cut short, instead of stopping silently. The
        # wording matters here: this limit is a net under a runaway loop, so the
        # reader is told what was done and what is left, not handed homework.
        if turn.limit_hit
          notice = "⚠️ Turn stopped after #{turn.limit} rounds without finishing. " \
                   "Say \"lanjut\" to carry on from here — the work so far is saved."
          combined = combined.empty? ? notice : "#{combined}\n\n#{notice}"
        end

        warn "[cron] Combined response (#{parts.size} parts): #{combined[0..200]}" if Rubot.debug?
        combined
      end
    end
  end
end
