# frozen_string_literal: true

require "fileutils"
require "time"

module Rubot
  # Manages MEMORY.md — persistent memory that survives across sessions.
  # The bot can read and update this file via the memory tool.
  #
  # Format:
  #   # Memory
  #
  #   ## Facts
  #   - User prefers Python over JavaScript
  #   - Project uses Ruby 3.0+
  #
  #   ## Preferences
  #   - Concise responses preferred
  #   - No emojis in code
  #
  #   ## Context
  #   - Working on rubot project
  #   - Last discussion: tool registry refactoring
  class Memory
    attr_reader :file_path, :content

    DEFAULT_MEMORY = <<~MEMORY.freeze
      # Memory

      _This file is automatically managed by Rubot. The bot reads and updates
      this file to remember important information across sessions._

      ## Facts

      ## Preferences

      ## Context

      ## Learned Corrections
    MEMORY

    def initialize(workspace: nil)
      @workspace = workspace
      @file_path = workspace ? File.join(workspace, "MEMORY.md") : nil
      @content = load_content
    end

    # Returns the memory content for injection into system prompt
    def to_s
      @content || ""
    end

    def enabled?
      !@content.nil? && !@content.empty?
    end

    # Read the current memory
    def read
      @content || ""
    end

    # Write new memory content (full replace)
    def write(content)
      return unless @file_path
      with_file_lock do |file|
        @content = content
        write_locked(file, @content)
      end
    end

    # Append a line to a section (e.g., "## Facts")
    def append(section, line)
      with_file_lock do |file|
        @content ||= load_content
        return unless @content
        section_header = "## #{section}"

        if @content.include?(section_header)
          # Find the section and append
          lines = @content.lines
          section_index = lines.index { |l| l.strip == section_header }
          if section_index
            # Find the end of the section (next ## or end of file)
            next_section = lines[(section_index + 1)..].index { |l| l.start_with?("##") }
            insert_at = next_section ? (section_index + 1 + next_section) : lines.length

            # Remove trailing blank lines in the section before inserting
            while insert_at > section_index + 1 && lines[insert_at - 1].strip.empty?
              insert_at -= 1
            end

            lines.insert(insert_at, "- #{line}\n")
            @content = lines.join
          end
        else
          # Create the section
          @content += "\n## #{section}\n- #{line}\n"
        end

        write_locked(file, @content)
      end
    end

    # Update or create a section with new content (full replace of section)
    def update_section(section, content_lines)
      with_file_lock do |file|
        @content ||= load_content
        return unless @content
        section_header = "## #{section}"
        lines = @content.lines

        if @content.include?(section_header)
          section_index = lines.index { |l| l.strip == section_header }
          if section_index
            # Find the end of the section
            next_section = lines[(section_index + 1)..].index { |l| l.start_with?("##") }
            end_index = next_section ? (section_index + 1 + next_section) : lines.length

            # Replace the section content
            new_section_lines = content_lines.map { |l| l.start_with?("-") ? l : "- #{l}" }
            lines[section_index + 1...end_index] = new_section_lines.map { |l| "#{l}\n" }
            @content = lines.join
          end
        else
          @content += "\n## #{section}\n"
          content_lines.each { |l| @content += "- #{l}\n" }
        end

        write_locked(file, @content)
      end
    end

    private

    # Serialize memory mutations with an exclusive file lock so that
    # multiple session Ractors cannot corrupt MEMORY.md or lose updates.
    def with_file_lock
      return yield(nil) unless @file_path

      FileUtils.mkdir_p(File.dirname(@file_path))
      File.open(@file_path, File::RDWR | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX)
        @content = file.read
        begin
          yield file
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end

    def write_locked(file, content)
      return unless content
      if file
        file.rewind
        file.truncate(0)
        file.write(content)
        file.flush
      else
        FileUtils.mkdir_p(File.dirname(@file_path))
        File.write(@file_path, content)
      end
    end

    def load_content
      return nil unless @file_path

      if File.exist?(@file_path)
        File.read(@file_path)
      else
        # Create default memory file
        FileUtils.mkdir_p(File.dirname(@file_path))
        File.write(@file_path, DEFAULT_MEMORY)
        DEFAULT_MEMORY
      end
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def save!
      return unless @file_path && @content
      with_file_lock { |file| write_locked(file, @content) }
    end
  end
end
