# frozen_string_literal: true

require_relative "test_helper"

# The shape of a turn: how often the provider is asked, and the order in which
# the channel is told what happened.
#
# F5 moves #process into named phases. The one thing that must not move with it
# is this: the number of requests, the round each tool ran in, and the sequence
# of callbacks a channel receives. A phase that runs in the wrong order still
# answers, still passes the behavioural tests, and only shows up as a timeline
# that draws a tool row before the sentence that introduced it — or as a turn
# that quietly asks the model one more time than it used to.
class TestTurnShape < Minitest::Test
  # Answers with whatever the script holds, in order, and records every request
  # it was asked. Running out of script means the turn asked more than it should.
  class ScriptedProvider
    attr_reader :requests

    def initialize(script)
      @script = script.dup
      @requests = []
    end

    def name
      "openai"
    end

    def last_usage
      { "prompt_tokens" => 20, "completion_tokens" => 5 }
    end

    def chat(messages, tools: nil, on_retry: nil)
      @requests << messages
      raise "the provider was asked for more than the script holds" if @script.empty?

      @script.shift
    end
    alias chat_stream chat
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def build_agent(script, max_rounds: 6)
    path = File.join(@tmpdir, "config.yml")
    File.write(path, {
      "agents" => { "defaults" => { "workspace" => @workspace, "max_rounds" => max_rounds } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)
    provider = ScriptedProvider.new(script)
    [ Rubot::Agent.new(config: Rubot::Config.new(path), provider: provider, session_id: "shape"), provider ]
  end

  def list_call(id = "call_1")
    {
      "id" => id,
      "type" => "function",
      "function" => {
        "name" => "file_ops",
        "arguments" => JSON.generate({ "operation" => "list", "path" => @workspace })
      }
    }
  end

  # Runs one turn and returns the answer with the callbacks it produced, in
  # order. Usage is left out on purpose: it is published on its own cadence and
  # says nothing about the order the channel has to draw things in.
  def run_turn(agent, message = "halo")
    events = []
    answer = agent.process(
      message,
      stream: false,
      on_assistant_text: ->(text) { events << [ :text, text.to_s ] },
      on_tool_call: ->(name, _args, _snapshot) { events << [ :call, name ] },
      on_tool_result: ->(name, _result, _diff) { events << [ :result, name ] },
      on_steer: ->(text) { events << [ :steer, text.to_s ] },
      on_stopped: -> { events << [ :stopped ] },
      on_progress: ->(round, count) { events << [ :progress, round, count ] }
    )
    [ answer, events ]
  end

  # A turn that needs no tool is one request, and the answer is its return
  # value: nothing is narrated, because there is nothing happening before it.
  def test_a_plain_answer_is_one_request_and_no_events
    agent, provider = build_agent([ { "content" => "halo juga", "finish_reason" => "stop" } ])
    answer, events = run_turn(agent)

    assert_equal 1, provider.requests.size
    assert_equal "halo juga", answer
    assert_equal [], events
  end

  # One call: the narration arrives first, then the row, then its result, then
  # the round's progress. The answer is a second request.
  def test_one_tool_call_is_narrated_then_run_then_answered
    agent, provider = build_agent([
      { "content" => "Checking.", "tool_calls" => [ list_call ] },
      { "content" => "done", "finish_reason" => "stop" }
    ])
    answer, events = run_turn(agent)

    assert_equal 2, provider.requests.size
    assert_equal "done", answer
    assert_equal [
      [ :text, "Checking." ],
      [ :call, "file_ops" ],
      [ :result, "file_ops" ],
      [ :progress, 1, 1 ]
    ], events
  end

  # A batch runs as a batch: both calls are announced before either result
  # exists, and the progress line carries how many the round ran.
  def test_a_batch_announces_every_call_before_any_result
    agent, provider = build_agent([
      { "content" => "Batch.", "tool_calls" => [ list_call("a"), list_call("b") ] },
      { "content" => "done", "finish_reason" => "stop" }
    ])
    _answer, events = run_turn(agent)

    assert_equal 2, provider.requests.size
    assert_equal [
      [ :text, "Batch." ],
      [ :call, "file_ops" ],
      [ :call, "file_ops" ],
      [ :result, "file_ops" ],
      [ :result, "file_ops" ],
      [ :progress, 1, 2 ]
    ], events
  end

  # The round limit is a hard stop: the script holds a third request but the
  # turn must never ask for it, and the reader is told why there is no answer.
  def test_the_round_limit_stops_before_another_request
    agent, provider = build_agent(
      Array.new(3) { { "content" => "Round.", "tool_calls" => [ list_call ] } },
      max_rounds: 2
    )
    answer, events = run_turn(agent)

    assert_equal 2, provider.requests.size,
                 "a turn of two rounds must not ask the provider a third time"
    assert_includes answer, "stopped after 2 rounds"
    assert_equal [
      [ :text, "Round." ],
      [ :call, "file_ops" ],
      [ :result, "file_ops" ],
      [ :progress, 1, 1 ],
      [ :text, "Round." ],
      [ :call, "file_ops" ],
      [ :result, "file_ops" ],
      [ :progress, 2, 1 ]
    ], events
  end
end
