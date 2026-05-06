# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

module Rubot
  class TestSkill < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_skill_loads_from_file
      skills_dir = File.join(@tmpdir, "skills", "test-skill")
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, "SKILL.md"), <<~SKILL)
        ---
        name: test-skill
        description: A test skill for testing
        ---

        # Test Skill

        This is a test skill.
      SKILL

      skill = Skill.new(directory: skills_dir)
      assert_equal "test-skill", skill.name
      assert_includes skill.to_s, "# Test Skill"
      assert_equal "A test skill for testing", skill.summary
      assert skill.enabled?
    end

    def test_skill_loads_without_frontmatter
      skills_dir = File.join(@tmpdir, "skills", "no-frontmatter")
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, "SKILL.md"), <<~SKILL)
        # No Frontmatter Skill

        This skill has no YAML frontmatter.
      SKILL

      skill = Skill.new(directory: skills_dir)
      assert_equal "no-frontmatter", skill.name
      assert skill.enabled?
    end

    def test_skill_returns_nil_when_file_missing
      skills_dir = File.join(@tmpdir, "skills", "missing")
      FileUtils.mkdir_p(skills_dir)

      skill = Skill.new(directory: skills_dir)
      refute skill.enabled?
      assert_equal "", skill.to_s
    end

    def test_skill_description_falls_back_to_first_text_line
      skills_dir = File.join(@tmpdir, "skills", "fallback-desc")
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, "SKILL.md"), <<~SKILL)
        ---
        name: fallback-desc
        ---

        This is the first text line used as description.
      SKILL

      skill = Skill.new(directory: skills_dir)
      assert_equal "This is the first text line used as description.", skill.summary
    end

    def test_skill_description_falls_back_to_name
      skills_dir = File.join(@tmpdir, "skills", "empty-skill")
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, "SKILL.md"), "")

      skill = Skill.new(directory: skills_dir)
      refute skill.enabled?
    end
  end

  class TestSkillRegistry < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_empty_when_no_skills_dir
      registry = SkillRegistry.new(workspace: @tmpdir)
      refute registry.any?
      assert_equal 0, registry.count
    end

    def test_empty_when_no_workspace
      registry = SkillRegistry.new(workspace: nil)
      refute registry.any?
      assert_equal 0, registry.count
    end

    def test_loads_single_skill
      skills_dir = File.join(@tmpdir, "skills", "my-skill")
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, "SKILL.md"), <<~SKILL)
        ---
        name: my-skill
        description: Does something useful
        ---

        # My Skill

        Instructions here.
      SKILL

      registry = SkillRegistry.new(workspace: @tmpdir)
      assert registry.any?
      assert_equal 1, registry.count
      assert_kind_of Skill, registry.get("my-skill")
    end

    def test_loads_multiple_skills
      [ "skill-a", "skill-b", "skill-c" ].each do |name|
        dir = File.join(@tmpdir, "skills", name)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "SKILL.md"), "# #{name}\n\nContent for #{name}.")
      end

      registry = SkillRegistry.new(workspace: @tmpdir)
      assert_equal 3, registry.count
      assert registry.get("skill-a")
      assert registry.get("skill-b")
      assert registry.get("skill-c")
    end

    def test_ignores_hidden_directories
      dir = File.join(@tmpdir, "skills", ".hidden")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "# Hidden")

      dir = File.join(@tmpdir, "skills", "visible")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "# Visible")

      registry = SkillRegistry.new(workspace: @tmpdir)
      assert_equal 1, registry.count
      assert registry.get("visible")
      refute registry.get(".hidden")
    end

    def test_to_system_prompt
      dir = File.join(@tmpdir, "skills", "code-reviewer")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), <<~SKILL)
        ---
        name: code-reviewer
        description: Review code for quality and best practices
        ---

        # Code Reviewer
      SKILL

      registry = SkillRegistry.new(workspace: @tmpdir)
      prompt = registry.to_system_prompt

      assert_includes prompt, "<available_skills>"
      assert_includes prompt, "</available_skills>"
      assert_includes prompt, "<name>code-reviewer</name>"
      assert_includes prompt, "<description>Review code for quality and best practices</description>"
      assert_includes prompt, "<location>#{File.join(@tmpdir, "skills", "code-reviewer", "SKILL.md")}</location>"
    end

    def test_to_system_prompt_empty_when_no_skills
      registry = SkillRegistry.new(workspace: @tmpdir)
      assert_equal "", registry.to_system_prompt
    end

    def test_install_skill
      registry = SkillRegistry.new(workspace: @tmpdir)
      result = registry.install("new-skill", "# New Skill\n\nInstructions.")

      assert result
      assert registry.get("new-skill")
      assert File.exist?(File.join(@tmpdir, "skills", "new-skill", "SKILL.md"))
    end

    def test_uninstall_skill
      dir = File.join(@tmpdir, "skills", "remove-me")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "# Remove Me")

      registry = SkillRegistry.new(workspace: @tmpdir)
      assert registry.get("remove-me")

      result = registry.uninstall("remove-me")
      assert result
      refute registry.get("remove-me")
      refute Dir.exist?(dir)
    end

    def test_uninstall_nonexistent_skill
      registry = SkillRegistry.new(workspace: @tmpdir)
      refute registry.uninstall("does-not-exist")
    end

    def test_skills_dir_returns_correct_path
      registry = SkillRegistry.new(workspace: "/some/workspace")
      assert_equal "/some/workspace/skills", registry.skills_dir
    end

    def test_skills_dir_returns_nil_without_workspace
      registry = SkillRegistry.new(workspace: nil)
      assert_nil registry.skills_dir
    end
  end
end
