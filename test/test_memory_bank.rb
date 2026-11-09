# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class TestMemoryBank < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @global_path = File.join(@tmpdir, "MEMORY.md")
    @workspace_path = File.join(@tmpdir, "memory", "project-abc123.md")
    @bank = Rubot::MemoryBank.new(global_path: @global_path, workspace_path: @workspace_path)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_writes_go_to_the_workspace_layer_by_default
    @bank.append("Context", "builds a Jekyll site")

    assert_includes File.read(@workspace_path), "builds a Jekyll site"
    refute_includes File.read(@global_path), "builds a Jekyll site"
    assert_includes @bank.read, "builds a Jekyll site"
  end

  def test_global_scope_writes_to_the_global_file
    @bank.append("Facts", "user lives in Jakarta", scope: "global")

    assert_includes File.read(@global_path), "user lives in Jakarta"
    refute File.exist?(@workspace_path), "a global write must not create the workspace file"
  end

  def test_read_merges_both_layers_with_global_first
    @bank.append("Facts", "global fact", scope: "global")
    @bank.append("Facts", "workspace fact")

    content = @bank.read
    assert_equal 1, content.scan("# Memory").size, "the merged view has one title"
    assert_operator content.index("global fact"), :<, content.index("workspace fact")
    assert_includes content, "## Facts"
  end

  def test_read_deduplicates_identical_bullets_across_layers
    @bank.append("Facts", "same fact", scope: "global")
    @bank.append("Facts", "same fact")

    assert_equal 1, @bank.read.scan("same fact").size
  end

  def test_read_keeps_sections_only_present_in_one_layer
    @bank.append("Preferences", "prefers Bahasa Indonesia", scope: "global")
    @bank.append("Context", "ruby project")

    content = @bank.read
    assert_includes content, "prefers Bahasa Indonesia"
    assert_includes content, "ruby project"
  end

  def test_update_section_replaces_only_its_own_layer
    @bank.append("Facts", "global fact", scope: "global")
    @bank.append("Facts", "old local fact")
    @bank.update_section("Facts", [ "new local fact" ])

    content = @bank.read
    assert_includes content, "global fact"
    assert_includes content, "new local fact"
    refute_includes content, "old local fact"
  end

  def test_the_workspace_file_is_not_created_until_something_is_written
    refute File.exist?(@workspace_path)

    @bank.consolidate!
    refute File.exist?(@workspace_path), "consolidating must not create a file"

    @bank.read
    refute File.exist?(@workspace_path), "reading must not create a file"
  end

  def test_workspaces_do_not_see_each_other
    @bank.append("Context", "first project")

    other = Rubot::MemoryBank.new(
      global_path: @global_path,
      workspace_path: File.join(@tmpdir, "memory", "other-def456.md")
    )
    other.append("Context", "second project")

    reopened = Rubot::MemoryBank.new(global_path: @global_path, workspace_path: @workspace_path)
    content = reopened.read
    assert_includes content, "first project"
    refute_includes content, "second project"
  end

  def test_enabled_without_any_file
    bank = Rubot::MemoryBank.new(global_path: nil, workspace_path: File.join(@tmpdir, "none.md"))

    refute bank.enabled?
    assert_equal "", bank.read
  end

  def test_each_memory_file_gets_its_own_archive
    assert_equal File.join(@tmpdir, "MEMORY_ARCHIVE.md"),
                 Rubot::Memory.archive_path_for(File.join(@tmpdir, "MEMORY.md"))
    assert_equal File.join(@tmpdir, "project-abc123_ARCHIVE.md"),
                 Rubot::Memory.archive_path_for(File.join(@tmpdir, "project-abc123.md"))
  end
end

class TestConfigMemoryPaths < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config = Rubot::Config.from_data({}, config_path: File.join(@tmpdir, "config.yml"))
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_global_memory_sits_next_to_the_config
    assert_equal File.join(@tmpdir, "MEMORY.md"), @config.global_memory_path
  end

  def test_workspace_memory_is_keyed_by_the_workspace_path
    a = @config.workspace_memory_path(File.join(@tmpdir, "one", "project"))
    b = @config.workspace_memory_path(File.join(@tmpdir, "two", "project"))

    assert_equal File.join(@tmpdir, "memory"), File.dirname(a)
    refute_equal a, b, "two projects with the same name must not share a file"
    assert_equal a, @config.workspace_memory_path(File.join(@tmpdir, "one", "project"))
  end

  # A persona is not a project: its memory is part of the persona, so it
  # lives in the persona's own directory instead of a path-keyed file.
  def test_a_persona_keeps_its_memory_in_its_own_directory
    persona_dir = File.join(@tmpdir, "personas", "trainer")
    persona = @config.with_persona_workspace(persona_dir)

    assert_equal File.join(persona_dir, "MEMORY.md"), persona.workspace_memory_path
    assert_equal File.join(@tmpdir, "MEMORY.md"), persona.global_memory_path,
                 "the global layer is still shared"
    refute_equal @config.workspace_memory_path(persona_dir), persona.workspace_memory_path
  end

  def test_a_persona_calls_its_layer_a_persona
    persona = @config.with_persona_workspace(File.join(@tmpdir, "personas", "trainer"))

    assert_equal "persona", persona.memory_scope_label
    assert_equal "workspace", @config.memory_scope_label
  end

  # Skills are tooling, not identity: one copy in the configured workspace,
  # shared by every persona, instead of a tree per specialist.
  def test_skills_stay_in_the_configured_workspace_for_a_persona
    File.write(@config.config_path, {
      "agents" => { "defaults" => { "workspace" => File.join(@tmpdir, "main") } }
    }.to_yaml)
    config = Rubot::Config.new(@config.config_path)
    persona = config.with_persona_workspace(File.join(@tmpdir, "personas", "trainer"))

    assert_equal File.join(@tmpdir, "main"), persona.skills_workspace
    assert_equal File.join(@tmpdir, "personas", "trainer"), persona.assets_workspace
  end

  # One pricing cache and one model catalog for the whole install: the answer
  # does not change per persona, so neither should the file.
  def test_the_catalogs_live_next_to_the_config
    persona = @config.with_persona_workspace(File.join(@tmpdir, "personas", "trainer"))

    assert_equal @tmpdir, persona.catalog_dir
    assert_equal @config.catalog_dir, persona.catalog_dir
  end
end
