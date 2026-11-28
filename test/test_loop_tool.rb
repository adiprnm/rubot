# frozen_string_literal: true

require_relative "test_helper"

# The tool is a thin adapter: this file drives it against a real state file on
# disk and a fake runner that records the calls it received, so a loop can be
# created, listed, paused and resumed with no model, no Ractor and no network.
class TestLoopTool < Minitest::Test
  # Stands in for the channel handle the agent would inject as loop_runner. The
  # block, when a test passes one, runs at the moment the runner is told to
  # resume: it is how a test sees what the file said by then.
  class FakeRunner
    attr_reader :calls

    def initialize(&on_resume)
      @calls = []
      @on_resume = on_resume
    end

    def start(id) = @calls << [ :start, id ]
    def abort(id) = @calls << [ :abort, id ]
    def resume(id)
      @on_resume&.call(id)
      @calls << [ :resume, id ]
    end
  end

  # Stands in for the agent a turn stamps on the tool. It records what it was
  # asked and answers with a sentence, like Agent#request_loop does.
  class FakeAgent
    attr_reader :requests

    def initialize(answer = "Loop started in the background. A status call shows where it got.")
      @answer = answer
      @requests = []
    end

    def request_loop(**request)
      @requests << request
      @answer
    end
  end

  def setup
    @tmp = Dir.mktmpdir("rubot-loop-tool")
    @root = File.join(@tmp, "root")
    @store = Rubot::LoopStore.new(dir: File.join(@root, "loops"))
    @repo = File.join(@tmp, "repo")
    FileUtils.mkdir_p(@repo)
    @runner = FakeRunner.new
    @tool = Rubot::Tools::Loop.new(store_root: @root)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.exist?(@tmp)
  end

  # -- helpers ---------------------------------------------------------------

  def start_loop(**overrides)
    @tool.execute(
      { "operation" => "start", "goal" => "make the demo honest",
        "done_criteria" => "the demo test is green", "repo" => @repo }.merge(overrides)
    )
  end

  def create(**overrides)
    @store.create(
      **{ goal: "make the demo honest", done_criteria: "the demo test is green", repo: @repo }.merge(overrides)
    )
  end

  def assert_error(result)
    assert result.start_with?("ERROR:"), result
  end

  def assert_ok(result)
    assert result.start_with?("OK:"), result
  end

  # The real runner, for the tests that need to see what the tool's write does to
  # it. It needs a repository a worktree can be made from: the wake is written
  # only after `prepare` succeeds, so a plain directory would stop the run one
  # step early and the file would be read while it was correctly left alone. Its
  # session runner raises, which is the cheapest stand-in for a run that starts
  # and then dies inside its first turn.
  def real_runner
    Rubot::LoopRunner.new(
      store: @store,
      worktree_root: File.join(@root, "worktrees"),
      session_runner: ->(session_id:, prompt:, workspace:) { raise IOError, "the run did not get to work" },
      verifier_persona: "code_reviewer"
    )
  end

  def git_repo
    @git_repo ||= begin
      dir = File.join(@tmp, "git-demo")
      FileUtils.mkdir_p(dir)
      system("git", "init", "-q", "-b", "main", dir, exception: true)
      system("git", "-C", dir, "config", "user.email", "tool@example.com", exception: true)
      system("git", "-C", dir, "config", "user.name", "Loop Tool Test", exception: true)
      File.write(File.join(dir, "README.md"), "demo\n")
      system("git", "-C", dir, "add", "-A", exception: true)
      system("git", "-C", dir, "commit", "-q", "-m", "init", exception: true)
      dir
    end
  end

  # The state a run now leaves behind when it reaches its cap: paused, with the
  # iterations already at the cap, which is the state a resume has to get out of.
  def cap_stopped(max_iterations: 2)
    state = create(max_iterations: max_iterations)
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.iterations = max_iterations
    end
    state
  end

  # The state a budget stop leaves behind: paused, with the tokens already past
  # the budget in the file. Nothing in the file can move on its own, which is
  # why a resume that only sets the status walks straight back into this.
  def budget_stopped(tokens: 6_000, max_tokens: 5_000)
    state = create(max_tokens: max_tokens)
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.iterations = 1
      loop.tokens = tokens
    end
    state
  end

  # -- start -----------------------------------------------------------------

  def test_start_without_a_runner_records_the_loop_and_says_no_runner_is_attached
    result = start_loop

    assert_ok result
    assert_includes result, "no runner is attached"

    id = result[/(\d{8}-\d{6}-[0-9a-f]+)/, 1]
    refute_nil id, result
    state = @store.load(id)
    refute_nil state
    assert_equal "active", state.status
    assert_equal 0, state.iterations
    assert_equal @repo, state.repo
  end

  def test_start_with_a_runner_hands_the_loop_to_it
    @tool.loop_runner = @runner

    result = start_loop

    assert_ok result
    id = @store.ids.first
    assert_equal [ [ :start, id ] ], @runner.calls
  end

  def test_start_rejects_a_missing_goal
    result = start_loop("goal" => nil)

    assert_error result
    assert_includes result, "goal"
    assert_empty @store.ids
  end

  def test_start_rejects_missing_done_criteria
    result = start_loop("done_criteria" => "")

    assert_error result
    assert_includes result, "done_criteria"
    assert_empty @store.ids
  end

  def test_start_rejects_a_missing_repo
    result = start_loop("repo" => nil)

    assert_error result
    assert_includes result, "repo"
    assert_empty @store.ids
  end

  def test_start_rejects_a_repo_path_that_does_not_exist
    result = start_loop("repo" => File.join(@tmp, "missing"))

    assert_error result
    assert_includes result, "not an existing directory"
    assert_empty @store.ids
  end

  # -- the budget a start names ----------------------------------------------

  def test_start_records_the_budget_it_was_given
    @tool.loop_runner = @runner

    result = start_loop("max_tokens" => 750_000)

    assert_ok result
    state = @store.load(@store.ids.first)
    assert_equal 750_000, state.max_tokens
    assert_includes File.read(@store.path(state.id)), "max_tokens: 750000"
    assert_includes @tool.execute("operation" => "status", "id" => state.id), "tokens: 0/750000",
                    "the budget is what a reader meets in the status"
  end

  def test_start_without_a_budget_gets_the_default
    result = start_loop

    assert_ok result
    assert_equal Rubot::LoopStore::State::DEFAULT_MAX_TOKENS, @store.load(@store.ids.first).max_tokens
  end

  # The budget a loop gets without asking is twelve million tokens, and a
  # reader who is not told that has no way to notice what a start is about to
  # allow: the number is said out loud, whether it was asked for or defaulted.
  def test_start_says_the_budget_the_loop_gets
    result = start_loop

    assert_ok result
    assert_includes result, "12000000", "a start names the budget it just allowed"

    asked = start_loop("max_tokens" => 750_000)
    assert_includes asked, "750000", "and the one it was given instead"
  end

  # Refused rather than coerced: a budget of zero stops the loop before its
  # first iteration, and "a lot" silently becoming twelve million is a loop
  # spending more than the reader meant to allow.
  def test_start_rejects_a_budget_that_is_not_a_whole_number_above_zero
    [ "0", "-5", "12.5", "a lot" ].each do |budget|
      result = start_loop("max_tokens" => budget)

      assert_error result
      assert_includes result, "max_tokens must be a whole number of tokens above zero"
      assert_includes result, budget.inspect
      assert_empty @store.ids, "#{budget.inspect} must not create a loop"
    end
  end

  # -- list ------------------------------------------------------------------

  def test_list_with_no_loops
    assert_equal "No loops.", @tool.execute("operation" => "list")
  end

  def test_list_shows_every_loop_with_its_iterations_and_status
    first = create
    second = create(goal: "second goal")
    @store.update(second.id) do |loop|
      loop.status = "paused"
      loop.iterations = 3
    end

    lines = @tool.execute("operation" => "list").lines.map(&:chomp)

    assert_equal 2, lines.size
    line = lines.find { |candidate| candidate.start_with?(first.id) }
    refute_nil line, lines.inspect
    assert_includes line, "it=0/3"
    assert_includes line, "active"

    line = lines.find { |candidate| candidate.start_with?(second.id) }
    refute_nil line, lines.inspect
    assert_includes line, "it=3/3"
    assert_includes line, "paused"
  end

  # The listing is where a reader meets the cap, and the loop was created here
  # with no cap of its own: three is the default a loop actually gets.
  def test_a_loop_started_without_a_cap_gets_three_iterations
    @tool.loop_runner = @runner

    result = start_loop

    assert_ok result
    assert_equal 3, @store.load(@store.ids.first).max_iterations
    assert_includes @tool.execute("operation" => "list"), "it=0/3"
  end

  # Two places state the numbers -- the store a start falls back to and this
  # tool's own constants -- and they may not drift apart: the cap and the budget
  # the tool writes are the ones a loop gets without asking. Three iterations
  # inside twelve million tokens, because one measured iteration is two full
  # turns of 2.8M to 5.8M tokens: an 85k iteration is the toy loop that made the
  # old 500,000 budget look generous while it was smaller than one real turn.
  def test_the_tools_defaults_are_the_stores_and_fit_the_measured_iteration
    assert_equal 3, Rubot::Tools::Loop::DEFAULT_MAX_ITERATIONS
    assert_equal Rubot::LoopStore::State::DEFAULT_MAX_ITERATIONS, Rubot::Tools::Loop::DEFAULT_MAX_ITERATIONS
    assert_equal Rubot::LoopStore::State::DEFAULT_MAX_TOKENS, Rubot::Tools::Loop::DEFAULT_MAX_TOKENS
    assert_operator 2_800_000 * Rubot::Tools::Loop::DEFAULT_MAX_ITERATIONS, :<=,
                    Rubot::Tools::Loop::DEFAULT_MAX_TOKENS,
                    "three real iterations must fit under the budget, or the cap is decorative"
    refute_operator 5_800_000 * Rubot::Tools::Loop::DEFAULT_MAX_ITERATIONS, :<=,
                    Rubot::Tools::Loop::DEFAULT_MAX_TOKENS,
                    "three expensive iterations must not fit: the budget is the brake for those"
  end

  # -- status ----------------------------------------------------------------

  def test_status_shows_the_goal_and_the_newest_entries_first
    state = create
    @store.append_log(state.id, "first try")
    @store.append_log(state.id, "second try")

    result = @tool.execute("operation" => "status", "id" => state.id)

    assert_includes result, "make the demo honest"
    assert_includes result, "the demo test is green"
    assert_includes result, state.id
    assert_operator result.index("second try"), :<, result.index("first try")
  end

  def test_status_caps_the_log_at_the_last_five_entries
    state = create
    7.times { |i| @store.append_log(state.id, "step #{i + 1}") }

    result = @tool.execute("operation" => "status", "id" => state.id)

    assert_includes result, "step 7"
    assert_includes result, "step 6"
    assert_includes result, "step 3"
    refute_includes result, "step 2"
    refute_includes result, "step 1"
    refute_includes result, "loop started"
  end

  def test_status_on_a_missing_loop_is_an_error_and_does_not_raise
    result = @tool.execute("operation" => "status", "id" => "20260101-000000-aaaa")

    assert_equal "ERROR: no loop '20260101-000000-aaaa'", result
  end

  # A cap can only be raised through the numbers the reader can see, so the
  # status has to carry it next to the iterations already spent.
  def test_status_shows_the_cap_next_to_the_iterations
    state = cap_stopped(max_iterations: 4)

    result = @tool.execute("operation" => "status", "id" => state.id)

    assert_includes result, "iterations: 4/4"
    assert_includes result, "status: paused"
  end

  # -- pause / resume / stop -------------------------------------------------

  def test_pause_pauses_an_active_loop_and_aborts_the_runner
    state = create
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "pause", "id" => state.id)

    assert_ok result
    assert_equal "paused", @store.load(state.id).status
    assert_equal [ [ :abort, state.id ] ], @runner.calls
  end

  def test_pause_on_a_done_loop_is_a_no_op_that_says_so
    state = create
    @store.update(state.id) { |loop| loop.status = "done" }
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "pause", "id" => state.id)

    assert_ok result
    assert_includes result, "done"
    assert_equal "done", @store.load(state.id).status
    assert_empty @runner.calls
  end

  # The runner is the half that knows whether a wake is a wake or a takeover, so
  # it is the half that writes the status: the tool raises the cap and leaves the
  # file's two "is this loop really running" facts alone. Asserting `active` here
  # would be asserting the tool did the runner's job -- and doing it is what made
  # an ordinary resume look like a pickup from a dead process.
  def test_resume_raises_the_cap_and_leaves_the_wake_to_the_runner
    state = create
    @store.update(state.id) { |loop| loop.status = "paused" }
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_ok result
    assert_equal "paused", @store.load(state.id).status, "the runner wakes it, not this"
    assert_equal [ [ :resume, state.id ] ], @runner.calls
  end

  # The tool writes the file before it asks the runner to continue, and that
  # write used to say `active` for a loop it had just woken. The real runner then
  # read the file the tool had written, saw an active loop nobody was holding,
  # and counted a takeover for a run that was starting normally -- three of those
  # were enough to stall a healthy loop for good, with a log saying it kept dying.
  #
  # The test drives the real runner, because a fake one cannot see this: the bug
  # lived in the pair, not in either half.
  def test_a_paused_loop_woken_by_the_tool_is_not_counted_as_a_takeover
    state = create(repo: git_repo)
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.takeovers = 2
    end
    @tool.loop_runner = real_runner

    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_ok result
    reread = @store.load(state.id)
    assert_equal 0, reread.takeovers, "a deliberate wake starts the count over"
    refute(reread.log.any? { |entry| entry.text.start_with?("taken over") },
           "and is not written down as a run picked up off a dead process")
    assert_operator reread.iterations, :>=, 1,
                    "the wake has to have produced a run; a file left alone proves nothing"
  end

  # The bug this pair exists for: everything above passes with a fake runner, and
  # the wake written into the file was only harmful when the real runner read it
  # afterwards -- which is exactly what the channel does with a handed-off
  # request. This drives both halves in that order.
  def test_a_handed_off_wake_is_not_counted_as_a_takeover_when_the_runner_picks_it_up
    state = create(repo: git_repo)
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.takeovers = 2
    end
    @tool.agent = FakeAgent.new

    @tool.execute("operation" => "resume", "id" => state.id)
    assert_equal "paused", @store.load(state.id).status, "the hand-off wakes nothing by itself"

    real_runner.resume(state.id)

    reread = @store.load(state.id)
    assert_equal 0, reread.takeovers, "a resume the reader asked for is not a pickup off a dead process"
    refute(reread.log.any? { |entry| entry.text.start_with?("taken over") },
           "and the log must not say the loop kept dying")
    assert_operator reread.iterations, :>=, 1, "the runner picked it up and started work"
  end

  # The other half of the same pair: a file that already said `active` with
  # nobody holding it is a run that died, and the tool wakening it must leave the
  # counting to the runner rather than pretending it woke something.
  def test_an_active_loop_woken_by_the_tool_is_counted_as_one_takeover
    state = create(repo: git_repo)
    @tool.loop_runner = real_runner

    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_ok result
    assert_equal 1, @store.load(state.id).takeovers
  end

  def test_resume_on_a_done_loop_is_refused_and_leaves_it_done
    state = create
    @store.update(state.id) { |loop| loop.status = "done" }
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_error result
    assert_includes result, "done"
    assert_equal "done", @store.load(state.id).status
    assert_empty @runner.calls
  end

  # -- raising the cap on resume ---------------------------------------------

  # A loop that stopped at its cap is paused, and the cap is the one fact that
  # has to move for it to run again. The resume is where the user already is.
  def test_resume_with_a_higher_max_iterations_raises_the_cap_before_continuing
    state = cap_stopped(max_iterations: 2)
    caps_at_resume = []
    runner = FakeRunner.new { |id| caps_at_resume << @store.load(id).max_iterations }
    @tool.loop_runner = runner

    result = @tool.execute("operation" => "resume", "id" => state.id, "max_iterations" => 5)

    assert_ok result
    reread = @store.load(state.id)
    assert_equal 5, reread.max_iterations
    # The wake itself is the runner's write (see the real-runner tests below):
    # this half owns the cap, because a run that read it afterwards would never
    # see the number the reader asked for.
    assert_equal "paused", reread.status
    assert_equal [ 5 ], caps_at_resume, "the run must see the raised cap before it is asked to continue"
    assert_equal [ [ :resume, state.id ] ], runner.calls
  end

  def test_resume_refuses_a_cap_at_or_below_the_iterations_already_spent
    state = cap_stopped(max_iterations: 2)
    @tool.loop_runner = @runner

    [ 2, 1, 0 ].each do |cap|
      result = @tool.execute("operation" => "resume", "id" => state.id, "max_iterations" => cap)

      assert_error result
      assert_includes result, "must be above 2"
      reread = @store.load(state.id)
      assert_equal 2, reread.max_iterations, "a refused resume must leave the cap alone"
      assert_equal "paused", reread.status, "and must not revive the loop"
    end

    assert_empty @runner.calls
  end

  def test_resume_refuses_a_cap_that_is_not_a_whole_number
    state = cap_stopped(max_iterations: 2)
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "resume", "id" => state.id, "max_iterations" => "a few")

    assert_error result
    assert_includes result, "whole number"
    reread = @store.load(state.id)
    assert_equal 2, reread.max_iterations
    assert_equal "paused", reread.status
    assert_empty @runner.calls
  end

  # Allowed, and it must stay a resume of a capped loop: no cap is invented, so
  # the next run stops on the same number instead of running unbounded.
  def test_resume_without_a_cap_leaves_the_cap_where_it_was
    state = cap_stopped(max_iterations: 2)
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_ok result
    assert_equal 2, @store.load(state.id).max_iterations, "a resume must not raise a cap nobody asked for"
    assert_equal "paused", @store.load(state.id).status, "the wake is the runner's write"
    assert_equal [ [ :resume, state.id ] ], @runner.calls
  end

  # A loop already iterating is never started twice -- one worktree, one index,
  # one iteration number -- but its cap is still a fact worth raising. "Already
  # iterating" is the lease's answer, not the status field's: an active file is
  # only a loop that should be running.
  def test_resume_with_a_cap_on_an_active_loop_raises_it_without_starting_a_second_run
    state = create(max_iterations: 2)
    @store.update(state.id) { |loop| loop.iterations = 2 }
    @tool.loop_runner = @runner
    holder = Rubot::LoopLease.hold(@store.dir, state.id)

    result = @tool.execute("operation" => "resume", "id" => state.id, "max_iterations" => 6)

    assert_ok result
    assert_includes result, "already active"
    assert_equal 6, @store.load(state.id).max_iterations
    assert_empty @runner.calls, "an already active loop must not get a second run"
  ensure
    holder&.release
  end

  # An active file nobody holds is a run that died with its process, and that is
  # exactly the loop a resume is for: the guard must let it through. The status
  # is left alone here -- the runner's takeover branch is what records the event,
  # and writing `active` again would hide it.
  def test_resume_of_an_active_loop_nobody_is_running_reaches_the_runner
    state = create
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_ok result
    assert_includes result, "resumed"
    assert_equal [ [ :resume, state.id ] ], @runner.calls
    assert_equal 0, @store.load(state.id).takeovers, "the takeover is the runner's to count, not the tool's"
  end

  # A runner with a voice. The web channel's answers in words, and a tool that
  # speaks over them reports a wake the runner refused.
  class SpeakingRunner
    def initialize(answer) = @answer = answer
    def resume(_id) = @answer
  end

  # The runner is the part that knows whether a wake became a run, so a refusal
  # is carried rather than overruled: "resumed" for a loop that stayed put is the
  # same optimism as a resume with nothing behind it, one level up.
  def test_a_runner_that_refuses_the_wake_is_quoted_instead_of_overruled
    state = create
    @tool.loop_runner = SpeakingRunner.new(
      "OK: loop #{state.id} stays paused: resume refused: spent 6000 of 5000 tokens"
    )

    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_ok result
    assert_includes result, "stays paused"
    refute_includes result, "resumed", "the runner refused, so nothing was resumed"
  end

  # The note survives the hopeless path too: a cap raised on a loop this channel
  # cannot run is still a cap raised, and the sentence about nothing iterating
  # must not throw away the one thing the write bought.
  def test_a_resume_that_cannot_run_still_says_what_it_changed
    state = create
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.iterations = 2
    end

    result = @tool.execute("operation" => "resume", "id" => state.id, "max_iterations" => 6)

    assert_ok result
    assert_includes result, "its cap is now 6", "the raise happened, so the answer says so"
    assert_includes result, "nothing is iterating it"
    assert_equal 6, @store.load(state.id).max_iterations
  end

  # A resume with no runner and no agent is a write and nothing else: no part of
  # this channel can iterate a loop, so the file keeps saying paused and no
  # iteration follows. Answering "resumed" promised work nobody here would do.
  def test_resume_without_a_runner_or_an_agent_says_nothing_is_iterating_it
    state = create
    @store.update(state.id) { |loop| loop.status = "paused" }

    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_ok result
    assert_includes result, "nothing is iterating it"
    refute_includes result, "resumed", "nothing was resumed, and the answer must not say so"
    reread = @store.load(state.id)
    assert_equal "paused", reread.status, "nothing ran, so nothing was woken"
    assert_equal 0, reread.takeovers, "and no run was picked up off a dead process"
  end

  # -- the budget on resume --------------------------------------------------

  # A spent budget is the one stop a resume cannot walk away from: the run stops
  # on the same file's numbers before it spends anything, so a resume that only
  # moved the status would stop at the same boundary, one tick at a time. The
  # budget is the fact that has to move, and the resume is where the reader
  # already is when it happens.
  def test_resume_with_a_bigger_budget_raises_it_before_continuing
    state = budget_stopped
    budgets_at_resume = []
    runner = FakeRunner.new { |id| budgets_at_resume << @store.load(id).max_tokens }
    @tool.loop_runner = runner

    result = @tool.execute("operation" => "resume", "id" => state.id, "max_tokens" => 20_000)

    assert_ok result
    reread = @store.load(state.id)
    assert_equal 20_000, reread.max_tokens
    assert_equal "paused", reread.status, "the wake is the runner's write, the budget is this one's"
    assert_equal [ 20_000 ], budgets_at_resume, "the run must see the raised budget before it continues"
    assert_includes result, "20000", "the answer says what the loop may spend now"
    assert_equal [ [ :resume, state.id ] ], runner.calls
  end

  # Raising the budget is the only way on, so a resume that does not raise it is
  # refused where the reader can read why, instead of reviving a loop that stops
  # again before it spends a token.
  def test_resume_of_a_spent_loop_without_a_bigger_budget_is_refused
    state = budget_stopped
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_error result
    assert_includes result, "max_tokens"
    assert_includes result, "6000", "the answer says what was spent"
    assert_includes result, "5000", "and what it was allowed"
    reread = @store.load(state.id)
    assert_equal "paused", reread.status, "a refused resume must not revive the loop"
    assert_equal 5_000, reread.max_tokens, "and must not move the budget nobody raised"
    assert_empty @runner.calls
  end

  def test_resume_refuses_a_budget_at_or_below_what_was_already_spent
    state = budget_stopped
    @tool.loop_runner = @runner

    [ 6_000, 1 ].each do |budget|
      result = @tool.execute("operation" => "resume", "id" => state.id, "max_tokens" => budget)

      assert_error result
      assert_includes result, "6000", "a budget that does not clear the spend is not a way on"
      assert_equal "paused", @store.load(state.id).status
      assert_equal 5_000, @store.load(state.id).max_tokens
    end

    assert_empty @runner.calls
  end

  def test_resume_refuses_a_budget_that_is_not_a_whole_number
    state = budget_stopped
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "resume", "id" => state.id, "max_tokens" => "a lot")

    assert_error result
    assert_includes result, "whole number"
    assert_equal "paused", @store.load(state.id).status
    assert_empty @runner.calls
  end

  # -- raise a limit ---------------------------------------------------------

  # A loop stopped by either ceiling can only go on if the number that stopped
  # it moves, and the run reads that number from the file. The counters are the
  # one thing a raise must never touch: they are what was already paid for.
  def test_raise_moves_the_budget_and_leaves_the_spend_where_it_was
    state = budget_stopped
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "raise", "id" => state.id, "max_tokens" => 20_000)

    assert_ok result
    assert_includes result, "5000 -> 20000", "the answer names the old number beside the new one"
    reread = @store.load(state.id)
    assert_equal 20_000, reread.max_tokens
    assert_equal 6_000, reread.tokens, "a raise is not a refund"
    assert_equal 1, reread.iterations
    assert_equal "paused", reread.status, "a raise says what it may spend, resume says when"
    assert_empty @runner.calls
  end

  def test_raise_moves_the_cap_and_leaves_the_iteration_count_where_it_was
    state = cap_stopped(max_iterations: 2)
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "raise", "id" => state.id, "max_iterations" => 5)

    assert_ok result
    assert_includes result, "2 -> 5"
    reread = @store.load(state.id)
    assert_equal 5, reread.max_iterations
    assert_equal 2, reread.iterations, "a raise is not a rewind of the count"
    assert_equal 0, reread.tokens
    assert_empty @runner.calls
  end

  def test_raise_moves_both_ceilings_in_one_call
    state = cap_stopped(max_iterations: 2)
    @store.update(state.id) { |loop| loop.tokens = 6_000; loop.max_tokens = 5_000 }

    result = @tool.execute("operation" => "raise", "id" => state.id,
                           "max_iterations" => 5, "max_tokens" => 20_000)

    assert_ok result
    reread = @store.load(state.id)
    assert_equal 5, reread.max_iterations
    assert_equal 20_000, reread.max_tokens
    assert_equal 2, reread.iterations
    assert_equal 6_000, reread.tokens
  end

  def test_a_loop_raised_at_its_budget_resumes_past_the_budget
    state = budget_stopped
    @tool.loop_runner = @runner

    assert_ok @tool.execute("operation" => "raise", "id" => state.id, "max_tokens" => 20_000)
    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_ok result
    assert_equal [ [ :resume, state.id ] ], @runner.calls
    assert_operator @store.load(state.id).max_tokens, :>, @store.load(state.id).tokens,
                    "the run's own boundary no longer stops it before it spends"
  end

  def test_a_loop_raised_at_its_cap_resumes_past_the_cap
    state = cap_stopped(max_iterations: 2)
    @tool.loop_runner = @runner

    assert_ok @tool.execute("operation" => "raise", "id" => state.id, "max_iterations" => 4)
    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_ok result
    assert_equal [ [ :resume, state.id ] ], @runner.calls
    reread = @store.load(state.id)
    assert_operator reread.max_iterations, :>, reread.iterations
  end

  def test_raise_refuses_an_active_loop_and_moves_nothing
    state = create(max_tokens: 5_000)
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "raise", "id" => state.id, "max_tokens" => 20_000)

    assert_error result
    assert_includes result, "active", "the answer says which state refused it"
    reread = @store.load(state.id)
    assert_equal 5_000, reread.max_tokens
    assert_equal "active", reread.status
    assert_empty @runner.calls
  end

  def test_raise_refuses_a_done_loop_and_moves_nothing
    state = create(max_tokens: 5_000)
    @store.update(state.id) { |loop| loop.status = "done" }

    result = @tool.execute("operation" => "raise", "id" => state.id, "max_tokens" => 20_000)

    assert_error result
    assert_includes result, "done", "the answer says which state refused it"
    reread = @store.load(state.id)
    assert_equal 5_000, reread.max_tokens
    assert_equal "done", reread.status
  end

  # A "raise" that lowers a number, or writes the one already there, is not a
  # way out of anything: the run would stop at the same place or sooner, so it
  # is refused where the reader can still see the number that is in force.
  def test_raise_refuses_a_budget_that_does_not_clear_the_spend
    state = budget_stopped
    [ 6_000, 5_000, 1 ].each do |budget|
      result = @tool.execute("operation" => "raise", "id" => state.id, "max_tokens" => budget)

      assert_error result
      assert_includes result, "6000", "the answer says what the floor is"
      assert_equal 5_000, @store.load(state.id).max_tokens
    end
  end

  def test_raise_refuses_a_cap_that_does_not_clear_the_iterations_already_run
    state = cap_stopped(max_iterations: 2)
    [ 2, 1 ].each do |cap|
      result = @tool.execute("operation" => "raise", "id" => state.id, "max_iterations" => cap)

      assert_error result
      assert_includes result, "already allows"
      assert_equal 2, @store.load(state.id).max_iterations
    end
  end

  def test_raise_refuses_a_call_that_names_no_ceiling
    state = cap_stopped(max_iterations: 2)

    result = @tool.execute("operation" => "raise", "id" => state.id)

    assert_error result
    assert_includes result, "max_tokens"
    assert_includes result, "max_iterations"
    assert_equal 2, @store.load(state.id).max_iterations
  end

  def test_raise_refuses_a_number_that_is_not_whole
    state = budget_stopped

    result = @tool.execute("operation" => "raise", "id" => state.id, "max_tokens" => "a lot")

    assert_error result
    assert_includes result, "whole number"
    assert_equal 5_000, @store.load(state.id).max_tokens
  end

  def test_raise_writes_the_raise_into_the_log
    state = budget_stopped

    @tool.execute("operation" => "raise", "id" => state.id, "max_tokens" => 20_000)

    newest = @store.load(state.id).log.first.text
    assert_includes newest, "limit raised"
    assert_includes newest, "5000 -> 20000"
  end

  # -- undo ------------------------------------------------------------------

  # The warning's "drop" is this call in exactly this state: paused, with the
  # iteration nobody judged committed in a worktree still on disk. It goes back
  # one commit and leaves the counters alone, because a rewind of what was
  # spent would be a refund nobody gave.
  def test_undo_takes_a_paused_warning_loop_back_one_commit_and_leaves_the_counters
    worktrees = Rubot::LoopWorktree.new(root: File.join(@root, "worktrees"), repo: git_repo)
    state = create(repo: git_repo)
    dir = worktrees.create(id: state.id)
    File.write(File.join(dir, "step.txt"), "step one\n")
    worktrees.commit(state.id,
                     message: "#{Rubot::LoopRun::UNVERIFIED_MARKER} iteration 1: wrote step.txt")
    unjudged = worktrees.head(state.id)
    @store.update(state.id) do |loop|
      loop.worktree = dir
      loop.status = "paused"
      loop.iterations = 1
      loop.tokens = 10_800_000
    end

    assert_ok @tool.execute("operation" => "undo", "id" => state.id)

    refute_equal unjudged, worktrees.head(state.id), "the unjudged commit is off the branch"
    reread = @store.load(state.id)
    assert_equal 1, reread.iterations, "an undo is not a rewind of the count"
    assert_equal 10_800_000, reread.tokens, "nor of the spend"
    assert_equal "paused", reread.status, "dropping the work does not restart the loop"
  end

  def test_stop_pauses_the_loop_and_says_stopped
    state = create
    @tool.loop_runner = @runner

    result = @tool.execute("operation" => "stop", "id" => state.id)

    assert_ok result
    assert_includes result, "stopped"
    assert_equal "paused", @store.load(state.id).status
    assert_equal [ [ :abort, state.id ] ], @runner.calls
  end

  # -- hand-off to the agent -------------------------------------------------

  # In actor mode the channel holds a proxy, so no runner can be attached here.
  # The agent is the way out, and its sentence is what the model reads.
  def test_start_with_an_agent_and_no_runner_asks_the_agent
    agent = FakeAgent.new
    @tool.agent = agent

    result = start_loop

    assert_ok result
    assert_includes result, "background"
    assert_equal 1, agent.requests.size
    assert_equal :start, agent.requests.first[:op]
    assert_equal @store.ids.first, agent.requests.first[:id]
  end

  # A runner on this side iterates without crossing a Ractor, so a round trip
  # through the agent would only be a second way to start the same loop.
  def test_a_local_runner_is_used_without_asking_the_agent
    agent = FakeAgent.new
    @tool.agent = agent
    @tool.loop_runner = @runner

    result = start_loop

    assert_ok result
    assert_equal [ [ :start, @store.ids.first ] ], @runner.calls
    assert_empty agent.requests, "the agent must not be asked when a runner is here"
  end

  # nil is the signal that no channel asked for loops, not an error: the tool
  # owes its honest sentence, exactly as it gave before the agent existed.
  def test_an_agent_that_answers_nil_leaves_the_honest_message
    @tool.agent = FakeAgent.new(nil)

    result = start_loop

    assert_includes result, "no runner is attached"
  end

  def test_resume_with_an_agent_and_no_runner_asks_the_agent_to_resume
    state = create
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.takeovers = 2
    end
    @tool.agent = FakeAgent.new

    result = @tool.execute("operation" => "resume", "id" => state.id)

    assert_ok result
    reread = @store.load(state.id)
    # The hand-off is a request, not a run: the file keeps saying paused, and the
    # runner the channel wakes from it is what moves the status and the count.
    # This side writing them is what let an ordinary resume be counted as a
    # takeover once the real runner read the file.
    assert_equal "paused", reread.status
    assert_equal 2, reread.takeovers
    assert_equal [ { op: :resume, id: state.id } ], @tool.instance_variable_get(:@agent).requests
  end

  # Pause and stop are one write on this side, and one request to the channel:
  # its runner is what knows whether the run is still being paid for.
  def test_pause_with_an_agent_and_no_runner_asks_the_agent_to_abort
    state = create
    @tool.agent = FakeAgent.new("OK: the runner was told to abort")

    result = @tool.execute("operation" => "pause", "id" => state.id)

    assert_includes result, "told to abort"
    assert_equal "paused", @store.load(state.id).status
    assert_equal [ { op: :abort, id: state.id } ], @tool.instance_variable_get(:@agent).requests
  end

  # -- robustness ------------------------------------------------------------

  def test_an_unknown_operation_lists_the_valid_ones
    result = @tool.execute("operation" => "explode")

    assert_error result
    Rubot::Tools::Loop::OPERATIONS.each { |name| assert_includes result, name }
  end

  def test_the_tool_never_raises_when_the_store_cannot_be_created
    blocker = File.join(@tmp, "blocked")
    File.write(blocker, "a file where the loops directory should be")
    tool = Rubot::Tools::Loop.new(store_root: blocker)

    result = tool.execute(
      "operation" => "start", "goal" => "g", "done_criteria" => "d", "repo" => @repo
    )

    assert_error result
    assert_includes result, blocker
    assert_equal "No loops.", tool.execute("operation" => "list")
  end
end
