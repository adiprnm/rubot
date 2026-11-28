# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  # A skill is loaded by reading its SKILL.md through the file tool, so the one
  # place that recognizes that read is what every surface asks before it draws a
  # row. These tests pin the recognition: which calls count, which do not, and
  # what happens to arguments that describe nothing at all.
  class TestSkillLoad < Minitest::Test
    SKILLS = "/home/adipurnm/.rubot/skills"

    def names(tool, args)
      SkillLoad.names(tool, args)
    end

    def test_a_file_read_of_a_skill_file_loads_that_skill
      assert_equal [ "brain" ],
                   names("file_read", { "operation" => "read",
                                       "path" => "#{SKILLS}/brain/SKILL.md" })
    end

    def test_a_shell_read_of_a_skill_file_loads_it_too
      assert_equal [ "grill" ], names("shell_exec", { "command" => "cat #{SKILLS}/grill/SKILL.md" })
      assert_equal [ "code-review" ],
                   names("shell_exec", { "command" => "head -n 40 #{SKILLS}/code-review/SKILL.md" })
    end

    # Skills are shared install-wide, but the tree an install puts them in
    # differs, so only the `/skills/<name>/SKILL.md` tail is matched.
    def test_a_workspace_skill_directory_counts_as_well
      assert_equal [ "writing" ],
                   names("file_read", { "operation" => "read",
                                       "path" => "#{SKILLS}/../workspace/skills/writing/SKILL.md" })
    end

    def test_writing_a_skill_file_is_authoring_one_not_loading_it
      assert_empty names("file_write", { "operation" => "write", "path" => "#{SKILLS}/grill/SKILL.md" })
      assert_empty names("file_write", { "operation" => "edit", "path" => "#{SKILLS}/grill/SKILL.md" })
    end

    # The decision is about the operation, not the tool the model used. The
    # writing tool has no default read, so even a call that names a skill path
    # with no operation is not a load.
    def test_the_write_tool_naming_a_skill_path_is_never_a_load
      assert_empty names("file_write", { "path" => "#{SKILLS}/brain/SKILL.md" })
      assert_empty names("file_write", { "operation" => "delete", "path" => "#{SKILLS}/brain/SKILL.md" })
    end

    # A skill is loaded by reading SKILL.md, and the file tool reads when it is
    # told nothing: a call that leaves the operation out is a read, so it loads
    # a skill like any other read.
    def test_a_read_without_an_operation_still_loads_a_skill
      assert_equal [ "brain" ], names("file_read", { "path" => "#{SKILLS}/brain/SKILL.md" })
      assert_equal [ "brain" ],
                   names("file_read", { "operation" => "", "path" => "#{SKILLS}/brain/SKILL.md" })
    end

    # Two skills read in one call are two skills loaded, in the order asked for.
    def test_several_paths_load_every_skill_they_name
      assert_equal %w[brain grill],
                   names("file_read", { "operation" => "read",
                                       "paths" => [ "#{SKILLS}/brain/SKILL.md", "/tmp/notes.md",
                                                    "#{SKILLS}/grill/SKILL.md" ] })
    end

    def test_the_same_skill_read_twice_is_named_once
      assert_equal [ "brain" ],
                   names("file_read", { "paths" => [ "#{SKILLS}/brain/SKILL.md",
                                                    "#{SKILLS}/brain/SKILL.md" ] })
    end

    # The file tool ignores `path` once `paths` is there (see
    # FileTool#read_files), so a skill named only in the ignored argument was
    # never opened and must not be reported as loaded.
    def test_paths_win_over_a_path_the_tool_never_reads
      assert_equal %w[grill thesis],
                   names("file_read", { "path" => "#{SKILLS}/brain/SKILL.md",
                                       "paths" => [ "#{SKILLS}/grill/SKILL.md",
                                                    "#{SKILLS}/thesis/SKILL.md" ] })
    end

    # A backup of a skill file is not the skill: the tail has to end there.
    def test_a_backup_of_a_skill_file_is_not_a_load
      assert_empty names("file_read", { "operation" => "read",
                                       "path" => "#{SKILLS}/brain/SKILL.md.bak" })
    end

    def test_an_ordinary_file_read_is_not_a_skill_load
      assert_empty names("file_read", { "operation" => "read", "path" => "/tmp/notes.md" })
      assert_empty names("file_read", { "paths" => %w[/tmp/a.md /tmp/b.md] })
    end

    # Listing the directory says which skills exist, not which one was picked.
    def test_listing_the_skills_directory_is_not_a_load
      assert_empty names("file_read", { "operation" => "list", "path" => SKILLS })
    end

    # A shell line that touches a skill file without reading it does not load
    # it: removing one is not picking it up.
    def test_a_shell_command_that_is_not_a_read_does_not_load_a_skill
      assert_empty names("shell_exec", { "command" => "rm #{SKILLS}/brain/SKILL.md" })
    end

    def test_a_tool_that_takes_no_path_never_loads_a_skill
      assert_empty names("web_fetch", { "path" => "#{SKILLS}/brain/SKILL.md" })
    end

    # Arguments arrive from a model: a missing hash, an empty one, or one with
    # no path must not raise while a row is being drawn.
    def test_arguments_that_describe_nothing_are_safe
      assert_empty names("file_read", nil)
      assert_empty names("file_read", {})
      assert_empty names("file_read", { "operation" => "read" })
      assert_empty names("shell_exec", { "command" => nil })
    end
  end
end
