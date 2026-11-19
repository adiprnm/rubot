# frozen_string_literal: true

require_relative "../tool"

module Rubot
  module Tools
    # Finds files and matching lines inside a directory tree. A dedicated tool
    # keeps the common "where is this defined?" step from costing a shell round
    # trip and a 20k-character dump, and gives the model stable `path:line`
    # anchors for a follow-up read or edit.
    class Search < Tool
      MAX_RESULTS = 100
      MAX_FILES_SCANNED = 5_000
      MAX_FILE_BYTES = 1_000_000
      MAX_LINE_CHARS = 300
      # Directories never worth walking in a code task.
      SKIP_DIRS = %w[
        .git .svn .hg .bundle .ruby-lsp .venv .tox
        node_modules tmp log coverage dist build target
        vendor/bundle docker-data
      ].freeze

      attr_accessor :safety_guard

      def initialize(safety_guard: nil)
        @safety_guard = safety_guard
      end

      def name
        "search"
      end

      def description
        desc = <<~DESC.strip
          Find files or matching lines under a directory, without shelling out.
          Operations:
          - content (default): grep a regular expression. Returns `path:line: text`.
          - files: match file paths against a glob such as `**/*.rb` or `*.yml`.
          At most #{MAX_RESULTS} results are returned; refine the pattern when a
          search is too broad. Binary files, .git, node_modules and build output
          are skipped.
        DESC
        if @safety_guard&.restrict_to_workspace
          desc + "\nSearches are restricted to: #{@safety_guard.workspace}"
        else
          desc
        end
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "pattern" => {
              "type" => "string",
              "description" => "Regular expression for content, or a glob for files"
            },
            "operation" => {
              "type" => "string",
              "enum" => %w[content files],
              "description" => "content (default) or files"
            },
            "path" => {
              "type" => "string",
              "description" => "Directory to search; defaults to the workspace"
            },
            "glob" => {
              "type" => "string",
              "description" => "Only scan files matching this glob, e.g. **/*.rb (content searches)"
            },
            "ignore_case" => {
              "type" => "boolean",
              "description" => "Case-insensitive content search"
            },
            "max_results" => {
              "type" => "integer",
              "description" => "Maximum results to return (default 50, max #{MAX_RESULTS})"
            }
          },
          "required" => [ "pattern" ]
        }
      end

      def execute(arguments)
        pattern = arguments["pattern"].to_s
        return "ERROR: no pattern provided" if pattern.strip.empty?

        base = arguments["path"].to_s
        base = default_base if base.strip.empty?
        check_path(base)
        base = File.expand_path(base)
        return "ERROR: directory not found: #{base}" unless Dir.exist?(base)

        max = arguments["max_results"].to_i
        max = 50 if max <= 0
        max = MAX_RESULTS if max > MAX_RESULTS

        operation = arguments["operation"].to_s
        operation = "content" if operation.empty?

        case operation
        when "files" then find_files(base, pattern, max)
        when "content"
          grep(base, pattern, arguments["glob"].to_s,
               ignore_case: arguments["ignore_case"] == true, max: max)
        else
          "ERROR: unknown operation '#{operation}'. Use: content, files"
        end
      rescue RegexpError => e
        "ERROR: invalid regular expression: #{e.message}"
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end

      private

      def default_base
        workspace || @safety_guard&.workspace || Dir.pwd
      end

      def check_path(path)
        guard = @safety_guard
        return true unless guard

        guard.check_path(path, operation: :read)
      rescue StandardError => e
        raise "Path blocked by safety guard: #{e.message}"
      end

      def grep(base, pattern, glob, ignore_case:, max:)
        regex = if ignore_case
          Regexp.new(pattern, Regexp::IGNORECASE)
        else
          Regexp.new(pattern)
        end

        results = []
        scanned = 0
        truncated = false

        catch(:done) do
          each_file(base, glob) do |path|
            scanned += 1
            if scanned > MAX_FILES_SCANNED
              truncated = true
              throw :done
            end
            next if binary?(path)

            begin
              File.foreach(path).with_index(1) do |line, number|
                next unless line.match?(regex)

                results << "#{display_path(path, base)}:#{number}: #{clip(line)}"
                throw :done if results.size >= max
              end
            rescue SystemCallError, IOError
              next
            end
          end
        end

        return "No matches for #{pattern.inspect} under #{base}" if results.empty?

        footer = []
        footer << "showing the first #{results.size}" if results.size >= max
        footer << "stopped after #{scanned} files" if truncated
        text = results.join("\n")
        footer.empty? ? text : "#{text}\n... (#{footer.join('; ')})"
      end

      def find_files(base, pattern, max)
        path_glob = pattern.include?("/") ? pattern : "**/#{pattern}"
        matches = Dir.glob(File.join(base, path_glob)).reject do |path|
          File.directory?(path) || skipped?(path, base)
        end

        if matches.empty?
          return "No files matching #{pattern.inspect} under #{base}"
        end

        total = matches.size
        matches = matches.sort
        shown = matches.first(max).map { |path| display_path(path, base) }
        return shown.join("\n") if total <= max

        "#{shown.join("\n")}\n... (showing #{shown.size} of #{total} matches)"
      end

      def each_file(base, glob)
        pattern = glob.empty? ? "**/*" : glob
        pattern = "**/#{pattern}" unless pattern.include?("/") || pattern.start_with?("**")
        Dir.glob(File.join(base, pattern)).each do |path|
          next if File.directory?(path)
          next if skipped?(path, base)

          yield path
        end
      end

      def skipped?(path, base)
        relative = path.delete_prefix("#{base}/")
        return true if relative.start_with?(".")

        SKIP_DIRS.any? do |dir|
          relative == dir || relative.start_with?("#{dir}/") || relative.include?("/#{dir}/")
        end
      end

      def display_path(path, base)
        path.delete_prefix("#{base}/")
      end

      def clip(line)
        text = line.strip
        text.length > MAX_LINE_CHARS ? "#{text[0...MAX_LINE_CHARS]}..." : text
      end

      def binary?(path)
        size = File.size(path)
        return true if size > MAX_FILE_BYTES

        File.open(path, "rb") { |f| f.read(8_192).to_s.include?("\0") }
      rescue SystemCallError, IOError
        true
      end
    end
  end
end
