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
    assert_equal "gpt-4", @agent.active_model_name
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
    assert_equal "gpt-4", @agent.active_model_name

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
    assert_equal "gpt-4o-mini", @agent.active_model_name

    @agent.switch_session("session-b")
    assert_equal "gpt-4", @agent.active_model_name

    @agent.switch_session("session-a")
    assert_equal "gpt-4o-mini", @agent.active_model_name
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

class TestAgentPersona < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @config_path = File.join(@tmpdir, "config.yml")

    File.write(@config_path, {
      "agents" => { "defaults" => {
        "workspace" => @workspace,
        "name" => "model-a",
        "system_prompt" => "GLOBAL DEFAULT PROMPT"
      } },
      "models" => [
        { "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" },
        { "name" => "model-b", "model" => "openai/gpt-4", "api_key" => "sk-test" }
      ]
    }.to_yaml)

    @config = Rubot::Config.new(@config_path)
    @tools = Rubot::Tools::Registry.new
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def build_agent(persona: nil, session_id: "persona-test")
    Rubot::Agent.new(
      config: @config,
      session_id: session_id,
      tools: @tools,
      persona: persona
    )
  end

  def trading_persona(model: "model-b", prompt: "Kamu adalah asisten trading. Jawab singkat.")
    Rubot::Persona.new(name: "trading", model: model, system_prompt: prompt)
  end

  def test_initializer_applies_persona_model_and_prompt
    agent = build_agent(persona: trading_persona.to_h)

    assert_equal "gpt-4", agent.active_model_name
    prompt = agent.build_system_prompt

    assert_includes prompt, "# Persona"
    assert_includes prompt, "Kamu adalah asisten trading."
    refute_includes prompt, "GLOBAL DEFAULT PROMPT"
  end

  def test_persona_without_prompt_keeps_the_config_prompt
    agent = build_agent(persona: { "model" => "model-b" })

    prompt = agent.build_system_prompt

    refute_includes prompt, "# Persona"
    assert_includes prompt, "GLOBAL DEFAULT PROMPT"
  end

  def test_persona_with_unknown_model_falls_back_to_default
    agent = build_agent(persona: trading_persona(model: "deleted-model").to_h)

    assert_equal "gpt-4o-mini", agent.active_model_name
  end

  def test_persona_info_is_plain_data
    agent = build_agent(persona: trading_persona)

    info = agent.persona_info

    assert_equal "trading", info["name"]
    assert_equal "model-b", info["model"]
    assert_equal "Kamu adalah asisten trading. Jawab singkat.", info["system_prompt"]
  end

  def test_apply_persona_switches_model_and_prompt
    agent = build_agent
    assert_equal "gpt-4o-mini", agent.active_model_name

    result = agent.apply_persona(model: "model-b", prompt: "Kamu adalah asisten hukum.")

    assert_equal "model-b", result["model"]
    assert_equal "gpt-4", agent.active_model_name
    assert_includes agent.build_system_prompt, "Kamu adalah asisten hukum."
  end

  def test_apply_persona_clears_a_stale_session_model_override
    agent = build_agent
    agent.use_model("model-a")
    assert_equal "model-a", agent.session.model_override

    agent.apply_persona(trading_persona.to_h)

    assert_nil agent.session.model_override
    assert_equal "gpt-4", agent.active_model_name
  end

  def test_apply_persona_nil_resets_to_the_default_model_and_prompt
    agent = build_agent(persona: trading_persona)
    assert_equal "gpt-4", agent.active_model_name

    result = agent.apply_persona(nil)

    assert_nil result
    assert_equal "gpt-4o-mini", agent.active_model_name
    prompt = agent.build_system_prompt
    refute_includes prompt, "# Persona"
    assert_includes prompt, "GLOBAL DEFAULT PROMPT"
  end

  def test_clear_session_keeps_the_persona_model
    agent = build_agent(persona: trading_persona)
    agent.session.add("user", "hello")

    agent.clear_session

    assert_equal 0, agent.session.message_count
    assert_equal "gpt-4", agent.active_model_name
    assert_includes agent.build_system_prompt, "Kamu adalah asisten trading."
  end

  def test_for_session_can_carry_a_persona
    parent = build_agent
    copy = parent.for_session("tg_1_2", persona: trading_persona.to_h)

    assert_equal "tg_1_2", copy.session.id
    assert_equal "gpt-4", copy.active_model_name
    assert_equal "model-b", copy.persona_info["model"]
  end

  def test_for_session_with_explicit_nil_persona_does_not_inherit
    parent = build_agent(persona: trading_persona)
    copy = parent.for_session("tg_1_2", persona: nil)

    assert_nil copy.persona_info
    assert_equal "gpt-4o-mini", copy.active_model_name
  end
