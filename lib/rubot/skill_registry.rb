# frozen_string_literal: true

require "fileutils"

module Rubot
  # Discovers and manages all skills a workspace can draw on.
  #
  # Skills live in:
  #   ~/.rubot/skills/{skill-name}/SKILL.md
  #
  # That directory is shared by every persona and every project (see
  # Config#skills_workspace). A workspace's own `skills/` is still read as a
  # fallback through `extra_workspaces:`, so an install that predates the move
  # keeps working without being rewritten.
  #
  # Each skill directory must contain a SKILL.md file.
  # The directory name becomes the skill name.
  class SkillRegistry
    SKILLS_DIR_NAME = "skills"

    attr_reader :workspace, :extra_workspaces

    # `workspace` is read first and is where install/uninstall write; the
    # extra workspaces only fill in names the first one does not have.
    def initialize(workspace: nil, extra_workspaces: [])
      @workspace = workspace
      @extra_workspaces = Array(extra_workspaces).compact.uniq
      @skills = {}
      load!
    end

    # Returns a hash of skill_name => Skill
    def all
      @skills
    end

    # Every skill name, in the order the directories were read.
    def names
      @skills.keys
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

    # Generate the <available_skills> XML block for the system prompt.
    #
    # `only` narrows the list to the skills a persona has left enabled (see
    # Persona#disabled_skills). nil means every skill; an empty list means
    # none, which is how a persona that switched them all off gets a prompt
    # with no skills section at all.
    def to_system_prompt(only: nil)
      skills = select_skills(only: only)
      return "" if skills.empty?

      lines = []
      lines << "The following skills provide specialized instructions for specific tasks."
      lines << "Use `file_read` to load a skill's file when the task matches its description."
      lines << "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands."
      lines << ""
      lines << "<available_skills>"
      skills.each do |skill|
        lines << "  <skill>"
        lines << "    <name>#{skill.name}</name>"
        lines << "    <description>#{skill.summary}</description>"
        lines << "    <location>#{skill.file_path}</location>"
        lines << "  </skill>"
      end
      lines << "</available_skills>"
      lines.join("\n")
    end

    # The loaded skills, narrowed to `only` when a filter is given.
    def select_skills(only: nil)
      return @skills.values if only.nil?

      wanted = Array(only).map(&:to_s)
      @skills.values.select { |skill| wanted.include?(skill.name) }
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

    # Uninstall a skill by removing its directory. Found in whichever
    # directory it was loaded from: the shared store, or the workspace
    # fallback an older install left behind.
    def uninstall(name)
      dir = skill_dirs.map { |root| File.join(root, name) }.find { |path| Dir.exist?(path) }
      return false unless dir

      FileUtils.rm_rf(dir)
      @skills.delete(name)
      true
    end

    private

    # The skills/ directories to read, most important first. The first one is
    # where new skills are installed; the rest are fallbacks, and a name found
    # in an earlier directory wins.
    def skill_dirs
      roots = [ @workspace, *@extra_workspaces ].compact.uniq
      roots.map { |root| File.join(root, SKILLS_DIR_NAME) }.select { |dir| Dir.exist?(dir) }
    end

    def load!
      skill_dirs.each do |dir|
        Dir.entries(dir).sort.each do |entry|
          next if entry.start_with?(".")
          next if @skills.key?(entry)

          skill_path = File.join(dir, entry)
          next unless Dir.exist?(skill_path)

          skill = Skill.new(directory: skill_path)
          @skills[skill.name] = skill if skill.enabled?
        end
      end
    end
  end
end
