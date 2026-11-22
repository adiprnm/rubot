# frozen_string_literal: true

module Rubot
  class Session
    # Finding saved sessions: the list /resume shows, one entry, or the
    # messages behind it.
    #
    # Two sources answer the same questions - the SQLite archive when the
    # process has one, the JSON files otherwise - and nothing above this layer
    # knows which one did. These are class-level readers, extended onto Session
    # so `Session.index` and friends keep working for the TUI, the web sidebar
    # and the store indexer, which all ask in those words.
    module Index
      # Directory holding one JSON file per session.
      def sessions_dir(workspace)
        workspace && File.join(workspace, "sessions")
      end

      # A session id that is not in use yet, used by the TUI to start a new
      # conversation on every launch. The file itself is not created until the
      # session has a message (see #save!), so quitting an untouched launch
      # leaves nothing behind.
      def fresh_id(workspace = nil, prefix: "default", stamp: nil, dir: nil)
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
      def index(workspace = nil, cwd: :all, dir: nil)
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
      def find(workspace, id, dir: nil)
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
      def transcript(workspace, id, dir: nil)
        transcript_with_start(workspace, id, dir: dir).first
      end

      # The transcript plus the index its first message carries in the archive.
      #
      # A trimmed session starts partway through: `messages_start` is the index
      # the stored transcript begins at, so position `n` in the returned array is
      # message `start + n`. Search hits are addressed by that absolute index, and
      # this is what turns one into a place in the list a page can draw. The file
      # fallback starts at zero, which is what a file always was.
      def transcript_with_start(workspace, id, dir: nil)
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
      def archive_transcript(workspace, id, dir: nil)
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
      def entry_from_row(row)
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
      def label(entry)
        [ entry[:title], entry[:last_prompt], entry[:id] ]
          .map { |value| value.to_s.strip }
          .find { |value| !value.empty? }
          .to_s
      end

      # Read one session file into the summary used by #index and #find.
      def describe(path)
        return nil unless File.file?(path)

        data = JSON.parse(File.read(path))
        describe_data(data, id: File.basename(path, ".json"), mtime: File.mtime(path))
      rescue JSON::ParserError, SystemCallError, EncodingError
        nil
      end

      # The same summary from already-parsed data, so a caller that also needs the
      # messages (the SQLite importer) does not parse the file twice.
      def describe_data(data, id:, mtime: nil)
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
      def last_prompt(messages)
        message = messages.reverse.find { |msg| msg["role"] == "user" && !text_content(msg["content"]).empty? }
        message ||= messages.reverse.find { |msg| !text_content(msg["content"]).empty? }
        snippet(text_content(message && message["content"]), 100)
      end

      # The name a session is listed under: the model-chosen title when one has
      # been stored, otherwise the opening prompt.
      def title_for(messages, title)
        stored = title.to_s.gsub(/\s+/, " ").strip
        return snippet(stored, 60) unless stored.empty?

        first_prompt(messages)
      end

      # The first thing the user asked, used as the conversation's name.
      def first_prompt(messages)
        message = messages.find { |msg| msg["role"] == "user" && !text_content(msg["content"]).empty? }
        snippet(text_content(message && message["content"]), 60)
      end

      def text_content(content)
        case content
        when String then content
        when Array
          content.filter_map { |part| part.is_a?(Hash) ? part["text"] : part }.join(" ")
        when Hash then content["text"].to_s
        else ""
        end
      end

      def snippet(text, limit)
        clean = text.to_s.gsub(/\s+/, " ").strip
        return clean if clean.length <= limit

        "#{clean[0, limit - 1]}…"
      end
    end
  end
end
