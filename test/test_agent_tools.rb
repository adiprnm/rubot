# frozen_string_literal: true

require_relative "test_helper"

# What a turn does with tools: cancelling it, parallel calls, steering mid-flight, the diff it returns and auto mode.
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

    def chat(_messages, tools: nil, on_retry: nil)
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
          "name" => "file_read",
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

    def chat(_messages, tools: nil, on_retry: nil)
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

    def chat(_messages, tools: nil, on_retry: nil)
      { "content" => "done" }
    end

    def chat_stream(_messages, tools: nil, on_retry: nil, &on_chunk)
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
    assert_equal 1, seen.count("file_read"), "only the first tool runs"
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


class TestAgentParallelToolCalls < Minitest::Test
  # Answers one round with several tool calls, then finishes. The commands are
  # the knobs: sleeping makes the wall time readable, echoing makes the order.
  class BatchProvider
    attr_reader :calls

    def initialize(commands)
      @commands = commands
      @calls = 0
    end

    def name
      "openai"
    end

    def chat(_messages, tools: nil, on_retry: nil)
      @calls += 1
      return { "content" => "all done" } if @calls > 1

      {
        "content" => "Running them.",
        "tool_calls" => @commands.each_with_index.map do |command, index|
          {
            "id" => "call_#{index}",
            "type" => "function",
            "function" => {
              "name" => "shell_exec",
              "arguments" => JSON.generate({ "command" => command })
            }
          }
        end
      }
    end
    alias chat_stream chat
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

  def build_agent(commands)
    Rubot::Agent.new(config: @config, provider: BatchProvider.new(commands), session_id: "parallel")
  end

  # A batch is only worth sending if answering it costs one round trip instead
  # of a queue: three half-second commands must finish in about half a second.
  def test_independent_tool_calls_run_at_the_same_time
    agent = build_agent([ "sleep 0.6", "sleep 0.6", "sleep 0.6" ])

    before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    agent.process("do three things", stream: false)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before

    assert_operator elapsed, :<, 1.4,
                    "three 0.6s calls must overlap, not add up (#{elapsed.round(2)}s)"
    assert_equal 2, agent.provider.calls
  end

  # Running them together must not shuffle the transcript: the provider
  # requires one result per call, and the reader sees the answers in the order
  # the model asked for them.
  def test_results_keep_the_request_order
    agent = build_agent([ "echo first", "echo second", "echo third" ])

    agent.process("do three things", stream: false)

    results = agent.session.messages.select { |m| m["role"] == "tool" }.map { |m| m["content"] }
    assert_equal 3, results.size
    assert_match(/first/, results[0])
    assert_match(/second/, results[1])
    assert_match(/third/, results[2])
  end
end


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

    def chat(messages, tools: nil, on_retry: nil)
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

    def chat_stream(messages, tools: nil, on_retry: nil, &on_chunk)
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

    def chat(_messages, tools: nil, on_retry: nil)
      @calls += 1
      return { "content" => "done" } if @calls > 1

      {
        "content" => "",
        "tool_calls" => [
          {
            "id" => "call_1",
            "type" => "function",
            "function" => {
              "name" => %w[edit write append delete].include?(@operation) ? "file_write" : "file_read",
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

  # Only a write has something to replay. A read is quiet: no snapshot, no
  # diff, nothing for the transcript to draw under the row.
  def test_a_read_produces_no_ui_diff
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      path = File.join(workspace, "notes.md")
      File.write(path, "one\ntwo\n")

      agent = run_write(workspace, path, WriteProvider.new(path, operation: "read", content: nil))
      tool = agent.session.messages.find { |msg| msg["role"] == "tool" }

      assert_includes tool["content"], "one"
      refute tool.key?("ui_diff"), "a read is not replayed as a diff"
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

    def chat(_messages, tools: nil, on_retry: nil)
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

    def chat_stream(messages, tools: nil, on_retry: nil, &_on_chunk)
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


# Asking is not rationed: a turn may interrupt the reader as often as the work
# needs, and every one of those questions is put to them. What limits a turn is
# the user's own answer — a cancellation ends it — not a counter inside it.
class TestAgentAsksWithoutACeiling < Minitest::Test
  # One more than the ceiling this change removed (five questions a turn). Six
  # is what makes the test mean something: at five the old code passes too.
  ROUNDS = 6

  # One question per provider round, so every round is a separate call.
  class AskingProvider
    attr_reader :calls

    def initialize(rounds)
      @rounds = rounds
      @calls = 0
    end

    def name
      "openai"
    end

    def chat(_messages, tools: nil, on_retry: nil)
      @calls += 1
      return { "content" => "all answered" } if @calls > @rounds

      {
        "content" => "Asking.",
        "tool_calls" => [
          {
            "id" => "call_#{@calls}",
            "type" => "function",
            "function" => {
              "name" => "ask_user",
              "arguments" => JSON.generate({
                "questions" => [
                  { "question" => "Round #{@calls}: which one?",
                    "options" => [ { "label" => "A" }, { "label" => "B" } ] }
                ]
              })
            }
          }
        ]
      }
    end
    alias chat_stream chat
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @config = isolated_config(@tmpdir, name: "asking")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def test_every_question_of_a_turn_reaches_the_reader
    agent = Rubot::Agent.new(config: @config, provider: AskingProvider.new(ROUNDS), session_id: "asking")
    asked = []
    reader = ->(payload) { asked << payload[:question]; { outcome: :option, index: 0, label: "A" } }

    agent.process("ask me a few things", stream: false, on_ask: reader)

    assert_equal ROUNDS, asked.size, "the last question must be asked, not refused"
    assert_equal ROUNDS + 1, agent.provider.calls, "one round per question, then the closing answer"
    results = agent.session.messages.select { |m| m["role"] == "tool" }.map { |m| m["content"] }
    assert_equal ROUNDS, results.size
    results.each { |content| assert_includes content, "The user chose: A" }
  end
end

# A tools list is the declaration of what an agent may call. A list that names
# nothing, or names a tool this install does not have, is an error rather than
# a silent "everything" or a silently ignored entry.
class TestAgentToolList < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def agent_with(tools)
    config_path = File.join(@tmpdir, "config.yml")
    File.write(config_path, {
      "agents" => { "defaults" => { "workspace" => @workspace } },
      "models" => [
        { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" }
      ],
      "tools" => tools
    }.to_yaml)
    Rubot::Agent.new(config: Rubot::Config.new(config_path), session_id: "tools",
                     provider: OneCallProvider.new)
  end

  class OneCallProvider
    def name
      "openai"
    end

    def chat(_messages, tools: nil, on_retry: nil)
      { "content" => "nothing to do" }
    end
    alias chat_stream chat
  end

  # The list is config, so a mistake in it fails the build rather than the
  # first turn that happens to ask for definitions.
  def test_an_empty_tools_list_fails_when_the_agent_is_built
    error = assert_raises(ArgumentError) { agent_with({}) }

    assert_match(/names no tool/, error.message)
  end

  def test_a_stale_tool_name_fails_when_the_agent_is_built
    error = assert_raises(ArgumentError) { agent_with({ "file_ops" => { "enabled" => true } }) }

    assert_match(/file_ops/, error.message)
  end

  def test_a_named_list_offers_exactly_what_it_names
    names = agent_with({ "file_read" => { "enabled" => true },
                         "file_write" => { "enabled" => true } })
            .tool_definitions.map(&:name)

    assert_includes names, "file_read"
    assert_includes names, "file_write"
    refute_includes names, "shell_exec", "a tool the list does not name is not offered"
    refute_includes names, "delegate"
  end
end
