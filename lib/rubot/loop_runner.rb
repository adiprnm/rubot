# frozen_string_literal: true

require "time"

require_relative "loop_run"
require_relative "loop_store"
require_relative "loop_worktree"

module Rubot
  # What one iteration of a loop actually does.
  #
  # LoopRun owns the cycle -- budget, counters, when to stop -- and reaches an
  # agent only through two lambdas. This class fills them in: one session per
  # iteration, one for the verdict, both through the `session_runner` it is given.
  # That lambda is the only door to the outside world, so nothing here names a
  # provider, an Agent or a Ractor, a test can drive a whole loop with a proc, and
  # nothing is pushed: commits stay on the loop's branch until they are read.
  class LoopRunner
    # The slice of the log an iteration reads: two entries per iteration, so ten
    # is about five iterations, which is the default cap in one go.
    LOG_WINDOW = LoopRun::LOG_WINDOW
    # A prompt that grows with the log stops being one, so these caps keep it inside.
    PROMPT_LINES = 40
    GOAL_LINES = 4
    CRITERIA_LINES = 10
    # The verdict prompt has the same ceiling as an iteration's. Its fixed part
    # (header, goal, criteria, instruction) is 35 lines at the goal's and the
    # criteria's own limits, so the file list always gets the rest of the budget
    # and is the only thing that gives way.
    VERIFIER_LINES = PROMPT_LINES
    # What the verdict means, in one paragraph: the criteria are not the goal,
    # and a goal that also forbids something forbids it however green they are.
    CONSTRAINT_INSTRUCTION = [
      "Answer DONE only when BOTH: the done criteria hold AND nothing the goal asked",
      "for was violated. A constraint written in the goal outranks finishing the",
      "criteria: if the goal forbids something and the work did it, answer NOT_YET",
      "and name the violation, however green the criteria look."
    ].freeze
    # One width for both paths into the branch's history, the run's and this one's.
    SUBJECT_CHARS = LoopRun::COMMIT_SUBJECT_CHARS
    NO_VERDICT = "verifier gave no verdict"
    DEFAULT_SUBJECT = "loop iteration"
    # A resume may wake these up. `done` is not one of them: its verdict was
    # answered, and an id in a log file must not re-arm a finished loop.
    RESUMABLE = %w[ paused stalled ].freeze

    def initialize(store:, worktree_root:, session_runner:, verifier_persona: "code_reviewer", logger: nil)
      @store = store
      @worktree_root = worktree_root
      @session_runner = session_runner
      # The session boundary takes no persona, so the name reaches the verifier
      # in its prompt: the only place a channel can see it.
      @verifier_persona = verifier_persona
      @logger = logger
    end

    # Runs an active loop to its next stopping point and answers with the run's
    # own result, unchanged, so the tool and the tests read one shape. A state file
    # that cannot be read is the one thing that leaves this method: its budget and
    # status are unknown, and guessing them is how a spent loop gets a fresh one.
    def start(id) = run(id)

    # Wakes a paused or stalled loop first; the counters are on disk, so the run
    # continues from the file's iteration rather than from zero.
    def resume(id)
      status = @store.load(id)&.status.to_s
      @store.update(id) { |loop| loop.status = "active" } if RESUMABLE.include?(status)
      run(id)
    end

    private

    def run(id)
      state = @store.load(id)
      return result(nil, :missing, 0, "no loop with id #{id.to_s.inspect}") if state.nil?

      worktree = LoopWorktree.new(root: @worktree_root, repo: state.repo)
      begin
        dir, branch, base = prepare(worktree, state)
      rescue LoopWorktree::Error, SystemCallError => e
        # A repository that cannot take a worktree today can take one after the
        # user looks at it, so the loop is left exactly as it was.
        return reported(id, "could not prepare a worktree: #{e.message}", :worktree_error)
      end

      outcome = LoopRun.new(store: @store, worktree: worktree,
                            runner: runner_for(id, worktree, dir, branch),
                            verifier: verifier_for(id, worktree, dir, branch, base)).call(id)
      log("loop #{id} stopped: #{outcome.stop_reason} after #{outcome.iterations_run} iterations")
      cleanup(settle(outcome), worktree)
    rescue LoopStore::Corrupt
      raise # an unreadable file means an unknown budget, and the caller must know
    rescue StandardError => e
      # Last resort: the reason lands in the file and in the result, because a
      # channel has nobody to show a stack trace to.
      reported(id, "#{e.class}: #{e.message}", :error)
    end

    # A loop that is not active is not prepared: the run answers :paused or
    # :not_active without touching git, and a worktree made for a loop that will not
    # iterate is a branch nobody asked for. It is made here rather than left to the
    # run because the prompt names its branch, and a repository that cannot take a
    # worktree should fail before an iteration is paid for.
    #
    # The base is recorded once, when the worktree is made, and again for a loop
    # whose file predates the fact: it is the commit the verifier's list of
    # changed files is measured from, so a later read would move the line. Read
    # from the worktree the moment it exists, which is the commit it was created
    # on -- or, for a loop resuming its own branch, where the loop's work stands.
    def prepare(worktree, state)
      return [ nil, nil, nil ] unless state.status.to_s == "active"

      id = state.id
      dir = worktree.exists?(id) ? worktree.path(id) : worktree.create(id: id, branch: state.branch)
      branch = worktree.branch(id)
      base = worktree.head(id)
      recorded = nil
      @store.update(id) do |loop|
        loop.worktree = dir
        loop.branch = branch
        loop.base ||= base
        recorded = loop.base
      end
      [ dir, branch, recorded ]
    end

    # The iteration: one agent turn in the worktree, its spend reported as the
    # run's, and the work it left behind committed as one step. The commit
    # message is shaped like the entry the run will write -- subject from the
    # answer's first line and the iteration number, body from the rest -- so
    # `git log` on the branch reads like the loop's history.
    #
    # The log entry itself is not written here. The run writes it once the sha
    # and both halves of the spend are known, and a second write from this side
    # is how one iteration came to be logged twice, in two different shapes.
    def runner_for(id, worktree, dir, branch)
      lambda do |context|
        iteration = context[:iteration].to_i
        # The head on either side of the turn is what says whether it produced
        # anything: an agent may run `git commit` itself, and the worktree it
        # leaves behind is then clean.
        before = worktree.head(id)
        text, tokens = ask("loop-#{id}~it#{iteration}", iteration_prompt(context, dir, branch), dir)
        # Charged here, before the commit, because the commit can fail: a stale
        # index.lock or a refused commit would otherwise throw away a turn the
        # provider already billed. The report hands back zero, since the run
        # charges what a runner reports and this one has already paid.
        charge(id, tokens)
        commit = commit_iteration(worktree, id, commit_message(iteration, text))
        after = worktree.head(id)
        progress, reported = progress_report(commit, before, after)
        { text: text, tokens: 0, commit: reported, progress: progress }
      end
    end

    # Whether an iteration made progress, and the commit that says so, from the
    # head read before the turn, the head read after it, and the commit this
    # runner made out of what the turn left behind.
    #
    # A moved head is the agent's own commit, and the new head is the commit to
    # report; a commit made here is this runner's. Neither is the other's
    # business, which is why the commit alone was the wrong question: an agent
    # that commits its own work leaves a clean tree, and reading that as no
    # progress stalled a loop whose branch had a fresh commit on it. A head that
    # could not be read twice is not evidence of anything, so it falls back to
    # the commit made here and never becomes progress by itself.
    def progress_report(commit, before, after)
      return [ true, after ] if before && after && before != after

      [ !commit.nil?, commit ]
    end

    # The verdict: a session of its own that may read and run tests but never write.
    # It is shown the goal, the criteria and the files the loop changed, because a
    # goal can state a constraint the criteria never mention and a verdict on the
    # criteria alone let a loop end DONE with a stray file at the repository root.
    # Its spend is charged here, because the run charges only what the runner
    # reports, and an unpaid verifier would let a loop spend its whole budget on
    # judgement and never notice.
    def verifier_for(id, worktree, dir, branch, base)
      lambda do |context|
        iteration = context[:iteration].to_i
        files = worktree.changed_files(id, base)
        text, tokens = ask("loop-#{id}~verify#{iteration}", verifier_prompt(context, dir, branch, files), dir)
        charge(id, tokens)
        verdict, reason = parse_verdict(text)
        { verdict: verdict, reason: reason }
      end
    end

    # The one door to an agent: a session id, a prompt, and the worktree as its
    # workspace. A session that raises is left to the run, which already turns a
    # failure into a log entry and an :error stop.
    def ask(session_id, prompt, workspace)
      log("#{session_id}: #{prompt.lines.size} prompt lines in #{workspace}")
      answer = @session_runner.call(session_id: session_id, prompt: prompt, workspace: workspace)
      raise TypeError, "session runner returned #{answer.class}" unless answer.is_a?(Hash)
      [ (answer[:text] || answer["text"]).to_s, (answer[:tokens] || answer["tokens"]).to_i ]
    end

    # In the order an iteration needs it: what is wanted, how it is judged, where
    # to work, what was already tried, and only then one instruction. The log is
    # trimmed from its oldest end, because the newest entry is the one that says
    # where the last turn stopped.
    def iteration_prompt(context, dir, branch)
      lines = [
        "Goal:", clip(context[:goal], GOAL_LINES),
        "", "Done criteria:", clip(context[:done_criteria], CRITERIA_LINES),
        "", "Worktree: #{dir}", "Branch: #{branch}",
        "", "Log, newest first:"
      ]
      room = [ [ PROMPT_LINES - 3 - lines.size, LOG_WINDOW ].min, 0 ].max
      Array(context[:log]).first(room).each { |entry| lines << "- #{LoopStore.one_line(entry)}" }
      lines.push("", "Make one step of progress toward the done criteria, then stop.")
      lines.join("\n")
    end

    # In the order a verdict needs it: what was asked for, how it is judged, what
    # the loop actually changed, where that is, and only then one instruction. The
    # file list is what makes a constraint the goal states in terms of paths
    # checkable at all -- the criteria never name one. The log stays out: the
    # verifier judges the worktree, and a log of attempts would only tell it what
    # to believe.
    def verifier_prompt(context, dir, branch, files)
      head = [
        "You are the verifier of a loop (persona: #{@verifier_persona}).",
        "You may read files in the worktree and run its tests. You must never edit,",
        "create or delete anything in it, and never commit.",
        "", "Goal:", clip(context[:goal], GOAL_LINES),
        "", "Done criteria:", clip(context[:done_criteria], CRITERIA_LINES),
        "", "Files this loop changed:"
      ]
      tail = [
        "", "Worktree: #{dir}", "Branch: #{branch}",
        "", *CONSTRAINT_INSTRUCTION,
        "", "Answer with exactly one line: start it with DONE and the evidence when the",
        "criteria and the goal are both satisfied, or with NOT_YET and the reason when",
        "they are not."
      ]
      room = VERIFIER_LINES - [ *head, *tail ].join("\n").lines.size
      [ *head, *file_list_lines(files, room), *tail ].join("\n")
    end

    # The one part that gives way: the goal and the criteria are what the loop is
    # judged on, and a prompt that dropped them to fit a directory listing would
    # judge the diff instead of the request. What it leaves out is always stated,
    # and the note costs a line of its own, so this never prints more lines than
    # the room it was given.
    def file_list_lines(files, room)
      return [] if room <= 0
      return [ "(the loop changed no files)" ] if files.empty?
      return files if files.size <= room

      note = "(and #{files.size - [ room - 1, 0 ].max} more changed files not shown)"
      room == 1 ? [ note ] : [ *files.first(room - 1), note ]
    end

    # Only two answers count, and "DONE: tests pass" says what "DONE tests pass"
    # does. A verifier that rambles, or whose verdict is not first on a line, has
    # not said the work is done -- a loop that ends on that lied about its goal.
    def parse_verdict(text)
      text.to_s.each_line do |line|
        trimmed = line.strip
        done = trimmed.match(/\ADONE\b/i)
        return [ :done, detail(done.post_match, "verifier said done") ] if done
        return [ :not_yet, detail(trimmed.sub(/\ANOT_YET\b/i, ""), "no reason given") ] if trimmed.match?(/\ANOT_YET\b/i)
      end
      [ :not_yet, NO_VERDICT ]
    end

    def detail(text, fallback) = text.to_s.strip.sub(/\A[:-]\s*/, "").strip.then { |value| value.empty? ? fallback : value }

    # The commit's message, and the readable half of the entry the run writes:
    # "iteration N: <answer>" on the subject, the rest of the answer as the body.
    # The run's entry puts the sha and the spend in a parenthetical after the
    # number, so the two read as one history -- the subject git keeps is the part
    # a reader matches against the file.
    def commit_message(iteration, text)
      head, *rest = text.to_s.split("\n").map(&:strip)
      [ "iteration #{iteration}: #{head.to_s.empty? ? DEFAULT_SUBJECT : head}", *rest ].join("\n")
    end

    # An iteration that left nothing behind gets no commit: an empty one would add
    # a step a reader cannot tell from real work, and this nil is what the report
    # falls back to when a head could not be read. Subject from the entry's first
    # line and everything after it as the body, so a second step cannot reach the
    # subject.
    def commit_iteration(worktree, id, note)
      return nil unless worktree.changed?(id)

      subject, body = note.split("\n", 2)
      subject = subject.to_s.strip[0, SUBJECT_CHARS].to_s.strip
      subject = DEFAULT_SUBJECT if subject.empty?
      body = body.to_s.strip
      worktree.commit(id, message: body.empty? ? subject : "#{subject}\n\n#{body}")
    end

    # The run names the status for done, stalled and for a pause it woke up to. A
    # budget stop is the one it leaves active, and a loop that will not iterate
    # again until somebody resumes it must not read "active" in the file. Totals are
    # already there -- every iteration charged itself before the next one started.
    def settle(outcome)
      return outcome unless outcome.stop_reason == :budget && outcome.state

      id = outcome.state.id
      @store.update(id) do |loop|
        loop.status = "paused"
        loop.add_entry(entry("paused: #{outcome.message}"))
      end
      outcome.state = @store.load(id)
      outcome
    end

    # A finished loop's worktree holds nothing anybody will wake: the goal was
    # judged satisfied, the branch keeps the commits, and a directory left behind
    # is one more thing on disk nobody remembers making. Every other stop keeps
    # its worktree -- the work in it is unfinished, and a resume continues in
    # the same place rather than starting the repository over.
    #
    # Cleanup never changes the verdict. A loop whose goal was satisfied is done
    # whether or not the directory could be taken away, and a failure is a log
    # line rather than a reason to call finished work unfinished.
    def cleanup(outcome, worktree)
      return outcome unless outcome.stop_reason == :done_by_verifier

      id = outcome.state&.id
      return outcome unless id

      begin
        # Forced: the verifier is told to run the project's tests, and whatever
        # they leave behind (coverage, node_modules, a report) makes an unforced
        # `git worktree remove` refuse. The verdict is already settled, and a
        # kept directory would contradict the log line below, so the branch is
        # what survives, not the scratch files.
        removed = worktree.remove(id, force: true)
        note = if removed
          "worktree removed, branch #{outcome.state.branch} kept"
        else
          # Nothing was there to remove, so the log must not claim a cleanup:
          # a loop whose base workspace moved keeps its directory elsewhere.
          "no worktree was left to remove, branch #{outcome.state.branch} kept"
        end
      rescue StandardError => e
        note = "worktree left in place: #{e.message}"
      end

      outcome.state = @store.update(id) { |loop| loop.add_entry(entry(note)) }
      outcome
    end

    # Every failure ends here: the note in the file, the message in the result,
    # and nothing raised.
    def reported(id, message, reason)
      log("loop #{id}: #{message}")
      state = @store.update(id) { |loop| loop.add_entry(entry(message)) }
      result(state, reason, iterations_of(state), message)
    end

    def charge(id, tokens)
      @store.update(id) { |loop| loop.tokens = loop.tokens.to_i + tokens.to_i } unless tokens.to_i.zero?
    end

    def log(text) = @logger&.call(text.to_s)
    def entry(text) = LoopStore::Entry.new(at: Time.now, text: text)
    def iterations_of(state) = state ? state.iterations.to_i : 0

    # The run's own shape, including the stops this class reports by itself.
    def result(state, reason, iterations, message)
      LoopRun::Result.new(state: state, stop_reason: reason, iterations_run: iterations, message: message)
    end

    def clip(text, max_lines)
      lines = text.to_s.strip.split("\n").map(&:rstrip)
      return "" if lines.empty?
      return lines.join("\n") if lines.size <= max_lines

      (lines.first([ max_lines - 1, 1 ].max) << "...").join("\n")
    end
  end
end
