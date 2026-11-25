# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "open3"

require "rubot/loop_runner"

# The runner reaches an agent only through the `session_runner` proc, so a whole
# loop -- real git, real worktree, real state file -- is driven here by a fake
# that records every call and answers from a script per test: no model, no
# network, no Ractor.
class TestLoopRunner < Minitest::Test
  GOAL = "make the demo honest"
  CRITERIA = "the demo test is green"

  def setup
    @tmp = Dir.mktmpdir("rubot-loop-runner")
    @repo = File.join(@tmp, "demo")
    FileUtils.mkdir_p(@repo)
    git(@repo, "init", "-b", "main")
    git(@repo, "config", "user.email", "loop@example.com")
    git(@repo, "config", "user.name", "Loop Runner Test")
    File.write(File.join(@repo, "README.md"), "demo\n")
    git(@repo, "add", "-A")
    git(@repo, "commit", "-m", "init")

    @store = Rubot::LoopStore.new(dir: File.join(@tmp, "loops"))
    @root = File.join(@tmp, "worktrees")
    @calls = []
    @changes = true       # does the fake agent touch the worktree?
    @agent_commits = false # does it commit its own work? a boolean or a proc(number)
    @own_shas = []         # every sha the fake agent committed itself
    @iteration_tokens = 1_000
    @verify_tokens = 250
    @answer = ->(number) { "wrote step #{number}.txt" }
    @verdict = ->(number) { "NOT_YET still red #{number}" }
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.exist?(@tmp)
  end

  # -- helpers ---------------------------------------------------------------

  def git(dir, *args)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out
  end

  def new_loop(max_iterations: 8)
    @store.create(goal: GOAL, done_criteria: CRITERIA, repo: @repo, max_iterations: max_iterations)
  end

  # One call per session, exactly as the real boundary would be called: the
  # workspace it is handed is where the fake agent does its work.
  def session_runner
    lambda do |session_id:, prompt:, workspace:|
      @calls << { session_id: session_id, prompt: prompt, workspace: workspace }
      number = session_id[/~[a-z]+(\d+)\z/, 1].to_i
      if session_id.include?("~verify")
        { text: @verdict.call(number), tokens: @verify_tokens }
      else
        if commits_itself?(number)
          @own_shas << commit_own_step(workspace, number)
        elsif @changes
          write_step(workspace, number)
        end
        { text: @answer.call(number), tokens: @iteration_tokens }
      end
    end
  end

  def write_step(workspace, number)
    File.write(File.join(workspace, "step#{number}.txt"), "#{number}\n")
  end

  # An agent that commits its own work, the way one that runs `git commit` does:
  # it leaves the worktree clean and the only trace of the turn is a new head.
  def commit_own_step(workspace, number)
    File.write(File.join(workspace, "step#{number}.txt"), "#{number}\n")
    git(workspace, "add", "-A")
    git(workspace, "commit", "-m", "agent step #{number}")
    git(workspace, "rev-parse", "HEAD").strip
  end

  def commits_itself?(number)
    @agent_commits.respond_to?(:call) ? @agent_commits.call(number) : @agent_commits
  end

  def loop_runner(session: nil, logger: nil, budget: false)
    Rubot::LoopRunner.new(store: @store, worktree_root: @root,
                          session_runner: session || session_runner, logger: logger, budget: budget)
  end

  def worktree_path(id) = Rubot::LoopWorktree.new(root: @root, repo: @repo).path(id)

  # Counted on the branch, not in the worktree: a loop that finished has had its
  # worktree taken away, and the commits are the thing that outlives it.
  def commits(id) = git(@repo, "rev-list", "--count", "loop/#{id}").to_i

  # The entry the run writes for each turn: "iteration N (sha ..., worker ...,
  # verifier ...): <answer>". The number is part of the match because the run's
  # own notes can start with the same word ("iteration cap reached").
  def iteration_entries(id)
    @store.load(id).log.select { |entry| entry.text.match?(/\Aiteration \d+ \(/) }
  end

  # The commit each iteration reported. The entry for an iteration carries the
  # sha in its parenthetical when that turn claimed a commit, and no sha at all
  # when it claimed none.
  def reported_shas(id)
    log = @store.load(id).log.map(&:text)
    (1..iteration_entries(id).size).map do |number|
      answer = @answer.call(number)
      text = log.find { |candidate| candidate.end_with?("): #{answer}") }
      text&.[](/\(sha (\h{7,})\b/, 1)
    end
  end

  def prompts_of(kind) = @calls.select { |call| call[:session_id].include?(kind) }.map { |call| call[:prompt] }

  # -- starting --------------------------------------------------------------

  def test_a_missing_loop_is_reported_without_asking_anyone
    result = loop_runner.start("20260101-000000-abcd")

    assert_equal :missing, result.stop_reason
    assert_empty @calls, "no session may be started for a loop that does not exist"
  end

  def test_a_done_verdict_ends_the_loop_with_one_commit_per_iteration
    state = new_loop
    @verdict = ->(_number) { "DONE step1.txt is there" }

    result = loop_runner.start(state.id)

    assert_equal :done_by_verifier, result.stop_reason
    assert_equal "done", @store.load(state.id).status
    assert_equal 2, commits(state.id), "the repo's init commit plus one iteration"
    assert_equal 1, iteration_entries(state.id).size, "one log entry per iteration"
    assert_equal "1\n", git(@repo, "show", "loop/#{state.id}:step1.txt"),
                 "the iteration's commit is on the branch the loop kept"
    assert_equal "demo\n", File.read(File.join(@repo, "README.md")), "the user's checkout stays put"
  end

  # The runner used to write the iteration's text into the log itself and the run
  # wrote it again behind the sha, so one turn filled the file: the text twice
  # and the verdict twice on top. One iteration is two entries now, and the
  # commit subject still names the entry the file carries.
  def test_one_iteration_leaves_two_entries_and_the_commit_subject_names_the_work
    state = new_loop
    @verdict = ->(_number) { "DONE step1.txt is there" }

    loop_runner.start(state.id)

    entries = @store.load(state.id).log.map(&:text)
                  .reject { |text| text == "loop started" || text.start_with?("worktree ") }
    sha = git(@repo, "rev-parse", "loop/#{state.id}").strip[0, 7]
    assert_equal [ "verifier: step1.txt is there",
                   "iteration 1 (sha #{sha}, worker 1k, verifier 250): wrote step 1.txt" ], entries,
                 "one entry per iteration and one per verdict: #{entries.inspect}"
    assert_equal "iteration 1: wrote step 1.txt",
                 git(@repo, "log", "-1", "--format=%s", "loop/#{state.id}").strip,
                 "git log on the branch and the loop file tell the same story"
  end

  # The worktree is a place to work, not the record: the branch carries the
  # commits and the directory is gone once the loop has nothing left to do.
  def test_a_finished_loop_removes_its_worktree_and_keeps_the_branch
    state = new_loop
    @verdict = ->(_number) { "DONE step1.txt is there" }

    result = loop_runner.start(state.id)

    assert_equal :done_by_verifier, result.stop_reason
    refute File.exist?(worktree_path(state.id)), "the worktree is gone"
    assert_equal 1, git(@repo, "rev-list", "--count", "loop/#{state.id}").to_i - 1
    assert_includes @store.load(state.id).log.map(&:text).join("\n"),
                    "worktree removed, branch loop/#{state.id} kept"
  end

  # The opposite case, and the one that matters more: a loop that stopped short
  # is resumed in the work it already has, so its directory must survive.
  def test_a_stalled_loop_keeps_its_worktree
    state = new_loop
    @changes = false

    result = loop_runner.start(state.id)

    assert_equal :stalled, result.stop_reason
    assert File.exist?(worktree_path(state.id)), "unfinished work stays where it is"
    refute_includes @store.load(state.id).log.map(&:text).join("\n"), "worktree removed"
  end

  def test_the_iteration_prompt_names_the_goal_the_criteria_and_the_newest_entry_first
    state = new_loop(max_iterations: 2)
    loop_runner.start(state.id)

    first, second = prompts_of("~it")

    [ first, second ].each do |prompt|
      assert_includes prompt, GOAL
      assert_includes prompt, CRITERIA
      assert_includes prompt, worktree_path(state.id)
      assert_includes prompt, "loop/#{state.id}"
      assert_operator prompt.lines.size, :<, 40, "the prompt has a ceiling"
    end
    assert_includes first, "loop started", "the only entry there is on the first turn"
    # Newest first: the verdict on the first turn sits above the entry the loop
    # was created with, and that one above nothing older.
    assert_operator second.index("verifier: still red 1"), :<, second.index("loop started")
    assert_match(/iteration 1 \(sha \h{7}, worker 1k, verifier 250\): wrote step 1\.txt/, second,
                 "one entry per iteration, carrying its sha and both halves of the spend")
    assert_operator second.index("iteration 1 ("), :<, second.index("loop started")
  end

  def test_the_verifier_prompt_judges_the_worktree_and_never_reads_the_log
    state = new_loop
    @verdict = ->(number) { number == 1 ? "NOT_YET still red" : "DONE now green" }

    loop_runner.start(state.id)

    verify_calls = @calls.select { |call| call[:session_id].include?("~verify") }
    assert_equal 2, verify_calls.size
    prompt = verify_calls.first[:prompt]

    assert_includes prompt, GOAL
    assert_includes prompt, CRITERIA
    assert_includes prompt, worktree_path(state.id)
    assert_includes prompt, "never edit"
    refute_includes prompt, "loop started", "the verifier judges the tree, not the attempts"
    refute_includes prompt, "wrote step 1.txt"
    assert_equal [ "~verify1", "~verify2" ], verify_calls.map { |call| call[:session_id][/~verify\d+\z/] }
    assert_equal [ worktree_path(state.id) ], verify_calls.map { |call| call[:workspace] }.uniq
  end

  # Bug: the verifier was only ever asked whether the done criteria held against
  # the worktree, so a goal that also stated a constraint was never enforced. In
  # a real run the worker created done.flag at the repository root while the goal
  # forbade touching anything outside catatan/, and the verifier still said DONE.
  # The files the loop changed are the evidence, and they reach the prompt.
  def test_the_verifier_prompt_carries_the_files_the_loop_changed
    state = new_loop(max_iterations: 1)
    session = lambda do |session_id:, prompt:, workspace:|
      @calls << { session_id: session_id, prompt: prompt, workspace: workspace }
      if session_id.include?("~verify")
        { text: "NOT_YET done.flag is not what the goal asked for", tokens: @verify_tokens }
      else
        File.write(File.join(workspace, "done.flag"), "")
        { text: "wrote done.flag", tokens: @iteration_tokens }
      end
    end

    loop_runner(session: session).start(state.id)

    prompt = prompts_of("~verify").first
    assert_includes prompt, GOAL
    assert_includes prompt, CRITERIA
    assert_includes prompt, "Files this loop changed:"
    assert_includes prompt, "A done.flag", "the verifier is shown the path the loop wrote"
  end

  # A constraint written in the goal outranks finishing the criteria: here the
  # criteria are met and the work still broke the goal, so the loop must not end
  # done, and the violation is what the file records.
  def test_a_violated_goal_constraint_keeps_the_loop_from_ending_done
    state = @store.create(goal: "write the note in catatan/ and do not touch anything outside catatan/",
                          done_criteria: "catatan/01.md exists", repo: @repo, max_iterations: 1)
    violation = "violated the goal: done.flag is outside catatan/"
    session = lambda do |session_id:, prompt:, workspace:|
      @calls << { session_id: session_id, prompt: prompt, workspace: workspace }
      if session_id.include?("~verify")
        # A fake verifier that judges the goal: it can only name the violation
        # because the prompt showed it the file.
        { text: prompt.include?("A done.flag") ? "NOT_YET #{violation}" : "DONE catatan/01.md exists",
          tokens: @verify_tokens }
      else
        FileUtils.mkdir_p(File.join(workspace, "catatan"))
        File.write(File.join(workspace, "catatan", "01.md"), "note\n")
        File.write(File.join(workspace, "done.flag"), "")
        { text: "wrote the note and flagged it", tokens: @iteration_tokens }
      end
    end

    result = loop_runner(session: session).start(state.id)

    refute_equal :done_by_verifier, result.stop_reason, "criteria met is not the whole goal"
    refute_equal "done", @store.load(state.id).status
    assert_equal :max_iterations, result.stop_reason
    assert_includes @store.load(state.id).log.map(&:text).join("\n"), violation
  end

  # The file list is the one part that gives way: eighty changed files must not
  # become a prompt the verifier cannot read, and the goal must survive whole.
  def test_the_verifier_prompt_fits_its_line_budget_with_eighty_changed_files
    state = @store.create(goal: "make the demo honest\nand keep it that way",
                          done_criteria: CRITERIA, repo: @repo, max_iterations: 1)
    session = lambda do |session_id:, prompt:, workspace:|
      @calls << { session_id: session_id, prompt: prompt, workspace: workspace }
      if session_id.include?("~verify")
        { text: "NOT_YET still red", tokens: @verify_tokens }
      else
        80.times { |index| File.write(File.join(workspace, format("file%02d.txt", index)), "x\n") }
        { text: "wrote eighty files", tokens: @iteration_tokens }
      end
    end

    loop_runner(session: session).start(state.id)

    prompt = prompts_of("~verify").first
    assert_operator prompt.lines.size, :<=, Rubot::LoopRunner::PROMPT_LINES,
                    "the verdict prompt has the same ceiling as an iteration's"
    assert_includes prompt, "make the demo honest\nand keep it that way", "the goal is never trimmed"
    assert_includes prompt, CRITERIA
    assert_match(/more changed files not shown/, prompt, "a trimmed list says what it left out")
  end

  # -- stopping --------------------------------------------------------------

  def test_a_turn_that_changes_nothing_twice_stalls_the_loop
    state = new_loop
    @changes = false

    result = loop_runner.start(state.id)

    assert_equal :stalled, result.stop_reason
    assert_equal "stalled", @store.load(state.id).status
    assert_equal 1, commits(state.id), "no commit for a turn that changed nothing"
    assert_equal 2, iteration_entries(state.id).size
    assert_equal [ nil, nil ], reported_shas(state.id), "an idle turn claims no commit"
  end

  # Bug: progress was read off the commit this runner made itself, and an agent
  # that commits its own work leaves a clean worktree, so every such turn looked
  # idle and two of them stalled a loop whose branch carried two fresh commits.
  # The worktree heads read on either side of the turn are the evidence now.
  def test_an_agent_that_commits_itself_is_progress_and_reports_its_own_sha
    state = new_loop(max_iterations: 2)
    @agent_commits = true

    result = loop_runner.start(state.id)

    refute_equal :stalled, result.stop_reason, "two productive turns are not a stall"
    assert_equal :max_iterations, result.stop_reason
    assert_equal 2, iteration_entries(state.id).size
    assert_equal @own_shas.map { |sha| sha[0, 7] }, reported_shas(state.id),
                 "each iteration reports the commit the agent made itself"
    assert_equal 3, commits(state.id), "the repo's init commit plus one per iteration"
    assert_equal "1\n", git(@repo, "show", "loop/#{state.id}:step1.txt")
    assert_equal "2\n", git(@repo, "show", "loop/#{state.id}:step2.txt")
  end

  # One idle turn is not a stall: STALL_REPEATS is 2, and the turn before it did
  # commit, so the loop must keep going and report one commit and then none.
  def test_one_idle_turn_after_a_productive_one_does_not_stall
    state = new_loop(max_iterations: 2)
    @changes = false
    @agent_commits = ->(number) { number == 1 }

    result = loop_runner.start(state.id)

    assert_equal :max_iterations, result.stop_reason
    assert_equal [ @own_shas.first[0, 7], nil ], reported_shas(state.id)
    assert_equal 2, commits(state.id), "the init commit plus the one the agent made"
  end

  # The other half of the pair: a turn that edits and never commits leaves the
  # work to this runner, and the commit it makes is what the run must report.
  def test_a_commit_this_runner_makes_is_reported_as_the_iterations_commit
    state = new_loop(max_iterations: 2)
    @changes = true

    result = loop_runner.start(state.id)

    refute_equal :stalled, result.stop_reason
    branch = "loop/#{state.id}"
    assert_equal [ git(@repo, "rev-parse", "#{branch}~1").strip[0, 7], git(@repo, "rev-parse", branch).strip[0, 7] ],
                 reported_shas(state.id), "one runner commit per turn, in order"
    assert_equal 3, commits(state.id)
  end

  def test_a_verifier_that_keeps_refusing_for_the_same_reason_stops_as_stuck
    state = new_loop
    @verdict = ->(_number) { "NOT_YET the demo test is still red" }

    result = loop_runner.start(state.id)

    assert_equal :verifier_stuck, result.stop_reason
    assert_equal "paused", @store.load(state.id).status
    assert_equal 3, iteration_entries(state.id).size
  end

  def test_a_session_that_raises_is_a_result_and_not_an_exception
    state = new_loop
    boom = lambda { |**_options| raise ArgumentError, "no model today" }

    result = loop_runner(session: boom).start(state.id)

    assert_equal :error, result.stop_reason
    assert_match(/no model today/, result.message)
    assert(@store.load(state.id).log.any? { |entry| entry.text.include?("no model today") })
  end

  # -- the budget ------------------------------------------------------------

  def test_the_verifier_spends_against_the_same_budget_as_the_iteration
    state = @store.create(goal: GOAL, done_criteria: CRITERIA, repo: @repo, max_tokens: 2_500)
    @verdict = ->(number) { "NOT_YET red #{number}" }

    result = loop_runner.start(state.id)

    assert_equal :budget, result.stop_reason
    # Two iterations and two verdicts: the judgement is paid for like the work,
    # and the loop is left resumable instead of reading "active" in the file.
    assert_equal 2_500, @store.load(state.id).tokens
    assert_equal "paused", @store.load(state.id).status
  end

  # A turn the provider billed must still be charged when the step after it
  # fails. A refused commit used to report zero tokens, so the budget was spent
  # invisibly and the loop looked free.
  def test_a_paid_iteration_is_charged_even_when_the_commit_is_refused
    state = new_loop(max_iterations: 2)
    hook = File.join(@repo, ".git", "hooks", "pre-commit")
    FileUtils.mkdir_p(File.dirname(hook))
    File.write(hook, "#!/bin/sh\nexit 1\n")
    FileUtils.chmod(0o755, hook)

    result = loop_runner.start(state.id)

    refute_equal :done_by_verifier, result.stop_reason
    assert_equal 1_000, @store.load(state.id).tokens
  end

  # The budget has to reach the door, not only the run: a channel's session
  # runner is the only thing that can stop a turn that is already spending.
  def test_the_session_runner_is_told_the_budget_and_the_spend_so_far
    state = @store.create(goal: GOAL, done_criteria: CRITERIA, repo: @repo,
                          max_iterations: 1, max_tokens: 40_000)
    seen = []
    session = lambda do |session_id:, prompt:, workspace:, id: nil, budget: nil, spent: nil|
      seen << { id: id, budget: budget, spent: spent, session_id: session_id }
      session_id.include?("~verify") ? { text: "NOT_YET red", tokens: 100 } : { text: "a step", tokens: 1_000 }
    end

    loop_runner(session: session).start(state.id)

    assert_equal [ state.id, state.id ], seen.map { |call| call[:id] }
    assert_equal [ 40_000, 40_000 ], seen.map { |call| call[:budget] }
    assert_equal [ 0, 1_000 ], seen.map { |call| call[:spent] },
                 "the verdict is told what the work turn cost"
  end

  # A session runner written before the budget existed takes three keywords and
  # nothing else. Asking it for a fourth is an ArgumentError before the turn
  # starts, so it is never asked: the loop still runs, with the budget checked
  # at the boundaries it has.
  def test_a_session_runner_without_the_budget_keywords_is_still_called
    state = new_loop(max_iterations: 1)
    calls = []
    session = lambda do |session_id:, prompt:, workspace:|
      calls << session_id
      { text: "NOT_YET red", tokens: 100 }
    end

    result = loop_runner(session: session).start(state.id)

    assert_equal :max_iterations, result.stop_reason
    assert_equal 2, calls.size, "the work turn and the verdict"
    assert_match(/\Aloop-#{Regexp.escape(state.id)}~a[^~]+~it1\z/, calls[0],
                 "the work turn, on the three keywords it declared")
    assert_match(/\Aloop-#{Regexp.escape(state.id)}~a[^~]+~verify1\z/, calls[1],
                 "the verdict, on the three keywords it declared")
  end

  # A turn the channel stopped for its budget, end to end: the store is paid as
  # the turn reports, the runner hands the stop on, and the loop settles paused
  # with the work committed and nothing charged twice. This is the shape a real
  # session produces, driven here by a lambda.
  def test_a_turn_cancelled_for_its_budget_pauses_the_loop_without_double_charging
    state = @store.create(goal: GOAL, done_criteria: CRITERIA, repo: @repo, max_tokens: 5_000)
    verdicts = 0
    session = lambda do |session_id:, prompt:, workspace:, id: nil, budget: nil, spent: nil|
      if session_id.include?("~verify")
        verdicts += 1
        { text: "NOT_YET red", tokens: 100 }
      else
        File.write(File.join(workspace, "step1.txt"), "1\n")
        # The turn reports 6,000 against a budget of 5,000 and is cancelled there.
        @store.update(id) { |loop| loop.tokens = loop.tokens.to_i + 6_000 }
        { text: "half a step", tokens: 0, budget_stopped: true }
      end
    end

    result = loop_runner(session: session).start(state.id)

    assert_equal :budget, result.stop_reason
    assert_equal 0, verdicts, "the verdict is a second turn the loop cannot afford"
    assert_equal "paused", @store.load(state.id).status
    assert_equal 6_000, @store.load(state.id).tokens,
                 "charged once: the turn paid the store, and the run charged nothing on top"
    assert_equal 2, commits(state.id), "the init commit plus the one the stopped turn made"
  end

  # The budget keywords are the brake, and a production runner that cannot take
  # them must not fall back to the three-keyword path in silence: the loop would
  # run with nothing able to stop a turn, and not one line would say so.
  def test_a_runner_that_must_take_the_budget_but_cannot_fails_hard
    state = new_loop(max_iterations: 1)
    session = lambda do |session_id:, prompt:, workspace:|
      @calls << { session_id: session_id, prompt: prompt, workspace: workspace }
      { text: "NOT_YET red", tokens: 100 }
    end

    result = loop_runner(session: session, budget: true).start(state.id)

    assert_equal :error, result.stop_reason
    assert_includes result.message, "budget"
    assert_empty @calls, "nothing is spent on a turn nothing could stop"
    assert(@store.load(state.id).log.any? { |entry| entry.text.include?("budget") },
           "the reason is in the loop's own log, where a reader finds it")
  end

  # A run that died mid-iteration leaves the number where it was, so the next
  # run comes back to the same iteration. Reusing that iteration's session id
  # hands the new turn the dead one's history and its usage, and the brake then
  # reads a spend that was already paid for: the turn is cancelled before it
  # does a thing. The session belongs to the attempt, not to the number.
  def test_a_run_that_comes_back_to_the_same_iteration_asks_a_new_session
    state = new_loop(max_iterations: 2)
    @verdict = ->(_number) { "NOT_YET red" }

    loop_runner.start(state.id)
    first = @calls.map { |call| call[:session_id] }.grep(/~it1\z/)
    refute_empty first, "the first run asks its iteration-1 session"

    # The file a crash leaves behind: the iteration number never advanced.
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.iterations = 0
      loop.tokens = 0
    end
    @calls.clear

    loop_runner.resume(state.id)
    second = @calls.map { |call| call[:session_id] }.grep(/~it1\z/)

    refute_empty second, "the resumed run asks iteration 1 again"
    refute_equal first, second, "the same iteration number must not reuse the dead run's session"
  end

  # A loop that stopped for its budget is paused, and paused is what a tick
  # wakes -- but nothing in the file can raise the budget, so the wake buys
  # nothing. It must not buy a turn, and it must say why once instead of every
  # time a schedule fires.
  def test_a_resume_past_the_budget_buys_no_turn_and_is_recorded_once
    state = @store.create(goal: GOAL, done_criteria: CRITERIA, repo: @repo, max_tokens: 2_000)
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.iterations = 1
      loop.tokens = 3_000
    end

    first = loop_runner.resume(state.id)
    second = loop_runner.resume(state.id)

    assert_equal :budget, first.stop_reason
    assert_equal :budget, second.stop_reason
    assert_empty @calls, "a spent loop buys no turn, however often it is woken"
    reread = @store.load(state.id)
    assert_equal "paused", reread.status
    assert_equal 1, reread.log.count { |entry| entry.text.include?("max_tokens") },
                 "one entry saying how to get going again, not one per wake"
  end

  # What the loop tool writes when the reader names a bigger budget: the run
  # reads the file, so that write is what makes the next iteration affordable.
  def test_a_resume_runs_again_once_the_budget_is_raised
    state = @store.create(goal: GOAL, done_criteria: CRITERIA, repo: @repo,
                          max_iterations: 3, max_tokens: 2_000)
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.iterations = 1
      loop.tokens = 3_000
    end
    @verdict = ->(_number) { "DONE finished it" }
    @store.update(state.id) { |loop| loop.max_tokens = 20_000 }

    result = loop_runner.resume(state.id)

    assert_equal :done_by_verifier, result.stop_reason
    refute_empty @calls, "a bigger budget is what buys the next turn"
    assert_match(/\Aloop-#{Regexp.escape(state.id)}~a[^~]+~it2\z/, @calls.first[:session_id],
                 "it continues from the file's iteration")
  end

  # Tokens a channel could not write down are not silently forgiven: the turn
  # says what the store is owed, and the loop's log is where it lands.
  def test_tokens_a_channel_could_not_write_are_named_in_the_loops_log
    state = new_loop(max_iterations: 1)
    session = lambda do |session_id:, prompt:, workspace:, id: nil, budget: nil, spent: nil|
      { text: "a step", tokens: 0, unwritten: 12_345 }
    end

    loop_runner(session: session, budget: true).start(state.id)

    assert(@store.load(state.id).log.any? { |entry| entry.text.include?("12345") },
           "the tokens nothing wrote down are named in the loop's own log")
  end

  # A turn the budget stopped hands the agent's own notice back ("Stopped by
  # user") instead of an answer -- see Agent::STOP_NOTICE. The entry and the
  # commit subject say what actually happened; the notice belongs to neither, and
  # a loop whose history reads "Stopped by user" is a loop a reader will think
  # they ended.
  def test_a_stopped_turn_puts_the_stop_in_the_log_not_the_agents_notice
    state = @store.create(goal: GOAL, done_criteria: CRITERIA, repo: @repo, max_tokens: 5_000)
    session = lambda do |session_id:, prompt:, workspace:, id: nil, budget: nil, spent: nil|
      if session_id.include?("~verify")
        { text: "NOT_YET red", tokens: 100 }
      else
        File.write(File.join(workspace, "step1.txt"), "1\n")
        { text: "⏹️ Stopped by user.", tokens: 0, budget_stopped: true, spent: 6_000 }
      end
    end

    result = loop_runner(session: session, budget: true).start(state.id)

    assert_equal :budget, result.stop_reason
    log = @store.load(state.id).log.map(&:text)
    refute(log.any? { |text| text.include?("Stopped by user") }, "the agent's notice is not the loop's history")
    assert(log.any? { |text| text.include?("stopped for its budget") }, log.inspect)
    assert_equal "iteration 1: stopped for its budget",
                 git(@repo, "log", "-1", "--format=%s", "loop/#{state.id}").strip
  end

  # -- the verdict -----------------------------------------------------------

  def test_an_answer_without_a_verdict_line_is_not_a_done
    state = new_loop(max_iterations: 1)
    @verdict = ->(_number) { "I read the files and it all looks reasonable to me." }

    result = loop_runner.start(state.id)

    refute_equal :done_by_verifier, result.stop_reason
    assert_equal :max_iterations, result.stop_reason
    # The cap settles as paused, the way a spent budget does: stopped at the cap
    # is not a loop still running.
    assert_equal "paused", @store.load(state.id).status
    assert(@store.load(state.id).log.any? { |entry| entry.text.include?("verifier gave no verdict") })
  end

  # -- resuming --------------------------------------------------------------

  def test_resume_continues_from_the_iteration_the_file_records
    state = new_loop(max_iterations: 5)
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.iterations = 2
      loop.tokens = 4_000
    end
    @verdict = ->(_number) { "DONE finished it" }

    result = loop_runner.resume(state.id)

    assert_equal :done_by_verifier, result.stop_reason
    assert_equal 3, result.iterations_run
    ids = @calls.map { |call| call[:session_id] }
    assert_match(/\Aloop-#{Regexp.escape(state.id)}~a[^~]+~it3\z/, ids[0])
    assert_match(/\Aloop-#{Regexp.escape(state.id)}~a[^~]+~verify3\z/, ids[1])
    reread = @store.load(state.id)
    assert_equal 3, reread.iterations
    assert_equal 4_000 + 1_000 + 250, reread.tokens
  end

  # -- a repository that cannot take a worktree ------------------------------

  # The loop is a repair for the user, not a crash: the reason is on disk and
  # nothing escapes #start.
  def test_a_worktree_that_cannot_be_made_is_reported_as_a_worktree_error
    state = new_loop
    FileUtils.mkdir_p(worktree_path(state.id))

    result = loop_runner.start(state.id)

    assert_equal :worktree_error, result.stop_reason
    assert_match(/could not prepare a worktree/, result.message)
    assert_empty @calls, "nothing is spent on a loop that has nowhere to work"
    assert(@store.load(state.id).log.any? { |entry| entry.text.include?("could not prepare a worktree") })
  end
end
