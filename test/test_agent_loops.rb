# frozen_string_literal: true

require_relative "test_helper"

# The agent's half of a loop hand-off: a tool that cannot hold a runner asks
# the agent, and the agent calls its channel callback with plain data. No
# model, no Ractor: the callback records what it was given.
class TestAgentLoops < Minitest::Test
  # The agent never gets as far as the provider here, but a sub agent or a
  # process() call would build one, and nothing in this file may reach a
  # network.
  class FakeProvider
    attr_reader :name

    def initialize = @name = "fake"

    def chat(_messages, tools: nil, on_retry: nil)
      { "content" => "ok" }
    end

    def chat_stream(messages, tools: nil, on_retry: nil, &_block)
      chat(messages, tools: tools)
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("rubot-agent-loops")
    @config = isolated_config(@tmpdir)
    @agent = Rubot::Agent.new(config: @config, provider: FakeProvider.new, session_id: "lead")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  # -- the hand-off ----------------------------------------------------------

  def test_the_request_is_plain_data_and_the_model_is_told_the_loop_goes_on_without_it
    requests = []
    @agent.on_loop = ->(request) { requests << request }

    answer = @agent.request_loop(op: :start, id: "20260101-000000-a001")

    assert_equal 1, requests.size
    request = requests.first
    assert_equal %i[op id parent_session slug], request.keys
    assert_equal :start, request[:op]
    assert_equal "20260101-000000-a001", request[:id]
    assert_equal "lead", request[:parent_session]
    assert(request.values.all? { |value| value.is_a?(String) || value.is_a?(Symbol) }, request.inspect)

    assert_kind_of String, answer
    assert_includes answer, "background", "the model has to know the work continues without it"
    assert_includes answer, "status", "and where the progress is"
    assert_includes answer, "on its own", "and that it need not wait for the answer"
  end

  def test_a_resume_and_a_stop_travel_as_symbols_and_answer_about_themselves
    requests = []
    @agent.on_loop = ->(request) { requests << request }

    resumed = @agent.request_loop(op: :resume, id: "loop-1")
    stopped = @agent.request_loop(op: :abort, id: "loop-1")

    assert_equal %i[resume abort], requests.map { |request| request[:op] }
    assert_includes resumed, "resumed"
    assert_includes stopped, "stop"
  end

  def test_no_callback_means_no_runner_and_nil_is_the_signal
    assert_nil @agent.on_loop
    assert_nil @agent.request_loop(op: :start, id: "loop-1")
  end

  # A sub agent that starts a loop hands back an answer while the work it began
  # keeps spending tokens with nobody watching it.
  def test_a_sub_agent_session_refuses_and_never_calls_the_callback
    requests = []
    @agent.on_loop = ->(request) { requests << request }
    @agent.instance_variable_set(:@subagent_depth, 1)

    answer = @agent.request_loop(op: :start, id: "loop-1")

    assert_kind_of String, answer
    assert_includes answer, "sub agent"
    assert_empty requests, "the callback must not be reached from a sub agent"
  end

  def test_an_operation_a_runner_cannot_perform_is_refused_without_calling_out
    requests = []
    @agent.on_loop = ->(request) { requests << request }

    answer = @agent.request_loop(op: :list, id: "")

    assert_includes answer, "unknown loop operation"
    assert_empty requests
  end

  # The tool owes the model a string either way, so a callback that blew up is
  # an answer, not an exception in the middle of the turn.
  def test_a_callback_that_raises_still_leaves_the_tool_a_string
    @agent.on_loop = ->(_request) { raise "no pool on this side" }

    answer = @agent.request_loop(op: :start, id: "loop-1")

    assert_kind_of String, answer
    assert_includes answer, "no pool on this side"
  end
end
