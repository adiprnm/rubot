# frozen_string_literal: true

module Rubot
  # Lightweight .env file loader (zero runtime dependencies).
  #
  # Parses standard .env files and populates ENV.
  # Supports:
  #   - KEY=VALUE
  #   - KEY="VALUE" (double-quoted, with \n, \t, \\, \" escapes)
  #   - KEY='VALUE' (single-quoted, literal — no escapes)
  #   - # and inline comments
  #   - export KEY=VALUE
  #   - blank lines
  module EnvLoader
    class Error < StandardError; end
    class ParseError < Error; end

    DEFAULT_ENV_FILES = %w[
      .env
      .env.local
      .env.#{defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby"}
    ].freeze

    class << self
      # Load environment variables from a file into ENV.
      #
      # @param path [String, nil] Explicit file path. If nil, searches
      #   the current directory then the user's config dir (~/.rubot).
      # @param overwrite [Boolean] Whether to overwrite existing ENV vars.
      # @return [String] The path of the loaded file, or nil if none found.
      def load(path = nil, overwrite: false)
        if path
          raise Error, "env file not found: #{path}" unless File.exist?(path)
          parse_file(path, overwrite: overwrite)
          return path
        end

        # Search common locations
        search_paths = [
          *DEFAULT_ENV_FILES,
          *DEFAULT_ENV_FILES.map { |f| File.join(File.expand_path("~/.rubot"), f) }
        ]

        search_paths.each do |p|
          next unless File.exist?(p)
          parse_file(p, overwrite: overwrite)
          return p
        end

        nil
      end

      # Parse a string of env content and merge into ENV.
      def parse(content, overwrite: false)
        parse_lines(content.lines, overwrite: overwrite)
      end

      private

      def parse_file(path, overwrite:)
        content = File.read(path)
        parse_lines(content.lines, overwrite: overwrite)
      rescue Errno::ENOENT
        raise Error, "env file not found: #{path}"
      rescue Errno::EACCES
        raise Error, "permission denied: #{path}"
      end

      def parse_lines(lines, overwrite:)
        lines.each_with_index do |line, idx|
          num = idx + 1
          stripped = line.strip

          # Skip blank lines and full-line comments
          next if stripped.empty? || stripped.start_with?("#")

          # Strip inline comments (only for unquoted values)
          stripped = strip_inline_comment(stripped)

          # Handle `export` prefix
          stripped = stripped.sub(/\Aexport\s+/, "")

          key, value = parse_assignment(stripped, num)
          next if key.nil?

          if overwrite || !ENV.key?(key)
            ENV[key] = value
          end
        end
      end

      def parse_assignment(line, line_num)
        eq_index = line.index("=")
        return [ nil, nil ] unless eq_index

        key = line[0...eq_index].strip
        raw_value = line[(eq_index + 1)..].strip

        raise ParseError, "line #{line_num}: invalid key '#{key}'" unless valid_key?(key)

        value = if raw_value.start_with?('"')
                  parse_double_quoted(raw_value, line_num)
        elsif raw_value.start_with?("'")
                  parse_single_quoted(raw_value, line_num)
        else
                  raw_value
        end

        [ key, value ]
      end

      def parse_double_quoted(raw, line_num)
        # Find the matching closing quote (handle escaped quotes)
        content = raw[1..] # skip opening "
        result = +""
        i = 0
        while i < content.length
          ch = content[i]
          if ch == "\\" && i + 1 < content.length
            next_ch = content[i + 1]
            case next_ch
            when "n" then result << "\n"; i += 2
            when "t" then result << "\t"; i += 2
            when "r" then result << "\r"; i += 2
            when "\\" then result << "\\"; i += 2
            when '"' then result << '"'; i += 2
            else result << ch << next_ch; i += 2
            end
          elsif ch == '"'
            return result
          else
            result << ch
            i += 1
          end
        end
        raise ParseError, "line #{line_num}: unterminated double-quoted string"
      end

      def parse_single_quoted(raw, line_num)
        end_idx = raw.index("'", 1)
        raise ParseError, "line #{line_num}: unterminated single-quoted string" unless end_idx
        raw[1...(end_idx)]
      end

      def strip_inline_comment(line)
        in_single = false
        in_double = false
        escaped = false

        line.chars.each_with_index do |ch, i|
          if escaped
            escaped = false
            next
          end

          case ch
          when "\\"
            escaped = true if in_double
          when "'"
            in_single = !in_single unless in_double
          when '"'
            in_double = !in_double unless in_single
          when "#"
            return line[0...i].rstrip unless in_single || in_double
          end
        end

        line
      end

      def valid_key?(key)
        !key.empty? && key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      end
    end
  end
end
