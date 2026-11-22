# frozen_string_literal: true

require_relative "test_helper"

# What a turn costs and reports: live usage, reasoning, the thinking level and the cache records behind the footer.
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

    def chat(_messages, tools: nil, on_retry: nil)
      raise "streamed only"
    end

    def chat_stream(_messages, tools: nil, on_retry: nil)
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

    def chat(_messages, tools: nil, on_retry: nil)
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

    def chat_stream(messages, tools: nil, on_retry: nil)
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


# Reasoning is streamed to the channel before the answer, on a callback of its
# own: the TUI draws it as a live thinking block, and the answer must not be
# polluted with it.
class TestAgentReasoning < Minitest::Test
  class ThinkingProvider
    def chat(_messages, tools: nil, on_retry: nil)
      { "content" => "answer", "reasoning_content" => "let me think" }
    end

    def chat_stream(_messages, tools: nil, on_retry: nil)
      yield nil, nil, "let me "
      yield nil, nil, "think"
      yield "answer", nil
      { "content" => "answer", "reasoning_content" => "let me think" }
    end
  end

  # A model that thinks but never streams it (or does not think at all) must
  # not make the channel invent fragments.
  class SilentProvider
    def chat(_messages, tools: nil, on_retry: nil)
      { "content" => "answer" }
    end

    def chat_stream(_messages, tools: nil, on_retry: nil)
      yield "answer", nil
      { "content" => "answer" }
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @config = isolated_config(@tmpdir, name: "reasoning")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def build_agent(provider)
    Rubot::Agent.new(config: @config, provider: provider, session_id: "reasoning")
  end

  def test_reasoning_fragments_reach_the_channel_apart_from_the_answer
    thoughts = []
    chunks = []

    response = build_agent(ThinkingProvider.new).process("go", on_reasoning: ->(text) { thoughts << text }) do |chunk|
      chunks << chunk
    end

    assert_equal [ "let me ", "think" ], thoughts
    assert_equal [ "answer" ], chunks
    assert_equal "answer", response
  end

  def test_a_model_without_reasoning_calls_nothing
    thoughts = []

    build_agent(SilentProvider.new).process("go", on_reasoning: ->(text) { thoughts << text })

    assert_empty thoughts
  end
end


class TestAgentThinkingLevel < Minitest::Test
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
    @agent = Rubot::Agent.new(config: @config, session_id: "default", tools: @tools)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_use_thinking_sets_the_provider_effort_and_persists_it
    @agent.use_thinking("low")

    assert_equal "low", @agent.provider.config.reasoning_effort

    fresh = Rubot::Agent.new(config: @config, session_id: "default", tools: @tools)
    assert_equal "low", fresh.provider.config.reasoning_effort,
                 "a session keeps its thinking level across restarts"
  end

  def test_use_thinking_rejects_an_unknown_level
    assert_nil @agent.use_thinking("turbo")
    assert_nil @agent.session.thinking_level
  end

  def test_use_thinking_empty_returns_to_the_config_default
    @agent.use_thinking("high")
    @agent.use_thinking("")

    assert_nil @agent.session.thinking_level
    assert_nil @agent.provider.config.reasoning_effort
  end

  def test_switching_models_keeps_the_thinking_level
    @agent.use_thinking("medium")

    @agent.use_model("model-b")

    assert_equal "medium", @agent.provider.config.reasoning_effort
    assert_equal "gpt-4", @agent.active_model_name
  end

  def test_clearing_the_session_level_falls_back_to_the_preset    config_data = {
      "agents" => { "defaults" => { "workspace" => @workspace, "model_preset" => "primary" } },
      "models" => [
        { "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" }
      ],
      "model_presets" => {
        "primary" => { "model" => "model-a", "reasoning_effort" => "high" }
      }
    }
    File.write(@config_path, config_data.to_yaml)
    config = Rubot::Config.new(@config_path)
    agent = Rubot::Agent.new(config: config, session_id: "default", tools: @tools)

    assert_equal "high", agent.provider.config.reasoning_effort,
                 "the preset's effort is what the session starts on"

    agent.use_thinking("")

    assert_equal "high", agent.provider.config.reasoning_effort,
                 "clearing the session's own choice goes back to the preset's effort"
  end

  # A persona carries the default a new conversation starts from, so a
  # session that has chosen nothing runs on the persona's level.
  def test_the_persona_default_is_what_an_unchosen_session_runs_on
    config_data = {
      "agents" => { "defaults" => { "workspace" => @workspace } },
      "models" => [
        { "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" }
      ]
    }
    File.write(@config_path, config_data.to_yaml)
    config = Rubot::Config.new(@config_path)
    persona = Rubot::Persona.new(slug: "trading", name: "Trading", thinking: "high")

    agent = Rubot::Agent.new(config: config, session_id: "default", tools: @tools,
                             persona: persona)
    assert_equal "high", agent.thinking_level
    assert_equal "high", agent.provider.config.reasoning_effort

    agent.use_thinking("low")
    assert_equal "low", agent.provider.config.reasoning_effort,
                 "the session's own choice comes first"

    fresh = Rubot::Agent.new(config: config, session_id: "default", tools: @tools,
                             persona: persona)
    assert_equal "low", fresh.provider.config.reasoning_effort,
                 "and it survives a restart"
  end
