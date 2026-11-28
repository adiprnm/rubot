# frozen_string_literal: true

require_relative "../loop_run"
require_relative "../loop_runner"
require_relative "../loop_store"
require_relative "../loop_worktree"
require_relative "reports"

module Rubot
  module Web
    # The web channel's half of a loop: the one place that hands the loop tool
    # something able to iterate.
    #
    # A loop outlives the turn that started it, so nothing here waits for it.
    # Iterations run on a thread of their own, in a worktree of their own, and a
    # reader learns where the loop got by asking the tool for its status -- a
    # loop's progress is a file on disk, not a stream to draw.
    module Loops
      # The drawing of a report is shared with the delegated runs, which arrive
      # the same way: a background turn in a conversation that is already open.
      include Rubot::Web::Reports

      # The state file and the checkout it works in sit under the same root, so
      # a loop's file and its worktree are never separated by a configuration
      # change: the tool is stamped with the same root (see #bind_loop_runner).
      LOOPS_DIR = "loops"
      WORKTREES_DIR = "worktrees"
      # The one status the footer's panel draws. A loop that is paused, finished
      # or stalled is not in flight, and the panel exists to answer "what is
      # being worked right now?" — the loop tool is what answers the rest.
      LOOP_PANEL_STATUS = "active"
      # The operations a `:loop` event can carry: the ones a runner performs.
      # Status and list are answered from the state file by the tool itself.
      LOOP_OPS = %i[start resume abort].freeze
      # What a finished run is worth a turn for. The exclusions are the point:
      # `paused` is the reader's own doing and they know how it ended, while
      # `missing` and `not_active` are not endings at all -- nothing ran, so
      # there is nothing to report. `worktree_missing` is the run's own name for
      # a checkout that vanished mid-iteration, which is the same repair as a
      # worktree that could not be prepared in the first place.
      #
      # Every way of running out of room is in here, not only the ones that read
      # like a verdict: `budget` spent the loop's tokens, `max_iterations` used
      # its last chance, `verifier_stuck` kept getting the same refusal. A loop
      # that stops short of the goal and says nothing is a loop the reader has
      # to ask `status` about -- which is the whole reason this exists.
      ANNOUNCED_STOPS = %i[
        done_by_verifier stalled budget budget_warning max_iterations verifier_stuck context_ceiling
        error worktree_error worktree_missing
      ].freeze
      # The endings a schedule can produce over and over, and the ones that must
      # therefore be said once per loop budget rather than once per wake: a tick
      # wakes the same paused loop, and every wake would repeat the same sentence
      # into the parent conversation. A budget warning is the newest of them -- a
      # loop that stopped at nine tenths of its loop budget is paused, which is
      # exactly the status a tick is allowed to wake.
      ANNOUNCE_ONCE = %i[budget budget_warning].freeze
      # The model's cue that this arrived on its own, shaped like the one a
      # finished batch of delegated runs gets. "Kabar" rather than "hasil",
      # because not every ending is a result: a loop that broke or ran out of
      # budget arrives through the same door.
      LOOP_REPORT_LABEL = "Kabar dari loop yang kamu jalankan:\n\n"
      # How long a report waits for the reader's own turn to end before it gives
      # up and draws anyway. Bounded: a turn that never ends must not become a
      # thread that never ends either.
      TURN_WAIT_SECONDS = 300

      # What the loop tool holds. The tool speaks a tool's language -- start,
      # resume, abort, and a plain string back -- while LoopRunner speaks the
      # run's, so this is the seam and the only object the tool ever sees.
      class SessionRunner
        attr_reader :base

        def initialize(base:, store:, session_runner:, logger: nil, async: true, on_finish: nil,
                       on_change: nil)
          @base = base
          @store = store
          @async = async
          @logger = logger
          # Where the run's ending goes. A loop outlives the turn that started
          # it, so a thread that has nobody reading it is the one place left to
          # say where the loop got; the channel closes its session id into this.
          @on_finish = on_finish
          # Where a run beginning or ending goes. The footer's panel draws only
          # what is running, so both moments change whether it is on the page at
          # all -- and a reader who had to reload to see the toggle would not
          # call that watching a loop.
          @on_change = on_change
          # One run per loop at a time. Two runs on one id share a worktree, an
          # iteration number and a session file, and a session's token total
          # already contains the other run's spend, so the same budget would be
          # charged twice and both would commit into one index.
          @running = {}
          @threads = []
          @mutex = Mutex.new
          @runner = LoopRunner.new(
            store: store,
            worktree_root: File.join(base, WORKTREES_DIR),
            session_runner: session_runner,
            logger: logger,
            # This is production: the brake has to reach the turn, and a runner
            # that cannot take the budget keywords is a bug worth stopping for
            # rather than a loop that runs with nothing able to stop it.
            budget: true
          )
        end

        # A run lasts as long as its iterations do, and the caller is a tool
        # call inside someone's turn: answering now and working on a thread is
        # what keeps the conversation usable while the loop works.
        def start(id) = launch(:start, id)

        # A wake is not always a run. A loop that stopped for its budget is
        # paused, which is exactly what a schedule and a resume are allowed to
        # wake, and nothing outside the loop's own file can raise that budget:
        # waking it would buy a turn or a boundary stop, say so to the
        # conversation, and do it again on the next tick. The refusal is the
        # honest answer, and it is recorded once rather than once per wake.
        def resume(id)
          refusal = @runner.spent_refusal(id)
          return "OK: loop #{id} stays paused: #{refusal}" if refusal

          launch(:resume, id)
        end

        # The claim, in public for one caller. A `loop` tool call spoken inside
        # a Ractor reaches the channel as plain data, so the channel is what
        # has to take the claim, before it hands the run on: taken there, a
        # second request for an id already running can say so once instead of
        # queueing a run that would work the same worktree. It is the same
        # claim #start takes, so one id still means one run.
        def claim_start(id) = claim(id)

        # The claimed run, on a thread of its own: exactly what #start does once
        # the claim is in, for a caller that has already made it.
        def run_claimed(op, id)
          spawn(op, id)
          "OK: loop #{id} is iterating on a thread of its own; ask for its status to see where it got"
        end

        # Whether the id names a loop file this runner can work. Asked before a
        # handed-off request goes near a thread: a run on an unknown id would
        # only answer :missing inside it, where nobody is reading.
        def known?(id)
          !@store.load(id).nil?
        rescue LoopStore::Corrupt
          true # an unreadable file is the run's own problem to report, not this one
        end

        # A pause is not a signal to a thread: the run re-reads the loop's
        # status at the top of every iteration, so writing it is what stops the
        # loop -- after the iteration in flight, never in the middle of one.
        def abort(id)
          @store.update(id) { |loop| loop.status = "paused" if loop.status.to_s == "active" }
          notify_change
          "OK: loop #{id} stops after the iteration in flight, which is still paid for"
        rescue LoopStore::Corrupt
          raise
        rescue StandardError => e
          # A pause that did not reach the file leaves the loop running, so it
          # is not an OK: the reader would stop watching a loop still spending.
          "ERROR: loop #{id} could not be paused: #{e.message}"
        end

        # Waited on before the pool shuts down: a thread that wakes up after it
        # builds a new actor against a stopped store, and one killed mid-commit
        # leaves an index.lock that the next run trips over.
        def join(timeout = 5)
          threads = @mutex.synchronize { @threads.dup }
          deadline = Time.now + timeout
          threads.each do |thread|
            left = deadline - Time.now
            break if left <= 0

            thread.join(left)
          end
          threads.size
        end

        def running?(id)
          @mutex.synchronize { @running.key?(id) }
        end

        private

        def launch(op, id)
          return run_now(op, id) unless @async
          return "OK: loop #{id} is already iterating; ask for its status to see where it got" unless claim_start(id)

          run_claimed(op, id)
        end

        # The run itself, claimed already. Everything that outlives the caller
        # is here: the thread, the failure note it has nobody else to tell, the
        # release of the id when it lands, and the report of where it got.
        def spawn(op, id)
          thread = Thread.new do
            Thread.current.report_on_exception = false
            outcome = nil
            begin
              outcome = @runner.public_send(op, id)
            rescue StandardError => e
              # Nobody is reading a thread: the caller was answered with a
              # promise, so the only place to leave a trace is the loop's own
              # file. A warning on stderr is not a trace a reader will find. A
              # run that broke before it could name a reason is announced as
              # one, in the shape the announcement reads.
              note_failure(id, e)
              outcome = failure_result(id, e)
            ensure
              # Released before the report: the run is over, and the report is a
              # turn in the conversation rather than part of the loop. A resume
              # asked for while it is being written must not be told the id is
              # still busy.
              @mutex.synchronize { @running.delete(id) }
            end
            announce(id, outcome)
          end

          @mutex.synchronize { @threads << thread }
          notify_change
          thread
        end

        def claim(id)
          @mutex.synchronize do
            return false if @running.key?(id)

            @running[id] = true
          end
        end

        def note_failure(id, error)
          text = "run failed: #{error.class}: #{error.message}"
          @logger&.call("loop #{id}: #{text}")
          @store.append_log(id, text)
        rescue StandardError
          nil
        end

        # A run outlives the turn that started it, so without this the reader
        # learns where it got only by asking for `status` -- or never. This is
        # the one moment the channel can speak unprompted, so it is where the
        # report hangs.
        #
        # Nothing here may escape: a report is a provider request in another
        # conversation, and a loop that finished cannot be undone by one that
        # failed to say so. The loop's file is left exactly as the run wrote it.
        def announce(id, outcome)
          notify_change
          @on_finish&.call(id, outcome)
        rescue StandardError => e
          @logger&.call("loop #{id}: could not be reported: #{e.class}: #{e.message}")
        end

        # The footer's panel is drawn from the state file, so a run that begins
        # or ends changes whether it belongs on the page at all. Saying so here
        # rather than from the turn is what makes the toggle appear while the
        # turn that started the loop is still being read.
        #
        # Nothing escapes: a panel that did not redraw is a stale icon, and a
        # loop that is already on its own thread must not be broken by one.
        def notify_change
          @on_change&.call
          true
        rescue StandardError => e
          @logger&.call("loop: could not redraw the panel: #{e.class}: #{e.message}")
          false
        end

        # An exception is a run that broke before it could answer with a reason,
        # so it is turned into the shape the announcement reads. The counters are
        # the file's: #note_failure has already written what is known of them.
        def failure_result(id, error)
          state = begin
            @store.load(id)
          rescue StandardError
            nil
          end

          LoopRun::Result.new(
            state: state,
            stop_reason: :error,
            iterations_run: state ? state.iterations.to_i : 0,
            message: "#{error.class}: #{error.message}"
          )
        end

        # The synchronous shape a test drives: the same call, answered with the
        # run's own reason instead of a promise.
        def run_now(op, id)
          outcome = @runner.public_send(op, id)
          "OK: loop #{id} stopped: #{outcome.stop_reason}"
        rescue LoopStore::Corrupt => e
          "ERROR: #{e.message}"
        end
      end

      # What a `:loop` event asks for. The tool spoke inside the session Ractor,
      # where no runner can be handed to it, so the agent called its `on_loop`
      # callback with plain data and this is where that data is worked: the same
      # runner methods the local path calls, in the conversation's own runner,
      # so the iterations answer as its persona and the state file sits under
      # the same root the tool reads.
      #
      # Nothing waits, and nothing raises: a request names a loop that is gone,
      # or one that is already iterating, and both are one line in the log
      # rather than a turn that fails on work it delegated.
      def handle_loop_request(sid, request)
        data = request.to_h
        op = data[:op].to_s.to_sym
        id = data[:id].to_s
        # The parent conversation is what the request names; the turn carrying
        # the event is the same one, and only a fallback.
        parent = data[:parent_session].to_s
        parent = sid.to_s if parent.empty?

        unless LOOP_OPS.include?(op)
          return warn_loop_request(id, "operation #{data[:op].inspect} is not one a channel works")
        end
        return warn_loop_request(id, "the request names no loop") if id.empty?

        base = workspace_for_session(parent).to_s
        return warn_loop_request(id, "no workspace is known for #{parent}") if base.empty?

        runner = loop_runner_for(parent, base)
        warn_loop_persona(id, data[:slug].to_s, owner_slug(parent) || default_slug)

        return warn_loop_request(id, "no loop with that id") unless runner.known?(id)

        # A pause is one file write: the run re-reads the status at the top of
        # every iteration, so there is nothing to hand to a thread.
        if op == :abort
          runner.abort(id)
          return true
        end

        # The claim is what makes a second request harmless, and it is the same
        # claim a tool call takes: one id, one run, whatever started it.
        unless runner.claim_start(id)
          return warn_loop_request(id, "already iterating; the second request starts nothing")
        end

        runner.run_claimed(op, id)
        true
      rescue StandardError => e
        warn_loop_request(id, "#{e.class}: #{e.message}")
        false
      end

      private

      # Bound with the other tool contexts before a turn starts (see
      # #prepare_delivery). The runner belongs to the conversation rather than to
      # the tool, because two conversations may work on two loops at once and
      # each one's iterations answer as its own persona.
      def bind_loop_runner(sid)
        tool = session_for(sid).tools.get("loop")
        return unless tool

        base = workspace_for_session(sid).to_s
        return if base.empty?

        # In actor mode the channel holds a ToolProxy, which can only forward a
        # call: the runner is a lambda and a lambda does not cross a Ractor
        # boundary. Binding is a no-op there, so the tool asks the agent
        # instead and the request comes back as a `:loop` event
        # (see #handle_loop_request). Raising NoMethodError in the middle of
        # every turn is what an unguarded setter did.
        return unless tool.respond_to?(:loop_runner=)

        tool.workspace = base
        tool.loop_runner = loop_runner_for(sid, base)
      end

      # Named so a test can drive the seam without send: binding is a step a turn
      # performs, and one iteration is one turn. Both are what a channel hands
      # the loop tool, so both are what a test has to be able to see.
      def loop_runner_for(sid, base)
        @loop_runners ||= {}
        @loop_runner_mutex ||= Mutex.new
        key = [ sid, base ]
        # WEBrick answers turns on threads of its own, so two of them can bind
        # the same conversation at once: unsynchronised, each builds its own
        # SessionRunner and two stores end up writing one directory.
        @loop_runner_mutex.synchronize do
          @loop_runners[key] ||= SessionRunner.new(
            base: base,
            store: LoopStore.new(dir: File.join(base, LOOPS_DIR)),
            session_runner: loop_session_runner(sid),
            logger: ->(text) { warn "[loop] #{text}" },
            # The conversation is closed into the report rather than handed to
            # the runner as an argument: a run reports where it was created, and
            # that is fixed the moment the tool is bound.
            on_finish: ->(id, outcome) { report_loop_finished(sid, id, outcome) },
            # The panel draws only what is running, so a run beginning or
            # ending is a fact its page has to hear about: the toggle it never
            # drew is the one a reader would have to reload to find.
            on_change: -> { push_loop_sheet(sid) }
          )
        end
      end

      # What the conversation is told when a run ends: a background turn in the
      # session that opened the loop, so the agent says it in its own words and
      # the message is archived like any other -- a report a reader cannot
      # scroll back to is one they have to ask for again.
      #
      # Not every ending deserves a turn (see ANNOUNCED_STOPS), and none of them
      # may cost the loop anything: a failure here is the runner's to log, which
      # is why nothing is rescued on this side.
      def report_loop_finished(sid, id, outcome)
        reason = outcome.stop_reason.to_s.to_sym
        return unless ANNOUNCED_STOPS.include?(reason)
        return if ANNOUNCE_ONCE.include?(reason) && !announce_budget?(id, outcome.state)

        wait_for_quiet_turn(sid)
        prepare_delivery(sid)
        deliver_report(sid, text: loop_report_text(id, outcome), label: LOOP_REPORT_LABEL)
      end

      # A stop the schedule can repeat is the one a reader has to be spared from
      # hearing twice: a tick wakes the same spent or warned loop, and every wake
      # would say the same sentence into the parent conversation. Once per
      # allowance is news; the second copy is the reason a reader stops reading
      # them. A bigger allowance -- a raised limit is the only way to get one --
      # is a different fact, so meeting it again is worth saying. Both limits
      # are in the key: raising the iteration cap alone leaves `max_tokens`
      # untouched, and a loop that then meets its allowance again has news the
      # old key would have swallowed.
      def announce_budget?(id, state)
        key = [ id.to_s, state&.max_tokens.to_i, state&.max_iterations.to_i ]
        @announced_budget ||= {}
        @announced_budget_mutex ||= Mutex.new
        @announced_budget_mutex.synchronize do
          return false if @announced_budget.key?(key)

          @announced_budget[key] = true
        end
      end

      # The reader's own turn comes first. A block opened while it is running
      # would land above an answer still being written, and only a reload would
      # put the two back in the archive's order — the same reason a delegated
      # batch is not reported into a live turn (see Subagents#claim_subagent_results).
      def wait_for_quiet_turn(sid)
        deadline = Time.now + TURN_WAIT_SECONDS
        sleep 0.5 while live_turn(sid) && Time.now < deadline
      end

      # What the conversation is told. It carries the facts a reader would
      # otherwise ask `status` for, and the stop reason both as the runner's own
      # word -- which a resume, an undo and the file all use -- and in plain
      # words, because `done_by_verifier` is not a sentence.
      def loop_report_text(id, outcome)
        state = outcome.state
        lines = [ "## loop #{id}" ]
        goal = state&.goal.to_s.strip
        lines << "Tujuan: #{goal}" unless goal.empty?
        lines << "Yang terjadi: #{loop_stop_phrase(outcome.stop_reason)}"
        lines << "Alasan berhenti: #{outcome.stop_reason}"
        lines << "Iterasi: #{outcome.iterations_run}"
        if state
          lines << "Token terpakai: #{state.tokens.to_i} dari #{state.max_tokens.to_i}"
          branch = state.branch.to_s.strip
          lines << "Branch: #{branch}" unless branch.empty?
          worktree = state.worktree.to_s.strip
          lines << "Worktree: #{worktree}" unless worktree.empty?
        end

        message = outcome.message.to_s.strip
        lines.push("", message) unless message.empty?
        # A budget warning is the one ending that leaves a decision to the
        # reader, so its answer says what can be done about the work still
        # sitting there -- in the same answer, because a report that names a
        # stop and no next step is one they have to come back and ask about.
        if state && outcome.stop_reason.to_s.to_sym == :budget_warning
          lines.push("", warning_answer(id, state))
        end
        lines.join("\n").rstrip
      end

      # What a budget warning leaves the reader to decide: how much of the loop
      # budget went, that the last iteration is an unverified iteration rather
      # than unfinished work, and which of the three ways out this state actually
      # allows. Keep, drop and raise all act on the commit the warning left
      # behind -- dropping it is `loop undo`, which takes the branch back one
      # commit -- so a loop whose warning iteration committed nothing has nothing
      # to keep or drop, and offering the choice there would offer a button that
      # drops work the reader never meant to lose. Every option named here is an
      # operation the loop tool already has (see Tools::Loop::OPERATIONS).
      def warning_answer(id, state)
        lines = [ I18n.t("web.loops.warning.spend", spent: state.tokens.to_i, limit: state.max_tokens.to_i) ]
        options = if warning_work_waiting?(state)
          [ I18n.t("web.loops.warning.keep"),
            I18n.t("web.loops.warning.drop", id: id),
            I18n.t("web.loops.warning.raise") ]
        else
          [ I18n.t("web.loops.warning.raise_only") ]
        end
        options.each { |option| lines << "- #{option}" }
        lines.join("\n")
      end

      # Whether the warning left work nobody has judged: its iteration committed,
      # and that commit's subject carries the marker that says no verdict was
      # bought for it. Asked of the branch and not of the worktree's status,
      # because the work is committed by the time the choice is offered and the
      # worktree is clean again -- the commit is what `undo` would drop. A
      # worktree that cannot answer, or a file that records none, says no: a
      # choice missing is better than a choice that destroys judged work.
      def warning_work_waiting?(state)
        path = state&.worktree.to_s
        return false if path.empty? || state&.repo.to_s.empty?

        worktree = LoopWorktree.new(root: File.dirname(path), repo: state.repo)
        worktree.head_subject(state.id).to_s.start_with?(LoopRun::UNVERIFIED_MARKER)
      rescue LoopWorktree::Error, SystemCallError
        false
      end

      # One turn of one iteration, in the loop's worktree. The session is a
      # throwaway: it gets an id of its own per iteration, it is not a
      # conversation the roster lists, and nothing in it is marked unread --
      # a loop's sessions are not places a reader can open.
      #
      # The budget is enforced here because this is the only place that can.
      # `usage.total_tokens` is everything the turn has been charged so far, and
      # a request re-sends the whole conversation, so one turn of one iteration
      # can spend several million tokens. Waiting for the turn to end and then
      # charging it -- which is what the run does with whatever a runner reports
      # -- made the budget a report on money already spent. Here each report is
      # debited as it arrives and the turn is cancelled the moment the loop's
      # budget is reached.
      def loop_session_runner(sid)
        slug = owner_slug(sid) || default_slug
        ledger = loop_ledger(sid)

        lambda do |session_id:, prompt:, workspace:, id: nil, budget: nil, spent: nil|
          handle = @pool&.delegate(parent_session: "loop", slug: slug, run_id: session_id,
                                   workspace: workspace, session_id: session_id)
          # Two different causes reach this branch, and the log is the only
          # place a reader can tell them apart later.
          raise "no session pool is running and no persona '#{slug}' is known, so the loop cannot reach an agent" unless handle

          # Three numbers, and they are not the same number.
          #
          # `seen` is the last report as the provider sent it, estimate and all:
          # that is what the brake reads, because stopping late costs a whole
          # turn. `measured` is the last figure the provider actually charged
          # for -- a report without `provisional` -- and `paid` is how much of it
          # is already on the loop's file. Only measured usage is ever debited:
          # the estimate in `seen` describes a request that has not come back,
          # so billing it bills a guess, and when the real figure lands lower
          # there is nothing to give back.
          paid = 0
          measured = 0
          seen = 0
          stopped = false
          stop_failures = 0
          # What the turn's requests looked like, from the reports that
          # measured them. It travels back with the answer so the loop's own
          # entry can say it (see #note_request_shape).
          shape = {}

          on_usage = lambda do |report|
            seen = usage_field(report, :total_tokens).to_i
            note_request_shape(shape, report) unless provisional?(report)
            # A caller that knows no budget keeps the old answer and charges it
            # itself, which is what every caller written before this did.
            next if budget.nil?

            measured = [ measured, seen ].max unless provisional?(report)
            # A debit that did not land must not advance `paid`: the difference
            # between what was reported and what was written is owed again by
            # the next report, or named as unwritten at the end of the turn.
            paid = measured if measured > paid && debit(ledger, id, measured - paid)

            next if stopped || spent.to_i + seen < budget.to_i

            # A cancellation that did not land is not a stop: the turn is still
            # running and still spending, so it is asked again on the next
            # report, and the first failure is said where the loop is read.
            if handle.cancel!
              stopped = true
            else
              record_stop_failed(ledger, id) if stop_failures.zero?
              stop_failures += 1
            end
          end

          text = ""
          begin
            text = handle.process(prompt, stream: false, on_usage: on_usage)
          rescue StandardError
            # The cancellation this turn asked for comes back as an exception
            # from the turn that was still running. That is the stop working,
            # not a failure to report: what stopped the loop is its budget. A
            # turn whose stop never landed is a real failure and travels.
            raise unless stopped
          ensure
            # The iteration is over, so its actor has nothing left to do.
            @pool&.invalidate(session_id)
          end
          # A stopped turn hands back the agent's own notice ("Stopped by
          # user"), not an answer: what stopped it is the budget, and the notice
          # must not become the loop's log entry or the commit's subject.
          text = "" if stopped

          # The iteration's own ceilings, when it reached one. The agent is the
          # only side that knows them, and the run is the only side with the log
          # to write them into, so they ride back with the answer. Two of them,
          # because an iteration stops either when it has had its rounds or when
          # its context has grown past what is worth sending again.
          cap = handle.last_round_cap if handle.respond_to?(:last_round_cap)
          ceiling = handle.last_context_ceiling if handle.respond_to?(:last_context_ceiling)

          # Zero back to a caller that knows the budget: this turn has already
          # paid every token it reported, and a total charged a second time by
          # the run is one turn billed twice.
          if budget.nil?
            report = { text: text.to_s, tokens: seen }
            report[:round_cap] = cap if cap
            report[:context_ceiling] = ceiling if ceiling
            next with_shape(report, shape)
          end

          owed = outstanding(ledger, id, measured, paid)
          report = with_shape({ text: text.to_s, tokens: 0, spent: measured, budget_stopped: stopped }, shape)
          report[:round_cap] = cap if cap
          report[:context_ceiling] = ceiling if ceiling
          report[:unwritten] = owed if owed.positive?
          report
        end
      end

      # The metrics ride only when something was measured: a turn whose reports
      # said nothing leaves the answer exactly as it was, and the loop's entry
      # then carries no request part at all rather than a made-up zero.
      def with_shape(report, shape)
        report[:metrics] = shape.dup unless shape.empty?
        report
      end

      # The shape of the turn's requests, folded from the reports that measured
      # them: how many requests it made, how big the context was at the first
      # and the last of them, and the cache share of the latest. This is what
      # tells a reader whether an iteration is expensive because the work is or
      # because every request re-sends a conversation that grew. Only measured
      # reports reach here; an estimate of a request that has not come back is
      # not a figure to write down.
      def note_request_shape(shape, report)
        requests = usage_field(report, :requests).to_i
        shape[:requests] = requests if requests.positive?
        # The prompt of the latest measured request: the first one seen is the
        # turn's opening context, the last is what the final request carried.
        prompt = usage_field(report, :last_prompt_tokens).to_i
        if prompt.positive?
          shape[:context_first] ||= prompt
          shape[:context_last] = prompt
        end
        cache = usage_field(report, :cache_hit_rate)
        shape[:cache_hit_rate] = cache.to_f unless cache.nil?
        shape
      end

      # What the store is still owed, after one last attempt at the end of the
      # turn. A debit that never landed is money the provider billed and the
      # loop's file never heard of, so it is not swallowed: it travels back with
      # the turn's report, where the run writes it into the log.
      def outstanding(ledger, id, measured, paid)
        owed = [ measured - paid, 0 ].max
        return 0 if owed.zero?
        return 0 if debit(ledger, id, owed)

        owed
      end

      # A usage report may arrive under symbol or string keys, and the one
      # spelling is the one the channel's own accounting uses.
      def usage_field(report, key)
        value = report[key]
        value.nil? ? report[key.to_s] : value
      end

      # A report is provisional while it carries the estimate of a request that
      # has not returned (see UsageAccounting#report). Its absence and its
      # falsehood mean the same thing: this figure is the provider's.
      def provisional?(report) = truthy_usage?(usage_field(report, :provisional))

      def truthy_usage?(value) = value == true || value == "true"

      # A stop the turn never received, said where a loop is read: the turn is
      # still spending, so what it spends lands on the file after all and the
      # run ends the iteration at its budget boundary instead.
      def record_stop_failed(ledger, id)
        return unless ledger && id

        ledger.append_log(id, "budget stop did not reach the turn: it could not be stopped, " \
                              "so it runs to its end and the loop stops at the iteration boundary")
      rescue StandardError => e
        warn "[loop] #{id}: could not record a stop that did not land: #{e.message}"
      end

      # What a turn is spending, written the moment it is known. A loop's tokens
      # are its budget, so a debit that never lands is money spent that nothing
      # notices; `update` is the store's own charge path, the one the run uses
      # for a whole iteration, so the two cannot disagree about the total.
      #
      # Answers whether the write landed, because a caller that bills in deltas
      # may only advance its own counter on a true.
      def debit(ledger, id, tokens)
        return false unless ledger && id && tokens.positive?

        ledger.update(id) { |loop| loop.tokens = loop.tokens.to_i + tokens }
        true
      rescue StandardError => e
        # A file that cannot be written is the turn's to report in its answer and
        # the run's to write down, never a reason to lose the turn still arriving.
        warn "[loop] #{id}: could not debit #{tokens} tokens: #{e.message}"
        false
      end

      # The store a turn pays into: the same directory the run counts, reached
      # the way #loop_runner_for reaches it, so a debit during a turn and the
      # budget read at an iteration boundary are the same file. nil when the
      # channel knows no workspace, because then there is nothing to pay into.
      def loop_ledger(sid)
        base = workspace_for_session(sid).to_s
        return nil if base.empty?

        LoopStore.new(dir: File.join(base, LOOPS_DIR))
      end

      # -- the footer's panel ---------------------------------------------------

      # The loops the footer's sheet draws: every loop of this conversation's
      # workspace that is being worked right now, newest update first. Read from
      # the same store a running turn pays into (see #loop_ledger), so the
      # budget printed in the row and the budget the brake reads are one number
      # rather than two that happen to agree today.
      def loop_rows(sid)
        ledger = loop_ledger(sid)
        return [] if ledger.nil?

        ledger.ids.filter_map do |id|
          state = begin
            ledger.load(id)
          rescue LoopStore::Corrupt
            # A file that cannot be read back is not a loop the panel can
            # describe. The tool is where a reader hears about it, and a row
            # whose numbers were guessed would be worse than no row at all.
            nil
          end
          next nil unless state && state.status.to_s == LOOP_PANEL_STATUS

          loop_row(state)
        end.sort_by { |row| -row[:age_seconds] }
      end

      # One row of it. Everything the panel shows is decided here, in numbers
      # and words the template only has to place: a row is never half-assembled
      # in ERB, so the page and the poll cannot word the same loop differently.
      #
      # Two figures and a name. What a loop has spent is the same fact as what
      # is left of it, and the rest -- the id, the status word, the clock -- was
      # the panel repeating the reader's own question back at them.
      def loop_row(state)
        max_tokens = state.max_tokens.to_i
        used = state.tokens.to_i
        updated = state.updated_at
        {
          goal: LoopStore.one_line(state.goal),
          iterations: state.iterations.to_i,
          max_iterations: state.max_iterations.to_i,
          max_tokens: max_tokens,
          # Never negative: the turn that crosses the line can be charged past
          # the budget, and "-12,000 left" is not a figure a reader should have
          # to reason about at the end of a long day.
          remaining: [ max_tokens - used, 0 ].max,
          # Not drawn: this is what orders the cards, so the loop that moved last
          # is the one at the top.
          age_seconds: updated ? [ (Time.now - updated.to_time).to_i, 0 ].max : 0
        }
      end

      # The rows on their own, for the poll the sheet makes while it is open:
      # the same partial the page drew, so the panel and the answer to its poll
      # can never disagree about a loop.
      def loop_rows_markup(sid, rows = loop_rows(sid)) = View.render("_loop_rows", loops: rows)

      # The sheet whole, drawn for a page that is already open. A loop
      # beginning or ending changes whether the toggle exists at all, and a
      # reader who had to reload to find the panel watching their loop would not
      # call that live. Marked out of band because it travels on the idle
      # stream, where there is no request of its own to answer.
      def loop_sheet_markup(sid, rows = loop_rows(sid))
        # Outside the channel there is no token to carry; a page drawn by a test
        # still has to render.
        query = respond_to?(:token_query) ? token_query.to_s : ""
        markup = View.render("_loop_sheet", loops: rows, session_id: sid, token_query: query)
        markup.sub(%(<details class="usage-sheet usage-sheet-loops" id="loop-sheet"),
                   %(<details class="usage-sheet usage-sheet-loops" id="loop-sheet" hx-swap-oob="true"))
      end

      # Only the rows, for the case where the panel's own existence has not
      # changed: replacing the whole sheet would close an open panel under the
      # reader's cursor, and a second loop starting is no reason to lose their
      # place in the first.
      def loop_body_markup(sid, rows = loop_rows(sid))
        %(<div id="loop-sheet-body" hx-swap-oob="innerHTML">#{loop_rows_markup(sid, rows)}</div>)
      end

      # Told to the conversation's open pages, if it has any: with none open
      # this is one read of the state file and nothing else, and the page that
      # opens next draws the same rows from the same place.
      def push_loop_sheet(sid)
        return if sid.to_s.empty?

        rows = loop_rows(sid)
        remember = remember_loop_sheet(sid, rows.empty?)
        markup = remember ? loop_sheet_markup(sid, rows) : loop_body_markup(sid, rows)
        push_to_session(sid, :"loop-sheet", markup)
      rescue StandardError => e
        # A stale icon, never a broken loop: the run is on a thread of its own
        # and its file is already written.
        warn "[loop] #{sid}: could not redraw the panel: #{e.class}: #{e.message}"
      end

      # Whether the toggle should be on the page right now, as of the last thing
      # this channel said. Unsynced, a turn's thread and a loop's own thread are
      # both allowed here, and the panel would be redrawn whole every time.
      def remember_loop_sheet(sid, hidden)
        @loop_sheet_states ||= {}
        @loop_sheet_lock ||= Mutex.new
        @loop_sheet_lock.synchronize do
          changed = !@loop_sheet_states.key?(sid) || @loop_sheet_states[sid] != hidden
          @loop_sheet_states[sid] = hidden
          changed
        end
      end

      # Called from the channel's stop path, before the pool goes down.
      def stop_loop_threads(timeout: 5)
        runners = @loop_runners ? @loop_runners.values : []
        runners.each { |runner| runner.join(timeout) }
        runners.size
      end

      # One line, one place: a request that could not be worked is never an
      # exception, because it arrived from a turn that has already been
      # answered.
      def warn_loop_request(id, reason)
        warn "[loop] #{id.to_s.empty? ? 'request' : id}: #{reason}"
        false
      end

      # Iterations answer as the conversation's persona, which was fixed when
      # its runner was built. A request naming another one is worth a line: the
      # loop would otherwise work as an agent the reader did not choose.
      def warn_loop_persona(id, asked, iterating_as)
        return if asked.empty? || asked == iterating_as

        warn "[loop] #{id}: asked for persona #{asked}, iterating as #{iterating_as}"
      end

      # Plain words for the run's own vocabulary: the reader asked what became
      # of their goal, not for the symbol that ended it. The warning's sentence
      # comes from the dictionary like the rest of the offer below it, because it
      # is the half of this report a reader has to act on.
      def loop_stop_phrase(reason)
        case reason.to_sym
        when :done_by_verifier then "kriteria yang kamu tetapkan sudah terpenuhi"
        when :stalled then "tidak ada kemajuan baru, jadi iterasi lagi hanya akan membakar token"
        when :budget then "jatah token untuk loop ini habis"
        when :budget_warning then I18n.t("web.loops.warning.phrase")
        when :context_ceiling then "satu iterasinya sudah mencapai plafon konteks, jadi request berikutnya cuma akan mengirim ulang transkrip yang sama"
        when :max_iterations then "batas iterasinya tercapai sebelum kriterianya terpenuhi"
        when :verifier_stuck then "verifier terus menolak dengan alasan yang sama, jadi iterasi lagi tidak mengubah apa pun"
        when :worktree_error, :worktree_missing then "worktree-nya bermasalah, jadi iterasinya tidak bisa jalan"
        else "loop berhenti karena gagal"
        end
      end

      # Named so a test can drive the seam without send: binding is a step a turn
      # performs, and one iteration is one turn. Both are what a channel hands
      # the loop tool, so both are what a test has to be able to see. The report
      # is a seam for the same reason: what a finished run says to its
      # conversation is a fact about the channel, not about the thread that ran
      # it.
      public :bind_loop_runner, :loop_session_runner, :stop_loop_threads,
             :report_loop_finished, :loop_report_text,
             # What the footer's panel draws, and the rows the poll answers
             # with. Both are seams for the same reason: a test that checks the
             # panel against real state files has to be able to ask what the
             # channel would have drawn, and a route answers with exactly these
             # rows. Only these two: how one row is built stays private.
             :loop_rows, :loop_rows_markup,
             # The panel redrawn for a page that is already open. Public for the
             # same reason: what a loop beginning does to the footer is a fact
             # about the channel, and the test can only see it if the push is
             # callable.
             :loop_sheet_markup, :loop_body_markup, :push_loop_sheet
    end
  end
end
