# frozen_string_literal: true

require "json"
require "fileutils"
require "set"
require "time"
require_relative "usage"
require_relative "session/archive"
require_relative "session/compactor"
require_relative "session/index"
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
    # Where the session is written: see session/archive.rb.
    include Archive

    # Sizing the next request: see session/tokens.rb.
    include Tokens
    extend Tokens

    # Finding saved sessions: see session/index.rb.
    extend Index

    attr_reader :id, :messages, :workspace, :usage, :last_usage, :cost
    # Absolute index of messages[0] in the archive, moved by #drop_front! so
    # the window can be trimmed without renumbering the stored transcript.
    attr_reader :archive_offset
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
#
# The work is in session/compactor.rb, which is the one place in a session
# that calls a model. This is the door callers keep using, so the
# signature and the shape of the result stay exactly as they were.
def compact!(provider:, keep_recent: DEFAULT_KEEP_RECENT_MESSAGES, keep_recent_tokens: nil, min_keep: nil, system_prompt: nil, provider_factory: nil)
  Compactor.new(self).compact!(provider: provider, keep_recent: keep_recent,
                               keep_recent_tokens: keep_recent_tokens, min_keep: min_keep,
                               system_prompt: system_prompt, provider_factory: provider_factory)
end

# Message-count based summarization kept for backwards compatibility and
# as a safety net. New callers should prefer #compact! with a context
# threshold.
#
# Returns the text that was summarized (the new summary fragment), or nil
# if nothing was trimmed.
def summarize_and_trim!(provider:, system_prompt:, limit: DEFAULT_MESSAGE_LIMIT)
  Compactor.new(self).summarize_and_trim!(provider: provider, system_prompt: system_prompt, limit: limit)
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

    # The archive, when the process has one (set by SessionPool at boot).
    #
    # These three readers are the seam: channels ask for a list, a summary or a
    # transcript and do not care where it comes from. With the archive set they
    # answer from SQLite; without it (the fallback when it cannot be opened) the
    # JSON files answer exactly as before.
    class << self
      attr_accessor :store
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

    private

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