end

class TestAgentCatalogModels < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @config_path = File.join(@tmpdir, "config.yml")

    File.write(@config_path, {
      "agents" => { "defaults" => { "workspace" => @workspace, "name" => "opencode-go" } },
      "models" => [
        {
          "name" => "opencode-go",
          "model" => "openai/deepseek-v4.1-flash",
          "api_key" => "sk-test",
          "api_base" => "https://opencode.ai/zen/go/v1"
        }
      ]
    }.to_yaml)

    File.write(File.join(@workspace, "model_catalog.json"), JSON.generate(
      "models" => [
        { "id" => "deepseek-v4.1-flash", "name" => "DeepSeek V4.1 Flash" },
        { "id" => "deepseek-v4-pro", "name" => "DeepSeek V4 Pro" }
      ]
    ))

    @config = Rubot::Config.new(@config_path)
    @tools = Rubot::Tools::Registry.new
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def build_agent(persona: nil, session_id: "catalog")
    Rubot::Agent.new(
      config: @config,
      session_id: session_id,
      tools: @tools,
      persona: persona
    )
  end

  def test_initializer_applies_a_catalog_model
    agent = build_agent(persona: {
      "model" => "deepseek-v4-pro",
      "system_prompt" => "Kamu adalah asisten trading."
    })

    assert_equal "deepseek-v4-pro", agent.active_model_name
    assert_equal "deepseek-v4-pro", agent.provider.config.model
    assert_equal "openai", agent.provider.name
    assert_includes agent.build_system_prompt, "Kamu adalah asisten trading."
  end

  def test_use_model_accepts_a_catalog_model
    agent = build_agent
    assert_equal "deepseek-v4.1-flash", agent.active_model_name

    assert_equal "deepseek-v4-pro", agent.use_model("deepseek-v4-pro")
    assert_equal "deepseek-v4-pro", agent.active_model_name
    assert_equal "deepseek-v4-pro", agent.session.model_override
  end

  def test_unknown_model_not_in_config_or_catalog_is_rejected
    agent = build_agent

    assert_nil agent.use_model("not-a-real-model")
    assert_equal "deepseek-v4.1-flash", agent.active_model_name
  end

  def test_persona_model_removed_from_catalog_falls_back
    agent = build_agent(persona: { "model" => "not-a-real-model" })

    assert_equal "deepseek-v4.1-flash", agent.active_model_name
  end
end

