# frozen_string_literal: true

require "yaml"

module Rubot
  # Represents a single skill — a specialized instruction set stored as SKILL.md
  # in a subdirectory of the workspace skills directory.
  #
  # Skills provide of the system prompt with domain-specific instructions.
  # They are matched to user messages based on their description.
  #
  # Directory layout:
  #   ~/.rubot/workspace/skills/{skill-name}/SKILL.md
  class Skill
    attr_reader :name, :description, :content, :directory, :file_path

    def initialize(directory:)
      @directory = directory
      @name = File.basename(directory)
      @file_path = File.join(directory, "SKILL.md")
      @description = ""
      @content = ""
      load!
    end

    # Returns true if the skill file exists and is readable
    def enabled?
      !@content.nil? && !@content.empty?
    end

    # Returns the full skill content for injection into the system prompt
    def to_s
      @content || ""
    end

    # Returns a short summary for the <available_skills> listing
    def summary
      @description || @name
    end

    private

    def load!
      return unless File.exist?(@file_path)
      raw = File.read(@file_path)
      @content = raw
      @description = extract_description(raw)
    rescue Errno::ENOENT, Errno::EACCES
      @content = nil
    end

    def extract_description(raw)
      # Extract description from YAML frontmatter
      if raw.start_with?("---\n") || raw.start_with?("---\r\n")
        parts = raw.lines
        end_index = parts[1..].index { |l| l.strip == "---" }
        if end_index
          yaml_content = parts[1..end_index].join
          frontmatter = parse_yaml_safely(yaml_content)
          return frontmatter["description"] if frontmatter && frontmatter["description"] && !frontmatter["description"].to_s.empty?
        end
      end

      # Fallback: extract from first paragraph after frontmatter (or from start)
      body = raw.dup
      if body.start_with?("---")
        # Skip frontmatter
        parts = body.lines
        end_index = parts[1..].index { |l| l.strip == "---" }
        body = parts[(end_index.to_i + 2)..].join if end_index
      end

      # Extract description from first non-heading line
      body.each_line do |line|
        stripped = line.strip
        next if stripped.empty?
        next if stripped.start_with?("#")
        return stripped
      end

      @name
    end

    # Parse YAML frontmatter safely, returning nil on any error
    def parse_yaml_safely(yaml_content)
      YAML.safe_load(yaml_content, permitted_classes: [ Symbol ])
    rescue Psych::SyntaxError
      nil
    rescue StandardError
      nil
    end
  end
end
