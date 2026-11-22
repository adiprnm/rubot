# frozen_string_literal: true

module Rubot
  class Store
    # Full-text search over the archive: the query, the snippets it returns,
    # and the index behind it.
    #
    # The index is a separate table maintened from triggers, so everything here
    # is either reading it or rebuilding it. The weights and the term cap are
    # constants of the class, not of a call: two searches in flight must rank
    # the same way.
    #
    # Moved as it was, comments included. A snippet is escaped before it is
    # turned into markup, and that order is what keeps a message from becoming
    # a tag.
    module Search
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

      private

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
    end
  end
end
