# frozen_string_literal: true
require "json"
require "fileutils"
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
      in_transaction do
        statement = @db.prepare(<<~SQL)
          INSERT OR IGNORE INTO messages(session_id, idx, role, text, created_at, payload, diff)
          VALUES(?, ?, ?, ?, ?, ?, ?)
        SQL
        messages.each_with_index do |message, offset|
          next unless message.is_a?(Hash)

          content = message["content"]
          payload, diff = split_display_field(message)
          statement.execute(
            session_id.to_s,
            start_index + offset,
            message["role"].to_s,
            Session.text_content(content),
            message["timestamp"],
            payload,
            diff
          )
          # INSERT OR IGNORE affects zero rows when the (session_id, idx) pair is
          # already there, which is exactly the case that must not be counted.
          inserted += @db.changes
        end
        statement.close
      end
      touch_session(session_id, messages)
      refresh_count(session_id)
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
          title          = excluded.title,
          updated_at     = excluded.updated_at,
          cwd            = excluded.cwd,
          bytes          = excluded.bytes,
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

    # Whether an id is already in use. Cheaper than loading the transcript: the
    # web client asks this before handing out a fresh id.
    def session?(session_id)
      id = text_id(session_id)
      return false if id.empty?

      !@db.get_first_value("SELECT 1 FROM sessions WHERE id = ? LIMIT 1", [id]).nil?
    end

    # What the sidebar shows, newest first. Three columns and no JSON parsing:
    # this is the query that replaces Session.describe over the whole directory.
    def sidebar(limit: 40)
      @db.execute(<<~SQL, [limit.to_i]).map do |(id, title, updated_at, count, cwd)|
        SELECT id, title, updated_at, msg_count, cwd
        FROM sessions
        ORDER BY COALESCE(updated_at, '') DESC
        LIMIT ?
      SQL
        {
          id: text_id(id),
          title: title.to_s,
          updated_at: updated_at,
          timestamp: timestamp_of(updated_at),
          messages: count.to_i,
          cwd: cwd
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

    def close
      @db.close if @db && !@db.closed?
      @db = nil
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
