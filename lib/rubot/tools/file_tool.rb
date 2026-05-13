# frozen_string_literal: true

require "fileutils"
require "pathname"
require_relative "../tool"

module Rubot
  module Tools
    class FileTool < Tool
      MAX_READ = 20_000  # characters
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
          Perform file operations: read, write, append, list directory, or check file info.
          Operations: read, write, append, list, info
          - read: Read file contents
          - write: Write content to a file (overwrites)
          - append: Append content to a file
          - list: List directory contents
          - info: Get file/directory information
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
              "enum" => %w[read write append list info],
              "description" => "The file operation to perform"
            },
            "path" => {
              "type" => "string",
              "description" => "File or directory path"
            },
            "content" => {
              "type" => "string",
              "description" => "Content to write or append (for write/append operations)"
            }
          },
          "required" => [ "operation", "path" ]
        }
      end

      def execute(arguments)
        operation = arguments["operation"]
        path = arguments["path"]
        content = arguments["content"]

        case operation
        when "read"    then read_file(path)
        when "write"   then write_file(path, content)
        when "append"  then append_file(path, content)
        when "list"    then list_dir(path)
        when "info"    then file_info(path)
        else "ERROR: Unknown operation '#{operation}'. Use: read, write, append, list, info"
        end
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end

      # Returns true if the operation could cause data loss.
      # write on an existing file = data loss (overwriting).
      # write on a new file = safe (creating).
      # append = safe (never destroys existing data).
      def dangerous_action?(arguments)
        return false unless arguments["operation"] == "write"

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

      def read_file(path)
        check_path(path, operation: :read)
        p = safe_path(path)
        raise "File not found: #{path}" unless File.exist?(p)
        raise "Not a file: #{path}" unless File.file?(p)

        content = File.read(p, encoding: "UTF-8")
        if content.length > MAX_READ
          content[0...MAX_READ] + "\n... (file truncated, #{content.length} total chars)"
        else
          content
        end
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
