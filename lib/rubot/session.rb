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
    # Hard cap on the transcript stored on disk. The request itself is bounded
    # by the context window and compaction; this only keeps a session file from
    # growing forever. 400 messages is roughly 50 tool-call rounds.
    #
    # Measured on this repo's own store before picking a different number
    # (73 sessions, 2026-11-10): three were parked at the cap, the ninetieth
    # percentile was 293 messages and the median 38 — so the ceiling is reached,
    # which is what a file-size guard is for. What the count is *not* is a
    # measure of size: the largest file held 388 messages at 3.8 MB while a
    # capped one held 400 at 1.0 MB, because a tool result can be a hundred
    # times the size of a sentence. Raising the cap would not buy context (the
    # window is 1M and compaction fires long before 400 messages); it would only
    # let those two files grow. A byte budget is the honest guard if this ever
    # needs to move.
    DEFAULT_MAX_MESSAGES = 400

    attr_reader :id, :messages, :workspace, :usage, :last_usage, :cost
    attr_reader :task, :cwd, :cache_history
    attr_accessor :summary, :forced_skill, :model_override, :model_preset, :title

    # How many recent requests keep their cache share. Enough to see a pattern
    # (a run of zeros is a busted cache, a stray zero is a compaction), short
    # enough that the session file does not grow for it.
    CACHE_HISTORY_LIMIT = 12

    def initialize(id = "default", workspace: nil, sessions_dir: nil, cwd: nil,
                   max_messages: DEFAULT_MAX_MESSAGES, archive: nil)
      @id = id
      @messages = []
      @workspace = workspace
      # Optional handle to the SQLite archive (see StoreClient). When present it
      # is the source of truth and the JSON file is only an export: the
      # transcript is appended to, not rewritten. The cache does not notice —
      # this is read once at load and written at save!, and neither touches
      # @messages in between.
      @archive = archive
      # Absolute index of @messages[0] in the archive, and how many of the
      # messages in @messages have already been written. The archive is
      # append-only, so trimming the front of the live window moves the offset
      # instead of renumbering anything.
      @archive_offset = 0
      @archived = 0
      # Where the JSON file goes. Defaults to <workspace>/sessions so callers
      # that only know a workspace keep working; the TUI passes the central
      # directory explicitly (Config#sessions_dir).
      @sessions_dir = sessions_dir || self.class.sessions_dir(workspace)
      # Directory this session was launched from, used to filter /resume.
      # nil means "no origin" (Telegram, one-shot runs, legacy files).
      @cwd = cwd
      @max_messages = max_messages.to_i.positive? ? max_messages.to_i : DEFAULT_MAX_MESSAGES
      # The user's original instruction for this session. Kept outside the
      # message list so neither the hard trim nor compaction can delete the
      # goal of a long task; it is injected into the system prompt.
      @task = nil
      @summary = nil
      @forced_skill = nil
      @model_override = nil
      @model_preset = nil
      # A name for the conversation, chosen by the model from the first prompt
      # (see SessionNamer). nil means "not named yet"; readers fall back to the
      # opening prompt.
      @title = nil
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
      # The system prompt this session was started with, and the epoch that
      # says whether it is still the right one (see #system_prompt).
      @system_prompt = nil
      @system_prompt_epoch = nil
      # Cache share of the last few requests, oldest first.
      @cache_history = []
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
      push_cache_history(delta)
      add_cost(delta, rates)
      save!
      delta
    end

    # Keep the cache share of this request so a reader can tell a broken cache
    # from a single cold request. A run of zeros is the shape of a prefix that
    # moves on every request; one zero after a compaction is expected.
    def push_cache_history(delta)
      return unless delta.requests.positive?

      @cache_history << delta.cache_hit_rate.round(4)
      @cache_history.shift while @cache_history.size > CACHE_HISTORY_LIMIT
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

    def add(role, content, tool_calls: nil, tool_call_id: nil, reasoning_content: nil, ui_diff: nil)
      msg = {
        "role" => self.class.normalize_utf8(role),
        "content" => self.class.normalize_utf8(content),
        "timestamp" => Time.now.iso8601
      }
      msg["tool_calls"] = self.class.normalize_utf8(tool_calls) if tool_calls
      msg["tool_call_id"] = self.class.normalize_utf8(tool_call_id) if tool_call_id
      msg["reasoning_content"] = self.class.normalize_utf8(reasoning_content) if reasoning_content
      # UI-only annotation (the before/after of a file write) so /resume can
      # redraw the diff. Not sent to the model: conversation_history builds a
      # fresh hash with only role/content/tool_calls/tool_call_id.
      msg["ui_diff"] = self.class.normalize_utf8(ui_diff) if ui_diff
      # The first user message is the task statement. Remember it before the
      # transcript can be trimmed, so a long turn cannot lose its own goal.
      @task = msg["content"].to_s.strip if role.to_s == "user" && @task.nil?
      @messages << msg
      trim! if @workspace
      save!
      msg
    end

    # The instruction that started this session, or nil for an empty session.
    # It survives compaction and the hard message trim because it is stored
    # beside the transcript, not in it.
    def task_statement
      text = @task.to_s.strip
      text.empty? ? nil : text
    end

    def conversation_history(reasoning_tail: nil)
      # `reasoning_tail` limits reasoning_content to the newest N messages.
      # Providers bill every byte of the prompt, and the thinking of a turn
      # that has already finished is never needed again: only the reasoning
      # produced inside the turn still being executed has to survive (a tool
      # loop continues from it). nil keeps the old behaviour (send everything).
      #
      # A reasoning block on a tool-call round is kept regardless of age. That
      # is not about the model needing it — it is about the prompt staying the
      # same from one request to the next. Recency is not a property the
      # provider's cache can follow: dropping a turn's reasoning the moment the
      # next turn starts rewrites the front of the transcript, and everything
      # after it is re-read uncached. Keeping them makes the payload
      # append-only, which the cache rewards: measured on a 135-message
      # session, the stable rule held a 99.8% cache hit where the recency rule
      # dropped to 0% at every turn boundary.
      #
      # The reasoning of a finished *answer* (an assistant message with no
      # tool calls) is still dropped: it is one message at the end of the turn
      # that ended, so the divergence it causes sits at the tail, where it
      # costs almost nothing.
      reasoning_from = if reasoning_tail.nil?
        0
      else
        [ @messages.size - reasoning_tail.to_i, 0 ].max
      end

      history = @messages.each_with_index.map do |msg, index|
        entry = { "role" => msg["role"], "content" => msg["content"] }
        entry["tool_calls"] = msg["tool_calls"] if msg["tool_calls"]
        entry["tool_call_id"] = msg["tool_call_id"] if msg["tool_call_id"]
        keeps_reasoning = index >= reasoning_from || !msg["tool_calls"].nil?
        entry["reasoning_content"] = msg["reasoning_content"] if msg["reasoning_content"] && keeps_reasoning
        entry
      end
      remove_orphaned_tool_messages(history)
    end

    # Returns conversation history with an optional limit, ensuring no orphaned
    # tool_call_id references (tool results whose parent tool_call was trimmed).
    #
    # `max_tokens` additionally drops the oldest messages until the remaining
    # block fits that approximate budget (0/nil disables it).
    #
    # Both limits land a block below the threshold instead of exactly on it, and
    # are allowed to grow a block past it before cutting again (see
    # TRIM_BLOCK_FRACTION). A window that slides one message per append moves the
    # front of every request with it, and nothing in front of the change is
    # reusable: the cached prefix is exactly the part that moved.
    def safe_history(limit: nil, max_tokens: nil, reasoning_tail: nil)
      history = conversation_history(reasoning_tail: reasoning_tail)

      limit = limit.to_i
      if limit.positive? && history.size > limit
        # Cut in whole blocks once a block has grown past the limit, so the front
        # of the window stands still for the block of appends that follows.
        # A boundary that moved on every append carried the cached prefix with
        # it, which is the whole reason the pin exists.
        block = trim_block_size(limit)
        trim_index = ((history.size - limit) / block + 1) * block
        trim_index = history.size - 1 if trim_index >= history.size

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
        # The same block rule, in messages: the boundary only moves when a whole
        # block of growth has pushed the budget over, so the prefix survives the
        # appends in between. Measured on a 2k-token budget over 200 appends of
        # ~50-token messages: 35 moves, one per 4 appends — a tenth of the
        # window, which is exactly the rule. A bigger block would break the
        # cache less often and throw away more history each time it did; the
        # budget is the reader's own choice of window, so the fraction follows
        # it rather than a fixed count.
        block = trim_block_size(history.size)
        trim_index = ((trim_index + block - 1) / block) * block
        trim_index = history.size - 1 if trim_index >= history.size
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

    # The system prompt is pinned for the life of a session instead of being
    # rebuilt on every request.
    #
    # Rebuilding it is what made prompt caching useless here. The system prompt
    # sits at the front of every request, so one changed character there
    # dropped the entire cached prefix: measured against the same gateway, an
    # edit anywhere inside the system message took the cache hit from 99% to
    # 0%. Memory extraction rewrites MEMORY.md after most turns and the
    # composed prompt included it, so the prefix moved constantly — which is
    # how a session that was never trimmed still ran at a 0% cache hit on a
    # 54k-token prompt.
    #
    # `epoch` is the fingerprint of the inputs whose change *must* reach the
    # model: the model itself, the summary rewritten by compaction, and a
    # forced skill. Everything else (a new memory line, an edited skill file)
    # waits for the next epoch instead of costing a full re-read every request.
    def system_prompt_for(epoch)
      return nil unless @system_prompt
      return nil unless @system_prompt_epoch == epoch

      @system_prompt
    end

    def store_system_prompt(prompt, epoch)
      changed = @system_prompt != prompt || @system_prompt_epoch != epoch
      @system_prompt = prompt
      @system_prompt_epoch = epoch
      save! if changed
      changed
    end

    # Forget the pinned prompt so the next request rebuilds it. Compaction
    # calls this because it rewrites the summary, and a user-facing refresh can
    # call it to pick up memory written since the session started.
    def clear_system_prompt!
      return false if @system_prompt.nil?

      @system_prompt = nil
      @system_prompt_epoch = nil
      save!
      true
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
      # A clear opens a new window instead of emptying the archive: the next
      # message lands after what came before it, so no index is ever reused and
      # nothing is deleted.
      drop_front!(@messages.size)
      @forced_skill = nil
      @summary = nil
      @task = nil
      @title = nil
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
      drop_front!(cutoff)
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
      return nil unless @sessions_dir
      File.join(@sessions_dir, "#{@id}.json")
    end

    # Directory holding one JSON file per session.
    def self.sessions_dir(workspace)
      workspace && File.join(workspace, "sessions")
    end

    # A session id that is not in use yet, used by the TUI to start a new
    # conversation on every launch. The file itself is not created until the
    # session has a message (see #save!), so quitting an untouched launch
    # leaves nothing behind.
    def self.fresh_id(workspace = nil, prefix: "default", stamp: nil, dir: nil)
      base = "#{prefix}-#{stamp || Time.now.strftime("%Y%m%d-%H%M%S")}"
      dir ||= sessions_dir(workspace)
      return base unless dir

      candidate = base
      counter = 1
      archive = store
      while File.exist?(File.join(dir, "#{candidate}.json")) || archive&.session?(candidate)
        counter += 1
        candidate = "#{base}-#{counter}"
      end
      candidate
    end

    # Plain-data summaries of the sessions saved in `workspace` (or in `dir`,
    # which names the sessions directory directly), newest first.
    #
    # `cwd:` narrows the list to the conversations started from one directory.
    # It defaults to :all; pass a path to get an exact match, which also drops
    # every session without a recorded origin (Telegram chats, legacy files).
    # Sessions without messages (and unreadable files) are left out: /resume
    # only offers something that can actually be continued.
    # The archive, when the process has one (set by SessionPool at boot).
    #
    # These three readers are the seam: channels ask for a list, a summary or a
    # transcript and do not care where it comes from. With the archive set they
    # answer from SQLite; without it (the fallback when it cannot be opened) the
    # JSON files answer exactly as before.
    class << self
      attr_accessor :store
    end

    def self.index(workspace = nil, cwd: :all, dir: nil)
      dir ||= sessions_dir(workspace)
      if (archive = store) && dir
        entries = archive.sidebar(limit: 1000).map { |row| entry_from_row(row) }
        entries = entries.select { |entry| entry[:cwd] == cwd } unless cwd == :all
        return entries
      end
      return [] unless dir && Dir.exist?(dir)

      entries = Dir.glob(File.join(dir, "*.json")).filter_map { |path| describe(path) }
      entries = entries.select { |entry| entry[:cwd] == cwd } unless cwd == :all

      entries
        .sort_by { |entry| entry[:timestamp] }
        .reverse
        .map { |entry| entry.except(:timestamp) }
    end

    # Summary of one saved session, or nil when there is nothing to resume.
    def self.find(workspace, id, dir: nil)
      dir ||= sessions_dir(workspace)
      if (archive = store)
        row = archive.sidebar(limit: 1000).find { |entry| entry[:id] == id.to_s }
        return row && entry_from_row(row)
      end
      return nil unless dir

      describe(File.join(dir, "#{id}.json"))&.except(:timestamp)
    end

    # Full message list of a saved session, used by /resume to restore the
    # transcript exactly as it was.
    def self.transcript(workspace, id, dir: nil)
      dir ||= sessions_dir(workspace)
      if (archive = store)
        loaded = archive.load_session(id)
        return loaded ? normalize_utf8(loaded[:messages]) : []
      end
      return [] unless dir

      path = File.join(dir, "#{id}.json")
      return [] unless File.file?(path)

      data = JSON.parse(File.read(path))
      messages = data["messages"]
      messages.is_a?(Array) ? normalize_utf8(messages) : []
    rescue JSON::ParserError, SystemCallError, EncodingError
      []
    end

    # The list shape the channels already expect from #describe. `updated_at` is
    # what a list prints as the age of a conversation; leaving it out made every
    # entry read as "unknown" once the archive answered instead of the files.
    # `last_prompt` stays nil here: the archive keeps the name in `title` and the
    # newest prompt would cost one query per session to dig back out.
    def self.entry_from_row(row)
      {
        id: row[:id],
        title: row[:title].to_s,
        updated_at: row[:updated_at],
        timestamp: row[:timestamp],
        messages: row[:messages].to_i,
        cwd: row[:cwd],
        last_prompt: nil
      }
    end

    # What a session list prints as the name of one entry: the name the model
    # gave it, the prompt it was opened with, its last prompt, or the id when
    # none of those are there. The archive only has the first two, the JSON
    # files have all of them, so the chain is what keeps the two paths looking
    # the same.
    def self.label(entry)
      [ entry[:title], entry[:last_prompt], entry[:id] ]
        .map { |value| value.to_s.strip }
        .find { |value| !value.empty? }
        .to_s
    end

    # Read one session file into the summary used by #index and #find.
    def self.describe(path)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      describe_data(data, id: File.basename(path, ".json"), mtime: File.mtime(path))
    rescue JSON::ParserError, SystemCallError, EncodingError
      nil
    end

    # The same summary from already-parsed data, so a caller that also needs the
    # messages (the SQLite importer) does not parse the file twice.
    def self.describe_data(data, id:, mtime: nil)
      messages = data["messages"]
      return nil unless messages.is_a?(Array) && !messages.empty?

      updated = begin
        Time.iso8601(data["updated_at"].to_s)
      rescue ArgumentError, TypeError
        mtime || Time.now
      end

      {
        id: id,
        messages: messages.size,
        updated_at: updated.iso8601,
        timestamp: updated.to_f,
        cwd: data["cwd"].to_s.strip.empty? ? nil : data["cwd"].to_s,
        last_prompt: last_prompt(messages),
        # What the conversation was opened with. /resume lists the newest
        # prompt because it is about continuing; a sidebar lists conversations,
        # and a conversation is known by the question that started it — or by
        # the name the model gave it once the first turn finished.
        title: title_for(messages, data["title"])
      }
    end

    # The newest thing the user asked, which is what /resume shows for each
    # session. Falls back to any message with text.
    def self.last_prompt(messages)
      message = messages.reverse.find { |msg| msg["role"] == "user" && !text_content(msg["content"]).empty? }
      message ||= messages.reverse.find { |msg| !text_content(msg["content"]).empty? }
      snippet(text_content(message && message["content"]), 100)
    end

    # The name a session is listed under: the model-chosen title when one has
    # been stored, otherwise the opening prompt.
    def self.title_for(messages, title)
      stored = title.to_s.gsub(/\s+/, " ").strip
      return snippet(stored, 60) unless stored.empty?

      first_prompt(messages)
    end

    # The first thing the user asked, used as the conversation's name.
    def self.first_prompt(messages)
      message = messages.find { |msg| msg["role"] == "user" && !text_content(msg["content"]).empty? }
      snippet(text_content(message && message["content"]), 60)
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
      return save_to_archive! if @archive
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
      data["cwd"] = @cwd if @cwd
      data["task"] = @task if @task
      data["title"] = @title if @title
      data["summary"] = @summary if @summary
      data["forced_skill"] = @forced_skill if @forced_skill
      data["model_override"] = @model_override if @model_override
      data["model_preset"] = @model_preset if @model_preset
      data["usage"] = @usage.to_h
      data["last_usage"] = @last_usage.to_h
      data["cost"] = @cost if @cost
      data["cost_partial"] = true if @cost_partial
      data["last_usage_watermark"] = @last_usage_watermark if @last_usage_watermark
      data["cache_history"] = @cache_history if @cache_history && !@cache_history.empty?
      data["system_prompt"] = @system_prompt if @system_prompt
      data["system_prompt_epoch"] = @system_prompt_epoch if @system_prompt_epoch
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

    # Write only what is new. The old file path rewrote the whole transcript on
    # every save — up to 3.7 MB per turn on this repo's sessions — and the JSON
    # file is now an export rather than the store.
    #
    # Nothing here touches @messages, so the payload the model is sent stays
    # identical to what it was before the save: the prompt cache is not affected
    # by a turn being persisted.
    def save_to_archive!
      return false unless persistable?

      pending = @messages[@archived..] || []
      if pending.any?
        @archive.append(@id, pending, start_index: @archive_offset + @archived)
        @archived += pending.size
      end
      @archive.save_meta(
        @id,
        meta: archive_meta,
        messages_start: @archive_offset,
        title: @title,
        cwd: @cwd,
        created_at: @messages.first&.fetch("timestamp", nil)
      )
      true
    end

    # The same fields the JSON file carried. Keys match, so load! restores from
    # either source through one path; nil means "not set", not "unset it".
    def archive_meta
      {
        "summary" => @summary,
        "task" => @task,
        "forced_skill" => @forced_skill,
        "model_override" => @model_override,
        "model_preset" => @model_preset,
        "usage" => @usage.to_h,
        "last_usage" => @last_usage.to_h,
        "cost" => @cost,
        "cost_partial" => @cost_partial,
        "last_usage_watermark" => @last_usage_watermark,
        "cache_history" => @cache_history,
        # The pin: losing either of these rebuilds the system prompt, and a
        # rebuilt prompt at the front of the request is a cold cache.
        "system_prompt" => @system_prompt,
        "system_prompt_epoch" => @system_prompt_epoch,
        "memory_backlog" => @memory_backlog
      }.compact
    end

    # Drop `count` messages off the front of the live window. The archive keeps
    # them: only the window moves, so trimming never renumbers anything and a
    # reload returns exactly what the old JSON file would have held.
    def drop_front!(count)
      count = count.to_i
      return if count <= 0

      count = @messages.size if count > @messages.size
      @messages = @messages[count..] || []
      @archive_offset += count
      @archived = [ @archived - count, 0 ].max
    end

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
      data = @archive ? archive_state : file_state
      return unless data

      @messages = self.class.normalize_utf8(data["messages"] || [])
      # Everything loaded is already in the archive; only what is appended
      # afterwards needs writing.
      @archived = @messages.size if @archive
      @cwd = data["cwd"].to_s.strip.empty? ? nil : data["cwd"].to_s if data.key?("cwd")
      @task = data["task"] if data["task"]
      # Sessions written before the task field existed: recover the first user
      # message if the transcript still starts with one.
      if @task.nil? && @messages.first && @messages.first["role"] == "user"
        @task = @messages.first["content"].to_s.strip
      end
      @summary = data["summary"] if data["summary"]
      @title = data["title"] if data["title"]
      @forced_skill = data["forced_skill"] if data["forced_skill"]
      @model_override = data["model_override"] if data["model_override"]
      @model_preset = data["model_preset"] if data["model_preset"]
      @usage = Usage.from_h(data["usage"])
      @last_usage = Usage.from_h(data["last_usage"])
      @cost = load_cost(data["cost"])
      @cost_partial = data["cost_partial"] == true
      @last_usage_watermark = data["last_usage_watermark"].is_a?(Integer) ? data["last_usage_watermark"] : nil
      @cache_history = Array(data["cache_history"]).map(&:to_f).last(CACHE_HISTORY_LIMIT)
      @system_prompt = data["system_prompt"].to_s.empty? ? nil : data["system_prompt"].to_s
      @system_prompt_epoch = data["system_prompt_epoch"].is_a?(Hash) ? data["system_prompt_epoch"] : nil
      @memory_backlog = Array(data["memory_backlog"]).map(&:to_s)
    end

    # The session state as the archive holds it: the messages it returned (which
    # already start at `messages_start`) plus the metadata blob under the same
    # keys the JSON file used, so one restore path serves both.
    def archive_state
      loaded = @archive.load(@id)
      return nil unless loaded

      @archive_offset = loaded[:start].to_i
      (loaded[:meta] || {}).merge("messages" => loaded[:messages] || [])
    end

    def file_state
      return nil unless file_path && File.exist?(file_path)

      raw = File.read(file_path)
      return nil if raw.strip.empty?

      JSON.parse(raw)
    rescue JSON::ParserError => e
      # A truncated/corrupt session must not take the bot down: start fresh.
      warn "[session] ignoring unreadable session #{file_path}: #{e.message}"
      nil
    end

    # Share of the cap dropped in a single cut once the transcript reaches it.
    #
    # Dropping one message per append keeps the transcript at the cap, and that
    # costs real money: every append moves the front of the conversation, and a
    # provider's prompt cache matches on the prefix, so a session parked at the
    # cap misses it on every request and pays the full input price for its whole
    # transcript again. Measured on this repo's own sessions, a capped one cost
    # 5x per request ($0.0056 vs $0.0011) with a 45% cache hit next to 98% for
    # sessions below the cap. Cutting a block at a time leaves the prefix stable
    # for many requests, so the cache stays warm between cuts.
    TRIM_BLOCK_FRACTION = 0.1

    # How many messages one cut removes. Always at least one, and never more
    # than the cap itself, so a small `max_messages` still behaves.
    def trim_block_size(limit)
      [ (limit * TRIM_BLOCK_FRACTION).round, 1 ].max
    end

    def trim!
      # Keep only the last N messages so the session file cannot grow forever.
      # This is a last resort: the request is bounded by the context window and
      # compaction, and the task statement lives outside @messages.
      return unless @workspace
      limit = @max_messages
      return unless limit.positive? && @messages.size > limit

      # Land below the cap instead of exactly on it (see TRIM_BLOCK_FRACTION):
      # the next `limit - block` appends then leave the prefix untouched.
      trim_index = @messages.size - limit + trim_block_size(limit)
      trim_index = 0 if trim_index.negative?
      # A cut must never empty the transcript the turn is still being built on.
      trim_index = @messages.size - 1 if trim_index >= @messages.size

      # If the first kept message is a tool result, its parent assistant message
      # (with tool_calls) was trimmed out. Skip all consecutive tool results to
      # prevent orphaned tool_call_id references that cause API errors.
      while trim_index < @messages.size && @messages[trim_index]["role"] == "tool"
        trim_index += 1
      end

      @messages = @messages[trim_index..]
      @archive_offset += trim_index
      @archived = [ @archived - trim_index, 0 ].max
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
