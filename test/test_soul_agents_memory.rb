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
      max_rounds: 12
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
    assert_equal 12, af.max_rounds
    assert_equal({ "exec" => false }, af.tools_config)
    assert_includes af.rules, "Be nice"
    assert_includes af.rules, "Be fast"
  end

  def test_old_max_tool_iterations_frontmatter_is_still_accepted
    File.write(File.join(@tmpdir, "AGENTS.md"), <<~MD)
      ---
      max_tool_iterations: 9
      ---

      # Rules
    MD

    af = Rubot::AgentsFile.new(workspace: @tmpdir)
    assert_equal 9, af.max_rounds
    assert_equal 9, af.max_tool_iterations
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

  def test_memory_file_write_still_works_internally
    # Memory.write is used internally for initial creation and save!
    mem = Rubot::Memory.new(workspace: @tmpdir)
    mem.write("# Memory\n\n## Facts\n- Test fact")
    assert_includes mem.read, "Test fact"
  end
end

class TestMemoryToolProtection < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @memory = Rubot::Memory.new(workspace: @tmpdir)
    @tool = Rubot::Tools::MemoryTool.new(@memory)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_memory_tool_has_no_write_operation
    ops = @tool.parameters["properties"]["operation"]["enum"]
    refute_includes ops, "write"
    assert_includes ops, "read"
    assert_includes ops, "append"
    assert_includes ops, "update_section"
  end

  def test_memory_tool_write_operation_rejected
    result = @tool.execute({ "operation" => "write", "content" => "ERASED" })
    assert_includes result, "ERROR"
    assert_includes result, "reset"
    # Verify memory was not changed
    assert_includes @memory.read, "## Facts"
  end

  def test_memory_tool_read_works
    result = @tool.execute({ "operation" => "read" })
    assert_includes result, "## Facts"
  end

  def test_memory_tool_append_works
    result = @tool.execute({ "operation" => "append", "section" => "Facts", "content" => "New fact" })
    assert_includes result, "New fact"
    assert_includes @memory.read, "New fact"
  end

  def test_memory_tool_update_section_works
    @memory.append("Facts", "Old fact")
    result = @tool.execute({
      "operation" => "update_section",
      "section" => "Facts",
      "items" => ["Updated fact 1", "Updated fact 2"]
    })
    assert_includes result, "Updated"
    content = @memory.read
    refute_includes content, "Old fact"
    assert_includes content, "Updated fact 1"
  end
end

class TestMemoryProtectionViaFileTool < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @guard = Rubot::SafetyGuard.new(workspace: @tmpdir, restrict_to_workspace: false)
    @file_tool = Rubot::Tools::FileTool.new(safety_guard: @guard)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_file_tool_blocks_write_to_memory_md
    mem_path = File.join(@tmpdir, "MEMORY.md")
    File.write(mem_path, "Original memory content")

    result = @file_tool.execute({
      "operation" => "write",
      "path" => mem_path,
      "content" => "ERASED BY FILE TOOL"
    })
    assert_includes result, "ERROR"
    assert_includes result, "Cannot overwrite MEMORY.md"
    # Verify memory was not changed
    assert_includes File.read(mem_path), "Original memory content"
  end

  def test_file_tool_allows_write_to_other_files
    other_path = File.join(@tmpdir, "other.md")
    result = @file_tool.execute({
      "operation" => "write",
      "path" => other_path,
      "content" => "Other content"
    })
    assert_includes result, "Written"
  end

  def test_file_tool_allows_read_memory_md
    mem_path = File.join(@tmpdir, "MEMORY.md")
    File.write(mem_path, "# Memory\n\n## Facts\n- Read test")

    result = @file_tool.execute({
      "operation" => "read",
      "path" => mem_path
    })
    assert_includes result, "Read test"
    refute_includes result, "ERROR"
  end
end

