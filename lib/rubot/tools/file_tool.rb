# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "../tool"

module Rubot
  module Tools
    class FileTool < Tool
      MAX_READ = 20_000  # characters returned by one read
      # One call may read several files, but the answer still has to fit in a
      # request: past this much, the remaining paths are named and left for a
      # call of their own rather than silently dropped.
      MAX_BATCH_READ = 60_000
      MAX_READ_LINES = 2_000 # lines returned when offset/limit are used
      MAX_LIST = 100     # entries
      # Compare at most this much of an existing file before deciding whether
      # a rewrite destroys it; bigger files are treated as fully replaced.
      MAX_COMPARE_BYTES = 1_000_000
      # A rewrite that keeps less than this share of the old lines is data
      # loss; a one-line fix keeps ~99%, so it never asks.
      DESTRUCTIVE_WRITE_RATIO = 0.7

      attr_accessor :safety_guard
      attr_reader :last_read_path

      def initialize(safety_guard: nil)
        @safety_guard = safety_guard
      end

      def name
        "file_ops"
      end

      def description
        desc = <<~DESC.strip
          Read files, make targeted edits, create and delete files, list
          directories, and inspect paths.
          Operations: read, edit, write, append, delete, list, info
          - read:  Read a file. Pass `offset` (1-based line) and `limit` (lines)
                   to read part of a long file; the reply says which lines were
                   returned so you can continue from there. Pass `paths` (an
                   array) to read several files in one call: one round trip
                   instead of one per file, each answered under its own header.
          - edit:  Replace `old_string` with `new_string` in the file at
                   `path`. Both `path` and `old_string` are required; `old_string`
                   must appear exactly once unless `replace_all` is true. This is
                   the preferred way to change an existing file — it does not
                   rewrite the parts you did not touch.
          - write: Write content to a file (overwrites the whole file)
          - append: Append content to a file
          - delete: Delete one file (directories are refused; delete their
                   files one by one)
          - list:  List directory contents
          - info:  Get file/directory information
        DESC
        if @safety_guard&.restrict_to_workspace
          ws = @safety_guard.workspace
          desc + "\nAll operations are restricted to the workspace: #{ws}"
        else
          desc
        end
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "operation" => {
              "type" => "string",
              "enum" => %w[read edit write append delete list info],
              "description" => "The file operation to perform (default: read)"
            },
            "path" => {
              "type" => "string",
              "description" => "File or directory path. Optional when `paths` is given."
            },
            "paths" => {
              "type" => "array",
              "items" => { "type" => "string" },
              "description" => "Several paths to read in one call (read operation). " \
                               "Cheaper than one call per file: each is answered under its own header."
            },
            "content" => {
              "type" => "string",
              "description" => "Content to write or append (for write/append operations)"
            },
            "old_string" => {
              "type" => "string",
              "description" => "Exact text to replace (for the edit operation). Include enough surrounding lines to be unique."
            },
            "new_string" => {
              "type" => "string",
              "description" => "Replacement text (for the edit operation). Use an empty string to delete the matched text."
            },
            "replace_all" => {
              "type" => "boolean",
              "description" => "Replace every occurrence instead of requiring exactly one (edit operation)"
            },
            "offset" => {
              "type" => "integer",
              "description" => "First line to read, 1-based (read operation, optional)"
            },
            "limit" => {
              "type" => "integer",
              "description" => "How many lines to read (read operation, optional)"
            }
          },
          "required" => [ "operation" ]
        }
      end

      def execute(arguments)
        # A call with only a path means read: models routinely leave the
        # operation out for the most common case, and rejecting it burned a
        # full provider round every time.
        operation = arguments["operation"].to_s
        paths = Array(arguments["paths"]).map { |entry| entry.to_s }.reject(&:empty?)
        path = arguments["path"]
        operation = "read" if operation.empty? && !(path.to_s.empty? && paths.empty?)
        content = arguments["content"]

        case operation
        when "read"    then read_files(paths, path, offset: arguments["offset"], limit: arguments["limit"])
        when "edit"    then edit_file(path, arguments["old_string"], arguments["new_string"],
                                       replace_all: arguments["replace_all"],
                                       offset: arguments["offset"], limit: arguments["limit"])
        when "write"   then write_file(path, content)
        when "append"  then append_file(path, content)
        when "delete"  then delete_file(path)
        when "list"    then list_dir(path)
        when "info"    then file_info(path)
        else "ERROR: Unknown operation '#{operation.inspect}'. Use: read, edit, write, append, delete, list, info"
        end
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end

      # Returns true if the operation could cause data loss.
      # delete on an existing file = data loss, so it is confirmed.
      # write on a new file = safe (creating).
      # write on an existing file = only when the new content drops most of
      # what is there (see #dangerous_action_reason).
      # append = safe (never destroys existing data).
      def dangerous_action?(arguments)
        !dangerous_action_reason(arguments).nil?
      end

      # Shared with #dangerous_action? so the decision and the explanation can
      # never disagree. A rewrite that keeps most of the old lines (a one-line
      # fix, a new section, a longer file) is not worth asking about; a rewrite
      # that throws the content away is.
      def dangerous_action_reason(arguments)
        operation = arguments["operation"].to_s
        return nil unless %w[write delete].include?(operation)

        path = arguments["path"]
        return nil if path.nil? || path.to_s.strip.empty?

        target = begin
          resolve_path(path)
        rescue StandardError
          return nil
        end
        return nil unless target.file? # nothing there to lose

        existing = comparable_lines(target)
        return "overwrite #{path} (contents cannot be compared)" if existing.nil?

        if operation == "delete"
          return existing.empty? ? "delete #{path}" : "delete #{path} (#{existing.length} lines)"
        end

        incoming = split_lines(arguments["content"].to_s)
        return "empty #{path} (#{existing.length} lines would be lost)" if incoming.empty?

        kept = multiset_intersection(existing, incoming)
        removed = existing.length - kept
        return nil if removed.zero?

        # A small edit loses a few lines and keeps the rest. A rewrite that
        # keeps less than DESTRUCTIVE_WRITE_RATIO of the file is data loss.
        return nil if kept.to_f / existing.length >= DESTRUCTIVE_WRITE_RATIO

        "overwrite #{path} — #{removed} of #{existing.length} lines would be lost"
      end

      private

      # Old lines still present in the new content (multiset: a line repeated
      # twice counts twice). Cheap and good enough to tell an edit from a
      # rewrite without diffing the whole file.
      def multiset_intersection(old_lines, new_lines)
        incoming = new_lines.tally
        old_lines.tally.sum { |line, count| [ count, incoming[line].to_i ].min }
      end

      def split_lines(text)
        # lines(chomp: true) counts what a reader would call lines: a trailing
        # newline does not add an empty one, and an empty string is no lines.
        text.lines(chomp: true)
      end

      # Lines of the file to compare against, or nil when it is too big or not
      # text (a binary overwrite is always worth the question).
      def comparable_lines(target)
        return nil if target.size > MAX_COMPARE_BYTES

        split_lines(File.binread(target.to_s).force_encoding(Encoding::UTF_8).scrub)
      rescue StandardError
        nil
      end

      # Resolve a path against the agent's workspace when one is set. The
      # process cwd is only a fallback for tools used outside a channel (tests,
      # scripts), where no workspace has been injected.
      def resolve_path(path)
        candidate = Pathname.new(path.to_s)
        candidate = Pathname.new(workspace).join(candidate) if !candidate.absolute? && workspace
        candidate.expand_path
      end

      def safe_path(path)
        expanded = resolve_path(path)
        # FIX (VULN-9): Resolve symlinks at operation time to prevent TOCTOU attacks
        # where a file is replaced with a symlink between check and use
        return expanded if expanded.to_s.start_with?("/dev/")
        if File.exist?(expanded.to_s)
          begin
            return Pathname.new(File.realpath(expanded.to_s))
          rescue SystemCallError
            # File was deleted between check and use — let the operation fail naturally
          end
        end
        expanded
      end
      # Confirm the bytes are on disk before reporting success.
      #
      # A write that reports "Edited" while the file is unchanged is the one
      # failure a caller cannot see and cannot recover from — it goes on to build
      # on a change that is not there. It has been observed (2026-11-11): every
      # edit in a session reported OK, while reading the same paths found nothing.
      # The cause was never reproduced, so this does not pretend to fix it: it
      # refuses to lie about it, and names the path, the sizes and the mtime so
      # the next report can be acted on instead of guessed at.
      def verify_written!(p, content)
        on_disk = File.read(p, encoding: "UTF-8")
        return true if on_disk == content

        raise "Write verification failed for #{p}: wrote #{content.bytesize} bytes, " \
              "read back #{on_disk.bytesize} bytes (mtime #{File.mtime(p).utc.iso8601}). " \
              "Another process may be rewriting this file; the edit is not in effect."
      end

      # The append case only needs the tail to be there; reading a whole large
      # file back to prove a 200-byte append would cost more than it buys.
      def verify_appended!(p, content)
        expected = content.bytesize
        actual = File.size(p)
        return true if actual >= expected && File.binread(p, expected, actual - expected) == content.b

        raise "Append verification failed for #{p}: the file does not end with the " \
              "#{expected} bytes that were appended (size #{actual}). " \
              "Another process may be rewriting this file; the append is not in effect."
      end

      def check_path(path, operation:)
        guard = @safety_guard
        if guard.nil?
          warn "[file:safety] NO safety guard configured for #{operation} #{path}" if Rubot.debug?
          return true
        end
        warn "[file:safety] restrict=#{guard.restrict_to_workspace} #{operation}=#{path}" if Rubot.debug?
        guard.check_path(path, operation: operation)
      end

      # One read for several files. They are answered under their own headers
      # because that is how the model tells them apart, and a path that could
      # not be read is reported in place: one bad path must not hide the files
      # that did load.
      def read_files(paths, path, offset: nil, limit: nil)
        return read_file(path, offset: offset, limit: limit) if paths.empty?

        budget = MAX_BATCH_READ
        out = +""
        paths.each do |candidate|
          body = begin
            read_file(candidate, offset: offset, limit: limit)
          rescue StandardError => e
            "ERROR: #{e.class}: #{e.message}"
          end

          if out.length + body.length > budget
            out << "\n=== #{candidate} ===\n(read skipped: #{budget} characters already " \
                   "returned; read this one in a call of its own)\n"
            next
          end

          out << "\n=== #{candidate} ===\n" << body << "\n"
        end
        out.sub(/\A\n/, "")
      end

      def read_file(path, offset: nil, limit: nil)
        raise "No path provided (the file to read)" if path.nil? || path.to_s.strip.empty?
        check_path(path, operation: :read)
        p = safe_path(path)
        raise "File not found: #{path}" unless File.exist?(p)
        raise "Not a file: #{path}" unless File.file?(p)

        @last_read_path = p.to_s
        content = File.read(p, encoding: "UTF-8")

        if offset.nil? && limit.nil?
          return content if content.length <= MAX_READ

          return content[0...MAX_READ] +
                 "\n... (file truncated at #{MAX_READ} of #{content.length} chars; " \
                 "call read again with offset/limit to see the rest)"
        end

        lines = content.lines
        total = lines.size
        start = offset.to_i
        start = 1 if start < 1
        count = limit.to_i
        count = MAX_READ_LINES if count < 1
        count = MAX_READ_LINES if count > MAX_READ_LINES

        slice = lines[(start - 1), count] || []
        return "(no lines: file has #{total} line(s), offset #{start} is past the end)" if slice.empty?

        body = slice.join
        if body.length > MAX_READ
          body = body[0...MAX_READ] + "\n... (this range was truncated at #{MAX_READ} chars)"
        end

        last = start + slice.size - 1
        "#{body}\n... (lines #{start}-#{last} of #{total})"
      end

      # Replace an exact block of text. Far safer and cheaper than rewriting a
      # whole file, which is what a multi-file change used to require.
      def edit_file(path, old_string, new_string, replace_all: false, offset: nil, limit: nil)
        if path.nil? || path.to_s.strip.empty?
          if @last_read_path
            path = @last_read_path
          else
            raise "No path provided (the file to edit)"
          end
        end
        check_path(path, operation: :write)
        raise "Cannot edit MEMORY.md — use the memory tool instead." if memory_file?(path)

        old_text = old_string.to_s

        p = safe_path(path)
        raise "File not found: #{path}" unless File.exist?(p)
        raise "Not a file: #{path}" unless File.file?(p)

        @last_read_path = p.to_s
        content = File.read(p, encoding: "UTF-8")

        # Line-range edit: when old_string is omitted but offset is given, replace
        # those lines with new_string. Models that address a target by line number
        # (offset/limit) instead of exact text land here.
        if old_text.empty? && !offset.nil?
          lines = content.lines
          total = lines.size
          start = offset.to_i
          start = 1 if start < 1
          count = limit.to_i
          count = 1 if count < 1
          ending = [ start - 1 + count, total ].min
          prefix = lines[0...(start - 1)].join
          suffix = (ending < total) ? lines[ending..].join : ""
          replacement = new_string.to_s
          replacement += "\n" unless replacement.empty? || replacement.end_with?("\n")
          # If the file did not end with a newline and we are replacing the last
          # line, keep it that way.
          if suffix.empty? && !content.end_with?("\n") && replacement.end_with?("\n")
            replacement = replacement.chomp("\n")
          end
          updated = prefix + replacement + suffix
          File.write(p, updated, encoding: "UTF-8")
          verify_written!(p, updated)
          return "Edited #{p}: replaced lines #{start}-#{[ start + count - 1, total ].min} "                  "with #{new_string.to_s.length} chars"
        end

        if old_text.empty?
          raise "No old_string provided (the exact text to replace)"
        end

        pattern = Regexp.new(Regexp.escape(old_text), Regexp::MULTILINE)
        occurrences = content.scan(pattern).size

        if occurrences.zero?
          hint = old_text.include?("\\") ? " The old_string contains backslashes; pass the literal text." : ""
          raise "old_string not found in #{p}. Read the file again and copy the exact text, " \
                "including indentation.#{hint}"
        end

        if occurrences > 1 && !replace_all
          raise "old_string appears #{occurrences} times in #{p}. Include more surrounding " \
                "lines so it is unique, or pass replace_all: true to change every occurrence."
        end

        updated = if replace_all
          content.gsub(pattern) { new_string.to_s }
        else
          content.sub(pattern) { new_string.to_s }
        end

        File.write(p, updated, encoding: "UTF-8")
        verify_written!(p, updated)
        "Edited #{p}: replaced #{occurrences} occurrence(s), " \
          "#{old_text.length} -> #{new_string.to_s.length} chars"
      end

      def write_file(path, content)
        if path.nil? || path.to_s.strip.empty?
          if @last_read_path
            path = @last_read_path
          else
            raise "No path provided (the file to write)"
          end
        end
        check_path(path, operation: :write)
        raise "Cannot overwrite MEMORY.md — use the memory tool (append/update_section) instead. Memory cannot be reset." if memory_file?(path)
        raise "No content provided" if content.nil?
        p = safe_path(path)
        FileUtils.mkdir_p(File.dirname(p))
        @last_read_path = p.to_s
        File.write(p, content, encoding: "UTF-8")
        verify_written!(p, content)
        "Written #{content.length} characters to #{p}"
      end

      def append_file(path, content)
        if path.nil? || path.to_s.strip.empty?
          if @last_read_path
            path = @last_read_path
          else
            raise "No path provided (the file to append to)"
          end
        end
        check_path(path, operation: :write)
        # FIX (VULN-9): Block append to MEMORY.md — same protection as write
        raise "Cannot append to MEMORY.md — use the memory tool (append/update_section) instead. Memory cannot be reset." if memory_file?(path)
        raise "No content provided" if content.nil?
        p = safe_path(path)
        FileUtils.mkdir_p(File.dirname(p))
        @last_read_path = p.to_s
        File.open(p, "a", encoding: "UTF-8") { |f| f.write(content) }
        verify_appended!(p, content)
        "Appended #{content.length} characters to #{p}"
      end

      # Removing a whole file. Directories are refused so a stray call cannot
      # take a tree with it; the caller deletes their files one by one.
      def delete_file(path)
        raise "No path provided (the file to delete)" if path.nil? || path.to_s.strip.empty?
        check_path(path, operation: :write)
        raise "Cannot delete MEMORY.md — use the memory tool instead. Memory cannot be reset." if memory_file?(path)
        p = safe_path(path)
        raise "File not found: #{path}" unless File.exist?(p)
        raise "Refusing to delete a directory: #{path} — delete its files one by one" if File.directory?(p)

        size = File.size(p)
        File.delete(p)
        "Deleted #{p} (#{size} bytes)"
      end

      def list_dir(path)
        raise "No path provided (the directory to list)" if path.nil? || path.to_s.strip.empty?
        check_path(path, operation: :read)
        p = safe_path(path)
        raise "Directory not found: #{path}" unless Dir.exist?(p)

        entries = Dir.entries(p).reject { |e| e.start_with?(".") }.sort
        entries = entries[0...MAX_LIST]

        result = entries.map do |e|
          full = File.join(p, e)
          prefix = File.directory?(full) ? "📁" : "📄"
          "  #{prefix} #{e}"
        end.join("\n")

        total = Dir.entries(p).reject { |e| e.start_with?(".") }.size
        header = "📁 #{p} (#{total} entries):"
        header += "\n... (showing first #{MAX_LIST} of #{total})" if entries.length < total
        "#{header}\n#{result}"
      end

      def file_info(path)
        raise "No path provided (the path to inspect)" if path.nil? || path.to_s.strip.empty?
        check_path(path, operation: :read)
        p = safe_path(path)
        raise "Path not found: #{path}" unless File.exist?(p)

        stat = File.stat(p)
        <<~INFO.strip
          Path: #{p}
          Type: #{File.file?(p) ? "File" : "Directory"}
          Size: #{stat.size} bytes
          Permissions: #{stat.mode.to_s(8)[-3..]}
          Modified: #{stat.mtime}
          Created: #{stat.ctime}
        INFO
      end

      # Check if a path targets the memory file.
      # Prevents the bot from bypassing the memory tool to directly
      # overwrite or delete MEMORY.md.
      # Memory is managed through the memory tool only, never by editing the
      # file directly. That covers the global MEMORY.md / MEMORY_ARCHIVE.md and
      # the per-workspace <slug>.md / <slug>_ARCHIVE.md in the memory directory.
      def memory_file?(path)
        return false if path.nil? || path.to_s.strip.empty?
        basename = File.basename(path).downcase
        return true if basename == "memory.md" || basename == "memory_archive.md"

        basename.end_with?("_archive.md") && File.basename(File.dirname(path)) == "memory"
      end
    end
  end
end
