# frozen_string_literal: true

require_relative "test_helper"

# The reading half of the split: what file_read answers, and what it refuses
# even when the model asks. A regression here must fail on its own, without a
# write test in the same file proving anything.
class TestFileRead < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @tool = Rubot::Tools::FileRead.new
    @tool.workspace = @tmpdir
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_the_tool_is_named_for_the_capability
    assert_equal "file_read", @tool.name
    assert @tool.writes? == false
  end

  # Only reading operations are offered. A model shown a write here would spend
  # a round on a tool that does not have it.
  def test_the_parameter_list_offers_only_reading_operations
    schema = @tool.parameters

    assert_equal %w[read list info], schema["properties"]["operation"]["enum"]
    refute schema["properties"].key?("content")
    refute schema["properties"].key?("old_string")
    refute schema["properties"].key?("new_string")
    refute_match(/^- (edit|write|append|delete):/, @tool.description)
    refute_match(/\bwrite\b/, @tool.description)
  end

  def test_a_call_with_only_a_path_reads
    path = File.join(@tmpdir, "note.txt")
    File.write(path, "hello\n")

    assert_equal "hello\n", @tool.execute({ "path" => path })
  end

  def test_list_and_info_still_work
    path = File.join(@tmpdir, "note.txt")
    File.write(path, "hello\n")

    assert_includes @tool.execute({ "operation" => "list", "path" => @tmpdir }), "note.txt"
    assert_includes @tool.execute({ "operation" => "info", "path" => path }), "Type: File"
  end

  # The operation set is enforced where the file would change, not only in the
  # description the model was shown.
  def test_a_writing_operation_is_unknown_here_and_changes_nothing
    path = File.join(@tmpdir, "note.txt")
    File.write(path, "keep me\n")

    result = @tool.execute({ "operation" => "write", "path" => path, "content" => "gone" })

    assert_match(/Unknown operation/, result)
    assert_match(/read, list, info/, result, "the error names what this tool does accept")
    assert_equal "keep me\n", File.read(path)
  end
end
