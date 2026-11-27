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
      def prepare_turn(message, callbacks)
        # Fire any due cron jobs and collect their results
        cron_results = fire_due_cron_jobs
        warn "[cron] fire_due_cron_jobs returned #{cron_results.size} result(s)" if Rubot.debug?

        # This turn can now be stopped with /stop (or Ctrl+C in the REPL).
        @cancellation.start!
        Thread.current[:rubot_cancellation] = @cancellation
        turn = Turn.new(limit: turn_round_limit, close_out: loop_iteration_session?)
        # A cap reported by an earlier turn must not be read as this one's: the
        # reader of the answer looks here to write down what stopped it.
        @last_round_cap = nil
        @last_context_ceiling = nil
        # The tool registry is shared across sessions, so the persona that owns
        # this turn has to be stamped on it now — not at boot, where a second
        # persona's actor would silently overwrite the first one's scope.
        inject_tool_persona
        inject_tool_delegate
        @subagent_count = 0
        @on_subagent = callbacks.subagent
        @on_delegate = callbacks.delegate
        @on_loop = callbacks.on_loop
        @on_compaction = callbacks.compaction
        @on_compaction_start = callbacks.compaction_start
        @on_compaction_failed = callbacks.compaction_failed

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
      def finish_turn(turn, callbacks, cron_results:, response:, reasoning_content:)
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

        callbacks.stopped&.call if turn.stopped

        if turn.stopped
          turn.answer << "\n\n" unless turn.answer.empty?
          turn.answer << STOP_NOTICE
        end

        # The other ceiling an iteration can reach: the transcript got too big to
        # send again. It stopped before the request rather than after it, so the
        # notice is the only thing the turn has to say -- and it says the number,
        # because the next reading of the loop starts from it.
        if @last_context_ceiling
          turn.answer << "\n\n" unless turn.answer.empty?
          turn.answer << "⚠️ The iteration stopped at its context ceiling " \
                         "(#{@last_context_ceiling[:tokens]} of #{@last_context_ceiling[:limit]} tokens) " \
                         "instead of re-sending it. What it produced is committed, and the next " \
                         "iteration starts from a fresh context."
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
        # reader is told what was done and what is left, not handed homework. A
        # loop iteration's cap is not that net: it is the iteration's own
        # ceiling, and "lanjut" is not the word for a loop that asks again by
        # itself.
        if turn.limit_hit
          # What the loop's log needs to know: the iteration stopped at its cap,
          # not on its own. Two numbers rather than a sentence, because the entry
          # has its own line to write. A turn outside a loop keeps the wording it
          # always had, so its channels read the same text as before.
          @last_round_cap = { rounds: turn.rounds, limit: turn.limit } if turn.close_out?
          notice = if turn.close_out?
            "⚠️ The iteration stopped at its round cap (#{turn.limit}) and reported " \
              "where it got. The next iteration continues from here."
          else
            "⚠️ Turn stopped after #{turn.limit} rounds without finishing. " \
              "Say \"lanjut\" to carry on from here — the work so far is saved."
          end
          combined = combined.empty? ? notice : "#{combined}\n\n#{notice}"
        end

        warn "[cron] Combined response (#{parts.size} parts): #{combined[0..200]}" if Rubot.debug?
        combined
      end

      # The rounds of one turn: ask the provider, run the calls it asked for,
      # and decide whether to ask again. Every way a round can end lives in this
      # loop, which is why it moved last: the count of provider requests and the
      # order of the callbacks are what a channel sees, and nothing else in the
      # turn is allowed to move them.
      #
      # Returns [response, reasoning_content] as the last round left them, so the
      # finish phase can store the closing text.
      def run_rounds(turn, callbacks, stream: true, &on_chunk)
        response = ""
        tool_calls = nil
        reasoning_content = nil

        finish_reason = nil

        loop do
          if turn.exhausted?
            turn.limit_hit = true
            # A loop iteration's cap is a ceiling on cost, not a guillotine. The
            # agent gets one last round with no tools to say where it stopped,
            # which is what makes the next iteration start from a report instead
            # of from a call that was cut off halfway. An ordinary turn keeps the
            # hard stop: its reader is waiting, and it is told so below.
            if turn.close_out? && !turn.closed_out
              turn.closed_out = true
              response, reasoning_content = close_out_round(turn, callbacks, stream: stream, &on_chunk)
            end
            break
          end

          # The other ceiling an iteration has: its context. Checked before the
          # request leaves, so the stop costs nothing -- the opposite of the
          # auto-compaction an iteration no longer buys, which paid for a
          # summary and then rewrote the prefix the rest of the turn was still
          # hitting. A loop's work is committed by the run that reads the
          # answer, so stopping here keeps what was made and drops only the
          # request that would have re-sent it.
          break if context_ceiling_reached?

          # Steering, a stop, and the compaction that may call the provider all
          # happen here, between rounds. Any of them can end the turn.
          break if round_blocked?(turn, callbacks)

          messages = build_messages
          log_debug("Sending #{messages.size} messages to provider")

          # The request is about to leave. Its input size is best estimated from
          # the last measured usage plus everything appended since — the same
          # figure /context shows — so the context number starts from an anchor
          # instead of a guess that would jump backwards when usage lands.
          live = { prompt_tokens: context_usage[:tokens], output_tokens: 0 }
          emit_usage(callbacks.usage, live: live)

          response, result = begin
            ask_provider(messages, callbacks, response: response, live: live,
                         stream: stream, &on_chunk)
          rescue Cancelled
            # The user stopped the turn while the provider was answering. The
            # partial answer is discarded, exactly as when the stop lands after
            # the response arrived.
            turn.stopped = true
            break
          end

          record_usage(result, messages: messages)
          # The moment this request's tokens land, cost, cache and context have
          # moved. Publishing here, not at the end of the turn, is what lets a
          # channel show live figures while the turn is still running.
          emit_usage(callbacks.usage)

          # Parse result — both streaming and non-streaming now return Hash
          response, tool_calls, reasoning_content, finish_reason =
            read_result(result, turn, response, finish_reason)

          if turn.truncated
            warn "[agent] answer truncated (finish_reason=#{finish_reason.inspect}); " \
                 "#{turn.continuations}/#{MAX_CONTINUATIONS} continuations used"
          end

          # The user may have stopped the turn while the provider was thinking.
          # The late answer is discarded so the channel reports the stop instead.
          if @cancellation.cancelled?
            turn.stopped = true
            break
          end

          # Handle tool calls
          if tool_calls && !tool_calls.empty?
            stop = run_tools(turn, callbacks, tool_calls: tool_calls, response: response,
                             reasoning_content: reasoning_content)
            response = ""
            tool_calls = nil
            break if stop
          elsif response.to_s.strip.empty? && !turn.reasked
            # Nothing the user can read came back. With tools in play that means
            # the model stopped without reporting; with none it means the output
            # budget went to hidden reasoning. Either way, ask once for the
            # answer instead of substituting a summary of tool output.
            turn.reasked = true
            warn "[agent] empty answer after #{turn.rounds} round(s); asking again"
            @session.add("user", turn.rounds.positive? ? ANSWER_NOW_PROMPT : EMPTY_ANSWER_PROMPT)
            turn.rounds += 1
          elsif turn.truncated && !response.to_s.strip.empty? && turn.continuations < MAX_CONTINUATIONS
            # The answer is a fragment. Keep it, ask for the rest, and rejoin.
            turn.answer << response
            @session.add("assistant", response, reasoning_content: reasoning_content)
            @session.add("user", CONTINUE_PROMPT)
            turn.continuations += 1
            turn.rounds += 1
            finish_reason = nil
          else
            # No tool calls — but the user may have steered the turn while this
            # answer was streaming. The answer stands as its own message and
            # the steer gets the next round.
            if steering_pending?
              turn.answer << response
              turn.answer << "\n\n" unless response.to_s.strip.empty?
              @session.add("assistant", response, reasoning_content: reasoning_content)
              response = ""
              reasoning_content = nil
              turn.rounds += 1
              next
            end

            # No tool calls, we're done
            turn.answer << response
            break
          end
        end

        [ response, reasoning_content ]
      end

      # What happens between two rounds, when nothing has been asked of the
      # provider yet. Returns true when the turn has to stop.
      #
      # Steering: text the user typed while this turn was running. It is
      # delivered after the previous round's tool calls and before this round's
      # provider call, so it can redirect work already in flight.
      def round_blocked?(turn, callbacks)
        steer = take_steering
        if steer
          @session.add("user", steer)
          callbacks.steer&.call(steer)
        end

        # Stop before starting another round (another provider call or more tool
        # executions) once the user has asked us to.
        if @cancellation.cancelled?
          turn.stopped = true
          return true
        end

        # Adaptive: compact the transcript when it crosses the configured share
        # of the model's context window. Compaction calls the provider, so a
        # stop during it unwinds here like any other provider call.
        begin
          run_auto_compaction
        rescue Cancelled
          turn.stopped = true
          return true
        end
        false
      end

      # Whether this round would re-send a transcript past the iteration's own
      # ceiling. Only a loop iteration has one, and only a measured figure
      # counts: before the first request nothing has been priced (an estimate of
      # the system prompt is not a context), and after it the anchor plus
      # everything appended since is what the next request would carry.
      #
      # No closing round is bought here, which is the difference from the round
      # cap: a closing round is one more request carrying exactly the context
      # this ceiling exists to stop paying for. The work is committed by the run,
      # and the notice says where the iteration stopped.
      def context_ceiling_reached?
        return false unless loop_iteration_session?
        return false unless @session.context_anchored?

        ceiling = loop_max_context_tokens
        used = context_usage[:tokens].to_i
        return false unless ceiling.positive? && used >= ceiling

        @last_context_ceiling = { tokens: used, limit: ceiling }
        true
      end

      # The one round an iteration gets after its cap: no tools, one question,
      # and the answer is the turn's closing text. It is a request like any
      # other -- measured and published like one -- but it does not count towards
      # the cap, because it is the chance to stop cleanly rather than to work. A
      # stop that lands while it runs unwinds like every other provider call, and
      # the turn reports itself stopped instead.
      def close_out_round(turn, callbacks, stream:, &on_chunk)
        messages = build_messages
        messages << { "role" => "user", "content" => LOOP_CLOSE_OUT_PROMPT }
        live = { prompt_tokens: context_usage[:tokens], output_tokens: 0 }
        emit_usage(callbacks.usage, live: live)

        response, result = begin
          ask_provider(messages, callbacks, response: "", live: live, stream: stream, tools: [], &on_chunk)
        rescue Cancelled
          turn.stopped = true
          return [ "", nil ]
        end

        record_usage(result, messages: messages)
        emit_usage(callbacks.usage)
        response, _tool_calls, reasoning_content, _finish_reason =
          read_result(result, turn, response, nil)
        # The closing text is the turn's answer: the channel is handed the
        # iteration's own report, not a fallback invented because no normal
        # round had anything to say.
        turn.answer << response unless turn.stopped || response.to_s.empty?
        [ response, reasoning_content ]
      end

      # One provider result, in whichever of the three shapes a provider
      # returns it, read into the names the loop works with.
      def read_result(result, turn, response, finish_reason)
        tool_calls = nil
        reasoning_content = nil

        if result.is_a?(Hash)
          response = result["content"] || ""
          tool_calls = result["tool_calls"]
          reasoning_content = result["reasoning_content"]
          finish_reason = result["finish_reason"]
          turn.truncated = result["truncated"] == true
          # Some gateways close the stream without a terminator. The text is a
          # prefix of the answer even if they never said why.
          turn.truncated ||= result["stream_incomplete"] == true && !response.to_s.empty?
        elsif result.is_a?(Array)
          # Legacy streaming format: [content, tool_calls]
          response, tool_calls = result
          finish_reason = nil
          turn.truncated = false
        else
          response = result.to_s
          finish_reason = nil
          turn.truncated = false
        end

        [ response, tool_calls, reasoning_content, finish_reason ]
      end
      # One round's tool calls: what may run is decided in the order the model
      # asked for it, the approved calls run together, and their results reach the
      # transcript in request order. Returns true when the turn ends here.
      def run_tools(turn, callbacks, tool_calls:, response:, reasoning_content:)
        log_debug("Got #{tool_calls.size} tool call(s)")

        # Add assistant message with tool calls to session
        @session.add("assistant", response, tool_calls: tool_calls, reasoning_content: reasoning_content)

        narrate_tool_round(callbacks, response, tool_calls)

        # Deciding what may run comes first, in the order the model asked for
        # it: the guard may ask the reader a question, and a cancelled turn
        # must stop before more work starts. Running comes after, all at once.
        pending = pending_tool_calls(turn, callbacks, tool_calls)

        # The calls were already known to the model when it sent them, so
        # none of them needs another's output: run them together and report
        # in request order, which keeps the transcript and the UI identical
        # to a sequential run.
        turn.silent_answer = false
        execute_tool_calls(pending).each do |call|
          tool_result = call[:result]
          ui_diff = file_ui_diff(call[:snapshot], tool_result)
          callbacks.tool_result&.call(call[:name], tool_result, ui_diff)

          log_debug("Tool result: #{tool_result[0..200]}")

          # A successful write carries its before/after text so the TUI can
          # rebuild the diff on /resume. The transcript gets the clipped copy:
          # the callback above already showed the full result, and every later
          # request re-sends what is written here.
          @session.add("tool", Rubot::ToolOutput.clip(tool_result, max_chars: tool_output_max_chars),
                       tool_call_id: call[:id], ui_diff: ui_diff)

          # A tool that answered with UI has nothing for the model to say.
          # End the turn here instead of asking for a reply that would only
          # restate the button the reader is already looking at.
          tool = @tools.get(call[:name])
          turn.silent_answer ||= tool && tool.respond_to?(:silent_result?) && tool.silent_result?(tool_result)
        end

        # Continue the loop to get the next response
        tool_count = tool_calls.size
        turn.rounds += 1
        turn.tool_rounds += 1

        # Fire progress callback after each round. The tool count is captured
        # before `tool_calls` is cleared so consumers get the real number.
        callbacks.progress&.call(turn.rounds, tool_count)
        # The tool results just added to the transcript are part of the next
        # request, so the context figure moves before the provider does.
        emit_usage(callbacks.usage)

        turn.stopped || turn.silent_answer
      end

      # Forward the model's narration before it runs the tools. This is the
      # assistant text that accompanies the tool calls ("Let me check the
      # structure first."); without this callback it would be swallowed by the
      # `response = ""` reset at the end of the round. A tool whose result is UI
      # (the Instagram connect card) is the exception: its card is the answer,
      # so a sentence in front of it is noise.
      def narrate_tool_round(callbacks, response, tool_calls)
        narration = response.to_s.strip
        silent_batch = tool_calls.any? do |tc|
          tool_name, args, ok = parse_tool_call(tc)
          ok && (tool = @tools.get(tool_name)) && tool.respond_to?(:silent_operation?) &&
            tool.silent_operation?(args)
        end
        callbacks.assistant_text&.call(narration) unless narration.empty? || silent_batch
      end

      # One round's calls decided in order: refused when the arguments never
      # arrived, skipped when the turn stopped or the reader said no, and
      # otherwise queued to run with the file's before-content already taken.
      def pending_tool_calls(turn, callbacks, tool_calls)
        pending = []
        tool_calls.each do |tc|
          tool_name, arguments, arguments_ok = parse_tool_call(tc)
          log_debug("Executing tool: #{tool_name}")

          # Use the tool call ID for tracking
          tool_call_id = tc.is_a?(Hash) ? (tc["id"] || tool_name) : tool_name

          # Invalid arguments would run the tool on a half-read path or
          # command (a truncated answer ends mid-JSON), so the model is told
          # to re-issue the call instead of executing an empty hash.
          unless arguments_ok
            tool_error = if turn.truncated
              "ERROR: this tool call was cut off before its arguments " \
                "finished (the answer hit the output limit). Re-issue it " \
                "with complete arguments."
            else
              "ERROR: the arguments for #{tool_name} were not a valid JSON " \
                "object. Re-issue the call with one complete JSON object."
            end
            # Kept in the pending list so its result reaches the transcript in
            # request order, next to the calls that do run.
            pending << skipped_call(tool_call_id, tool_name, tool_error)
            next
          end

          # Check for dangerous action that could cause data loss
          if @cancellation.cancelled?
            turn.stopped = true
            pending << skipped_call(tool_call_id, tool_name, CANCELLED_TOOL_RESULT)
            next
          end

          tool = @tools.get(tool_name)

          # A question is the call itself: it blocks this thread until the
          # reader answers, and the answer becomes the call's result. It is
          # asked here rather than inside the tool because the reader lives in
          # the channel and a tool cannot reach it.
          if tool_name == "ask_user"
            result = ask_the_user(tool, arguments, callbacks)
            # The row is published like any other call, so the transcript keeps
            # both halves: what was asked, and what came back.
            callbacks.tool_call&.call(tool_name, arguments, nil)
            pending << { name: tool_name, arguments: arguments, id: tool_call_id,
                         snapshot: nil, result: result }
            next
          end

          if tool && tool.respond_to?(:dangerous_action?) && tool.dangerous_action?(arguments)
            if auto_approve?
              # Auto mode: the prompt is skipped, not the guard. Destructive
              # patterns are refused inside the tool itself, so this branch
              # can only ever run something the guard already allowed.
              log_debug("Auto mode, allowing #{tool_name}: #{arguments.inspect}")
            else
              # Asking costs a second look at the file, so the reason is only
              # worked out when a question is actually going to be shown.
              reason = tool.respond_to?(:dangerous_action_reason) ? tool.dangerous_action_reason(arguments) : nil
              if callbacks.confirm && !callbacks.confirm.call(tool_name, arguments, reason)
                log_debug("Action cancelled by user: #{tool_name}")
                pending << skipped_call(tool_call_id, tool_name, "Action cancelled by user.")
                next
              end
            end
          end

          # Fire pre-execution callback. The before-content travels with it:
          # whoever renders the diff must not read the file afterwards, or a
          # fast operation (delete is one syscall) wins the race and the diff
          # has nothing to show.
          ui_snapshot = file_ui_snapshot(tool_name, arguments)
          callbacks.tool_call&.call(tool_name, arguments, ui_snapshot)

          pending << {
            name: tool_name,
            arguments: arguments,
            id: tool_call_id,
            snapshot: ui_snapshot
          }
        end
        pending
      end

      # One question, asked through the channel's reader.
      #
      # A channel that handed no reader (a background turn, a surface with
      # nowhere to ask) gets the tool's own honest answer instead of a block
      # that would never be released. Nothing here counts the questions: a
      # cancellation ends the turn, so the reader's own answer is the limit.
      def ask_the_user(tool, arguments, callbacks)
        return "Nobody can be asked on this surface." if tool.nil? || !tool.respond_to?(:ask)

        tool.ask(arguments, reader: callbacks.ask)
      end
      # One request to the provider, streamed when the channel can take chunks.
      #
      # Thinking fragments and answer chunks go out while the request is still
      # open, and the live cost figures are repainted on the way, because the
      # answer the next request will carry grows with every chunk.
      #
      # Returns [response, result]: the answer as far as it has arrived (a
      # truncated answer keeps appending across continuations) and whatever the
      # provider returned for the caller to parse.
      def ask_provider(messages, callbacks, response:, live:, stream:, tools: tool_definitions, &on_chunk)
        result = if block_given? && stream
          live_chars = 0
          live_emitted_at = 0.0
          @provider.chat_stream(messages, tools: tools, on_retry: callbacks.retry_callback) do |chunk, tool_data, reasoning|
            # Thinking arrives before (and between) answer chunks; the answer
            # itself is never delayed by it.
            callbacks.reasoning&.call(reasoning) if reasoning && !reasoning.empty?
            response += chunk if chunk
            if chunk && !chunk.empty?
              # The answer is arriving, so the output side of the cost and
              # the answer the next request will carry both grow now. Rate
              # limited: repainting faster than the eye (or the event pump)
              # can follow would be noise, not freshness.
              live_chars += chunk.length
              live[:output_tokens] = (live_chars / Session::CHARS_PER_TOKEN).ceil
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              if now - live_emitted_at >= LIVE_USAGE_INTERVAL
                live_emitted_at = now
                emit_usage(callbacks.usage, live: live)
              end
            end
            yield chunk if chunk && block_given?
          end
        else
          @provider.chat(messages, tools: tools, on_retry: callbacks.retry_callback)
        end

        [ response, result ]
      end
    end
  end
end
