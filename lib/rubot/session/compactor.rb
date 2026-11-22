# frozen_string_literal: true

module Rubot
  class Session
    # Compaction: folding the older half of a transcript into one summary.
    #
    # This is the only part of a session that calls a model. It lives in its own
    # class so that fact stays visible: everything else in Session is a window onto
    # messages, and a window does not need a provider to work.
    #
    # The compactor is handed the session it compacts - the window math moves
    # messages, the provider work does not - and holds nothing between calls.
    class Compactor
      def initialize(session)
        @session = session
      end

      # Summarize old messages down to `keep_recent` and fold the result into
      # the running summary. Used by `/compact` and by automatic compaction when
      # the configured context threshold is reached.
      #
      # Returns nil when there is nothing to do, otherwise a plain-data hash
      # (safe to cross a Ractor boundary):
      #   { summary:, summarized_messages:, kept_messages:,
      #     context_before:, context_after: }
      def compact!(provider:, keep_recent: DEFAULT_KEEP_RECENT_MESSAGES, keep_recent_tokens: nil, min_keep: nil, system_prompt: nil, provider_factory: nil)
        return nil unless @session.workspace
        return nil if @session.messages.empty?

        if keep_recent_tokens && keep_recent_tokens.to_i.positive?
          budget = keep_recent_tokens.to_i
          keep = 0
          used = 0
          i = @session.messages.size - 1
          while i >= 0
            msg_tokens = Session.message_tokens(@session.messages[i], reasoning: false)
            break if keep.positive? && used + msg_tokens > budget

            used += msg_tokens
            keep += 1
            i -= 1
          end
          keep = 1 if keep < 1
        else
          keep = keep_recent.to_i
          keep = 1 if keep < 1
        end

        keep = [ keep, min_keep.to_i ].max if min_keep
        return nil if @session.messages.size <= keep

        cutoff = @session.messages.size - keep
        # Never keep a tool result whose assistant message (with tool_calls) is
        # about to be summarized away: that breaks the provider's pairing rules.
        while cutoff < @session.messages.size && @session.messages[cutoff]["role"] == "tool"
          cutoff += 1
        end
        return nil if cutoff <= 0

        to_summarize = @session.messages[0...cutoff]
        # The merge input is the whole running summary, not the capped view the
        # prompt shows: the summarizer is the one place where dropping the older
        # part is a decision, and it can only make it with the text in hand.
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        summary_text = call_summarizer(provider, system_prompt, to_summarize, previous: @session.summary,
                                       provider_factory: provider_factory)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        return nil if summary_text.nil? || summary_text.strip.empty?

        prompt_chars = system_prompt.to_s.length
        context_before = @session.context_tokens(extra_chars: prompt_chars)[:tokens]
        clean_summary = Session.normalize_utf8(summary_text.strip)
        # The absolute index of the first message being summarized away. Capture
        # it before drop_front! moves the window: afterwards @archive_offset and
        # @messages.size cancel each other out and the cut is no longer locatable.
        # A reader refreshing the page uses this to put the seam in the turn that
        # was in flight when compaction ran.
        cut_index = @session.archive_offset + cutoff
        # Replace the old summary: the summarizer already merged it into this
        # one. Appending here is what made the prompt grow without bound.
        @session.summary = clean_summary
        @session.drop_front!(cutoff)
        # The transcript was rewritten, so the last request's usage no longer
        # describes it (Pi invalidates its context estimate the same way).
        @session.invalidate_context_anchor!
        @session.save!

        {
          summary: summary_text.strip,
          summarized_messages: to_summarize.size,
          kept_messages: @session.messages.size,
          cut_index: cut_index,
          context_before: context_before,
          context_after: @session.context_tokens(extra_chars: prompt_chars)[:tokens],
          elapsed: elapsed
        }
      end

      # Message-count based summarization kept for backwards compatibility and
      # as a safety net. New callers should prefer #compact! with a context
      # threshold.
      #
      # Returns the text that was summarized (the new summary fragment), or nil
      # if nothing was trimmed.
      def summarize_and_trim!(provider:, system_prompt:, limit: DEFAULT_MESSAGE_LIMIT)
        return nil unless @session.workspace
        return nil if @session.messages.empty?

        # Keep 60% of the limit and summarize the rest.
        keep = (limit * 0.6).to_i
        return nil if @session.messages.size <= keep

        result = compact!(provider: provider, keep_recent: keep, system_prompt: system_prompt)
        result && result[:summary]
      end
      private

      # Call the LLM to summarize a batch of old messages into a compact form.
      # Very long transcripts are split into chunks so the summarizer request
      # itself stays within the model's context window.
      #
      # A long transcript becomes dozens of batches, and each one is an LLM
      # request. Running them one after another made a 900-message compaction
      # take minutes. With a provider_factory the batches go out over a small
      # worker pool instead; results land in an indexed array so the summary is
      # assembled in the original order no matter which worker finished first.
      # Without a factory the old serial path stays, which keeps callers that
      # inject a single (often fake) provider behaving exactly as before.
      def call_summarizer(provider, system_prompt, messages, previous: nil, provider_factory: nil)
        batches = split_summary_batches(messages)
        carry = words_in(previous)
        # Each part carries the length it is allowed as well as its text, so the
        # merge can keep what the parts between them could hold instead of
        # answering in the length of one of them.
        budgets = batches.map do |batch|
          # A single batch can take the previous summary directly in its prompt;
          # with several batches the merge step below does that instead. Its own
          # budget carries what the summary already says, so merging more
          # material never makes the summary shorter than it was.
          summary_word_budget(batch_chars(batch)) + (batches.size == 1 ? carry : 0)
        end

        texts = if provider_factory && batches.size > 1
          summarize_batches_parallel(provider_factory, system_prompt, batches, budgets)
        else
          batches.map.with_index do |batch, i|
            summarize_batch(provider, system_prompt, batch,
                            previous: batches.size == 1 ? previous : nil,
                            word_budget: budgets[i])
          end
        end

        # A failed batch must not turn into a silent hole in the summary: the
        # caller drops every summarized message once a summary comes back, so a
        # nil here would lose that batch's content from both the summary and the
        # transcript. Refuse the whole compaction instead and keep the messages.
        return nil if texts.any?(&:nil?)

        parts = texts.each_with_index.map do |text, i|
          { "text" => text, "words" => budgets[i].clamp(MIN_SUMMARY_WORDS, MAX_SUMMARY_WORDS) }
        end
        return nil if parts.empty?
        return parts.first["text"] if parts.size == 1

        # The merge is one more summarizer request, so it belongs to the same
        # model as the batches. With a factory, build a fresh provider for it
        # rather than reusing the conversation's, which may be a different model.
        merge_provider = provider_factory ? provider_factory.call : provider
        merge_summaries(merge_provider, system_prompt, parts, previous) ||
          [ previous, *parts.map { |part| part["text"] } ].compact.join("\n\n")
      end

      # Fan the batch requests out over a few workers. Each worker builds its own
      # provider from the factory: a provider carries per-request state (last
      # usage, cancellation), so sharing one across threads would let batches
      # overwrite each other's bookkeeping. The cancellation token is carried
      # over too, so a Stop still reaches the in-flight requests.
      def summarize_batches_parallel(provider_factory, system_prompt, batches, budgets)
        token = defined?(Cancellation) ? Cancellation.current : nil
        queue = Queue.new
        batches.each_index { |i| queue << i }
        texts = Array.new(batches.size)
        lock = Mutex.new

        [ batches.size, SUMMARY_WORKERS ].min.times.map do
          Thread.new do
            Thread.current[:rubot_cancellation] = token if token
            worker = provider_factory.call
            while (i = begin
              queue.pop(true)
            rescue ThreadError
              nil
            end)
              text = summarize_batch(worker, system_prompt, batches[i],
                                     previous: nil, word_budget: budgets[i])
              lock.synchronize { texts[i] = text }
            end
          rescue StandardError => e
            warn "[session:summarize] worker failed: #{e.class}: #{e.message}" if Rubot.debug?
          end
        end.each(&:join)

        texts
      end

      # Fold the partial summaries into one, a group at a time, until one is left.
      #
      # Merging them all in a single request is what a compaction with many
      # batches would do, and the request grows with the number of batches -- the
      # one thing the per-batch limit exists to prevent. A part is never re-written
      # alone: a group of one is already a summary.
      def merge_summaries(provider, system_prompt, parts, previous)
        first_round = true
        while parts.size > 1
          before = parts.size
          merged = summary_groups(parts).map do |group|
            next group.first if group.size == 1

            budget = group.sum { |part| part["words"] }.clamp(MIN_SUMMARY_WORDS, MAX_SUMMARY_WORDS)
            text = summarize_batch(
              provider,
              system_prompt,
              group.map { |part| { "role" => "assistant", "content" => part["text"] } },
              merging: true,
              previous: first_round ? previous : nil,
              word_budget: budget
            )
            text && { "text" => text, "words" => budget }
          end.compact
          first_round = false

          return nil if merged.empty?
          parts = merged
          return parts.first["text"] if parts.size == 1
          # No progress (every group held a single part): the join is honest
          # about having several summaries instead of looping forever.
          break if parts.size >= before
        end
        parts.map { |part| part["text"] }.join("\n\n")
      end

      # Parts packed greedily into groups that stay inside one summarizer request.
      def summary_groups(parts)
        groups = []
        current = []
        current_chars = 0

        parts.each do |part|
          size = part["text"].to_s.bytesize
          if !current.empty? && current_chars + size > MAX_SUMMARY_INPUT_CHARS
            groups << current
            current = []
            current_chars = 0
          end
          current << part
          current_chars += size
        end
        groups << current unless current.empty?
        groups
      end

      # How many words a summary of `chars` characters may take. It is a policy
      # number rather than a detail of the prompt string, so it lives in one
      # place and the tests can read it.
      def summary_word_budget(chars)
        (chars.to_i / SUMMARY_CHARS_PER_WORD).clamp(MIN_SUMMARY_WORDS, MAX_SUMMARY_WORDS)
      end

      def summarize_batch(provider, system_prompt, messages, merging: false, previous: nil,
                          word_budget: nil)
        context = messages.map do |msg|
          role = msg["role"]
          content = msg["content"] || ""
          "[#{role}]: #{content}"
        end.join("\n")

        instruction = if merging
          "Merge the following partial summaries into one cohesive summary."
        else
          "Summarize the following conversation history."
        end

        budget = (word_budget || summary_word_budget(context.length)).clamp(MIN_SUMMARY_WORDS,
                                                                           MAX_SUMMARY_WORDS)

        previous_block = previous.to_s.strip.empty? ? "" : <<~PREV
          Existing summary of even older turns. Merge it with the new material
          into one cohesive summary; do not repeat it verbatim:
          #{previous}

        PREV

        summarize_prompt = <<~PROMPT.strip
          #{instruction}
          #{previous_block}
          Preserve important facts, decisions, and outcomes: what was asked for,
          which files were read or changed and what changed in them, what failed
          and why, what is still open. Omit pleasantries and redundant exchanges.
          Keep it under #{budget} words.

          Conversation:
          #{context}
        PROMPT

        request = []
        sys = system_prompt.to_s.strip
        request << { "role" => "system", "content" => sys } unless sys.empty?
        request << { "role" => "user", "content" => summarize_prompt }

        result = provider.chat(request, tools: nil)
        content = result.is_a?(Hash) ? result["content"] : result.to_s
        content.to_s.strip.empty? ? nil : content
      rescue StandardError => e
        warn "[session:summarize] Failed: #{e.class}: #{e.message}" if Rubot.debug?
        nil
      end

      # A batch's total size, the same figure split_summary_batches limits by.
      def batch_chars(messages)
        messages.sum do |msg|
          size = msg["content"].to_s.bytesize
          size += JSON.generate(msg["tool_calls"]).bytesize if msg["tool_calls"]
          size
        end
      end

      def words_in(text)
        text.to_s.scan(/\S+/).size
      end

      # Split messages so no single summarizer request exceeds
      # MAX_SUMMARY_INPUT_CHARS.
      def split_summary_batches(messages)
        batches = []
        current = []
        current_chars = 0

        messages.each do |msg|
          size = msg["content"].to_s.bytesize
          size += JSON.generate(msg["tool_calls"]).bytesize if msg["tool_calls"]

          if !current.empty? && current_chars + size > MAX_SUMMARY_INPUT_CHARS
            batches << current
            current = []
            current_chars = 0
          end

          current << msg
          current_chars += size
        end

        batches << current unless current.empty?
        batches
      end
    end
  end
end
