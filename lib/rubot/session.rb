# frozen_string_literal: true

require "json"
require "fileutils"
require "set"
require "time"
require_relative "usage"

module Rubot
  class Session
    # Message-count safety net used by the legacy summarizer.
    DEFAULT_MESSAGE_LIMIT = 100
    # Messages kept verbatim after a compaction so the model still has the
    # immediate turn in view.
    DEFAULT_KEEP_RECENT_MESSAGES = 6
    # Upper bound for the text sent to the summarizer in a single request.
    # Without it, compacting a very long transcript could overflow the
    # summarizer's own context window.
    MAX_SUMMARY_INPUT_CHARS = 24_000
    # How much of the running summary is injected into the system prompt. Each
    # compaction used to append another paragraph, so a long session ended up
    # re-sending every summary it had ever produced (35 KB in one live
    # session). The newest part is the relevant one; older paragraphs are
    # dropped from the prompt (the file keeps them until the next compaction
    # merges everything into one).
    MAX_SUMMARY_CHARS = 6_000
    # User messages waiting to be extracted into MEMORY.md. Bounded so a long
    # stretch between extractions cannot grow the session file without limit.
    MAX_MEMORY_BACKLOG = 20

    attr_reader :id, :messages, :workspace, :usage, :last_usage, :cost
    attr_accessor :summary, :forced_skill, :model_override, :model_preset

    def initialize(id = "default", workspace: nil)
      @id = id
      @messages = []
      @workspace = workspace
      @summary = nil
      @forced_skill = nil
      @model_override = nil
      @model_preset = nil
      @usage = Usage.zero
      @last_usage = Usage.zero
      # Cumulative cost, priced per request with the rates of the model that
      # served it. nil means "no priced request yet".
      @cost = nil
      # True once a request could not be priced. The total is then incomplete
      # and the report re-prices the aggregate instead of showing a low number.
      @cost_partial = false
      # Message count at the moment the last usage was recorded. nil disables
      # the usage anchor for context estimates (see #context_tokens).
      @last_usage_watermark = nil
      @memory_backlog = []
      load!
    end

    # Record the token usage of one provider request. `raw` is the provider's
    # usage hash (OpenAI/Anthropic/Ollama shapes are all accepted). `rates`
    # are the prices in effect for the model that served the request, so the
    # cost is frozen at request time instead of being re-priced later with
    # whatever model the session happens to end on (Pi prices per message).
    def record_usage(raw, provider: nil, rates: nil)
      delta = Usage.from(raw, provider: provider)
      return nil if delta.nil?

      @last_usage = delta
      @last_usage_watermark = @messages.size
      @usage = @usage.merge(delta)
      add_cost(delta, rates)
      save!
      delta
    end

    # Same as #record_usage, but for requests that are not the user-facing turn
    # (memory extraction, summarization, cron). It adds to the totals without
    # replacing `last_usage` or the context anchor, which is what `/context`
    # uses to estimate how full the next request's context will be.
    def record_auxiliary_usage(raw, provider: nil, rates: nil)
      delta = Usage.from(raw, provider: provider)
      return nil if delta.nil?

      @usage = @usage.merge(delta)
      add_cost(delta, rates)
      save!
      delta
    end

    # User messages queued for the next memory extraction. Kept on the session
    # so the queue survives a restart and is shared by every agent instance
    # working on this session.
    def memory_backlog
      @memory_backlog ||= []
    end

    def push_memory_backlog(message)
      text = self.class.normalize_utf8(message.to_s).strip
      return false if text.empty?

      memory_backlog << text
      memory_backlog.shift while memory_backlog.size > MAX_MEMORY_BACKLOG
      save!
      true
    end

    # Remove and return everything queued so far.
    def take_memory_backlog
      items = memory_backlog.dup
      @memory_backlog = []
      save!
      items
    end

    # Returns true if summarization has already been applied to this session
    def summarized?
      !@summary.nil? && !@summary.strip.empty?
    end

    # Append additional text to the existing summary
    def append_summary(text)
      clean = self.class.normalize_utf8(text.to_s)
      if @summary.nil? || @summary.strip.empty?
        @summary = clean
      else
        @summary += "\n" + clean
      end
      save!
    end

    # Tool output (binary files, PNG bytes, latin-1 from a CLI) can be invalid
    # UTF-8. Such strings break JSON generation for the session file and for the
    # provider request, so everything that enters the transcript is forced to
    # valid UTF-8 here. Invalid bytes are replaced with U+FFFD.
    def self.normalize_utf8(value)
      case value
      when String
        str = value.dup.force_encoding(Encoding::UTF_8)
        str.valid_encoding? ? str : str.scrub
      when Array
        value.map { |item| normalize_utf8(item) }
      when Hash
        value.each_with_object({}) do |(key, val), acc|
          acc[normalize_utf8(key)] = normalize_utf8(val)
        end
      else
        value
      end
    end

    def add(role, content, tool_calls: nil, tool_call_id: nil, reasoning_content: nil)
      msg = {
        "role" => self.class.normalize_utf8(role),
        "content" => self.class.normalize_utf8(content),
        "timestamp" => Time.now.iso8601
      }
      msg["tool_calls"] = self.class.normalize_utf8(tool_calls) if tool_calls
      msg["tool_call_id"] = self.class.normalize_utf8(tool_call_id) if tool_call_id
      msg["reasoning_content"] = self.class.normalize_utf8(reasoning_content) if reasoning_content
      @messages << msg
      trim! if @workspace
      save!
      msg
    end

    def conversation_history(reasoning_tail: nil)
      # `reasoning_tail` limits reasoning_content to the newest N messages.
      # Providers bill every byte of the prompt, and the thinking of a turn
      # that has already finished is never needed again: only the reasoning
      # produced inside the turn still being executed has to survive (a tool
      # loop continues from it). nil keeps the old behaviour (send everything).
      reasoning_from = if reasoning_tail.nil?
        0
      else
        [ @messages.size - reasoning_tail.to_i, 0 ].max
      end

      history = @messages.each_with_index.map do |msg, index|
        entry = { "role" => msg["role"], "content" => msg["content"] }
        entry["tool_calls"] = msg["tool_calls"] if msg["tool_calls"]
        entry["tool_call_id"] = msg["tool_call_id"] if msg["tool_call_id"]
        entry["reasoning_content"] = msg["reasoning_content"] if msg["reasoning_content"] && index >= reasoning_from
        entry
      end
      remove_orphaned_tool_messages(history)
    end

    # Returns conversation history with an optional limit, ensuring no orphaned
    # tool_call_id references (tool results whose parent tool_call was trimmed).
    #
    # `max_tokens` additionally drops the oldest messages until the remaining
    # block fits that approximate budget (0/nil disables it).
    def safe_history(limit: nil, max_tokens: nil, reasoning_tail: nil)
      history = conversation_history(reasoning_tail: reasoning_tail)

      if limit && history.size > limit
        trim_index = history.size - limit

        # If the first kept message is a tool result, its parent assistant was
        # trimmed out. Skip all consecutive tool results to avoid orphaned IDs.
        while trim_index < history.size && history[trim_index]["role"] == "tool"
          trim_index += 1
        end

        history = history[trim_index..]
      end

      budget = max_tokens.to_i
      if budget.positive?
        trim_index = 0
        tokens = history.sum { |msg| self.class.message_tokens(msg) }
        while tokens > budget && trim_index < history.size
          tokens -= self.class.message_tokens(history[trim_index])
          trim_index += 1
        end
        # Same orphan rule as the count limit above.
        trim_index += 1 while trim_index < history.size && history[trim_index]["role"] == "tool"
        history = history[trim_index..] if trim_index.positive?
      end

      history
    end

    # Drop the old anchor when the hard message cap removes messages from the
    # front: the last usage no longer describes this transcript.
    def invalidate_context_anchor!
      @last_usage_watermark = nil
    end

    def add_cost(delta, rates)
      breakdown = Usage.cost(delta, rates)
      if breakdown.nil?
        @cost_partial = true
        return
      end

      @cost ||= { "input" => 0.0, "cached_input" => 0.0, "cache_creation" => 0.0, "output" => 0.0, "total" => 0.0 }
      breakdown.each { |key, value| @cost[key] = (@cost[key] || 0.0) + value.to_f }
    end

    # True when at least one request could not be priced (no rates known yet).
    def cost_partial?
      @cost_partial
    end

    def load_cost(raw)
      return nil unless raw.is_a?(Hash) && !raw.empty?

      raw.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value.to_f }
    end

    def message_count
      @messages.size
    end

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
      if context_anchored?
        start = @last_usage_watermark.to_i
        # The usage describes the request that produced the assistant message
        # appended right after it. That reply is already in completion_tokens,
        # so the trailing estimate starts on the message after it.
        start += 1 if @messages[start] && @messages[start]["role"] == "assistant"
        trailing = @messages[start..].to_a.sum { |msg| self.class.message_tokens(msg, reasoning: false) }
        usage_tokens = @last_usage.prompt_tokens + @last_usage.completion_tokens
        {
          tokens: (usage_tokens + trailing).ceil,
          usage_tokens: usage_tokens,
          trailing_tokens: trailing.ceil,
          anchored: true
        }
      else
        tokens = extra_chars.to_i / CHARS_PER_TOKEN
        @messages.each { |msg| tokens += self.class.message_tokens(msg, reasoning: false) }
        { tokens: tokens.ceil, usage_tokens: 0, trailing_tokens: tokens.ceil, anchored: false }
      end
    end

    # True when the last provider request still describes the transcript: it
    # is discarded by compaction and by the hard message trim, which is what
    # Pi does via `context_edit`/`compaction` invalidation.
    def context_anchored?
      @last_usage.requests.positive? && !@last_usage_watermark.nil?
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
    def self.message_tokens(msg, reasoning: true)
      chars = text_chars(msg["content"])
      chars += text_chars(msg["reasoning_content"]) if reasoning && msg["reasoning_content"]
      chars += text_chars(JSON.generate(msg["tool_calls"])) if msg["tool_calls"]
      (chars / CHARS_PER_TOKEN).ceil
    rescue StandardError
      (text_chars(msg["content"]) / CHARS_PER_TOKEN).ceil
    end

    # Text length of a content payload, which may be a string or a list of
    # blocks (text/image parts).
    def self.text_chars(value)
      case value
      when String then value.length
      when Array then value.sum { |item| text_chars(item) }
      when Hash then text_chars(value["text"] || value["content"])
      when nil then 0
      else value.to_s.length
      end
    end

    def clear!
      @messages = []
      @forced_skill = nil
      @summary = nil
      @model_override = nil
      @model_preset = nil
      @usage = Usage.zero
      @last_usage = Usage.zero
      @cost = nil
      @cost_partial = false
      @last_usage_watermark = nil
      @memory_backlog = []
      save!
    end

    # Summarize old messages down to `keep_recent` and fold the result into
    # the running summary. Used by `/compact` and by automatic compaction when
    # the configured context threshold is reached.
    #
    # Returns nil when there is nothing to do, otherwise a plain-data hash
    # (safe to cross a Ractor boundary):
    #   { summary:, summarized_messages:, kept_messages:,
    #     context_before:, context_after: }
    def compact!(provider:, keep_recent: DEFAULT_KEEP_RECENT_MESSAGES, system_prompt: nil)
      return nil unless @workspace
      return nil if @messages.empty?

      keep = keep_recent.to_i
      keep = 1 if keep < 1
      return nil if @messages.size <= keep

      cutoff = @messages.size - keep
      # Never keep a tool result whose assistant message (with tool_calls) is
      # about to be summarized away: that breaks the provider's pairing rules.
      while cutoff < @messages.size && @messages[cutoff]["role"] == "tool"
        cutoff += 1
      end
      return nil if cutoff <= 0

      to_summarize = @messages[0...cutoff]
      summary_text = call_summarizer(provider, system_prompt, to_summarize, previous: summary_text)
      return nil if summary_text.nil? || summary_text.strip.empty?

      prompt_chars = system_prompt.to_s.length
      context_before = context_tokens(extra_chars: prompt_chars)[:tokens]
      clean_summary = self.class.normalize_utf8(summary_text.strip)
      # Replace the old summary: the summarizer already merged it into this
      # one. Appending here is what made the prompt grow without bound.
      @summary = clean_summary
      @messages = @messages[cutoff..] || []
      # The transcript was rewritten, so the last request's usage no longer
      # describes it (Pi invalidates its context estimate the same way).
      invalidate_context_anchor!
      save!

      {
        summary: summary_text.strip,
        summarized_messages: to_summarize.size,
        kept_messages: @messages.size,
        context_before: context_before,
        context_after: context_tokens(extra_chars: prompt_chars)[:tokens]
      }
    end

    # Message-count based summarization kept for backwards compatibility and
    # as a safety net. New callers should prefer #compact! with a context
    # threshold.
    #
    # Returns the text that was summarized (the new summary fragment), or nil
    # if nothing was trimmed.
    def summarize_and_trim!(provider:, system_prompt:, limit: DEFAULT_MESSAGE_LIMIT)
      return nil unless @workspace
      return nil if @messages.empty?

      # Keep 60% of the limit and summarize the rest.
      keep = (limit * 0.6).to_i
      return nil if @messages.size <= keep

      result = compact!(provider: provider, keep_recent: keep, system_prompt: system_prompt)
      result && result[:summary]
    end

    # Returns the summary text for inclusion in the system prompt. Long
    # summaries keep only the newest part: the summary is written
    # chronologically, so the tail is what the current work depends on.
    def summary_text
      return nil if @summary.nil? || @summary.strip.empty?

      text = @summary.strip
      return text if text.length <= MAX_SUMMARY_CHARS

      tail = text[-MAX_SUMMARY_CHARS..].to_s
      # Start at a sentence/paragraph boundary instead of mid-word.
      boundary = tail.index(/[.\n]/)
      tail = tail[(boundary + 1)..].to_s.lstrip if boundary && boundary < 200
      "…(earlier summary omitted)\n#{tail}"
    end

    def file_path
      return nil unless @workspace
      File.join(@workspace, "sessions", "#{@id}.json")
    end

    # Directory holding one JSON file per session.
    def self.sessions_dir(workspace)
      workspace && File.join(workspace, "sessions")
    end

    # A session id that is not in use yet, used by the TUI to start a new
    # conversation on every launch. The file itself is not created until the
    # session has a message (see #save!), so quitting an untouched launch
    # leaves nothing behind.
    def self.fresh_id(workspace, prefix: "default", stamp: nil)
      base = "#{prefix}-#{stamp || Time.now.strftime("%Y%m%d-%H%M%S")}"
      dir = sessions_dir(workspace)
      return base unless dir

      candidate = base
      counter = 1
      while File.exist?(File.join(dir, "#{candidate}.json"))
        counter += 1
        candidate = "#{base}-#{counter}"
      end
      candidate
    end

    # Plain-data summaries of the sessions saved in `workspace`, newest
    # first. Sessions without messages (and unreadable files) are left out:
    # /resume only offers something that can actually be continued.
    def self.index(workspace)
      dir = sessions_dir(workspace)
      return [] unless dir && Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.json"))
        .filter_map { |path| describe(path) }
        .sort_by { |entry| entry[:timestamp] }
        .reverse
        .map { |entry| entry.except(:timestamp) }
    end

    # Summary of one saved session, or nil when there is nothing to resume.
    def self.find(workspace, id)
      dir = sessions_dir(workspace)
      return nil unless dir

      describe(File.join(dir, "#{id}.json"))&.except(:timestamp)
    end

    # Full message list of a saved session, used by /resume to restore the
    # transcript exactly as it was.
    def self.transcript(workspace, id)
      dir = sessions_dir(workspace)
      return [] unless dir

      path = File.join(dir, "#{id}.json")
      return [] unless File.file?(path)

      data = JSON.parse(File.read(path))
      messages = data["messages"]
      messages.is_a?(Array) ? normalize_utf8(messages) : []
    rescue JSON::ParserError, SystemCallError, EncodingError
      []
    end

    # Read one session file into the summary used by #index and #find.
    def self.describe(path)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      messages = data["messages"]
      return nil unless messages.is_a?(Array) && !messages.empty?

      updated = begin
        Time.iso8601(data["updated_at"].to_s)
      rescue ArgumentError, TypeError
        File.mtime(path)
      end

      {
        id: File.basename(path, ".json"),
        messages: messages.size,
        updated_at: updated.iso8601,
        timestamp: updated.to_f,
        last_prompt: last_prompt(messages)
      }
    rescue JSON::ParserError, SystemCallError, EncodingError
      nil
    end

    # The newest thing the user asked, which is what /resume shows for each
    # session. Falls back to any message with text.
    def self.last_prompt(messages)
      message = messages.reverse.find { |msg| msg["role"] == "user" && !text_content(msg["content"]).empty? }
      message ||= messages.reverse.find { |msg| !text_content(msg["content"]).empty? }
      snippet(text_content(message && message["content"]), 100)
    end

    def self.text_content(content)
      case content
      when String then content
      when Array
        content.filter_map { |part| part.is_a?(Hash) ? part["text"] : part }.join(" ")
      when Hash then content["text"].to_s
      else ""
      end
    end

    def self.snippet(text, limit)
      clean = text.to_s.gsub(/\s+/, " ").strip
      return clean if clean.length <= limit

      "#{clean[0, limit - 1]}…"
    end

    # Persist session to disk. Uses an exclusive file lock so a session
    # file is never partially written even if another process/Ractor
    # touches it at the same time.
    #
    # A session that has no content yet is not written, and an existing file
    # for it is removed. That keeps a launch that the user closes before
    # typing anything out of the sessions directory (and out of /resume).
    def save!
      return unless file_path

      unless persistable?
        FileUtils.rm_f(file_path)
        return
      end

      FileUtils.mkdir_p(File.dirname(file_path))
      data = {
        "id" => @id,
        "created_at" => @messages.first&.fetch("timestamp", Time.now.iso8601),
        "updated_at" => Time.now.iso8601,
        "messages" => @messages
      }
      data["summary"] = @summary if @summary
      data["forced_skill"] = @forced_skill if @forced_skill
      data["model_override"] = @model_override if @model_override
      data["model_preset"] = @model_preset if @model_preset
      data["usage"] = @usage.to_h
      data["last_usage"] = @last_usage.to_h
      data["cost"] = @cost if @cost
      data["cost_partial"] = true if @cost_partial
      data["last_usage_watermark"] = @last_usage_watermark if @last_usage_watermark
      data["memory_backlog"] = @memory_backlog if @memory_backlog && !@memory_backlog.empty?

      # Generate before opening the file: JSON.pretty_generate can raise (e.g.
      # invalid UTF-8), and truncating first would leave an empty session file.
      payload = JSON.pretty_generate(self.class.normalize_utf8(data))

      File.open(file_path, File::WRONLY | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX)
        file.truncate(0)
        file.write(payload)
        file.flush
        file.flock(File::LOCK_UN)
      end
    end

    private

    # A freshly created session has nothing worth a file yet. Messages are the
    # obvious content; summary, usage and the memory backlog are kept too, so
    # state written before the first message (or by tests/tools) survives.
    def persistable?
      return true unless @messages.empty?
      return true if @summary && !@summary.strip.empty?
      return true if @forced_skill || @model_override || @model_preset
      return true if @usage.requests.positive?
      return true if @last_usage.requests.positive?
      return true if @memory_backlog && !@memory_backlog.empty?

      false
    end

    # Call the LLM to summarize a batch of old messages into a compact form.
    # Very long transcripts are split into chunks so the summarizer request
    # itself stays within the model's context window.
    def call_summarizer(provider, system_prompt, messages, previous: nil)
      batches = split_summary_batches(messages)
      summaries = batches.map do |batch|
        # A single batch can take the previous summary directly in its prompt;
        # with several batches the merge step below does that instead.
        summarize_batch(provider, system_prompt, batch,
                        previous: batches.size == 1 ? previous : nil)
      end.compact
      return nil if summaries.empty?
      return summaries.first if summaries.size == 1

      merged = summarize_batch(
        provider,
        system_prompt,
        summaries.map { |text| { "role" => "assistant", "content" => text } },
        merging: true,
        previous: previous
      )
      merged || [ previous, *summaries ].compact.join("\n\n")
    end

    def summarize_batch(provider, system_prompt, messages, merging: false, previous: nil)
      context = messages.map do |msg|
        role = msg["role"]
        content = msg["content"] || ""
        "[#{role}]: #{content}"
      end.join("\n")

      instruction = if merging
        "Merge the following partial summaries into one concise paragraph."
      else
        "Summarize the following conversation history into a concise paragraph."
      end

      previous_block = previous.to_s.strip.empty? ? "" : <<~PREV
        Existing summary of even older turns. Merge it with the new material
        into one cohesive summary; do not repeat it verbatim:
        #{previous}

      PREV

      summarize_prompt = <<~PROMPT.strip
        #{instruction}
        #{previous_block}
        Preserve important facts, decisions, and outcomes. Omit pleasantries
        and redundant exchanges. Keep it under 200 words.

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

    def load!
      return unless file_path && File.exist?(file_path)

      raw = File.read(file_path)
      return if raw.strip.empty?

      data = JSON.parse(raw)
      @messages = self.class.normalize_utf8(data["messages"] || [])
      @summary = data["summary"] if data["summary"]
      @forced_skill = data["forced_skill"] if data["forced_skill"]
      @model_override = data["model_override"] if data["model_override"]
      @model_preset = data["model_preset"] if data["model_preset"]
      @usage = Usage.from_h(data["usage"])
      @last_usage = Usage.from_h(data["last_usage"])
      @cost = load_cost(data["cost"])
      @cost_partial = data["cost_partial"] == true
      @last_usage_watermark = data["last_usage_watermark"].is_a?(Integer) ? data["last_usage_watermark"] : nil
      @memory_backlog = Array(data["memory_backlog"]).map(&:to_s)
    rescue JSON::ParserError => e
      # A truncated/corrupt session must not take the bot down: start fresh.
      warn "[session] ignoring unreadable session #{file_path}: #{e.message}"
      @messages = []
    end

    def trim!
      # Keep only the last N messages to avoid context overflow
      return unless @workspace
      # We'll use the config's history_limit later, for now keep last 100
      limit = 100
      return unless @messages.size > limit

      trim_index = @messages.size - limit

      # If the first kept message is a tool result, its parent assistant message
      # (with tool_calls) was trimmed out. Skip all consecutive tool results to
      # prevent orphaned tool_call_id references that cause API errors.
      while trim_index < @messages.size && @messages[trim_index]["role"] == "tool"
        trim_index += 1
      end

      @messages = @messages[trim_index..]
      invalidate_context_anchor!
    end

    # Remove tool messages whose tool_call_id doesn't correspond to any
    # tool_call ID remaining in the history (safety net for edge cases).
    def remove_orphaned_tool_messages(history)
      valid_ids = Set.new
      history.each do |msg|
        next unless msg["tool_calls"]
        msg["tool_calls"].each do |tc|
          valid_ids << tc["id"] if tc["id"]
        end
      end
      history.reject { |msg| msg["role"] == "tool" && !valid_ids.include?(msg["tool_call_id"]) }
    end
  end
end
