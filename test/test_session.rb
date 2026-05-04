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
end
