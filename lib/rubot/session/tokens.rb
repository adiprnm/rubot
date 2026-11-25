# frozen_string_literal: true

module Rubot
  class Session
    # How large the next request is, in tokens, without a tokenizer.
    #
    # Ruby has no tokenizer for any provider, so this is a length heuristic:
    # the same one Pi uses, over the transcript plus (when there is no anchor)
    # the system prompt. It decides when automatic compaction fires and what
    # /context shows, which is why the two share one formula instead of each
    # carrying its own estimate.
    #
    # The instance methods read the transcript and the usage anchor; the
    # class-level ones measure a single message and are extended onto Session
    # so `Session.message_tokens` keeps working for callers outside.
    module Tokens
      # Pi's `CHARS_PER_TOKEN`. Ruby has no tokenizer, so this is the same
      # text-length heuristic Pi uses for the parts of the transcript that no
      # provider usage report covers yet.
      CHARS_PER_TOKEN = 3.5

      # Approximate token count of the next request: the anchor from the latest
      # provider usage plus an estimate of the messages added after it (or, when
      # there is no usable anchor, an estimate of the whole transcript).
      # `extra_chars` is the system prompt and is only needed for the fallback:
      # an anchored usage already counted the prompt it was sent with.
      def context_tokens(extra_chars: 0)
        # Fallback estimate of the whole transcript, used to keep the number honest
        # when the provider's usage anchor is stale or never grew.
        fallback_tokens = extra_chars.to_i / CHARS_PER_TOKEN
        @messages.each { |msg| fallback_tokens += self.class.message_tokens(msg, reasoning: false) }

        if context_anchored?
          start = @last_usage_watermark.to_i
          start += 1 if @messages[start] && @messages[start]["role"] == "assistant"
          trailing = @messages[start..].to_a.sum { |msg| self.class.message_tokens(msg, reasoning: false) }
          usage_tokens = @last_usage.prompt_tokens + @last_usage.completion_tokens
          anchored_tokens = usage_tokens + trailing
          # Never report less than the transcript we are actually about to send:
          # a stale anchor must not freeze the context size.
          tokens = [ anchored_tokens, fallback_tokens ].max
          {
            tokens: tokens.ceil,
            usage_tokens: usage_tokens,
            trailing_tokens: trailing.ceil,
            anchored: true
          }
        else
          { tokens: fallback_tokens.ceil, usage_tokens: 0, trailing_tokens: fallback_tokens.ceil, anchored: false }
        end
      end

      # Approximate size of the next request, used to decide when to compact.
      # Shares its formula with /context so the footer and the compaction
      # trigger never disagree. Reasoning is deliberately excluded: past
      # reasoning is never sent (see #conversation_history).
      def estimated_tokens(extra_chars: 0)
        context_tokens(extra_chars: extra_chars)[:tokens]
      end

      # Approximate token cost of one message as it will be sent. The reasoning
      # block is included by default because the turn being executed sends it.
      def message_tokens(msg, reasoning: true)
        chars = text_chars(msg["content"])
        chars += text_chars(msg["reasoning_content"]) if reasoning && msg["reasoning_content"]
        chars += text_chars(JSON.generate(msg["tool_calls"])) if msg["tool_calls"]
        (chars / CHARS_PER_TOKEN).ceil
      rescue StandardError
        (text_chars(msg["content"]) / CHARS_PER_TOKEN).ceil
      end

      # Text length of a content payload, which may be a string or a list of
      # blocks (text/image parts).
      def text_chars(value)
        case value
        when String then value.length
        when Array then value.sum { |item| text_chars(item) }
        when Hash then text_chars(value["text"] || value["content"])
        when nil then 0
        else value.to_s.length
        end
      end
    end
  end
end
