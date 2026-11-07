# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "../tool"

module Rubot
  module Tools
    class FileTool < Tool
      MAX_READ = 20_000  # characters returned by one read
      MAX_READ_LINES = 2_000 # lines returned when offset/limit are used
      MAX_LIST = 100     # entries

      attr_accessor :safety_guard

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
                   returned so you can continue from there.
          - edit:  Replace `old_string` with `new_string`. `old_string` must
                   appear exactly once unless `replace_all` is true. This is the
                   preferred way to change an existing file — it does not
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
              "description" => "File or directory path"
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
          "required" => [ "operation", "path" ]
        }
      end

      def execute(arguments)
        # A call with only a path means read: models routinely leave the
        # operation out for the most common case, and rejecting it burned a
        # full provider round every time.
        operation = arguments["operation"].to_s
        operation = "read" if operation.empty? && !arguments["path"].to_s.empty?
        path = arguments["path"]
        content = arguments["content"]

        case operation
        when "read"    then read_file(path, offset: arguments["offset"], limit: arguments["limit"])
        when "edit"    then edit_file(path, arguments["old_string"], arguments["new_string"],
                                       replace_all: arguments["replace_all"])
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
      # write on an existing file = data loss (overwriting).
      # write on a new file = safe (creating).
      # append = safe (never destroys existing data).
      # delete on an existing file = data loss, so it is confirmed too.
      def dangerous_action?(arguments)
        operation = arguments["operation"].to_s
        return false unless %w[write delete].include?(operation)

        path = arguments["path"]
        return false if path.nil?

        # Only flag if the file already exists (overwriting = data loss)
        begin
          p = Pathname.new(path).expand_path
          File.exist?(p)
        rescue StandardError
          false
        end
      end

      private

      def safe_path(path)
        expanded = Pathname.new(path).expand_path
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
      def check_path(path, operation:)
        guard = @safety_guard
        if guard.nil?
          warn "[file:safety] NO safety guard configured for #{operation} #{path}" if Rubot.debug?
          return true
        end
        warn "[file:safety] restrict=#{guard.restrict_to_workspace} #{operation}=#{path}" if Rubot.debug?
        guard.check_path(path, operation: operation)
      end

      def read_file(path, offset: nil, limit: nil)
        check_path(path, operation: :read)
        p = safe_path(path)
        raise "File not found: #{path}" unless File.exist?(p)
        raise "Not a file: #{path}" unless File.file?(p)

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
      def edit_file(path, old_string, new_string, replace_all: false)
        check_path(path, operation: :write)
        raise "Cannot edit MEMORY.md — use the memory tool instead." if memory_file?(path)

        old_text = old_string.to_s
        raise "No old_string provided (the exact text to replace)" if old_text.empty?

        p = safe_path(path)
        raise "File not found: #{path}" unless File.exist?(p)
        raise "Not a file: #{path}" unless File.file?(p)

        content = File.read(p, encoding: "UTF-8")
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
        "Edited #{p}: replaced #{occurrences} occurrence(s), " \
          "#{old_text.length} -> #{new_string.to_s.length} chars"
      end

      def write_file(path, content)
        check_path(path, operation: :write)
        raise "Cannot overwrite MEMORY.md — use the memory tool (append/update_section) instead. Memory cannot be reset." if memory_file?(path)
        raise "No content provided" if content.nil?
        p = safe_path(path)
        FileUtils.mkdir_p(File.dirname(p))
        File.write(p, content, encoding: "UTF-8")
        "Written #{content.length} characters to #{p}"
      end

      def append_file(path, content)
        check_path(path, operation: :write)
        # FIX (VULN-9): Block append to MEMORY.md — same protection as write
        raise "Cannot append to MEMORY.md — use the memory tool (append/update_section) instead. Memory cannot be reset." if memory_file?(path)
        raise "No content provided" if content.nil?
        p = safe_path(path)
        FileUtils.mkdir_p(File.dirname(p))
        File.open(p, "a", encoding: "UTF-8") { |f| f.write(content) }
        "Appended #{content.length} characters to #{p}"
      end

      # Removing a whole file. Directories are refused so a stray call cannot
      # take a tree with it; the caller deletes their files one by one.
      def delete_file(path)
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
      def memory_file?(path)
        basename = File.basename(path).downcase
        basename == "memory.md"
      end
    end
  end
end
