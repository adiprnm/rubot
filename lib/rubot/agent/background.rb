# frozen_string_literal: true

module Rubot
  class Agent
    # The turns nobody is waiting for: cron jobs, memory extraction, session
    # naming, feedback learning, and the compaction that runs after a turn.
    #
    # Each of them reuses this agent's config and provider but not its turn: no
    # cancellation token, no callbacks a reader is watching, and a failure is
    # logged rather than raised into anything. They used to sit at the bottom of
    # agent.rb under a second `public`, far from the loop they borrow from.
    #
    # Moved as they were, comments included: the order in which these tasks see
    # the transcript is what keeps a background write from landing mid-turn.
    module Background
      # Process a cron message through the LLM. Called by the cron scheduler's
      # background thread.
      #
      # `fresh` starts a transcript from nothing but the system prompt, for jobs
      # that want a conversation of their own: a daily practice session should
      # not inherit yesterday's subject, and a long-running reminder should not
      # drag the history it was created in behind it.
      def process_cron(message, fresh: false)
        process_background(message, fresh: fresh, label: "⏰ Scheduled task fired:\n")
      end

      # A turn the reader did not speak.
      #
      # The text reaches the model as context and nothing of it is written to the
      # transcript: only the answer is. A fired job arrives this way, and so does
      # the report a finished batch of sub agents leaves behind — the reader asked
      # for the work, not for a message in their own voice.
      #
      # A block given to this method is handed the answer as it is written, one
      # call per passage. A background turn is exactly the one nobody is watching,
      # so a channel that can show it arriving does — otherwise the reader waits
      # through the whole answer in silence and then reads it all at once.
      def process_background(message, fresh: false, label: "", &on_chunk)
        # Build local messages from session history ONLY (up to the last assistant response)
        # Do NOT include the current user message — this is a separate conversation turn
        @turn_start_index = @session.messages.size
        local_messages = build_background_messages(fresh: fresh)
        local_messages << { "role" => "user", "content" => "#{label}#{message}" }

        response = ""
        tool_calls = nil
        reasoning_content = nil
        rounds = 0
        limit = max_rounds

        loop do
          break if rounds >= limit

          # A fired job runs on this agent's own persona, but the tool registry is
        # shared — stamp the scope before the turn reaches any tool.
        inject_tool_persona

        # A background turn has no channel callback to report retries to, so pass a
          # no-op rather than the `on_retry` local from #process — that variable
          # is not in scope here and used to raise NameError on every fired job.
          result = if block_given?
            # The answer accumulates here as well as in the provider: what the
            # reader is shown is the passage so far, not the fragment that just
            # arrived, so a repaint can never lose a word.
            @provider.chat_stream(local_messages, tools: tool_definitions, on_retry: nil) do |chunk, _tools, _reasoning|
              response += chunk if chunk
              on_chunk.call(response.dup) if chunk && !chunk.empty?
            end
          else
            @provider.chat(local_messages, tools: tool_definitions, on_retry: nil)
          end
          # A background run is a separate, local transcript: count its tokens and cost,
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

            # A background turn has no guard to ask and nobody watching, so the
            # calls are collected and run together like a normal turn's.
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

        # An empty answer falls back to the text that was handed in: something
        # has to stand in the transcript, and the request says more than "".
        response = message if response.nil? || response.strip.empty?

        # The answer carries a stamp so the transcript can give it a block of its
        # own (see the page's history): nothing prompted it, and glued under the
        # answer above it read as if it had never arrived.
        unless response.empty?
          @session.add("assistant", response, reasoning_content: reasoning_content, background: true)
        end
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

      # Build messages for a background turn — uses conversation history
      # but excludes the current user message being processed.
      #
      # With `fresh: true` the history is left out entirely: the system prompt is
      # the whole context, which is what a job that opens its own conversation
      # needs.
      def build_background_messages(fresh: false)
        messages = []
        messages << { "role" => "system", "content" => build_system_prompt }
        return messages if fresh

        all_history = @session.safe_history(
          reasoning_tail: 0
        )

        # If the last message is a user message (the current one being processed),
        # exclude it so cron processing has clean context
        history = all_history.dup
        history.pop if history.last && history.last["role"] == "user"

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
      #
      # Both branches run in the middle of a turn, so both hand the turn in flight
      # to compact_session as something it may not summarize.
      def run_auto_compaction
        return unless @config.auto_compact?
        min_keep = @config.token_based_compaction? ? 2 : @config.compact_keep_recent_messages
        return if @session.message_count <= min_keep

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

        # The summarizer call is the slow part, and it happens inside compact!.
        # Announce it before entering so the reader sees "in progress" while the
        # provider is working, not only once the result is already in hand.
        @on_compaction_start&.call
        result = compact_session(protect_current_turn: true)
        if result
          @on_compaction&.call(result)
        else
          # The "in progress" row was already drawn. Without this the reader is
          # left staring at it forever when the summarizer fails or finds nothing
          # to do, because the success callback is the only thing that retires it.
          @on_compaction_failed&.call
        end
        if result && Rubot.debug?
          warn "[compaction] auto: #{result[:summarized_messages]} messages summarized, " \
               "context #{result[:context_before]} -> #{result[:context_after]} tokens (estimated)"
        end
        result
      end
    end
  end
end
