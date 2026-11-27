# frozen_string_literal: true

require "time"

require_relative "loop_store"
require_relative "loop_worktree"

module Rubot
  # Runs one loop to a stopping point.
  #
  # A loop is a goal an agent works at over many iterations, so the work itself
  # arrives through `runner` and the judgement through `verifier`: this class
  # never touches a provider, a Ractor or a channel, which is what lets the
  # whole cycle be tested with two lambdas. What it owns is the part that must
  # be identical every time -- the budget, the record on disk, and the decision
  # to stop -- because a loop that cannot stop is a bill, not a tool.
  #
  # The store is the only counter and the only status: the loop re-reads its
  # state at the top of every iteration and again immediately before it spends
  # anything, so a pause lands at an iteration boundary -- before the next one is
  # paid for, never in the middle of a turn -- and a resumed run continues from
  # the file, not from a fresh budget.
  #
  # A budget is the one thing that does stop a turn already in flight, because a
  # turn is where the tokens go: one iteration is two full turns and each request
  # inside one re-sends the conversation, so a turn can cost millions. The runner
  # is told the budget and the spend so far (see #runner_context), debits what it
  # reports, and answers `budget_stopped` when it cancelled the turn for it. What
  # that changes here is small and exact: the work is committed, and no verdict is
  # bought for it -- the verifier is a second turn of the same size.
  #
  # Two stops are worth telling apart. A *stall* is an agent that produced
  # nothing new twice in a row, judged by what the runner reported rather than by
  # the worktree, which is clean again once the work is committed, so iterating
  # only spends tokens. *Verifier stuck* is the opposite: the agent does produce
  # new work, yet the same reason comes back, so more iterations will not fix it.
  # "The same reason" is judged on a normalised key, not on the raw sentence: a
  # verifier names the file and the count it just looked at, and those move every
  # iteration (see #reason_key).
  #
  # A *context ceiling* is the third: an iteration stopped because its transcript
  # grew past what is worth sending again. Unlike the budget, which reaches
  # inside a turn, this one happens at a round boundary and costs nothing -- the
  # request that would have re-sent the transcript is never made. The work is
  # committed like any other iteration's, no verdict is bought for it, and the
  # loop pauses because a step that cannot finish under the ceiling is a step the
  # user has to split or raise the ceiling for.
  class LoopRun
    Result = Struct.new(:state, :stop_reason, :iterations_run, :message, keyword_init: true)

    # How much of the log reaches an iteration: enough to know what was tried.
    # An iteration writes two entries -- the work and its verdict -- so this is
    # about five iterations of history, which is more than the default cap lets
    # a loop run in one go.
    LOG_WINDOW = 10
    COMMIT_SUBJECT_CHARS = 72
    STUCK_REPEATS = 3
    STALL_REPEATS = 2
    # What a normalised reason has instead of the parts that move: a hash, a
    # count, a path. The placeholder itself carries none of those, so a later
    # rule cannot rewrite what an earlier one put down.
    REASON_PLACEHOLDER = "<var>"
    # A file named without a directory: a root file, or one whose path was
    # already folded away. Anything not in this list is left alone, because a
    # path is only worth folding when it is plainly one.
    REASON_FILE = %r{[^\s/]*\.(?:rb|md|txt|json|yml|yaml|erb|html|css|js|sh|lock|toml)\b}
    # Only a prefix of the reason is compared: a verifier that rambles should not
    # have its first sentence buried, and two failures that agree this far agree
    # in the part that matters.
    STUCK_REASON_CHARS = 120
    # The marker a commit carries when no verdict was bought for it, so the
    # branch says what the log says: this work was never judged (see #subject).
    UNVERIFIED_MARKER = "[unverified]"
    VERDICTS = { "done" => :done, "not_yet" => :not_yet }.freeze

    # The share of its budget a loop may spend before it stops to ask instead of
    # buying another verdict. At nine tenths the next iteration -- work and
    # verdict, two full turns of the same size -- can no longer be paid for, so
    # the iteration just finished is committed unverified and the loop pauses.
    # A constant, not a field in the loop's own file: the file already carries
    # facts that have to stay in sync across every path that writes it, and a
    # per-loop threshold is one more of those for no gain.
    BUDGET_WARNING = Rational(9, 10)

    # Every way a run can end, in one place, so a caller can write an exhaustive
    # case over the result instead of grepping for the symbols.
    STOP_REASONS = %i[
      done_by_verifier max_iterations budget budget_warning stalled verifier_stuck paused
      not_active context_ceiling missing error worktree_missing repo_mismatch
    ].freeze

    # Whether a loop that has spent `tokens` of `budget` has reached its warning.
    # The one implementation of the fraction: the run decides the stop with it,
    # and a runner marks the commit it makes with it (see LoopRunner), because a
    # commit written at the end of a turn is the one the run cannot mark later
    # without amending it. A budget nobody set warns on nothing.
    def self.budget_warning?(tokens, budget)
      limit = budget.to_i
      limit.positive? && tokens.to_i >= limit * BUDGET_WARNING
    end

    # Raised only to leave an iteration that cannot go on: the note is on disk
    # by then, and the stop reason travels with it because a runner that failed
    # and a worktree that vanished are different repairs for the user.
    class Failed < StandardError
      attr_reader :stop_reason
      def initialize(message, stop_reason: :error)
        super(message)
        @stop_reason = stop_reason
      end
    end

    # `max_tokens` is an override, never the budget itself: the cap that counts
    # is the one in the state file, so a resumed run, a cron retry or a second
    # process cannot hand a spent loop another full budget by omitting it.
    def initialize(store:, worktree:, runner:, verifier:, max_tokens: nil)
      @store = store
      @worktree = worktree
      @runner = runner
      @verifier = verifier
      @max_tokens = max_tokens&.to_i
    end

    def call(id)
      state = @store.load(id)
      return result(nil, :missing, 0, "no loop with id #{id.to_s.inspect}") if state.nil?
      return result(state, stop_reason_for(state.status), 0, "loop is #{state.status}") unless active?(state)

      # A loop names the repository it was created for. Running it against
      # another one would put an iteration's commits on a branch nobody reads,
      # so a mismatch is refused instead of repaired.
      mine = state.repo.to_s
      theirs = @worktree.repo.to_s
      if !mine.empty? && !theirs.empty? && File.expand_path(mine) != File.expand_path(theirs)
        return result(state, :repo_mismatch, 0, "loop is bound to #{mine}, not #{theirs}")
      end

      begin
        ensure_worktree(state.id)
      rescue LoopWorktree::Error, SystemCallError => e
        # The loop stays active: a repository that cannot take a worktree today
        # (dirty tree, missing branch) can take one after the user looks at it.
        return result(state, :error, 0, "could not create a worktree: #{e.message}")
      end

      run(state.id)
    end

    private

    # Nothing is counted here: how far the loop has come is read back from the
    # store, which is what makes a resumed run agree with the file.
    def run(id)
      # Nothing has been produced before the first iteration, so an iteration
      # producing nothing must not compare equal to "no previous key".
      previous_key = Object.new
      repeats = 0
      stuck_key = nil
      stuck_count = 0

      loop do
        state = @store.load(id) or return result(nil, :missing, 0, "loop disappeared")

        # Re-read every iteration: a pause lands here, at the boundary, before
        # another iteration is paid for. Nothing interrupts a turn already being
        # worked, which is why #iterate looks once more before it spends.
        unless active?(state)
          return result(state, stop_reason_for(state.status), iterations_of(state), "loop is #{state.status}")
        end
        return stop_at_the_cap(state) if state.iterations.to_i >= state.max_iterations.to_i
        return result(state, :budget, iterations_of(state),
                      "spent #{state.tokens} of #{budget_for(state)} tokens") if over_budget?(state)

        begin
          step = iterate(state)
        rescue Failed => e
          return stopped(id, e.stop_reason, e.message)
        end

        if step[:verdict] == :done
          # No note here: the verdict is already in the file, written once by
          # #iterate where every verdict passes.
          finish(id, "done")
          return stopped(id, :done_by_verifier, step[:reason])
        end

        # Compared by its normalised key, never by its bytes: the verifier
        # reasons about the file and the number it just looked at, so the same
        # failure comes back in different words every iteration. What the user
        # reads -- the note and the result -- stays the raw sentence.
        now = reason_key(step[:reason])
        stuck_count = now == stuck_key ? stuck_count + 1 : 1
        stuck_key = now
        if stuck_count >= STUCK_REPEATS
          finish(id, "paused", "verifier gave the same reason #{stuck_count} times: #{step[:reason]}")
          return stopped(id, :verifier_stuck, step[:reason])
        end

        # Only what the runner said it produced goes in the key, not the reason:
        # an agent that keeps producing while the verifier keeps refusing is
        # stuck (above), which is a different repair from one that stopped.
        key = step[:produced]
        repeats = key == previous_key ? repeats + 1 : 1
        previous_key = key
        next if repeats < STALL_REPEATS

        finish(id, "stalled", "no new work for #{repeats} iterations: #{step[:reason]}")
        return stopped(id, :stalled, step[:reason])
      end
    end

    # One iteration: ask for work, charge it, keep it, then have it judged. The
    # count and the tokens reach the store the moment the runner returns --
    # before the commit, the diff read, the verdict or the log write, any of
    # which can fail -- so an iteration that falls over still costs what the
    # provider already charged for it.
    #
    # One entry per iteration and one per verdict. The iteration's is written
    # once the commit sha and both halves of the spend are known, before the
    # verdict's, and so sits below it in the file's newest-first log: written
    # earlier it could only carry the number and the worker's part, and written
    # in both places -- by the runner and by the run -- the same text landed
    # twice, which is how a real run logged five entries for one iteration.
    #
    # The split is measured, not reported. A lambda may charge the store itself
    # (LoopRunner does) or hand the tokens back to be charged here (a plain
    # runner lambda), so what each side spent is the difference in the store's
    # one total, read before the runner and after each call. `tokens` stays the
    # only counter: the budget is checked against it, and nothing here keeps a
    # second one that could disagree with it.
    def iterate(state)
      # The status was read at the top of the loop and that read is a moment old
      # by now: a pause issued in the gap would still buy a whole iteration plus
      # its verification, tens of thousands of tokens, after the user was told the
      # loop had stopped. This is the last look that can say no for free.
      check_still_active!(state.id)

      iteration = state.iterations.to_i + 1
      before = tokens_of(state.id)
      record = call_runner(runner_context(state, iteration))
      # Zero from a runner that watched the budget and paid the store itself as
      # each usage report arrived: charging its total here as well would count
      # one turn twice.
      charge(state.id, iteration, record[:tokens].to_i)

      # A turn the budget stopped on purpose reports the stop, not a failure:
      # the cancellation it caused is the stop, and what it already spent is on
      # the file, so nothing here raises for it.
      budget_stop = record[:budget] == true
      if record[:error] && !budget_stop
        fail_iteration(state.id, "iteration #{iteration} failed: #{record[:error]}")
      end

      # Read back from the file, never from the state this iteration began
      # with: the turn just paid it. The verifier is a second turn of the same
      # size, and one iteration that reaches this point with nothing left is how
      # a loop spent five million tokens against a five-hundred-thousand budget
      # -- half of it on judgement nobody could afford. What the turn produced is
      # committed below, so stopping here costs the loop its verdict, not its
      # work.
      spent = tokens_of(state.id)

      text = one_line(record[:text])
      begin
        # Read before the commit: afterwards the worktree is clean again.
        diff = diff_of(state.id)
        # The loop's money decides the iteration's fate here, before the commit
        # and not after it, so the commit can carry the decision. A verdict that
        # is never bought is written into the subject of the commit that stands
        # for the iteration, which is the branch's own record: `git log` then
        # says "unverified" without anyone having to open the loop's file, and a
        # later resume cannot make the history imply a judgement nobody paid for.
        stop = stop_after_work(state, spent: spent, budget_stop: budget_stop,
                               ceiling: record[:context_ceiling])
        ours = commit_iteration(state.id, record[:text], unverified: unverified?(stop))
      rescue LoopWorktree::Error => e
        fail_iteration(state.id, "commit failed: #{e.message}")
      rescue Errno::ENOENT => e
        # A worktree removed underneath the run is where the loop stops, not an
        # exception for the caller to translate.
        fail_iteration(state.id, "worktree is missing: #{e.message}", reason: :worktree_missing)
      end

      # The runner may commit its own work; then the sha it reported is the one.
      commit = record[:commit] || ours
      # Measured between two reads of one total, so a file that went away mid
      # iteration cannot make the split negative.
      worker = [ tokens_of(state.id) - before, 0 ].max

      # What the turn's own reports said about its shape, read off the report
      # before anything is written: the note is the only place a reader finds
      # out whether this iteration was expensive because the work was, or
      # because every request re-sent a conversation that had grown (see
      # #request_facts). A runner that reports none leaves it nil.
      metrics = record[:metrics]
      # The ceiling this iteration reached, if it reached one: the agent reports
      # it, and the entry is the only place it becomes history.
      round_cap = record[:round_cap]
      ceiling = record[:context_ceiling]

      if reason_of(stop) == :budget
        @store.update(state.id) do |s|
          s.add_entry(entry(iteration_note(iteration, commit, worker, 0, text, metrics, round_cap, ceiling)))
        end
        fail_iteration(state.id, "budget spent at iteration #{iteration}: " \
                                 "#{spent} of #{budget_for(state)} tokens", reason: :budget)
      end

      # The loop has spent nine tenths of its allowance, so it stops to ask
      # rather than buying a judgement it could not pay for whole. This is a
      # boundary decision and not a cancellation: the turn that just finished
      # ran to its end, its work is committed, and what it is missing is a
      # verdict -- which is why the entry says what is waiting instead of what
      # went wrong.
      if reason_of(stop) == :budget_warning
        waiting = waiting_facts(@worktree.commit_stat(state.id, commit), changed_files_of(state))
        @store.update(state.id) do |s|
          s.add_entry(entry(iteration_note(iteration, commit, worker, 0, text, metrics, round_cap, ceiling,
                                           waiting: waiting)))
        end
        fail_iteration(state.id, "budget warning at iteration #{iteration}: " \
                                 "#{spent} of #{budget_for(state)} tokens spent; " \
                                 "its work is unverified, not unfinished", reason: :budget_warning)
      end

      # The iteration stopped because its context grew past what is worth
      # sending again. Its work is committed above, and no verdict is bought for
      # it: the turn stopped before the request, so the iteration has no answer
      # to judge -- judging the notice would spend a second turn on the same
      # transcript. The loop pauses rather than starting another iteration blind,
      # because a goal that needs more than the ceiling in one step is a goal the
      # user has to look at: raise the ceiling, or split the step.
      if ceiling
        numbers = ceiling_tokens(ceiling)
        @store.update(state.id) do |s|
          s.add_entry(entry(iteration_note(iteration, commit, worker, 0, text, metrics, round_cap, ceiling)))
        end
        fail_iteration(state.id, "context ceiling reached at iteration #{iteration}: " \
                                 "#{kilo(numbers[:tokens])} of #{kilo(numbers[:limit])} tokens; " \
                                 "its work is committed and no verdict was bought for it",
                       reason: :context_ceiling)
      end

      verdict = ask_verifier(state, iteration, text, commit, diff, spent)
      verifier = [ tokens_of(state.id) - before - worker, 0 ].max

      @store.update(state.id) do |s|
        s.add_entry(entry(iteration_note(iteration, commit, worker, verifier, text, metrics, round_cap, ceiling)))
      end
      fail_iteration(state.id, "verifier failed: #{verdict[:error]}") if verdict[:error]
      @store.update(state.id) do |s|
        s.add_entry(entry("verifier: #{verdict[:reason]}"))
        # An iteration that reached its verdict is proof the run survived one
        # whole turn and got judged, so the takeovers it outlived are cleared.
        # Not before: an iteration is counted the moment it starts spending, so
        # a charge is what a run makes on its way into dying, not evidence it
        # lived. This is the only place a loop's progress is written down, which
        # is what makes the ceiling count crashes instead of restarts.
        s.takeovers = 0
      end

      {
        verdict: verdict[:verdict], reason: verdict[:reason], commit: commit,
        produced: produced(record[:commit], ours, record[:progress])
      }
    end

    # The second and last look at the status, taken when the next iteration is
    # already chosen but nothing has been spent on it yet. Nothing is written
    # here: the store already says paused, and the run leaves the file exactly as
    # the user set it. A pause lands at an iteration boundary, never mid-turn --
    # an iteration whose runner has already been called is left to finish and to
    # be judged, and this check stops the loop before another one is paid for.
    def check_still_active!(id)
      state = @store.load(id) or raise Failed.new("loop disappeared", stop_reason: :missing)
      return if active?(state)

      raise Failed.new("loop is #{state.status}", stop_reason: stop_reason_for(state.status))
    end

    def ensure_worktree(id)
      return if @worktree.exists?(id)

      dir = @worktree.create(id: id)
      branch = @worktree.branch(id)
      # The commit the worktree was created from, recorded with the worktree the
      # way the runner records it: it is what the loop's work is measured from,
      # and a stop that has to name the files it is waiting on cannot derive it
      # afterwards without moving the line.
      base = @worktree.head(id)
      @store.update(id) do |s|
        s.worktree = dir
        s.branch = branch
        s.base ||= base
      end
    end

    # The subject comes from the report as written: the flattened text is what
    # the log and the verifier read, not what git is asked to record. A commit
    # made for an iteration no verdict was bought for carries the marker, which
    # is why the decision has to be taken before this is called.
    def commit_iteration(id, report, unverified: false)
      return nil unless @worktree.changed?(id)

      @worktree.commit(id, message: subject(report, unverified: unverified))
    end

    # What the loop's money says about the iteration that has just been paid
    # for, decided at the boundary and not inside a turn: nil for the ordinary
    # iteration that goes on to be judged, otherwise the reason it stops here.
    #
    # The order is the order of the money. A budget already spent -- found here,
    # or reported by a runner that cancelled the turn for it -- comes first and
    # keeps its mid-turn cancellation; a context ceiling is the turn's own
    # report; the warning is the loop spending nine tenths of its allowance,
    # where the next iteration and its verdict could no longer be afforded.
    def stop_after_work(state, spent:, budget_stop:, ceiling:)
      limit = budget_for(state)
      return { reason: :budget, spent: spent, limit: limit } if budget_stop || spent >= limit
      return { reason: :context_ceiling, ceiling: ceiling } if ceiling
      return { reason: :budget_warning, spent: spent, limit: limit } if self.class.budget_warning?(spent, limit)

      nil
    end

    def reason_of(stop) = stop && stop[:reason]

    # Only the stops that leave the work committed with no judgement are marked:
    # a context ceiling did not stop the money, and its commit reads as it always
    # has until a ticket asks otherwise.
    def unverified?(stop) = %i[budget budget_warning].include?(reason_of(stop))

      # What a warning is waiting for, in the reader's words: the shape of the work
      # and the files it touched, so the choice between keeping it and dropping it
      # can be made without opening the worktree. The summary is the iteration's
      # own commit -- the only place a new file's size appears -- and the file
      # list is the loop's own, measured from the commit it started at.
      def waiting_facts(stat, files)
        facts = []
        stat = one_line(stat.to_s.lines.map(&:strip).reject(&:empty?).last)
        facts << "diff #{stat}" unless stat.empty?
        facts << "files #{one_line(files.join(', '))}" unless files.empty?
        facts
      end

    # The files the loop has touched since it started, off the worktree's own
    # seam: a loop with no base recorded, or a worktree that has gone away, says
    # nothing rather than raising in the middle of writing an entry.
    def changed_files_of(state) = @worktree.changed_files(state.id, state.base)

    # The file's cap unless the caller named one for this run.
    def budget_for(state) = @max_tokens || state.max_tokens.to_i

    def over_budget?(state) = state.tokens.to_i >= budget_for(state)

    def diff_of(id) = @worktree.diff_stat(id)

    def runner_context(state, iteration)
      {
        id: state.id,
        iteration: iteration,
        goal: state.goal,
        done_criteria: state.done_criteria,
        worktree: state.worktree,
        log: state.log.first(LOG_WINDOW).map(&:text),
        # The two facts a runner needs to stop a turn that is already spending:
        # what the loop may spend in all, and what it had spent when this
        # iteration began. A runner that only respects them at the boundary is
        # the bug this exists to fix -- one turn can spend a loop's whole budget
        # and more.
        budget: budget_for(state),
        spent: state.tokens.to_i
      }
    end

    # `spent` is passed rather than read off the state, because by now the work
    # turn has paid and the state this iteration began with is stale: the verdict
    # is a second turn charged against the same budget, so a runner told zero
    # would let it spend the whole allowance again.
    def verifier_context(state, iteration, text, commit, diff, spent)
      runner_context(state, iteration).merge(text: text, commit: commit, diff_stat: diff, spent: spent)
    end

    # Both callables return plain hashes and may fail in three ways: raise,
    # answer with an :error, or answer something that is not a hash at all. All
    # three end the same way, with the reason on disk instead of a stack trace
    # in a terminal nobody is watching. What the runner produced is read from
    # its own report: a clean worktree is not evidence of anything, because the
    # runner may have committed what it did.
    #
    # A fourth answer is `budget_stopped`: the runner watched the spend during
    # the turn, cancelled it when it reached the budget, and paid the store
    # before returning. It is not an error and it is not a report to charge
    # again, which is why it travels as a fact of its own.
    def call_runner(context)
      record = @runner.call(context)
      return { error: "runner returned #{record.class}" } unless record.is_a?(Hash)

      tokens = (record[:tokens] || record["tokens"]).to_i
      error = record[:error] || record["error"]
      budget = flag_of(record, :budget_stopped) || flag_of(record, :budget)
      metrics = (record[:metrics] || record["metrics"])
      round_cap = (record[:round_cap] || record["round_cap"])
      ceiling = (record[:context_ceiling] || record["context_ceiling"])
      return { error: error.to_s, tokens: tokens, budget: budget, metrics: metrics } if error

      { text: (record[:text] || record["text"]).to_s, tokens: tokens, budget: budget,
        commit: sha_of(record), progress: progress_of(record), metrics: metrics,
        round_cap: round_cap, context_ceiling: ceiling }
    rescue StandardError => e
      { error: "#{e.class}: #{e.message}", tokens: 0 }
    end

    # Whether the report carries a fact, under the symbol or the string key: a
    # runner may be handed a context and answer in either spelling.
    def flag_of(record, key)
      value = record[key].nil? ? record[key.to_s] : record[key]
      value == true || value == "true"
    end

    def sha_of(record) = (record[:commit] || record["commit"]).to_s.strip.then { |sha| sha.empty? ? nil : sha }

    # nil means the runner said nothing about progress, which is not the same
    # as saying there was none: only an explicit false overrides its commits.
    def progress_of(record)
      value = record[:progress].nil? ? record["progress"] : record[:progress]
      value.nil? ? nil : value != false
    end

    def ask_verifier(state, iteration, text, commit, diff, spent)
      record = @verifier.call(verifier_context(state, iteration, text, commit, diff, spent))
      return { error: "verifier returned #{record.class}" } unless record.is_a?(Hash)

      verdict = verdict_of(record[:verdict] || record["verdict"])
      return { error: "unknown verdict #{record[:verdict].inspect}" } if verdict.nil?

      reason = (record[:reason] || record["reason"]).to_s.strip
      { verdict: verdict, reason: reason.empty? ? "no reason given" : reason }
    rescue StandardError => e
      { error: "#{e.class}: #{e.message}" }
    end

    def verdict_of(value) = VERDICTS[value.to_s]

    # The key that decides whether the verifier said the same thing again.
    #
    # The raw sentence cannot be compared. A verifier reports what it just
    # looked at -- "case notes/04.md has 7 entries" -- so a loop that keeps
    # producing work while the criteria never pass hands back a different string
    # every iteration: same failure, different file, different count. Compared
    # byte for byte, that loop looks like news each time and runs to the cap or
    # the budget, and the one stop meant to catch it can never fire outside a
    # fake verifier that repeats itself. Folding out the moving parts leaves the
    # claim itself, so two refusals of one failure compare equal while "the
    # tests do not compile" is still a different failure from "the config is
    # missing". Only the comparison uses this; the reason the user reads stays
    # the sentence the verifier wrote.
    def reason_key(reason)
      key = reason.to_s.downcase
      key = key.gsub(/\b0x[0-9a-f]{4,}\b|\b[0-9a-f]{6,}\b/, REASON_PLACEHOLDER) # a hash, a sha, 0xdeadbeef
      key = key.gsub(/\d+/, REASON_PLACEHOLDER)              # a count, a line, an offset
      key = key.gsub(%r{\S*/\S*}, REASON_PLACEHOLDER)        # notes/05.md, src/lib/foo
      key = key.gsub(REASON_FILE, REASON_PLACEHOLDER)        # a root foo.rb, foo.md
      key.gsub(/\s+/, " ").strip[0, STUCK_REASON_CHARS].to_s
    end

    def fail_iteration(id, note, reason: :error)
      # The counters are already charged, so nothing here touches them: this
      # writes the status and the note, raising with the reason for #run.
      @store.update(id) do |s|
        s.status = "paused"
        s.add_entry(entry(note))
      end
      raise Failed.new(note, stop_reason: reason)
    end

    # A status, and a note only when the stop has something of its own to say.
    # `done` passes none: the verdict that ended the loop is already in the file,
    # written once where every verdict is written, and saying it again here is
    # how one verdict came to be logged twice.
    def finish(id, status, note = nil)
      @store.update(id) do |s|
        s.status = status
        s.add_entry(entry(note)) if note
      end
    end

    # The cap settles where every other stop does, not in a caller that may or
    # may not remember it: a file left saying `active` at it=2/2 is a loop that
    # `list` shows as running forever and nothing will ever move. `paused` is
    # the status, the same one a spent budget gets, because the repair is the
    # same road -- raise the cap and resume -- and every reader of a status
    # already knows what `paused` means. The reason stays :max_iterations: how
    # the loop stopped and what the file says afterwards are two facts, and a
    # status of its own would ripple into every badge and resume rule for none.
    def stop_at_the_cap(state)
      finish(state.id, "paused",
             "iteration cap reached at #{state.max_iterations} iterations; " \
             "raise max_iterations before resuming")
      stopped(state.id, :max_iterations, "reached #{state.max_iterations} iterations")
    end

    # The one write that must not be lost: the count and the tokens land before
    # the commit and before the verdict, so a pause or a crash costs the
    # iteration in flight and not the budget already spent.
    #
    # `update`, never `save`: the state this iteration read at the top of the
    # loop is stale by the time the runner answers, and #save merges a stale
    # object by diffing its facts against the ones it was read with. `tokens`
    # would differ, so #save writes that object's absolute total and erases
    # whatever the verifier charged while the iteration was in flight. #update
    # instead re-reads the file under the exclusive lock and adds to what is
    # there, so this charge and a verifier's -- from this process or another --
    # both survive, counted once each.
    def charge(id, iteration, tokens)
      @store.update(id) do |s|
        s.iterations = iteration
        s.tokens = s.tokens.to_i + tokens
      end
    end

    def entry(text) = LoopStore::Entry.new(at: Time.now, text: text)

    # The one entry an iteration gets: what it did, the commit it stands on when
    # there is one, and what each side of the turn cost.
    #
    # The part after the colon is the commit subject a runner made itself, so
    # `git log` on the loop's branch and this file read as the same history in
    # the same order. The sha cannot be in the subject of the commit it names,
    # which is why the parenthetical sits between the number and the text rather
    # than being part of the subject git records.
    #
    # `metrics` is what the turn's own usage reports said about its shape: how
    # many requests it made, how big the context was at the first and the last of
    # them, and the cache hit rate. Those three are what tells a reader whether a
    # loop is expensive because the work is, or because every request re-sends a
    # conversation that grew. It is nil for a runner that reports none -- there
    # is then nothing honest to say, and a fabricated "req 0" would read as a turn
    # that made no request at all.
    def iteration_note(iteration, commit, worker, verifier, text, metrics = nil, round_cap = nil, ceiling = nil,
                       waiting: nil)
      facts = []
      facts << "sha #{commit[0, 7]}" if commit
      facts << "worker #{kilo(worker)}"
      facts << "verifier #{kilo(verifier)}"
      facts.concat(request_facts(metrics))
      facts.concat(round_facts(round_cap))
      facts.concat(ceiling_facts(ceiling))
      # Last, because these are the facts of an iteration that stopped to ask:
      # what is waiting in the worktree, and what it looks like.
      facts.concat(Array(waiting))
      "iteration #{iteration} (#{facts.join(', ')}): #{text}"
    end

    # The context ceiling an iteration stopped at, and what it weighed when it
    # did. The other ceiling, in the same shape: an entry that says
    # `ceiling 100k/100k` is an iteration that ended because the transcript had
    # grown, not because the work had.
    def ceiling_facts(ceiling)
      ceiling = ceiling.is_a?(Hash) ? ceiling : {}
      tokens = read_metric(ceiling, :tokens).to_i
      limit = read_metric(ceiling, :limit).to_i
      return [] unless tokens.positive? && limit.positive?

      [ "ceiling #{kilo(tokens)}/#{kilo(limit)}" ]
    end

    # The two numbers off a reported ceiling, read once for the note and once for
    # the message the stop is announced with.
    def ceiling_tokens(ceiling)
      ceiling = ceiling.is_a?(Hash) ? ceiling : {}
      { tokens: read_metric(ceiling, :tokens).to_i, limit: read_metric(ceiling, :limit).to_i }
    end

    # The one fact that says the iteration stopped at its own ceiling rather
    # than on its own: a reader who sees a thin entry needs to know whether the
    # work ran out or the turn did. Present only when the agent reported it, so a
    # runner that cannot is not accused of a cap it never reached.
    def round_facts(cap)
      cap = cap.is_a?(Hash) ? cap : {}
      rounds = read_metric(cap, :rounds).to_i
      limit = read_metric(cap, :limit).to_i
      return [] unless rounds.positive? && limit.positive?

      [ "rounds #{rounds}/#{limit}" ]
    end

    # The three facts of a turn's own shape, each only when the report carried
    # it: a metric that never arrived is left out rather than guessed, so the
    # parenthetical is exactly as long as what the turn measured. The cache
    # share arrives the way a usage report states it, as a fraction of the last
    # request's prompt tokens, and is written as the reader's percentage.
    def request_facts(metrics)
      metrics = metrics.is_a?(Hash) ? metrics : {}
      requests = read_metric(metrics, :requests).to_i
      first = read_metric(metrics, :context_first)
      last = read_metric(metrics, :context_last)
      cache = read_metric(metrics, :cache_hit_rate)
      facts = []
      facts << "req #{requests}" if requests.positive?
      facts << "ctx #{kilo(first)}->#{kilo(last)}" if first && last && first.to_i.positive?
      facts << "cache #{(cache.to_f * 100).round}%" unless cache.nil?
      facts
    end

    # A report may arrive under symbol or string keys; the loop only ever writes
    # symbol ones, and a runner written by somebody else may not.
    def read_metric(metrics, key)
      value = metrics[key]
      value.nil? ? metrics[key.to_s] : value
    end

    # Tokens as a reader adds them up: a thousand at a time, because the exact
    # figure is in the frontmatter and a log line is history, not an invoice.
    def kilo(tokens)
      count = tokens.to_i
      count < 1_000 ? count.to_s : "#{(count / 1_000.0).round}k"
    end

    # What a step of the iteration cost, from the one counter the budget is
    # checked against: read either side of the call, the difference is what it
    # spent no matter which side charged it.
    def tokens_of(id)
      state = @store.load(id)
      state ? state.tokens.to_i : 0
    end

    # A commit subject is one line, taken from the report's own first line and
    # capped so a runaway first line cannot become the whole history. The
    # report is not flattened first: a second line belongs in the log entry,
    # never in a subject that would then carry a newline into git.
    #
    # The marker goes in front, where a cap on the text cannot eat it: the whole
    # point of the subject is that `git log --oneline` says the iteration was
    # never judged, and a marker hidden past the truncation says nothing.
    def subject(report, unverified: false)
      line = report.to_s.each_line.first.to_s.strip
      line = "loop iteration" if line.empty?
      return line[0, COMMIT_SUBJECT_CHARS].to_s.strip unless unverified

      room = [ COMMIT_SUBJECT_CHARS - UNVERIFIED_MARKER.length - 1, 1 ].max
      "#{UNVERIFIED_MARKER} #{line[0, room]}".strip
    end

    # One implementation, shared with the store: both shape a note into one line.
    def one_line(text) = LoopStore.one_line(text)

    # What the iteration produced, from what the runner reported and from the
    # commit made out of what it left behind -- never from the worktree's dirty
    # state: an agent that commits its own work leaves the worktree clean, and a
    # dirty check would call that a stall on the iteration that did the most.
    # `progress: false` overrides both; `progress: true` without a commit is
    # work the runner cannot name but did do.
    def produced(reported_commit, commit, progress)
      return nil if progress == false

      reported_commit || commit || (Object.new if progress)
    end

    # The result reads its counters from the store: a resumed run reports the
    # loop's total rather than a count of its own.
    def stopped(id, reason, message)
      state = @store.load(id)
      result(state, reason, state ? iterations_of(state) : 0, message)
    end

    def iterations_of(state) = state.iterations.to_i

    # A paused loop is resumable whatever paused it -- the user, or the run
    # itself at the cap -- and anything else is finished.
    def stop_reason_for(status) = status.to_s == "paused" ? :paused : :not_active

    def active?(state) = state.status.to_s == "active"

    def result(state, stop_reason, iterations_run, message)
      Result.new(state: state, stop_reason: stop_reason, iterations_run: iterations_run, message: message)
    end
  end
end
