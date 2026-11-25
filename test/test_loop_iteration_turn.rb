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

    def initialize(script, usage: { "prompt_tokens" => 20, "completion_tokens" => 5 })
      @script = script.dup
      @usage = usage
      @requests = []
      @offers = []
    end

    def name = "openai"

    def last_usage
      @usage
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

  def build_agent(script, session_id:, defaults: {}, usage: nil)
    path = File.join(@tmpdir, "config.yml")
    File.write(path, {
      "agents" => { "defaults" => { "workspace" => @workspace }.merge(defaults) },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)
    provider = usage ? ScriptedProvider.new(script, usage: usage) : ScriptedProvider.new(script)
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

  # -- the context ceiling ---------------------------------------------------

  # The other half of the ceiling, and the one that replaces compaction: an
  # iteration stops when its transcript is bigger than it is worth sending
  # again. It is a setting of its own, default 100k tokens, because the right
  # number follows what one step of real work costs.
  def test_the_context_ceiling_is_a_setting_of_its_own
    iteration, = build_agent([], session_id: "loop-abc~a1~it1")

    assert_equal Rubot::Config::DEFAULT_LOOP_MAX_CONTEXT_TOKENS, iteration.loop_max_context_tokens
    assert_equal 100_000, iteration.loop_max_context_tokens
  end

  def test_the_context_ceiling_follows_the_setting
    agent, = build_agent([], session_id: "loop-abc~a1~it1",
                             defaults: { "loop_max_context_tokens" => 12_345 })

    assert_equal 12_345, agent.loop_max_context_tokens
    assert_equal 12_345, agent.config.loop_max_context_tokens
  end

  # The whole behaviour, at the provider: the measured request already carries
  # more than the ceiling, so the round that would re-send it is never made --
  # the opposite of the compaction this replaces, which bought a summary and
  # then paid for the same transcript again.
  def test_an_iteration_stops_at_its_context_ceiling_instead_of_sending_again
    agent, provider = build_agent(
      [ tool_round("call_1"), { "content" => "must never be asked" } ],
      session_id: "loop-abc~a1~it1",
      defaults: { "loop_max_context_tokens" => 4_000 },
      usage: { "prompt_tokens" => 4_200, "completion_tokens" => 5 }
    )

    answer = agent.process("work a step", stream: false)

    assert_equal 1, provider.requests.size, "the request that would re-send the context is never made"
    reaching = agent.last_context_ceiling
    refute_nil reaching, "the ceiling it stopped at is reported"
    assert_equal 4_000, reaching[:limit]
    assert_operator reaching[:tokens], :>=, 4_000
    assert_includes answer, "stopped at its context ceiling"
    assert_includes answer, "of 4000 tokens"
    assert_nil agent.last_round_cap, "no round cap was reached"
  end

  # A turn outside a loop has no such ceiling: the reader is waiting for its
  # answer, and 100k tokens of a normal conversation is not a reason to stop it.
  def test_an_ordinary_turn_has_no_context_ceiling
    agent, provider = build_agent(
      [ tool_round("call_1"), { "content" => "answered anyway" } ],
      session_id: "chatter",
      defaults: { "loop_max_context_tokens" => 4_000 },
      usage: { "prompt_tokens" => 4_200, "completion_tokens" => 5 }
    )

    answer = agent.process("halo", stream: false)

    assert_equal 2, provider.requests.size, "an ordinary turn keeps its rounds"
    assert_nil agent.last_context_ceiling
    assert_includes answer, "answered anyway"
  end

  # -- the wiring from config ------------------------------------------------

  # Both numbers are settings, so the thing worth proving is not that the
  # defaults work (the tests above do that) but that a file's own numbers reach
  # the turn. These are values nobody would guess: a turn that reads the
  # constant instead of the config fails every assertion below.
  TUNED = { "loop_max_rounds" => 7, "loop_max_context_tokens" => 12_345 }.freeze

  def test_the_numbers_in_the_config_file_reach_the_iteration_turn
    iteration, = build_agent([], session_id: "loop-abc~a1~it1", defaults: TUNED)
    ordinary, = build_agent([], session_id: "chatter", defaults: TUNED)

    assert_equal 7, iteration.turn_round_limit, "the iteration obeys the file's round cap"
    assert_equal 12_345, iteration.loop_max_context_tokens, "and the file's context ceiling"
    assert_equal 1000, ordinary.turn_round_limit, "the tuned loop cap is not an ordinary turn's"
  end

  # The cap as the turn really spends it: seven tool rounds are allowed, the
  # eighth request is the closing one. A turn on the default 40 would keep
  # asking, and one on the ordinary 1000 would ask again after the seventh.
  def test_the_tuned_round_cap_is_the_one_the_turn_obeys
    script = (1..7).map { |index| tool_round("call_#{index}") } << { "content" => "seven rounds, then the report" }
    agent, provider = build_agent(script, session_id: "loop-abc~a1~it1", defaults: TUNED)

    answer = agent.process("work a step", stream: false)

    assert_equal 8, provider.requests.size, "seven working rounds and the closing one"
    assert_equal 7, provider.offers.count { |tools| !tools.empty? }
    assert_includes answer, "stopped at its round cap (7)"
    assert_equal({ rounds: 7, limit: 7 }, agent.last_round_cap)
  end

  # The ceiling as the turn compares it: 11k is under 12_345 and the turn goes
  # on; 12_346 is over it and the next request is never made. A turn comparing
  # against the 100k default would send again in both cases.
  def test_the_tuned_context_ceiling_is_the_one_the_turn_obeys
    under, under_provider = build_agent(
      [ tool_round("call_1"), { "content" => "carried on" } ],
      session_id: "loop-abc~a1~it1", defaults: TUNED,
      usage: { "prompt_tokens" => 11_000, "completion_tokens" => 5 }
    )
    over, over_provider = build_agent(
      [ tool_round("call_1"), { "content" => "must never be asked" } ],
      session_id: "loop-abc~a1~it1", defaults: TUNED,
      usage: { "prompt_tokens" => 12_346, "completion_tokens" => 5 }
    )

    assert_includes under.process("work a step", stream: false), "carried on"
    assert_equal 2, under_provider.requests.size, "11k is under the tuned ceiling"
    assert_nil under.last_context_ceiling

    answer = over.process("work a step", stream: false)
    assert_equal 1, over_provider.requests.size, "12_346 is over the tuned ceiling"
    assert_equal 12_345, over.last_context_ceiling[:limit]
    assert_includes answer, "of 12345 tokens", "the stop names the number the file set"
  end

  # The two facts together, in the same turn: compaction is on and would fire
  # for an ordinary session at this size, yet the iteration that is over its
  # ceiling stops without buying a summary and without sending the transcript
  # again. One request is the whole proof.
  def test_an_iteration_at_its_ceiling_buys_no_compaction
    agent, provider = build_agent(
      [ tool_round("call_1"), { "content" => "the conversation so far" }, { "content" => "must never be asked" } ],
      session_id: "loop-abc~a1~it1",
      defaults: TUNED.merge("compaction" => { "auto" => true, "threshold_tokens" => 1,
                                             "keep_recent_messages" => 1 }),
      usage: { "prompt_tokens" => 12_346, "completion_tokens" => 5 }
    )

    answer = agent.process("work a step", stream: false)

    assert_equal 1, provider.requests.size, "no summary request, no second attempt"
    refute_nil agent.last_context_ceiling
    assert_includes answer, "stopped at its context ceiling"
  end

  # The other side, so the skip above cannot be a global one: the same config
  # and the same size on an ordinary session compacts -- the summarizer reads
  # the earlier conversation, which is a real request -- and the turn still
  # takes its following round. The script answers that summarizer first, so the
  # order of the requests is the order of the facts.
  def test_an_ordinary_session_at_the_same_size_still_compacts
    agent, provider = build_agent(
      [ { "content" => "what came before, in a sentence" }, tool_round("call_1"),
        { "content" => "answered anyway" } ],
      session_id: "chatter",
      defaults: TUNED.merge("max_rounds" => 4,
                            "compaction" => { "auto" => true, "threshold_tokens" => 1,
                                              "keep_recent_messages" => 1 }),
      usage: { "prompt_tokens" => 12_346, "completion_tokens" => 5 }
    )
    # A conversation already under way, so the summarizer has an earlier part to
    # read: the current turn is always kept verbatim, and compacting nothing is
    # not a compaction.
    3.times { |index| agent.session.add("user", "earlier message #{index}") }

    answer = agent.process("halo", stream: false)

    assert_equal 3, provider.requests.size,
                 "the summary it bought, the round, and the round after it"
    assert_includes provider.requests[0].map { |message| message["content"].to_s }.join, "earlier message",
                    "the first request is the summarizer reading the transcript"
    refute_empty provider.offers[1], "the ordinary turn keeps taking tool rounds"
    assert_includes answer, "answered anyway"
    assert_nil agent.last_context_ceiling, "an ordinary turn has no context ceiling"
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
