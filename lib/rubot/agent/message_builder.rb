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
    # Moved as it was, comments included.
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
    end
  end
end
