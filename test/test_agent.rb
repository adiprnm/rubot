# frozen_string_literal: true

require_relative "test_helper"

# One turn of the agent: switching sessions, the round limit, how progress is narrated and how a persona reaches the prompt.
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
    code_session = Rubot::Session.new("code-topic", workspace: @workspace, sessions_dir: @config.sessions_dir)
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
    session = Rubot::Session.new("finance-topic", workspace: @workspace, sessions_dir: @config.sessions_dir)
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
    session_a = Rubot::Session.new("session-a", workspace: @workspace, sessions_dir: @config.sessions_dir)
    session_a.model_override = "model-a"
    session_a.add("user", "hi")
    session_a.send(:save!)

    session_b = Rubot::Session.new("session-b", workspace: @workspace, sessions_dir: @config.sessions_dir)
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
    session = Rubot::Session.new("my-topic", workspace: @workspace, sessions_dir: @config.sessions_dir)
    expected = File.join(@config.sessions_dir, "my-topic.json")
    assert_equal expected, session.file_path
    refute_includes expected, File.join(@workspace, "sessions"),
                    "sessions live next to config.yml, not inside the workspace"
  end
end


class TestAgentRoundLimit < Minitest::Test
  # Always asks for another tool call, so the agent can only stop via the limit.
  class EndlessToolCallProvider
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def chat(_messages, tools: nil, on_retry: nil)
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

    def chat_stream(messages, tools: nil, on_retry: nil)
      chat(messages, tools: tools, on_retry: on_retry)
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

  # A fired cron job runs through #process_cron, which calls the provider
  # directly. It used to pass `on_retry`, a local of #process that is not in
  # scope here, so every scheduled turn died with NameError before the model
  # was ever asked. The provider below accepts the keyword to prove the call
  # shape is right and records what it received.
  class CronProvider
    attr_reader :calls, :retry_values

    def initialize
      @calls = 0
      @retry_values = []
    end

    def name
      "openai"
    end

    def chat(_messages, tools: nil, on_retry: :missing)
      @calls += 1
      @retry_values << on_retry
      { "content" => "cron answer", "finish_reason" => "stop" }
    end
  end

  def test_process_cron_does_not_raise_name_error_on_retry
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(@tmpdir, "cron-config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "workspace" => workspace } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)

    provider = CronProvider.new
    agent = Rubot::Agent.new(
      config: Rubot::Config.new(config_path),
      provider: provider,
      session_id: "cron-retry"
    )

    response = agent.process_cron("Rangkuman berita", fresh: true)

    assert_equal "cron answer", response
    assert_equal 1, provider.calls
    assert_equal [ nil ], provider.retry_values
  end

  # A turn the reader did not speak: the text reaches the model as context and
  # the transcript keeps only the answer. Otherwise a background report would
  # appear in the conversation in the reader's own voice, saying words they
  # never typed.
  def test_a_background_turn_leaves_out_the_message_it_was_given
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(@tmpdir, "background-config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "workspace" => workspace } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)

    agent = Rubot::Agent.new(
      config: Rubot::Config.new(config_path),
      provider: CronProvider.new,
      session_id: "background-report"
    )

    response = agent.process_background("## writer\npuisi jadi",
                                        label: "Hasil subagent yang sudah selesai:\n\n")

    assert_equal "cron answer", response
    roles = agent.session.messages.map { |message| message["role"] }
    assert_equal [ "assistant" ], roles, "only the answer joins the transcript"
    assert_includes agent.session.messages.first["content"], "cron answer"
    refute_includes agent.session.messages.first["content"], "puisi jadi"
    assert agent.session.messages.first["background"],
           "the reply is stamped as one nobody prompted, so the page can give it its own block"
  end

  # A provider that answers only by streaming: asking the background turn to
  # hand its answer over passage by passage must go through `chat_stream`, or
  # the reader gets the whole thing at once after the full wait.
  class StreamingBackgroundProvider
    def name
      "openai"
    end

    def chat(_messages, tools: nil, on_retry: nil)
      raise "a background turn with a block must stream"
    end

    def chat_stream(_messages, tools: nil, on_retry: nil)
      yield "Halo", nil, nil
      yield " dunia", nil, nil
      { "content" => "Halo dunia", "finish_reason" => "stop" }
    end
  end

  def test_a_background_turn_hands_its_answer_over_as_it_is_written
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(@tmpdir, "stream-config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "workspace" => workspace } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)

    agent = Rubot::Agent.new(
      config: Rubot::Config.new(config_path),
      provider: StreamingBackgroundProvider.new,
      session_id: "background-stream"
    )

    written = []
    response = agent.process_background("hasil subagent") { |text| written << text }

    assert_equal "Halo dunia", response
    assert_equal [ "Halo", "Halo dunia" ], written,
                 "each call carries the passage so far, so a repaint cannot lose a word"
  end

  def test_uses_configured_limit_instead_of_hardcoded_ten
    agent = build_agent(max_rounds: 3)

    assert_equal 3, agent.config.max_rounds

    response = agent.process("loop forever", stream: false)

    assert_equal 3, agent.provider.calls, "expected exactly 3 LLM round-trips"
    assert_includes response, "stopped after 3 rounds",
                    "the notice names the limit that was hit"
    assert_includes response, "lanjut",
                    "and says how to carry on, in the language the reader uses"
  end

  # The limit is a net under a runaway loop, not a budget for a piece of work.
  # To ask for "continue" repeatedly is the failure this number is set high to
  # avoid; a turn that really has gone wrong is stopped by the reader.
  def test_the_default_limit_is_a_last_resort_not_a_budget
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "workspace" => workspace } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)

    limit = Rubot::Config.new(config_path).max_rounds

    assert_equal 1000, limit
    assert_operator limit, :>=, 500,
                    "a real read-edit-test cycle must not spend it"
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

    def chat(_messages, tools: nil, on_retry: nil)
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

    def chat_stream(messages, tools: nil, on_retry: nil, &_on_chunk)
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
      def chat(_messages, tools: nil, on_retry: nil)
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

  # A round trip is the expensive part of a turn, so the batching rule is
  # restated as the very last thing in the prompt: measured on this model, the
  # same rule buried in the middle of a long prompt produced one or two calls
  # per message, while repeating it at the end produced all four.
  def test_system_prompt_ends_with_the_batching_reminder
    prompt = @agent.build_system_prompt

    assert_includes prompt, "# Before You Send"
    assert_includes prompt, "Count the tool calls you are about to make"
    assert prompt.rstrip.end_with?(Rubot::Agent::BATCH_REMINDER),
           "the reminder has to be the last thing the model reads"
  end

  # The rule is the request, not the clock: an unprompted announcement repeats
  # what the reader already sees. The one exception is a standing request for a
  # notification at the end of every turn — and nothing smaller counts as it.
  def test_system_prompt_never_announces_a_turn_on_its_own_initiative
    prompt = @agent.build_system_prompt
    assert_includes prompt, "Announcing the End of a Turn"
    assert_includes prompt, "on your own initiative"
  end

  def test_system_prompt_allows_per_turn_notifications_only_when_asked
    prompt = @agent.build_system_prompt
    assert_includes prompt, "notified at the end of every turn"
    assert_includes prompt, "counts as that request"
  end

  # The rule names a tool, so it must travel only when that tool can be called:
  # a prompt sentence the model has no way to obey is worse than none.
  def test_notify_rule_is_left_out_when_the_tool_is_not_available
    bare = Rubot::Tools::Registry.new
    bare.clear

    agent = Rubot::Agent.new(
      config: @config,
      provider: NarratingProvider.new,
      session_id: "no-notify",
      tools: bare
    )

    refute_includes agent.build_system_prompt, "Announcing the End of a Turn"
  end

  def test_system_prompt_asks_for_ruby_scripts_instead_of_python
    prompt = @agent.build_system_prompt
    assert_includes prompt, "Scripting Language"
    assert_includes prompt, "Write every script, helper, and one-off snippet in Ruby"
    assert_includes prompt, "Do not write new Python"
  end

  # How to send files is decided before the model reads a description, so the
  # rule lives in the prompt with the other one-rule-for-one-job entries. It was
  # learned the hard way: "kirim 5 gambar" once arrived as five separate calls,
  # and a "3 gambar" of my own as one call plus a pair.
  def test_system_prompt_sends_a_batch_with_one_call
    prompt = @agent.build_system_prompt

    assert_includes prompt, "Sending Files"
    assert_includes prompt, "`send_files` hands local files to the user in one call"
    assert_includes prompt, "one entry for a single file, several for"
    assert_includes prompt, "one round trip per file"
    refute_includes prompt, "`send_file`"
  end

  # config.yml can turn the delivery tool off. The rule must follow the tool
  # list: naming `send_files` when the model cannot call it is what made a batch
  # of twelve pictures arrive as twelve separate calls.
  def test_system_prompt_leaves_the_delivery_rule_out_when_the_tool_is_disabled
    no_delivery = Rubot::Tools::Registry.new
    no_delivery.clear
    no_delivery.register(Rubot::Tools::Notify.new)

    agent = Rubot::Agent.new(
      config: @config,
      provider: NarratingProvider.new,
      session_id: "no-delivery",
      tools: no_delivery
    )

    prompt = agent.build_system_prompt
    refute_includes prompt, "Sending Files"
    refute_includes prompt, "send_files", "prompt names a tool the model cannot call"
  end

  # SOUL.md is written with its own "# Soul" heading (Soul::DEFAULT_SOUL has
  # one), and the prompt adds another — the heading was sent twice, one above
  # the other, which reads as two sections.
  def test_system_prompt_sends_the_soul_heading_once
    File.write(File.join(@config.assets_workspace, "SOUL.md"),
               "# Soul\n\nYou are Rubot, written in Ruby.\n")

    agent = Rubot::Agent.new(
      config: @config,
      provider: NarratingProvider.new,
      session_id: "soul-heading",
      tools: @tools
    )

    prompt = agent.build_system_prompt
    assert_equal 1, prompt.scan(/^#\s+Soul$/).size, "the soul heading is repeated"
    assert_includes prompt, "You are Rubot, written in Ruby."
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

  # The system prompt sits at the front of every request, so rebuilding it is
  # not free: measured against the same gateway, an edit anywhere inside the
  # system message took the prompt cache from 99% to 0%. Memory extraction
  # rewrites MEMORY.md after most turns and the composed prompt quoted it, so
  # the prefix moved constantly and a session that was never trimmed could
  # still run at a 0% cache hit on a 54k-token prompt.
  def test_the_system_prompt_is_pinned_instead_of_rebuilt_every_request
    File.write(@config.global_memory_path, "## Facts\n\n- a fact from before\n")
    agent = Rubot::Agent.new(config: @config, provider: NarratingProvider.new,
                             session_id: "pin", tools: @tools)
    agent.session.add("user", "Kerjakan nomor 6 dulu")

    first = agent.build_system_prompt
    assert_includes first, "a fact from before"

    agent.memory.append("Facts", "a fact learned after the session started")

    assert_equal first, agent.build_system_prompt,
                 "the prompt must not move when memory changes mid-session"
    refute_includes agent.build_system_prompt, "a fact learned after the session started"
  end

  # The door out of the pin: memory written mid-session (or an edited skill)
  # reaches the model only when the epoch moves or a reader asks. Asking must
  # rebuild, and it must say whether there was anything to rebuild — the cost of
  # the request is paid either way.
  def test_repinning_the_prompt_picks_up_memory_written_mid_session
    File.write(@config.global_memory_path, "## Facts\n\n- a fact from before\n")
    agent = Rubot::Agent.new(config: @config, provider: NarratingProvider.new,
                             session_id: "repin", tools: @tools)
    agent.session.add("user", "Kerjakan nomor 6 dulu")
    agent.build_system_prompt
    agent.memory.append("Facts", "a fact learned after the session started")

    refute_includes agent.build_system_prompt, "a fact learned after the session started"

    assert agent.repin_system_prompt, "asking to repin must report that it did something"
    refute agent.repin_system_prompt, "clearing twice with no rebuild in between is a no-op"
    assert_includes agent.build_system_prompt, "a fact learned after the session started",
                    "the next prompt is built from the files as they are now"
  end

  # A restart must not throw the pin away: the whole point is that the bytes
  # stay the same, and a new process rebuilding them would undo it.
  def test_the_pin_survives_a_restart
    agent = Rubot::Agent.new(config: @config, provider: NarratingProvider.new,
                             session_id: "pin-restart", tools: @tools)
    agent.session.add("user", "Kerjakan nomor 6 dulu")
    first = agent.build_system_prompt

    reopened = Rubot::Agent.new(config: @config, provider: NarratingProvider.new,
                                session_id: "pin-restart", tools: @tools)

    assert_equal first, reopened.build_system_prompt
  end

  # The pin has to move for the inputs the model cannot go without.
  def test_compaction_moves_the_pin_so_the_new_summary_reaches_the_model
    @agent.session.add("user", "Kerjakan nomor 6 dulu")
    before = @agent.build_system_prompt

    @agent.session.summary = "Ringkasan percakapan yang baru"

    refute_equal before, @agent.build_system_prompt
    assert_includes @agent.build_system_prompt, "Ringkasan percakapan yang baru"
  end

  # The model name is quoted in the prompt, so a switch has to rebuild it.
  def test_the_epoch_tracks_the_model_the_summary_and_the_forced_skill
    @agent.session.add("user", "Kerjakan nomor 6 dulu")
    epoch = @agent.send(:system_prompt_epoch)

    assert_equal @agent.active_model_name.to_s, epoch["model"]
    assert_equal "", epoch["task"],
                 "the transcript still carries the request, so there is no anchor to pin"
    assert_equal "", epoch["summary"], "no summary yet, so nothing to pin it to"
    assert_equal "", epoch["persona"], "no persona, so nothing to fingerprint"

    @agent.session.summary = "Ringkasan"
    @agent.session.forced_skill = "review"

    moved = @agent.send(:system_prompt_epoch)
    refute_equal epoch["summary"], moved["summary"]
    assert_equal "review", moved["skill"]
  end

  # Volatile content lives at the tail so that when the pin does move, the
  # provider still finds a cached prefix in front of the changed block.
  def test_memory_is_the_last_section_of_the_prompt
    File.write(@config.global_memory_path, "## Facts\n\n- a fact that changes often\n")
    agent = Rubot::Agent.new(config: @config, provider: NarratingProvider.new,
                             session_id: "pin-tail", tools: @tools)
    agent.session.add("user", "Kerjakan nomor 6 dulu")

    prompt = agent.build_system_prompt

    assert_operator prompt.index("# Current Model"), :<, prompt.index("a fact that changes often"),
                    "memory must come after the stable sections"
    assert_equal prompt.rindex("a fact that changes often"),
                 prompt.index("a fact that changes often"),
                 "memory is quoted once"
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

  # Skills are shared, so the persona is what says which of them apply.
  def test_persona_skills_are_named_in_the_prompt
    persona = Rubot::Persona.new(
      name: "kanyaah",
      skills: %w[kanyaah-brand marketing-strategist]
    )
    agent = build_agent(persona: persona.to_h)

    prompt = agent.build_system_prompt

    assert_includes prompt, "# Required Skills"
    assert_includes prompt, "kanyaah-brand, marketing-strategist"
  end

  def test_a_persona_without_skills_adds_no_skill_block
    agent = build_agent(persona: trading_persona.to_h)

    refute_includes agent.build_system_prompt, "# Required Skills"
  end

  def test_persona_without_prompt_keeps_the_config_prompt
    agent = build_agent(persona: { "model" => "model-b" })

    prompt = agent.build_system_prompt

    refute_includes prompt, "# Persona"
    assert_includes prompt, "GLOBAL DEFAULT PROMPT"
  end

  # A persona is identity, not context. Switching to another one that keeps the
  # same model used to leave the pinned prompt alone — the epoch tracked only
  # the model — so the old persona went on answering for the rest of the
  # session while /persona said it had changed.
  def test_switching_persona_with_the_same_model_rebuilds_the_prompt
    agent = build_agent(persona: persona_at("model-a", "Kamu adalah asisten trading.").to_h)
    assert_includes agent.build_system_prompt, "asisten trading"

    agent.apply_persona(persona_at("model-a", "Kamu adalah asisten marketing.").to_h)

    assert_equal "gpt-4o-mini", agent.active_model_name,
                 "the model must not be what carries this change"
    prompt = agent.build_system_prompt
    assert_includes prompt, "asisten marketing"
    refute_includes prompt, "asisten trading"
  end

  # The same hole, seen from the other side: removing a persona while staying
  # on the model it chose left the persona's words in the pinned prompt.
  def test_resetting_a_persona_with_the_same_model_drops_its_prompt
    agent = build_agent(persona: persona_at("model-a", "Kamu adalah asisten trading.").to_h)
    assert_includes agent.build_system_prompt, "asisten trading"

    agent.apply_persona(nil)

    assert_equal "gpt-4o-mini", agent.active_model_name, "only the persona moved"
    prompt = agent.build_system_prompt
    refute_includes prompt, "asisten trading"
    assert_includes prompt, "GLOBAL DEFAULT PROMPT"
  end

  # The skills a persona exists to use are quoted in the prompt, so they belong
  # in the fingerprint beside its instructions.
  def test_switching_the_skills_of_a_persona_rebuilds_the_prompt
    agent = build_agent(persona: { "name" => "kanyaah", "model" => "model-a",
                                   "skills" => %w[kanyaah-brand] }.to_h)
    assert_includes agent.build_system_prompt, "kanyaah-brand"

    agent.apply_persona({ "name" => "kanyaah", "model" => "model-a",
                          "skills" => %w[marketing-strategist] }.to_h)

    prompt = agent.build_system_prompt
    assert_includes prompt, "marketing-strategist"
    refute_includes prompt, "kanyaah-brand"
  end

  # The listing is where a skill announces itself, so a skill a persona
  # switched off is not advertised with its description and location. It is
  # still named once, as switched off: its file is on disk, so a model told
  # "use the writing skill" could otherwise open it by hand.
  def test_a_switched_off_skill_is_not_listed_in_the_prompt
    install_skill("kept-skill")
    install_skill("switched-off-skill")

    agent = build_agent(persona: { "name" => "kanyaah", "model" => "model-a",
                                   "disabled_skills" => "switched-off-skill" })

    prompt = agent.build_system_prompt

    assert_includes prompt, "kept-skill"
    refute_includes prompt, "Instruksi switched-off-skill", "the description is not offered as a task match"
    refute_includes prompt, "skills/switched-off-skill/SKILL.md", "the model is not handed the file path"

    assert_includes prompt, "# Skills Switched Off"
    assert_includes prompt, "skills switched off: switched-off-skill"
    assert_includes prompt, "insists"
  end

  # Requiring a skill wins over switching it off, so the two lists cannot
  # contradict each other: it stays listed and is never called switched off.
  def test_a_required_skill_stays_on_and_is_not_called_switched_off
    install_skill("kept-skill")

    agent = build_agent(persona: { "name" => "kanyaah", "model" => "model-a",
                                   "skills" => %w[kept-skill],
                                   "disabled_skills" => "kept-skill" })

    prompt = agent.build_system_prompt

    assert_includes prompt, "Instruksi kept-skill"
    refute_includes prompt, "# Skills Switched Off"
  end

  # Switching one off is a change to the pinned prompt, not just to the next
  # build: an open session has to let go of the skill it was advertised.
  def test_switching_a_skill_off_rebuilds_the_prompt
    install_skill("kept-skill")

    agent = build_agent(persona: { "name" => "kanyaah", "model" => "model-a" })
    assert_includes agent.build_system_prompt, "Instruksi kept-skill"

    agent.apply_persona({ "name" => "kanyaah", "model" => "model-a",
                          "disabled_skills" => "kept-skill" })

    refute_includes agent.build_system_prompt, "Instruksi kept-skill"
  end

  # /use can name anything the registry knows, so a forced skill has to be
  # checked against the persona too — otherwise the switch is cosmetic. The
  # refusal replaces the skill's instructions, so the user is told rather than
  # answered as if the request never happened.
  def test_a_switched_off_skill_is_not_forced_into_the_turn
    install_skill("switched-off-skill")

    agent = build_agent(persona: { "name" => "kanyaah", "model" => "model-a",
                                   "disabled_skills" => "switched-off-skill" })
    agent.session.forced_skill = "switched-off-skill"

    prompt = agent.build_system_prompt

    refute_includes prompt, "# Active Skill: switched-off-skill"
    refute_includes prompt, "Isi switched-off-skill", "its instructions never reach the turn"

    assert_includes prompt, "# Refused Skill: switched-off-skill"
    assert_nil agent.session.forced_skill, "the flag is spent even when it is refused"
  end

  # The refusal is one turn long: a skill left on afterwards is forced as
  # usual, so the switch does not stick to the session.
  def test_a_skill_left_on_is_still_forced
    install_skill("kept-skill")

    agent = build_agent(persona: { "name" => "kanyaah", "model" => "model-a",
                                   "disabled_skills" => "switched-off-skill" })
    agent.session.forced_skill = "kept-skill"

    prompt = agent.build_system_prompt

    assert_includes prompt, "# Active Skill: kept-skill"
    assert_includes prompt, "Isi kept-skill"
    refute_includes prompt, "# Refused Skill"
  end

  # Skills are read from the shared directory beside config.yml, the same one
  # every persona draws on.
  def install_skill(name)
    dir = File.join(@tmpdir, "skills", name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"),
               "---\nname: #{name}\ndescription: Instruksi #{name}\n---\n\nIsi #{name}.\n")
  end

  def persona_at(model, prompt)
    Rubot::Persona.new(name: "trading", model: model, system_prompt: prompt)
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
