# frozen_string_literal: true

require "fileutils"
require "set"
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

    # Every line of MEMORY.md is paid for on every request, so each section is
    # capped. Entries pushed past the cap are moved to MEMORY_ARCHIVE.md, which
    # is never injected into a prompt.
    SECTION_LIMITS = {
      "Facts" => 25,
      "Preferences" => 15,
      "Context" => 10,
      "Learned Corrections" => 10
    }.freeze

    ARCHIVE_FILE = "MEMORY_ARCHIVE.md"

    # The archive of a memory file: MEMORY.md -> MEMORY_ARCHIVE.md, and
    # <slug>.md -> <slug>_ARCHIVE.md so that the per-workspace memory files
    # sharing one directory do not append into the same archive.
    def self.archive_path_for(file_path)
      base = File.basename(file_path.to_s, ".md")
      name = base.casecmp?("MEMORY") ? ARCHIVE_FILE : "#{base}_ARCHIVE.md"
      File.join(File.dirname(file_path.to_s), name)
    end

    # Words that carry no meaning when comparing two bullets. Indonesian
    # function words are included because memory mixes both languages.
    COMPARE_STOPWORDS = %w[
      a an the user users is are was were be been being to of in on for and or
      with that this it its as at by from has have had does do not no
      yang dan di ke dari untuk dengan ini itu adalah tidak
      bahasa
    ].to_set.freeze

    # Words that mean the same thing for deduplication purposes.
    TOKEN_ALIASES = {
      "indonesian" => "indonesia",
      "prefers" => "prefer",
      "preference" => "prefer",
      "preferences" => "prefer",
      "likes" => "prefer"
    }.freeze

    # Two bullets are considered the same when their meaningful words overlap
    # this much, or when one's words are entirely contained in the other
    # ("User is a content creator" vs the same sentence with more detail).
    SIMILARITY_THRESHOLD = 0.8

    # Words that turn a "correction" into a retry request ("coba lagi med").
    # Such entries teach the model nothing and used to fill the log.
    RETRY_WORDS = %w[coba try lagi again dong med met please tolong gw gue ya deh].to_set.freeze

    DEFAULT_MEMORY = <<~MEMORY.freeze
      # Memory

      _This file is automatically managed by Rubot. The bot reads and updates
      this file to remember important information across sessions._

      ## Facts

      ## Preferences

      ## Context

      ## Learned Corrections
    MEMORY

    # Either `workspace:` (the file is <workspace>/MEMORY.md, the historical
    # layout) or `path:` (an explicit file, which is how the global memory
    # and the per-workspace memory of MemoryBank are addressed).
    #
    # `create: false` leaves a missing file alone instead of creating it with
    # the default template, so merely visiting a directory does not litter the
    # memory directory with empty files.
    def initialize(workspace: nil, path: nil, create: true)
      @workspace = workspace
      @file_path = path || (workspace ? File.join(workspace, "MEMORY.md") : nil)
      @create = create
      @content = load_content
    end

    def exists?
      !@file_path.nil? && File.exist?(@file_path)
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

    # Append a line to a section (e.g., "## Facts").
    #
    # `max_items` caps the section: the oldest entries beyond it are dropped
    # (and archived when a workspace is available). Callers that write a
    # bounded log — the feedback learner, for example — should set it.
    # `scope` is accepted so a single-file Memory and a MemoryBank can be used
    # interchangeably by the memory tool, extractor and feedback learner; one
    # file has exactly one layer, so there is nothing to choose between.
    def append(section, line, max_items: nil, scope: nil)
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

        dropped = max_items ? trim_section(@content, section, max_items) : []
        write_locked(file, @content)
        archive_lines(dropped) unless dropped.empty?
      end
    end

    # Update or create a section with new content (full replace of section)
    def update_section(section, content_lines, scope: nil)
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

    # Merge near-duplicate entries, cap every section, and move whatever falls
    # off the end into MEMORY_ARCHIVE.md. This is what keeps the per-request
    # memory cost from growing forever: the extractor is additive, so without
    # it every rephrased fact would be paid for on every single request.
    #
    # Returns { removed:, size: } or nil when nothing changed.
    def consolidate!(limits: SECTION_LIMITS)
      return nil unless @file_path
      # A layer that has never been written to has nothing to consolidate, and
      # consolidating it would create the file as a side effect.
      return nil if !@create && !exists?

      with_file_lock do |file|
        @content ||= load_content
        return nil unless @content

        new_content, dropped = consolidate_content(@content, limits)
        return nil if new_content == @content

        @content = new_content
        write_locked(file, @content)
        archive_lines(dropped) unless dropped.empty?
        { removed: dropped.size, size: @content.bytesize }
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
        # A write against a file that does not exist yet (or is empty) starts
        # from the default template, so a fresh memory file keeps its sections.
        @content = DEFAULT_MEMORY if @content.empty?
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
      elsif @create
        # Create default memory file
        FileUtils.mkdir_p(File.dirname(@file_path))
        File.write(@file_path, DEFAULT_MEMORY)
        DEFAULT_MEMORY
      end
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    # Drop the oldest bullets of a section until it holds at most `limit`.
    # Returns the dropped lines so the caller can archive them.
    def trim_section(content, section, limit)
      lines = content.lines
      header = "## #{section}"
      header_index = lines.index { |l| l.strip == header }
      return [] unless header_index

      next_section = lines[(header_index + 1)..].index { |l| l.start_with?("##") }
      end_index = next_section ? (header_index + 1 + next_section) : lines.length
      bullet_indexes = (header_index + 1...end_index).select { |i| lines[i].start_with?("- ") }

      overflow = bullet_indexes.size - limit.to_i
      return [] unless overflow.positive?

      dropped_indexes = bullet_indexes.first(overflow)
      dropped = dropped_indexes.map { |i| lines[i].sub(/\A- /, "").strip }
      dropped_indexes.reverse_each { |i| lines.delete_at(i) }
      content.replace(lines.join)
      dropped
    end

    # Rewrite content with duplicates merged and sections capped.
    def consolidate_content(content, limits)
      lines = content.lines
      output = []
      dropped = []
      index = 0

      # Preamble (title and description) is kept verbatim.
      while index < lines.length && !lines[index].start_with?("## ")
        output << lines[index]
        index += 1
      end

      while index < lines.length
        header = lines[index]
        section = header.sub(/\A##\s+/, "").strip
        index += 1

        body = []
        while index < lines.length && !lines[index].start_with?("## ")
          body << lines[index]
          index += 1
        end

        bullets = body.select { |l| l.start_with?("- ") }.map { |l| l.sub(/\A- /, "").rstrip }
        others = body.reject { |l| l.start_with?("- ") || l.strip.empty? }

        # Clean up retry-only corrections written before the learner stopped
        # storing them. Anything with real content is kept.
        if section == "Learned Corrections"
          junk, bullets = bullets.partition { |b| junk_correction?(b) }
          dropped.concat(junk.map { |b| [ section, b ] })
        end

        kept, overflow = dedupe_bullets(bullets, limits[section])

        output << header
        others.each { |l| output << l }
        kept.each { |b| output << "- #{b}\n" }
        output << "\n"
        dropped.concat(overflow.map { |b| [ section, b ] })
      end

      # Collapse the blank line left before the end of the file.
      output.pop while output.size > 1 && output[-1].strip.empty? && output[-2].to_s.strip.empty?

      [ output.join, dropped ]
    end

    # Merge bullets that say the same thing, then keep the newest `limit`.
    # Returns [kept_bullets, dropped_bullets].
    def dedupe_bullets(bullets, limit)
      kept = []
      kept_tokens = []

      bullets.each do |bullet|
        tokens = compare_tokens(bullet)
        existing = kept_tokens.index { |other| similar?(tokens, other) }

        if existing
          # Keep the more informative wording, at the original position.
          if bullet.length > kept[existing].length
            kept[existing] = bullet
            kept_tokens[existing] = tokens
          end
        else
          kept << bullet
          kept_tokens << tokens
        end
      end

      dropped = []
      if limit && kept.size > limit
        dropped = kept.shift(kept.size - limit)
      end

      [ kept, dropped ]
    end

    # True when a stored correction only asked for a retry.
    def junk_correction?(line)
      feedback = line[/User feedback:\s*'(.*)'\s*\z/m, 1]
      return false unless feedback

      words = feedback.downcase.gsub(/[^a-z\s]/, " ").split
      return false if words.empty?

      words.all? { |w| RETRY_WORDS.include?(w) }
    end

    def compare_tokens(text)
      text.to_s.downcase
          .gsub(/[^a-z0-9\s]/, " ")
          .split
          .reject { |t| (t.length < 2 && !t.match?(/\d/)) || COMPARE_STOPWORDS.include?(t) }
          .map { |t| TOKEN_ALIASES.fetch(t, t) }
          .uniq
    end

    def similar?(a, b)
      return false if a.empty? || b.empty?

      shared = (a & b).size
      return false if shared < 2

      return true if (a - b).empty? || (b - a).empty?

      shared.to_f / (a | b).size >= SIMILARITY_THRESHOLD
    end

    # Append removed entries to MEMORY_ARCHIVE.md. That file is deliberately
    # not read into any prompt; it only exists so consolidation never loses
    # information outright.
    def archive_lines(entries)
      return if entries.nil? || entries.empty? || !@file_path

      path = self.class.archive_path_for(@file_path)
      FileUtils.mkdir_p(File.dirname(path))
      stamp = Time.now.strftime("%Y-%m-%d")

      File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o644) do |file|
        file.flock(File::LOCK_EX)
        file.write("# Memory Archive\n\n") if file.size.zero?
        entries.each do |section, line|
          file.write("- #{stamp} (#{section}) #{line.strip}\n")
        end
        file.flush
        file.flock(File::LOCK_UN)
      end
    rescue StandardError => e
      warn "[memory] Failed to archive entries: #{e.class}: #{e.message}" if Rubot.debug?
    end

    def save!
      return unless @file_path && @content
      with_file_lock { |file| write_locked(file, @content) }
    end
  end
end
