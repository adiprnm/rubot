# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

require "rubot/tools/loop_tool"
require "rubot/web/loops"

# The web channel's half of a loop: binding the tool, and the one turn an
# iteration is. The pool and the session it hands back are fakes, so nothing
# here opens a Ractor, reaches a model, or runs git.
class TestWebLoops < Minitest::Test
  # A conversation that is only as much channel as these methods need: the
  # module reaches its state through `self`, which is what makes it testable.
  class Harness
    include Rubot::Web::Loops

    attr_accessor :pool, :tool, :base

    def initialize(pool: nil, base: Dir.mktmpdir("rubot-web-loops"), tool: Rubot::Tools::Loop.new)
      @pool = pool
      @base = base
      @tool = tool
    end

    def session_for(_sid)
      fake = Struct.new(:tools).new(ToolsStub.new(@tool))
      # Enough of a background turn for a finished run to report itself: what
      # the report says is the shared module's business, not this fake's.
      fake.define_singleton_method(:process_background) { |_text, **_options, &_chunk| "" }
      fake
    end

    def workspace_for_session(_sid) = @base
    def owner_slug(_sid) = "implementer"
    def default_slug = "default"

    # A turn performs the first before a background turn runs (see
    # #prepare_delivery), and drawing a report reaches the page through the
    # second. A conversation with no page open has neither. Nothing is running
    # in a harness, so there is never a turn to wait for either.
    def prepare_delivery(_sid) = nil
    def push_to_session(_sid, _type, _markup) = nil
    def live_turn(_sid) = nil
  end

  # The tool registry, as far as binding is concerned.
  class ToolsStub
    def initialize(tool) = @tool = tool
    def get(name) = name == "loop" ? @tool : nil
  end

  # One turn of one iteration, answered from a script. It records how it was
  # called, because the session id and the workspace are the contract, and it
  # can report its usage in several steps -- a turn makes many requests, and
  # each one re-sends the conversation -- which is what makes the budget a
  # moving number rather than one figure at the end.
  class FakeHandle
    # What a cancelled turn really hands back. The agent appends a notice to its
    # answer instead of returning nothing (see Agent::STOP_NOTICE), so a runner
    # that took the returned text as the turn's work would commit and log the
    # notice itself.
    STOP_NOTICE = "⏹️ Stopped by user."

    attr_reader :calls, :cancelled

    def initialize(tokens: 1_234, text: "wrote step.txt", raise_with: nil, usage: nil, reports: nil,
                   cancel_ok: true, cancel_raises: false, cancel_results: [], between: nil)
      @tokens = tokens
      @text = text
      @raise_with = raise_with
      # Cumulative totals, the way a turn reports them, oldest first; `reports`
      # is the same thing with the provisional flag each report carries.
      @reports = reports || usage&.map { |total| { total_tokens: total } }
      # Runs before each report is handed over, which is how a test lands
      # something between two requests of one turn.
      @between = between
      @cancel_ok = cancel_ok
      @cancel_raises = cancel_raises
      # A scripted answer per cancellation, for a stop that has to be asked for
      # twice before it lands.
      @cancel_results = cancel_results
      @calls = []
      @cancelled = 0
    end

    def process(prompt, stream: true, on_usage: nil, **)
      @calls << { prompt: prompt, stream: stream }
      raise @raise_with if @raise_with

      if @reports.nil?
        on_usage&.call({ total_tokens: @tokens })
      else
        @reports.each_with_index do |report, index|
          @between&.call(index)
          on_usage&.call(report)
        end
      end
      # A turn stopped from the outside can come back either way: the actor
      # raises into the session that asked for it, or the agent answers with
      # the notice it appended.
      raise Rubot::Cancelled, "stopped for its budget" if @cancelled.positive? && @cancel_raises
      return STOP_NOTICE if @cancelled.positive?

      @text
    end

    # What SessionHandle#cancel! does: a :stop on the port of the turn running.
    # It answers false when the port is already gone, which is a stop that never
    # landed.
    def cancel!
      @cancelled += 1
      return @cancel_results.shift unless @cancel_results.empty?

      @cancel_ok
    end
  end

  class FakePool
    attr_reader :delegated, :invalidated
    attr_accessor :handle

    def initialize(handle)
      @handle = handle
      @delegated = []
      @invalidated = []
    end

    def delegate(**kwargs)
      @delegated << kwargs
      @handle
    end

    def invalidate(session_id)
      @invalidated << session_id
    end
  end

  def setup
    @base = Dir.mktmpdir("rubot-web-loops")
    @store = Rubot::LoopStore.new(dir: File.join(@base, "loops"))
  end

  def teardown
    FileUtils.remove_entry(@base) if File.exist?(@base)
  end

  def harness(pool: nil, tool: Rubot::Tools::Loop.new)
    Harness.new(pool: pool, base: @base, tool: tool)
  end

  # A loop file in the store the harness pays into, with the budget under test.
  def loop_state(max_tokens: nil)
    @store.create(goal: "make the demo honest", done_criteria: "the demo test is green",
                  repo: @base, **(max_tokens ? { max_tokens: max_tokens } : {}))
  end

  # -- binding ---------------------------------------------------------------

  def test_binding_stamps_the_workspace_and_a_runner_on_the_tool
    channel = harness
    channel.bind_loop_runner("s1")

    assert_equal @base, channel.tool.instance_variable_get(:@workspace)
    runner = channel.tool.loop_runner
    refute_nil runner
    %i[start resume abort].each { |op| assert_respond_to runner, op }
    assert_equal File.join(@base, "loops"), runner.base.then { |base| File.join(base, "loops") }
  end

  def test_binding_twice_keeps_one_runner
    channel = harness
    channel.bind_loop_runner("s1")
    first = channel.tool.loop_runner
    channel.bind_loop_runner("s1")

    assert_same first, channel.tool.loop_runner, "a second turn does not stack runners"
  end

  def test_binding_a_session_without_the_tool_does_nothing
    channel = harness(tool: nil)
    channel.bind_loop_runner("s1")

    assert_nil channel.tool
  end

  def test_binding_skips_a_channel_with_no_workspace
    channel = harness
    channel.base = ""
    channel.bind_loop_runner("s1")

    assert_nil channel.tool.loop_runner
  end

  # -- one iteration ---------------------------------------------------------

  # A caller that names no budget is the one that pays: it gets the turn's total
  # back and charges it itself, which is the contract every caller written
  # before the budget knew about had. No debit happens on this path, so the
  # number is reported and not spent twice.
  def test_an_iteration_answers_with_the_text_and_the_tokens_the_callback_reported
    handle = FakeHandle.new(tokens: 1_234, text: "wrote step.txt")
    pool = FakePool.new(handle)
    channel = harness(pool: pool)

    answer = channel.loop_session_runner("s1").call(session_id: "loop-abc~it1",
                                                    prompt: "do one step",
                                                    workspace: "/tmp/wt")

    assert_equal({ text: "wrote step.txt", tokens: 1_234 }, answer)
    assert_equal 1_234, answer[:tokens], "the number the provider reported, not a guess"
  end

  def test_an_iteration_runs_in_the_worktree_as_the_conversations_persona
    pool = FakePool.new(FakeHandle.new)
    channel = harness(pool: pool)

    channel.loop_session_runner("s1").call(session_id: "loop-abc~it2",
                                           prompt: "do one step", workspace: "/tmp/wt")

    call = pool.delegated.first
    assert_equal "/tmp/wt", call[:workspace]
    assert_equal "loop-abc~it2", call[:session_id], "the actor is named after the iteration"
    assert_equal "implementer", call[:slug], "the conversation's persona, not a new one"
  end

  def test_an_iteration_releases_its_actor_and_asks_for_no_stream
    handle = FakeHandle.new
    pool = FakePool.new(handle)
    channel = harness(pool: pool)

    channel.loop_session_runner("s1").call(session_id: "loop-abc~it3",
                                           prompt: "do one step", workspace: "/tmp/wt")

    assert_equal [ "loop-abc~it3" ], pool.invalidated, "a throwaway session does not stay in memory"
    assert_equal false, handle.calls.first[:stream], "nobody is watching this turn arrive"
  end

  def test_an_iteration_without_a_pool_says_so_instead_of_hanging
    channel = harness(pool: nil)

    error = assert_raises(RuntimeError) do
      channel.loop_session_runner("s1").call(session_id: "loop-abc~it4",
                                             prompt: "do one step", workspace: "/tmp/wt")
    end
    assert_includes error.message, "no session pool"
  end

  def test_a_turn_that_raises_still_releases_the_actor
    pool = FakePool.new(FakeHandle.new(raise_with: StandardError.new("provider said no")))
    channel = harness(pool: pool)

    assert_raises(StandardError) do
      channel.loop_session_runner("s1").call(session_id: "loop-abc~it5",
                                             prompt: "do one step", workspace: "/tmp/wt")
    end
    assert_equal [ "loop-abc~it5" ], pool.invalidated
  end

  # The shape of a turn is measured where the usage reports arrive, because that
  # is the only place the numbers exist: how many requests the turn made, how
  # big the context was at the first and the last of them, and the cache share
  # of the latest. It rides back with the answer and the loop writes it into the
  # iteration's own entry.
  def test_an_iteration_reports_the_shape_of_its_requests_from_the_usage_reports
    handle = FakeHandle.new(reports: [
      { total_tokens: 20_000, requests: 1, last_prompt_tokens: 19_000, cache_hit_rate: 0.0 },
      { total_tokens: 55_000, requests: 60, last_prompt_tokens: 48_000, cache_hit_rate: 0.95 },
      { total_tokens: 90_000, requests: 110, last_prompt_tokens: 76_000, cache_hit_rate: 0.96 }
    ])
    channel = harness(pool: FakePool.new(handle))

    answer = channel.loop_session_runner("s1").call(session_id: "loop-abc~it1",
                                                    prompt: "do one step", workspace: "/tmp/wt")

    assert_equal({ requests: 110, context_first: 19_000, context_last: 76_000, cache_hit_rate: 0.96 },
                 answer[:metrics], "the first request's context and the last one's, from the reports themselves")
  end

  # An estimate describes a request that has not come back yet, so it is not a
  # figure to write into a log that reads as a measurement.
  def test_an_estimate_is_not_folded_into_the_shape_of_the_requests
    handle = FakeHandle.new(reports: [
      { total_tokens: 20_000, requests: 1, last_prompt_tokens: 19_000, cache_hit_rate: 0.96 },
      { total_tokens: 140_000, requests: 2, last_prompt_tokens: 120_000, cache_hit_rate: 0.1,
        provisional: true }
    ])
    channel = harness(pool: FakePool.new(handle))

    answer = channel.loop_session_runner("s1").call(session_id: "loop-abc~it1",
                                                    prompt: "do one step", workspace: "/tmp/wt")

    assert_equal({ requests: 1, context_first: 19_000, context_last: 19_000, cache_hit_rate: 0.96 },
                 answer[:metrics])
  end

  # A turn nobody measured answers exactly as it did before this existed: no
  # metrics key at all, rather than a made-up zero the loop would print.
  def test_a_turn_with_no_usage_numbers_carries_no_shape
    handle = FakeHandle.new(tokens: 1_234, text: "wrote step.txt")
    channel = harness(pool: FakePool.new(handle))

    answer = channel.loop_session_runner("s1").call(session_id: "loop-abc~it1",
                                                    prompt: "do one step", workspace: "/tmp/wt")

    assert_equal({ text: "wrote step.txt", tokens: 1_234 }, answer)
  end

  # -- the budget, inside the turn -------------------------------------------

  # The whole bug, in one turn. The budget used to be checked between
  # iterations only, so one turn -- many requests, each re-sending the
  # conversation -- could spend a loop's entire allowance before anything
  # looked. Here the turn is stopped from the inside at the budget, and what it
  # spent is on the loop's file before the cancellation lands.
  def test_a_turn_is_cancelled_the_moment_its_usage_reaches_the_budget
    state = loop_state(max_tokens: 50_000)
    handle = FakeHandle.new(text: "half a step", usage: [ 20_000, 40_000, 60_000 ])
    channel = harness(pool: FakePool.new(handle))

    answer = channel.loop_session_runner("s1").call(session_id: "loop-#{state.id}~it1",
                                                    prompt: "do one step", workspace: "/tmp/wt",
                                                    id: state.id, budget: 50_000, spent: 0)

    assert_equal 1, handle.cancelled, "the turn is stopped from the inside, once"
    assert_equal true, answer[:budget_stopped]
    assert_equal "", answer[:text],
                 "a cancelled turn hands back its 'stopped' notice, never an answer: " \
                 "the stop is the report, and the notice would otherwise become the log entry and the commit subject"

    reread = @store.load(state.id)
    assert_equal 60_000, reread.tokens, "every report debited as it arrived, and only once"
    assert_operator reread.tokens, :<=, 50_000 + 20_000,
                    "a stop may overshoot by one usage report, never by a whole turn"
  end

  # The cancellation the turn asked for comes back as an exception from the
  # turn that was still running. That is the stop working, not a failure: the
  # loop stopped because it ran out of budget, and a runner that turned it into
  # an error would end the loop as broken work instead of as spent money.
  def test_a_cancelled_turn_is_a_budget_stop_and_not_an_error
    state = loop_state(max_tokens: 10_000)
    handle = FakeHandle.new(usage: [ 30_000 ], cancel_raises: true)
    channel = harness(pool: FakePool.new(handle))

    answer = channel.loop_session_runner("s1").call(session_id: "loop-#{state.id}~it1",
                                                    prompt: "do one step", workspace: "/tmp/wt",
                                                    id: state.id, budget: 10_000, spent: 0)

    refute answer.key?(:error), answer.inspect
    assert_equal true, answer[:budget_stopped]
    assert_equal 30_000, @store.load(state.id).tokens
  end

  # Under the budget nothing is cancelled, and the turn still pays the store as
  # it goes: the answer says nothing is left to charge, so the run cannot count
  # the same tokens a second time, and `spent` is there for the log.
  def test_a_turn_under_the_budget_pays_the_store_and_reports_nothing_left_to_charge
    state = loop_state(max_tokens: 100_000)
    handle = FakeHandle.new(text: "a step", usage: [ 10_000, 12_000 ])
    channel = harness(pool: FakePool.new(handle))

    answer = channel.loop_session_runner("s1").call(session_id: "loop-#{state.id}~it1",
                                                    prompt: "do one step", workspace: "/tmp/wt",
                                                    id: state.id, budget: 100_000, spent: 0)

    assert_equal 0, handle.cancelled
    assert_equal 0, answer[:tokens], "the turn has already paid, so there is nothing to charge"
    assert_equal 12_000, answer[:spent], "the last report is the turn's total"
    assert_equal false, answer[:budget_stopped]
    assert_equal 12_000, @store.load(state.id).tokens
  end

  # A second turn of the same iteration -- the verdict -- counts from what the
  # loop had already spent, not from zero: the budget belongs to the loop.
  def test_a_turn_already_past_the_budget_is_stopped_on_its_first_report
    state = loop_state(max_tokens: 100_000)
    handle = FakeHandle.new(usage: [ 10_000 ])
    channel = harness(pool: FakePool.new(handle))

    channel.loop_session_runner("s1").call(session_id: "loop-#{state.id}~verify1",
                                           prompt: "judge it", workspace: "/tmp/wt",
                                           id: state.id, budget: 100_000, spent: 95_000)

    assert_equal 1, handle.cancelled, "5,000 left is not enough for a report of 10,000"
  end

  # The estimate of a request that has not come back is not a bill. A report
  # carries usage-so-far plus the in-flight request's guess (see
  # UsageAccounting, `provisional`), so billing every report billed a figure the
  # provider never confirmed: the guess was debited, the real usage came in
  # lower, and a counter that refuses a negative delta could only go up. Four
  # reports of one turn, two of them estimates, must leave the measured total.
  def test_a_provisional_report_is_never_billed_and_the_store_ends_at_the_measured_usage
    state = loop_state(max_tokens: 1_000_000)
    handle = FakeHandle.new(reports: [
      { total_tokens: 40_000, provisional: true },
      { total_tokens: 39_000, provisional: false },
      { total_tokens: 94_000, provisional: true },
      { total_tokens: 93_000, provisional: false }
    ])
    channel = harness(pool: FakePool.new(handle))

    answer = channel.loop_session_runner("s1").call(session_id: "loop-#{state.id}~it1",
                                                    prompt: "do one step", workspace: "/tmp/wt",
                                                    id: state.id, budget: 1_000_000, spent: 0)

    assert_equal 0, handle.cancelled, "nothing here reaches the budget"
    assert_equal 93_000, @store.load(state.id).tokens,
                 "39,000 + 54,000 measured tokens, never the 40,000 and 94,000 estimates on top"
    assert_equal 93_000, answer[:spent]
    assert_equal 0, answer[:tokens], "the turn paid the store, so the run charges nothing"
  end

  # The guess is allowed to decide the stop, because stopping late costs a whole
  # turn: the decision reads the higher figure while the store reads the
  # measured one.
  def test_a_provisional_estimate_may_stop_the_turn_but_is_not_billed
    state = loop_state(max_tokens: 50_000)
    handle = FakeHandle.new(reports: [ { total_tokens: 60_000, provisional: true } ])
    channel = harness(pool: FakePool.new(handle))

    answer = channel.loop_session_runner("s1").call(session_id: "loop-#{state.id}~it1",
                                                    prompt: "do one step", workspace: "/tmp/wt",
                                                    id: state.id, budget: 50_000, spent: 0)

    assert_equal 1, handle.cancelled, "60,000 estimated is past a budget of 50,000"
    assert_equal true, answer[:budget_stopped]
    assert_equal 0, @store.load(state.id).tokens,
                 "an estimate nobody has confirmed is not written down as money spent"
  end

  # A failed debit must not advance the counter it was measured against: the
  # difference between what was reported and what was written has to be debited
  # again by the next report, or the turn is billed and the loop never hears of
  # it.
  def test_a_debit_that_could_not_be_written_is_retried_on_the_next_report
    state = loop_state(max_tokens: 100_000)
    path = @store.path(state.id)
    original = File.read(path)
    # A directory where the state file was: every write to it fails, the way a
    # full disk or a read-only mount does.
    FileUtils.rm_f(path)
    FileUtils.mkdir_p(path)
    restore = lambda do |index|
      next unless index == 1

      FileUtils.rm_rf(path)
      File.write(path, original)
    end
    handle = FakeHandle.new(reports: [ { total_tokens: 10_000 }, { total_tokens: 30_000 } ], between: restore)
    channel = harness(pool: FakePool.new(handle))

    answer = nil
    _out, err = capture_io do
      answer = channel.loop_session_runner("s1").call(session_id: "loop-#{state.id}~it1",
                                                      prompt: "do one step", workspace: "/tmp/wt",
                                                      id: state.id, budget: 100_000, spent: 0)
    end

    assert_includes err, "could not debit 10000", "a debit that never landed is said out loud"
    assert_equal 30_000, @store.load(state.id).tokens,
                 "the second report owes the whole measured total, not only its own increase"
    assert_nil answer[:unwritten], "nothing is left unwritten once a later debit lands"
  end

  # The other end of the same rule: when no debit lands at all, the turn says
  # what the store is missing instead of ending as if it were paid.
  def test_a_debit_that_never_lands_is_reported_at_the_end_of_the_turn
    state = loop_state(max_tokens: 100_000)
    path = @store.path(state.id)
    FileUtils.rm_f(path)
    FileUtils.mkdir_p(path)
    handle = FakeHandle.new(reports: [ { total_tokens: 10_000 }, { total_tokens: 30_000 } ])
    channel = harness(pool: FakePool.new(handle))

    answer = nil
    _out, err = capture_io do
      answer = channel.loop_session_runner("s1").call(session_id: "loop-#{state.id}~it1",
                                                      prompt: "do one step", workspace: "/tmp/wt",
                                                      id: state.id, budget: 100_000, spent: 0)
    end

    assert_equal 30_000, answer[:unwritten], "what the store is owed, in the turn's own report"
    assert_includes err, "could not debit"
  end

  # A cancellation that never reached the turn is not a stopped turn. Claiming
  # it stopped would end the loop as spent money while the turn was still
  # buying requests.
  def test_a_cancel_that_does_not_land_is_not_reported_as_a_stop
    state = loop_state(max_tokens: 10_000)
    handle = FakeHandle.new(cancel_ok: false, reports: [ { total_tokens: 30_000 } ])
    channel = harness(pool: FakePool.new(handle))

    answer = channel.loop_session_runner("s1").call(session_id: "loop-#{state.id}~it1",
                                                    prompt: "do one step", workspace: "/tmp/wt",
                                                    id: state.id, budget: 10_000, spent: 0)

    assert_equal 1, handle.cancelled, "the stop was asked for"
    assert_equal false, answer[:budget_stopped], "a stop that did not land must not be claimed"
    assert(@store.load(state.id).log.any? { |entry| entry.text.include?("could not be stopped") },
           "the loop's own log is where a stop that did not land is read")
  end

  # A stop the turn never received is asked for again on the next report, and
  # the failure is written down once: a turn is only ever reported as stopped
  # when a cancellation actually landed.
  def test_a_stop_that_does_not_land_is_asked_again_on_the_next_report
    state = loop_state(max_tokens: 10_000)
    handle = FakeHandle.new(cancel_results: [ false, true ],
                            reports: [ { total_tokens: 20_000 }, { total_tokens: 30_000 } ])
    channel = harness(pool: FakePool.new(handle))

    answer = channel.loop_session_runner("s1").call(session_id: "loop-#{state.id}~it1",
                                                    prompt: "do one step", workspace: "/tmp/wt",
                                                    id: state.id, budget: 10_000, spent: 0)

    assert_equal 2, handle.cancelled, "the stop is asked for until one lands"
    assert_equal true, answer[:budget_stopped]
    assert_equal 1, @store.load(state.id).log.count { |entry| entry.text.include?("could not be stopped") },
                 "one line about the failure, not one per report"
    assert_equal 30_000, @store.load(state.id).tokens
  end

  # -- waking a loop ---------------------------------------------------------

  # A loop that stopped for its budget is paused, and `paused` is exactly what a
  # tick and a tool call are allowed to wake. Nothing raises the budget by
  # itself, so waking a spent loop bought nothing and cost everything: an entry
  # in the file, a turn or a boundary stop, and an announcement to the
  # conversation -- every tick, forever.
  def test_a_spent_loop_is_not_woken_by_an_automatic_resume_and_is_not_announced_again
    channel = harness
    delivered = []
    turns = []
    channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
    channel.define_singleton_method(:deliver_report) { |_sid, text:, label: ""| delivered << text }
    state = @store.create(goal: "g", done_criteria: "c", repo: @base, max_tokens: 5_000)
    @store.update(state.id) { |loop| loop.status = "paused"; loop.tokens = 6_000 }

    runner = Rubot::Web::Loops::SessionRunner.new(
      base: @base, store: @store,
      session_runner: lambda do |session_id:, prompt:, workspace:|
        turns << session_id
        { text: "a step", tokens: 900 }
      end,
      on_finish: ->(id, outcome) { channel.report_loop_finished("s1", id, outcome) }
    )

    2.times do
      runner.resume(state.id)
      runner.join(5)
    end

    assert_empty turns, "a loop that has spent its budget buys no turn"
    assert_empty delivered, "the same stop is not announced to the conversation twice"
    reread = @store.load(state.id)
    assert_equal "paused", reread.status
    assert_equal 1, reread.log.count { |entry| entry.text.include?("max_tokens") },
                 "one entry saying how to get going again, however many ticks fire"
  end

  # The other side of the same rule: a paused loop with room left is woken, so
  # the refusal above is about the budget and not about waking at all.
  def test_a_paused_loop_with_room_left_is_woken
    state = @store.create(goal: "g", done_criteria: "c", repo: @base, max_tokens: 5_000)
    @store.update(state.id) { |loop| loop.status = "paused"; loop.tokens = 1_000 }
    runner = session_runner(async: false, on_finish: ->(_id, _outcome) { nil })

    answer = runner.resume(state.id)

    refute_includes answer, "max_tokens", "nothing was refused"
    # Not a git repository here, so the run stops before an iteration is paid
    # for: it was woken, and that is what this says.
    assert_includes answer, "stopped:"
  end

  # -- a handed-off request --------------------------------------------------

  # The runner a conversation already has, as far as a `:loop` event is
  # concerned: whether the id exists, the claim it was asked for, and what it
  # was then told to do.
  class FakeRunner
    attr_reader :calls

    def initialize(known: true, claims: 1)
      @known = known
      @claims_left = claims
      @calls = []
    end

    def known?(_id) = @known

    def claim_start(id)
      return false if @claims_left.zero?

      @claims_left -= 1
      @calls << [ :claim, id ]
      true
    end

    def run_claimed(op, id)
      @calls << [ op, id ]
      "OK: loop #{id} is iterating on a thread of its own"
    end

    def abort(id)
      @calls << [ :abort, id ]
      "OK: loop #{id} stops after the iteration in flight"
    end
  end

  def loop_request(**overrides)
    { op: :start, id: "20260101-000000-a001", parent_session: "s1", slug: "implementer" }.merge(overrides)
  end

  def channel_with_runner(runner)
    channel = harness
    channel.instance_variable_set(:@loop_runners, { [ "s1", @base ] => runner })
    channel
  end

  def test_a_start_request_claims_the_loop_and_hands_it_to_the_runner
    runner = FakeRunner.new
    channel = channel_with_runner(runner)

    assert channel.handle_loop_request("s1", loop_request)

    assert_equal [ [ :claim, "20260101-000000-a001" ], [ :start, "20260101-000000-a001" ] ], runner.calls
  end

  def test_a_resume_request_goes_through_the_same_claim
    runner = FakeRunner.new
    channel = channel_with_runner(runner)

    channel.handle_loop_request("s1", loop_request(op: :resume))

    assert_equal [ [ :claim, "20260101-000000-a001" ], [ :resume, "20260101-000000-a001" ] ], runner.calls
  end

  # A pause is one write on the run's side; there is nothing to hand to a
  # thread and nothing to claim.
  def test_a_pause_request_stops_the_run_without_claiming_it
    runner = FakeRunner.new
    channel = channel_with_runner(runner)

    channel.handle_loop_request("s1", loop_request(op: :abort))

    assert_equal [ [ :abort, "20260101-000000-a001" ] ], runner.calls
  end

  def test_a_second_request_for_a_loop_already_iterating_warns_and_starts_nothing
    runner = FakeRunner.new(claims: 1)
    channel = channel_with_runner(runner)
    channel.handle_loop_request("s1", loop_request)

    result = nil
    _out, err = capture_io { result = channel.handle_loop_request("s1", loop_request) }

    assert_equal false, result
    assert_equal 1, runner.calls.count { |op, _id| op == :start }, "one id, one run"
    assert_includes err, "already iterating"
  end

  def test_a_resume_for_an_unknown_loop_warns_and_raises_nothing
    runner = FakeRunner.new(known: false)
    channel = channel_with_runner(runner)

    result = nil
    _out, err = capture_io { result = channel.handle_loop_request("s1", loop_request(op: :resume)) }

    assert_equal false, result
    assert_empty runner.calls, "nothing is started for a loop that is not there"
    assert_includes err, "no loop with that id"
  end

  # The claim is the runner's own guard, so the request path and a tool call
  # cannot both start the same loop.
  def test_claim_start_only_hands_one_run_per_loop
    channel = harness
    channel.bind_loop_runner("s1")
    runner = channel.tool.loop_runner

    assert runner.claim_start("20260101-000000-a001")
    refute runner.claim_start("20260101-000000-a001"), "a second claim must not start a second run"
  end

  # -- stopping --------------------------------------------------------------

  def test_abort_pauses_the_loop_because_the_run_rereads_its_status_each_iteration
    channel = harness
    channel.bind_loop_runner("s1")
    state = @store.create(goal: "g", done_criteria: "c", repo: @base)

    channel.tool.loop_runner.abort(state.id)

    assert_equal "paused", @store.load(state.id).status
  end

  def test_start_answers_at_once_and_leaves_the_iterating_to_a_thread
    channel = harness
    channel.bind_loop_runner("s1")
    # Not a git repository, so the run stops before an iteration is paid for --
    # the point of this test is the answer, not the work.
    state = @store.create(goal: "g", done_criteria: "c", repo: @base)

    answer = channel.tool.loop_runner.start(state.id)

    assert_includes answer, "thread of its own"
    refute_includes answer, "stopped:" # the run has not finished and must not pretend it has

    # Let the thread land before the temp directory goes away underneath it.
    40.times do
      break if @store.load(state.id).log.any? { |entry| entry.text.include?("could not prepare") }

      sleep 0.05
    end
  end

  # -- reporting where the run got -------------------------------------------

  # A conversation as far as a report is concerned: an archive whose next index
  # only moves once the report turn has written, which is exactly the race a
  # per-session lock exists to lose.
  class ReportHarness
    include Rubot::Web::Reports

    attr_reader :openings

    def initialize
      @last_index = 0
      @openings = []
      @recorded = Mutex.new
    end

    def next_entry_index(_sid) = @last_index + 1

    # Only the opening call is of interest: it is the one that claims the index.
    def broadcast_report_entry(_sid, index, text)
      return unless text.to_s.empty?

      @recorded.synchronize { @openings << index }
    end

    def push_to_session(_sid, _type, _markup) = nil

    def session_for(_sid)
      advance = -> { @last_index += 1 }
      fake = Object.new
      fake.define_singleton_method(:process_background) do |_text, label: "", tools: true, &_chunk|
        advance.call
        "dibaca"
      end
      fake
    end
  end

  # Two features report this way — a finished batch of delegated runs and a loop
  # that stopped — and a block is grown in place, so two reports under one index
  # would write into the same element. The second waits for the first.
  def test_two_reports_for_one_session_never_share_an_entry_index
    channel = ReportHarness.new

    2.times.map do |i|
      Thread.new { channel.deliver_report("s1", text: "laporan #{i}", label: "x:\n\n") }
    end.each(&:join)

    assert_equal 2, channel.openings.size
    assert_equal 2, channel.openings.uniq.size, "one block, one index"
  end

  def session_runner(on_finish: nil, logger: nil, async: true)
    Rubot::Web::Loops::SessionRunner.new(
      base: @base,
      store: @store,
      session_runner: ->(session_id:, prompt:, workspace:) { { text: "", tokens: 0 } },
      logger: logger,
      async: async,
      on_finish: on_finish
    )
  end

  def result_for(state, stop_reason, message: "verifier: 3 tests pass", iterations: 2)
    Rubot::LoopRun::Result.new(state: state, stop_reason: stop_reason,
                               iterations_run: iterations, message: message)
  end

  # A run outlives the turn that started it, so the thread that ran it is the
  # only thing left that can say where it got. Not a git repository here, so the
  # run stops before an iteration is paid for -- which is still an ending, and
  # still has to reach the conversation.
  def test_a_finished_run_is_reported_to_the_conversation_that_opened_it
    announced = Queue.new
    runner = session_runner(on_finish: ->(id, outcome) { announced << [ id, outcome ] })
    state = @store.create(goal: "ship the readme", done_criteria: "readme exists", repo: @base)

    runner.start(state.id)
    runner.join(5)

    assert_equal 1, announced.size, "one run, one report"
    id, outcome = announced.pop
    assert_equal state.id, id
    assert_equal :worktree_error, outcome.stop_reason
  end

  # A run that breaks before it can answer with a reason is announced too: an
  # unreadable file leaves the exception with nowhere else to go, and the reader
  # is still owed the news that the loop stopped.
  def test_a_run_that_breaks_is_reported_as_an_error
    state = @store.create(goal: "g", done_criteria: "c", repo: @base)
    File.write(File.join(@base, "loops", "#{state.id}.md"), "this is not a loop file\n")

    announced = Queue.new
    runner = session_runner(on_finish: ->(id, outcome) { announced << [ id, outcome ] })

    runner.start(state.id)
    runner.join(5)

    assert_equal 1, announced.size
    _id, outcome = announced.pop
    assert_equal :error, outcome.stop_reason
    assert_includes outcome.message, "Corrupt"
  end

  # A report is a provider request in another conversation, and a loop that
  # finished cannot be undone by one that failed to say so.
  def test_an_announcement_that_raises_is_one_log_line_and_nothing_more
    logged = []
    runner = session_runner(logger: ->(text) { logged << text },
                            on_finish: ->(_id, _outcome) { raise "the conversation is gone" })
    state = @store.create(goal: "g", done_criteria: "c", repo: @base)

    runner.start(state.id)
    runner.join(5)

    assert(logged.any? { |line| line.include?("could not be reported") })
    assert_equal state.id, @store.load(state.id).id, "the loop's file is left as the run wrote it"
  end

  # The exclusions are the point: a pause is the reader's own doing, and a loop
  # that was never active ran nothing at all.
  def test_an_ending_nobody_asked_about_stays_silent
    channel = harness
    delivered = []
    channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
    channel.define_singleton_method(:deliver_report) { |sid, text:, label: ""| delivered << [ sid, text, label ] }
    state = @store.create(goal: "g", done_criteria: "c", repo: @base)

    %i[paused missing not_active].each do |reason|
      channel.report_loop_finished("s1", state.id, result_for(state, reason))
    end

    assert_empty delivered, "nothing ran, or the reader ended it themselves"
  end

  # Running out of room is news too. A loop that spent its tokens, used its last
  # iteration or kept getting the same refusal from the verifier stopped short of
  # the goal, and a reader who hears nothing about it has to ask `status` to find
  # out that nothing is happening any more.
  def test_a_loop_that_ran_out_of_room_says_so_in_plain_words
    channel = harness
    delivered = []
    channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
    channel.define_singleton_method(:deliver_report) { |sid, text:, label: ""| delivered << [ sid, text, label ] }
    state = @store.create(goal: "g", done_criteria: "c", repo: @base)

    {
      budget: "jatah token untuk loop ini habis",
      max_iterations: "batas iterasinya tercapai sebelum kriterianya terpenuhi",
      verifier_stuck: "verifier terus menolak dengan alasan yang sama"
    }.each do |reason, phrase|
      channel.report_loop_finished("s1", state.id, result_for(state, reason))
      sid, text, _label = delivered.last
      assert_equal "s1", sid
      assert_includes text, phrase, "#{reason} is told as a sentence the reader can act on"
      assert_includes text, "Alasan berhenti: #{reason}"
    end

    assert_equal 3, delivered.size, "each ending reports once"
  end

  # The budget stop is the one a schedule can announce over and over: a tick
  # wakes the same spent loop, and every wake would say the same sentence in the
  # parent conversation. Once per allowance is news; the second copy is what a
  # reader stops reading.
  def test_a_budget_stop_is_announced_once_per_allowance
    channel = harness
    delivered = []
    channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
    channel.define_singleton_method(:deliver_report) { |_sid, text:, label: ""| delivered << text }
    state = @store.create(goal: "g", done_criteria: "c", repo: @base, max_tokens: 5_000)

    2.times { channel.report_loop_finished("s1", state.id, result_for(state, :budget)) }

    assert_equal 1, delivered.size, "one stop, one announcement"

    # A bigger budget is a different allowance, so meeting it again is news.
    @store.update(state.id) { |loop| loop.max_tokens = 50_000 }
    channel.report_loop_finished("s1", state.id, result_for(@store.load(state.id), :budget))

    assert_equal 2, delivered.size
  end

  def test_the_report_carries_the_goal_and_why_the_loop_stopped
    channel = harness
    delivered = []
    channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
    channel.define_singleton_method(:deliver_report) { |sid, text:, label: ""| delivered << [ sid, text, label ] }
    state = @store.create(goal: "ship the readme", done_criteria: "readme exists", repo: @base)
    @store.update(state.id) do |loop|
      loop.branch = "loop/readme"
      loop.tokens = 4_321
    end

    channel.report_loop_finished("s1", state.id, result_for(@store.load(state.id), :done_by_verifier))

    assert_equal 1, delivered.size
    sid, text, label = delivered.first
    assert_equal "s1", sid
    assert_includes label, "Kabar dari loop", "the model is told this arrived on its own"
    assert_includes text, state.id
    assert_includes text, "ship the readme"
    assert_includes text, "done_by_verifier"
    assert_includes text, "kriteria yang kamu tetapkan sudah terpenuhi",
                    "plain words, not only the run's own symbol"
    assert_includes text, "Iterasi: 2"
    assert_includes text, "Token terpakai: 4321"
    assert_includes text, "loop/readme"
  end

  # A report drawn while the reader's own turn is running would open its block
  # above an answer still being written, and only a reload would put the two
  # back in the archive's order. Waiting is bounded, so the wait itself is what
  # this test pins: the report goes out after the turn ends, not before.
  def test_a_report_waits_for_the_readers_own_turn_to_end
    channel = harness
    delivered = []
    waits = []
    channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
    channel.define_singleton_method(:deliver_report) { |sid, text:, label: ""| delivered << [ sid, text, label ] }
    channel.define_singleton_method(:sleep) { |seconds| waits << seconds }
    channel.define_singleton_method(:live_turn) { |_sid| waits.size < 2 }
    state = @store.create(goal: "g", done_criteria: "c", repo: @base)

    channel.report_loop_finished("s1", state.id, result_for(state, :done_by_verifier))

    assert_equal 2, waits.size, "it looked twice before drawing"
    assert_equal 1, delivered.size
  end
end
