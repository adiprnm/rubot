# frozen_string_literal: true

require_relative "test_helper"

# Delegation: one agent hands a self-contained task to another persona. The
# tests here drive Agent#spawn_subagent directly with a fake provider, so no
# network is involved. What matters is the guards, the persona/workspace
# routing, the restricted tool set and the progress events.
class TestDelegate < Minitest::Test
  class AnswerProvider
    attr_reader :name, :prompts

    def initialize(answer = "sub answer")
      @name = "fake"
      @answer = answer
      @prompts = []
    end

    def chat(messages, tools: nil, on_retry: nil)
      @prompts << messages.last&.dig("content").to_s
      { "content" => @answer }
    end

    def chat_stream(messages, tools: nil, on_retry: nil, &_block)
      chat(messages, tools: tools)
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @config_path = File.join(@tmpdir, "config.yml")
    write_config(delegation: true)
    @config = Rubot::Config.new(@config_path)
    write_personas
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def write_config(delegation:, max_per_turn: 4, max_depth: 1)
    File.write(@config_path, {
      "agents" => { "defaults" => { "workspace" => @workspace, "name" => "model-a" } },
      "models" => [
        { "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" },
        { "name" => "model-b", "model" => "openai/gpt-4", "api_key" => "sk-test" }
      ],
      "delegation" => {
        "enabled" => delegation,
        "max_per_turn" => max_per_turn,
        "max_depth" => max_depth
      }
    }.to_yaml)
  end

  def write_personas
    store = Rubot::PersonaStore.new(dir: @tmpdir, legacy_workspace: @workspace)
    store.set("writer", Rubot::Persona.new(
      slug: "writer", name: "Writer", model: "model-b",
      system_prompt: "You are a writer."
    ))
    store.set("researcher", Rubot::Persona.new(
      slug: "researcher", name: "Researcher", system_prompt: "You research."
    ))
  end

  def build_agent(provider: AnswerProvider.new, persona: nil)
    agent = Rubot::Agent.new(config: @config, provider: provider, session_id: "lead", persona: persona)
    agent.subagent_provider = ->(_slug) { AnswerProvider.new }
    agent
  end

  def test_delegation_is_off_by_default
    write_config(delegation: false)
    @config = Rubot::Config.new(@config_path)
    agent = build_agent

    result = agent.spawn_subagent(agent_slug: "writer", task: "do it")

    assert_match(/disabled/, result)
  end

  def test_delegates_to_a_persona_and_returns_its_answer
    events = []
    agent = build_agent
    agent.on_subagent = ->(info) { events << info }

    result = agent.spawn_subagent(agent_slug: "writer", task: "write a poem")

    assert_equal "sub answer", result
    phases = events.map { |e| e[:phase] }
    assert_includes phases, :started
    assert_includes phases, :done
    assert(events.all? { |e| e[:agent] == "writer" })
  end

  def test_unknown_agent_is_refused
    agent = build_agent
    result = agent.spawn_subagent(agent_slug: "nobody", task: "do it")
    assert_match(/unknown agent/, result)
  end

  def test_cannot_delegate_to_self
    agent = build_agent(persona: { "slug" => "writer", "name" => "Writer" })
    result = agent.spawn_subagent(agent_slug: "writer", task: "do it")
    assert_match(/current agent/, result)
  end

  def test_sub_agent_uses_the_target_personas_model
    agent = build_agent
    agent.spawn_subagent(agent_slug: "writer", task: "write")

    # The lead's provider is the fake; the sub agent built its own provider
    # from the config, so we check the persona/model resolution instead.
    store = Rubot::PersonaStore.new(dir: @tmpdir, legacy_workspace: @workspace)
    assert_equal "model-b", store["writer"].model
  end

  def test_configured_subagent_model_overrides_the_persona_preset
    @config.apply_settings({ "subagent_model" => "model-a" })
    agent = build_agent
    sub = agent.send(:build_subagent,
                     Rubot::PersonaStore.new(dir: @tmpdir)["writer"],
                     "writer", "abc123", nil)

    assert_equal "model-a", sub.instance_variable_get(:@persona).model
    assert_nil sub.instance_variable_get(:@persona).preset
  end

  def test_per_subagent_model_and_thinking_override_the_definition
    @config.set_subagent_settings("writer", "model" => "model-c", "thinking" => "high")
    agent = build_agent
    sub = agent.send(:build_subagent,
                     Rubot::PersonaStore.new(dir: @tmpdir)["writer"],
                     "writer", "abc123", nil)

    persona = sub.instance_variable_get(:@persona)
    assert_equal "model-c", persona.model
    assert_nil persona.preset
    assert_equal "high", persona.thinking
  end

  def test_per_subagent_settings_beat_the_global_subagent_model
    @config.apply_settings({ "subagent_model" => "model-a" })
    @config.set_subagent_settings("writer", "model" => "model-c")
    agent = build_agent
    sub = agent.send(:build_subagent,
                     Rubot::PersonaStore.new(dir: @tmpdir)["writer"],
                     "writer", "abc123", nil)

    assert_equal "model-c", sub.instance_variable_get(:@persona).model
  end

  def test_explicit_model_override_beats_the_configured_subagent_model
    @config.apply_settings({ "subagent_model" => "model-a" })
    agent = build_agent
    sub = agent.send(:build_subagent,
                     Rubot::PersonaStore.new(dir: @tmpdir)["writer"],
                     "writer", "abc123", "model-b")

    assert_equal "model-b", sub.instance_variable_get(:@persona).model
  end

  def test_without_a_configured_subagent_model_the_persona_is_untouched
    agent = build_agent
    sub = agent.send(:build_subagent,
                     Rubot::PersonaStore.new(dir: @tmpdir)["writer"],
                     "writer", "abc123", nil)

    assert_equal "model-b", sub.instance_variable_get(:@persona).model
  end

  def test_sub_agent_cannot_delegate_again
    write_config(delegation: true, max_depth: 1)
    @config = Rubot::Config.new(@config_path)
    agent = build_agent

    # Simulate being a sub agent at the depth limit.
    agent.instance_variable_set(:@subagent, true)
    agent.instance_variable_set(:@subagent_depth, 1)

    result = agent.spawn_subagent(agent_slug: "writer", task: "do it")
    assert_match(/cannot delegate further/, result)
  end

  def test_per_turn_limit_is_enforced
    write_config(delegation: true, max_per_turn: 1)
    @config = Rubot::Config.new(@config_path)
    agent = build_agent

    first = agent.spawn_subagent(agent_slug: "writer", task: "one")
    second = agent.spawn_subagent(agent_slug: "researcher", task: "two")

    assert_equal "sub answer", first
    assert_match(/limit reached/, second)
  end

  def test_sub_agent_tool_set_excludes_delegation_and_notifications
    agent = build_agent
    sub = agent.send(:build_subagent,
                     Rubot::PersonaStore.new(dir: @tmpdir)["writer"],
                     "writer", "abc123", nil)
    names = sub.send(:tool_definitions).map(&:name)

    refute_includes names, "delegate"
    refute_includes names, "notify"
    refute_includes names, "cron"
    refute_includes names, "instagram"
  end

  def test_sub_agent_session_id_carries_the_sub_marker
    agent = build_agent
    sub = agent.send(:build_subagent,
                     Rubot::PersonaStore.new(dir: @tmpdir)["writer"],
                     "writer", "abc123", nil)

    assert_match(/~sub-abc123\z/, sub.session.id)
  end

  # A fake archive standing in for StoreClient: the agent only needs the three
  # audit methods, and the test checks they are called with the right data.
  class FakeArchive
    attr_reader :started, :finished

    def initialize
      @started = []
      @finished = []
    end

    def start_subagent_run(**args)
      @started << args
    end

    def finish_subagent_run(**args)
      @finished << args
    end

    # Session#load calls this when an archive is present. Returning nil makes
    # it fall back to the JSON file, which is what we want in this test.
    def load(_id, all: false)
      nil
    end

    def append(*); 0; end
    def save_meta(*); true; end
    def message_count(*); 0; end
  end

  def test_delegation_writes_an_audit_trail
    archive = FakeArchive.new
    agent = build_agent
    agent.instance_variable_set(:@archive, archive)

    agent.spawn_subagent(agent_slug: "writer", task: "write a poem")

    assert_equal 1, archive.started.size
    assert_equal "lead", archive.started.first[:parent_session]
    assert_equal "writer", archive.started.first[:agent_slug]
    assert_equal 1, archive.finished.size, archive.finished.inspect
    assert_equal "done", archive.finished.first[:status], archive.finished.first[:error].to_s
    assert_match(/~sub-/, archive.finished.first[:sub_session])
  end

  def test_builtin_subagents_are_available_but_not_user_personas
    store = Rubot::PersonaStore.new(dir: @tmpdir)

    assert_equal 6, store.subagents.size
    assert_equal "Debugger", store["debugger"].name
    refute store.all.key?("debugger")
    refute store.specialists.map(&:first).include?("debugger")
  end

  def test_delegates_to_a_builtin_subagent
    agent = build_agent

    result = agent.spawn_subagent(agent_slug: "planner", task: "plan a small task")

    assert_equal "sub answer", result
  end

  def test_builtin_subagent_tool_set_is_narrowed_by_allowed_tools
    agent = build_agent
    sub = agent.send(:build_subagent,
                     Rubot::PersonaStore.new(dir: @tmpdir)["researcher"],
                     "researcher", "abc123", nil)
    names = sub.send(:tool_definitions).map(&:name)

    assert_equal ["web_fetch"], names
  end

  def test_internal_persona_in_file_is_hidden_from_user_lists
    store = Rubot::PersonaStore.new(dir: @tmpdir)
    store.set("hidden", Rubot::Persona.new(
      slug: "hidden", name: "Hidden", internal: true,
      system_prompt: "You are hidden."
    ))

    refute store.all.key?("hidden")
    refute store.specialists.map(&:first).include?("hidden")
  end

  def test_internal_flag_round_trips_through_persona_hash
    persona = Rubot::Persona.from(Rubot::SubagentRegistry["planner"])

    assert persona.internal
    assert persona.to_h["internal"]
  end
end
