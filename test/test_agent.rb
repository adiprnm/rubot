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

class TestAgentToolIterationLimit < Minitest::Test
  # Always asks for another tool call, so the agent can only stop via the limit.
  class EndlessToolCallProvider
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def chat(_messages, tools: nil)
      @calls += 1
      {
        "content" => "",
        "tool_calls" => [
          {
            "id" => "call_#{@calls}",
            "type" => "function",
            "function" => {
              "name" => "file",
              "arguments" => JSON.generate({ "operation" => "list", "path" => "." })
            }
          }
        ]
      }
    end

    def chat_stream(messages, tools: nil)
      chat(messages, tools: tools)
    end
  end

  def build_agent(max_tool_iterations:)
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(@tmpdir, "config.yml")

    File.write(config_path, {
      "agents" => { "defaults" => {
        "workspace" => workspace,
        "max_tool_iterations" => max_tool_iterations
      } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)

    Rubot::Agent.new(
      config: Rubot::Config.new(config_path),
      provider: EndlessToolCallProvider.new,
      session_id: "limit-#{max_tool_iterations}"
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def test_uses_configured_limit_instead_of_hardcoded_ten
    agent = build_agent(max_tool_iterations: 3)

    assert_equal 3, agent.config.max_tool_iterations

    response = agent.process("loop forever", stream: false)

    assert_equal 3, agent.provider.calls, "expected exactly 3 LLM round-trips"
    assert_includes response, "tool-iteration limit (3)"
  end

  def test_default_limit_is_fifty_when_unset
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "workspace" => workspace } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)

    assert_equal 50, Rubot::Config.new(config_path).max_tool_iterations
  end

  def test_zero_or_negative_limit_falls_back_to_default
    @tmpdir = Dir.mktmpdir
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "max_tool_iterations" => 0 } }
    }.to_yaml)

    assert_equal Rubot::Config::DEFAULT_MAX_TOOL_ITERATIONS,
                 Rubot::Config.new(config_path).max_tool_iterations
  end
end

class TestAgentProgressNarration < Minitest::Test
  # Replies with narration + a tool call on the first turn, then a final answer.
  class NarratingProvider
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def chat(_messages, tools: nil)
      @calls += 1
      if @calls == 1
        {
          "content" => "Let me check the structure first.",
          "tool_calls" => [
            {
              "id" => "call_1",
              "type" => "function",
              "function" => { "name" => "probe", "arguments" => "{}" }
            }
          ]
        }
      else
        { "content" => "All done." }
      end
    end

    def chat_stream(messages, tools: nil, &_on_chunk)
      chat(messages, tools: tools)
    end
  end

  class ProbeTool < Rubot::Tool
    def name
      "probe"
    end

    def description
      "Test tool that does nothing."
    end

    def parameters
      { "type" => "object", "properties" => {} }
    end

    def execute(_arguments)
      "ok"
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @config = isolated_config(@tmpdir, name: "narration")
    @tools = Rubot::Tools::Registry.new
    @tools.register(ProbeTool.new)
    @agent = Rubot::Agent.new(
      config: @config,
      provider: NarratingProvider.new,
      session_id: "narration",
      tools: @tools
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_forwards_assistant_text_that_accompanies_tool_calls
    narrations = []
    # "go" is below MemoryExtractor::MIN_MESSAGE_LENGTH, so the provider's first
    # call is the agent turn itself rather than a background memory extraction.
    response = @agent.process("go", stream: false,
                              on_assistant_text: ->(text) { narrations << text })

    assert_equal [ "Let me check the structure first." ], narrations
    assert_equal "All done.", response
    refute_includes response, "Let me check the structure first."
  end

  def test_does_not_forward_empty_narration
    empty_narration_provider = Class.new(NarratingProvider) do
      def chat(_messages, tools: nil)
        @calls += 1
        if @calls == 1
          { "content" => "", "tool_calls" => [ { "id" => "call_1", "type" => "function",
                                                 "function" => { "name" => "probe", "arguments" => "{}" } } ] }
        else
          { "content" => "Done." }
        end
      end
    end
    agent = Rubot::Agent.new(
      config: @config,
      provider: empty_narration_provider.new,
      session_id: "empty-narration",
      tools: @tools
    )

    narrations = []
    agent.process("go", stream: false, on_assistant_text: ->(text) { narrations << text })

    assert_empty narrations
  end

  def test_system_prompt_asks_the_model_to_narrate_progress
    assert_includes @agent.build_system_prompt, "Progress Narration"
  end
end
