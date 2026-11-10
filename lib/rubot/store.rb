# frozen_string_literal: true
require "json"
require "fileutils"
require "digest"
require "set"
require "time"
require "zlib"
require "sqlite3"
require_relative "session"
require_relative "store/migrator"

module Rubot
  # SQLite archive of every conversation.
  #
  # Transcripts used to live only as one JSON file each, and the web sidebar
  # rebuilt itself by parsing all of them on every render: measured at +30 MB of
  # resident memory for a single sweep over 73 sessions and +81 MB after four
  # sweeps, none of it returned to the OS. Answering the same list from three
  # columns costs +0.8 MB and does not grow on repeat. That is what the store is
  # for; full-text search is the other reason it exists.
  #
  # Two rules hold the model together:
  #
  #   * messages are append-only. Nothing in this class deletes a row. A session
  #     trimmed to fit the model's context window keeps its archive, which is
  #     what makes "find that conversation from last week" possible at all.
  #   * `payload` is the message as the JSON file held it, minus `ui_diff`, and
  #     `text` is its flattened text. The diff lives compressed in its own column
  #     because it is 69% of the bytes (21.7 MB over 527 messages) and no model
  #     ever sees it — dropping it from the payload took the archive from 38.9 MB
  #     to 22.6 MB with every message still coming back byte for byte.
  #
  # Ractor safety: SQLite3::Database is not Ractor-safe — SQLite3 raises
  # Ractor::UnsafeError from open_v2 inside a non-main Ractor (verified, not
  # assumed). A Store is therefore opened in the main Ractor and reached from a
  # SessionActor through a port, never instantiated inside one.
  class Store
    DB_FILENAME = "sessions.db"
    # The schema is the numbered .sql files in store/migrations/, applied by
    # Migrator. Nothing here knows what version 3 will add.
    MIGRATIONS_DIR = File.join(__dir__, "store", "migrations")
    # Small on purpose: the sidebar reads three short columns and the archive is
    # read once per turn, so a large page cache would only cost resident memory
    # (it is per connection, and connections cannot be shared across Ractors).
    DEFAULT_CACHE_KB = 512
    BUSY_TIMEOUT_MS = 5_000
    # The full-text index is merged back into shape every so many appended
    # messages, not on a timer: a timer needs an owner and a lifetime, and the
    # store is already the thing that knows a message was written. 500 is about a
    # week of ordinary use.
    FTS_OPTIMIZE_EVERY = 500
    # How much of a tool result is searchable. A `cat` of a large file is not
    # more findable past its first pages, and indexing all of it turned the index
    # into a second copy of the repository.
    TOOL_INDEX_LIMIT = 8_192
    # How far back the dedupe of a repeated tool result looks: a session that
    # reads the same file twice in a row is the case worth catching, and a window
    # keeps the lookup bounded.
    TOOL_DEDUPE_WINDOW = 200
    # bm25 weights, in the order the columns are declared: what the person said,
    # what the assistant answered, what a tool printed.
    SEARCH_WEIGHTS = [ 10.0, 5.0, 1.0 ].freeze
    # How many words of the query are used. A query longer than this is a
    # paragraph, and every extra word only narrows the answer.
    SEARCH_TERMS = 8
    # Markers around the matched words. Control characters rather than `<mark>`
    # because the snippet is text until the last step: it is escaped first and
    # only then turned into markup, so a message containing a tag cannot become
    # one.
    SNIPPET_OPEN = "\u0002"
    SNIPPET_CLOSE = "\u0003"

    attr_reader :path, :migrations_dir

    # Where the archive lives for a given sessions directory: next to the JSON
    # files it replaces, so config.yml's own directory stays the single place
    # that decides where sessions are.
    def self.path_for(sessions_dir)
      File.join(File.dirname(sessions_dir), DB_FILENAME)
    end

    def initialize(path, cache_kb: DEFAULT_CACHE_KB, migrations_dir: MIGRATIONS_DIR)
      @path = path
      @migrations_dir = migrations_dir
      FileUtils.mkdir_p(File.dirname(path))
      @db = SQLite3::Database.new(path)
      @db.busy_timeout = BUSY_TIMEOUT_MS
      apply_pragmas(cache_kb)
      migrate!
      rebuild_index_if_stale
    end

    # --- writing -------------------------------------------------------

    # Append messages at their position in the transcript. `start_index` is the
    # index of the first message in the array; re-appending a block that is
    # already stored is a no-op, so a turn saved twice cannot duplicate history.
    #
    # Returns how many rows were actually new.
    def append_messages(session_id, messages, start_index: 0)
      return 0 if messages.nil? || messages.empty?

      session_id = text_id(session_id)
      inserted = 0
      # The tool outputs this session already indexes, so a repeated `cat` of the
      # same file does not fill the index with a second copy of itself.
      seen_tool = recent_tool_digests(session_id)
      in_transaction do
        statement = @db.prepare(<<~SQL)
          INSERT OR IGNORE INTO messages(session_id, idx, role, text, created_at, payload, diff,
                                         user_text, assistant_text, tool_text)
          VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        messages.each_with_index do |message, offset|
          next unless message.is_a?(Hash)

          content = message["content"]
          payload, diff = split_display_field(message)
          indexable = index_columns(message, seen_tool)
          statement.execute(
            session_id.to_s,
            start_index + offset,
            message["role"].to_s,
            Session.text_content(content),
            message["timestamp"],
            payload,
            diff,
            indexable[:user_text],
            indexable[:assistant_text],
            indexable[:tool_text]
          )
          # INSERT OR IGNORE affects zero rows when the (session_id, idx) pair is
          # already there, which is exactly the case that must not be counted.
          inserted += @db.changes
        end
        statement.close
      end
      touch_session(session_id, messages)
      refresh_count(session_id)
      optimize_fts_when_due(inserted)
      inserted
    end

    # Metadata row for the sidebar. Kept separate from the messages so renaming a
    # conversation does not touch the transcript.
    #
    # `meta` and `messages_start` are nil-unless-set: a caller that only knows the
    # title must not wipe the summary or move the window.
    def upsert_session(id:, title: "", created_at: nil, updated_at: nil, cwd: nil, bytes: 0,
                       meta: nil, messages_start: nil)
      id = text_id(id)
      meta_json = meta.nil? ? nil : JSON.generate(meta)
      # meta and messages_start appear twice: once for the insert, once for the
      # conflict update, where a nil must keep what is already stored.
      args = [id.to_s, title.to_s, created_at, updated_at, cwd, bytes,
              meta_json, messages_start, meta_json, messages_start]
      @db.execute(<<~SQL, args)
        INSERT INTO sessions(id, title, created_at, updated_at, cwd, bytes, meta, messages_start)
        VALUES(?, ?, ?, ?, ?, ?, COALESCE(?, '{}'), COALESCE(?, 0))
        ON CONFLICT(id) DO UPDATE SET
          -- A blank field means "I was not told", not "clear it". Every turn
          -- saves the session, so anything overwritten unconditionally was
          -- erased once per turn: the name the model gave it, the timestamp the
          -- sidebar sorts on, and the byte count the import uses to decide a
          -- file is unchanged.
          title      = CASE WHEN excluded.title = '' THEN sessions.title ELSE excluded.title END,
          updated_at = COALESCE(excluded.updated_at, sessions.updated_at),
          cwd        = COALESCE(excluded.cwd, sessions.cwd),
          bytes      = CASE WHEN excluded.bytes = 0 THEN sessions.bytes ELSE excluded.bytes END,
          meta           = COALESCE(?, sessions.meta),
          messages_start = COALESCE(?, sessions.messages_start)
      SQL
      refresh_count(id)
      self
    end

    # Remove a conversation for good — the one place rows are deleted, and only
    # because a reader asked while looking at it (the web client's delete
    # button). Trimming never takes this path: it moves `messages_start`.
    def delete_session(session_id)
      id = text_id(session_id)
      in_transaction do
        @db.execute("DELETE FROM messages WHERE session_id = ?", [id])
        @db.execute("DELETE FROM sessions WHERE id = ?", [id])
      end
      true
    end

    # --- reading -------------------------------------------------------

    # Lift a conversation out of the chronological list, or put it back. The
    # stamp is kept rather than a flag because the pinned section is ordered by
    # it: a cap of ten then has a defined "oldest" to drop.
    #
    # Pinning is not a message write, so it does not go through the actor — the
    # web client owns this column and no turn reads it.
    def pin_session(session_id, at: nil)
      id = text_id(session_id)
      return false if id.empty?

      @db.execute(
        "UPDATE sessions SET pinned_at = ? WHERE id = ?",
        [ (at || Time.now.utc.iso8601).to_s, id ]
      )
      @db.changes.positive?
    end

    def unpin_session(session_id)
      id = text_id(session_id)
      return false if id.empty?

      @db.execute("UPDATE sessions SET pinned_at = NULL WHERE id = ?", [ id ])
      @db.changes.positive?
    end

    # Whether an id is already in use. Cheaper than loading the transcript: the
    # web client asks this before handing out a fresh id.
    def session?(session_id)
      id = text_id(session_id)
      return false if id.empty?

      !@db.get_first_value("SELECT 1 FROM sessions WHERE id = ? LIMIT 1", [id]).nil?
    end

    # What the sidebar shows, newest first. Three columns and no JSON parsing:
    # this is the query that replaces Session.describe over the whole directory.
    #
    # A pinned row is never dropped by the limit: the sidebar has a section for
    # it, and a conversation pinned months ago must stay there however many
    # newer ones exist. The limit still bounds the chronological rows.
    #
    # `limit: nil` reads every row, which is what a paginated list needs in
    # order to know how many pages there are.
    def sidebar(limit: 40)
      args = []
      sql = +"SELECT id, title, updated_at, msg_count, cwd, pinned_at FROM sessions "
      unless limit.nil?
        sql << <<~SQL
          WHERE pinned_at IS NOT NULL
             OR id IN (SELECT id FROM sessions ORDER BY COALESCE(updated_at, '') DESC LIMIT ?)
        SQL
        args << limit.to_i
      end
      sql << " ORDER BY COALESCE(updated_at, '') DESC"

      @db.execute(sql, args).map do |(id, title, updated_at, count, cwd, pinned_at)|
        {
          id: text_id(id),
          title: title.to_s,
          updated_at: updated_at,
          timestamp: timestamp_of(updated_at),
          messages: count.to_i,
          cwd: cwd,
          pinned_at: pinned_at
        }
      end
    end

    # The transcript, in order, with every message reconstructed as it was.
    #
    # `payload` is the message without `ui_diff`, so a tool call, its reasoning
    # and its parts array all survive the round trip; the diff comes back from
    # its own column. Nothing is stored twice: `text` is the searchable
    # projection and content is read back out of the payload rather than kept as
    # a third copy (which cost 4 MB on 7k messages).
    def load_session(session_id)
      id = text_id(session_id)
      row = @db.execute(
        "SELECT meta, messages_start FROM sessions WHERE id = ?", [id]
      ).first
      start = row ? row[1].to_i : 0

      rows = @db.execute(<<~SQL, [id, start])
        SELECT payload, diff, text, role, created_at FROM messages
        WHERE session_id = ? AND idx >= ? ORDER BY idx
      SQL
      # No session row and no messages: nothing is known about this id.
      return nil if rows.empty? && row.nil?

      messages = rows.map do |(payload, diff, text, role, created_at)|
        message = decode_payload(payload) || { "role" => role.to_s, "content" => text.to_s }
        # Rows written before schema 2 still carry the diff inside the payload;
        # only attach when it was moved out, so a legacy row is not overwritten.
        diff = inflate(diff)
        message["ui_diff"] = diff if diff
        message["timestamp"] ||= created_at if created_at
        message
      end
      { id: id, messages: messages, meta: decode_meta(row && row[0]), start: start }
    end

    def session_ids
      @db.execute("SELECT id FROM sessions ORDER BY COALESCE(updated_at, '') DESC").map { |row| text_id(row.first) }
    end

    def message_count(session_id)
      @db.get_first_value("SELECT COUNT(*) FROM messages WHERE session_id = ?", [text_id(session_id)]).to_i
    end

    # Index of the newest message stored for a session, or -1 when there is none.
    # The actor uses it to append only what is new instead of rewriting the whole
    # transcript every turn.
    def last_index(session_id)
      @db.get_first_value("SELECT COALESCE(MAX(idx), -1) FROM messages WHERE session_id = ?", [text_id(session_id)]).to_i
    end

    def counts
      {
        sessions: @db.get_first_value("SELECT COUNT(*) FROM sessions").to_i,
        messages: @db.get_first_value("SELECT COUNT(*) FROM messages").to_i,
        chars: @db.get_first_value("SELECT COALESCE(SUM(LENGTH(text)), 0) FROM messages").to_i
      }
    end

    # Full-text search over every message ever stored — including the turns a
    # compacted session no longer shows the model, which is the whole point of
    # keeping the archive.
    #
    # The weights are the ranking, and they are the reason the index has three
    # columns: search for "cache hit" and the conversation where the person
    # asked about it comes before the twenty where the phrase appeared inside a
    # grep result.
    #
    # Returns [{ session_id:, idx:, role:, created_at:, title:, snippet:, html:,
    # score: }, ...], best first.
    #
    # `prefix` narrows the search to sessions whose id starts with it, so a
    # channel can ask for the conversations it can actually open. The archive is
    # shared by every channel — a Telegram chat is in here too — and a hit in a
    # conversation the asker has no page for is a dead link, not a result. It is
    # an SQL filter rather than a slice in Ruby so the limit stays a limit:
    # filtering twenty rows down to two would answer with two.
    def search(text, limit: 20, prefix: nil)
      expression = search_expression(text)
      return [] if expression.nil? || fts_table.nil?

      weights = SEARCH_WEIGHTS.join(", ")
      scope = prefix.to_s.empty? ? [ "", [] ] : [ " AND substr(m.session_id, 1, ?) = ?",
                                                  [ prefix.to_s.length, prefix.to_s ] ]
      @db.execute(<<~SQL, [ expression, *scope[1], limit.to_i ]).map do |row|
        SELECT m.session_id, m.idx, m.role, m.created_at, s.title,
               snippet(fts, -1, '#{SNIPPET_OPEN}', '#{SNIPPET_CLOSE}', '…', 24),
               bm25(fts, #{weights})
        FROM fts
        JOIN messages m ON m.id = fts.rowid
        LEFT JOIN sessions s ON s.id = m.session_id
        WHERE fts MATCH ?#{scope[0]}
        ORDER BY bm25(fts, #{weights})
        LIMIT ?
      SQL
        raw = row[5].to_s
        {
          session_id: text_id(row[0]),
          idx: row[1].to_i,
          role: row[2].to_s,
          created_at: row[3],
          title: row[4].to_s,
          snippet: raw.delete(SNIPPET_OPEN).delete(SNIPPET_CLOSE),
          html: snippet_html(raw),
          score: row[6].to_f
        }
      end
    end

    # Rebuilds the searchable projection of the whole archive. Reset first and
    # then rebuilt, so a run always leaves the index agreeing with the
    # transcript.
    #
    # Runs once by itself on an archive that predates the index (see
    # rebuild_index_if_stale), and is safe to run again at any time.
    def rebuild_index!
      table = fts_table
      return 0 unless table

      rewrite = @db.prepare(<<~SQL)
        UPDATE messages SET user_text = ?, assistant_text = ?, tool_text = ? WHERE id = ?
      SQL
      rows = @db.execute("SELECT id, session_id, role, text FROM messages ORDER BY session_id, idx")
      seen = Hash.new { |hash, key| hash[key] = Set.new }
      in_transaction do
        rows.each do |(id, session_id, role, text)|
          columns = index_columns({ "role" => role, "content" => text }, seen[text_id(session_id)])
          rewrite.execute(columns[:user_text], columns[:assistant_text], columns[:tool_text], id)
        end
        rewrite.close
        # The update trigger kept the index in step row by row, but a row whose
        # projection was wrong before this run cannot be repaired by deleting
        # what the index thinks it holds: only a rebuild rereads every row from
        # the content table, which is what makes this function's promise —
        # "leaves the index agreeing with the transcript" — true.
        @db.execute(%(INSERT INTO #{table}(#{table}) VALUES('rebuild')))
      end
      rows.size
    end

    def close
      return if @db.nil? || @db.closed?

      # The last thing a process does with the archive is tidy it: the planner
      # statistics and the full-text index cost nothing on a connection that is
      # about to disappear, and are the two things that make every later query
      # cheaper. A failure here must never stop the close.
      begin
        optimize!
      rescue StandardError => e
        warn "[store] optimize before close: #{e.class}: #{e.message}"
      end
      @db.close
    ensure
      @db = nil
    end

    # --- maintenance ---------------------------------------------------

    # SQLite's own housekeeping, in the two places it pays off.
    #
    # `PRAGMA optimize` gathers the statistics the query planner uses; without
    # it the planner guesses at how many rows a session has, and the sidebar's
    # "newest 40" is planned as a scan. The full-text index is append-only like
    # the messages it mirrors, so it accumulates the segments of deleted text the
    # same way, and merging them back is what keeps a search from reading the
    # history of every edit ever made.
    #
    # Returns the steps that ran, so a caller can report what it did.
    def optimize!
      ran = []
      @db.execute("PRAGMA optimize")
      ran << :planner
      if fts_table
        @db.execute(%(INSERT INTO #{fts_table}(#{fts_table}) VALUES('optimize')))
        ran << :fts
      end
      ran
    end

    # The name of the full-text table if the schema has one. Asked once rather
    # than assumed: the archive works without search, and the index arrived in a
    # later migration. `migrate!` has already run by the time anyone asks, so the
    # answer cannot go stale inside one process.
    def fts_table
      return @fts_table if @fts_checked

      @fts_checked = true
      @fts_table = if @db.nil? || @db.closed?
        nil
      else
        @db.get_first_value(<<~SQL)
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name IN ('fts', 'messages_fts')
          LIMIT 1
        SQL
      end
    end

    # A copy that is consistent while the archive is open.
    #
    # `cp` is not: under WAL the newest turns live in `sessions.db-wal`, so the
    # file a copy picks up is the archive as of the last checkpoint — and a
    # checkpoint may not have happened for hours. VACUUM INTO asks SQLite to
    # write the whole logical database into a new file, which is what a query
    # would see, WAL included.
    #
    # The copy is written beside the destination and renamed, because VACUUM INTO
    # refuses a target that already exists and because a half-written file must
    # never wear the name a restore script looks for.
    def backup(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      temporary = "#{destination}.tmp-#{Process.pid}"
      FileUtils.rm_f(temporary)
      @db.execute("VACUUM INTO ?", [ temporary ])
      File.rename(temporary, destination)
      destination
    ensure
      FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
    end

    # The JSON files the archive replaced, written back out one per session.
    #
    # This is the second backup format on purpose: a .db file is only readable
    # by SQLite and only while the schema and this class agree, and a backup you
    # cannot read is not a backup. What is written here is the same shape
    # `import_directory` reads, so restoring is the importer and nothing else has
    # to be written for the day the archive is lost.
    def export_json(dir)
      FileUtils.mkdir_p(dir)
      written = 0
      sessions_with_dates.each do |row|
        loaded = load_session(row[:id])
        next if loaded.nil?

        data = {}
        loaded[:meta].each { |key, value| data[key.to_s] = value }
        data["id"] = row[:id]
        data["title"] = row[:title]
        data["created_at"] = row[:created_at]
        data["updated_at"] = row[:updated_at]
        data["cwd"] = row[:cwd]
        data["messages"] = loaded[:messages]
        File.write(File.join(dir, "#{row[:id]}.json"), JSON.pretty_generate(data))
        written += 1
      end
      written
    end

    # --- import --------------------------------------------------------

    # Load every session file in `dir` into the archive. Idempotent: a file that
    # was already imported only fills in what is missing, so running it twice
    # changes nothing.
    def import_directory(dir, skip_existing: false)
      stats = { files: 0, sessions: 0, messages: 0, skipped: 0 }
      # A file is skipped without parsing only when it has not grown since it
      # was imported. Size is the honest test for an append-only JSON file: the
      # old writer kept appending, so a session imported from a still-running
      # process is topped up instead of silently left behind.
      known = skip_existing ? session_sizes : nil
      Dir.glob(File.join(dir, "*.json")).sort.each do |path|
        stats[:files] += 1
        id = File.basename(path, ".json")
        if known && known.key?(id) && known[id] == File.size(path)
          stats[:skipped] += 1
          next
        end

        result = import_file(path)
        if result
          stats[:sessions] += 1
          stats[:messages] += result
        else
          stats[:skipped] += 1
        end
      end
      stats
    end

    # id => the file size the archive was imported from.
    def session_sizes
      @db.execute("SELECT id, bytes FROM sessions").each_with_object({}) do |(id, bytes), hash|
        hash[id] = bytes.to_i
      end
    end

    # Every conversation with the dates a JSON file carries. `sidebar` answers
    # the same question for the page, but it drops what a file needs to be
    # rebuilt.
    def sessions_with_dates
      @db.execute(<<~SQL).map do |(id, title, created_at, updated_at, cwd)|
        SELECT id, title, created_at, updated_at, cwd
        FROM sessions
        ORDER BY COALESCE(updated_at, '') DESC
      SQL
        { id: text_id(id), title: title.to_s, created_at: created_at,
          updated_at: updated_at, cwd: cwd }
      end
    end

    # One file. Returns the number of messages it holds, or nil when the file has
    # nothing to resume (Session.describe_data decides that, the same rule the
    # sidebar uses, so the list looks the same after the migration).
    # The session fields the JSON file carried beyond the messages. Imported so
    # a compacted session keeps the summary its transcript was compressed into —
    # without it, resuming that session after the migration would show the model
    # the tail of a conversation whose beginning it no longer has.
    META_KEYS = %w[
      summary task forced_skill model_override model_preset usage last_usage cost
      cost_partial last_usage_watermark cache_history system_prompt system_prompt_epoch
      memory_backlog
    ].freeze

    def import_file(path)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      summary = Session.describe_data(data, id: File.basename(path, ".json"), mtime: File.mtime(path))
      return nil unless summary

      messages = Session.normalize_utf8(data["messages"])
      meta = META_KEYS.each_with_object({}) do |key, hash|
        hash[key] = data[key] if data.key?(key) && !data[key].nil?
      end
      in_transaction do
        append_messages(summary[:id], messages)
        upsert_session(
          id: summary[:id],
          title: summary[:title].to_s,
          created_at: data["created_at"],
          updated_at: summary[:updated_at],
          cwd: summary[:cwd],
          bytes: File.size(path),
          meta: meta
        )
      end
      summary[:messages]
    rescue JSON::ParserError, SystemCallError, EncodingError => e
      warn "[store] skip #{File.basename(path)}: #{e.class}: #{e.message}"
      nil
    end

    private

    # SQLite refuses a transaction inside a transaction, and the importer opens
    # one for the whole file while append_messages wants one of its own. Joining
    # the caller's transaction keeps "one file, all or nothing" true without
    # making every caller aware of it.
    def in_transaction
      return yield if @db.transaction_active?

      @db.transaction { yield }
    end

    def apply_pragmas(cache_kb)
      # WAL: one writer, many readers, and a crash leaves a recoverable file.
      @db.execute("PRAGMA journal_mode = WAL")
      # NORMAL is the right trade here: a lost turn after a power cut is a lost
      # message, not a corrupt archive.
      @db.execute("PRAGMA synchronous = NORMAL")
      @db.execute("PRAGMA cache_size = -#{cache_kb.to_i}")
    end

    def migrate!
      Migrator.new(@db, dir: @migrations_dir).run!
    end

    # Merging the index costs a write of its own, so it waits for a batch of
    # appends instead of running inside every turn. A schema without the index
    # has nothing to merge, and a merge that fails must not fail the append that
    # triggered it: the messages are already stored.
    def optimize_fts_when_due(inserted)
      @appended_since_optimize = (@appended_since_optimize || 0) + inserted.to_i
      return if @appended_since_optimize < FTS_OPTIMIZE_EVERY

      @appended_since_optimize = 0
      table = fts_table
      return unless table

      @db.execute(%(INSERT INTO #{table}(#{table}) VALUES('optimize')))
    rescue StandardError => e
      warn "[store] fts optimize: #{e.class}: #{e.message}"
    end

    # The searchable projection of one message: exactly one of the three columns
    # is filled, chosen by who said it. A tool result is clipped and, if this
    # session already indexes the same text, dropped — a second identical grep
    # adds nothing to a search but its own weight.
    def index_columns(message, seen_tool)
      text = Session.text_content(message["content"]).to_s
      case message["role"].to_s
      when "user"
        { user_text: text, assistant_text: "", tool_text: "" }
      when "assistant"
        { user_text: "", assistant_text: text, tool_text: "" }
      when "tool"
        clipped = text[0, TOOL_INDEX_LIMIT].to_s
        digest = Digest::SHA256.hexdigest(clipped)
        return { user_text: "", assistant_text: "", tool_text: "" } if clipped.empty? || seen_tool.include?(digest)

        seen_tool << digest
        { user_text: "", assistant_text: "", tool_text: clipped }
      else
        { user_text: "", assistant_text: "", tool_text: "" }
      end
    end

    # The tool outputs this session already has in the index, as digests. Bounded
    # by TOOL_DEDUPE_WINDOW so a long session does not turn every append into a
    # scan of its whole history.
    def recent_tool_digests(session_id)
      rows = @db.execute(<<~SQL, [ text_id(session_id), TOOL_DEDUPE_WINDOW ])
        SELECT tool_text FROM messages
        WHERE session_id = ? AND tool_text <> ''
        ORDER BY idx DESC
        LIMIT ?
      SQL
      rows.each_with_object(Set.new) { |(text), set| set << Digest::SHA256.hexdigest(text.to_s) }
    end

    # What the person typed, turned into an FTS5 expression that cannot be a
    # syntax error: the words are found in it, quoted, and made prefix matches,
    # so "cach" still finds "cache". A query with no words in it matches nothing
    # rather than everything.
    def search_expression(text)
      terms = text.to_s.downcase.scan(/[[:alnum:]_]+/).first(SEARCH_TERMS)
      return nil if terms.empty?

      terms.map { |term| %("#{term}"*) }.join(" AND ")
    end

    # Escape first, mark up second: the snippet is a piece of a message the model
    # wrote or a tool printed, and it reaches the page as text.
    def snippet_html(raw)
      CGI.escapeHTML(raw.to_s)
         .gsub(SNIPPET_OPEN, "<mark>")
         .gsub(SNIPPET_CLOSE, "</mark>")
    end

    # An archive that predates the index has three empty columns and an empty
    # index. Rebuilding is the only expensive thing this class does, so it
    # happens once — on the first open that finds the work undone — and never
    # again.
    def rebuild_index_if_stale
      table = fts_table
      return if table.nil?
      return if @db.get_first_value("SELECT COUNT(*) FROM #{table}").to_i.positive?
      return if @db.get_first_value("SELECT COUNT(*) FROM messages").to_i.zero?

      rebuild_index!
    end

    def decode_payload(payload)
      return nil if payload.nil? || payload.empty?

      JSON.parse(payload)
    rescue JSON::ParserError
      nil
    end

    def decode_meta(raw)
      return {} if raw.nil? || raw.to_s.empty?

      parsed = JSON.parse(raw.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    # `ui_diff` is what a channel draws under a tool call, never something the
    # model is sent. It is 69% of the archive (21.7 MB over 527 messages, 42 KB
    # each) and compresses to 24%, so it travels in its own column as zlib rather
    # than inside the payload. Splitting it also keeps `payload` readable: what
    # is left is the conversation.
    def split_display_field(message)
      diff = message["ui_diff"]
      return [ JSON.generate(message), nil ] if diff.nil?

      payload = JSON.generate(message.reject { |key, _| key == "ui_diff" })
      [ payload, deflate(JSON.generate(diff)) ]
    end

    def deflate(text)
      Zlib::Deflate.deflate(text, Zlib::BEST_COMPRESSION)
    end

    # nil rather than raising for an empty or unreadable blob: a diff is display
    # furniture, it must never stop a transcript from loading.
    def inflate(blob)
      return nil if blob.nil? || blob.empty?

      JSON.parse(Zlib::Inflate.inflate(blob.to_s))
    rescue Zlib::Error, JSON::ParserError
      nil
    end

    def refresh_count(session_id)
      id = text_id(session_id)
      @db.execute(<<~SQL, [id, id])
        UPDATE sessions
        SET msg_count = (SELECT COUNT(*) FROM messages WHERE session_id = ?)
        WHERE id = ?
      SQL
    end

    # A message written must not leave the conversation missing from the sidebar,
    # and a conversation that just got a turn must move to the top of it. Both
    # are this one row: created empty on the first append, then moved forward —
    # never backwards, so an append carrying an old timestamp cannot reorder the
    # list.
    def touch_session(session_id, messages)
      id = text_id(session_id)
      newest = messages.filter_map { |m| m.is_a?(Hash) ? m["timestamp"] : nil }.max
      newest = newest.to_s.empty? ? Time.now.iso8601 : newest.to_s

      @db.execute("INSERT OR IGNORE INTO sessions(id, updated_at) VALUES(?, ?)", [id, newest])
      @db.execute(<<~SQL, [newest, id, newest])
        UPDATE sessions SET updated_at = ? WHERE id = ? AND (updated_at IS NULL OR updated_at < ?)
      SQL
    end

    # A session id that is always the same value in SQLite.
    #
    # Ids come from HTTP paths (WEBrick hands those over as ASCII-8BIT), form
    # fields and Ractor ports. sqlite3 binds a string with that encoding as a
    # BLOB, and a BLOB is not equal to the TEXT row of the same bytes — so the
    # same conversation could be stored twice, once under each type, with the
    # BLOB copy invisible to every `WHERE id = ?` and missing from the sidebar's
    # name and timestamp. One normalisation at the edge of the store keeps every
    # write and every lookup on the same row.
    def text_id(value)
      id = value.to_s
      id = id.dup.force_encoding(Encoding::UTF_8) if id.encoding == Encoding::ASCII_8BIT
      id.valid_encoding? ? id : id.scrub
    end

    def timestamp_of(iso)
      return 0.0 if iso.to_s.empty?

      Time.iso8601(iso.to_s).to_f
    rescue ArgumentError, TypeError
      0.0
    end
  end
end
