# frozen_string_literal: true

require_relative "test_helper"

# Models and memory: the catalog, presets, compaction and the summary an agent learns from afterwards.
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

    File.write(File.join(@tmpdir, "model_catalog.json"), JSON.generate(
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
    session = Rubot::Session.new("saved-preset", workspace: @workspace, sessions_dir: @config.sessions_dir)
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

    def chat(_messages, tools: nil, on_retry: nil)
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
    assert_equal 1, @agent.session.compaction_events.size
    assert @agent.session.summarized?
  end

  def test_compaction_replaces_the_running_summary
    fill_session(10)
    @agent.session.append_summary("Old summary that must be merged away. " * 20)

    @agent.compact_session

    assert_equal "Summarized.", @agent.session.summary_text
    refute_includes @agent.session.summary_text, "Old summary"
  end

  def test_usage_report_estimates_the_window_for_an_aliased_model
    agent = Rubot::Agent.new(
      config: Rubot::Config.new(@config_path),
      provider: SummaryProvider.new,
      session_id: "alias-window",
      tools: Rubot::Tools::Registry.new
    )
    agent.instance_variable_set(:@active_preset, { "model" => "hy4-flash-free" })

    report = agent.usage_report

    assert_equal 1_048_576, report[:context_window]
    assert_in_delta report[:context_used].to_f / 1_048_576 * 100, report[:context_percent], 0.01
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

  # The anchor appears exactly when the goal leaves the transcript. Compaction
  # is the moment that happens, and the pinned prompt has to move with it.
  def test_the_task_is_restated_once_compaction_drops_the_message_that_stated_it
    @agent.session.add("user", "Refactor the auth flow across five files")
    9.times { |i| @agent.session.add("assistant", "step #{i}") }

    refute_includes @agent.send(:build_system_prompt), "# Task",
                    "the transcript still opens with the request"

    @agent.compact_session

    prompt = @agent.send(:build_system_prompt)
    assert_includes prompt, "# Task"
    assert_includes prompt, "Refactor the auth flow across five files"
  end

  # A compaction that runs in the middle of a turn must leave that turn alone:
  # the messages it is still working from are not something to summarize.
  def test_a_mid_turn_compaction_keeps_the_turn_it_runs_in
    8.times { |i| @agent.session.add(i.even? ? "user" : "assistant", "old #{i}") }
    @agent.instance_variable_set(:@turn_start_index, @agent.session.messages.size)
    6.times { |i| @agent.session.add("assistant", "working #{i}", reasoning_content: "why #{i}") }

    result = @agent.compact_session(protect_current_turn: true)

    refute_nil result
    assert_equal 8, result[:summarized_messages]
    assert_equal (0...6).map { |i| "working #{i}" }, @agent.session.messages.map { |m| m["content"] }
    # The mark that says where the turn began moved with the messages, so the
    # turn keeps its own reasoning for the requests that follow.
    assert_equal 6, @agent.send(:current_turn_message_count)
  end

  def test_auto_compaction_triggers_at_the_context_threshold
    fill_session(10)

    result = @agent.send(:run_auto_compaction)

    refute_nil result
    assert @agent.session.summarized?
  end

  def test_auto_compaction_reports_failure_when_the_summarizer_returns_nothing
    fill_session(10)
    failed = 0
    notified = 0

    empty = SummaryProvider.new
    empty.define_singleton_method(:chat) { |_messages, tools: nil, on_retry: nil| { "content" => "" } }
    @agent.instance_variable_set(:@provider, empty)

    @agent.on_compaction = ->(_result) { notified += 1 }
    @agent.on_compaction_failed = -> { failed += 1 }
    @agent.send(:run_auto_compaction)

    assert_equal 0, notified
    assert_equal 1, failed, "the in-progress row must be retired on failure"
  end

  def test_auto_compaction_notifies_the_channel_and_records_the_seam
    fill_session(10)
    notified = []
    started = 0

    @agent.on_compaction = ->(result) { notified << result }
    @agent.on_compaction_start = -> { started += 1 }
    @agent.send(:run_auto_compaction)

    assert_equal 1, started
    assert_equal 1, notified.size
    assert_equal 8, notified.first[:summarized_messages]
    events = @agent.session.compaction_events
    assert_equal 1, events.size
    assert_equal 8, events.first["summarized"]
    # The seam must point at the first message that was summarized away, not
    # one past the end of the shrunken transcript — otherwise a refresh cannot
    # find the turn it belongs to and drops the row.
    assert_equal 8, events.first["index"]
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
  # Counts requests and files them by purpose, because a flush now sends two
  # different background requests: one names the conversation (once per
  # session) and, when the backlog is full enough, one extracts memory.
  class CountingProvider
    MEMORY_MARKER = "memory extraction assistant"
    NAMING_MARKER = "You name conversations"

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

    def chat(messages, tools: nil, on_retry: nil)
      @calls += 1
      @requests << messages
      prompt = system_prompt(messages)

      if prompt.include?(MEMORY_MARKER)
        { "content" => '{"facts": [], "preferences": [], "context": []}', "finish_reason" => "stop" }
      elsif prompt.include?(NAMING_MARKER)
        { "content" => "Local app tweaks", "finish_reason" => "stop" }
      else
        { "content" => "answered", "finish_reason" => "stop" }
      end
    end

    def chat_stream(messages, tools: nil, on_retry: nil)
      chat(messages, tools: tools)
    end

    def extraction_calls
      count_with(MEMORY_MARKER)
    end

    def naming_calls
      count_with(NAMING_MARKER)
    end

    private

    def system_prompt(messages)
      first = messages.first
      first.is_a?(Hash) ? first.to_h["content"].to_s : ""
    end

    def count_with(marker)
      @requests.count { |messages| system_prompt(messages).include?(marker) }
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
    assert_equal 0, @provider.extraction_calls, "one message is below the batch size"
    assert_equal 1, @provider.naming_calls, "the first flush names the conversation"
    assert_equal 1, @agent.session.memory_backlog.size

    @agent.process("second message here", stream: false)
    @agent.flush_learning

    assert_equal 1, @provider.extraction_calls, "two answers plus one batched extraction"
    assert_equal 1, @provider.naming_calls, "a conversation is named once"
    assert_empty @agent.session.memory_backlog
  end

  # The rules the build ships are part of the prompt's identity. Adding the
  # batching reminder to the code did nothing for a session that was already
  # running: its prompt stayed pinned to the text of the older build, so the
  # reminder was written and never sent.
  def test_a_prompt_pinned_by_an_older_build_is_rebuilt
    @agent.process("first message here", stream: false)

    assert_includes @agent.system_prompt_epoch.keys, "rules",
                    "the shipped rule text has to move the epoch"

    # What an older build left behind: the same prompt, an epoch with no rules.
    @agent.session.store_system_prompt("teks dari build lama",
                                       @agent.system_prompt_epoch.except("rules"))

    rebuilt = @agent.build_system_prompt

    assert_includes rebuilt, "Before You Send",
                    "a prompt pinned under an older epoch must not be reused"
    refute_includes rebuilt, "teks dari build lama"
  end

  def test_a_named_conversation_keeps_its_title
    @agent.process("first message here", stream: false)
    @agent.flush_learning

    assert_equal "Local app tweaks", @agent.session.title

    saved = JSON.parse(File.read(@agent.session.file_path))
    assert_equal "Local app tweaks", saved["title"], "the title must survive a restart"

    @agent.process("second message here", stream: false)
    @agent.flush_learning

    assert_equal 1, @provider.naming_calls, "a second turn must not rename the session"
    assert_equal "Local app tweaks", @agent.session.title
  end

  # A name written by hand is not a placeholder for one the model picks later:
  # the namer only ever fills an empty title, so a conversation renamed before
  # its first turn answers keeps the name it was given.
  def test_a_hand_written_title_is_not_replaced_by_the_namer
    @agent.set_session_title("Proyek Templete")
    @agent.process("first message here", stream: false)
    @agent.flush_learning

    assert_equal 0, @provider.naming_calls, "a title already set is not a question to answer"
    assert_equal "Proyek Templete", @agent.session.title
  end

  def test_naming_replaces_the_first_prompt_in_the_session_list
    @agent.process("first message here", stream: false)
    @agent.flush_learning

    entry = Rubot::Session.describe(@agent.session.file_path)

    assert_equal "Local app tweaks", entry[:title]
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

  # A second config in the same sandbox, differing only in the auxiliary model.
  def config_with_auxiliary(name, presets: nil)
    data = {
      "agents" => { "defaults" => {
        "workspace" => File.join(@tmpdir, "workspace"),
        "memory" => { "extract_every" => 2 },
        "auxiliary_model" => name
      } },
      "models" => [ { "name" => "test", "model" => "openai/test-model", "api_key" => "sk-test" } ]
    }
    data["model_presets"] = presets if presets
    path = File.join(@tmpdir, "config-auxiliary.yml")
    File.write(path, data.to_yaml)
    Rubot::Config.new(path)
  end

  # Naming and extraction ask for a title and a JSON object, not for an
  # answer, so they are the requests a fast model should serve. Unset is the
  # default and stays the old behaviour: the conversation's own provider.
  def test_without_an_auxiliary_model_the_conversation_provider_serves_them
    assert_nil @agent.config.auxiliary_model
    assert_same @provider, @agent.send(:auxiliary_provider),
                "an unset auxiliary model must not build a second provider"
  end

  def test_an_auxiliary_model_takes_over_naming_and_extraction
    fast = CountingProvider.new
    agent = Rubot::Agent.new(
      config: config_with_auxiliary("deepseek-v4.1-flash"),
      provider: @provider,
      session_id: "auxiliary"
    )

    Rubot::Provider.stub(:build, fast) do
      agent.process("first message here", stream: false)
      agent.flush_learning
      agent.process("second message here", stream: false)
      agent.flush_learning
    end

    assert_equal 1, fast.naming_calls, "the namer must go to the auxiliary model"
    assert_equal 1, fast.extraction_calls, "the extractor must go too"
    assert_equal 0, @provider.naming_calls + @provider.extraction_calls,
                 "the conversation's provider must be left to the conversation"
    assert_equal "deepseek-v4.1-flash", agent.config.auxiliary_settings.model
  end

  # The saving has to be visible in the session totals: a cheap model billed at
  # the conversation's rate would look like it cost the same.
  def test_auxiliary_requests_are_priced_against_the_auxiliary_model
    config = config_with_auxiliary("fast", presets: {
      "fast" => {
        "model" => "openai/cheap-model",
        "pricing" => { "input" => 1.0, "output" => 2.0, "cached_input" => 0.1 }
      }
    })
    agent = Rubot::Agent.new(config: config, provider: @provider, session_id: "auxiliary-rates")

    assert_equal 1.0, agent.send(:auxiliary_rates)["input"]
    assert_equal 2.0, agent.send(:auxiliary_rates)["output"]
  end

  def test_a_failing_extraction_does_not_lose_the_answer
    failing = Class.new(CountingProvider) do
      def chat(messages, tools: nil, on_retry: nil)
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
