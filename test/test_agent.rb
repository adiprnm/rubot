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

class TestAgentRoundLimit < Minitest::Test
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
              "arguments" => JSON.generate({ "operation" => "list", "path" => @path })
            }
          }
        ]
      }
    end

    def chat_stream(messages, tools: nil)
      chat(messages, tools: tools)
    end
  end

  def build_agent(max_rounds:)
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(@tmpdir, "config.yml")

    File.write(config_path, {
      "agents" => { "defaults" => {
        "workspace" => workspace,
        "max_rounds" => max_rounds
      } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)

    Rubot::Agent.new(
      config: Rubot::Config.new(config_path),
      provider: EndlessToolCallProvider.new,
      session_id: "limit-#{max_rounds}"
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def test_uses_configured_limit_instead_of_hardcoded_ten
    agent = build_agent(max_rounds: 3)

    assert_equal 3, agent.config.max_rounds

    response = agent.process("loop forever", stream: false)

    assert_equal 3, agent.provider.calls, "expected exactly 3 LLM round-trips"
    assert_includes response, "round limit (3)"
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

    assert_equal 50, Rubot::Config.new(config_path).max_rounds
  end

  def test_zero_or_negative_limit_falls_back_to_default
    @tmpdir = Dir.mktmpdir
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "max_rounds" => 0 } }
    }.to_yaml)

    assert_equal Rubot::Config::DEFAULT_MAX_ROUNDS,
                 Rubot::Config.new(config_path).max_rounds
  end

  def test_old_max_tool_iterations_key_is_still_accepted
    @tmpdir = Dir.mktmpdir
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "max_tool_iterations" => 7 } }
    }.to_yaml)

    assert_equal 7, Rubot::Config.new(config_path).max_rounds
  end

  def test_max_rounds_wins_over_the_old_key
    @tmpdir = Dir.mktmpdir
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "max_rounds" => 5, "max_tool_iterations" => 9 } }
    }.to_yaml)

    assert_equal 5, Rubot::Config.new(config_path).max_rounds
  end

  def test_progress_callback_receives_the_tool_count
    agent = build_agent(max_rounds: 3)
    events = []

    agent.process("loop forever", stream: false, on_progress: ->(round, tool_count) {
      events << [ round, tool_count ]
    })

    assert_equal [ [ 1, 1 ], [ 2, 1 ], [ 3, 1 ] ], events
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

  def test_system_prompt_asks_for_ruby_scripts_instead_of_python
    prompt = @agent.build_system_prompt
    assert_includes prompt, "Scripting Language"
    assert_includes prompt, "Write every script, helper, and one-off snippet in Ruby"
    assert_includes prompt, "Do not write new Python"
  end

  def test_system_prompt_asks_for_file_tool_edits_instead_of_shell
    prompt = @agent.build_system_prompt
    assert_includes prompt, "Editing Files"
    assert_includes prompt, "`edit` operation"
    assert_includes prompt, "Avoid shell commands that edit files in place"
  end

  # The agent must not paste the edited file's contents — or pseudo-diff
  # line summaries — into its reply; the TUI renders the real diff itself.
  def test_system_prompt_tells_the_agent_not_to_recite_edited_files
    prompt = @agent.build_system_prompt
    assert_includes prompt, "Do not reconstruct the"
    assert_includes prompt, "no +/- diff lines"
    assert_includes prompt, "report it briefly"
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

  def test_a_model_from_the_live_catalog_can_be_used
    agent = build_agent
    catalog = agent.model_catalog
    # The provider answered with a model that is not in the disk cache yet.
    catalog.instance_variable_set(:@entries, [ { "id" => "brand-new-model", "name" => "Brand New" } ])
    catalog.instance_variable_set(:@fetched_at, Time.now)

    assert_equal "brand-new-model", agent.use_model("brand-new-model")
    assert_equal "brand-new-model", agent.active_model_name
    assert_equal "brand-new-model", agent.session.model_override
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

  def test_compaction_replaces_the_running_summary
    fill_session(10)
    @agent.session.append_summary("Old summary that must be merged away. " * 20)

    @agent.compact_session

    assert_equal "Summarized.", @agent.session.summary_text
    refute_includes @agent.session.summary_text, "Old summary"
  end

  def test_usage_report_context_falls_back_to_an_estimate_after_compaction
    @agent.instance_variable_set(:@pricing_catalog, OfflineCatalog.new)
    fill_session(10)
    @agent.session.record_usage({ "prompt_tokens" => 5_000, "completion_tokens" => 100 })
    assert @agent.session.context_anchored?

    @agent.compact_session

    report = @agent.usage_report
    refute report[:context_anchored]
    # The pre-compaction prompt size must not linger in the footer.
    assert_operator report[:context_used], :<, 5_000
  end

  class OfflineCatalog
    def rates(*, **)
      nil
    end

    def context_window(*, **)
      nil
    end

    def source
      nil
    end
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

