# frozen_string_literal: true

require_relative "test_helper"

# One iteration of a loop is a turn, but not a conversation: it is a step the
# loop will ask for again, and every request inside it re-sends the whole
# context. These tests hold the two consequences: an iteration stops at its own
# round cap (40 by default) and is allowed one closing round to say where it got,
# and it never buys a compaction for a transcript that is thrown away when the
# turn ends. An ordinary turn keeps both behaviours it always had.
class TestLoopIterationTurn < Minitest::Test
  # Answers from a script, in order, and records what each request carried --
  # the messages and the tools on offer -- because the closing round is defined
  # by having no tools at all.
  class ScriptedProvider
    attr_reader :requests, :offers

    def initialize(script)
      @script = script.dup
      @requests = []
      @offers = []
    end

    def name = "openai"

    def last_usage
      { "prompt_tokens" => 20, "completion_tokens" => 5 }
    end

    def chat(messages, tools: nil, on_retry: nil)
      @requests << messages
      @offers << (tools || [])
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

  def build_agent(script, session_id:, defaults: {})
    path = File.join(@tmpdir, "config.yml")
    File.write(path, {
      "agents" => { "defaults" => { "workspace" => @workspace }.merge(defaults) },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)
    provider = ScriptedProvider.new(script)
    agent = Rubot::Agent.new(config: Rubot::Config.new(path), provider: provider, session_id: session_id)
    [ agent, provider ]
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

  def tool_round(id)
    { "content" => "Checking.", "tool_calls" => [ list_call(id) ] }
  end

  # -- the cap ---------------------------------------------------------------

  # The number is a setting because a loop is not a conversation: 1000 rounds
  # is a net under a runaway turn, and an iteration that reaches it has already
  # spent the loop's budget several times over.
  def test_a_loop_iteration_is_capped_at_forty_rounds_by_default
    iteration, = build_agent([], session_id: "loop-20260101-abc~a1~it1")
    ordinary, = build_agent([], session_id: "chatter")

    assert_equal 40, iteration.turn_round_limit
    assert_equal Rubot::Config::DEFAULT_LOOP_MAX_ROUNDS, iteration.turn_round_limit
    assert_equal 1000, ordinary.turn_round_limit, "a normal turn keeps max_rounds"
  end

  def test_the_cap_follows_the_setting
    agent, = build_agent([], session_id: "loop-abc~a1~it1",
                             defaults: { "max_rounds" => 120, "loop_max_rounds" => 7 })

    assert_equal 7, agent.turn_round_limit
    assert_equal 7, agent.config.loop_max_rounds
  end

  # The whole behaviour: two tool rounds are the cap, and the third request is
  # the closing one -- no tools, the instruction in front of it, and the answer
  # it writes is what the turn ends with.
  def test_an_iteration_stops_at_its_cap_with_one_round_to_close_out
    agent, provider = build_agent(
      [ tool_round("call_1"), tool_round("call_2"), { "content" => "done 2 of 5; next: the tests" } ],
      session_id: "loop-abc~a1~it1", defaults: { "loop_max_rounds" => 2 }
    )

    answer = agent.process("work a step", stream: false)

    assert_equal 3, provider.requests.size, "two working rounds and exactly one closing round"
    assert_equal 2, provider.offers.count { |tools| !tools.empty? }, "the closing round offers no tools"
    assert_empty provider.offers.last
    assert_includes provider.requests.last.last["content"], "round cap",
                    "the closing round says why it cannot call a tool"
    assert_includes answer, "done 2 of 5; next: the tests", "the closing answer is the turn's answer"
    assert_includes answer, "stopped at its round cap (2)"
    refute_includes answer, "Say \"lanjut\"", "a loop is not continued by a reader typing"
    assert_equal({ rounds: 2, limit: 2 }, agent.last_round_cap)
  end

  # A turn outside a loop is unchanged: the cap is a hard stop, no closing round
  # is bought, and the notice is the one it always had.
  def test_an_ordinary_turn_keeps_the_hard_stop
    agent, provider = build_agent(
      [ tool_round("call_1"), tool_round("call_2"), { "content" => "must never be asked" } ],
      session_id: "chatter", defaults: { "max_rounds" => 2 }
    )

    answer = agent.process("halo", stream: false)

    assert_equal 2, provider.requests.size, "no closing round outside a loop"
    assert_includes answer, "stopped after 2 rounds"
    assert_includes answer, "Say \"lanjut\""
    assert_nil agent.last_round_cap
  end

  # -- compaction ------------------------------------------------------------

  # Compaction is a request in the middle of a turn that rewrites the
  # conversation, which is exactly what an iteration cannot pay for: the session
  # is thrown away when the turn ends, so the summary would never be read, and
  # the rewrite breaks the prefix the rest of that turn was still hitting cache
  # on. The proof is at the provider: an ordinary session asks for its summary,
  # an iteration session asks for nothing.
  def test_a_loop_iteration_never_compacts_while_an_ordinary_session_does
    defaults = {
      "compaction" => { "auto" => true, "threshold_tokens" => 1, "keep_recent_messages" => 1 }
    }
    summary = { "content" => "the conversation so far, in a sentence" }
    iteration, iteration_provider = build_agent([ summary ], session_id: "loop-abc~a1~it1",
                                                             defaults: defaults)
    ordinary, ordinary_provider = build_agent([ summary ], session_id: "chatter", defaults: defaults)
    [ iteration, ordinary ].each do |agent|
      3.times { |index| agent.session.add("user", "message #{index}") }
    end

    iteration.run_auto_compaction
    ordinary.run_auto_compaction

    assert_empty iteration_provider.requests, "an iteration session must not buy a summary"
    assert_equal 1, ordinary_provider.requests.size,
                 "an ordinary session compacts with the request it always made"
  end
end
