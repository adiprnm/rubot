# frozen_string_literal: true

require_relative "test_helper"

class TestSoul < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_no_workspace
    soul = Rubot::Soul.new(workspace: nil)
    refute soul.enabled?
    assert_nil soul.to_s
  end

  def test_workspace_without_file
    soul = Rubot::Soul.new(workspace: @tmpdir)
    refute soul.enabled?
  end

  def test_loads_soul_file
    File.write(File.join(@tmpdir, "SOUL.md"), "# Soul\n\nI am helpful.")
    soul = Rubot::Soul.new(workspace: @tmpdir)
    assert soul.enabled?
    assert_includes soul.to_s, "I am helpful."
  end

  def test_write_soul
    soul = Rubot::Soul.new(workspace: @tmpdir)
    soul.write("# My Soul\n\nI am creative.")
    assert File.exist?(File.join(@tmpdir, "SOUL.md"))
    assert_includes File.read(File.join(@tmpdir, "SOUL.md")), "I am creative."
  end
end

class TestAgentsFile < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_no_workspace
    af = Rubot::AgentsFile.new(workspace: nil)
    refute af.enabled?
  end

  def test_workspace_without_file
    af = Rubot::AgentsFile.new(workspace: @tmpdir)
    refute af.enabled?
  end

  def test_parses_frontmatter_and_body
    File.write(File.join(@tmpdir, "AGENTS.md"), <<~MD)
      ---
      name: TestBot
      model: gpt-4
      max_tokens: 2048
      temperature: 0.5
      tools:
        exec: false
      ---

      # Rules
      - Be nice
      - Be fast
    MD

    af = Rubot::AgentsFile.new(workspace: @tmpdir)
    assert af.enabled?
    assert_equal "TestBot", af.name
    assert_equal "gpt-4", af.model
    assert_equal 2048, af.max_tokens
    assert_equal 0.5, af.temperature
    assert_equal({ "exec" => false }, af.tools_config)
    assert_includes af.rules, "Be nice"
    assert_includes af.rules, "Be fast"
  end

  def test_body_only_without_frontmatter
    File.write(File.join(@tmpdir, "AGENTS.md"), "# Just rules\n- Rule 1")
    af = Rubot::AgentsFile.new(workspace: @tmpdir)
    assert af.enabled?
    refute af.name
    assert_includes af.rules, "Rule 1"
  end
end

class TestMemory < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_creates_default_memory
    mem = Rubot::Memory.new(workspace: @tmpdir)
    assert mem.enabled?
    assert_includes mem.read, "## Facts"
    assert_includes mem.read, "## Preferences"
    assert_includes mem.read, "## Context"
  end

  def test_append_to_section
    mem = Rubot::Memory.new(workspace: @tmpdir)
    mem.append("Facts", "User likes Ruby")
    mem.append("Facts", "User works in Jakarta")
    content = mem.read
    assert_includes content, "- User likes Ruby"
    assert_includes content, "- User works in Jakarta"
  end

  def test_update_section
    mem = Rubot::Memory.new(workspace: @tmpdir)
    mem.append("Facts", "old fact")
    mem.update_section("Facts", [ "new fact 1", "new fact 2" ])
    content = mem.read
    refute_includes content, "old fact"
    assert_includes content, "- new fact 1"
    assert_includes content, "- new fact 2"
    # Facts section should only have the new items
    facts_section = content.split("## Facts").last.split("##").first
    assert_includes facts_section, "- new fact 1"
    assert_includes facts_section, "- new fact 2"
    refute_includes facts_section, "old fact"
  end

  def test_write_full_replacement
    mem = Rubot::Memory.new(workspace: @tmpdir)
    mem.write("# Custom Memory\n\nNothing here.")
    assert_equal "# Custom Memory\n\nNothing here.", mem.read
  end

  def test_persistence
    mem1 = Rubot::Memory.new(workspace: @tmpdir)
    mem1.append("Facts", "Persistent fact")

    mem2 = Rubot::Memory.new(workspace: @tmpdir)
    assert_includes mem2.read, "Persistent fact"
  end

  def test_no_workspace
    mem = Rubot::Memory.new(workspace: nil)
    refute mem.enabled?
    assert_equal "", mem.read
  end
end