# /stop — the user can stop a turn while the agent is running tools.
class TestAgentCancellation < Minitest::Test
  class TwoToolCallsProvider
    attr_reader :calls

    def initialize(path)
      @path = path
      @calls = 0
    end

    def name
      "openai"
    end

    def chat(_messages, tools: nil)
      @calls += 1
      return { "content" => "done" } if @calls > 1

      {
        "content" => "Checking.",
        "tool_calls" => [
          tool_call("call_1", "list"),
          tool_call("call_2", "list")
        ]
      }
    end
    alias chat_stream chat

    private

    def tool_call(id, _suffix)
      {
        "id" => id,
        "type" => "function",
        "function" => {
          "name" => "file_ops",
          "arguments" => JSON.generate({ "operation" => "list", "path" => @path })
        }
      }
    end
  end

  class SlowShellProvider
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def name
      "openai"
    end

    def chat(_messages, tools: nil)
      @calls += 1
      return { "content" => "all done" } if @calls > 1

      {
        "content" => "Running it.",
        "tool_calls" => [
          {
            "id" => "call_sleep",
            "type" => "function",
            "function" => {
              "name" => "shell_exec",
              "arguments" => JSON.generate({ "command" => "sleep 30" })
            }
          }
        ]
      }
    end
    alias chat_stream chat
  end

  # Streams forever, obeying the same cancellation contract real providers
  # use: a stop is noticed at the next chunk.
  class EndlessStreamProvider
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def name
      "openai"
    end

    def chat(_messages, tools: nil)
      { "content" => "done" }
    end

    def chat_stream(_messages, tools: nil, &on_chunk)
      @calls += 1
      1_000.times do |i|
        Rubot::Cancellation.check!
        on_chunk&.call("chunk #{i} ")
        sleep 0.01
      end

      { "content" => "never finishes" }
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @config_path = File.join(@tmpdir, "config.yml")
    File.write(@config_path, {
      "agents" => { "defaults" => { "workspace" => @workspace } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)
    @config = Rubot::Config.new(@config_path)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def build_agent(provider)
    Rubot::Agent.new(config: @config, provider: provider, session_id: "cancel")
  end

  def test_cancel_skips_the_remaining_tool_calls
    agent = build_agent(TwoToolCallsProvider.new(@workspace))
    seen = []

    response = agent.process("do two things", stream: false,
      on_tool_call: ->(name, _args, _snapshot) {
        seen << name
        agent.cancel!
      },
      on_tool_result: ->(_name, result, _ui_diff) { seen << result })

    assert_equal 1, agent.provider.calls, "no further provider round after /stop"
    assert_equal 1, seen.count("file_ops"), "only the first tool runs"
    assert_includes seen, Rubot::Agent::CANCELLED_TOOL_RESULT
    assert_includes response, "Stopped by user"

    tool_results = agent.session.messages.select { |m| m["role"] == "tool" }.map { |m| m["content"] }
    assert_equal 2, tool_results.size
    assert_equal Rubot::Agent::CANCELLED_TOOL_RESULT, tool_results.last
  end

  def test_cancelling_an_idle_agent_does_nothing
    agent = build_agent(TwoToolCallsProvider.new(@workspace))

    refute agent.cancel!, "no turn is running"
    refute agent.cancelled?

    agent.process("hello", stream: false)
    assert_equal "done", agent.process("hello again", stream: false)
  end

  def test_stop_kills_the_running_shell_command
    agent = build_agent(SlowShellProvider.new)
    started = Queue.new
    response = nil

    runner = Thread.new do
      response = agent.process("sleep", stream: false,
        on_tool_call: ->(_name, _args, _snapshot) { started << true })
    end

    started.pop
    sleep 0.2

    before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert agent.cancel!, "the turn is running, so the stop request must register"
    finished = runner.join(10)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before

    assert finished, "the turn must end once the command is killed"
    assert_operator elapsed, :<, 8, "the command must be killed, not waited out"
    assert_equal 1, agent.provider.calls
    assert_includes response, "Stopped by user"
  end

  def test_stop_interrupts_a_streaming_answer_at_the_next_chunk
    agent = build_agent(EndlessStreamProvider.new)
    chunks = Queue.new
    response = nil

    # The stop arrives from another thread, the way the TUI's esc handler and
    # the session actor's watcher thread send it.
    canceller = Thread.new do
      chunks.pop
      agent.cancel!
    end

    before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    runner = Thread.new do
      response = agent.process("keep talking", stream: true) { |chunk| chunks << chunk }
    end

    assert runner.join(5), "the turn must end at the next streamed chunk"
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before

    assert_operator elapsed, :<, 3, "a streaming answer must stop without reading it all"
    assert canceller.join(2)
    assert_equal 1, agent.provider.calls, "no further provider rounds after the stop"
    assert_includes response, "Stopped by user"
    refute_includes response, "never finishes"
  end
end

class TestAgentHistoryTrimming < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yml")
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    File.write(@config_path, {
      "agents" => { "defaults" => {
        "workspace" => @workspace,
        "history" => { "tool_result_keep" => 1, "tool_result_max_chars" => 50 }
      } },
      "models" => [
        { "name" => "gpt-4o-mini", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" }
      ],
      "provider" => "openai"
    }.to_yaml)
    @agent = Rubot::Agent.new(
      config: Rubot::Config.new(@config_path),
      session_id: "history-trim",
      tools: Rubot::Tools::Registry.new
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_past_reasoning_is_not_sent_but_the_current_turn_keeps_it
    @agent.session.add("assistant", "old answer", reasoning_content: "old thinking")
    @agent.instance_variable_set(:@turn_start_index, @agent.session.messages.size)
    @agent.session.add("user", "new question")
    @agent.session.add("assistant", "working", reasoning_content: "fresh thinking")

    messages = @agent.send(:build_messages)
    assistants = messages.select { |m| m["role"] == "assistant" }

    assert_nil assistants[0]["reasoning_content"]
    assert_equal "fresh thinking", assistants[1]["reasoning_content"]
  end

  def test_old_tool_results_are_truncated_but_the_newest_is_kept
    @agent.session.add("assistant", "round 1", tool_calls: [
      { "id" => "call-1", "type" => "function", "function" => { "name" => "shell_exec" } }
    ])
    @agent.session.add("tool", "1" * 200, tool_call_id: "call-1")
    @agent.session.add("assistant", "round 2", tool_calls: [
      { "id" => "call-2", "type" => "function", "function" => { "name" => "shell_exec" } }
    ])
    @agent.session.add("tool", "2" * 200, tool_call_id: "call-2")

    messages = @agent.send(:build_messages)
    tools = messages.select { |m| m["role"] == "tool" }

    assert_equal "1" * 50 + Rubot::Agent::TRUNCATED_TOOL_RESULT_NOTICE, tools[0]["content"]
    assert_equal "2" * 200, tools[1]["content"]
  end

  # A turn no longer drops messages just because there are many of them: the
  # context window and compaction are the bound. The old 50-message cap made
  # the model forget everything past ~25 tool calls.
  def test_no_message_count_cap_by_default
    @agent.session.add("user", "start")
    60.times { |i| @agent.session.add("assistant", "step #{i}") }

    messages = @agent.send(:build_messages)
    assert_equal 62, messages.size
    assert_equal "start", messages[1]["content"]
  end

  # The task statement lives outside the transcript, so trimming and
  # compaction cannot lose it. It is re-stated in the system prompt each round.
  def test_the_task_statement_is_always_in_the_system_prompt
    @agent.session.add("user", "Refactor auth across five files")
    40.times { |i| @agent.session.add("assistant", "step #{i}") }

    prompt = @agent.send(:build_system_prompt)
    assert_includes prompt, "# Task"
    assert_includes prompt, "Refactor auth across five files"
  end

  def test_stored_tool_output_is_not_modified
    @agent.session.add("assistant", "round 1", tool_calls: [
      { "id" => "call-1", "type" => "function", "function" => { "name" => "shell_exec" } }
    ])
    @agent.session.add("tool", "1" * 200, tool_call_id: "call-1")
    @agent.session.add("assistant", "round 2", tool_calls: [
      { "id" => "call-2", "type" => "function", "function" => { "name" => "shell_exec" } }
    ])
    @agent.session.add("tool", "2" * 200, tool_call_id: "call-2")

    @agent.send(:build_messages)

    assert_equal "1" * 200, @agent.session.messages[1]["content"]
  end
end

# Feature: steering. Text typed while a turn is already running is queued and
# handed to the model between rounds instead of waiting for the turn to end.
class TestAgentSteering < Minitest::Test
  # Records the messages of every provider call and answers with a distinct
  # text per round, so a test can see exactly what the model was sent.
  class ScriptedProvider
    attr_reader :rounds
    attr_accessor :on_round

    def initialize(tool_first: false)
      @rounds = []
      @on_round = nil
      @tool_first = tool_first
    end

    def chat(messages, tools: nil)
      @rounds << messages.map { |m| [ m["role"], m["content"] ] }
      @on_round&.call(@rounds.size)

      if @tool_first && @rounds.size == 1
        {
          "content" => "",
          "tool_calls" => [
            {
              "id" => "call_1",
              "type" => "function",
              "function" => { "name" => "no_such_tool", "arguments" => "{}" }
            }
          ]
        }
      else
        { "content" => "answer #{@rounds.size}" }
      end
    end

    def chat_stream(messages, tools: nil, &on_chunk)
      result = chat(messages, tools: tools)
      on_chunk&.call(result["content"])
      result
    end
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def build_agent(provider)
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "workspace" => workspace } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)

    @agent = Rubot::Agent.new(
      config: Rubot::Config.new(config_path),
      provider: provider,
      session_id: "steering",
      tools: Rubot::Tools::Registry.new
    )
  end

  def test_a_steer_typed_while_the_answer_streams_gets_its_own_round
    provider = ScriptedProvider.new
    provider.on_round = ->(round) { @agent.steer("focus on the tests") if round == 1 }
    build_agent(provider)

    steered = []
    response = @agent.process("do the task", stream: false, on_steer: ->(text) { steered << text })

    assert_equal [ "focus on the tests" ], steered, "the steer is reported when delivered"
    assert_equal 2, provider.rounds.size, "the steer opens a second provider call"
    assert_equal [ "user", "focus on the tests" ], provider.rounds[1].last
    assert_includes response, "answer 1", "the pre-steer answer is kept"
    assert_includes response, "answer 2", "the steered answer is kept"
    assert_equal %w[user assistant user assistant],
                 @agent.session.messages.map { |m| m["role"] },
                 "the steer is its own user turn in the transcript"
  end

  def test_a_steer_arriving_during_a_tool_round_is_sent_with_the_next_call
    provider = ScriptedProvider.new(tool_first: true)
    build_agent(provider)

    steered = []
    @agent.process(
      "do the task",
      stream: false,
      on_tool_call: ->(_name, _args, _snapshot) { @agent.steer("check the logs instead") },
      on_steer: ->(text) { steered << text }
    )

    assert_equal [ "check the logs instead" ], steered
    assert_equal 2, provider.rounds.size
    assert_equal [ "user", "check the logs instead" ], provider.rounds[1].last
  end

  def test_a_leftover_steer_enters_ahead_of_the_next_message
    provider = ScriptedProvider.new
    build_agent(provider)
    @agent.steer("and keep it short")

    @agent.process("next task", stream: false)

    assert_equal [ [ "user", "and keep it short" ], [ "user", "next task" ] ],
                 provider.rounds.first.last(2)
  end

  def test_steer_rejects_blank_text
    build_agent(ScriptedProvider.new)

    refute @agent.steer("   ")
    refute @agent.steering_pending?
  end
end

# The TUI redraws a write's diff on /resume from before/after text stored on
# the tool message. It must never reach the provider request.
class TestAgentUiDiff < Minitest::Test
  class WriteProvider
    def initialize(path, operation: "write", content: "one\ntwo\n")
      @path = path
      @operation = operation
      @content = content
      @calls = 0
    end

    def name
      "openai"
    end

    def chat(_messages, tools: nil)
      @calls += 1
      return { "content" => "done" } if @calls > 1

      {
        "content" => "",
        "tool_calls" => [
          {
            "id" => "call_1",
            "type" => "function",
            "function" => {
              "name" => "file_ops",
              "arguments" => JSON.generate({
                "operation" => @operation,
                "path" => @path,
                "content" => @content
              })
            }
          }
        ]
      }
    end
    alias chat_stream chat
  end

  def run_write(workspace, path, provider)
    config_path = File.join(File.dirname(workspace), "config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "workspace" => workspace } },
      "models" => [
        { "name" => "model", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" }
      ]
    }.to_yaml)
    agent = Rubot::Agent.new(
      config: Rubot::Config.new(config_path),
      provider: provider,
      session_id: "ui-diff"
    )
    agent.process("edit it", stream: false)
    agent
  end

  def test_a_successful_write_records_before_and_after_on_the_tool_message
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      path = File.join(workspace, "notes.md")
      File.write(path, "one\n")

      agent = run_write(workspace, path, WriteProvider.new(path))
      tool = agent.session.messages.find { |msg| msg["role"] == "tool" }

      assert tool, "the tool row is in the session"
      diff = tool["ui_diff"]
      assert diff, "the write carries its UI diff"
      assert_equal path, diff["path"]
      assert_equal "one\n", diff["before"]
      assert_equal "one\ntwo\n", diff["after"]
      refute(agent.session.conversation_history.any? { |msg| msg.key?("ui_diff") },
             "the annotation is stripped from the model history")
    end
  end

  def test_an_append_records_the_concatenated_after
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      path = File.join(workspace, "log.md")
      File.write(path, "first\n")

      agent = run_write(workspace, path, WriteProvider.new(path, operation: "append", content: "second\n"))
      tool = agent.session.messages.find { |msg| msg["role"] == "tool" }

      assert_equal "first\n", tool["ui_diff"]["before"]
      assert_equal "first\nsecond\n", tool["ui_diff"]["after"]
    end
  end

  def test_a_delete_records_an_empty_after_so_the_removal_replays
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      path = File.join(workspace, "gone.md")
      File.write(path, "one\ntwo\n")

      agent = run_write(workspace, path, WriteProvider.new(path, operation: "delete", content: nil))
      tool = agent.session.messages.find { |msg| msg["role"] == "tool" }

      assert_match(/\ADeleted /, tool["content"])
      diff = tool["ui_diff"]
      assert diff, "the delete carries its UI diff"
      assert_equal "one\ntwo\n", diff["before"]
      assert_nil diff["after"], "nothing is left to show as the new content"
      refute File.exist?(path), "the file is gone"
    end
  end

  def test_a_write_the_tool_rejects_has_no_ui_diff
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      path = File.join(workspace, "MEMORY.md")
      File.write(path, "do not touch\n")

      agent = run_write(workspace, path, WriteProvider.new(path))
      tool = agent.session.messages.find { |msg| msg["role"] == "tool" }

      assert_match(/ERROR/, tool["content"])
      refute tool.key?("ui_diff"), "a failed write is not replayed as a diff"
    end
  end
end

class TestAgentLiveUsage < Minitest::Test
  # Streams its answer in chunks with a pause between them, so the figures
  # published mid-turn can be observed while the answer is still arriving.
  class StreamingProvider
    def initialize(chunks: 4, chunk: "kata " * 40, pause: 0.25)
      @chunks = chunks
      @chunk = chunk
      @pause = pause
      @last_usage = nil
    end

    def name
      "test"
    end

    def last_usage
      @last_usage
    end

    def chat(_messages, tools: nil)
      raise "streamed only"
    end

    def chat_stream(_messages, tools: nil)
      text = +""
      @chunks.times do
        sleep @pause
        text << @chunk
        yield @chunk, nil
      end
      @last_usage = {
        "prompt_tokens" => 1_000,
        "completion_tokens" => 200,
        "prompt_tokens_details" => { "cached_tokens" => 800 }
      }
      { "content" => text, "usage" => @last_usage }
    end
  end

  # Two provider calls carrying usage: the first asks for a tool, the second
  # answers. The second prompt is bigger, exactly like a real tool loop, so a
  # live footer has something to show before the turn ends.
  class MeteredProvider
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def name
      "test"
    end

    def chat(_messages, tools: nil)
      @calls += 1
      if @calls == 1
        {
          "content" => "",
          "tool_calls" => [
            {
              "id" => "call_1",
              "type" => "function",
              "function" => {
                "name" => "file",
                "arguments" => JSON.generate({ "operation" => "list", "path" => "." })
              }
            }
          ],
          "usage" => {
            "prompt_tokens" => 1_000,
            "completion_tokens" => 100,
            "prompt_tokens_details" => { "cached_tokens" => 800 }
          }
        }
      else
        {
          "content" => "done",
          "usage" => {
            "prompt_tokens" => 2_000,
            "completion_tokens" => 50,
            "prompt_tokens_details" => { "cached_tokens" => 1_600 }
          }
        }
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
      "agents" => { "defaults" => { "workspace" => workspace, "max_rounds" => 4 } },
      "models" => [
        {
          "name" => "test",
          "model" => "openai/gpt-4o-mini",
          "api_key" => "sk-test",
          "pricing" => { "input" => 1.0, "output" => 2.0, "cached_input" => 0.25 }
        }
      ]
    }.to_yaml)
    @config_path = config_path

    @agent = Rubot::Agent.new(
      config: Rubot::Config.new(config_path),
      provider: MeteredProvider.new,
      session_id: "live-usage"
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def collect_reports
    reports = []
    @agent.process("hello", stream: false, on_usage: ->(report) { reports << report })
    reports
  end

  # Measured reports only: a provisional one describes a request that has not
  # landed yet, so it says nothing about the provider's cache behaviour.
  def measured_reports
    collect_reports.reject { |report| report[:provisional] }
  end

  def test_usage_is_published_before_the_turn_finishes
    reports = measured_reports

    refute_empty reports
    assert_equal 1, reports.first[:requests], "first report should cover the first request"
    assert_equal 2, reports.last[:requests], "last report should cover both requests"
  end

  # The provider says nothing about tokens until its answer is complete, so a
  # turn that only published measured figures would sit still for its whole
  # duration. The first report has to describe the request in flight.
  def test_first_report_describes_the_request_in_flight
    reports = collect_reports
    first = reports.first

    assert first[:provisional], "the request has not returned yet"
    assert_operator first[:prompt_tokens], :>, 0, "the request being sent has a size"
    assert_operator first[:context_used], :>, 0
  end

  def test_the_last_report_is_measured_data_again
    reports = collect_reports

    refute reports.last[:provisional]
  end

  # Streamed text is the only moving target a turn has: the answer grows as
  # the chunks arrive, so the cost and the context estimate have to follow it
  # instead of waiting for the usage block at the end.
  def test_cost_and_context_follow_the_streamed_answer
    provider = StreamingProvider.new(chunks: 12, chunk: "kata " * 40)
    agent = Rubot::Agent.new(
      config: Rubot::Config.new(@config_path),
      provider: provider,
      session_id: "live-usage-stream"
    )

    reports = []
    agent.process("hello", on_usage: ->(report) { reports << report }) { |_chunk| }

    live = reports.select { |r| r[:provisional] }
    measured = reports.reject { |r| r[:provisional] }

    refute_empty live, "the stream should publish figures while it runs"
    refute_empty measured, "and the final figures once usage lands"

    outputs = live.map { |r| r[:completion_tokens] }
    assert_equal outputs.sort, outputs, "the output estimate only grows"
    assert_operator outputs.last, :>, outputs.first, "the answer moved the output figure"
    assert_operator live.map { |r| r[:context_used] }.last,
                    :>, live.map { |r| r[:context_used] }.first
  end

  def test_cache_hit_rate_follows_the_latest_request
    reports = measured_reports

    assert_in_delta 0.8, reports.first[:cache_hit_rate], 0.01
    assert_in_delta 0.8, reports.last[:cache_hit_rate], 0.01
  end

  def test_cost_grows_while_the_turn_is_running
    reports = measured_reports

    first = reports.first[:cost]["total"]
    last = reports.last[:cost]["total"]

    assert_operator first, :>, 0.0
    assert_operator last, :>, first
  end

  def test_context_estimate_moves_with_the_transcript
    reports = measured_reports

    assert_operator reports.last[:context_used], :>, reports.first[:context_used]
  end

  def test_reports_are_plain_data_for_a_ractor
    reports = collect_reports

    reports.each do |report|
      assert_kind_of Hash, report
      assert_kind_of Symbol, report.keys.first
      assert_kind_of String, report[:model]
      assert_kind_of Integer, report[:requests]
    end
  end
end


# Auto mode: the prompt is skipped, the safety guard is not. These tests drive
# a turn that asks for a destructive action, so they exercise the real decision
# point in Agent#process rather than a copy of it.
class TestAgentAutoMode < Minitest::Test
  # A tool that claims every call is destructive, so the confirmation branch is
  # always the one under test.
  class DestructiveTool < Rubot::Tool
    def name
      "risky"
    end

    def description
      "Test tool that always claims to destroy something."
    end

    def parameters
      { "type" => "object", "properties" => {} }
    end

    def dangerous_action?(_arguments)
      true
    end

    def dangerous_action_reason(_arguments)
      "deletes files"
    end

    def execute(_arguments)
      "ran"
    end
  end

  class OneCallProvider
    attr_reader :name

    def initialize
      @name = "fake"
      @calls = 0
    end

    def chat(_messages, tools: nil)
      @calls += 1
      if @calls == 1
        {
          "content" => "",
          "tool_calls" => [
            {
              "id" => "call_1",
              "type" => "function",
              "function" => { "name" => "risky", "arguments" => "{}" }
            }
          ]
        }
      else
        { "content" => "done" }
      end
    end

    def chat_stream(messages, tools: nil, &_on_chunk)
      chat(messages, tools: tools)
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @config = isolated_config(@tmpdir, name: "auto")
    @tools = Rubot::Tools::Registry.new
    @tools.register(DestructiveTool.new)
    @agent = Rubot::Agent.new(config: @config, provider: OneCallProvider.new,
                              session_id: "auto", tools: @tools)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_auto_mode_runs_the_action_without_asking
    @agent.auto_approve = true
    asked = []

    @agent.process("go", on_confirm: ->(name, args, reason) { asked << [ name, reason ]; false })

    assert_empty asked, "auto mode must not call the confirmation callback"
    assert_equal "ran", @agent.session.messages.find { |m| m["role"] == "tool" }["content"]
  end

  def test_without_auto_mode_the_action_asks_first
    asked = []

    @agent.process("go", on_confirm: ->(name, args, reason) { asked << [ name, reason ]; false })

    assert_equal [ [ "risky", "deletes files" ] ], asked
    assert_includes @agent.session.messages.find { |m| m["role"] == "tool" }["content"],
                    "cancelled"
  end

  # The preference has to survive a restart, otherwise /auto is per-launch
  # noise instead of a setting.
  def test_auto_mode_is_written_to_config
    refute Rubot::Config.new(@config.config_path).auto_approve

    @agent.auto_approve = true

    assert Rubot::Config.new(@config.config_path).auto_approve
  end

  def test_a_fresh_agent_reads_the_saved_preference
    @agent.auto_approve = true

    reloaded = Rubot::Agent.new(config: Rubot::Config.new(@config.config_path),
                                provider: OneCallProvider.new, session_id: "auto2",
                                tools: @tools)

    assert reloaded.auto_approve?
  end
end
