# frozen_string_literal: true

require "fileutils"

module Rubot
  # Discovers and manages all skills in the workspace skills directory.
  #
  # Skills are stored in:
  #   ~/.rubot/workspace/skills/{skill-name}/SKILL.md
  #
  # Each skill directory must contain a SKILL.md file.
  # The directory name becomes the skill name.
  class SkillRegistry
    SKILLS_DIR_NAME = "skills"

    attr_reader :workspace

    def initialize(workspace: nil)
      @workspace = workspace
      @skills = {}
      load!
    end

    # Returns a hash of skill_name => Skill
    def all
      @skills
    end

    # Get a specific skill by name
    def get(name)
      @skills[name]
    end

    # Returns the number of loaded skills
    def count
      @skills.size
    end

    # Returns true if any skills are configured
    def any?
      !@skills.empty?
    end

    # Returns skills directory path
    def skills_dir
      @workspace ? File.join(@workspace, SKILLS_DIR_NAME) : nil
    end

    # Re-scan the skills directory and refresh the loaded skills.
    def reload!
      @skills = {}
      load!
    end

    # Generate the <available_skills> XML block for the system prompt
    def to_system_prompt
      return "" if @skills.empty?

      lines = []
      lines << "The following skills provide specialized instructions for specific tasks."
      lines << "Use the file tool to load a skill's file when the task matches its description."
      lines << "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands."
      lines << ""
      lines << "<available_skills>"
      @skills.each_value do |skill|
        lines << "  <skill>"
        lines << "    <name>#{skill.name}</name>"
        lines << "    <description>#{skill.summary}</description>"
        lines << "    <location>#{skill.file_path}</location>"
        lines << "  </skill>"
      end
      lines << "</available_skills>"
      lines.join("\n")
    end

    # Install a skill by copying its SKILL.md content to a new skill directory
    def install(name, content)
      skill_dir = skills_dir
      return false unless skill_dir

      dir = File.join(skill_dir, name)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), content)
      @skills[name] = Skill.new(directory: dir)
      true
    end

    # Uninstall a skill by removing its directory
    def uninstall(name)
      skill_dir = skills_dir
      return false unless skill_dir

      dir = File.join(skill_dir, name)
      return false unless Dir.exist?(dir)

      FileUtils.rm_rf(dir)
      @skills.delete(name)
      true
    end

    private

    def load!
      return unless @workspace

      dir = skills_dir
      return unless dir && Dir.exist?(dir)

      Dir.entries(dir).each do |entry|
        next if entry.start_with?(".")
        skill_path = File.join(dir, entry)
        next unless Dir.exist?(skill_path)

        skill = Skill.new(directory: skill_path)
        @skills[skill.name] = skill if skill.enabled?
      end
    end
  end
end
