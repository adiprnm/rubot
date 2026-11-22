# frozen_string_literal: true

require "json"
require "fileutils"
require "set"
require "time"
require_relative "usage"
require_relative "session/tokens"

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
    # How many summarizer requests may be in flight at once. A long transcript
    # splits into dozens of batches; running them serially made compaction take
    # minutes. Four is the same ceiling the tool runner uses, low enough not to
    # trip the gateway's rate limit but enough to cut the wall time severalfold.
    SUMMARY_WORKERS = 4
    # How much of the running summary is injected into the system prompt. Each
    # compaction used to append another paragraph, so a long session ended up
    # re-sending every summary it had ever produced (35 KB in one live
    # session). The newest part is the relevant one; older paragraphs are
    # dropped from the prompt (the file keeps them until the next compaction
    # merges everything into one).
    #
    # The cap has to leave room for a summary that is actually a summary: with
    # the length the summarizer is now allowed (see #summary_word_budget), one
    # compaction of a long, tool-heavy transcript lands around 8 KB. Capping at
    # 6 KB clipped the newest part of exactly those summaries while the file
    # kept the rest.
    MAX_SUMMARY_CHARS = 12_000
    # How long a summary may be, in words, for a given amount of material.
    #
    # A fixed 200-word answer to 278 messages was not a summary, it was a
    # caption: the model got one paragraph, could not tell what it had already
    # read or changed, and spent the next turn re-exploring the repo. One word
    # per 40 characters keeps the summary near 15% of what it replaces, which
    # is where a summary is worth reading and the prompt is still smaller than
    # the transcript it stands in for.
    SUMMARY_CHARS_PER_WORD = 40
    MIN_SUMMARY_WORDS = 200
    MAX_SUMMARY_WORDS = 1_200
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
    # Sizing the next request: see session/tokens.rb.
    include Tokens
    extend Tokens

    attr_reader :id, :messages, :workspace, :usage, :last_usage, :cost
    attr_reader :task, :cwd, :cache_history, :cache_records, :compaction_events, :system_additions, :system_patch
    attr_accessor :summary, :forced_skill, :model_override, :model_preset, :thinking_level, :title

    # How many recent requests keep their cache share. Enough to see a pattern
    # (a run of zeros is a busted cache, a stray zero is a compaction), short
    # enough that the session file does not grow for it.
    CACHE_HISTORY_LIMIT = 12

    # How many request records the session keeps in hand. The archive keeps
    # more (Store::CACHE_RECORDS_KEPT) and prunes the oldest; this is the window
    # a reader asks about, and it is what a file-only session can persist.
    CACHE_RECORDS_LIMIT = 50

    # Compaction seams the reader can still see in the transcript. Each one
    # names the absolute message index it moved past, so a page that reads the
    # whole archive can draw the marker in the turn it happened in. Bounded for
    # the same reason as the cache records: a long session must not grow a
    # metadata blob forever just to remember its own history.
    COMPACTION_EVENTS_LIMIT = 50

    def initialize(id = "default", workspace: nil, sessions_dir: nil, cwd: nil,
                   archive: nil)
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
      # The user's original instruction for this session. Kept outside the
      # message list so neither the hard trim nor compaction can delete the
      # goal of a long task; it is injected into the system prompt.
      @task = nil
      @summary = nil
      @forced_skill = nil
      @model_override = nil
      @model_preset = nil
      # Reasoning effort this session asks for ("minimal"/"low"/"medium"/"high").
      # nil means "whatever the config or preset says".
      @thinking_level = nil
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
      # The request records behind those numbers: what each request was made
      # of, and what the provider said the cache did with it.
      @cache_records = []
      @compaction_events = []
      @memory_backlog = []
      @system_additions = []
      # Newer text for prompt sections the model already has. Kept apart from
      # the pinned prompt and from #system_additions: it is replaced, not
      # appended, because only the newest version of a section is worth
      # sending and the block sits after the transcript, where it is re-read
      # uncached on every request either way.
      @system_patch = nil
      load!
    end

    # Record the token usage of one provider request. `raw` is the provider's
    # usage hash (OpenAI/Anthropic/Ollama shapes are all accepted). `rates`
    # are the prices in effect for the model that served the request, so the
    # cost is frozen at request time instead of being re-priced later with
    # whatever model the session happens to end on (Pi prices per message).
    def record_usage(raw, provider: nil, rates: nil, shape: nil)
      delta = Usage.from(raw, provider: provider)
      return nil if delta.nil?

      @last_usage = delta
      @last_usage_watermark = @messages.size
      @usage = @usage.merge(delta)
      push_cache_history(delta)
      add_cost(delta, rates)
      record_cache_record(delta, shape) if shape
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
    def record_auxiliary_usage(raw, provider: nil, rates: nil, shape: nil)
      delta = Usage.from(raw, provider: provider)
      return nil if delta.nil?

      @usage = @usage.merge(delta)
      add_cost(delta, rates)
      record_cache_record(delta, shape) if shape
      save!
      delta
    end

    # Keep what the request was made of next to what the provider said the
    # cache did with it. `cache_history` keeps the hit rate as a bare number,
    # which says a request missed but not why; the shape (prompt digest, tool
    # digest, block count) is what turns that number into a diagnosis.
    #
    # The record goes to the archive immediately when there is one — a request
    # that is later followed by a crash should still be readable — and to the
    # JSON file with the rest of the state otherwise.
    def record_cache_record(delta, shape)
      record = {
        "at" => Time.now.utc.iso8601,
        "prompt_tokens" => delta.prompt_tokens,
        "cached_tokens" => delta.cached_tokens,
        "cache_creation_tokens" => delta.cache_creation_tokens
      }.merge(shape.to_h { |key, value| [ key.to_s, value ] })
      # Only the newest record keeps its fingerprint — one request is all the
      # next comparison needs, and fifty of them would be 65 KB of hex in the
      # JSON export. The archive applies the same rule in SQL.
      previous = @cache_records.last
      previous["fingerprint"] = nil if previous.is_a?(Hash)
      @cache_records << record
      @cache_records.shift while @cache_records.size > CACHE_RECORDS_LIMIT
      @archive&.record_cache(@id, record)
      log_cache_cause
      warn_cache_streak(record)
      record
    end

    # Why the last request did or did not read the cache is a note for whoever
    # reads the log, not something a conversation needs to say: "cache
    # kedaluwarsa (>5 menit)" in a row of figures reads like a fault, when it is
    # only the ordinary end of the provider's five-minute window. The log is
    # where a diagnosis belongs; no surface a user is reading gets the label.
    def log_cache_cause
      cause = CacheDiagnosis.cause(@cache_records)
      warn "[cache] #{@id}: #{cause ? CacheDiagnosis.describe(cause) : 'hit'}"
    end

    # A prefix nobody changed that still reads nothing, three requests running,
    # is the one miss no rule on our side explains. Say it once when it starts
    # (and every ten after, so a long outage stays visible without filling the
    # log with the same line).
    def warn_cache_streak(record)
      streak = CacheDiagnosis.miss_streak(@cache_records)
      return unless streak >= CacheDiagnosis::STREAK_ALERT && (streak % 10) == 3

      warn "[cache] #{@id}: #{streak} request berurutan membaca 0 token cache " \
           "dengan prefix utuh (model #{record['model']}, epoch #{record['epoch']}, " \
           "#{record['blocks']} blok) — dugaan sisi provider/gateway, bukan perubahan prompt"
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

    def add(role, content, tool_calls: nil, tool_call_id: nil, reasoning_content: nil, ui_diff: nil,
            background: false)
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
      # An answer to something the reader never said — a fired job, a batch of
      # sub agents reporting back. Kept as a stamp so the transcript can start a
      # block of its own for it: the model's words belong to a turn nobody
      # prompted, and gluing them under the answer before made the reply read as
      # if it had never arrived.
      msg["background"] = true if background
      # The first user message is the task statement. Remember it before the
      # transcript can be trimmed, so a long turn cannot lose its own goal.
      @task = msg["content"].to_s.strip if role.to_s == "user" && @task.nil?
      @messages << msg
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

    # True when the goal has to be carried outside the transcript, because the
    # message that stated it is no longer in the window the model is sent.
    #
    # This is the whole point of the anchor and the reason it is not injected
    # unconditionally: a session whose first user message is still in the
    # transcript already states its own goal, and repeating it in the system
    # prompt gives the model a second, older request to answer instead. A
    # session opened with "show me my todos" and later told "do items 3 to 7"
    # kept answering with the todo list, because the pinned prompt still
    # called the listing the task. The anchor comes back exactly when the
    # transcript stops carrying that message -- one compaction or trim later.
    def task_anchor_needed?
      goal = task_statement
      return false if goal.nil?

      first = @messages.first
      return true if first.nil?

      !(first["role"].to_s == "user" && first["content"].to_s.strip == goal)
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

    # Conversation history as it will be sent to the provider. The only
    # remaining knob is `reasoning_tail`: reasoning from finished turns is
    # dropped, while the turn being executed keeps it. Trimming the transcript
    # itself is compaction's job (see #compact!).
    def safe_history(reasoning_tail: nil)
      conversation_history(reasoning_tail: reasoning_tail)
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
      breakdown.each do |key, value|
        # `cache_price_unknown` is a flag, not a figure: adding it up would be
        # `true + 0.0`.
        next unless value.is_a?(Numeric)

        @cost[key] = (@cost[key] || 0.0) + value.to_f
      end
      @cost["cache_price_unknown"] = true if breakdown["cache_price_unknown"]
    end

    # True when at least one request could not be priced (no rates known yet).
    def cost_partial?
      @cost_partial
    end

    def load_cost(raw)
      return nil unless raw.is_a?(Hash) && !raw.empty?

      # Figures are stored as numbers, flags as booleans: `true.to_f` would
      # raise on the way back in.
      raw.each_with_object({}) do |(key, value), acc|
        acc[key.to_s] = value.is_a?(Numeric) ? value.to_f : value
      end
    end

    def message_count
      @messages.size
    end

    # True when the last provider request still describes the transcript: it
    # is discarded by compaction and by the hard message trim, which is what
    # Pi does via `context_edit`/`compaction` invalidation.
    def context_anchored?
      @last_usage.requests.positive? && !@last_usage_watermark.nil?
    end

    def add_system_addition(text)
      return false if text.to_s.strip.empty?
      @system_additions << text.to_s
      @system_additions.shift while @system_additions.size > 20
      save!
      true
    end

    # Replace the text that supersedes parts of the pinned prompt. One patch,
    # not a growing list: the newest reading of a section is the only one the
    # request needs, and replacing it costs nothing extra because the block
    # sits behind the transcript, where no prefix can be reused anyway.
    def set_system_patch(text)
      value = text.to_s
      value = nil if value.strip.empty?
      return false if value == @system_patch

      @system_patch = value
      save!
      true
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
      @thinking_level = nil
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
    def compact!(provider:, keep_recent: DEFAULT_KEEP_RECENT_MESSAGES, keep_recent_tokens: nil, min_keep: nil, system_prompt: nil, provider_factory: nil)
      return nil unless @workspace
      return nil if @messages.empty?

      if keep_recent_tokens && keep_recent_tokens.to_i.positive?
        budget = keep_recent_tokens.to_i
        keep = 0
        used = 0
        i = @messages.size - 1
        while i >= 0
          msg_tokens = self.class.message_tokens(@messages[i], reasoning: false)
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
      return nil if @messages.size <= keep

      cutoff = @messages.size - keep
      # Never keep a tool result whose assistant message (with tool_calls) is
      # about to be summarized away: that breaks the provider's pairing rules.
      while cutoff < @messages.size && @messages[cutoff]["role"] == "tool"
        cutoff += 1
      end
      return nil if cutoff <= 0

      to_summarize = @messages[0...cutoff]
      # The merge input is the whole running summary, not the capped view the
      # prompt shows: the summarizer is the one place where dropping the older
      # part is a decision, and it can only make it with the text in hand.
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      summary_text = call_summarizer(provider, system_prompt, to_summarize, previous: @summary,
                                     provider_factory: provider_factory)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      return nil if summary_text.nil? || summary_text.strip.empty?

      prompt_chars = system_prompt.to_s.length
      context_before = context_tokens(extra_chars: prompt_chars)[:tokens]
      clean_summary = self.class.normalize_utf8(summary_text.strip)
      # The absolute index of the first message being summarized away. Capture
      # it before drop_front! moves the window: afterwards @archive_offset and
      # @messages.size cancel each other out and the cut is no longer locatable.
      # A reader refreshing the page uses this to put the seam in the turn that
      # was in flight when compaction ran.
      cut_index = @archive_offset + cutoff
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
        cut_index: cut_index,
        context_before: context_before,
        context_after: context_tokens(extra_chars: prompt_chars)[:tokens],
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
      transcript_with_start(workspace, id, dir: dir).first
    end

    # The transcript plus the index its first message carries in the archive.
    #
    # A trimmed session starts partway through: `messages_start` is the index
    # the stored transcript begins at, so position `n` in the returned array is
    # message `start + n`. Search hits are addressed by that absolute index, and
    # this is what turns one into a place in the list a page can draw. The file
    # fallback starts at zero, which is what a file always was.
    def self.transcript_with_start(workspace, id, dir: nil)
      dir ||= sessions_dir(workspace)
      if (archive = store)
        loaded = archive.load_session(id)
        return [ [], 0 ] if loaded.nil?

        return [ normalize_utf8(loaded[:messages]), loaded[:start].to_i ]
      end
      return [ [], 0 ] unless dir

      path = File.join(dir, "#{id}.json")
      return [ [], 0 ] unless File.file?(path)

      data = JSON.parse(File.read(path))
      messages = data["messages"]
      [ messages.is_a?(Array) ? normalize_utf8(messages) : [], 0 ]
    rescue JSON::ParserError, SystemCallError, EncodingError
      [ [], 0 ]
    end

    # The conversation as the archive kept it, read from the first message ever
    # written, plus where the model stopped being sent it.
    #
    # Compaction does not delete: it moves `messages_start` forward and keeps a
    # summary of what it moved past. A reader who starts at `messages_start`
    # therefore opens in the middle of a conversation that is still on disk, so
    # this reads the table from the top and hands back the seam as a number the
    # page can mark. `summary` is what replaced those messages, which is the
    # only thing standing in for them in the request.
    #
    # @return [Hash] { messages: [Hash], cut: Integer, summary: String }
    def self.archive_transcript(workspace, id, dir: nil)
      dir ||= sessions_dir(workspace)
      if (archive = store)
        loaded = archive.load_session(id, all: true)
        return { messages: [], cut: 0, summary: "", compaction_events: [] } if loaded.nil?

        meta = loaded[:meta] || {}
        return {
          messages: normalize_utf8(loaded[:messages]),
          cut: loaded[:cut].to_i,
          summary: meta["summary"].to_s,
          compaction_events: normalize_utf8(meta["compaction_events"])
        }
      end
      return { messages: [], cut: 0, summary: "", compaction_events: [] } unless dir

      path = File.join(dir, "#{id}.json")
      return { messages: [], cut: 0, summary: "", compaction_events: [] } unless File.file?(path)

      data = JSON.parse(File.read(path))
      messages = data["messages"]
      {
        messages: messages.is_a?(Array) ? normalize_utf8(messages) : [],
        cut: 0,
        summary: data["summary"].to_s,
        compaction_events: normalize_utf8(data["compaction_events"])
      }
    rescue JSON::ParserError, SystemCallError, EncodingError
      { messages: [], cut: 0, summary: "", compaction_events: [] }
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
        # The stamp, not a flag: the sidebar's pinned section is ordered by it,
        # and nil is "not pinned" for every row written before pins existed.
        pinned_at: row[:pinned_at],
        # Nil for a row from a database older than schema 11 and for the
        # file-backed list, which has nothing to read the mark from.
        unread_at: row[:unread_at],
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
        title: title_for(messages, data["title"]),
        # A hand-kept pin, when the file carries one. The archive is where pins
        # are written in practice; a JSON file only has one if something put it
        # there, and reading it costs nothing.
        pinned_at: data["pinned_at"]
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
      data["thinking_level"] = @thinking_level if @thinking_level
      data["usage"] = @usage.to_h
      data["last_usage"] = @last_usage.to_h
      data["cost"] = @cost if @cost
      data["cost_partial"] = true if @cost_partial
      data["last_usage_watermark"] = @last_usage_watermark if @last_usage_watermark
      data["cache_history"] = @cache_history if @cache_history && !@cache_history.empty?
      data["cache_records"] = @cache_records if @cache_records && !@cache_records.empty?
      data["compaction_events"] = @compaction_events if @compaction_events && !@compaction_events.empty?
      data["system_prompt"] = @system_prompt if @system_prompt
      data["system_prompt_epoch"] = @system_prompt_epoch if @system_prompt_epoch
      data["memory_backlog"] = @memory_backlog if @memory_backlog && !@memory_backlog.empty?
      data["system_additions"] = @system_additions if @system_additions && !@system_additions.empty?
      data["system_patch"] = @system_patch if @system_patch

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

    # Remember where an automatic compaction cut the transcript. The index is
    # absolute (the archive's numbering), so a reader that loads from the first
    # message can put the marker on the turn that was in flight when it happened.
    # The event is plain data: it crosses the actor boundary with the compaction
    # result and is persisted with the session's other metadata.
    def record_compaction(result)
      # Use the cut index captured inside compact! before the window moved.
      # Deriving it here from @archive_offset + @messages.size would point one
      # past the last message, which belongs to no turn, so a refresh would
      # silently drop the seam. Fall back to the old derivation only for a
      # result that did not carry the index (e.g. a hand-built test double).
      index = result[:cut_index] || (@archive_offset + @messages.size)
      @compaction_events << {
        "index" => index,
        "summarized" => result[:summarized_messages].to_i,
        "before" => result[:context_before].to_i,
        "after" => result[:context_after].to_i,
        "elapsed" => result[:elapsed].to_f
      }
      @compaction_events.shift while @compaction_events.size > COMPACTION_EVENTS_LIMIT
      save!
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
        "thinking_level" => @thinking_level,
        "usage" => @usage.to_h,
        "last_usage" => @last_usage.to_h,
        "cost" => @cost,
        "cost_partial" => @cost_partial,
        "last_usage_watermark" => @last_usage_watermark,
        "cache_history" => @cache_history,
        "compaction_events" => @compaction_events,
        # The pin: losing either of these rebuilds the system prompt, and a
        # rebuilt prompt at the front of the request is a cold cache.
        "system_prompt" => @system_prompt,
        "system_prompt_epoch" => @system_prompt_epoch,
        "memory_backlog" => @memory_backlog,
        "system_additions" => @system_additions,
        "system_patch" => @system_patch
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
      return true if @forced_skill || @model_override || @model_preset || @thinking_level
      return true if @usage.requests.positive?
      return true if @last_usage.requests.positive?
      return true if @memory_backlog && !@memory_backlog.empty?

      false
    end

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
      @thinking_level = data["thinking_level"] if data["thinking_level"]
      @usage = Usage.from_h(data["usage"])
      @last_usage = Usage.from_h(data["last_usage"])
      @cost = load_cost(data["cost"])
      @cost_partial = data["cost_partial"] == true
      @last_usage_watermark = data["last_usage_watermark"].is_a?(Integer) ? data["last_usage_watermark"] : nil
      @cache_history = Array(data["cache_history"]).map(&:to_f).last(CACHE_HISTORY_LIMIT)
      @cache_records = Array(data["cache_records"])
        .select { |record| record.is_a?(Hash) }
        .last(CACHE_RECORDS_LIMIT)
      @compaction_events = Array(data["compaction_events"])
        .select { |event| event.is_a?(Hash) }
        .last(COMPACTION_EVENTS_LIMIT)
      @system_prompt = data["system_prompt"].to_s.empty? ? nil : data["system_prompt"].to_s
      @system_prompt_epoch = data["system_prompt_epoch"].is_a?(Hash) ? data["system_prompt_epoch"] : nil
      @memory_backlog = Array(data["memory_backlog"]).map(&:to_s)
      @system_additions = Array(data["system_additions"]).map(&:to_s)
      @system_patch = data["system_patch"].to_s.empty? ? nil : data["system_patch"].to_s
    end

    # The session state as the archive holds it: the messages it returned (which
    # already start at `messages_start`) plus the metadata blob under the same
    # keys the JSON file used, so one restore path serves both.
    def archive_state
      loaded = @archive.load(@id)
      return nil unless loaded

      @archive_offset = loaded[:start].to_i
      (loaded[:meta] || {}).merge(
        "messages" => loaded[:messages] || [],
        # The records live in their own table, not in the meta blob: they are
        # written per request and pruned, which a blob rewritten on every save
        # would make expensive and a race.
        "cache_records" => @archive.cache_records(@id, limit: CACHE_RECORDS_LIMIT)
      )
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