class TestMemoryProtectionViaShell < Minitest::Test
  def setup
    @guard = Rubot::SafetyGuard.new(workspace: nil, restrict_to_workspace: false)
    @shell = Rubot::Tools::Shell.new(safety_guard: @guard)
  end

  def test_shell_blocks_rm_memory
    result = @shell.execute({ "command" => "rm MEMORY.md" })
    assert_includes result, "rejected"
    assert_includes result, "MEMORY.md"
    assert_includes result, "protected"
  end

  def test_shell_blocks_truncate_memory
    result = @shell.execute({ "command" => "truncate -s 0 MEMORY.md" })
    assert_includes result, "rejected"
    assert_includes result, "MEMORY.md"
  end

  def test_shell_blocks_echo_empty_to_memory
    result = @shell.execute({ "command" => "echo '' > MEMORY.md" })
    assert_includes result, "rejected"
    assert_includes result, "MEMORY.md"
  end

  def test_shell_allows_safe_commands
    result = @shell.execute({ "command" => "echo hello" })
    assert_includes result, "hello"
    refute_includes result, "rejected"
  end
end

class TestMemoryConsolidation < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @memory = Rubot::Memory.new(workspace: @tmpdir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def section_items(name)
    @memory.read.split("## #{name}").last.split(/^## /).first.to_s
           .lines.count { |l| l.strip.start_with?("- ") }
  end

  def test_merges_near_duplicate_entries
    @memory.append("Preferences", "User communicates in casual Bahasa Indonesia")
    @memory.append("Preferences", "User communicates in casual Indonesian slang")

    result = @memory.consolidate!

    refute_nil result
    assert_equal 1, section_items("Preferences")
  end

  def test_keeps_the_more_informative_wording
    @memory.append("Context", "User is a content creator")
    @memory.append("Context", "User is a content creator and needs a regular supply of ideas")

    @memory.consolidate!

    content = @memory.read
    assert_includes content, "needs a regular supply of ideas"
  end

  def test_keeps_distinct_entries
    @memory.append("Facts", "User lives in Jakarta")
    @memory.append("Facts", "User writes Ruby")
    @memory.append("Facts", "User ships on Fridays")

    @memory.consolidate!

    assert_equal 3, section_items("Facts")
  end

  def test_caps_a_section_and_archives_the_overflow
    (Rubot::Memory::SECTION_LIMITS["Facts"] + 5).times do |i|
      @memory.append("Facts", "Distinct fact number #{i}")
    end

    result = @memory.consolidate!
    refute_nil result
    assert_equal Rubot::Memory::SECTION_LIMITS["Facts"], section_items("Facts")
    assert_includes @memory.read, "Distinct fact number 29"
    refute_includes @memory.read, "Distinct fact number 0"

    archive = File.join(@tmpdir, Rubot::Memory::ARCHIVE_FILE)
    assert File.exist?(archive), "dropped entries should be archived"
    assert_includes File.read(archive), "Distinct fact number 0"
  end

  def test_append_with_max_items_drops_the_oldest_entry
    12.times { |i| @memory.append("Learned Corrections", "Correction #{i}", max_items: 3) }

    assert_equal 3, section_items("Learned Corrections")
    assert_includes @memory.read, "Correction 11"
    refute_includes @memory.read, "Correction 0"
  end

  def test_drops_retry_only_corrections
    @memory.append("Learned Corrections", "User asked: 'coba lagi dong' → Bot response was wrong/inadequate. User feedback: 'coba lagi dong'")
    @memory.append("Learned Corrections", "User asked: 'pakai Ruby' → Bot response was wrong/inadequate. User feedback: 'bukan python, pakai Ruby'")

    @memory.consolidate!

    content = @memory.read
    refute_includes content, "coba lagi dong"
    assert_includes content, "bukan python, pakai Ruby"

    archive = File.join(@tmpdir, Rubot::Memory::ARCHIVE_FILE)
    assert_includes File.read(archive), "coba lagi dong"
  end

  def test_keeps_corrections_that_mention_a_retry_and_a_rule
    line = "User asked: 'render ulang' → Bot response was wrong/inadequate. User feedback: 'coba lagi tapi pakai magick'"
    @memory.append("Learned Corrections", line)

    @memory.consolidate!

    assert_includes @memory.read, "pakai magick"
  end

  def test_is_idempotent
    @memory.append("Facts", "User lives in Jakarta")
    @memory.append("Facts", "User lives in Jakarta")

    assert @memory.consolidate!
    assert_nil @memory.consolidate!, "a second run should change nothing"
  end

  def test_does_nothing_without_a_workspace
    memory = Rubot::Memory.new(workspace: nil)
    assert_nil memory.consolidate!
  end
end
