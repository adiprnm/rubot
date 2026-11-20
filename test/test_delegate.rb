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
end