class TestAgentModelPresets < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @config_path = File.join(@tmpdir, "config.yml")

    File.write(@config_path, {
      "agents" => { "defaults" => {
        "workspace" => @workspace,
        "name" => "opencode-go",
        "model_preset" => "fast"
      } },
      "models" => [
        {
          "name" => "opencode-go",
          "model" => "openai/deepseek-v4.1-flash",
          "api_key" => "sk-test",
          "api_base" => "https://opencode.ai/zen/go/v1"
        }
      ],
      "model_presets" => {
        "fast" => { "model" => "deepseek-v4.1-flash", "max_tokens" => 4096, "temperature" => 0.2 },
        "deep" => { "model" => "deepseek-v4-pro", "max_tokens" => 8192, "temperature" => 0.1 }
      }
    }.to_yaml)

    @config = Rubot::Config.new(@config_path)
    @tools = Rubot::Tools::Registry.new
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def build_agent(session_id: "preset-test", persona: nil)
    Rubot::Agent.new(
      config: @config,
      session_id: session_id,
      tools: @tools,
      persona: persona
    )
  end

  def test_new_session_uses_the_primary_preset
    agent = build_agent

    assert_equal "fast", agent.active_preset_name
    assert_equal "deepseek-v4.1-flash", agent.active_model_name
    assert_equal 4096, agent.provider.config.max_tokens
    assert_in_delta 0.2, agent.provider.config.temperature
  end

  def test_switching_preset_within_a_session
    agent = build_agent

    applied = agent.use_model_preset("deep")

    assert_equal "deep", applied["name"]
    assert_equal "deepseek-v4-pro", applied["model"]
    assert_equal "deepseek-v4-pro", agent.active_model_name
    assert_equal "deep", agent.session.model_preset
    assert_equal "deepseek-v4-pro", agent.provider.config.model
    assert_equal 8192, agent.provider.config.max_tokens
  end

  def test_switching_to_default_follows_the_primary_preset
    agent = build_agent

    agent.use_model_preset("default")

    assert_equal "default", agent.session.model_preset
    assert_equal "deepseek-v4.1-flash", agent.active_model_name
  end

  def test_new_session_resets_an_in_session_switch
    agent = build_agent
    agent.use_model_preset("deep")

    agent.clear_session

    assert_equal "deepseek-v4.1-flash", agent.active_model_name
    assert_nil agent.session.model_preset
  end

  def test_persona_preset_is_applied
    agent = build_agent(persona: {
      "preset" => "deep",
      "system_prompt" => "Kamu adalah asisten trading."
    })

    assert_equal "deep", agent.active_preset_name
    assert_equal "deepseek-v4-pro", agent.active_model_name
    assert_nil agent.session.model_preset, "persona default is applied on every spawn"
    assert_includes agent.build_system_prompt, "Kamu adalah asisten trading."
  end

  def test_saved_session_preset_is_restored
    session = Rubot::Session.new("saved-preset", workspace: @workspace)
    session.model_preset = "deep"
    session.add("user", "hello")
    session.send(:save!)

    agent = build_agent(session_id: "saved-preset")

    assert_equal "deep", agent.active_preset_name
    assert_equal "deepseek-v4-pro", agent.active_model_name
  end

  def test_primary_default_exists_even_without_explicit_presets
    config = Rubot::Config.from_data(
      {
        "agents" => { "defaults" => { "workspace" => @workspace, "name" => "opencode-go" } },
        "models" => [
          {
            "name" => "opencode-go",
            "model" => "openai/deepseek-v4.1-flash",
            "api_key" => "sk-test",
            "api_base" => "https://opencode.ai/zen/go/v1"
          }
        ]
      },
      config_path: @config_path
    )
    agent = Rubot::Agent.new(config: config, session_id: "no-presets", tools: @tools)

    assert_equal "default", agent.active_preset_name
    assert_equal "deepseek-v4.1-flash", agent.active_model_name
    assert_equal [ "default" ], config.model_preset_names
  end
end

