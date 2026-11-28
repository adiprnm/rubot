# frozen_string_literal: true

require_relative "test_helper"

# The writing half of the split: what file_write answers, and what it refuses.
# A write regression fails here, apart from the reading tests.
class TestFileWrite < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @tool = Rubot::Tools::FileWrite.new
    @tool.workspace = @tmpdir
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_the_tool_is_named_for_the_capability
    assert_equal "file_write", @tool.name
    assert @tool.writes?
  end

  def test_the_parameter_list_offers_only_writing_operations
    schema = @tool.parameters

    assert_equal %w[edit write append delete], schema["properties"]["operation"]["enum"]
    refute schema["properties"].key?("paths")
    refute_match(/^- (read|list|info):/, @tool.description)
  end

  # There is no default operation here: a call that names none did not say what
  # to do with the file.
  def test_a_call_with_only_a_path_is_not_a_write
    path = File.join(@tmpdir, "note.txt")

    result = @tool.execute({ "path" => path, "content" => "surprise" })

    assert_match(/Unknown operation/, result)
    refute File.exist?(path)
  end

  def test_a_reading_operation_is_unknown_here
    path = File.join(@tmpdir, "note.txt")
    File.write(path, "hello\n")

    result = @tool.execute({ "operation" => "read", "path" => path })

    assert_match(/Unknown operation/, result)
    assert_match(/edit, write, append, delete/, result)
  end

  # The round trip a caller actually makes: read with one tool, change with the
  # other. The bytes it sees are the same as before the split.
  def test_read_then_edit_sees_the_same_bytes
    path = File.join(@tmpdir, "note.txt")
    File.write(path, "one\ntwo\nthree\n")
    reader = Rubot::Tools::FileRead.new
    reader.workspace = @tmpdir

    assert_equal "one\ntwo\nthree\n", reader.execute({ "path" => path })

    @tool.execute({ "operation" => "edit", "path" => path,
                    "old_string" => "two", "new_string" => "TWO" })

    assert_equal "one\nTWO\nthree\n", reader.execute({ "path" => path })
  end

  def test_write_append_and_delete_still_round_trip
    path = File.join(@tmpdir, "note.txt")

    assert_includes @tool.execute({ "operation" => "write", "path" => path, "content" => "one\n" }), "Written"
    assert_includes @tool.execute({ "operation" => "append", "path" => path, "content" => "two\n" }), "Appended"
    assert_equal "one\ntwo\n", File.read(path)

    assert_includes @tool.execute({ "operation" => "delete", "path" => path }), "Deleted"
    refute File.exist?(path)
  end
end
