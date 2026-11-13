# frozen_string_literal: true

require_relative "test_helper"

class TestPromptPatch < Minitest::Test
  STABLE = "# Stable\n\nYou are terse."
  MEMORY_A = "## Memory\n\nThe user is called Met."
  MEMORY_B = "## Memory\n\nThe user is called Met.\nThe user works from home."

  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @tools = Rubot::Tools::Registry.new
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def config_with(model)
    path = File.join(@tmpdir, "config.yml")
    File.write(path, {
      "agents" => { "defaults" => { "workspace" => @workspace } },
      "models" => [
        { "name" => "model-a", "model" => model, "api_key" => "sk-test" }
      ]
    }.to_yaml)
    Rubot::Config.new(path)
  end

  def opencode_agent(session_id = "patch-session")
    Rubot::Agent.new(config: config_with("opencode/deepseek-v4.1-flash"), session_id: session_id, tools: @tools)
  end

  def openai_agent(session_id = "patch-session")
    Rubot::Agent.new(config: config_with("openai/gpt-4o-mini"), session_id: session_id, tools: @tools)
  end

  def compose(agent, text)
    agent.stub(:compose_system_prompt, text) { yield }
  end

  def pin(agent, text)
    compose(agent, text) { agent.send(:build_system_prompt) }
  end

  def test_a_refresh_patches_when_the_provider_takes_a_mid_conversation_system_message
    agent = opencode_agent
    assert agent.send(:mid_conversation_system?)

    pinned = pin(agent, "#{STABLE}#{Rubot::Agent::SECTION_SEPARATOR}#{MEMORY_A}")
    compose(agent, "#{STABLE}#{Rubot::Agent::SECTION_SEPARATOR}#{MEMORY_B}") do
      assert agent.repin_system_prompt
    end

    patch = agent.session.system_patch
    refute_nil patch
    assert_includes patch, Rubot::Agent::PROMPT_PATCH_HEADER
    assert_includes patch, "The user works from home."
    refute_includes patch, STABLE, "an unchanged section must not be re-sent"

    compose(agent, "#{STABLE}#{Rubot::Agent::SECTION_SEPARATOR}#{MEMORY_B}") do
      assert_equal pinned, agent.send(:build_system_prompt)
    end
  end

  def test_the_patch_is_the_last_block_and_nothing_before_it_moves
    agent = opencode_agent
    agent.session.add("user", "halo")
    agent.session.add("assistant", "halo juga")
    pin(agent, "#{STABLE}#{Rubot::Agent::SECTION_SEPARATOR}#{MEMORY_A}")

    before = agent.send(:build_messages)
    compose(agent, "#{STABLE}#{Rubot::Agent::SECTION_SEPARATOR}#{MEMORY_B}") { agent.repin_system_prompt }
    after = agent.send(:build_messages)

    assert_equal before.size + 1, after.size
    assert_equal JSON.generate(before), JSON.generate(after[0...before.size])
    assert_equal "system", after.last["role"]
    assert_equal agent.session.system_patch, after.last["content"]
  end

  def test_a_refresh_with_nothing_new_costs_nothing
    agent = opencode_agent
    pin(agent, "#{STABLE}#{Rubot::Agent::SECTION_SEPARATOR}#{MEMORY_B}")
    compose(agent, "#{STABLE}#{Rubot::Agent::SECTION_SEPARATOR}#{MEMORY_B}") do
      refute agent.repin_system_prompt, "an unchanged prompt is a no-op, not a reason to touch the session"
    end
    assert_nil agent.session.system_patch
  end

  def test_a_provider_without_mid_conversation_system_still_repins
    agent = openai_agent
    refute agent.send(:mid_conversation_system?)
    pin(agent, "#{STABLE}#{Rubot::Agent::SECTION_SEPARATOR}#{MEMORY_A}")

    compose(agent, "#{STABLE}#{Rubot::Agent::SECTION_SEPARATOR}#{MEMORY_B}") do
      assert agent.repin_system_prompt
    end
    assert_nil agent.session.system_patch
  end

  def test_the_patch_survives_a_restart
    agent = opencode_agent("patch-restart")
    agent.session.add("user", "halo")
    pin(agent, "#{STABLE}#{Rubot::Agent::SECTION_SEPARATOR}#{MEMORY_A}")
    compose(agent, "#{STABLE}#{Rubot::Agent::SECTION_SEPARATOR}#{MEMORY_B}") { agent.repin_system_prompt }
    patch = agent.session.system_patch

    reopened = opencode_agent("patch-restart")
    assert_equal patch, reopened.session.system_patch
    assert_equal patch, reopened.send(:build_messages).last["content"]
  end

  def test_an_empty_patch_clears_the_previous_one
    agent = opencode_agent
    assert agent.session.set_system_patch("# Prompt Update\n\nold")
    assert agent.session.set_system_patch("   ")
    assert_nil agent.session.system_patch
  end
end
