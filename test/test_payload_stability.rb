# frozen_string_literal: true

require_relative "test_helper"

# What a provider is actually handed, request after request.
#
# Every other caching test checks one rule in isolation (the pin in
# test_agent.rb, the block boundary in the tool-truncation test, the block
# fingerprints in test_cache_probe.rb). This file checks the assembled payload,
# because that is the thing the provider caches: a rule can hold while the
# payload still moves — a hash rebuilt with a different key order, an object id
# leaking into a description, a conversion that rewrites an earlier message
# when a later one arrives.
#
# The invariants, in the words of the docs:
#
#   * the exact prefix must be byte-identical — so the whole payload is
#     compared as JSON, not as Ruby hashes that Minitest compares by value;
#   * cache hits require an *exact* prefix match — so appending a turn must
#     leave every earlier block untouched;
#   * nothing process-local may reach the payload — so two Agents on the same
#     session have to produce the same bytes.
#
# Not covered yet, because the feature is not built: the Anthropic breakpoint
# count (items 5-7) and `prompt_cache_key` (item 18). Their tests belong with
# the code that sends them; writing them now would assert on nothing.
class TestPayloadStability < Minitest::Test
  # Enough history to exercise the whole path, small enough to read in a
  # failure message.
  HISTORY = [
    [ "user", "Kerjakan nomor 21 dulu", {} ],
    [ "assistant", "Oke, gw lihat tes-nya.", {} ]
  ].freeze

  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @config_path = File.join(@tmpdir, "config.yml")
    File.write(@config_path, {
      "agents" => { "defaults" => { "workspace" => @workspace } },
      "models" => [
        { "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" }
      ]
    }.to_yaml)
    @config = Rubot::Config.new(@config_path)
    @tools = Rubot::Tools::Registry.new
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def build_agent(session_id = "payload")
    agent = Rubot::Agent.new(config: @config, session_id: session_id, tools: @tools)
    HISTORY.each { |role, content, extra| agent.session.add(role, content, **extra) }
    agent
  end

  def openai_provider
    Rubot::Providers::OpenAI.new(
      Rubot::ProviderSettings.new(
        provider: "openai", model: "gpt-4o-mini", api_key: "sk-test",
        api_base: "https://example.invalid/v1", max_tokens: 256, temperature: 0.7
      )
    )
  end

  def anthropic_provider
    Rubot::Providers::Anthropic.new(
      Rubot::ProviderSettings.new(
        provider: "anthropic", model: "claude-sonnet-5", api_key: "sk-test",
        api_base: "https://example.invalid/v1", max_tokens: 256, temperature: 0.7
      )
    )
  end

  def openai_payload(agent)
    messages = agent.send(:build_messages)
    openai_provider.send(:build_payload, messages, @tools.all)
  end

  def anthropic_payload(agent)
    messages = agent.send(:build_messages)
    system_prompt = messages.find { |m| m["role"] == "system" }&.dig("content")
    rest = messages.reject { |m| m["role"] == "system" }
    anthropic_provider.send(:build_payload, rest, @tools.all, system_prompt)
  end

  # The blocks of a request as the provider reads them, one JSON string each.
  # Joining them makes "the earlier request is a prefix of the later one" a
  # plain string assertion; comparing whole payloads would trip over the
  # closing bracket that every JSON array has.
  def blocks(messages)
    Array(messages).map { |message| JSON.generate(message) }.join("\u0001")
  end

  def test_the_same_transcript_builds_the_same_payload_twice
    agent = build_agent

    first = JSON.generate(openai_payload(agent))
    second = JSON.generate(openai_payload(agent))

    assert_equal first, second,
                 "two requests over an unchanged transcript must be byte-identical"
  end

  # A restart is another process with another hash seed. Nothing it builds may
  # carry that seed into the payload: `String#hash`, `object_id` or a randomly
  # ordered hash would make every launch look like a changed prefix.
  def test_a_second_agent_in_the_same_process_builds_the_same_bytes
    first = JSON.generate(openai_payload(build_agent("same-session")))
    # A second Agent on the same session loads the transcript instead of writing
    # it again — that is what a restart looks like.
    reopened = Rubot::Agent.new(config: @config, session_id: "same-session", tools: @tools)
    second = JSON.generate(openai_payload(reopened))

    assert_equal first, second
  end

  def test_appending_a_turn_leaves_the_earlier_blocks_untouched
    agent = build_agent
    before = blocks(openai_payload(agent)["messages"])

    agent.session.add("user", "Lanjut")
    after = blocks(openai_payload(agent)["messages"])

    assert after.start_with?(before),
           "a new turn may only append; a changed earlier block is a full re-read"
  end

  def test_the_anthropic_conversion_appends_without_rewriting
    agent = build_agent
    before = blocks(anthropic_payload(agent)["messages"])

    agent.session.add("user", "Lanjut")
    after = blocks(anthropic_payload(agent)["messages"])

    assert after.start_with?(before)
  end

  # The tool catalog sits between the system prompt and the transcript, so a
  # reordered key or a reordered tool moves every block after it. Two registries
  # are compared because a stray Set/Hash rebuild is invisible within one.
  def test_the_tool_catalog_serialises_the_same_way_twice
    first = Rubot::Tools::Registry.new
    second = Rubot::Tools::Registry.new

    openai = openai_provider
    assert_equal JSON.generate(openai.format_tools(first.all)),
                 JSON.generate(openai.format_tools(second.all))

    anthropic = anthropic_provider
    assert_equal JSON.generate(anthropic.format_tools(first.all)),
                 JSON.generate(anthropic.format_tools(second.all))
  end

  # The trim rewrites old tool results, and it must stop there: the messages
  # after the boundary still have to be byte-identical, or the saving is paid
  # back as a re-read of everything that follows.
  def test_trimming_old_results_does_not_touch_the_messages_after_them
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      path = File.join(dir, "config.yml")
      File.write(path, {
        "agents" => { "defaults" => {
          "workspace" => workspace,
          "history" => { "tool_result_keep" => 2, "tool_result_max_chars" => 10 }
        } },
        "models" => [
          { "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" }
        ]
      }.to_yaml)
      agent = Rubot::Agent.new(config: Rubot::Config.new(path), session_id: "trim",
                              tools: @tools)

      # Four results with keep=2: the oldest block of two is shortened, the two
      # newest stay verbatim.
      4.times do |i|
        agent.session.add("assistant", "round #{i}", tool_calls: [
          { "id" => "call-#{i}", "type" => "function", "function" => { "name" => "shell_exec" } }
        ])
        agent.session.add("tool", "#{i}" * 60, tool_call_id: "call-#{i}")
      end
      agent.session.add("user", "dan setelah itu?")

      messages = agent.send(:build_messages)
      body = messages.reject { |m| m["role"] == "system" }

      shortened = body.select { |m| m["content"].to_s.include?("older tool output truncated") }
      results = body.select { |m| m["role"] == "tool" }

      assert_equal 2, shortened.size,
                   "one whole block of two results is shortened, not one per request"
      assert_equal "0" * 10, shortened.first["content"][0, 10],
                   "the shortened body keeps its first max_chars characters"
      assert_equal [ "#{"2" * 60}", "#{"3" * 60}" ], results.last(2).map { |m| m["content"] },
                   "the newest block is still sent verbatim"
      assert_equal "dan setelah itu?", body.last["content"]
    end
  end
end
