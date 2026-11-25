# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "open3"

require "rubot/loop_run"

# The cycle only ever sees the model through the `runner` lambda and the
# judgement through `verifier`, so every test here drives real git and a real
# state file with two plain lambdas: no provider, no network, no sleep.
class TestLoopRun < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("rubot-loop-run")
    @repo = File.join(@tmp, "demo")
    FileUtils.mkdir_p(@repo)
    git(@repo, "init", "-b", "main")
    git(@repo, "config", "user.email", "loop@example.com")
    git(@repo, "config", "user.name", "Loop Test")
    File.write(File.join(@repo, "README.md"), "demo\n")
    git(@repo, "add", "-A")
    git(@repo, "commit", "-m", "init")

    @store = Rubot::LoopStore.new(dir: File.join(@tmp, "loops"))
    @worktree = Rubot::LoopWorktree.new(root: File.join(@tmp, "worktrees"), repo: @repo)
    @contexts = []
    @verify_contexts = []
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.exist?(@tmp)
  end

  # -- helpers ---------------------------------------------------------------

  # A store that pauses a loop immediately *after* the run has read it, which is
  # the one gap a run cannot see by trusting the status it read: the state the
  # run gets back still says "active", and the pause is already on disk by the
  # time it looks again. Armed only once the worktree exists, because that read
  # is the one at the top of the first iteration.
  class StoreThatPausesAfterReading
    def initialize(store)
      @store = store
      @armed = true
    end

    def load(id)
      state = @store.load(id)
      arm(state, id)
      state
    end

    def update(id, &block) = @store.update(id, &block)

    private

    def arm(state, id)
      return unless @armed && state && state.worktree && state.status == "active"

      @armed = false
      @store.update(id) { |loop| loop.status = "paused" }
    end
  end

  def git(dir, *args)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end

  def new_loop(max_iterations: 8)
    @store.create(goal: "make the demo honest", done_criteria: "the demo test is green",
                  repo: @repo, max_iterations: max_iterations)
  end

  def runner(&block)
    lambda do |ctx|
      @contexts << ctx
      block.call(ctx)
    end
  end

  def verifier(&block)
    lambda do |ctx|
      @verify_contexts << ctx
      block.call(ctx)
    end
  end

  # Answers the canned script in order, so a test says what the verifier thinks
  # once per iteration instead of building a state machine.
  def verdicts(*script)
    queue = script.dup
    verifier { queue.shift || { verdict: :not_yet, reason: "still red" } }
  end

  def write_file(ctx, name, body)
    File.write(File.join(ctx[:worktree], name), body)
  end

  def commits_in(id)
    git(@worktree.path(id), "rev-list", "--count", "HEAD").to_i
  end

  # The one entry an iteration writes, as the file spells it: the verdict's is
  # the other entry, and the loop's own start and worktree notes are neither.
  def iteration_entry(id)
    @store.load(id).log.map(&:text).find { |text| text.start_with?("iteration 1 ") }
  end

  # Seven characters, the way the entry names the commit it stands on.
  def head_sha(id) = git(@worktree.path(id), "rev-parse", "HEAD").strip[0, 7]

  # A repository-level hook that refuses, which is the cheapest way to make a
  # `git commit` fail after the iteration has already been paid for.
  def failing_hook(repo)
    hook = File.join(repo, ".git", "hooks", "pre-commit")
    FileUtils.mkdir_p(File.dirname(hook))
    File.write(hook, "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, hook)
  end

  # The budget comes from the state file unless a test names one: that is the
  # behaviour under test, so the helper must not hide it behind a default.
  def loop_run(runner:, verifier:, max_tokens: nil)
    Rubot::LoopRun.new(store: @store, worktree: @worktree,
                       runner: runner, verifier: verifier, max_tokens: max_tokens)
  end

  # -- stopping --------------------------------------------------------------

  def test_a_done_verdict_ends_the_loop
    state = new_loop
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "a.txt", "1\n"); { text: "added a.txt", tokens: 1_000 } },
      verifier: verdicts({ verdict: :done, reason: "a.txt exists" })
    )

    result = run.call(state.id)

    assert_equal :done_by_verifier, result.stop_reason
    assert_equal 1, result.iterations_run
    assert_equal "done", @store.load(state.id).status
    assert_equal 2, commits_in(state.id)
  end

  def test_the_loop_keeps_going_while_the_verifier_says_not_yet
    # The cap is what ends this one: three rejections in a row with different
    # reasons mean the loop is still working, not stuck.
    state = new_loop(max_iterations: 3)
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 100 } },
      verifier: verdicts({ verdict: :not_yet, reason: "red one" },
                         { verdict: :not_yet, reason: "red two" },
                         { verdict: :not_yet, reason: "red three" })
    )

    result = run.call(state.id)

    assert_equal :max_iterations, result.stop_reason
    assert_equal 3, result.iterations_run
    assert_equal 3, @contexts.size
    assert_equal "paused", result.state.status
  end

  # The cap stop is the one the file used to get wrong: it left `active` behind
  # at it=2/2, so `loop list` showed a loop that had stopped as still running and
  # nothing would ever move it. It settles like every other stop does.
  def test_max_iterations_stops_the_loop_before_the_verifier_agrees
    state = new_loop(max_iterations: 2)
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 100 } },
      verifier: verdicts({ verdict: :not_yet, reason: "red one" },
                         { verdict: :not_yet, reason: "red two" })
    )

    result = run.call(state.id)

    assert_equal :max_iterations, result.stop_reason
    assert_equal 2, result.iterations_run
    assert_equal 2, @contexts.size, "the runner must not be asked again after the cap"

    reread = @store.load(state.id)
    assert_equal "paused", reread.status, "the file must not read active after the loop stopped"
    assert_equal 2, reread.max_iterations, "the cap itself is unchanged; only the status moves"
    note = reread.log.first.text
    assert_includes note, "cap"
    assert_includes note, "max_iterations", "the note says which cap has to be raised before resuming"
    refute_equal :budget, result.stop_reason, "the cap is not the budget"
  end

  # Paused is only half the repair: the cap has to move, and the run reads it
  # from the file, which is what lets the next run go past the old one.
  def test_a_raised_cap_lets_the_run_continue_past_the_old_one
    state = new_loop(max_iterations: 2)
    n = 0
    step = runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 100 } }

    capped = loop_run(
      runner: step,
      verifier: verdicts({ verdict: :not_yet, reason: "red one" },
                         { verdict: :not_yet, reason: "red two" })
    ).call(state.id)

    assert_equal :max_iterations, capped.stop_reason
    assert_equal 2, @store.load(state.id).iterations

    # What the tool's resume with max_iterations writes: the cap, then active.
    @store.update(state.id) do |loop|
      loop.max_iterations = 4
      loop.status = "active"
    end

    resumed = loop_run(
      runner: step,
      verifier: verdicts({ verdict: :not_yet, reason: "red three" },
                         { verdict: :not_yet, reason: "red four" })
    ).call(state.id)

    assert_equal :max_iterations, resumed.stop_reason
    assert_equal 4, resumed.iterations_run
    assert_equal [ 3, 4 ], @contexts.drop(2).map { |ctx| ctx[:iteration] }
    reread = @store.load(state.id)
    assert_equal 4, reread.max_iterations, "the new cap is what the file records"
    assert_equal 4, reread.iterations
    assert_equal "paused", reread.status
  end

  # A resume with no cap is allowed -- the file stops saying paused -- but it
  # must not quietly turn a capped loop into an unbounded one: the run refuses
  # on the same number and the reader is never surprised by a new spend.
  def test_resuming_a_cap_stop_without_raising_the_cap_stops_at_the_same_place
    state = new_loop(max_iterations: 2)
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 100 } },
      verifier: verdicts({ verdict: :not_yet, reason: "red one" },
                         { verdict: :not_yet, reason: "red two" })
    )
    run.call(state.id)
    spent = @store.load(state.id).tokens

    @store.update(state.id) { |loop| loop.status = "active" } # a resume with no cap

    again = run.call(state.id)

    assert_equal :max_iterations, again.stop_reason
    assert_equal 2, again.iterations_run
    assert_equal 2, @contexts.size, "no iteration may run past a cap that did not move"
    reread = @store.load(state.id)
    assert_equal 2, reread.max_iterations
    assert_equal spent, reread.tokens, "a stop at the cap costs nothing"
    assert_equal "paused", reread.status
  end

  # The budget's pause is LoopRunner#settle's to write, and the cap's is this
  # run's: what is locked here is that the two never get confused, so neither
  # stop can borrow the other's reason or its note.
  def test_a_budget_stop_is_not_a_cap_stop
    state = new_loop
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 30_000 } },
      verifier: verdicts,
      max_tokens: 50_000
    )

    result = run.call(state.id)

    assert_equal :budget, result.stop_reason
    reread = @store.load(state.id)
    assert_equal 60_000, reread.tokens
    refute(reread.log.any? { |entry| entry.text.include?("cap") },
           "a budget stop must not write the cap's note")
  end

  def test_the_token_budget_stops_the_loop
    state = new_loop
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 30_000 } },
      verifier: verdicts({ verdict: :not_yet, reason: "red one" },
                         { verdict: :not_yet, reason: "red two" }),
      max_tokens: 50_000
    )

    # An iteration cannot be interrupted mid-flight, so the second one is paid
    # for in full: 30k in, 60k out. The overshoot is the cost of not stopping an
    # agent in the middle of its work; what must never happen is a third one.
    result = run.call(state.id)

    assert_equal :budget, result.stop_reason
    assert_equal 2, result.iterations_run
    assert_equal 60_000, @store.load(state.id).tokens
    assert_equal 2, @contexts.size, "no iteration may start once the budget is spent"
  end

  # The cap belongs to the loop, not to whoever constructs the run: a resumed
  # run, a cron retry or a second process that forgets the argument must still
  # see a spent budget instead of being handed a fresh one.
  def test_the_token_budget_is_read_from_the_file_not_the_constructor
    state = @store.create(goal: "make the demo honest", done_criteria: "the demo test is green",
                          repo: @repo, max_tokens: 50_000)
    n = 0
    spending = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 30_000 } },
      verifier: verdicts({ verdict: :not_yet, reason: "red one" },
                         { verdict: :not_yet, reason: "red two" })
    )

    first = spending.call(state.id)

    assert_equal :budget, first.stop_reason
    assert_equal 60_000, @store.load(state.id).tokens
    # A spent budget is a pause, the same status a cap stop leaves: nothing is
    # iterating, and the loop is still resumable.
    assert_equal "paused", @store.load(state.id).status

    # Woken up with the budget already spent, which is what a resume after one
    # looks like: the run reads the budget from the file, so nothing is bought.
    @store.update(state.id) { |loop| loop.status = "active" }

    again = loop_run(
      runner: runner { |ctx| write_file(ctx, "later.txt", "x\n"); { text: "another go", tokens: 30_000 } },
      verifier: verdicts({ verdict: :not_yet, reason: "still red" })
    ).call(state.id)

    assert_equal :budget, again.stop_reason
    assert_equal 2, again.iterations_run
    assert_equal 60_000, @store.load(state.id).tokens
    assert_equal 2, @contexts.size, "the second run must spend nothing"
  end

  # The channel's runner pays the store as each usage report arrives and cancels
  # the turn the moment the loop's budget is reached, so the run is handed a
  # finished turn that says where it stopped. What is locked here: the work the
  # stopped turn left behind is still committed, the reason is the budget, the
  # total it reports is not charged a second time, and the verdict -- a second
  # turn of the same size -- is never bought.
  def test_a_runner_stopped_by_the_budget_commits_its_work_and_buys_no_verdict
    budget = 50_000
    state = @store.create(goal: "make the demo honest", done_criteria: "the demo test is green",
                          repo: @repo, max_tokens: budget)
    reports = []
    run = loop_run(
      runner: runner do |ctx|
        write_file(ctx, "step1.txt", "1\n")
        # Four requests of 20k inside one turn, each report the turn's running
        # total, debited as the difference -- what the channel does, and why the
        # last report is the total rather than their sum.
        paid = 0
        [ 20_000, 40_000, 60_000, 80_000 ].each do |total|
          @store.update(ctx[:id]) { |loop| loop.tokens = loop.tokens.to_i + (total - paid) }
          paid = total
          reports << total
          break if total >= budget # the turn is cancelled here, and reports no more
        end
        { text: "half a step", tokens: 0, budget_stopped: true }
      end,
      verifier: verdicts({ verdict: :not_yet, reason: "red one" })
    )

    result = run.call(state.id)

    assert_equal :budget, result.stop_reason
    assert_equal 1, result.iterations_run
    reread = @store.load(state.id)
    assert_equal "paused", reread.status, "a spent budget pauses the loop, the same status a cap stop leaves"
    assert_equal reports.last, reread.tokens,
                 "the store holds the turn's own total, not the total plus the reports that made it"
    assert_operator reread.tokens, :<=, budget + 20_000,
                    "a turn stopped from the inside overshoots by one report at most"
    assert_equal 2, commits_in(state.id), "the work the stopped turn left behind is on the branch, on top of the init one"
    assert_empty @verify_contexts, "a verdict is a whole turn the loop can no longer afford"
    assert(reread.log.any? { |entry| entry.text.include?("budget spent") },
           reread.log.map(&:text).inspect)
    refute(reread.log.any? { |entry| entry.text.include?("cap") },
           "a budget stop must not borrow the cap's note")
  end

  # The verifier is a second full turn, and the run used to buy one with a
  # budget that was already spent. Counted here: once the work turn has finished
  # the loop's budget, the verifier lambda is never called -- and the work is
  # committed anyway, because stopping short costs the loop its verdict, never
  # the work it paid for.
  def test_the_verifier_is_not_asked_once_the_budget_is_spent
    state = @store.create(goal: "make the demo honest", done_criteria: "the demo test is green",
                          repo: @repo, max_tokens: 50_000)
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 60_000 } },
      verifier: verdicts({ verdict: :not_yet, reason: "red one" })
    )

    result = run.call(state.id)

    assert_equal :budget, result.stop_reason
    assert_empty @verify_contexts, "the verdict costs a full turn the loop cannot afford"
    assert_equal 60_000, @store.load(state.id).tokens
    assert_equal 2, commits_in(state.id), "the turn's work is on the branch, on top of the init one, even though it was never judged"
  end

  # What the run tells its runner, and the whole point of it: the budget and
  # what the loop had spent when the turn began. A runner that respects them can
  # stop a turn in flight; waiting for the turn to end is what let one spend a
  # whole budget and more.
  def test_the_runner_is_told_the_budget_and_what_was_spent_before_the_turn
    state = @store.create(goal: "make the demo honest", done_criteria: "the demo test is green",
                          repo: @repo, max_tokens: 80_000)
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 30_000 } },
      verifier: verdicts
    )

    result = run.call(state.id)

    assert_equal :budget, result.stop_reason
    assert_equal [ 80_000, 80_000, 80_000 ], @contexts.map { |ctx| ctx[:budget] }
    assert_equal [ 0, 30_000, 60_000 ], @contexts.map { |ctx| ctx[:spent] },
                 "each turn is told what the ones before it cost"
  end

  def test_a_loop_bound_to_another_repository_is_refused
    state = new_loop
    elsewhere = Rubot::LoopWorktree.new(root: File.join(@tmp, "other-worktrees"),
                                        repo: File.join(@tmp, "not-this-repo"))
    result = Rubot::LoopRun.new(store: @store, worktree: elsewhere,
                                runner: runner { { text: "should not run", tokens: 10 } },
                                verifier: verdicts({ verdict: :done, reason: "nothing" })).call(state.id)

    assert_equal :repo_mismatch, result.stop_reason
    assert_empty @contexts, "a mismatched loop must not reach the model"
    assert_equal 0, @store.load(state.id).tokens
  end

  def test_every_stop_reason_is_declared
    %i[done_by_verifier max_iterations budget stalled verifier_stuck paused not_active
       missing error worktree_missing repo_mismatch].each do |reason|
      assert_includes Rubot::LoopRun::STOP_REASONS, reason
    end
  end

  def test_an_agent_that_produces_nothing_twice_is_stalled
    state = new_loop
    run = loop_run(
      runner: runner { { text: "looked at it again", tokens: 100 } },
      verifier: verdicts({ verdict: :not_yet, reason: "still red" },
                         { verdict: :not_yet, reason: "still red" })
    )

    result = run.call(state.id)

    assert_equal :stalled, result.stop_reason
    assert_equal 2, result.iterations_run
    assert_equal "stalled", @store.load(state.id).status
  end

  # The regression lock for the stuck stop as it was always meant to work: the
  # same sentence, three times, byte for byte. It must keep passing unchanged.
  def test_a_verifier_that_repeats_itself_pauses_the_loop
    state = new_loop
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 100 } },
      verifier: verdicts({ verdict: :not_yet, reason: "tests still red" },
                         { verdict: :not_yet, reason: "tests still red" },
                         { verdict: :not_yet, reason: "tests still red" })
    )

    result = run.call(state.id)

    assert_equal :verifier_stuck, result.stop_reason
    assert_equal 3, result.iterations_run
    assert_equal "paused", @store.load(state.id).status
  end

  # What a real verifier writes names the file it looked at and the number it
  # counted there, so an agent that keeps producing work while the criteria never
  # pass hands back a different string every iteration. Compared raw, this loop
  # ran to the cap and was reported as :max_iterations -- the one stop meant to
  # catch it could only fire against a fake verifier that repeats itself, which
  # was the test proving itself instead of the behaviour.
  def test_refusals_that_differ_only_in_a_file_name_and_a_count_are_stuck
    state = new_loop
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 100 } },
      # The three refusals from the run that exposed this, and the same shape
      # after them -- "case notes/03.md has 2 entries", ".../04.md has 7",
      # ".../05.md has 12" -- so an unfixed run cannot stop by coincidence when
      # the script runs out: every reason names a different file and a count.
      verifier: verifier do |ctx|
        { verdict: :not_yet,
          reason: "case notes/%02d.md has %d entries" % [ ctx[:iteration] + 2, ctx[:iteration] * 5 - 3 ] }
      end
    )

    result = run.call(state.id)

    assert_equal :verifier_stuck, result.stop_reason
    assert_equal 3, result.iterations_run
    assert_equal "paused", @store.load(state.id).status
  end

  # The other half of that rule, and the guarantee that keeps it honest: three
  # refusals that differ in substance are three different failures, so the loop
  # is still working and must be allowed past the third one.
  def test_refusals_that_differ_in_substance_are_not_a_stuck_verifier
    state = new_loop(max_iterations: 4)
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 100 } },
      verifier: verdicts({ verdict: :not_yet, reason: "the API is undocumented" },
                         { verdict: :not_yet, reason: "the tests do not compile" },
                         { verdict: :not_yet, reason: "the config is missing" },
                         { verdict: :not_yet, reason: "the README lies about the setup" })
    )

    result = run.call(state.id)

    refute_equal :verifier_stuck, result.stop_reason
    assert_equal :max_iterations, result.stop_reason
    assert_equal 4, result.iterations_run
    assert_equal 4, @contexts.size, "the loop must keep going past the third refusal"
  end

  # Only the comparison is normalised. The note on disk and the message the
  # caller gets are the verifier's own sentence, because that is what the user
  # has to act on -- a placeholder would tell them nothing.
  def test_the_result_and_the_log_keep_the_raw_reason_not_the_normalised_one
    state = new_loop
    n = 0
    reasons = [ "case notes/03.md has 2 entries", "case notes/04.md has 7 entries",
                "case notes/05.md has 12 entries" ]
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 100 } },
      verifier: verdicts(*reasons.map { |reason| { verdict: :not_yet, reason: reason } })
    )

    result = run.call(state.id)

    assert_equal :verifier_stuck, result.stop_reason
    assert_equal "case notes/05.md has 12 entries", result.message, "the result carries the raw third reason"

    log = @store.load(state.id).log.map(&:text)
    assert_includes log.first, "case notes/05.md has 12 entries", "the stuck note quotes the raw reason"
    reasons.each { |reason| assert_includes log, "verifier: #{reason}", "each verdict is logged as written" }
    assert(log.none? { |line| line.include?("<var>") }, "the placeholder is for the comparison only")
  end

  # The counter restarts at the first refusal of a new streak, so one repeated
  # twice after a change of subject is not the same as one repeated three times:
  # this loop fires on the fifth iteration, not the third.
  def test_a_different_refusal_starts_the_stuck_count_again
    state = new_loop
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 100 } },
      verifier: verdicts({ verdict: :not_yet, reason: "the API is undocumented" },
                         { verdict: :not_yet, reason: "the tests do not compile" },
                         { verdict: :not_yet, reason: "the config is missing" },
                         { verdict: :not_yet, reason: "the config is missing" },
                         { verdict: :not_yet, reason: "the config is missing" },
                         { verdict: :not_yet, reason: "never reached" })
    )

    result = run.call(state.id)

    assert_equal :verifier_stuck, result.stop_reason
    assert_equal 5, result.iterations_run, "two refusals of one failure are not three"
    assert_equal 5, @contexts.size, "nothing is spent after the third repeat"
  end

  # A loop that recovers must still end done, whatever the stuck counter has
  # counted so far: the done verdict is read before anything is called stuck.
  def test_a_run_that_recovers_on_the_third_iteration_still_ends_done
    state = new_loop
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 100 } },
      verifier: verdicts({ verdict: :not_yet, reason: "the demo fails" },
                         { verdict: :not_yet, reason: "the demo still fails" },
                         { verdict: :done, reason: "the demo test is green" })
    )

    result = run.call(state.id)

    assert_equal :done_by_verifier, result.stop_reason
    assert_equal 3, result.iterations_run
    assert_equal "done", @store.load(state.id).status
  end

  # -- failure ---------------------------------------------------------------

  def test_a_runner_that_raises_pauses_the_loop_with_the_reason_on_disk
    state = new_loop
    run = loop_run(
      runner: runner { raise "boom" },
      verifier: verdicts
    )

    result = run.call(state.id)

    assert_equal :error, result.stop_reason
    assert_match(/boom/, result.message)
    state = @store.load(state.id)
    assert_equal "paused", state.status
    assert_equal 1, state.iterations
    assert(state.log.any? { |entry| entry.text.include?("boom") })
  end

  def test_a_runner_that_answers_with_an_error_is_the_same_as_raising
    state = new_loop
    run = loop_run(
      runner: runner { { text: "", tokens: 42, error: "provider refused" } },
      verifier: verdicts
    )

    result = run.call(state.id)

    assert_equal :error, result.stop_reason
    assert_match(/provider refused/, result.message)
    state = @store.load(state.id)
    assert_equal "paused", state.status
    assert_equal 42, state.tokens, "a failed iteration still spent its tokens"
  end

  def test_a_missing_loop_is_reported_without_running_anything
    run = loop_run(runner: runner { flunk "must not run" }, verifier: verdicts)

    result = run.call("20260101-000000-abcd")

    assert_equal :missing, result.stop_reason
    assert_nil result.state
    assert_empty @contexts
  end

  def test_a_loop_that_is_already_finished_does_not_run_again
    state = new_loop
    @store.update(state.id) { |s| s.status = "done" }
    run = loop_run(runner: runner { flunk "must not run" }, verifier: verdicts)

    result = run.call(state.id)

    assert_equal :not_active, result.stop_reason
    assert_empty @contexts
  end

  # -- the worktree ----------------------------------------------------------

  def test_the_worktree_is_made_on_the_first_call_and_written_back
    state = new_loop
    refute @worktree.exists?(state.id), "a fresh loop has no worktree yet"
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "a.txt", "1\n"); { text: "added a.txt", tokens: 10 } },
      verifier: verdicts({ verdict: :done, reason: "fine" })
    )

    run.call(state.id)

    state = @store.load(state.id)
    assert File.directory?(state.worktree)
    assert_equal "loop/#{state.id}", state.branch
    assert_equal @worktree.path(state.id), state.worktree
    assert_equal "demo\n", File.read(File.join(@repo, "README.md")), "the user's checkout stays put"
  end

  def test_the_runner_sees_the_goal_the_criteria_and_the_newest_log_entries
    state = new_loop(max_iterations: 1)
    15.times { |i| @store.append_log(state.id, "earlier note #{i}") }
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "a.txt", "1\n"); { text: "added a.txt", tokens: 10 } },
      verifier: verdicts({ verdict: :done, reason: "fine" })
    )

    run.call(state.id)

    context = @contexts.first
    assert_equal state.id, context[:id]
    assert_equal 1, context[:iteration]
    assert_equal "make the demo honest", context[:goal]
    assert_equal "the demo test is green", context[:done_criteria]
    assert_equal @worktree.path(state.id), context[:worktree]
    assert_equal 10, context[:log].size
    assert_equal "earlier note 14", context[:log].first, "newest entry first"
  end

  def test_the_commit_subject_is_the_first_line_of_the_report
    state = new_loop
    long = "first line that is far too long to be a commit subject, so it has to be cut somewhere"
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "a.txt", "1\n"); { text: "#{long}\nsecond line", tokens: 10 } },
      verifier: verdicts({ verdict: :done, reason: "fine" })
    )

    run.call(state.id)

    subject = git(@worktree.path(state.id), "log", "-1", "--format=%s").strip
    assert_equal long[0, 72].strip, subject
    refute_match(/second line/, subject)
  end

  def test_progress_is_persisted_every_iteration_not_only_at_the_end
    state = new_loop
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 30_000 } },
      verifier: verdicts({ verdict: :not_yet, reason: "red one" },
                         { verdict: :not_yet, reason: "red two" }),
      max_tokens: 50_000
    )

    run.call(state.id)

    reread = Rubot::LoopStore.new(dir: File.join(@tmp, "loops")).load(state.id)
    assert_equal 2, reread.iterations
    assert_equal 60_000, reread.tokens
  end

  # -- the six regressions ---------------------------------------------------

  # Bug 1: the run kept its counters in memory and wrote them once, at the end,
  # so a paused run came back with a fresh budget. Each iteration now charges
  # the store before the next runner call, which is what this test watches.
  def test_the_counters_are_on_disk_before_the_next_iteration_starts
    state = new_loop
    seen = []
    run = loop_run(
      runner: runner do |_ctx|
        store = @store.load(state.id)
        seen << [ store.iterations, store.tokens ]
        { text: "nothing to show", tokens: 10 }
      end,
      verifier: verdicts
    )

    run.call(state.id)

    assert_equal [ [ 0, 0 ], [ 1, 10 ] ], seen
  end

  # Bug 2: the status was read once, before the run, so a pause issued while an
  # iteration was working was ignored until the budget ran out.
  def test_a_pause_issued_mid_run_stops_the_loop_before_the_next_iteration
    state = new_loop
    n = 0
    run = loop_run(
      runner: runner do |ctx|
        n += 1
        write_file(ctx, "step#{n}.txt", "#{n}\n")
        @store.update(state.id) { |s| s.status = "paused" } if n == 1
        { text: "step #{n}", tokens: 100 }
      end,
      verifier: verdicts
    )

    result = run.call(state.id)

    assert_equal :paused, result.stop_reason
    assert_equal 1, result.iterations_run
    assert_equal 1, @contexts.size, "the loop must not pay for another iteration"
    assert_equal "paused", @store.load(state.id).status
  end

  # Bug 2, the other half: a loop finished underneath the run is not a pause.
  def test_a_loop_finished_mid_run_stops_as_finished_not_as_paused
    state = new_loop
    n = 0
    run = loop_run(
      runner: runner do |ctx|
        n += 1
        write_file(ctx, "step#{n}.txt", "#{n}\n")
        @store.update(state.id) { |s| s.status = "done" } if n == 1
        { text: "step #{n}", tokens: 100 }
      end,
      verifier: verdicts
    )

    result = run.call(state.id)

    assert_equal :not_active, result.stop_reason
    assert_equal 1, @contexts.size
    assert_equal "done", @store.load(state.id).status
  end

  # Bug 3: the run counted iterations itself and wrote that count over the one
  # on disk, so a resumed loop restarted at one. The store is the only counter.
  def test_a_resumed_run_reads_the_iteration_count_from_the_store
    state = new_loop(max_iterations: 5)
    @store.update(state.id) do |s|
      s.iterations = 3
      s.tokens = 900
    end
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "step#{ctx[:iteration]}.txt", "x\n"); { text: "step", tokens: 100 } },
      verifier: verdicts
    )

    result = run.call(state.id)

    assert_equal 5, result.iterations_run
    assert_equal [ 4, 5 ], @contexts.map { |ctx| ctx[:iteration] }
    reread = Rubot::LoopStore.new(dir: File.join(@tmp, "loops")).load(state.id)
    assert_equal 5, reread.iterations
    assert_equal 1_100, reread.tokens
  end

  # Bug 4: a worktree removed underneath the run raised Errno::ENOENT out of
  # #call, which the caller cannot act on. It is a stop, and the iteration in
  # flight has already been charged (bug 1), so nothing spent is lost either.
  def test_a_worktree_removed_underneath_the_run_stops_instead_of_raising
    state = new_loop
    n = 0
    run = loop_run(
      runner: runner do |ctx|
        n += 1
        FileUtils.remove_entry(ctx[:worktree]) if n == 2
        { text: "step #{n}", tokens: 100 }
      end,
      verifier: verdicts
    )

    result = run.call(state.id)

    assert_equal :worktree_missing, result.stop_reason
    assert_match(/worktree is missing/, result.message)
    assert_equal 2, result.iterations_run
    reread = @store.load(state.id)
    assert_equal "paused", reread.status
    assert_equal 200, reread.tokens, "the iteration in flight still spent its tokens"
  end

  # Bug 5: stall detection read the worktree's dirty state, so an agent that
  # committed its own work looked idle every iteration.
  def test_a_runner_that_commits_its_own_work_is_not_a_stall
    state = new_loop(max_iterations: 3)
    # Three refusals that differ in substance, not only in the number after
    # "red": a count is folded out of the stuck comparison, so a reason built
    # from one would end this run as verifier_stuck instead of at the cap, and
    # the stall this test is about would never be the thing under test.
    refusals = [ "red: the demo check fails", "red: the lint job is unhappy", "red: the docs are stale" ]
    run = loop_run(
      runner: runner do |ctx|
        name = "own-#{ctx[:iteration]}.txt"
        write_file(ctx, name, "x\n")
        git(ctx[:worktree], "add", "-A")
        git(ctx[:worktree], "commit", "-m", name)
        { text: "wrote #{name}", tokens: 10, commit: git(ctx[:worktree], "rev-parse", "HEAD").strip }
      end,
      verifier: verdicts(*refusals.map { |reason| { verdict: :not_yet, reason: reason } })
    )

    result = run.call(state.id)

    assert_equal :max_iterations, result.stop_reason
    assert_equal 3, result.iterations_run
    assert_equal 4, commits_in(state.id), "three commits of its own on top of the init one"
  end

  # Bug 5, the other half: when the worktree is dirty but the runner says it made
  # no progress, that report is what counts, not the leftover file.
  def test_an_explicit_no_progress_report_is_a_stall_however_dirty_the_worktree_is
    state = new_loop
    run = loop_run(
      runner: runner do |ctx|
        write_file(ctx, "scratch.txt", "#{ctx[:iteration]}\n")
        { text: "churned", tokens: 10, progress: false }
      end,
      verifier: verdicts
    )

    result = run.call(state.id)

    assert_equal :stalled, result.stop_reason
    assert_equal 2, result.iterations_run
  end

  # Bug 6: the subject was built from the flattened report, so a second line
  # rode along into the commit message.
  def test_a_multiline_report_cannot_make_a_multiline_commit_subject
    state = new_loop
    run = loop_run(
      runner: runner do |ctx|
        write_file(ctx, "a.txt", "1\n")
        { text: "add a.txt\n\nand rewrite the README as well", tokens: 10 }
      end,
      verifier: verdicts({ verdict: :done, reason: "fine" })
    )

    run.call(state.id)

    subject = git(@worktree.path(state.id), "log", "-1", "--format=%s").strip
    assert_equal "add a.txt", subject
  end

  # -- the two accounting windows --------------------------------------------

  # Bug 7: the status was read at the top of the iteration, so a pause issued
  # between that read and the runner still bought a full iteration plus a full
  # verification -- while the user had already been told the loop had stopped.
  # The run now looks again immediately before it spends anything, and an
  # iteration that never ran costs nothing.
  def test_a_pause_written_before_the_runner_is_called_costs_nothing
    state = new_loop
    store = StoreThatPausesAfterReading.new(@store)
    run = Rubot::LoopRun.new(
      store: store, worktree: @worktree,
      runner: runner { |ctx| write_file(ctx, "a.txt", "1\n"); { text: "added a.txt", tokens: 30_000 } },
      verifier: verdicts({ verdict: :not_yet, reason: "red" })
    )

    result = run.call(state.id)

    assert_equal :paused, result.stop_reason
    assert_empty @contexts, "the runner must not be called for an iteration the pause cancelled"
    assert_empty @verify_contexts, "and nothing may be verified that was never worked on"
    reread = @store.load(state.id)
    assert_equal 0, reread.tokens, "an iteration that never ran must charge nothing"
    assert_equal 0, reread.iterations
    assert_equal 0, result.iterations_run
    assert_equal "paused", reread.status
  end

  # Bug 8: the provider charges for a turn the moment the model answers, so an
  # iteration the run cannot finish is still an iteration the loop pays for. The
  # commit is what fails here, after the report.
  def test_tokens_reported_before_a_failed_commit_are_still_charged
    state = new_loop
    # Git runs the repository's hooks from the worktree, so a hook that fails
    # makes the iteration's commit fail after the runner has answered.
    failing_hook(@repo)
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "a.txt", "1\n"); { text: "added a.txt", tokens: 30_000 } },
      verifier: verdicts
    )

    result = run.call(state.id)

    assert_equal :error, result.stop_reason
    assert_match(/commit failed/, result.message)
    reread = @store.load(state.id)
    assert_equal 30_000, reread.tokens, "a failed iteration still spends what it spent"
    assert_equal 1, reread.iterations
    assert_equal "paused", reread.status
  end

  # The double-count/undercount guard: the verifier pays for its own judgement
  # through the store while the iteration that called it is still being
  # accounted for. A run that wrote its own snapshot back would erase that
  # charge; the exact total is what proves the increments stayed increments.
  def test_a_verifier_charge_made_mid_iteration_is_counted_exactly_once
    state = new_loop(max_iterations: 2)
    seen = 0
    run = loop_run(
      runner: runner do |ctx|
        write_file(ctx, "step#{ctx[:iteration]}.txt", "x\n")
        { text: "step #{ctx[:iteration]}", tokens: 1_000 }
      end,
      verifier: verifier do |_ctx|
        seen += 1
        @store.update(state.id) { |loop| loop.tokens = loop.tokens.to_i + 250 }
        { verdict: :not_yet, reason: "red #{seen}" }
      end
    )

    result = run.call(state.id)

    assert_equal :max_iterations, result.stop_reason
    assert_equal 2_500, @store.load(state.id).tokens,
                 "two iterations at 1000 plus two verdicts at 250, each counted once"
  end

  # -- the log and where the money went --------------------------------------

  # One iteration used to write five entries -- "iteration 1: <text>", a second
  # "sha <sha> <text>" with the same text, and the verdict twice on the done
  # path -- so the log read like a transcript of writes instead of a history.
  # Now each iteration is one entry and each verdict is one entry, and the
  # iteration's entry is written once the sha and both halves of the spend are
  # known.
  def test_one_iteration_writes_one_entry_and_one_verdict
    state = new_loop
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "a.txt", "1\n"); { text: "added a.txt", tokens: 82_000 } },
      verifier: verifier do |_ctx|
        @store.update(state.id) { |s| s.tokens = s.tokens.to_i + 14_000 }
        { verdict: :done, reason: "a.txt exists" }
      end
    )

    run.call(state.id)

    entries = @store.load(state.id).log.map(&:text).reject { |text| text == "loop started" }
    sha = git(@worktree.path(state.id), "rev-parse", "HEAD").strip[0, 7]
    assert_equal [ "verifier: a.txt exists",
                   "iteration 1 (sha #{sha}, worker 82k, verifier 14k): added a.txt" ], entries,
                 "one entry per iteration and one per verdict, newest first: #{entries.inspect}"
  end

  # What the shape of a turn is for. One iteration of a real loop was 99 to 110
  # requests, and the reason it cost what it did is that every one of them
  # re-sent a conversation that had grown from 19k to 76k tokens. Those three
  # facts sit next to the spend in the entry, so the next run's cost can be read
  # rather than guessed.
  def test_the_entry_carries_the_shape_of_the_turns_requests
    state = new_loop
    metrics = { requests: 110, context_first: 19_000, context_last: 76_000, cache_hit_rate: 0.96 }
    run = loop_run(
      runner: runner do |ctx|
        write_file(ctx, "a.txt", "1\n")
        { text: "added a.txt", tokens: 82_000, metrics: metrics }
      end,
      verifier: verdicts({ verdict: :done, reason: "a.txt exists" })
    )

    run.call(state.id)

    entry = iteration_entry(state.id)
    assert_equal "iteration 1 (sha #{head_sha(state.id)}, worker 82k, verifier 0, " \
                 "req 110, ctx 19k->76k, cache 96%): added a.txt", entry
  end

  # A runner that reports no metrics is not a turn that made no request: the
  # part is left out whole, and the entry is the one it always was. A fabricated
  # "req 0" would read as a measurement, and a reader would believe it.
  def test_a_runner_that_reports_no_metrics_leaves_the_shape_out_of_the_entry
    state = new_loop
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "a.txt", "1\n"); { text: "added a.txt", tokens: 100 } },
      verifier: verdicts({ verdict: :done, reason: "a.txt exists" })
    )

    run.call(state.id)

    entry = iteration_entry(state.id)
    assert_equal "iteration 1 (sha #{head_sha(state.id)}, worker 100, verifier 0): added a.txt", entry
    refute_includes entry, "req ", "nothing was measured, so nothing is claimed"
  end

  # The same thing from the other side: a runner that does send a metrics hash
  # whose numbers are all zero measured nothing worth writing down.
  def test_a_zero_metric_is_not_written_as_a_request_that_never_happened
    state = new_loop
    run = loop_run(
      runner: runner do |ctx|
        write_file(ctx, "a.txt", "1\n")
        { text: "added a.txt", tokens: 100, metrics: { requests: 0, context_first: 0, context_last: 0 } }
      end,
      verifier: verdicts({ verdict: :done, reason: "a.txt exists" })
    )

    run.call(state.id)

    entry = iteration_entry(state.id)
    refute_includes entry, "req 0"
    refute_includes entry, "ctx "
    assert_equal "iteration 1 (sha #{head_sha(state.id)}, worker 100, verifier 0): added a.txt", entry
  end

  # The same guarantee stated the way the bug was, from the texts: the report
  # and the verdict each appear exactly once, whatever shape the entries take.
  def test_no_text_appears_twice_in_the_log_of_one_iteration
    state = new_loop(max_iterations: 1)
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "a.txt", "1\n"); { text: "added a.txt", tokens: 100 } },
      verifier: verdicts({ verdict: :not_yet, reason: "still red" })
    )

    run.call(state.id)

    texts = @store.load(state.id).log.map(&:text)
    assert_equal 1, texts.count { |text| text.include?("added a.txt") }, texts.inspect
    assert_equal 1, texts.count { |text| text.include?("still red") }, texts.inspect
  end

  # An iteration that stopped at its round cap is not one that ended because the
  # work was done: the entry says so, in the same parenthetical as the spend, so
  # a thin result can be read for what it is. The fact arrives from the agent
  # through the runner and is never inferred from the text.
  def test_an_iteration_that_reached_its_round_cap_says_so_in_the_entry
    state = new_loop
    run = loop_run(
      runner: runner do |ctx|
        write_file(ctx, "a.txt", "1\n")
        { text: "started a.txt", tokens: 100, round_cap: { rounds: 40, limit: 40 } }
      end,
      verifier: verdicts({ verdict: :done, reason: "a.txt exists" })
    )

    run.call(state.id)

    assert_equal "iteration 1 (sha #{head_sha(state.id)}, worker 100, verifier 0, rounds 40/40): " \
                 "started a.txt", iteration_entry(state.id)
  end

  # A runner that reports no cap leaves no claim of one: the entry is the one it
  # always was, so a loop driven by an older runner does not look capped.
  def test_a_runner_that_reports_no_cap_leaves_the_fact_out_of_the_entry
    state = new_loop
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "a.txt", "1\n"); { text: "added a.txt", tokens: 100 } },
      verifier: verdicts({ verdict: :done, reason: "a.txt exists" })
    )

    run.call(state.id)

    refute_includes iteration_entry(state.id), "rounds "
  end

  # The done path used to write the verdict once from #iterate and again from
  # its own stop, so the last thing the file said about a finished loop was the
  # same sentence twice. Counted in the file itself, not in a copy of the log.
  def test_the_done_path_writes_the_verifier_reason_once
    state = new_loop
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "a.txt", "1\n"); { text: "added a.txt", tokens: 100 } },
      verifier: verdicts({ verdict: :done, reason: "a.txt exists" })
    )

    run.call(state.id)

    written = File.read(@store.path(state.id)).lines.count { |line| line.include?("verifier: a.txt exists") }
    assert_equal 1, written, File.read(@store.path(state.id))
    assert_equal "done", @store.load(state.id).status
  end

  # The payoff of two entries an iteration instead of five: LOG_WINDOW = 10 is
  # now about five iterations, so the sixth turn reads the five before it. On
  # the old shape the same window held three.
  def test_five_iterations_all_reach_the_next_iteration_prompt
    state = new_loop(max_iterations: 6)
    reasons = [ "the API is undocumented", "the tests do not compile", "the config is missing",
                "the README lies about the setup", "the demo check fails" ]
    n = 0
    run = loop_run(
      runner: runner { |ctx| n += 1; write_file(ctx, "step#{n}.txt", "#{n}\n"); { text: "step #{n}", tokens: 100 } },
      verifier: verdicts(*reasons.map { |reason| { verdict: :not_yet, reason: reason } })
    )

    run.call(state.id)

    sixth = @contexts.last[:log]
    assert_equal Rubot::LoopRun::LOG_WINDOW, sixth.size, "the window is what an iteration reads"
    iteration_lines = sixth.grep(/\Aiteration \d+ \(/)
    assert_equal 5, iteration_lines.size, "five iterations must fit the window: #{sixth.inspect}"
    (1..5).each do |number|
      assert_match(/\Aiteration #{number} \(sha \h{7}, worker 100, verifier 0\): step #{number}\z/,
                   iteration_lines.find { |line| line.start_with?("iteration #{number} (") }.to_s)
    end
  end

  # The state's `tokens` is the one counter the budget is checked against, and
  # it must still be the worker's spend plus the verifier's -- the split in the
  # log is read off this total, never kept beside it.
  def test_the_state_total_is_what_the_worker_and_the_verifier_spent
    state = new_loop(max_iterations: 2)
    run = loop_run(
      runner: runner { |ctx| write_file(ctx, "step#{ctx[:iteration]}.txt", "x\n"); { text: "step #{ctx[:iteration]}", tokens: 70_000 } },
      verifier: verifier do |ctx|
        @store.update(state.id) { |s| s.tokens = s.tokens.to_i + 15_000 }
        { verdict: :not_yet, reason: "red #{ctx[:iteration]}" }
      end
    )

    run.call(state.id)

    reread = @store.load(state.id)
    assert_equal 2 * (70_000 + 15_000), reread.tokens, "worker plus verifier, for both iterations"
    split = reread.log.map(&:text).grep(/\Aiteration \d+ \(/)
    assert_equal 2, split.size
    split.each { |entry| assert_includes entry, "worker 70k, verifier 15k" }
  end
end
