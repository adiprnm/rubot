# frozen_string_literal: true
require "json"
require "fileutils"
require "time"
require "sqlite3"
require_relative "session"

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
  #   * `content` is the message exactly as the JSON file held it and `text` is
  #     its flattened text. Losing `content` would lose tool calls and reasoning;
  #     `text` is only the searchable and displayable projection.
  #
  # Ractor safety: SQLite3::Database is not Ractor-safe — SQLite3 raises
  # Ractor::UnsafeError from open_v2 inside a non-main Ractor (verified, not
  # assumed). A Store is therefore opened in the main Ractor and reached from a
  # SessionActor through a port, never instantiated inside one.
  class Store
    SCHEMA_VERSION = 1
    DB_FILENAME = "sessions.db"
    # Small on purpose: the sidebar reads three short columns and the archive is
    # read once per turn, so a large page cache would only cost resident memory
    # (it is per connection, and connections cannot be shared across Ractors).
    DEFAULT_CACHE_KB = 512
    BUSY_TIMEOUT_MS = 5_000

    attr_reader :path

    # Where the archive lives for a given sessions directory: next to the JSON
    # files it replaces, so config.yml's own directory stays the single place
    # that decides where sessions are.
    def self.path_for(sessions_dir)
      File.join(File.dirname(sessions_dir), DB_FILENAME)
    end

    def initialize(path, cache_kb: DEFAULT_CACHE_KB)
      @path = path
      FileUtils.mkdir_p(File.dirname(path))
      @db = SQLite3::Database.new(path)
      @db.busy_timeout = BUSY_TIMEOUT_MS
      apply_pragmas(cache_kb)
      migrate!
    end

    # --- writing -------------------------------------------------------

    # Append messages at their position in the transcript. `start_index` is the
    # index of the first message in the array; re-appending a block that is
    # already stored is a no-op, so a turn saved twice cannot duplicate history.
    #
    # Returns how many rows were actually new.
    def append_messages(session_id, messages, start_index: 0)
      return 0 if messages.nil? || messages.empty?

      inserted = 0
      in_transaction do
        statement = @db.prepare(<<~SQL)
          INSERT OR IGNORE INTO messages(session_id, idx, role, text, created_at, payload)
          VALUES(?, ?, ?, ?, ?, ?)
        SQL
        messages.each_with_index do |message, offset|
          next unless message.is_a?(Hash)

          content = message["content"]
          statement.execute(
            session_id.to_s,
            start_index + offset,
            message["role"].to_s,
            Session.text_content(content),
            message["timestamp"],
            JSON.generate(message)
          )
          # INSERT OR IGNORE affects zero rows when the (session_id, idx) pair is
          # already there, which is exactly the case that must not be counted.
          inserted += @db.changes
        end
        statement.close
      end
      refresh_count(session_id)
      inserted
    end

    # Metadata row for the sidebar. Kept separate from the messages so renaming a
    # conversation does not touch the transcript.
    def upsert_session(id:, title: "", created_at: nil, updated_at: nil, cwd: nil, bytes: 0)
      @db.execute(<<~SQL, [id.to_s, title.to_s, created_at, updated_at, cwd, bytes])
        INSERT INTO sessions(id, title, created_at, updated_at, cwd, bytes)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          title      = excluded.title,
          updated_at = excluded.updated_at,
          cwd        = excluded.cwd,
          bytes      = excluded.bytes
      SQL
      refresh_count(id)
      self
    end

    # --- reading -------------------------------------------------------

    # What the sidebar shows, newest first. Three columns and no JSON parsing:
    # this is the query that replaces Session.describe over the whole directory.
    def sidebar(limit: 40)
      @db.execute(<<~SQL, [limit.to_i]).map do |(id, title, updated_at, count)|
        SELECT id, title, updated_at, msg_count
        FROM sessions
        ORDER BY COALESCE(updated_at, '') DESC
        LIMIT ?
      SQL
        {
          id: id,
          title: title.to_s,
          updated_at: updated_at,
          timestamp: timestamp_of(updated_at),
          messages: count.to_i
        }
      end
    end

    # The transcript, in order, with every message reconstructed as it was.
    #
    # `payload` is the whole message, so a tool call, its reasoning and its
    # parts array all survive the round trip. Nothing is stored twice: the
    # searchable projection lives in `text`, and content is read back out of the
    # payload rather than kept as a third copy (which cost 4 MB on 7k messages).
    def load_session(session_id)
      rows = @db.execute(<<~SQL, [session_id.to_s])
        SELECT payload, text, role, created_at FROM messages
        WHERE session_id = ? ORDER BY idx
      SQL
      return nil if rows.empty?

      messages = rows.map do |(payload, text, role, created_at)|
        message = decode_payload(payload) || { "role" => role.to_s, "content" => text.to_s }
        message["timestamp"] ||= created_at if created_at
        message
      end
      { id: session_id.to_s, messages: messages }
    end

    def session_ids
      @db.execute("SELECT id FROM sessions ORDER BY COALESCE(updated_at, '') DESC").map(&:first)
    end

    def message_count(session_id)
      @db.get_first_value("SELECT COUNT(*) FROM messages WHERE session_id = ?", [session_id.to_s]).to_i
    end

    # Index of the newest message stored for a session, or -1 when there is none.
    # The actor uses it to append only what is new instead of rewriting the whole
    # transcript every turn.
    def last_index(session_id)
      @db.get_first_value("SELECT COALESCE(MAX(idx), -1) FROM messages WHERE session_id = ?", [session_id.to_s]).to_i
    end

    def counts
      {
        sessions: @db.get_first_value("SELECT COUNT(*) FROM sessions").to_i,
        messages: @db.get_first_value("SELECT COUNT(*) FROM messages").to_i,
        chars: @db.get_first_value("SELECT COALESCE(SUM(LENGTH(text)), 0) FROM messages").to_i
      }
    end

    def close
      @db.close if @db && !@db.closed?
      @db = nil
    end

    # --- import --------------------------------------------------------

    # Load every session file in `dir` into the archive. Idempotent: a file that
    # was already imported only fills in what is missing, so running it twice
    # changes nothing.
    def import_directory(dir)
      stats = { files: 0, sessions: 0, messages: 0, skipped: 0 }
      Dir.glob(File.join(dir, "*.json")).sort.each do |path|
        stats[:files] += 1
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

    # One file. Returns the number of messages it holds, or nil when the file has
    # nothing to resume (Session.describe_data decides that, the same rule the
    # sidebar uses, so the list looks the same after the migration).
    def import_file(path)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      summary = Session.describe_data(data, id: File.basename(path, ".json"), mtime: File.mtime(path))
      return nil unless summary

      messages = Session.normalize_utf8(data["messages"])
      in_transaction do
        append_messages(summary[:id], messages)
        upsert_session(
          id: summary[:id],
          title: summary[:title].to_s,
          created_at: data["created_at"],
          updated_at: summary[:updated_at],
          cwd: summary[:cwd],
          bytes: File.size(path)
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
      current = @db.get_first_value("PRAGMA user_version").to_i
      return if current >= SCHEMA_VERSION

      @db.transaction do
        create_schema! if current < 1
        @db.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
      end
    end

    def create_schema!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS sessions(
          id         TEXT PRIMARY KEY,
          title      TEXT NOT NULL DEFAULT '',
          created_at TEXT,
          updated_at TEXT,
          cwd        TEXT,
          msg_count  INTEGER NOT NULL DEFAULT 0,
          bytes      INTEGER NOT NULL DEFAULT 0
        )
      SQL
      # No DELETE, ever: see the class comment. idx is the position in the
      # transcript and (session_id, idx) is what makes a re-save a no-op.
      #
      # `content` is not a column: it is recoverable from `payload`, and keeping
      # both cost 4 MB on 7k messages. `text` is the one derived copy worth
      # paying for — search and snippets read it without touching JSON.
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS messages(
          id         INTEGER PRIMARY KEY,
          session_id TEXT NOT NULL,
          idx        INTEGER NOT NULL,
          role       TEXT NOT NULL,
          text       TEXT NOT NULL DEFAULT '',
          created_at TEXT,
          payload    TEXT NOT NULL DEFAULT '',
          UNIQUE(session_id, idx)
        )
      SQL
      # The UNIQUE constraint already indexes (session_id, idx); a second index
      # on the same columns would only cost disk and write time.
      @db.execute("CREATE INDEX IF NOT EXISTS idx_sessions_updated ON sessions(updated_at)")
    end






    def decode_payload(payload)
      return nil if payload.nil? || payload.empty?

      JSON.parse(payload)
    rescue JSON::ParserError
      nil
    end

    def refresh_count(session_id)
      @db.execute(<<~SQL, [session_id.to_s, session_id.to_s])
        UPDATE sessions
        SET msg_count = (SELECT COUNT(*) FROM messages WHERE session_id = ?)
        WHERE id = ?
      SQL
    end

    def timestamp_of(iso)
      return 0.0 if iso.to_s.empty?

      Time.iso8601(iso.to_s).to_f
    rescue ArgumentError, TypeError
      0.0
    end
  end
end
