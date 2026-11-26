# frozen_string_literal: true

require "securerandom"
require "time"

require_relative "loop_lease"
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
    # What an iteration the budget stopped says in its commit subject and its
    # log entry. The turn has no answer to name -- it was cancelled mid-flight --
    # and the notice the agent appends to a stopped turn ("Stopped by user") is
    # not one: it would become the history of a loop nobody stopped.
    BUDGET_SUBJECT = "stopped for its budget"
    # What an iteration that reached its context ceiling says in its commit
    # subject and its log entry. Its notice names the two numbers, which is the
    # right thing for a reader and the wrong thing for a subject: the subject is
    # the one line `git log` shows, and it should say what stopped the work, not
    # repeat the ceiling. The run's own entry carries the numbers.
    CONTEXT_SUBJECT = "stopped at its context ceiling"
    # The first words of the one entry a spent loop gets when it is woken: it is
    # the marker that says the refusal is already in the log, so a schedule that
    # fires every five minutes writes it once instead of forever.
    BUDGET_REFUSED = "resume refused:"
    # A resume may wake these up. `done` is not one of them: its verdict was
    # answered, and an id in a log file must not re-arm a finished loop.
    RESUMABLE = %w[ paused stalled ].freeze
    # What the log says when a loop that looks alive is picked up from a process
    # that is not, so the next reader knows the run has been restarted rather
    # than continued.
    TAKEN_OVER = "taken over: nothing was holding it"

    def initialize(store:, worktree_root:, session_runner:, verifier_persona: "code_reviewer", logger: nil,
                   budget: false)
      @store = store
      @worktree_root = worktree_root
      @session_runner = session_runner
      # Whether the door can be told about the budget. A channel's runner takes
      # it (that is the whole point of it: it is what stops a turn mid-flight),
      # while a lambda written before it existed -- a test's, or another
      # channel's -- only knows a session, a prompt and a workspace, and asking
      # it for a fourth keyword is an ArgumentError before the turn even starts.
      @budget_aware = accepts?(:budget, :spent, :id)
      # A channel that works a loop in production says the brake is required, so
      # a runner that cannot take it stops the loop with a line in the log
      # rather than running with the brake silently off.
      @budget_required = budget
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
    #
    # An `active` file is the case this method exists for. It says a run *should*
    # be iterating, and after a restart it says that about a run that died with
    # its process: without the lease below, the only way out was editing the
    # markdown by hand. The lease is what tells the two apart -- held means a
    # live run, free means somebody died and the loop is taken over.
    #
    # Not every wake is a run. A loop that stopped for its budget is paused, and
    # raising the budget is the only thing that gets it going again: waking it
    # again would buy a turn or a boundary stop and announce the same stop into
    # the conversation, tick after tick. The refusal is recorded once and
    # answered as the run's own :budget result, so nothing downstream reads a
    # wake that did nothing as a loop that moved.
    def resume(id)
      state = @store.load(id)
      refusal = spent_refusal(id)
      return result(@store.load(id), :budget, iterations_of(state), refusal) if refusal

      status = state&.status.to_s
      if RESUMABLE.include?(status)
        # An explicit wake, which is also the reader saying "run it again": the
        # count of takeovers restarts here, so a loop that was stalled by them
        # is not one resume away from being stalled again.
        @store.update(id) do |loop|
          loop.takeovers = 0
          loop.status = "active"
        end
        return run(id)
      end

      return run(id) unless status == "active"
      # A run is really in flight: nothing changes, and one run per loop still
      # holds. run(id) answers the refusal, so the words are the same here as
      # they are for any other caller.
      return run(id) if LoopLease.held?(@store.dir, id)

      takeover(id, state)
    end

    # The note a spent loop gets instead of another wake, nil when it still has
    # room. Public because the channel asks before it spawns a thread: a wake
    # that buys nothing must not answer as if it had started something.
    def spent_refusal(id)
      state = @store.load(id) or return nil
      # Only a loop a wake can move: a finished loop is not re-armed by a bigger
      # budget, and an active one is already spending it.
      return nil unless RESUMABLE.include?(state.status.to_s)

      # The file's own budget, not an argument: the run reads the same number at
      # its boundary, so a resume and a turn cannot disagree about what is left.
      budget = state.max_tokens.to_i
      return nil if state.tokens.to_i < budget

      text = "#{BUDGET_REFUSED} spent #{state.tokens.to_i} of #{budget} tokens; " \
             "raise max_tokens to continue"
      # Once per loop, not once per wake: the entry is what tells a reader why a
      # schedule keeps firing and nothing moves, and a log of the same sentence
      # is a log nobody reads.
      unless state.log.any? { |entry| entry.text.to_s.start_with?(BUDGET_REFUSED) }
        @store.update(id) { |loop| loop.add_entry(entry(text)) }
      end
      log("loop #{id}: #{text}")
      text
    end

    private

    # An `active` file and a free lease: the process that was running this loop is
    # gone. A run per loop still holds -- the lease just proved nobody is running
    # it -- so the loop is picked up where its file says it stopped, unless being
    # picked up is what keeps happening.
    #
    # This decides; the run records. The count and the log entry are written by
    # `run` once it holds the lease, because two wakes of one loop can both get
    # here and only one of them can become a run: a loser that had already
    # written would leave a takeover in the file, and a log line saying a run had
    # been picked up, for a run that never happened.
    def takeover(id, state)
      count = state.takeovers.to_i
      if count >= LoopLease::MAX_TAKEOVERS
        # Taking it over again would spend another iteration on a loop that has
        # never finished one since it started dying, and the run -- or what the
        # run does -- is the best explanation there is. Stalled rather than
        # silently restarted, and said plainly: the count and what clears it are
        # the two facts a reader needs, and neither is in the file before this.
        message = "taken over #{count} times since its last completed iteration, which is " \
                  "probably what kills the process; it is stalled now, and a deliberate resume " \
                  "clears the count and runs it again"
        @store.update(id) do |loop|
          loop.status = "stalled"
          loop.add_entry(entry(message))
        end
        log("loop #{id}: #{message}")
        return result(@store.load(id), :stalled, iterations_of(state), message)
      end

      run(id, takeover: true)
    end

    # The trace of a run that was picked up: nobody was alive to write the ending,
    # so the next reader has to be told the start happened. Counted inside the
    # store's own write, which is what keeps two processes from writing the same
    # number twice.
    def record_takeover(id)
      @store.update(id) do |loop|
        loop.takeovers = loop.takeovers.to_i + 1
        loop.add_entry(entry(TAKEN_OVER))
      end
    end

    def run(id, takeover: false)
      state = @store.load(id)
      return result(nil, :missing, 0, "no loop with id #{id.to_s.inspect}") if state.nil?

      # The file says a loop should be iterating; only a held lease says one is.
      # Taken before git is touched and kept until this method is done, so a
      # second process answers "already active" instead of working the same
      # worktree -- two runs share an index and an iteration number. A run that
      # dies takes nothing with it: the kernel drops the lock with the process.
      #
      # A lock file that cannot even be opened is a loop that cannot be proved
      # either way -- a root-owned file after a privileged run is the ordinary
      # way this happens -- so it is answered in the same voice as a busy loop
      # rather than raised, which would leave the loop unresumable and the tool
      # with a stack trace to show nobody.
      lease = begin
        LoopLease.hold(@store.dir, id)
      rescue SystemCallError, IOError => e
        return result(state, :not_active, 0,
                      "loop #{id} could not be leased (#{e.message}); nothing was started")
      end
      if lease.nil?
        return result(state, :not_active, 0,
                      "loop #{id} is already active in another process; nothing was started")
      end

      begin
        record_takeover(id) if takeover
        worktree = LoopWorktree.new(root: @worktree_root, repo: state.repo)
        begin
          dir, branch, base = prepare(worktree, state)
        rescue LoopWorktree::Error, SystemCallError => e
          # A repository that cannot take a worktree today can take one after the
          # user looks at it, so the loop is left exactly as it was.
          return reported(id, "could not prepare a worktree: #{e.message}", :worktree_error)
        end

        outcome = LoopRun.new(store: @store, worktree: worktree,
                              runner: runner_for(id, worktree, dir, branch, attempt_stamp),
                              verifier: verifier_for(id, worktree, dir, branch, base, attempt_stamp)).call(id)
        log("loop #{id} stopped: #{outcome.stop_reason} after #{outcome.iterations_run} iterations")
        cleanup(settle(outcome), worktree)
      rescue LoopStore::Corrupt
        raise # an unreadable file means an unknown budget, and the caller must know
      rescue StandardError => e
        # Last resort: the reason lands in the file and in the result, because a
        # channel has nobody to show a stack trace to.
        reported(id, "#{e.class}: #{e.message}", :error)
      ensure
        # Every way out of a run releases the lease. The killed-process case is
        # the kernel's, but a return, a raise and a corrupt file all come through
        # here, and a lease left behind by one of those would look like a live run
        # to everyone who asks next.
        lease.release
      end
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
    def runner_for(id, worktree, dir, branch, attempt)
      lambda do |context|
        iteration = context[:iteration].to_i
        # The head on either side of the turn is what says whether it produced
        # anything: an agent may run `git commit` itself, and the worktree it
        # leaves behind is then clean.
        before = worktree.head(id)
        answer = ask("loop-#{id}~a#{attempt}~it#{iteration}", iteration_prompt(context, dir, branch), dir,
                     id: id, budget: context[:budget], spent: context[:spent])
        # A turn the budget stopped has no answer to name: what stopped it is the
        # entry and the commit subject, so the agent's own "stopped" notice never
        # becomes either. A turn that hit its context ceiling is the same case one
        # step later: its answer is the notice that says so, and the subject says
        # the short version instead.
        note = if answer[:budget_stopped]
          BUDGET_SUBJECT
        elsif answer[:context_ceiling]
          CONTEXT_SUBJECT
        else
          answer[:text]
        end
        # Charged here, before the commit, because the commit can fail: a stale
        # index.lock or a refused commit would otherwise throw away a turn the
        # provider already billed. The report hands back zero, since the run
        # charges what a runner reports and this one has already paid.
        charge(id, answer[:tokens])
        commit = commit_iteration(worktree, id, commit_message(iteration, note))
        after = worktree.head(id)
        progress, reported = progress_report(commit, before, after)
        # A turn the budget stopped is reported, never raised: the work it left
        # behind is committed like any other, and the run decides what a spent
        # budget means -- it is the one that knows whether a verdict is still
        # worth buying.
        { text: note, tokens: 0, commit: reported, progress: progress,
          budget_stopped: answer[:budget_stopped], metrics: answer[:metrics],
          round_cap: answer[:round_cap], context_ceiling: answer[:context_ceiling] }
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
    def verifier_for(id, worktree, dir, branch, base, attempt)
      lambda do |context|
        iteration = context[:iteration].to_i
        files = worktree.changed_files(id, base)
        answer = ask("loop-#{id}~a#{attempt}~verify#{iteration}", verifier_prompt(context, dir, branch, files), dir,
                     id: id, budget: context[:budget], spent: context[:spent])
        charge(id, answer[:tokens])
        verdict, reason = parse_verdict(answer[:text])
        { verdict: verdict, reason: reason }
      end
    end

    # A session id per attempt, because the iteration number alone is not one.
    # A run that died mid-iteration comes back to the same number, and reusing
    # its session id hands the new turn the dead one's history and its usage:
    # the brake then reads a spend that was already paid for and cancels the
    # turn before it does a thing (a restart did exactly that to a loop with
    # 5.1M tokens of history under an 8M budget). The stamp carries the process
    # and the second, and the random tail makes two attempts in the same second
    # -- a retry, a resume, a runner built again -- two sessions.
    def attempt_stamp
      "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}-#{SecureRandom.hex(3)}"
    end

    # The one door to an agent: a session id, a prompt, and the worktree as its
    # workspace. A session that raises is left to the run, which already turns a
    # failure into a log entry and an :error stop.
    #
    # The loop's id and budget ride along when the runner takes them. They are
    # what makes a turn stoppable from the inside: a channel that knows the
    # budget cancels the turn it is running the moment the spend reaches it,
    # instead of finishing the turn and discovering the loop was already spent.
    def ask(session_id, prompt, workspace, id: nil, budget: nil, spent: nil)
      log("#{session_id}: #{prompt.lines.size} prompt lines in #{workspace}")
      call = { session_id: session_id, prompt: prompt, workspace: workspace }
      if @budget_aware
        call.merge!(id: id, budget: budget, spent: spent)
      elsif @budget_required
        # A production channel's runner has to take the brake. Falling back to
        # the three-keyword call would leave the loop with no way to stop a turn
        # and nothing in the log to say so, so this stops the loop instead.
        raise ArgumentError,
              "the session runner does not accept the :id, :budget and :spent keywords, " \
              "so this loop's token budget could not reach the turn it is spending"
      end
      answer = @session_runner.call(**call)
      raise TypeError, "session runner returned #{answer.class}" unless answer.is_a?(Hash)

      # Tokens the turn could not write to the loop's budget come back with it:
      # they are the store's shortfall, and the loop's own log is where a reader
      # finds out that the total is not the whole bill.
      unwritten = (answer[:unwritten] || answer["unwritten"]).to_i
      report_unwritten(id, unwritten) if unwritten.positive?

      { text: (answer[:text] || answer["text"]).to_s,
        tokens: (answer[:tokens] || answer["tokens"]).to_i,
        # Only a runner that watched the budget says this, and only when it
        # stopped the turn for it.
        budget_stopped: truthy?(answer[:budget_stopped] || answer["budget_stopped"]),
        # The cap the iteration reached, when it reached one: reported by the
        # agent, carried here, written into the entry by the run.
        round_cap: (answer[:round_cap] || answer["round_cap"]),
        # The other ceiling it can reach, in the same shape and for the same
        # reason: a turn that stopped because its context grew past what is worth
        # sending again is not a failure, and the run is what says so.
        context_ceiling: (answer[:context_ceiling] || answer["context_ceiling"]),
        # The shape of the turn's requests, when the door measured it (see
        # Web#loop_session_runner). Passed through untouched and never
        # invented here: a session runner that reports none leaves the entry
        # without that part, which is what the log then says.
        metrics: (answer[:metrics] || answer["metrics"]) }
    end

    # A turn whose spend never reached the file says so where the loop is read:
    # the store is short by that much, and silently ending the iteration as if
    # it were paid is how a budget stops meaning anything.
    def report_unwritten(id, tokens)
      return if id.to_s.empty?

      note = "#{tokens} tokens spent on this turn could not be written to the loop's budget"
      log("loop #{id}: #{note}")
      @store.append_log(id, note)
    rescue StandardError => e
      log("loop #{id}: could not record #{tokens} unwritten tokens: #{e.message}")
    end

    # What a keyword-only callable agrees to be called with. A lambda says so
    # in its own parameters; an object says it in `call`'s. A `**rest` accepts
    # everything, which is what a runner that forwards its options looks like.
    def accepts?(*names)
      params = begin
        @session_runner.respond_to?(:parameters) ? @session_runner.parameters : @session_runner.method(:call).parameters
      rescue NameError
        []
      end
      return true if params.any? { |kind, _| kind == :keyrest }

      taken = params.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
      names.all? { |name| taken.include?(name) }
    end

    def truthy?(value) = value == true || value == "true"

    # In the order an iteration needs it: what is wanted, how it is judged, where
    # to work, what was already tried, and only then the instructions. The log is
    # trimmed from its oldest end, because the newest entry is the one that says
    # where the last turn stopped.
    #
    # The batching line is about the bill: a request carries the whole
    # conversation, so five dependent calls written one per round pay for the
    # same growing context five times, while two independent calls made together
    # pay for it once. Measured iterations were 76% one-call rounds.
    def iteration_prompt(context, dir, branch)
      lines = [
        "Goal:", clip(context[:goal], GOAL_LINES),
        "", "Done criteria:", clip(context[:done_criteria], CRITERIA_LINES),
        "", "Worktree: #{dir}", "Branch: #{branch}",
        "", "Log, newest first:"
      ]
      tail = [
        "",
        "Batch independent tool calls: when two or more calls do not need each",
        "other's output, make them together in one round instead of one per round.",
        "Make one step of progress toward the done criteria, then stop."
      ]
      room = [ [ PROMPT_LINES - lines.size - tail.size, LOG_WINDOW ].min, 0 ].max
      Array(context[:log]).first(room).each { |entry| lines << "- #{LoopStore.one_line(entry)}" }
      lines.concat(tail)
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
    # budget stop found at the boundary is the one it leaves active, and a loop
    # that will not iterate again until somebody resumes it must not read
    # "active" in the file. Totals are already there -- every iteration charged
    # itself before the next one started, and a turn stopped for its budget
    # charged itself as each usage report arrived. The note goes down once either
    # way; a budget stop that the run already paused (the one a turn reports from
    # the inside) is paused here again, which is the same write.
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