end


# Item 1 of the prompt-caching plan: every request leaves a record of what it
# was made of, so a hit rate of zero can be explained instead of guessed at.
class TestAgentCacheRecords < Minitest::Test
  class UsageProvider
    attr_reader :requests

    def initialize
      @requests = 0
    end

    def name
      "anthropic"
    end

    def last_usage
      {
        "input_tokens" => 400,
        "cache_read_input_tokens" => 8_000,
        "cache_creation_input_tokens" => 600,
        "output_tokens" => 12
      }
    end

    def chat(_messages, tools: nil, on_retry: nil)
      @requests += 1
      { "content" => "jawaban #{@requests}" }
    end

    def chat_stream(messages, tools: nil, on_retry: nil)
      chat(messages, tools: tools)
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    @config_path = File.join(@tmpdir, "config.yml")
    File.write(@config_path, {
      "agents" => { "defaults" => { "workspace" => workspace } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)
    @config = Rubot::Config.new(@config_path)
    @provider = UsageProvider.new
    @agent = Rubot::Agent.new(config: @config, provider: @provider, session_id: "cache-record")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_a_turn_records_what_the_request_was_made_of
    @agent.process("halo", stream: false)

    record = @agent.session.cache_records.last

    refute_nil record, "a request must leave a record behind"
    assert_equal "anthropic", record["provider"]
    assert_equal "gpt-4o-mini", record["model"]
    assert_equal 9_000, record["prompt_tokens"], "prompt is read + creation + uncached"
    assert_equal 8_000, record["cached_tokens"]
    assert_equal 600, record["cache_creation_tokens"]
    assert_equal 40, record["epoch"].to_s.length, "the prompt digest is a sha1"
    assert_equal 40, record["tools"].to_s.length, "and so is the tool catalog digest"
    assert_operator record["blocks"], :>, record["turns"],
                    "blocks count the system prompt and every tool on top of the turns"
    assert_equal false, record["auxiliary"]
    assert_equal "", record["summary"], "no compaction yet, so no summary digest"
    assert_equal @agent.thinking_level.to_s, record["effort"],
                 "and the thinking level the request went out with"
  end

  # The whole point of the pin: two requests in one session must carry the same
  # prompt, and the record has to say so. If the digest moved, the record would
  # blame the prefix and send the reader looking at the wrong thing.
  def test_the_prompt_and_tools_digest_hold_while_the_prompt_is_pinned
    @agent.process("halo", stream: false)
    first = @agent.session.cache_records.last

    @agent.process("lagi", stream: false)
    second = @agent.session.cache_records.last

    assert_equal first["epoch"], second["epoch"], "a pinned prompt keeps its digest"
    assert_equal first["tools"], second["tools"], "and so does the tool catalog"
    assert_operator second["turns"], :>, first["turns"], "the history grew in between"
  end
end


# Item 2 of the prompt-caching plan: the record says where the prefix moved,
# not just that it did.
class TestAgentCacheDivergence < Minitest::Test
  class UsageProvider
    def name
      "anthropic"
    end

    def last_usage
      {
        "input_tokens" => 100,
        "cache_read_input_tokens" => 4_000,
        "cache_creation_input_tokens" => 200,
        "output_tokens" => 5
      }
    end

    def chat(_messages, tools: nil, on_retry: nil)
      { "content" => "ok" }
    end

    def chat_stream(messages, tools: nil, on_retry: nil)
      chat(messages, tools: tools)
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    @config_path = File.join(@tmpdir, "config.yml")
    File.write(@config_path, {
      "agents" => { "defaults" => { "workspace" => workspace } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)
    @config = Rubot::Config.new(@config_path)
    @workspace = workspace
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def build_agent(id)
    Rubot::Agent.new(config: @config, provider: UsageProvider.new, session_id: id)
  end

  def test_the_first_request_has_nothing_to_compare_against
    agent = build_agent("divergence-first")
    agent.process("halo", stream: false)

    record = agent.session.cache_records.last

    assert_nil record["diverged_at"], "the first request of a session is not a request that moved"
    refute_nil record["fingerprint"], "but it still leaves the fingerprint for the next one"
  end

  def test_an_appended_turn_reports_an_intact_prefix
    agent = build_agent("divergence-append")
    agent.process("halo", stream: false)
    agent.process("lagi", stream: false)

    assert_equal(-1, agent.session.cache_records.last["diverged_at"],
                 "a turn that only appended has the prefix of a request that should hit")
  end

  # A rewritten earlier message is the interesting miss: the transcript looks
  # appended, but one block in the middle changed and everything behind it has
  # to be read again. This is what `reasoning_tail` does every turn.
  def test_a_rewritten_message_in_the_history_reports_its_index
    agent = build_agent("divergence-middle")
    agent.process("halo", stream: false)
    agent.process("lagi", stream: false)

    # A message that was already sent, quoted back with different text. The
    # first turn's own answer is not one: it arrived with the reply, so a
    # request that follows can only append it.
    agent.session.messages[2]["content"] = "lagi, tapi diubah"
    agent.process("ketiga", stream: false)

    record = agent.session.cache_records.last

    assert_operator record["diverged_at"], :>=, 2,
                    "the system prompt and the tools did not move, so the divergence is in the messages"
    assert_operator record["diverged_at"], :<, record["blocks"]
  end

  def test_a_rebuilt_prompt_reports_zero
    agent = build_agent("divergence-system")
    agent.process("halo", stream: false)

    # Clearing the pin alone rebuilds the same text; the prompt has to actually
    # change for the digest to move, and the summary is quoted into it.
    agent.session.summary = "ringkasan baru dari compaction"
    agent.session.clear_system_prompt!
    agent.process("lagi", stream: false)

    assert_equal 0, agent.session.cache_records.last["diverged_at"],
                 "a changed system prompt is block 0 and invalidates everything behind it"
  end

  # The comparison has to survive a restart: the fingerprint is stored with the
  # newest record precisely so the first request after a boot still knows what
  # the last request before it looked like.
  def test_the_comparison_survives_a_restart
    build_agent("divergence-restart").process("halo", stream: false)

    agent = build_agent("divergence-restart")
    agent.process("lagi", stream: false)

    record = agent.session.cache_records.last

    assert_equal(-1, record["diverged_at"],
                 "the reloaded fingerprint matched, so the prefix was still intact")
  end

  # Item 3: the record is only useful if the report says what it means.
  class ZeroCacheProvider < UsageProvider
    def last_usage
      {
        "input_tokens" => 5_000,
        "cache_read_input_tokens" => 0,
        "cache_creation_input_tokens" => 0,
        "output_tokens" => 5
      }
    end
  end

  def build_zero_cache_agent(id)
    Rubot::Agent.new(config: @config, provider: ZeroCacheProvider.new, session_id: id)
  end

  def test_the_report_names_a_cold_start
    agent = build_zero_cache_agent("cause-cold")
    agent.process("halo", stream: false)

    assert_equal :cold, agent.usage_report(network: false)[:cache_cause]
  end

  def test_the_report_says_nothing_when_the_last_request_hit
    agent = build_agent("cause-hit")
    agent.process("halo", stream: false)

    assert_nil agent.usage_report(network: false)[:cache_cause],
               "a hit has no cause worth a line"
  end

  # A summary is written because the transcript outgrew the budget. It rewrites
  # the prompt, but the fix is not "stop editing the prompt" — it is "the
  # conversation reached a compaction", which is why it gets its own label.
  def test_a_new_summary_is_reported_as_a_compaction
    agent = build_zero_cache_agent("cause-compaction")
    agent.process("halo", stream: false)

    agent.session.summary = "ringkasan dari compaction"
    agent.process("lagi", stream: false)

    assert_equal :compaction, agent.usage_report(network: false)[:cache_cause]
  end

  # What /context prints: figures, not a verdict. The cause of a miss is a log
  # line (Rubot.debug?), because it reads like a fault in a report — especially
  # `ttl_expiry`, which is only the provider's five minutes running out.
  def test_the_context_report_does_not_print_the_cause
    agent = build_zero_cache_agent("cause-render")
    agent.process("halo", stream: false)

    text = Rubot::UsageReport.render(agent.usage_report(network: false))

    refute_includes text, "Sebab"
    refute_includes text, "request pertama sesi ini"
  end
end