class TestAgentCompaction < Minitest::Test
  class SummaryProvider
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def name
      "openai"
    end

    def last_usage
      nil
    end

    def chat(_messages, tools: nil)
      @calls += 1
      { "content" => "Summarized." }
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @config_path = File.join(@tmpdir, "config.yml")
    write_config
    @agent = Rubot::Agent.new(
      config: Rubot::Config.new(@config_path),
      provider: SummaryProvider.new,
      session_id: "compact",
      tools: Rubot::Tools::Registry.new
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def write_config(compaction: {}, context_window: 100)
    File.write(@config_path, {
      "agents" => { "defaults" => {
        "workspace" => @workspace,
        "name" => "gpt-4o-mini",
        "system_prompt" => "Be brief.",
        "compaction" => {
          "auto" => true,
          "threshold_percent" => 10,
          "keep_recent_messages" => 2
        }.merge(compaction)
      } },
      "models" => [
        {
          "name" => "gpt-4o-mini",
          "model" => "openai/gpt-4o-mini",
          "api_key" => "sk-test",
          "context_window_tokens" => context_window
        }
      ],
      "provider" => "openai"
    }.to_yaml)
  end

  def fill_session(count = 10)
    count.times { |i| @agent.session.add(i.even? ? "user" : "assistant", "message #{i} " * 20) }
  end

  def test_compact_session_summarizes_old_messages
    fill_session(10)

    result = @agent.compact_session

    refute_nil result
    assert_equal 8, result[:summarized_messages]
    assert_equal 2, result[:kept_messages]
    assert_equal "Summarized.", result[:summary]
    assert @agent.session.summarized?
  end

  def test_compact_session_returns_nil_for_a_short_conversation
    @agent.session.add("user", "hello")

    assert_nil @agent.compact_session
  end

  def test_auto_compaction_triggers_at_the_context_threshold
    fill_session(10)

    result = @agent.send(:run_auto_compaction)

    refute_nil result
    assert @agent.session.summarized?
  end

  def test_auto_compaction_can_be_disabled
    write_config(compaction: { "auto" => false })
    agent = Rubot::Agent.new(
      config: Rubot::Config.new(@config_path),
      provider: SummaryProvider.new,
      session_id: "compact-disabled",
      tools: Rubot::Tools::Registry.new
    )
    10.times { |i| agent.session.add("user", "message #{i} " * 20) }

    assert_nil agent.send(:run_auto_compaction)
    refute agent.session.summarized?
  end

  def test_auto_compaction_does_nothing_below_the_threshold
    write_config(context_window: 10_000_000)
    agent = Rubot::Agent.new(
      config: Rubot::Config.new(@config_path),
      provider: SummaryProvider.new,
      session_id: "compact-below",
      tools: Rubot::Tools::Registry.new
    )
    10.times { |i| agent.session.add("user", "message #{i} " * 20) }

    assert_nil agent.send(:run_auto_compaction)
    refute agent.session.summarized?
  end
end

class TestAgentAdaptiveLearning < Minitest::Test
  class CountingProvider
    attr_reader :calls, :requests

    def initialize
      @calls = 0
      @requests = []
    end

    def name
      "openai"
    end

    def last_usage
      { "prompt_tokens" => 10, "completion_tokens" => 5 }
    end

    def chat(messages, tools: nil)
      @calls += 1
      @requests << messages
      if messages.first.to_h["content"].to_s.include?("memory extraction assistant")
        { "content" => '{"facts": [], "preferences": [], "context": []}', "finish_reason" => "stop" }
      else
        { "content" => "answered", "finish_reason" => "stop" }
      end
    end

    def chat_stream(messages, tools: nil)
      chat(messages, tools: tools)
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => {
        "workspace" => workspace,
        "memory" => { "extract_every" => 2 }
      } },
      "models" => [ { "name" => "test", "model" => "openai/test-model", "api_key" => "sk-test" } ]
    }.to_yaml)

    @provider = CountingProvider.new
    @agent = Rubot::Agent.new(
      config: Rubot::Config.new(config_path),
      provider: @provider,
      session_id: "adaptive"
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_answering_queues_memory_without_an_extra_request
    @agent.process("first message here", stream: false)

    assert_equal 1, @agent.session.memory_backlog.size
    assert_equal 1, @provider.calls, "answering must not trigger extraction"
  end

  def test_flush_learning_batches_extraction
    @agent.process("first message here", stream: false)
    @agent.flush_learning
    assert_equal 1, @provider.calls, "one message is below the batch size"
    assert_equal 1, @agent.session.memory_backlog.size

    @agent.process("second message here", stream: false)
    @agent.flush_learning

    assert_equal 3, @provider.calls, "two answers plus one batched extraction"
    assert_empty @agent.session.memory_backlog
  end

  def test_extraction_usage_is_counted_in_the_session_totals
    @agent.process("first message here", stream: false)
    @agent.flush_learning
    before = @agent.session.usage.requests

    @agent.process("second message here", stream: false)
    @agent.flush_learning

    assert_equal before + 2, @agent.session.usage.requests
  end

  def test_flush_learning_ignores_internal_prompts
    @agent.session.add("user", Rubot::Agent::CONTINUE_PROMPT)

    @agent.flush_learning

    assert_empty @agent.session.memory_backlog
    assert_equal 0, @provider.calls
  end

  def test_learned_corrections_are_not_injected_twice
    @agent.memory.append("Learned Corrections", "Do not use em dashes in captions")
    prompt = @agent.build_system_prompt

    assert_equal 1, prompt.scan("Do not use em dashes in captions").size
  end

  def test_a_failing_extraction_does_not_lose_the_answer
    failing = Class.new(CountingProvider) do
      def chat(messages, tools: nil)
        if messages.first.to_h["content"].to_s.include?("memory extraction assistant")
          raise "extractor exploded"
        end
        super
      end
    end
    agent = Rubot::Agent.new(
      config: @agent.config,
      provider: failing.new,
      session_id: "adaptive-failure"
    )

    answer = agent.process("first message here", stream: false)
    assert_equal "answered", answer

    agent.flush_learning
    agent.process("second message here", stream: false)
    agent.flush_learning # must not raise even though the extractor blows up
  end
end
