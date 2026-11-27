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
    @metrics = nil
    @round_cap = nil
    @context_ceiling = nil
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

  def new_loop(max_iterations: 8, max_tokens: nil)
    @store.create(goal: GOAL, done_criteria: CRITERIA, repo: @repo, max_iterations: max_iterations,
                  max_tokens: max_tokens)
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
        { text: @answer.call(number), tokens: @iteration_tokens, metrics: @metrics,
          round_cap: @round_cap, context_ceiling: @context_ceiling }
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

  # The takeovers the file holds as each turn is asked for. Read there rather
  # than after the run: an iteration that completes clears the count, so a later
  # read cannot tell a resume's clearing from an iteration's.
  def takeover_watching_runner(id, session: nil)
    seen = []
    fake = session || session_runner
    watching = lambda do |session_id:, prompt:, workspace:|
      seen << @store.load(id).takeovers
      fake.call(session_id: session_id, prompt: prompt, workspace: workspace)
    end
    [ loop_runner(session: watching), seen ]
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

  # The channel measures the shape of a turn's requests and hands it back with
  # the answer; this runner passes it, untouched, into the report the run writes
  # its entry from. Nothing is invented on the way: a session runner that says
  # nothing leaves the entry without that part (see the loop run's own tests).
  def test_a_session_runner_that_reports_the_shape_of_its_requests_is_logged
    state = new_loop
    @verdict = ->(_number) { "DONE step1.txt is there" }
    @metrics = { requests: 6, context_first: 19_000, context_last: 76_000, cache_hit_rate: 0.96 }

    loop_runner.start(state.id)

    entry = iteration_entries(state.id).last.text
    assert_includes entry, "req 6, ctx 19k->76k, cache 96%", entry
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

  # Measured iterations were 76% one-call rounds, and every request re-sends the
  # conversation: five dependent calls written one per round pay for the same
  # growing context five times, while two independent calls made together pay for
  # it once. The instruction that asks for the batch is in every iteration, and
  # it costs a line, not the ceiling.
  def test_the_iteration_prompt_asks_for_independent_tool_calls_in_one_round
    state = new_loop(max_iterations: 5)
    # A different reason each time: the run treats a repeated one as a verifier
    # stuck, and this test is about the prompt, not about stopping early.
    @verdict = ->(number) { "NOT_YET waiting on #{%w[alpha beta gamma delta epsilon][number - 1]}" }

    loop_runner.start(state.id)

    prompts = prompts_of("~it")
    assert_equal 5, prompts.size
    prompts.each do |prompt|
      assert_includes prompt, "Batch independent tool calls"
      assert_operator prompt.lines.size, :<=, Rubot::LoopRunner::PROMPT_LINES,
                      "the whole prompt, instruction included, stays under the ceiling"
    end
  end

  # An iteration that ran out of rounds is not an iteration that ran out of
  # work, and the log has to say which one it was. The agent reports the cap, the
  # runner carries it, and the entry writes it beside the spend.
  def test_an_iteration_that_hit_its_round_cap_says_so_in_its_entry
    state = new_loop(max_iterations: 1)
    @round_cap = { rounds: 40, limit: 40 }

    loop_runner.start(state.id)

    entry = iteration_entries(state.id).first.text
    assert_includes entry, "rounds 40/40"
    assert_includes entry, "worker 1k", "the cap sits beside what the turn cost"
  end

  # The other ceiling reaches the entry the same way -- through the answer, not
  # through anything this side infers. The loop pauses, and the turn's work is
  # on the branch: what stopped the iteration is the transcript, not the agent.
  def test_an_iteration_that_hit_its_context_ceiling_stops_the_loop_and_says_so
    state = new_loop
    @context_ceiling = { tokens: 101_400, limit: 100_000 }

    outcome = loop_runner.start(state.id)

    assert_equal :context_ceiling, outcome.stop_reason
    entry = iteration_entries(state.id).first.text
    assert_includes entry, "ceiling 101k/100k"
    assert_includes entry, "stopped at its context ceiling",
                    "the commit and the entry name the ceiling, not the agent's notice"
    # A ceiling did not stop the money, so the branch must not say the work went
    # unjudged for lack of budget. The order of the stops decides this, and it is
    # asked in one place so the runner cannot answer it differently from the run.
    assert_equal "iteration 1: stopped at its context ceiling",
                 git(@repo, "log", "-1", "--format=%s", "loop/#{state.id}").strip
    assert_equal 1, @calls.size,
                 "no verifier turn is bought for an iteration that never finished"
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

  # The warning's decision is made after the turn returns, so a commit the agent
  # made itself already exists by then. It has to carry the marker anyway: the
  # branch is where "unverified" is written, and the report that offers keep,
  # drop and raise asks exactly this newest subject whether work is waiting.
  def test_a_commit_the_agent_made_itself_is_marked_unverified_at_the_warning
    state = new_loop(max_iterations: 2, max_tokens: 2_400)
    @agent_commits = true

    result = loop_runner.start(state.id)

    assert_equal :budget_warning, result.stop_reason
    assert_equal "paused", @store.load(state.id).status
    branch = "loop/#{state.id}"
    head = git(@repo, "rev-parse", branch).strip
    subject = git(@repo, "log", "-1", "--format=%s", branch).strip
    assert subject.start_with?(Rubot::LoopRun::UNVERIFIED_MARKER),
           "the agent's own commit is amended to carry the marker, not left implying a verdict: #{subject}"
    assert_includes subject, "agent step 2", "the agent's own subject survives the amend"
    assert_equal 3, commits(state.id), "an amend rewrites the head, it does not add a step"
    entry = iteration_entries(state.id).first.text
    assert_includes entry, "sha #{head[0, 7]}", "the entry names the commit the branch now holds"
    refute_includes entry, "sha #{@own_shas.last[0, 7]}", "and never a sha the amend left behind"
  end

  # The harder stop reads alike: a turn cancelled mid-flight had no chance to be
  # told it was unverified either, and its commit is the agent's own when the
  # agent commits. Both stops have to leave the same marker on the branch.
  def test_a_commit_the_agent_made_itself_is_marked_unverified_at_the_budget_stop
    state = @store.create(goal: GOAL, done_criteria: CRITERIA, repo: @repo, max_tokens: 5_000)
    session = lambda do |session_id:, prompt:, workspace:, id: nil, budget: nil, spent: nil|
      @calls << { session_id: session_id, prompt: prompt, workspace: workspace }
      File.write(File.join(workspace, "step1.txt"), "1\n")
      git(workspace, "add", "-A")
      git(workspace, "commit", "-m", "agent step 1")
      @store.update(id) { |loop| loop.tokens = loop.tokens.to_i + 6_000 }
      { text: "half a step", tokens: 0, budget_stopped: true }
    end

    result = loop_runner(session: session, budget: true).start(state.id)

    assert_equal :budget, result.stop_reason
    subject = git(@repo, "log", "-1", "--format=%s", "loop/#{state.id}").strip
    assert subject.start_with?(Rubot::LoopRun::UNVERIFIED_MARKER),
           "a mid-turn budget stop marks the agent's commit too: #{subject}"
    assert_equal 2, commits(state.id), "the init commit plus the one the stopped turn made"
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
    state = @store.create(goal: GOAL, done_criteria: CRITERIA, repo: @repo, max_tokens: 2_000)
    @verdict = ->(number) { "NOT_YET red #{number}" }

    result = loop_runner.start(state.id)

    assert_equal :budget, result.stop_reason
    # Two iterations and two verdicts: the judgement is paid for like the work,
    # and the loop is left resumable instead of reading "active" in the file.
    # The second work turn crosses the budget in one step -- a thousand tokens
    # against the eight hundred left -- so the stop is the budget itself and not
    # the warning at nine tenths of it.
    assert_equal 2_250, @store.load(state.id).tokens
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
    # The subject carries the marker: no verdict was bought for this iteration,
    # and the branch has to say so where a reader looks without the loop's file.
    assert_equal "[unverified] iteration 1: stopped for its budget",
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

  # -- a run that died with its process --------------------------------------
  #
  # `status: active` says a loop should be iterating; the lease says one is. The
  # tests below are the two halves of that difference: a live run is refused,
  # and a dead one is picked up where its file says it stopped.

  # Two runs on one worktree share an index and an iteration number, so a run
  # that is really in flight is not started twice -- and the file a live run is
  # writing is left exactly as it found it.
  def test_a_run_is_refused_while_another_holder_has_the_lease
    state = new_loop
    holder = Rubot::LoopLease.hold(@store.dir, state.id)
    refute_nil holder, "the test's own run holds the lease first"
    before = File.read(@store.path(state.id))

    result = loop_runner.start(state.id)

    assert_equal :not_active, result.stop_reason
    assert_includes result.message, "another process"
    assert_empty @calls, "nothing is spent on a loop somebody else is running"
    assert_equal before, File.read(@store.path(state.id)), "the live run's file is not written over"
    refute File.exist?(worktree_path(state.id)), "no worktree is made for a run that will not iterate"
  ensure
    holder&.release
  end

  # The case the lease exists for: the file says active because the process that
  # was working it is gone, and nobody holds the lease. The loop is taken over --
  # worked, not refused -- and the takeover is counted before the first turn.
  def test_resuming_an_active_loop_nobody_holds_takes_it_over
    state = new_loop(max_iterations: 1)
    @verdict = ->(_number) { "NOT_YET red" }
    runner, seen = takeover_watching_runner(state.id)

    result = runner.resume(state.id)

    assert_equal :max_iterations, result.stop_reason
    refute_empty @calls, "nothing was holding the lease, so the loop is worked"
    assert_equal 1, seen.first, "the takeover is counted before the first turn"
    assert(@store.load(state.id).log.any? { |entry| entry.text.start_with?("taken over") },
           "the log says the run was picked up rather than continued")
  end

  # A resume of a loop somebody is running changes nothing: the words are the
  # same ones a second run of an active loop has always got, and no turn is
  # bought to say them.
  def test_resuming_a_loop_somebody_is_running_says_already_active_and_starts_nothing
    state = new_loop
    holder = Rubot::LoopLease.hold(@store.dir, state.id)
    before = File.read(@store.path(state.id))

    result = loop_runner.resume(state.id)

    assert_equal :not_active, result.stop_reason
    assert_includes result.message, "already active"
    assert_empty @calls
    assert_equal before, File.read(@store.path(state.id))
  ensure
    holder&.release
  end

  # The cap settles where every other stop does, not in a caller that may or…
  # (see above) — but the state this test starts from is a crash's own shape:
  # three takeovers in a row happen only when the process dies before it can
  # write anything, and a file left like that is exactly `active`, counted, and
  # held by nobody. It cannot be reached by failing iterations in-process: a
  # failed iteration pauses the loop, and the next resume of a paused loop is a
  # deliberate wake that clears the count. That is why the count is seeded here
  # and the increment is proved on its own, one takeover at a time.
  def test_a_resume_at_the_takeover_ceiling_stalls_the_loop_and_spends_nothing
    state = new_loop
    @store.update(state.id) { |loop| loop.takeovers = Rubot::LoopLease::MAX_TAKEOVERS }

    result = loop_runner.resume(state.id)

    assert_equal :stalled, result.stop_reason
    assert_empty @calls, "a loop that keeps dying is not given another iteration"
    reread = @store.load(state.id)
    assert_equal "stalled", reread.status
    entry = reread.log.find { |each| each.text.start_with?("taken over") }
    refute_nil entry, "the log says why it stalled"
    assert_includes entry.text, Rubot::LoopLease::MAX_TAKEOVERS.to_s
    assert_includes result.message, Rubot::LoopLease::MAX_TAKEOVERS.to_s
    assert_includes result.message, "deliberate resume", "and what gets it going again"
  end

  # A wake that cannot get as far as a worktree is not a run, so the file must
  # not be left saying `active`: the next resume would read that as a run that
  # died and count a takeover for a loop nobody ever started. The count is left
  # alone for the same reason.
  def test_a_wake_that_cannot_prepare_leaves_the_loop_paused
    state = @store.create(goal: GOAL, done_criteria: CRITERIA,
                          repo: File.join(@tmp, "no-such-repo"), max_iterations: 8)
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.takeovers = 1
    end

    result = loop_runner.resume(state.id)

    assert_equal :worktree_error, result.stop_reason
    reread = @store.load(state.id)
    assert_equal "paused", reread.status, "nothing ran, so nothing was woken"
    assert_equal 1, reread.takeovers, "and no pickup was counted"
    refute(reread.log.any? { |entry| entry.text.start_with?("taken over") })
  end

  # The case the todo asked for in so many words: a process that dies in the
  # middle of an iteration. The child holds the lease in its own process with an
  # iteration already charged, and is killed the way a restart kills a run --
  # SIGKILL, no cleanup, no chance to write an ending. What is left is what the
  # user had: a file saying active, an iteration paid for, nobody holding it.
  def test_a_loop_whose_process_dies_mid_iteration_is_resumed_from_that_iteration
    skip "fork is not available here" unless Process.respond_to?(:fork)
    skip "flock is not honoured on this filesystem" unless Rubot::LoopLease.hold(@store.dir, "probe")

    state = new_loop(max_iterations: 2)
    @verdict = ->(_number) { "DONE the second iteration finished it" }
    marker = File.join(@tmp, "running")

    child = fork do
      Rubot::LoopLease.hold(@store.dir, state.id)
      @store.update(state.id) do |loop|
        loop.iterations = 1
        loop.tokens = 5_000
      end
      File.write(marker, "1")
      sleep 30
      exit!(0)
    end

    begin
      deadline = Time.now + 10
      sleep 0.01 until File.exist?(marker) || Time.now > deadline
      assert Rubot::LoopLease.held?(@store.dir, state.id), "the child is the run"
      Process.kill("KILL", child)
    ensure
      Process.waitpid(child)
    end

    crash_left = @store.load(state.id)
    assert_equal "active", crash_left.status, "a kill writes no ending"
    assert_equal 1, crash_left.iterations

    result = loop_runner.resume(state.id)

    assert_equal :done_by_verifier, result.stop_reason
    reread = @store.load(state.id)
    assert_equal "done", reread.status
    assert_equal 2, reread.iterations, "the loop continued from the iteration it had paid for"
    # Read in the log rather than in the counter: the pickup is counted before the
    # run, and the iteration this run then finished is exactly what clears the
    # count again. Both facts are the design; the log is where the first one can
    # still be seen.
    assert(reread.log.any? { |entry| entry.text.start_with?("taken over") },
           "the resume that picked the loop up is written down")
    assert_equal 0, reread.takeovers, "and the iteration it completed cleared the count"
  ensure
    FileUtils.rm_f(marker) if marker
  end

  # The count has to survive what a dying run writes, or the ceiling is a number
  # nobody can reach: an iteration is charged the moment it starts spending, so
  # `iterations` moves on the runs that die too. A run that never gets to its
  # verdict leaves the count where it was.
  def test_a_run_that_dies_before_its_verdict_keeps_the_takeovers
    state = new_loop
    dying = ->(session_id:, prompt:, workspace:) { raise IOError, "the process went away" }
    runner = loop_runner(session: dying)

    runner.resume(state.id)

    reread = @store.load(state.id)
    assert_equal 1, reread.takeovers, "the crash this count exists for is not erased by itself"
    assert_operator reread.iterations, :>=, 1, "a charged iteration is an attempted one, not a finished one"
    assert_operator reread.iterations, :<, 2
  end

  # An iteration that ran to its verdict is the proof the loop is alive rather
  # than a run that keeps dying: whatever took it over has not done it again, so
  # the count starts over instead of following the loop for the rest of its life.
  def test_an_iteration_that_reaches_its_verdict_clears_the_takeovers
    state = new_loop(max_iterations: 1)
    @store.update(state.id) { |loop| loop.takeovers = 2 }
    @verdict = ->(_number) { "DONE finished it" }

    loop_runner.start(state.id)

    reread = @store.load(state.id)
    assert_equal 1, reread.iterations
    assert_equal 0, reread.takeovers, "a judged iteration is progress, so the takeovers it outlived are gone"
  end

  # A deliberate wake is the reader's own decision, so the takeovers start over:
  # a loop stalled by three of them must not be one resume away from stalling
  # again.
  def test_resuming_a_paused_loop_clears_its_takeovers
    state = new_loop(max_iterations: 1)
    @store.update(state.id) do |loop|
      loop.status = "paused"
      loop.takeovers = 2
    end
    @verdict = ->(_number) { "DONE finished it" }
    runner, seen = takeover_watching_runner(state.id)

    result = runner.resume(state.id)

    assert_equal :done_by_verifier, result.stop_reason
    assert_equal 0, seen.first, "an explicit wake starts the count over"
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
