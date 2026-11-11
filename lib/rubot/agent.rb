# frozen_string_literal: true

require "json"
require "digest"
require_relative "cancellation"
require_relative "config"
require_relative "model_info"
require_relative "model_catalog"
require_relative "opencode_usage"
require_relative "persona"
require_relative "pricing_catalog"
require_relative "session"
require_relative "usage"
require_relative "provider"
require_relative "tools/registry"
require_relative "safety_guard"
require_relative "soul"
require_relative "memory"
require_relative "agents_file"
require_relative "tools/memory_tool"
require_relative "memory_extractor"
require_relative "tools/feedback_learner"

module Rubot
  class Agent
    # How many times one turn may ask the model to carry on after the provider
    # cut its answer off at the output budget. Each continuation buys another
    # `max_tokens` worth of text, and only ever fires when the provider really
    # did truncate — so a generous number costs nothing on ordinary answers and
    # stops a long one from ending mid-sentence. Two was too few: a written
    # document at 16k output tokens needs three or four requests, and at two the
    # reader got a notice and a "continue" they had to type.
    MAX_CONTINUATIONS = 4

    # How often a turn in flight may publish provisional cost/context figures.
    # Five times a second keeps the footer moving without turning every
    # streamed chunk into an event the UI has to drain.
    LIVE_USAGE_INTERVAL = 0.2

    # Tool results kept verbatim in the request. Everything older is shortened:
    # a tool-heavy turn re-sends its entire stdout on every round, and the
    # model rarely needs the full log of a command it already acted on.
    # The session file still keeps the complete output; only the request is
    # trimmed, so nothing is lost for a later turn that needs to re-read it.
    TRUNCATED_TOOL_RESULT_NOTICE = "\n... [older tool output truncated; re-run the command if you still need it]"

    # Appended to an oversized argument value of an old tool call after its

    # first `tool_result_max_chars` characters. The count tells the model what

    # it is missing without ever sending the body again.

    REDACTED_TOOL_CALL_ARGS_NOTICE = "\n... [%d chars of this old tool call's argument redacted; re-run the tool if you still need them]"

    # Sent after a truncated answer. It has to be explicit about *not*
    # restarting: a model asked to "continue" will otherwise begin again at
    # the first sentence.
    # Frozen because it is read inside session Ractors: a non-shareable
    # constant raises Ractor::IsolationError there, which used to kill
    # post-answer learning (memory extraction and feedback) on every turn.
    CONTINUE_PROMPT = <<~PROMPT.strip.freeze
      Your previous message was cut off mid-sentence because it reached the
      output limit. Continue exactly where it stopped, starting with the
      remaining words of the interrupted sentence. Do not repeat anything you
      already wrote, do not start over, and do not add a preamble.
    PROMPT

    # Sent when the model finished a tool round without saying anything at all,
    # which leaves the user with silence and no images or files.
    #
    # It names both file tools on purpose. It used to name send_file alone, and
    # a batch of five pictures then arrived as five separate calls: the model
    # followed the one tool this sentence mentioned rather than the one meant
    # for a batch.
    ANSWER_NOW_PROMPT = <<~PROMPT.strip.freeze
      You ran the tools above but produced no answer. Using their results,
      reply to the user now, in the user's language. If they asked for files or
      images, send them before you finish: send_files for several in one call,
      send_file for one on its own.
    PROMPT

    # Sent when a reply came back with no visible text at all — on a reasoning
    # model the whole output budget can go to the hidden reasoning, leaving an
    # empty `content`. Nothing was sent to the user, so it is asked again.
    EMPTY_ANSWER_PROMPT = <<~PROMPT.strip.freeze
      Your previous reply contained no text the user could read (the output
      budget was spent before any of it was written). Answer the user's last
      message now, directly and as briefly as the question allows.
    PROMPT

    # Recorded for tool calls that were never run because the user stopped the
    # turn. The provider requires exactly one result per tool call, so the
    # skipped calls still get an answer in the transcript.
    CANCELLED_TOOL_RESULT = "ERROR: cancelled by user (/stop); this tool was not executed."

    # How many of one assistant message's tool calls run at the same time. A
    # batch is normally two or three reads; the cap only keeps a runaway batch
    # from opening one process per call.
    MAX_PARALLEL_TOOLS = 4

    # Before/after text kept on a write's tool message so the TUI can redraw
    # its diff when the session is resumed. Skipped for very large files: the
    # session file should not grow by a megabyte for one write.
    MAX_UI_DIFF_CHARS = 120_000

    # Cap on the original task statement injected into the system prompt. A
    # huge pasted request should not crowd out the transcript on every round.
    MAX_TASK_CHARS = 6_000

    # Appended to the answer when a turn is stopped early.
    STOP_NOTICE = "⏹️ Stopped by user."

    attr_reader :config, :provider, :session, :tools, :soul, :memory, :agents_file, :skill_registry, :safety_guard, :session_model, :persona, :active_preset_name

    # Cancellation token for the turn currently running on this agent. The
    # session actor swaps in the token its watcher thread listens on.
    attr_accessor :cancellation

    def initialize(config:, provider: nil, session_id: "default", tools: nil, persona: nil,
                   archive: nil)
      @config = config
      # Handle on the SQLite archive (see StoreClient). nil means the session
      # keeps living in its JSON file — the fallback when the archive cannot be
      # opened.
      @archive = archive
      @cancellation = Cancellation.new
      # Text the user typed while a turn was already running (TUI steering).
      # The turn consumes it between rounds; a mutex keeps the reader thread
      # from tearing the list that the turn thread is draining.
      @steering = []
      @steering_mutex = Mutex.new
      @persona = Persona.from(persona)
      # Auto mode: the preference lives in config.yml and is remembered across
      # launches; the setter writes it back.
      @auto_approve = config.respond_to?(:auto_approve) ? config.auto_approve : false
      @session = Session.new(session_id, workspace: config.workspace,
                                         sessions_dir: session_dir_for(config),
                                         cwd: session_cwd_for(config),
                                         max_messages: config.session_max_messages,
                                         archive: @archive)
      apply_initial_preset!
      @provider = provider || build_provider(preset: @active_preset, effort: thinking_level)

      # Build safety guard from config
      @safety_guard = SafetyGuard.new(
        workspace: config.workspace,
        restrict_to_workspace: config.restrict_to_workspace,
        allow_read_outside: config.allow_read_outside_workspace
      )

      @tools = tools || Tools::Registry.new
      # Always inject safety guard into tools, even when passed from outside
      inject_safety_guard

      # Warn if safety guard is disabled
      unless @safety_guard.restrict_to_workspace
        warn "[safety] WARNING: restrict_to_workspace is DISABLED — agent has full system access"
        warn "[safety] Set restrict_to_workspace: true in config.yml to enable sandboxing"
      else
        mode = @safety_guard.allow_read_outside ? "restrict-write" : "strict"
        warn "[safety] Safety guard ENABLED (mode: #{mode}, workspace: #{@safety_guard.workspace})"
      end

      # Identity, memory, rules and skills come from the configured workspace,
      # even when the channel re-roots the working directory (the TUI takes the
      # directory it was launched from). Otherwise launching in a project would
      # silently drop all of them.
      assets = config.assets_workspace
      @soul = Soul.new(workspace: assets)
      @memory = build_memory(config)
      # AGENTS.md is project rules, so a file in the working directory wins;
      # the configured workspace's copy is the fallback (and is what the
      # Telegram bot always uses, since its workspace is that directory).
      @agents_file = AgentsFile.new(workspace: agents_workspace(config, assets))
      # Skills stay in the configured workspace even when the agent works out
      # of a persona's directory: copying a skills tree into every persona
      # would mean maintaining one copy per specialist.
      @skill_registry = SkillRegistry.new(workspace: config.skills_workspace)
      config.ensure_workspace

      # Register the memory tool so the bot can manage its own memory
      @tools.register(Tools::MemoryTool.new(@memory)) if @memory.enabled?

      # Adaptive features (always on)
      @memory_extractor = MemoryExtractor.new(provider: @provider, memory: @memory)
      @feedback_learner = Tools::FeedbackLearner.new(memory: @memory)

      # Apply AGENTS.md overrides to config
      apply_agents_overrides if @agents_file.enabled?

      # Set workspace on cron tool so jobs persist to disk
      configure_cron_tool
      @cron_ractor = nil
    end

    # Attach a CronActor handle. When present, cron jobs are owned by the
    # actor and this agent no longer fires them inline.
    def cron_ractor=(ractor)
      @cron_ractor = ractor
      cron_tool = @tools.get("cron")
      cron_tool.cron_actor = ractor if cron_tool.respond_to?(:cron_actor=)
    end

    # Create a new Agent instance with a different session but sharing
    # the same config, tools, and all shared resources.
    # This enables concurrent request processing without cross-session
    # interference — each request gets an isolated session on its
    # own agent instance.
    def for_session(session_id, persona: :inherit)
      selected_persona = persona == :inherit ? @persona : persona
      # Let Agent.new handle session loading and provider building correctly.
      # Do NOT override @provider — it was already set up for this session.
      copy = Agent.new(
        config: @config,
        session_id: session_id,
        tools: @tools,
        persona: selected_persona
      )
      # Share stateless/shared resources only (skip @provider, which
      # Agent#new already built correctly for the target session)
      copy.instance_variable_set(:@safety_guard, @safety_guard)
      copy.instance_variable_set(:@soul, @soul)
      copy.instance_variable_set(:@memory, @memory)
      copy.instance_variable_set(:@agents_file, @agents_file)
      copy.instance_variable_set(:@skill_registry, @skill_registry)
      copy.instance_variable_set(:@memory_extractor, @memory_extractor)
      copy.instance_variable_set(:@feedback_learner, @feedback_learner)
      copy
    end

    # Process a user message and return the final assistant response.
    # Due cron jobs are fired first, their output prepended to the response.
    #
    # Callbacks (optional):
    #   on_tool_call:     Called before each tool executes. Yields (tool_name, arguments,
    #                     ui_snapshot) — the file's before-content when this call is
    #                     about to change a file, nil otherwise. Taken here, inside
    #                     whatever thread or Ractor runs the tool, because a caller
    #                     that reads the file after hearing about the call is racing
    #                     the tool: a delete finishes before the snapshot is taken.
    #   on_tool_result:   Called after each tool executes. Yields (tool_name, result,
    #                     ui_diff) — { "path", "before", "after" } for a file that
    #                     changed, nil otherwise. Both payloads travel with the
    #                     event so a channel only has to render them.
    #   on_progress:      Called after each full round. Yields (round_count, tool_count).
    #   on_usage:         Called with fresh usage report data as soon as a request's
    #                     tokens are recorded and after every round's tool results,
    #                     so a channel can update cost/cache/context mid-turn.
    #   on_confirm:       Called before dangerous actions that could cause data loss.
    #                     Yields (tool_name, arguments, reason) — reason is a
    #                     short phrase like "deletes files" or "overwrite
    #                     build.log — 412 of 900 lines would be lost", or nil
    #                     when the tool has no better description. Return
    #                     truthy to proceed, falsy to skip. Not called at all in
    #                     auto mode.
    #   on_assistant_text: Called with the model's own words whenever it replies
    #                     with text *and* tool calls (progress narration, e.g.
    #                     "Let me check the structure first."). Channels forward
    #                     this to the user as a regular message while work continues.
    #                     Yields (text).
    #   on_stopped:       Called once when the turn ended because the user
    #                     stopped it, before the stop notice is appended.
    #   on_steer:         Called with a message the user queued while the turn
    #                     was running, at the moment it is handed to the model.
    #   on_reasoning:     Called with each fragment of the model's thinking as
    #                     it streams in, before the answer starts. Channels use
    #                     it to show a live "thinking" block; nothing is called
    #                     for a model that does not stream its reasoning.
    def process(message, on_tool_call: nil, on_tool_result: nil, on_progress: nil, on_confirm: nil,
                on_assistant_text: nil, on_reasoning: nil, on_steer: nil, on_stopped: nil, on_usage: nil,
                stream: true, &on_chunk)
      # Fire any due cron jobs and collect their results
      cron_results = fire_due_cron_jobs
      warn "[cron] fire_due_cron_jobs returned #{cron_results.size} result(s)" if Rubot.debug?

      # This turn can now be stopped with /stop (or Ctrl+C in the REPL).
      @cancellation.start!
      Thread.current[:rubot_cancellation] = @cancellation
      stopped = false

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

      response = ""
      tool_calls = nil
      reasoning_content = nil
      rounds = 0
      limit = max_rounds
      limit_hit = false

      # The turn's answer, assembled across continuations. `response` only ever
      # holds the newest fragment; this holds all of them.
      answer = +""
      tool_rounds = 0
      continuations = 0
      reasked = false
      truncated = false
      finish_reason = nil

      loop do
        if rounds >= limit
          limit_hit = true
          break
        end

        # Steering: text the user typed while this turn was running. It is
        # delivered after the previous round's tool calls and before this
        # round's provider call, so it can redirect work already in flight.
        steer = take_steering
        if steer
          @session.add("user", steer)
          on_steer&.call(steer)
        end

        # Stop before starting another round (another provider call or more
        # tool executions) once the user has asked us to.
        if @cancellation.cancelled?
          stopped = true
          break
        end

        # Adaptive: compact the transcript when it crosses the configured
        # share of the model's context window. Compaction calls the provider,
        # so a stop during it unwinds here like any other provider call.
        begin
          run_auto_compaction
        rescue Cancelled
          stopped = true
          break
        end

        messages = build_messages
        log_debug("Sending #{messages.size} messages to provider")

        # The request is about to leave. Its input size is best estimated from
        # the last measured usage plus everything appended since — the same
        # figure /context shows — so the context number starts from an anchor
        # instead of a guess that would jump backwards when usage lands.
        live = { prompt_tokens: context_usage[:tokens], output_tokens: 0 }
        emit_usage(on_usage, live: live)

        result = begin
          if block_given? && stream
            live_chars = 0
            live_emitted_at = 0.0
            @provider.chat_stream(messages, tools: tool_definitions) do |chunk, tool_data, reasoning|
              # Thinking arrives before (and between) answer chunks; the answer
              # itself is never delayed by it.
              on_reasoning&.call(reasoning) if reasoning && !reasoning.empty?
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
                  emit_usage(on_usage, live: live)
                end
              end
              yield chunk if chunk && block_given?
            end
          else
            @provider.chat(messages, tools: tool_definitions)
          end
        rescue Cancelled
          # The user stopped the turn while the provider was answering. The
          # partial answer is discarded, exactly as when the stop lands after
          # the response arrived.
          stopped = true
          break
        end

        record_usage(result, messages: messages)
        # The moment this request's tokens land, cost, cache and context have
        # moved. Publishing here, not at the end of the turn, is what lets a
        # channel show live figures while the turn is still running.
        emit_usage(on_usage)

        # Parse result — both streaming and non-streaming now return Hash
        if result.is_a?(Hash)
          response = result["content"] || ""
          tool_calls = result["tool_calls"]
          reasoning_content = result["reasoning_content"]
          finish_reason = result["finish_reason"]
          truncated = result["truncated"] == true
          # Some gateways close the stream without a terminator. The text is a
          # prefix of the answer even if they never said why.
          truncated ||= result["stream_incomplete"] == true && !response.to_s.empty?
        elsif result.is_a?(Array)
          # Legacy streaming format: [content, tool_calls]
          response, tool_calls = result
          reasoning_content = nil
          finish_reason = nil
          truncated = false
        else
          response = result.to_s
          tool_calls = nil
          reasoning_content = nil
          finish_reason = nil
          truncated = false
        end

        if truncated
          warn "[agent] answer truncated (finish_reason=#{finish_reason.inspect}); " \
               "#{continuations}/#{MAX_CONTINUATIONS} continuations used"
        end

        # The user may have stopped the turn while the provider was thinking.
        # The late answer is discarded so the channel reports the stop instead.
        if @cancellation.cancelled?
          stopped = true
          break
        end

        # Handle tool calls
        if tool_calls && !tool_calls.empty?
          log_debug("Got #{tool_calls.size} tool call(s)")

          # Add assistant message with tool calls to session
          @session.add("assistant", response, tool_calls: tool_calls, reasoning_content: reasoning_content)

          # Forward the model's narration before it runs the tools. This is the
          # assistant text that accompanies the tool calls ("Let me check the
          # structure first."); without this callback it would be swallowed by
          # the `response = ""` reset at the end of the round.
          narration = response.to_s.strip
          on_assistant_text&.call(narration) unless narration.empty?

          # Deciding what may run comes first, in the order the model asked for
          # it: the guard may ask the reader a question, and a cancelled turn
          # must stop before more work starts. Running comes after, all at once.
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
              tool_error = if truncated
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
              stopped = true
              pending << skipped_call(tool_call_id, tool_name, CANCELLED_TOOL_RESULT)
              next
            end

            tool = @tools.get(tool_name)
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
                if on_confirm && !on_confirm.call(tool_name, arguments, reason)
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
            on_tool_call&.call(tool_name, arguments, ui_snapshot)

            pending << {
              name: tool_name,
              arguments: arguments,
              id: tool_call_id,
              snapshot: ui_snapshot
            }
          end

          # The calls were already known to the model when it sent them, so
          # none of them needs another's output: run them together and report
          # in request order, which keeps the transcript and the UI identical
          # to a sequential run.
          execute_tool_calls(pending).each do |call|
            tool_result = call[:result]
            ui_diff = file_ui_diff(call[:snapshot], tool_result)
            on_tool_result&.call(call[:name], tool_result, ui_diff)

            log_debug("Tool result: #{tool_result[0..200]}")

            # A successful write carries its before/after text so the TUI can
            # rebuild the diff on /resume.
            @session.add("tool", tool_result, tool_call_id: call[:id], ui_diff: ui_diff)
          end

          # Continue the loop to get the next response
          tool_count = tool_calls.size
          response = ""
          tool_calls = nil
          rounds += 1
          tool_rounds += 1

          # Fire progress callback after each round. The tool count is captured
          # before `tool_calls` is cleared so consumers get the real number.
          on_progress&.call(rounds, tool_count)
          # The tool results just added to the transcript are part of the next
          # request, so the context figure moves before the provider does.
          emit_usage(on_usage)

          break if stopped
        elsif response.to_s.strip.empty? && !reasked
          # Nothing the user can read came back. With tools in play that means
          # the model stopped without reporting; with none it means the output
          # budget went to hidden reasoning. Either way, ask once for the
          # answer instead of substituting a summary of tool output.
          reasked = true
          warn "[agent] empty answer after #{rounds} round(s); asking again"
          @session.add("user", rounds.positive? ? ANSWER_NOW_PROMPT : EMPTY_ANSWER_PROMPT)
          rounds += 1
        elsif truncated && !response.to_s.strip.empty? && continuations < MAX_CONTINUATIONS
          # The answer is a fragment. Keep it, ask for the rest, and rejoin.
          answer << response
          @session.add("assistant", response, reasoning_content: reasoning_content)
          @session.add("user", CONTINUE_PROMPT)
          continuations += 1
          rounds += 1
          finish_reason = nil
        else
          # No tool calls — but the user may have steered the turn while this
          # answer was streaming. The answer stands as its own message and
          # the steer gets the next round.
          if steering_pending?
            answer << response
            answer << "\n\n" unless response.to_s.strip.empty?
            @session.add("assistant", response, reasoning_content: reasoning_content)
            response = ""
            reasoning_content = nil
            rounds += 1
            next
          end

          # No tool calls, we're done
          answer << response
          break
        end
      end

      # Add final assistant response to session (only if not already added via tool-call branch)
      @session.add("assistant", response, reasoning_content: reasoning_content) if !stopped && !response.to_s.empty?

      # Ran out of continuations: say so rather than ending mid-sentence with
      # no explanation.
      if truncated && !answer.to_s.strip.empty?
        answer << "\n\n[the model's answer was cut off at the output limit — " \
                  "reply \"continue\" to get the rest]"
      end

      # Prepend cron results to the user's response
      # Skip inline processing if a callback is registered (Telegram handles it)
      parts = []
      cron_tool = @tools.get("cron")
      has_callback = cron_tool && cron_tool.respond_to?(:has_fire_callback?) && cron_tool.has_fire_callback?

      unless has_callback || stopped
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

      on_stopped&.call if stopped

      if stopped
        answer << "\n\n" unless answer.empty?
        answer << STOP_NOTICE
      end

      parts << answer if answer && !answer.empty?

      combined = parts.join("\n\n---\n\n")

      # Guard: if the LLM produced only tool calls with no text content
      # (e.g. read_file → grep → etc.), return the cron/tool summary or
      # a fallback so the user never gets a silent drop.
      if combined.empty?
        fallback = build_fallback_response(rounds, tool_rounds: tool_rounds)
        combined = fallback if fallback && !fallback.empty?
      end

      # Say so when the run was cut short, instead of stopping silently. The
      # wording matters here: this limit is a net under a runaway loop, so the
      # reader is told what was done and what is left, not handed homework.
      if limit_hit
        notice = "⚠️ Turn stopped after #{limit} rounds without finishing. " \
                 "Say \"lanjut\" to carry on from here — the work so far is saved."
        combined = combined.empty? ? notice : "#{combined}\n\n#{notice}"
      end

      warn "[cron] Combined response (#{parts.size} parts): #{combined[0..200]}" if Rubot.debug?
      combined
    ensure
      @cancellation.finish!
      Thread.current[:rubot_cancellation] = nil
    end

    # Ask the running turn to stop before its next provider call or tool
    # execution. Safe to call from another thread; idle agents ignore it.
    def cancel!
      @cancellation.cancel!
    end

    # Queue text for the turn that is already running, without blocking the
    # caller. It is delivered between rounds: after the current round's tool
    # calls, before the next provider call. Returns false when the message is
    # blank, so a caller can keep it in the prompt instead of losing it.
    def steer(message)
      text = message.to_s.strip
      return false if text.empty?

      @steering_mutex.synchronize { @steering << text }
      true
    end

    # Oldest queued steering message, consumed exactly once. Safe to call from
    # any thread.
    def take_steering
      @steering_mutex.synchronize { @steering.shift }
    end

    def steering_pending?
      @steering_mutex.synchronize { !@steering.empty? }
    end

    def cancelled?
      @cancellation.cancelled?
    end

    def clear_session
      @session.clear!
      # /new clears history and manual overrides. The topic's persona (and the
      # configured default preset) still apply to the new session.
      apply_initial_preset!
    end

    # Switch the current session to a named model preset. The choice is saved
    # on the session and survives actor/process restarts. A full preset hash
    # may be supplied when the caller's config snapshot is newer than ours.
    def use_model_preset(name, preset: nil)
      source = preset || @config.model_preset(name)
      return nil unless source.is_a?(Hash)

      apply_preset_source(source, name: name, session_name: name)
    end

    def active_model_preset
      return nil unless @active_preset

      @config.public_model_preset(@active_preset)
    end

    def model_presets
      @config.model_preset_names.filter_map do |name|
        preset = @config.model_preset(name)
        next unless preset

        @config.public_model_preset(preset)
      end
    end

    # Switch to a different model for the current session (legacy entry-based
    # API). Prefer #use_model_preset.
    def use_model(model_name)
      model_name = model_name.to_s.strip
      return nil if model_name.empty?

      entry = @config.model_entry_by_name(model_name)
      dynamic = entry.nil? && provider_model_id?(model_name)
      return nil if entry.nil? && !dynamic

      settings = @config.provider_settings(model_name)
      @active_preset = legacy_model_preset(model_name)
      @session_model = settings.model
      @session.model_override = model_name
      @session.model_preset = nil
      @active_preset_name = "default"
      @session.save!
      @provider = Provider.build(settings.with_effort(thinking_level))
      @session_model
    end

    # Switch the reasoning effort ("thinking level") for this session. nil or
    # "" drops the session's own choice, so the persona's default — or the
    # effort its preset carries — takes over again. The provider is rebuilt so
    # the very next request carries the new effort.
    def use_thinking(level)
      text = level.to_s.strip.downcase
      text = nil if text.empty?
      return nil if text && !Persona::THINKING_LEVELS.include?(text)

      @session.thinking_level = text
      @session.save!
      @provider = build_provider(preset: @active_preset, effort: thinking_level)
      text
    end

    # The reasoning effort this session runs on: its own choice first, then the
    # persona's default, then the effort its preset or the config carries.
    # nil means "send no effort at all", which is what the providers did before
    # the choice existed.
    def thinking_level
      @session.thinking_level || @persona&.thinking ||
        @active_preset&.dig("reasoning_effort") || @config.reasoning_effort
    end

    # The models the provider supports, from its /models catalog. The list is
    # cached (in memory and on disk), so an unreachable provider does not
    # empty the picker. Providers that cannot list models return [].
    def provider_models
      model_catalog.entries
    end

    # The memoized provider catalog.
    def model_catalog
      @model_catalog ||= ModelCatalog.new(config: @config)
    end

    # Returns the active model name (session override or config default)
    def active_model_name
      @session_model || @config.name
    end

    # Public, plain-data representation of the persona (safe to cross a
    # Ractor boundary).
    def persona_info
      @persona&.to_h
    end

    # Apply a persona to this agent. Accepts a Persona, a Hash, or nil to
    # remove the persona. Optionally accepts preset:/model:/prompt: keywords.
    # Returns the new persona as a Hash (or nil).
    def apply_persona(persona = nil, preset: nil, model: nil, prompt: nil)
      if persona.nil? && (!preset.nil? || !model.nil? || !prompt.nil?)
        persona = Persona.new(preset: preset, model: model, system_prompt: prompt)
      end

      persona = Persona.from(persona)

      if persona.nil?
        @persona = nil
        @session.model_override = nil
        @session.model_preset = nil
        apply_initial_preset!
        # The epoch below is what actually rebuilds the prompt, but the pin is
        # dropped here too: a persona change must never depend on every future
        # persona field remembering to join the fingerprint.
        @session.clear_system_prompt!
        @session.save!
        return nil
      end

      @persona = persona
      @session.model_override = nil

      if persona.preset
        source = @config.model_preset(persona.preset)
        if source
          apply_preset_source(source, name: persona.preset, session_name: persona.preset)
        else
          @session.model_preset = nil
          apply_initial_preset!
        end
      elsif persona.model
        # Backwards compatibility for personas saved with a raw model.
        @session.model_preset = nil
        model_name = persona_model_name
        if model_name
          @active_preset = legacy_model_preset(model_name)
          @active_preset_name = "default"
          @session_model = @active_preset["model"]
          @provider = build_provider(model_name)
        else
          apply_initial_preset!
        end
      else
        @session.model_preset = nil
        apply_initial_preset!
      end

      # A different persona is a different prompt, and the pin is dropped even
      # when the model it landed on happens to be the same one.
      @session.clear_system_prompt!
      @session.save!
      persona_info
    end

    alias set_persona apply_persona

    # Switch to a different session (e.g. per-topic in Telegram).
    # Applies the saved preset for that session, falling back to the topic's
    # persona or the configured default preset.
    def switch_session(session_id)
      return @session if @session.id == session_id
      @session = Session.new(session_id, workspace: @config.workspace,
                                         sessions_dir: session_dir_for(@config),
                                         cwd: session_cwd_for(@config),
                                         max_messages: @config.session_max_messages,
                                         archive: @archive)
      apply_initial_preset!
      @session
    end

    # Auto mode: run anything the safety guard allows without asking first.
    # What it skips is the question, never the guard — the destructive
    # patterns in SafetyGuard are checked inside each tool and stay refused.
    def auto_approve?
      @auto_approve == true
    end

    # Turn auto mode on or off. The choice is written to config.yml, so the
    # next launch starts in the same mode.
    def auto_approve=(value)
      @auto_approve = !!value
      @config.set_auto_approve(@auto_approve) if @config.respond_to?(:set_auto_approve)
      @auto_approve
    end

    def startup_info
      model = active_model_name
      info = {
        provider: @provider.name,
        model: model,
        tools: @tools.count,
        messages: @session.message_count
      }
      info[:model_override] = true if model != @config.name
      info[:model_preset] = @active_preset_name if @active_preset_name && @active_preset_name != "default"
      info[:soul] = "yes" if @soul.enabled?
      info[:memory] = "yes" if @memory.enabled?
      info[:agents] = "yes" if @agents_file.enabled?
      info[:persona] = (@persona.name || "yes") if @persona
      info[:safety] = @safety_guard.restrict_to_workspace ? "restricted" : "permissive"
      info[:auto_approve] = true if auto_approve?
      info[:skills] = @skill_registry.count if @skill_registry.any?
      info[:adaptive] = "memory+batched-extraction+summary+feedback"
      info
    end

    # Force a compaction of the current session transcript, regardless of the
    # automatic threshold. Used by /compact. Returns plain data so it can
    # cross a Ractor boundary, or nil when there is nothing to compact.
    def compact_session
      @session.compact!(
        provider: @provider,
        keep_recent: @config.compact_keep_recent_messages,
        system_prompt: build_system_prompt
      )
    end

    # Approximate size of the next request: transcript + system prompt. Uses
    # the latest provider usage as the anchor when it is still valid, exactly
    # like /context, so compaction and the footer agree.
    def estimated_context_tokens
      context_usage[:tokens]
    end

    # Context window of the active model, or nil when it cannot be resolved.
    def context_window_tokens
      preset = @active_preset || {}
      model_id = preset["model"] || @session_model || @config.model
      provider_name = preset["provider"] || @provider.name
      resolve_context_window(model_id, provider_name, preset)
    end

    # Token accounting and cost estimate for the current session.
    # Returns plain data (symbol keys, numbers, strings) so it can cross a
    # Ractor boundary from a SessionActor.
    #
    # `network: false` is the mid-turn path: figures that are already known,
    # without a models.dev lookup a running turn must not wait on.
    #
    # `live` carries provisional numbers for a request that has not come back
    # yet (see #process): `prompt_tokens` is the size of the request in flight
    # and `output_tokens` the answer streamed so far. They are estimates, and
    # the report says so, so a channel can show a figure that moves.
    def usage_report(network: true, live: nil)
      preset = @active_preset || {}
      model_id = preset["model"] || @session_model || @config.model
      provider_name = preset["provider"] || @provider.name

      window = resolve_context_window(model_id, provider_name, preset)
      rates, price_source = resolve_rates(model_id, provider_name, preset, network: network)
      context = context_usage
      usage = @session.usage
      last = @session.last_usage
      provisional = live.is_a?(Hash)
      live_prompt = provisional ? live[:prompt_tokens].to_i : 0
      live_output = provisional ? live[:output_tokens].to_i : 0

      # What the next request will carry while this one is still streaming:
      # the request that just went out plus the answer arriving now.
      if provisional
        context = { tokens: live_prompt + live_output, anchored: context[:anchored] }
      end

      {
        model: active_model_name,
        model_id: model_id,
        provider: provider_name,
        context_used: context[:tokens],
        context_anchored: context[:anchored],
        context_window: window,
        context_percent: window.to_i.positive? ? context[:tokens].to_f / window * 100 : nil,
        messages: @session.message_count,
        requests: usage.requests,
        # While a request is in flight its tokens are not measured yet; the
        # provisional ones are added on top of what the session has recorded.
        prompt_tokens: usage.prompt_tokens + live_prompt,
        completion_tokens: usage.completion_tokens + live_output,
        cached_tokens: usage.cached_tokens,
        cache_creation_tokens: usage.cache_creation_tokens,
        # Like Pi, the headline cache figure describes the latest request, not
        # the session total: that is what shows whether the cache is working
        # now instead of on average since the conversation started.
        cache_hit_rate: last.requests.positive? ? last.cache_hit_rate : 0.0,
        # The session-wide share, published next to the latest-request one
        # because the cost beside them is cumulative. A lone "cache 4%" under a
        # $2 total reads as a contradiction; the pair shows the history that
        # produced the bill and the request that is running now.
        cache_hit_rate_session: usage.requests.positive? ? usage.cache_hit_rate : 0.0,
        # Cache share of the last few requests, oldest first. A run of zeros is
        # the signature of a prefix that moves on every request; a single zero
        # after a compaction is expected. Without this a reader can only see the
        # latest request and has to guess which one it is looking at.
        cache_history: @session.cache_history.dup,
        last_prompt_tokens: last.prompt_tokens,
        total_tokens: usage.total_tokens + live_prompt + live_output,
        # Priced per request when it was recorded, so switching model mid-way
        # does not re-price earlier turns. Legacy session files have no stored
        # cost; price their totals with the current rates instead. A total that
        # missed a request (no rates yet on the first turn) is re-priced too.
        # The session's cost hash is mutated in place on every request, so a
        # report hands out a copy: a caller that keeps an earlier figure (the
        # live footer does) must not see it change underneath.
        cost: build_cost(usage, rates, live_prompt, live_output,
                         last.requests.positive? ? last.cache_hit_rate : 0.0),
        # True while part of the figure is estimated from a request that has
        # not returned yet. A channel can mark it instead of passing it off as
        # a measured number.
        provisional: provisional,
        price_source: price_source
      }
    end

    # Session cost, plus the in-flight request's contribution when there is
    # one. The in-flight input is priced with the previous request's cache
    # share as the assumption: prompt caching makes the prefix of a growing
    # conversation the cached part, so pricing it all as uncached would show a
    # figure that collapses the moment the real usage lands.
    def build_cost(usage, rates, live_prompt, live_output, cached_share = 0.0)
      stored = (@session.cost && !@session.cost_partial?) ? @session.cost.dup : Usage.cost(usage, rates)
      return stored if live_prompt.zero? && live_output.zero?

      live = Usage.new(prompt_tokens: live_prompt, completion_tokens: live_output,
                       cached_tokens: (live_prompt * cached_share.to_f).round)
      extra = Usage.cost(live, rates)
      return stored unless extra

      %w[input cached_input cache_creation output total].each_with_object({}) do |key, acc|
        acc[key] = stored[key].to_f + extra[key].to_f
      end
    end

    # OpenCode Go subscription allowance for the active provider. Returns plain
    # data (see OpencodeUsage) so it can cross a Ractor boundary.
    def opencode_usage
      settings = if @active_preset
        @config.provider_settings_for_preset(@active_preset)
      else
        @config.provider_settings(@session_model)
      end
      OpencodeUsage.fetch(api_base: settings.api_base, api_key: settings.api_key)
    end

    # Tell the model to narrate its progress between tool calls. Channels
    # surface that text as chat messages, so the user can follow along instead
    # of staring at a technical "running tool" status.
    # One language for everything the bot writes. Kept here (not in the
    # configurable prompt) so a per-topic persona cannot drop it.
    SCRIPTING_RULE = <<~PROMPT.strip.freeze
      # Scripting Language

      Write every script, helper, and one-off snippet in Ruby. Use
      `ruby -e '...'` for a single expression, or write a `.rb` file and run
      `ruby path/to/script.rb` for anything longer.

      Do not write new Python to get a task done, and do not install Python
      packages. Node is only for the existing JS pipelines in the mounted
      skills, not for new helper scripts.

      Python that already exists in a repository or skill (`tools/*.py`,
      `build.sh` wrappers) is the exception: run it as-is, do not port it.
    PROMPT

    NARRATION_RULE = <<~PROMPT.strip.freeze
      # Progress Narration

      Before running tools, write one short sentence in the same language as the
      user's message describing what you are about to do and why, for example
      "Let me look at the current structure first." or "Now I'll generate the image."
      Speak in terms of the task, not the tool: never mention tool names, function
      names, JSON arguments, or raw commands in these sentences. The user sees the
      sentence as a chat message while you work.

      # One Message, Every Call That Is Ready

      Every message you send costs a full round trip, and the reader waits through
      all of them. So narrate once, then issue every tool call whose arguments you
      already know in that same message: reading four files, checking three paths,
      or running two searches whose patterns are already clear is one message with
      four calls, not four messages. Call a tool alone only when its arguments
      depend on a result you do not have yet. Never split work into separate
      messages just to report progress between them.
    PROMPT

    # The same rule again, at the very end of the prompt. Placement is the
    # point: an instruction read immediately before the question is the one a
    # model follows most reliably, and this is the instruction that decides how
    # many round trips a turn costs.
    BATCH_REMINDER = <<~PROMPT.strip.freeze
      # Before You Send

      Count the tool calls you are about to make. If one of them does not need
      another's result, they belong in the same message: one message, every call
      that is already possible.
    PROMPT

    # Handing files back to the user. Kept here rather than left to the tool
    # descriptions alone: the model decides which tool to call before it reads
    # a description for guidance, and it reaches for the name it already knows.
    # A batch asked for as one instruction has to arrive as one call.
    FILE_DELIVERY_RULE = <<~PROMPT.strip.freeze
      # Sending Files

      Two tools hand files to the user. When the user asks for more than one
      file at once — "kirim 5 gambar di folder Pictures", "send the three
      reports" — use `send_files` in a single call with every path. Do not call
      `send_file` once per file: the batch is one instruction, it arrives as
      one strip, and five separate calls cost five rounds.

      `send_file` is for one file on its own. Up to ten paths fit in one
      `send_files` call; past that, send a second batch rather than falling back
      to one call per file.
    PROMPT

    # When config.yml enables `send_file` but not `send_files`. The rule above
    # would name a tool the model cannot call, which is how a batch of twelve
    # pictures used to arrive as twelve calls: the instruction pointed at the
    # batch tool while the tool list offered only the single-file one.
    FILE_DELIVERY_SINGLE_RULE = <<~PROMPT.strip.freeze
      # Sending Files

      `send_file` hands one local file to the user. Images (.png, .jpg, .jpeg,
      .webp, .gif) are delivered as pictures so they display inline; other
      files arrive as documents, and in the browser a PDF or a markdown note
      gets a card that opens in a tab.
    PROMPT

    # Editing files through the file tool, not shell. Kept here (not in the
    # configurable prompt) so a per-topic persona cannot drop it.
    FILE_EDIT_RULE = <<~PROMPT.strip.freeze
      # Editing Files

      Change an existing file with the file tool's `edit` operation: read the
      part you need, then replace an exact `old_string` with `new_string`. Use
      enough surrounding lines for `old_string` to be unique. Use `write` only
      when creating a file or genuinely rewriting all of it, and `append` to
      add to the end.

      Read with `offset`/`limit` when a file is long; the reply says which lines
      came back, so continue from there instead of re-reading the whole file.

      Avoid shell commands that edit files in place (`sed -i`, `perl -i`,
      stdout redirection into a file, `tee`). Files changed through the file
      tool are shown to the user as a before/after diff and confirmed —
      in-place shell edits bypass that review. Deleting a file goes through
      the file tool as well (`operation: delete`): its diff shows every line
      that went away, while `rm` would remove the file with nothing on screen.
      Shell is for what the file tool cannot do: searching (`grep`), renaming,
      moving, copying, and running what already exists.

      When an edit succeeds, report it briefly — which file you updated and
      what changed in one sentence — and stop there. Do not reconstruct the
      change in your reply in any form: no file contents, no +/- diff lines,
      no before/after comparison, no canned code excerpt. The terminal
      already renders the exact git-style diff under the tool row; repeating
      it just floods the chat. Only quote the few lines you are actually
      discussing.
    PROMPT

    # When a finished turn may ring the user's phone.
    #
    # The rule is the request, not the clock and not the agent's own judgement:
    # a turn ends on the screen where it was typed, so announcing one unprompted
    # only repeats what the reader already sees. The single exception is a
    # standing request — the user asking, in their own words, to be told at the
    # end of every turn — because that is a preference about their devices and
    # nothing about this particular turn can stand in for it.
    NOTIFY_RULE = <<~PROMPT.strip.freeze
      # Announcing the End of a Turn

      A turn ends where the user is already looking, so a notification nobody
      asked for tells them what is on their screen. Never call the `notify`
      tool on your own initiative — not for long work, not for work they are
      waiting on, not because a notification would be nice.

      Call it when the user asked to be told that this work is finished
      ("kabari kalau sudah kelar", "tell me when you are done"). The
      announcement carries `message` if you pass one, otherwise the opening of
      your answer, and it arrives when the turn ends.

      One request overrides this: when the user themselves asked to be
      notified at the end of every turn, call `notify` at the end of every
      turn from then on, without waiting to be asked again. Nothing else
      counts as that request.
    PROMPT

    # Build the full system prompt from all sources
    # Which delivery rule to send: the batch version only when `send_files` is
    # actually available, the single-file version when it is not, and nothing
    # at all when neither tool is enabled.
    def file_delivery_rule
      names = tool_names
      return FILE_DELIVERY_RULE if names.include?("send_files")
      return FILE_DELIVERY_SINGLE_RULE if names.include?("send_file")

      nil
    end

    # The system prompt for this request.
    #
    # Pinned for the life of the session rather than rebuilt every time (see
    # Session#system_prompt_for): it sits at the front of every request, so
    # rebuilding it meant a one-line memory edit cost a full uncached re-read
    # of the whole conversation. #compose_system_prompt does the actual work.
    def build_system_prompt
      epoch = system_prompt_epoch
      pinned = @session&.system_prompt_for(epoch)
      return pinned if pinned

      prompt = compose_system_prompt
      @session&.store_system_prompt(prompt, epoch)
      prompt
    end

    # Drop the pinned prompt so the next request builds it again.
    #
    # This is the way out of the pin, and the only one a reader has: memory
    # written since the session started, an edited skill file, a changed
    # AGENTS.md — none of them reach a running session until the epoch moves
    # (compaction, a model switch, a persona change). Asking for it costs one
    # uncached request: the prefix changes, so nothing in front of the change is
    # reusable. That is the trade, and it is why this is a deliberate request
    # rather than something that happens on every memory write.
    def repin_system_prompt
      return false unless @session

      @session.clear_system_prompt!
    end

    # Fingerprint of the inputs that must reach the model the moment they
    # change. Anything not listed here (a new memory line, an edited skill
    # file, AGENTS.md) waits for the next epoch — that delay is the price of a
    # cacheable prefix, and it is paid once instead of on every request.
    #
    # Memory being frozen for the life of a session is not a loss: memory is
    # how a fact survives into the *next* session, and inside this one the
    # transcript already carries everything that was learned from it. The one
    # moment the transcript stops carrying it is compaction, which rewrites the
    # summary and therefore moves this epoch — so the refresh lands exactly
    # when it is needed.
    def system_prompt_epoch
      {
        "model" => active_model_name.to_s,
        # The rules this build ships are an input like any other. Without them
        # here, adding the batching reminder to the code did nothing for a
        # session already running: its prompt stayed pinned to the text of the
        # older build, so the reminder was written, never sent, and the turn went
        # on making one round trip per tool call. A digest of the shipped text
        # moves the epoch when the code changes it — one uncached request per
        # session, once, which is the price of any changed prefix.
        "rules" => digest_of(shipped_rules),
        # A persona is identity, not context: switching to another one (or
        # removing it) changes who is answering, so the prompt has to move on
        # that exact request. Leaving it out meant /persona reset reported the
        # persona gone while the bot kept speaking as the old one — visible
        # whenever the new persona kept the same model, invisible when it did
        # not (the model field moved instead, by luck).
        "persona" => digest_of(persona_identity),
        # Compaction rewrites the summary that the prompt quotes verbatim.
        "summary" => digest_of(@session&.summary_text),
        "skill" => @session&.forced_skill.to_s,
        # Set from the first user message, so the pin must not survive its
        # arrival (early calls build the prompt before any message exists).
        "task" => digest_of(@session&.task_statement)
      }
    end

    # The instruction text this build appends to every prompt. Kept in one place
    # because the epoch digests it: a rule that changes in the code has to move
    # the epoch, or a session that is already running keeps answering under the
    # rules it was pinned with.
    def shipped_rules
      [ FILE_DELIVERY_RULE, FILE_DELIVERY_SINGLE_RULE, NOTIFY_RULE, BATCH_REMINDER ].join("\u0000")
    end

    # The persona parts that reach the prompt: its own instructions and the
    # skills it works with. The name is included because it is how the reader
    # is told who they are talking to — a renamed persona is another one.
    def persona_identity
      return "" unless @persona

      [@persona.name, @persona.system_prompt, Array(@persona.skills).join(",")].join("\u0000")
    end

    # Stable identity for a piece of text across restarts: String#hash is
    # salted per process and would make every launch look like a change.
    def digest_of(text)
      value = text.to_s
      return "" if value.empty?

      Digest::SHA1.hexdigest(value)
    end

    # Compose the prompt from its sources. Order is deliberate: the parts that
    # cannot change during a session come first and the volatile ones last, so
    # that when the pin does move (compaction, model switch) the provider still
    # finds a cached prefix in front of the changed block.
    def compose_system_prompt
      @skill_registry.reload!
      parts = []

      # 1. AGENTS.md rules (behavior guidelines). The file's own "# Agent
      # Rules" heading is stripped so it is not sent twice.
      if @agents_file.enabled? && !@agents_file.rules.empty?
        rules = @agents_file.rules.sub(/\A#\s+Agent Rules\s*\n+/, "")
        parts << "# Agent Rules\n\n#{rules}"
      end

      # 1b. Scripting language (Ruby for anything the bot writes itself)
      parts << SCRIPTING_RULE

      # 1c. Progress narration (channels show this to the user as messages)
      parts << NARRATION_RULE

      # 1d. File edits go through the file tool (diff view + confirmation)
      parts << FILE_EDIT_RULE

      # 1e. When a finished turn may announce itself. Only when the tool is
      # there to be called: a prompt that names a tool this agent does not
      # have is an instruction it cannot follow.
      parts << NOTIFY_RULE if tool_names.include?("notify")

      # 1e. A batch of files is one call, not one call per file. Only the
      # delivery tools this agent can actually call are named here.
      delivery_rule = file_delivery_rule
      parts << delivery_rule if delivery_rule

      # 2. SOUL.md (personality and identity). SOUL.md ships with its own
      # "# Soul" heading (see Soul::DEFAULT_SOUL), so the file's copy is
      # stripped and the prompt supplies the one heading.
      if @soul.enabled?
        soul = @soul.to_s.sub(/\A#\s+Soul\s*\n+/, "")
        parts << "# Soul\n\n#{soul}" unless soul.strip.empty?
      end

      # 2b. Persona (per Telegram forum topic, or a web specialist)
      persona_prompt = @persona&.system_prompt.to_s.strip
      unless persona_prompt.empty?
        parts << "# Persona\n\n#{persona_prompt}"
      end

      # 2c. The skills this persona exists to use. Skills themselves are shared
      # (they live in the configured workspace, not in the persona's own
      # directory), so the persona is what says which of them apply here.
      required_skills = Array(@persona&.skills)
      unless required_skills.empty?
        parts << "# Required Skills\n\nThis persona works with: #{required_skills.join(', ')}.\n" \
                 "Load them and follow them for everything in this conversation, even when the " \
                 "request looks small enough to answer without one."
      end

      # 2d. Current model identity (so the bot knows which model it's using)
      model_name = active_model_name
      model_entry = @config.model_entry_by_name(model_name) || @config.active_model_entry
      model_provider = model_entry["model"] || @config.model
      parts << "# Current Model\n\nYou are currently running as model: **#{model_name}** (#{model_provider}).\nWhen asked about which model you are, respond with: #{model_name}."

      # 2e. Default/config system prompt. A persona prompt replaces it.
      config_prompt = persona_prompt.empty? ? @config.system_prompt : ""
      parts << config_prompt unless config_prompt.empty?

      # --- Everything below is volatile: it changes while a session runs. ---

      # 3. The instruction that started this session. Stored outside the
      # transcript so the hard message trim and compaction cannot delete the
      # goal of a long, multi-step task.
      task = @session&.task_statement
      unless task.nil?
        shown = task.length > MAX_TASK_CHARS ? "#{task[0...MAX_TASK_CHARS]}\n... (task truncated)" : task
        parts << "# Task\n\nThe user's original request for this session:\n\n#{shown}"
      end

      # 4. Skills (specialized instruction sets). The list grows as skills are
      # loaded, so it belongs after the stable block.
      skill_prompt = @skill_registry.to_system_prompt
      parts << skill_prompt unless skill_prompt.empty?

      # 5. Forced skill — injected directly to skip LLM tool-call overhead
      forced = resolve_forced_skill
      if forced
        parts << "# Active Skill: #{forced[:name]}\n\nYou MUST follow the instructions below for this response:\n\n#{forced[:content]}"
      end

      # 6. Conversation Summary (from session summarization)
      if @session&.summary_text
        parts << "# Previous Conversation Summary\n\n#{@session.summary_text}"
      end

      # 7. Memory: global (~/.rubot/MEMORY.md) merged with this workspace's.
      # Last because extraction rewrites it after most turns; keeping it at the
      # tail means a refresh costs the tail and not the whole prefix.
      # Learned Corrections already live in MEMORY.md, so they are not injected
      # a second time here — that duplicated ~200 tokens per request for no
      # extra information.
      parts << @memory.to_s if @memory.enabled?

      # 8. The batching instruction, restated last on purpose. A round trip is
      # the expensive part of a turn, and this model follows the instruction it
      # reads closest to the question: the same rule in the middle of a long
      # prompt produced 1–2 calls per message, repeated here it produced 4 of
      # 4 on the same task. Costs ~30 tokens and buys back seconds per turn.
      parts << BATCH_REMINDER

      parts.join("\n\n---\n\n")
    end

    # Learn from the turn that just finished. Channels call this *after* they
    # have delivered the answer, so extraction never delays a reply.
    #
    # A failure here must never cost the user their answer, so everything is
    # rescued and reported through the debug log only.
    def flush_learning
      run_session_naming
      run_feedback_learning
      run_memory_extraction
    rescue StandardError => e
      warn "[adaptive] learning failed: #{e.class}: #{e.message}"
    end

    private

    # Where this agent's session files go, and the directory they are marked as
    # coming from. Both come from the config so a channel can re-root them: the
    # TUI keeps one central sessions directory while recording the project it
    # was launched in, and /resume filters on that recorded directory.
    def session_dir_for(cfg)
      cfg.respond_to?(:sessions_dir) ? cfg.sessions_dir : Session.sessions_dir(cfg.workspace)
    end

    def session_cwd_for(cfg)
      cfg.respond_to?(:sessions_cwd) ? cfg.sessions_cwd : nil
    end

    # Global memory next to config.yml plus the memory of the workspace this
    # agent works in — which for a persona is the persona's own MEMORY.md.
    # Configs that predate the split (tests, plain data configs) fall back to
    # the single file in the assets workspace.
    def build_memory(cfg)
      unless cfg.respond_to?(:global_memory_path) && cfg.respond_to?(:workspace_memory_path)
        return Memory.new(workspace: cfg.assets_workspace)
      end

      label = cfg.respond_to?(:memory_scope_label) ? cfg.memory_scope_label : MemoryBank::SCOPE_WORKSPACE
      MemoryBank.new(
        global_path: cfg.global_memory_path,
        workspace_path: cfg.workspace_memory_path(cfg.workspace),
        workspace_label: label
      )
    end

    # Directory holding the AGENTS.md this agent follows. The project's own
    # file is preferred over the global one in the configured workspace, so
    # running the TUI inside a repo picks up that repo's rules.
    def agents_workspace(config, assets)
      project = config.workspace
      if project && File.exist?(File.join(project, "AGENTS.md"))
        project
      else
        assets
      end
    end

    # Resolution order for the preset a session starts with:
    #   1. preset saved on the session (/model <preset>)
    #   2. topic persona preset
    #   3. legacy persona model
    #   4. configured default/primary preset (or the implicit `default`)
    def resolve_initial_preset
      if @session.model_preset
        preset = @config.model_preset(@session.model_preset)
        return preset if preset
      end

      if @session.model_override
        name = @session.model_override.to_s
        if @config.model_entry_by_name(name) || provider_model_id?(name)
          return legacy_model_preset(name)
        end
      end

      if @persona&.preset
        preset = @config.model_preset(@persona.preset)
        return preset if preset
      end

      if @persona&.model
        model_name = persona_model_name
        if model_name
          settings = @config.provider_settings(model_name)
          return {
            "name" => "default",
            "model" => settings.model,
            "provider" => settings.provider,
            "api_key" => settings.api_key,
            "api_base" => settings.api_base,
            "max_tokens" => settings.max_tokens,
            "temperature" => settings.temperature,
            "extra_headers" => settings.extra_headers,
            "implicit" => true
          }
        end
      end

      @config.default_model_preset
    end

    def legacy_model_preset(model_name)
      settings = @config.provider_settings(model_name)
      entry = @config.model_entry_by_name(model_name) || @config.active_model_entry || {}
      {
        "name" => "default",
        "model" => settings.model,
        "provider" => settings.provider,
        "api_key" => settings.api_key,
        "api_base" => settings.api_base,
        "max_tokens" => settings.max_tokens,
        "temperature" => settings.temperature,
        "context_window_tokens" => entry["context_window_tokens"] || entry["contextWindowTokens"],
        "pricing" => entry["pricing"],
        "extra_headers" => settings.extra_headers,
        "implicit" => true
      }
    end

    def apply_initial_preset!
      @active_preset = resolve_initial_preset || @config.default_model_preset
      @active_preset_name = @active_preset["name"]
      @session_model = @active_preset["model"]
      @provider = build_provider(preset: @active_preset, effort: thinking_level)
    end

    def apply_preset_source(source, name: nil, session_name: nil)
      settings = @config.provider_settings_for_preset(source)
      preset_name = (source["name"] || source[:name] || name || "default").to_s

      @active_preset = {
        "name" => preset_name,
        "model" => settings.model,
        "provider" => settings.provider,
        "api_key" => settings.api_key,
        "api_base" => settings.api_base,
        "max_tokens" => settings.max_tokens,
        "temperature" => settings.temperature,
        "extra_headers" => settings.extra_headers,
        "reasoning_effort" => source["reasoning_effort"] || source[:reasoning_effort],
        "context_window_tokens" => source["context_window_tokens"] || source[:context_window_tokens],
        "pricing" => source["pricing"] || source[:pricing],
        "implicit" => source["implicit"] || source[:implicit] || false
      }
      @active_preset_name = preset_name
      @session_model = settings.model
      @session.model_preset = session_name || preset_name
      @session.model_override = nil
      @session.save!
      @provider = Provider.build(settings.with_effort(thinking_level))
      active_model_preset
    end

    def apply_agents_overrides
      ag = @agents_file

      # Override config values if set in AGENTS.md frontmatter
      if ag.name
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["name"] = ag.name
      end

      if ag.model
        @config.data["model"] = ag.model
      end

      if ag.max_tokens
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["max_tokens"] = ag.max_tokens
      end

      if ag.temperature
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["temperature"] = ag.temperature
      end

      if ag.max_rounds
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["max_rounds"] = ag.max_rounds
      end

      # Apply tool overrides from AGENTS.md
      return if ag.tools_config.empty?
      tools = @config.data["tools"] || {}
      ag.tools_config.each do |tool_name, enabled|
        tools[tool_name.to_s] = { "enabled" => enabled }
      end
      @config.data["tools"] = tools unless ag.tools_config.empty?
    end

    # Set the workspace on the cron tool so jobs persist to disk
    def configure_cron_tool
      cron_tool = @tools.get("cron")
      return unless cron_tool && cron_tool.respond_to?(:workspace=)
      cron_tool.workspace = @config.workspace
      # The install's own jobs live next to config.yml (~/.rubot/cron), not
      # inside the workspace the agent works in.
      cron_tool.store_root = @config.catalog_dir if cron_tool.respond_to?(:store_root=)
    end

    # Inject the safety guard into all tools that support it.
    # Called after @tools is assigned, ensuring the guard is applied
    # regardless of whether tools came from the Agent's constructor
    # or were passed in externally (e.g. from bin/rubot or REPL).
    def inject_safety_guard
      return unless @tools.respond_to?(:all)
      @tools.all.each do |tool|
        next unless tool.respond_to?(:safety_guard=)
        tool.safety_guard = @safety_guard
      end
    end

    # Fire any due cron jobs and return their results.
    def fire_due_cron_jobs
      return [] if @cron_ractor
      cron_tool = @tools.get("cron")
      return [] unless cron_tool && cron_tool.respond_to?(:scheduler)
      scheduler = cron_tool.scheduler
      scheduler.fire_due_jobs
    rescue StandardError => e
      warn "[cron] Error firing due jobs: #{e.class}: #{e.message}"
      []
    end

    def build_messages
      messages = []

      # Add system prompt (composed from all sources)
      messages << { "role" => "system", "content" => build_system_prompt }

      # Add conversation history (limited by messages and, optionally, tokens).
      # `reasoning_tail` keeps reasoning only for the turn being executed.
      recent_messages = @session.safe_history(
        limit: @config.history_limit,
        max_tokens: @config.history_max_tokens,
        reasoning_tail: current_turn_message_count
      )
      trim_old_tool_results!(recent_messages)

      recent_messages.each do |msg|
        formatted = { "role" => msg["role"], "content" => msg["content"] }

        # Handle tool calls for assistant messages
        if msg["role"] == "assistant" && msg["tool_calls"]
          formatted["tool_calls"] = msg["tool_calls"]
        end

        # Include reasoning_content for DeepSeek and other reasoning models
        if msg["role"] == "assistant" && msg["reasoning_content"]
          formatted["reasoning_content"] = msg["reasoning_content"]
        end

        # Handle tool_call_id for tool results
        if msg["role"] == "tool"
          formatted["tool_call_id"] = msg["tool_call_id"]
        end

        messages << formatted
      end

      messages
    end

    # Number of messages that belong to the turn currently running. Used to
    # decide which reasoning blocks are still worth sending.
    def current_turn_message_count
      return 0 if @turn_start_index.nil?

      [ @session.messages.size - @turn_start_index, 0 ].max
    end

# Shorten all but the newest `tool_result_keep` tool outputs in place, and
# redact the oversized arguments of the tool calls that produced them.
#
# The boundary moves in blocks of `keep`, not one result at a time. A
# boundary that advances on every request rewrites a message in the middle
# of the transcript each time, and everything from that point on has to be
# re-read uncached — in a tool-heavy turn that is a new request every few
# seconds. Rounding the count down to a multiple of `keep` keeps the
# payload byte-for-byte identical between advances, so the same cached
# prefix survives roughly `keep` requests instead of one. The cost is up to
# `2 * keep` recent results kept verbatim instead of `keep`.
#
# Argument redaction rides the same boundary: a tool call whose result is
# old enough to truncate also loses any oversized argument value (a file
# written an hour ago does not need to ride along in every request).
# Sharing one boundary keeps the cache-miss cadence at one per block
# instead of two.
def trim_old_tool_results!(messages)
  keep = @config.tool_result_keep
  max_chars = @config.tool_result_max_chars
  return if max_chars.zero?

  indexes = messages.each_index.select { |i| messages[i]["role"] == "tool" }
  return if keep.positive? && indexes.size <= keep

  older = if keep.positive?
    # How many results are past the keep window, rounded down to a block.
    surplus = indexes.size - keep
    truncate_count = (surplus / keep) * keep
    return if truncate_count.zero?

    indexes[0, truncate_count].to_a
  else
    indexes
  end

  older.each do |i|
    redact_old_tool_call_args!(messages, messages[i]["tool_call_id"], max_chars)
    content = messages[i]["content"].to_s
    next if content.length <= max_chars

    messages[i] = messages[i].merge(
      "content" => content[0...max_chars] + TRUNCATED_TOOL_RESULT_NOTICE
    )
  end
end

# Replace oversized top-level string values in an old tool call's
# arguments with a notice, on the request copy only (the session transcript
# keeps the originals). Values are rebuilt through merge/map because
# conversation_history shares the stored tool_calls arrays by reference —
# mutating them in place would corrupt the session file.
def redact_old_tool_call_args!(messages, tool_call_id, max_chars)
  return unless tool_call_id

  index = messages.index do |m|
    m["role"] == "assistant" && m["tool_calls"]&.any? { |tc| tc["id"] == tool_call_id }
  end
  return unless index

  message = messages[index]
  calls = message["tool_calls"].map do |tc|
    next tc unless tc["id"] == tool_call_id

    args = tc.dig("function", "arguments").to_s
    redacted = redact_json_args(args, max_chars)
    next tc if redacted == args

    tc.merge("function" => tc["function"].merge("arguments" => redacted))
  end
  messages[index] = message.merge("tool_calls" => calls)
end

# Keep the first `max_chars` of each oversized top-level string value and
# note how much was dropped, so the model still sees paths and command
# shapes without carrying whole file bodies. Arguments that are not valid
# JSON are left alone: a malformed string in history is what the provider
# already accepted once, and guessing at its shape risks more.
def redact_json_args(args, max_chars)
  parsed = JSON.parse(args)
  return args unless parsed.is_a?(Hash)

  changed = false
  parsed.each do |key, value|
    next unless value.is_a?(String) && value.length > max_chars

    parsed[key] = value[0...max_chars] +
      format(REDACTED_TOOL_CALL_ARGS_NOTICE, value.length - max_chars)
    changed = true
  end
  changed ? JSON.generate(parsed) : args
rescue JSON::ParserError
  args
end

    # Build a provider from an immutable settings snapshot. No config
    # mutation is performed, so this is safe to call from any Ractor.
    def build_provider(model_name = nil, preset: nil, effort: nil)
      settings = if preset
        @config.provider_settings_for_preset(preset)
      else
        @config.provider_settings(model_name)
      end
      settings = settings.with_effort(effort) unless effort.nil?
      Provider.build(settings)
    end

    # Rebuild the provider using the session-level model override.
    def rebuild_provider
      return if @session_model.nil?
      return if @config.model_entry_by_name(@session_model).nil? && !provider_model_id?(@session_model)

      @provider = build_provider(@session_model, effort: thinking_level)
    end

    # A model from the provider's /models catalog rather than config.yml.
    def provider_model_id?(name)
      id = name.to_s
      return true if ModelCatalog.cached_model_ids(@config.catalog_dir).include?(id)

      # The catalog loaded in this process knows its ids without a fetch.
      @model_catalog&.cached_ids.to_a.include?(id)
    end

    # Persona model name. Config entries and provider catalog ids are valid;
    # anything else falls back to the default model.
    def persona_model_name
      name = @persona&.model
      return nil if name.nil? || name.empty?

      if @config.model_entry_by_name(name).nil? && !provider_model_id?(name)
        warn "[persona] model '#{name}' is not in config.yml or the provider catalog — using the default model"
        return nil
      end

      name
    end

    # The names a request may call, which is what a prompt sentence can safely
    # name: `tools_enabled` can switch the whole set off, and a config can trim
    # it further.
    def tool_names
      (tool_definitions || []).map(&:name)
    end

    def tool_definitions
      return nil unless @config.tools_enabled
      enabled_list = @config.enabled_tools

      # If no explicit tool configuration, use all registered tools
      tools = if enabled_list.nil? || enabled_list.empty?
        @tools.all
      else
        @tools.all.select { |t| enabled_list.include?(t.name) }
      end

      # Always include memory tool if memory is enabled, regardless of config
      if @memory.enabled?
        memory_tool = @tools.get("memory")
        tools << memory_tool if memory_tool && !tools.include?(memory_tool)
      end

      tools
    end

    # A call that will not run (bad arguments, a cancelled turn, a refused
    # guard question) but still owes the transcript one result per tool call.
    def skipped_call(id, name, result)
      { name: name, arguments: {}, id: id, snapshot: nil, result: result }
    end

    # Run the approved tool calls, several at a time, and return them in the
    # order they were asked for — a caller walking the result sees a transcript
    # exactly like the sequential one, with the wall time of the slowest call
    # instead of the sum. Calls already carrying a result are passed through.
    def execute_tool_calls(calls)
      todo = calls.reject { |call| call.key?(:result) }
      if todo.size < 2
        return calls.map { |call| call.key?(:result) ? call : call.merge(result: run_one_tool(call)) }
      end

      queue = Queue.new
      todo.each { |call| queue << call }
      results = {}
      lock = Mutex.new

      [ todo.size, MAX_PARALLEL_TOOLS ].min.times.map do
        Thread.new do
          while (call = begin
            queue.pop(true)
          rescue ThreadError
            nil
          end)
            result = run_one_tool(call)
            lock.synchronize { results[call.object_id] = result }
          end
        end
      end.each(&:join)

      calls.map { |call| call.key?(:result) ? call : call.merge(result: results[call.object_id]) }
    end

    # One tool call, with its output made safe for the transcript and the
    # request: a read can return a PNG, and an error is reported to the model
    # rather than raised, because a failed tool is a thing to answer about.
    def run_one_tool(call)
      result = @tools.execute(call[:name], call[:arguments])
      Session.normalize_utf8(result.to_s)
    rescue StandardError => e
      "ERROR: #{e.class}: #{e.message}"
    end

    # Returns [name, arguments, parsed_ok]. `parsed_ok` is false when the
    # arguments were not valid JSON — which is what a tool call cut off at the
    # output limit looks like — so the caller can refuse to run it on a
    # half-read argument instead of silently executing with an empty hash.
    # Before-content of a file a file_ops write/append/edit/delete is about to
    # touch. nil for reads and every other tool.
    def file_ui_snapshot(tool_name, arguments)
      return nil unless tool_name == "file_ops" && arguments.is_a?(Hash)
      return nil unless %w[write append edit delete].include?(arguments["operation"].to_s)

      path = arguments["path"].to_s
      return nil if path.empty?

      expanded = File.expand_path(path)
      before = File.exist?(expanded) ? File.read(expanded, encoding: "UTF-8") : nil
      { path: path, expanded: expanded, before: before }
    rescue StandardError
      nil
    end

    # After-content for the TUI diff, or nil when the tool did not write.
    # A delete leaves no file behind: its after-content is nil, so every line
    # the file had replays as a removal instead of disappearing from view.
    def file_ui_diff(snapshot, result)
      return nil unless snapshot
      return nil unless result.to_s.match?(/\A(?:Written|Appended|Edited|Deleted) /)

      after = File.exist?(snapshot[:expanded]) ? File.read(snapshot[:expanded], encoding: "UTF-8") : nil
      before = snapshot[:before]
      return nil if before == after
      return nil if before.to_s.length + after.to_s.length > MAX_UI_DIFF_CHARS

      { "path" => snapshot[:path], "before" => before, "after" => after }
    rescue StandardError
      nil
    end

    def parse_tool_call(tc)
      if tc.is_a?(Hash)
        fn = tc["function"]
        name = fn["name"]
        args_str = fn["arguments"]
      else
        fn = tc.function
        name = fn.name
        args_str = fn.arguments
      end

      arguments = args_str.is_a?(String) ? JSON.parse(args_str) : args_str
      return [ name, {}, false ] unless arguments.is_a?(Hash)

      [ name, arguments, true ]
    rescue JSON::ParserError, TypeError
      [ name, {}, false ]
    end

    # Persist the provider's usage for this request. Streaming providers may
    # return the usage inside the result hash; otherwise read last_usage.
    # `auxiliary` is for requests that are not the user-facing turn (cron,
    # memory extraction, summarization): they count toward the totals without
    # replacing the context anchor.
    def record_usage(result, auxiliary: false, messages: nil)
      raw = result.is_a?(Hash) ? result["usage"] : nil
      raw ||= @provider.last_usage if @provider.respond_to?(:last_usage)
      return if raw.nil?

      rates = current_rates(network: false)
      shape = cache_request_shape(messages, auxiliary: auxiliary)
      if auxiliary
        @session.record_auxiliary_usage(raw, provider: @provider.name, rates: rates, shape: shape)
      else
        @session.record_usage(raw, provider: @provider.name, rates: rates, shape: shape)
      end
    rescue StandardError => e
      warn "[usage] Failed to record usage: #{e.class}: #{e.message}" if @config.debug?
    end

    # The request as the prompt cache sees it: a digest of the pinned system
    # prompt, a digest of the tool catalog, how many blocks the provider will
    # hash, and how many turns the live window carried.
    #
    # Digests rather than copies, because the question they answer is only ever
    # "is this the same as last time?". A hit rate says a request missed; the
    # first record whose digest differs says where the prefix moved — the system
    # prompt, the tools, or the history in front of the cache breakpoint.
    #
    # `blocks` counts what a provider hashes as separate pieces: the system
    # prompt, each tool definition, each message. Anthropic's lookback window is
    # measured in blocks (twenty of them), so this is the number that tells a
    # growing conversation whether it has walked past the last cache write.
    #
    # The per-block `fingerprint` and `diverged_at` narrow the same question to
    # one block: the whole-prompt digest says the history changed, the
    # fingerprint says which message. Both are computed from the list that was
    # actually sent (`messages`), not from the session, so a trimmed window is
    # fingerprinted as it went out.
    def cache_request_shape(messages, auxiliary: false)
      tools = tool_definitions || []
      system_prompt = build_system_prompt
      sent = messages || @session.messages
      fingerprint = CacheProbe.fingerprint(system: system_prompt, tools: tools, messages: sent)
      previous = @session.cache_records.last
      {
        "provider" => @provider.name.to_s,
        "model" => active_model_name.to_s,
        "epoch" => digest_of(system_prompt),
        "tools" => digest_of(tools.map { |tool| [ tool.name, tool.description, tool.parameters ] }.to_json),
        "blocks" => CacheProbe.block_count(fingerprint),
        "turns" => sent.size,
        "fingerprint" => fingerprint,
        "diverged_at" => CacheProbe.first_divergence(previous && previous["fingerprint"], fingerprint),
        "auxiliary" => auxiliary
      }
    end

    # Publish live figures to a caller that wants them mid-turn. Failing to
    # produce a footer must never cost the user their answer, so every error
    # here is swallowed after a debug note.
    def emit_usage(callback, live: nil)
      return unless callback

      callback.call(usage_report(network: false, live: live))
    rescue StandardError => e
      warn "[usage] Failed to publish live usage: #{e.class}: #{e.message}" if @config.debug?
    end

    # Rate lookup for the model this agent is currently talking to. The turn
    # path passes `network: false` so a slow models.dev never delays an answer.
    def current_rates(network: true)
      preset = @active_preset || {}
      model_id = preset["model"] || @session_model || @config.model
      provider_name = preset["provider"] || @provider.name
      resolve_rates(model_id, provider_name, preset, network: network).first
    end

    # The provider for the requests that are not the conversation: naming a
    # session, extracting memory. Unset `auxiliary_model` returns the
    # conversation's own provider, so a config that says nothing behaves
    # exactly as before. Built once per agent and then reused, because a
    # provider is a connection pool, not a value.
    def auxiliary_provider
      settings = @config.auxiliary_settings
      return @provider if settings.nil?

      @auxiliary_provider ||= Provider.build(settings)
    end

    # What those requests cost, priced against the model that served them. A
    # cheap auxiliary model billed at the conversation's rate would make the
    # saving invisible in the session totals.
    def auxiliary_rates
      name = @config.auxiliary_model
      return current_rates(network: false) if name.nil?

      settings = @config.auxiliary_settings
      preset = @config.model_preset(name) || {}
      resolve_rates(settings.model, settings.provider, preset, network: false).first
    end

    # Context estimate for the next request. The system prompt is only needed
    # when there is no usable usage anchor (fresh session, after compaction),
    # because an anchor already includes the prompt it was sent with.
    def context_usage
      if @session.context_anchored?
        @session.context_tokens
      else
        @session.context_tokens(extra_chars: build_system_prompt.length)
      end
    end

    def pricing_catalog
      @pricing_catalog ||= PricingCatalog.new(config: @config)
    end

    def resolve_context_window(model_id, provider_name, preset)
      # Presets inherit `context_window_tokens` from their model entry, so
      # there is no need to consult another model's entry here (doing that
      # leaked the default model's window into a switched-to preset).
      value = preset["context_window_tokens"].to_i
      return value if value.positive?

      pricing_catalog.context_window(model_id, provider: provider_name) ||
        ModelInfo.context_window(model_id)
    end

    def resolve_rates(model_id, provider_name, preset, network: true)
      configured = ModelInfo.normalize_rates(preset["pricing"])
      return [ configured, "config" ] if configured

      if provider_name.to_s == "ollama"
        return [ { "input" => 0.0, "output" => 0.0, "cached_input" => 0.0,
                   "cache_creation_input" => 0.0 }, "free" ]
      end

      catalog_rates = pricing_catalog.rates(model_id, provider: provider_name, network: network)
      return [ catalog_rates, pricing_catalog.source ] if catalog_rates

      builtin = ModelInfo.rates(model_id, provider: provider_name)
      builtin ? [ builtin, "builtin" ] : [ nil, nil ]
    end

    def log_debug(msg)
      warn "[debug] #{msg}" if @config.debug?
    end

    # Maximum number of agent rounds per message. Comes from
    # `agents.defaults.max_rounds` (config.yml or AGENTS.md frontmatter).
    # A round is one loop trip, including re-asks and continuations, not one
    # tool call.
    def max_rounds
      @config.max_rounds
    end

    # Deprecated alias for callers that still use the old name.
    alias max_tool_iterations max_rounds

    # Build a response when the turn ends with no answer of its own — the
    # model produced only tool calls and nothing to say about them. This is a
    # last resort after the re-ask, so it stays short and honest: dumping the
    # raw tool output here used to send the user things like
    # "I completed 3 step(s) of tool calls. Results: 1. [Exit code: 0]".
    def build_fallback_response(rounds, tool_rounds: 0)
      if tool_rounds.zero?
        return "⚠️ The model returned an empty reply and nothing was sent. " \
               "Reply \"continue\" to retry."
      end

      last = last_tool_name
      summary = last ? "#{tool_rounds} tool call(s), last one #{last}" : "#{tool_rounds} tool call(s)"
      round_word = rounds == 1 ? "round" : "rounds"
      "⚠️ The model stopped after #{rounds} #{round_word} and #{summary} without " \
        "writing an answer, so there is nothing to show for this turn. " \
        "Reply \"continue\" to retry."
    end

    # Name of the most recent tool the session ran, for the fallback above.
    def last_tool_name
      history = @session.safe_history(limit: @config.history_limit)
      history.reverse_each do |msg|
        next unless msg["role"] == "assistant" && msg["tool_calls"]
        call = msg["tool_calls"].last
        return nil unless call

        return call.is_a?(Hash) ? call.dig("function", "name") : call.function.name
      end
      nil
    rescue StandardError
      nil
    end

    # Resolve the forced skill for the current session, return {name, content} or nil.
    # Clears the forced_skill flag after use so it only applies once.
    def resolve_forced_skill
      skill_name = @session&.forced_skill
      return nil if skill_name.nil? || skill_name.empty?

      # Clear the flag so it only applies to the next message
      @session.forced_skill = nil
      @session.save! if @session.respond_to?(:save!)

      skill = @skill_registry.get(skill_name)
      return nil unless skill && skill.enabled?

      { name: skill.name, content: skill.content }
    end

    # -- Public methods accessible from background threads and channels --
    public

    # Process a cron message through the LLM. Called by the cron scheduler's
    # background thread.
    #
    # `fresh` starts a transcript from nothing but the system prompt, for jobs
    # that want a conversation of their own: a daily practice session should
    # not inherit yesterday's subject, and a long-running reminder should not
    # drag the history it was created in behind it.
    def process_cron(message, fresh: false)
      # Build local messages from session history ONLY (up to the last assistant response)
      # Do NOT include the current user message — this is a separate conversation turn
      @turn_start_index = @session.messages.size
      local_messages = build_cron_messages(fresh: fresh)
      local_messages << { "role" => "user", "content" => "⏰ Scheduled task fired:\n#{message}" }

      response = ""
      tool_calls = nil
      reasoning_content = nil
      rounds = 0
      limit = max_rounds

      loop do
        break if rounds >= limit

        result = @provider.chat(local_messages, tools: tool_definitions)
        # A cron run is a separate, local transcript: count its tokens and cost,
        # but never let it become the anchor for /context's context size.
        record_usage(result, auxiliary: true, messages: local_messages)

        if result.is_a?(Hash)
          response = result["content"] || ""
          tool_calls = result["tool_calls"]
          reasoning_content = result["reasoning_content"]
        elsif result.is_a?(Array)
          response, tool_calls = result
          reasoning_content = nil
        else
          response = result.to_s
          tool_calls = nil
          reasoning_content = nil
        end

        if tool_calls && !tool_calls.empty?
          assistant_msg = { "role" => "assistant", "content" => response, "tool_calls" => tool_calls }
          assistant_msg["reasoning_content"] = reasoning_content if reasoning_content
          local_messages << assistant_msg

          # A cron turn has no guard to ask and nobody watching, so the calls
          # are collected and run together like a normal turn's.
          cron_calls = tool_calls.map do |tc|
            tool_name, arguments, = parse_tool_call(tc)
            tool_call_id = tc.is_a?(Hash) ? (tc["id"] || tool_name) : tool_name
            { name: tool_name, arguments: arguments, id: tool_call_id }
          end

          execute_tool_calls(cron_calls).each do |call|
            local_messages << { "role" => "tool", "content" => call[:result], "tool_call_id" => call[:id] }
          end

          response = ""
          tool_calls = nil
          rounds += 1
        else
          break
        end
      end

      # If the LLM returned empty, use the cron message itself as the response
      response = message if response.nil? || response.strip.empty?

      @session.add("assistant", response, reasoning_content: reasoning_content) unless response.empty?
      response
    end

    # Name a conversation that was opened without one. A cron job that starts
    # its own session has no user message for the name to come from, so without
    # this every run would sit in the sidebar as "Untitled session" and the days
    # would be impossible to tell apart.
    def set_session_title(title)
      text = title.to_s.strip
      return nil if text.empty?

      @session.title = text
      @session.save!
      @session.title
    end

    # Build messages for cron processing — uses conversation history
    # but excludes the current user message being processed.
    #
    # With `fresh: true` the history is left out entirely: the system prompt is
    # the whole context, which is what a job that opens its own conversation
    # needs.
    def build_cron_messages(fresh: false)
      messages = []
      messages << { "role" => "system", "content" => build_system_prompt }
      return messages if fresh

      history_limit = @config.history_limit
      all_history = @session.safe_history(
        limit: history_limit,
        max_tokens: @config.history_max_tokens,
        reasoning_tail: 0
      )

      # If the last message is a user message (the current one being processed),
      # exclude it so cron processing has clean context
      history = all_history.dup
      history.pop if history.last && history.last["role"] == "user"
      trim_old_tool_results!(history)

      recent = history
      recent.each do |msg|
        formatted = { "role" => msg["role"], "content" => msg["content"] }
        formatted["tool_calls"] = msg["tool_calls"] if msg["role"] == "assistant" && msg["tool_calls"]
        formatted["tool_call_id"] = msg["tool_call_id"] if msg["role"] == "tool"
        formatted["reasoning_content"] = msg["reasoning_content"] if msg["role"] == "assistant" && msg["reasoning_content"]
        messages << formatted
      end

      messages
    end

    # --- Adaptive feature helpers ---

    # Run extraction once enough user messages have piled up.
    #
    # Extraction used to be one provider request per user message, issued
    # before the answer. Batching it over `memory.extract_every` messages
    # (default 3) keeps most of the coverage for a third of the requests.
    def run_memory_extraction
      return unless @memory_extractor
      return unless @memory.enabled?

      every = @config.memory_extract_every.to_i
      return unless every.positive?
      return if @session.memory_backlog.size < every

      batch = @session.take_memory_backlog
      provider = auxiliary_provider
      extracted = @memory_extractor.extract(batch, provider: provider)

      # Extraction is a real provider request; count it in the session totals
      # without overwriting `last_usage`, which `/context` uses for context size.
      if @memory_extractor.last_usage
        @session.record_auxiliary_usage(
          @memory_extractor.last_usage, provider: provider.name,
          rates: auxiliary_rates
        )
      end

      if @config.memory_consolidate?
        result = @memory.consolidate!
        warn "[memory] consolidated: removed #{result[:removed]}" if result && Rubot.debug?
      end

      return if extracted.empty?

      if Rubot.debug?
        extracted.each do |item|
          warn "[memory_extractor] Stored [#{item[:section]}]: #{item[:fact]}"
        end
      end
    end

    # Give the conversation a name, once.
    #
    # A session file holds a transcript, not a name, and the prompt that opened
    # it is written for the agent rather than for a list someone scans. One
    # small request names it after the answer has been delivered, so naming
    # never delays the reply; its tokens are recorded as auxiliary usage so the
    # context figure the status row shows stays about the conversation itself.
    def run_session_naming
      return unless @session.title.to_s.strip.empty?

      prompt = first_user_prompt
      return if prompt.nil?

      namer = SessionNamer.new(provider: auxiliary_provider)
      title = namer.name(prompt, reply: first_assistant_answer)

      if namer.last_usage
        @session.record_auxiliary_usage(
          namer.last_usage, provider: auxiliary_provider.name,
          rates: auxiliary_rates
        )
      end
      return if title.nil?

      @session.title = title
      @session.save!
      warn "[session_namer] named #{@session.id}: #{title}" if Rubot.debug?
    end

    # The prompt that opened this conversation, ignoring the instructions rubot
    # sends itself.
    def first_user_prompt
      @session.messages.each do |msg|
        next unless msg["role"] == "user"

        content = msg["content"].to_s.strip
        next if content.empty?
        next if [ CONTINUE_PROMPT, ANSWER_NOW_PROMPT, EMPTY_ANSWER_PROMPT ].include?(content)

        return content
      end
      nil
    end

    # What the conversation turned into, which is often easier to name than the
    # request that started it. nil when the first turn produced no text.
    def first_assistant_answer
      msg = @session.messages.find { |m| m["role"] == "assistant" && !m["content"].to_s.strip.empty? }
      msg && msg["content"].to_s
    end

    # Run feedback learning — detect if user is correcting the bot (always on)
    def run_feedback_learning
      return unless @feedback_learner
      return unless @memory.enabled?

      message = last_user_message
      return if message.nil?

      # The current turn is already in the transcript, so the correction is
      # matched against the answer the user is reacting to.
      @feedback_learner.process(message, @session.conversation_history)
    end

    # The last thing the user actually wrote, ignoring the prompts rubot sends
    # itself (continuation and re-ask instructions).
    def last_user_message
      @session.messages.reverse_each do |msg|
        next unless msg["role"] == "user"

        content = msg["content"].to_s.strip
        next if content.empty?
        next if [ CONTINUE_PROMPT, ANSWER_NOW_PROMPT, EMPTY_ANSWER_PROMPT ].include?(content)

        return content
      end
      nil
    end

    # Run automatic compaction when the transcript approaches the configured
    # share of the model's context window. The estimate is recomputed from the
    # transcript each time, so a compaction immediately lowers it and the next
    # round does not compact again.
    def run_auto_compaction
      return unless @config.auto_compact?
      return if @session.message_count <= @config.compact_keep_recent_messages

      window = context_window_tokens
      # An unknown model used to disable compaction entirely, which left an
      # unbounded transcript and a silently trimmed request. Fall back to a
      # conservative window so there is always a bound.
      window = Config::DEFAULT_CONTEXT_WINDOW unless window.to_i.positive?

      threshold = window * (@config.compact_threshold_percent / 100.0)
      cap = @config.compact_threshold_tokens
      threshold = [ threshold, cap ].min if cap.positive?
      used = estimated_context_tokens
      return if used < threshold

      result = compact_session
      if result && Rubot.debug?
        warn "[compaction] auto: #{result[:summarized_messages]} messages summarized, " \
             "context #{result[:context_before]} -> #{result[:context_after]} tokens (estimated)"
      end
      result
    end
  end
end
