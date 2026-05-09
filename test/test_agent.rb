# frozen_string_literal: true

require_relative "test_helper"

class TestAgentSessionSwitching < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yml")
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)

    config_data = {
      "agents" => { "defaults" => { "workspace" => @workspace } },
      "models" => [
        { "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" },
        { "name" => "model-b", "model" => "openai/gpt-4", "api_key" => "sk-test" }
      ]
    }
    File.write(@config_path, config_data.to_yaml)
    @config = Rubot::Config.new(@config_path)
    @tools = Rubot::Tools::Registry.new
    @agent = Rubot::Agent.new(
      config: @config,
      session_id: "default",
      tools: @tools
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_switch_session_returns_same_session_if_id_matches
    session = @agent.switch_session("default")
    assert_equal "default", session.id
  end

  def test_switch_session_creates_new_session
    session = @agent.switch_session("new-topic")
    assert_equal "new-topic", session.id
    assert_equal 0, session.message_count
  end

  def test_switch_session_applies_model_override_from_saved_session
    # Set up session "code-topic" with model override
    code_session = Rubot::Session.new("code-topic", workspace: @workspace)
    code_session.model_override = "model-b"
    code_session.add("user", "hello")
    code_session.send(:save!)

    # Fresh agent on default session
    @agent = Rubot::Agent.new(
      config: @config,
      session_id: "default",
      tools: @tools
    )
    assert_equal "gpt-4o-mini", @agent.active_model_name

    # Switch to code-topic — should pick up the model-b override
    @agent.switch_session("code-topic")
    assert_equal "model-b", @agent.active_model_name
  end

  def test_switch_session_without_model_override_keeps_default
    # Create a session with no model override
    session = Rubot::Session.new("finance-topic", workspace: @workspace)
    session.add("user", "hello")

    @agent.switch_session("finance-topic")
    assert_equal "gpt-4o-mini", @agent.active_model_name
  end

  def test_clear_session_resets_model_override
    @agent.use_model("model-b")
    refute_nil @agent.session.model_override
    assert_equal "model-b", @agent.active_model_name

    @agent.clear_session
    assert_nil @agent.session.model_override
    assert_equal "gpt-4o-mini", @agent.active_model_name
  end

  def test_each_session_has_independent_model_override
    # Set up two sessions with different model overrides
    session_a = Rubot::Session.new("session-a", workspace: @workspace)
    session_a.model_override = "model-a"
    session_a.add("user", "hi")
    session_a.send(:save!)

    session_b = Rubot::Session.new("session-b", workspace: @workspace)
    session_b.model_override = "model-b"
    session_b.add("user", "hi")
    session_b.send(:save!)

    # Reconstruct agent on default session
    @agent = Rubot::Agent.new(
      config: @config,
      session_id: "default",
      tools: @tools
    )

    # Switch between sessions — each should get its own model
    @agent.switch_session("session-a")
    assert_equal "model-a", @agent.active_model_name

    @agent.switch_session("session-b")
    assert_equal "model-b", @agent.active_model_name

    @agent.switch_session("session-a")
    assert_equal "model-a", @agent.active_model_name
  end

  def test_session_file_path_is_correct
    session = Rubot::Session.new("my-topic", workspace: @workspace)
    expected = File.join(@workspace, "sessions", "my-topic.json")
    assert_equal expected, session.file_path
  end
end
