# frozen_string_literal: true

module Rubot
  class Agent
    # What one request to the provider is made of.
    #
    # #build_messages puts the system prompt, the trimmed transcript, the system
    # additions and the newest prompt patch into the order the cache expects.
    # That order is the whole reason this lives in one method with its comments:
    # everything in front of the last user turn has to stay byte-identical or
    # the prefix is re-read on the next round.
    #
    # Moved as it was, comments included. The two redaction helpers below it are
    # moved too rather than rewritten: they keep the argument bodies of old tool
    # calls out of the request, and their notice text is part of what the model
    # sees.
    module MessageBuilder
      private

      def build_messages
        messages = []

        # Add system prompt (composed from all sources)
        messages << { "role" => "system", "content" => build_system_prompt }

        # Add conversation history (limited by messages and, optionally, tokens).
        # `reasoning_tail` keeps reasoning only for the turn being executed.
        recent_messages = @session.safe_history(
          reasoning_tail: current_turn_message_count
        )

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

        # Append system additions without rewriting the cached prefix.
        if @session.respond_to?(:system_additions)
          @session.system_additions.each do |addition|
            messages << { "role" => "system", "content" => addition }
          end
        end

        # Newer text for sections the model was pinned with. Last on purpose: it
        # has to read closer to the question than what it supersedes, and it sits
        # behind the transcript, so a change here costs the block and nothing in
        # front of it.
        patch = @session.respond_to?(:system_patch) ? @session.system_patch : nil
        messages << { "role" => "system", "content" => patch } if patch

        messages
      end

      # Number of messages that belong to the turn currently running. Used to
      # decide which reasoning blocks are still worth sending.
      def current_turn_message_count
        return 0 if @turn_start_index.nil?

        [ @session.messages.size - @turn_start_index, 0 ].max
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
    end
  end
end
