# frozen_string_literal: true

require_relative "test_helper"

class TestSession < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_add_scrubs_invalid_utf8
    session = Rubot::Session.new("utf8", workspace: @workspace)
    binary = "\x89PNG\r\n\x1a\n\x00\xff".b

    session.add("tool", binary)

    stored = session.messages.last["content"]
    assert stored.valid_encoding?, "content must be valid UTF-8"
    assert_equal Encoding::UTF_8, stored.encoding

    raw = File.read(File.join(@workspace, "sessions", "utf8.json"))
    assert raw.valid_encoding?, "session file must be valid UTF-8"
    parsed = JSON.parse(raw)
    assert_equal 1, parsed["messages"].size
  end

  def test_add_scrubs_invalid_utf8_in_tool_calls
    session = Rubot::Session.new("utf8-tools", workspace: @workspace)
    bad = "arg\xff".b
    tool_calls = [ { "id" => "call_1", "type" => "function",
                     "function" => { "name" => "shell_exec", "arguments" => bad } } ]

    session.add("assistant", "running", tool_calls: tool_calls)

    raw = File.read(File.join(@workspace, "sessions", "utf8-tools.json"))
    assert raw.valid_encoding?
    JSON.parse(raw) # must not raise
  end

  def test_load_ignores_empty_session_file
    dir = File.join(@workspace, "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "empty.json"), "")

    session = Rubot::Session.new("empty", workspace: @workspace)
    assert_equal 0, session.message_count
  end

  def test_load_ignores_corrupt_session_file
    dir = File.join(@workspace, "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "corrupt.json"), "{\"messages\": [")

    session = Rubot::Session.new("corrupt", workspace: @workspace)
    assert_equal 0, session.message_count
  end

  def test_creates_session_without_workspace
    session = Rubot::Session.new("test-1", workspace: nil)
    assert_equal "test-1", session.id
    assert_equal 0, session.message_count
  end

  def test_add_message
    session = Rubot::Session.new("test-2", workspace: nil)
    session.add("user", "Hello!")
    assert_equal 1, session.message_count

    session.add("assistant", "Hi there!")
    assert_equal 2, session.message_count
  end

  def test_message_content
    session = Rubot::Session.new("test-3", workspace: nil)
    session.add("user", "What is Ruby?")
    msg = session.conversation_history.first
    assert_equal "user", msg["role"]
    assert_equal "What is Ruby?", msg["content"]
  end

  def test_conversation_history
    session = Rubot::Session.new("test-4", workspace: nil)
    session.add("user", "Q1")
    session.add("assistant", "A1")
    session.add("user", "Q2")
    session.add("assistant", "A2")

    history = session.conversation_history
    assert_equal 4, history.size
    assert_equal "user", history[0]["role"]
    assert_equal "A1", history[1]["content"]
  end

  def test_clear_session
    session = Rubot::Session.new("test-5", workspace: nil)
    session.add("user", "Hello")
    session.add("assistant", "Hi")
    assert_equal 2, session.message_count

    session.clear!
    assert_equal 0, session.message_count
  end

  def test_persistence_with_workspace
    session = Rubot::Session.new("persist-1", workspace: @workspace)
    session.add("user", "Persistent message")

    # Create a new session instance with the same ID
    session2 = Rubot::Session.new("persist-1", workspace: @workspace)
    assert_equal 1, session2.message_count
    assert_equal "Persistent message", session2.conversation_history.first["content"]
  end

  def test_tool_call_tracking
    session = Rubot::Session.new("tool-session", workspace: nil)
    session.add("assistant", "Let me check", tool_calls: [
      { "id" => "call-1", "type" => "function", "function" => { "name" => "test" } }
    ])
    session.add("tool", "Result", tool_call_id: "call-1")

    history = session.conversation_history
    assistant_msg = history.find { |m| m["role"] == "assistant" }
    assert_instance_of Array, assistant_msg["tool_calls"]

    tool_msg = history.find { |m| m["role"] == "tool" }
    assert_equal "call-1", tool_msg["tool_call_id"]
  end

  def test_forced_skill_is_nil_by_default
    session = Rubot::Session.new("forced-skill-test", workspace: nil)
    assert_nil session.forced_skill
  end

  def test_forced_skill_can_be_set
    session = Rubot::Session.new("forced-skill-test", workspace: nil)
    session.forced_skill = "librarian"
    assert_equal "librarian", session.forced_skill
  end

  def test_forced_skill_can_be_cleared
    session = Rubot::Session.new("forced-skill-test", workspace: nil)
    session.forced_skill = "librarian"
    session.forced_skill = nil
    assert_nil session.forced_skill
  end

  def test_forced_skill_persists_with_workspace
    session = Rubot::Session.new("forced-skill-persist", workspace: @workspace)
    session.add("user", "ping")  # trigger save
    session.forced_skill = "test-skill"
    session.send(:save!)

    session2 = Rubot::Session.new("forced-skill-persist", workspace: @workspace)
    assert_equal "test-skill", session2.forced_skill
  end

  def test_forced_skill_persists_to_disk
    session = Rubot::Session.new("forced-skill-disk", workspace: @workspace)
    session.add("user", "ping")  # trigger save
    session.forced_skill = "my-skill"
    session.send(:save!)
    file_path = session.file_path
    assert File.exist?(file_path)

    data = JSON.parse(File.read(file_path))
    assert_equal "my-skill", data["forced_skill"]
  end

  def test_forced_skill_cleared_alongside_session
    session = Rubot::Session.new("forced-skill-clear", workspace: @workspace)
    session.add("user", "hello")
    session.forced_skill = "some-skill"
    refute_nil session.forced_skill

    session.clear!
    assert_nil session.forced_skill
  end

  def test_model_override_is_nil_by_default
    session = Rubot::Session.new("model-override-test", workspace: nil)
    assert_nil session.model_override
  end

  def test_model_override_can_be_set
    session = Rubot::Session.new("model-override-test", workspace: nil)
    session.model_override = "other-model"
    assert_equal "other-model", session.model_override
  end

  def test_model_override_persists_with_workspace
    session = Rubot::Session.new("model-override-persist", workspace: @workspace)
    session.add("user", "ping")
    session.model_override = "test-model"
    session.send(:save!)

    session2 = Rubot::Session.new("model-override-persist", workspace: @workspace)
    assert_equal "test-model", session2.model_override
  end

  def test_model_override_persists_to_disk
    session = Rubot::Session.new("model-override-disk", workspace: @workspace)
    session.add("user", "ping")
    session.model_override = "my-model"
    session.send(:save!)

    data = JSON.parse(File.read(session.file_path))
    assert_equal "my-model", data["model_override"]
  end

  def test_model_override_cleared_on_session_clear
    session = Rubot::Session.new("model-override-clear", workspace: @workspace)
    session.add("user", "hello")
    session.model_override = "some-model"
    refute_nil session.model_override

    session.clear!
    assert_nil session.model_override
  end
end

class TestSessionSummarization < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @session = Rubot::Session.new("summarize-test", workspace: @workspace)
    @provider = FakeSummarizeProvider.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_summary_is_nil_by_default
    session = Rubot::Session.new("new-session", workspace: @workspace)
    refute session.summarized?
    assert_nil session.summary_text
  end

  def test_append_summary_creates_new_summary
    @session.append_summary("First summary")
    assert_equal "First summary", @session.summary_text
    assert @session.summarized?
  end

  def test_append_summary_appends_to_existing
    @session.append_summary("First part")
    @session.append_summary("Second part")
    assert_includes @session.summary_text, "First part"
    assert_includes @session.summary_text, "Second part"
  end

  def test_persistence_of_summary
    @session.append_summary("Persistent summary")
    session2 = Rubot::Session.new("summarize-test", workspace: @workspace)
    assert_includes session2.summary_text, "Persistent summary"
  end

  def test_summarize_and_trim_does_nothing_without_workspace
    session = Rubot::Session.new("no-ws", workspace: nil)
    result = session.summarize_and_trim!(provider: @provider, system_prompt: "")
    assert_nil result
  end

  def test_summarize_and_trim_does_nothing_when_under_threshold
    # Default threshold is 60% of 100 = 60 messages
    # With only 10 messages, nothing should happen
    10.times { @session.add("user", "msg") }
    result = @session.summarize_and_trim!(provider: @provider, system_prompt: "")
    assert_nil result
  end

  def test_summarize_and_trim_works_when_over_threshold
    # Need more than 60 messages to trigger (60% of 100)
    70.times { |i| @session.add("user", "Message #{i}") }

    @provider.response = "Summary of old messages"
    result = @session.summarize_and_trim!(provider: @provider, system_prompt: "")

    assert_equal "Summary of old messages", result
    assert @session.summarized?
    assert @session.message_count < 70
  end

  def test_summarize_and_trim_removes_orphaned_tool_messages
    70.times { |i| @session.add("user", "Message #{i}") }
    # Add a tool message at the trimming boundary
    @session.add("assistant", "Let me check", tool_calls: [{ "id" => "t1" }])
    @session.add("tool", "Result", tool_call_id: "t1")

    @provider.response = "Summary"
    @session.summarize_and_trim!(provider: @provider, system_prompt: "")

    # First message should not be a tool message
    first = @session.messages.first
    refute_equal "tool", first["role"] if first
  end

  def test_summarize_and_trim_handles_provider_error
    70.times { |i| @session.add("user", "Message #{i}") }
    @provider.raise_error = true

    result = @session.summarize_and_trim!(provider: @provider, system_prompt: "")
    assert_nil result
    # Messages should be unchanged
    assert_equal 70, @session.message_count
  end

  def test_session_persists_summary_to_disk
    @session.append_summary("Disk test")
    file_path = @session.file_path
    assert File.exist?(file_path)

    data = JSON.parse(File.read(file_path))
    assert_equal "Disk test", data["summary"]
  end

  def test_session_loads_summary_from_disk
    @session.append_summary("Saved summary")

    session2 = Rubot::Session.new("summarize-test", workspace: @workspace)
    assert_equal "Saved summary", session2.summary_text
  end

  class FakeSummarizeProvider
    attr_accessor :response, :raise_error

    def initialize
      @response = "Summary"
      @raise_error = false
    end

    def chat(messages, tools: nil)
      raise StandardError, "Provider error" if @raise_error
      @response
    end
  end
end
