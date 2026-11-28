# frozen_string_literal: true

require_relative "reports"

module Rubot
  module Web
    # Delegated work: the run a turn hands off, the sheet the footer draws while
    # it works, and the batch of answers handed back when it lands.
    #
    # A delegated run outlives the turn that asked for it, so nothing about it
    # can live in the turn. Its state is kept in SubagentJobs, which is what the
    # footer draws; its answer goes to the archive, where the model picks it up —
    # either because it asked with `subagent_results`, or because the last run of
    # a batch reports itself back (see #report_subagents_when_done).
    #
    # Included into the channel and left public on purpose: the event stream, the
    # page that opens beside a run and the tests all ask these questions
    # directly.
    module Subagents
      # The drawing of the report is not this module's: a loop reports itself the
      # same way, so it lives in Reports and this one only decides what a
      # finished batch says.
      include Rubot::Web::Reports

      # How many subagent answers one automatic report carries. A batch is
      # usually small; a long backlog is handed over in instalments rather than
      # as one wall of text, and only the runs actually quoted are marked read.
      SUBAGENT_REPORT_LIMIT = 5
      # How long one report may hold a conversation before its claim is treated
      # as abandoned. Long enough for a report turn that reads a file or two,
      # short enough that a thread which died does not silence the conversation
      # for the rest of the process.
      REPORT_CLAIM_SECONDS = 600
      # A notification body is read on a lock screen, so a finished delegation
      # says no more than a turn note does. The number is the cron delivery's,
      # which is where most of it is spent.
      TURN_NOTIFY_CHARS = Rubot::Web::Routes::Cron::TURN_NOTIFY_CHARS

      # Rounds an acting report may take. Small on purpose: the turn answers one
      # batch, and the step it may carry on with — commit, push the branch, open
      # the pull request — has a shape already known, so the conversation's
      # ceiling of a thousand is not a budget for it.
      ACTING_REPORT_MAX_ROUNDS = 20
      # How long an acting report may hold the conversation, in seconds. The
      # number is paid outside this turn: a background turn holds the session's
      # actor, so a reader who types while it runs waits in the queue behind it.
      # Five minutes is enough for tests, a push and a forge round trip, and it
      # is the most a reader can be asked to wait for a report nobody typed.
      ACTING_REPORT_TIMEOUT_SECONDS = 300

      # The footer's subagent sheet, moved without a reload. A background run
      # has no turn to report into, so this is the only thing that tells an open
      # page it started, moved, or came back.
      #
      # Whether the sheet is in the row at all changes with the run: it appears
      # when a delegation starts and leaves once the finished mark has timed
      # out. Only that transition replaces the whole element — every other event
      # rewrites the slots inside it, so an open panel is not closed by its own
      # progress.
      def broadcast_subagents(sid)
        runs = @subagent_jobs.runs(sid)
        visible = Rubot::Web::SubagentJobs.visible?(runs)
        changed = @subagent_mutex.synchronize do
          previous = @subagent_visible[sid]
          @subagent_visible[sid] = visible
          previous != visible
        end

        markup = changed ? subagent_sheet_markup(runs) : subagent_slots_markup(runs)
        push_to_session(sid, :"subagent-sheet", markup)
      end

      # Close a run, and arm the footer's hiding with it.
      #
      # The hiding cannot wait for the next event: a finished batch produces no
      # more events, so the row would keep its tick until something unrelated
      # moved. Every finish re-arms, and only the last timer finds nothing
      # running when it wakes — three seconds later, per
      # SubagentJobs::DONE_MARK_SECONDS.
      def finish_subagent(sid, run_id, **state)
        @subagent_jobs.finish(session_id: sid, run_id: run_id, **state)
        hide_subagents_later(sid)
      end

      def hide_subagents_later(sid, after: Rubot::Web::SubagentJobs::DONE_MARK_SECONDS)
        token = @subagent_mutex.synchronize do
          @subagent_hide_token[sid] = @subagent_hide_token[sid].to_i + 1
        end

        Thread.new do
          Thread.current.report_on_exception = false
          sleep after
          hide_finished_subagents(sid, token: token)
        end
      end

      # The hiding itself: the sheet as the page should now show it, which is
      # nothing at all once the finished mark has had its time. Only the
      # transition is acted on — a page that was never told the row was there
      # has nothing to take back, and a timer that woke to a conversation where
      # something is running again is not the current one.
      def hide_finished_subagents(sid, token: nil)
        runs = @subagent_jobs.runs(sid)
        due = @subagent_mutex.synchronize do
          current = token.nil? || @subagent_hide_token[sid] == token
          current && @subagent_visible[sid] && !Rubot::Web::SubagentJobs.visible?(runs)
        end
        broadcast_subagents(sid) if due
      end

      # Hand a delegated run to an actor of its own and return at once.
      #
      # The parent turn is not held: the conversation can take the next prompt
      # while this works. State goes into @subagent_jobs, which is what the
      # footer draws and what survives the turn; the answer goes to the archive,
      # where `subagent_results` picks it up.
      def start_delegate(sid, request)
        run_id = request[:run_id].to_s
        slug = request[:agent].to_s
        task = request[:task].to_s
        return if run_id.empty?

        @subagent_jobs.start(session_id: sid, run_id: run_id, agent: slug, task: task)

        handle = @pool&.delegate(parent_session: sid, slug: slug, run_id: run_id, model: request[:model])
        unless handle
          finish_subagent(sid, run_id, status: "failed",
                          error: "persona #{slug} tidak dikenal")
          finish_delegate_run(run_id, status: "failed", error: "persona #{slug} tidak dikenal")
          report_subagents_later(sid)
          return
        end

        Thread.new do
          Thread.current.report_on_exception = false
          begin
            answer = handle.process(
              task,
              stream: false,
              # Only the phase moves: the reader is told the run is still
              # working, not which tool it reached for (see SubagentLine).
              on_tool_call: ->(_name, _args, _snapshot) {
                @subagent_jobs.update(session_id: sid, run_id: run_id, phase: "tool")
              }
            )
            finish_subagent(sid, run_id, status: "done", result: answer.to_s)
            finish_delegate_run(run_id, status: "done", sub_session: handle.session_id, result: answer.to_s)
            notify_delegate_end(sid, slug, status: "done", result: answer.to_s)
          rescue StandardError => e
            error = "#{e.class}: #{e.message}"
            finish_subagent(sid, run_id, status: "failed", error: error)
            finish_delegate_run(run_id, status: "failed", sub_session: handle.session_id, error: error)
            notify_delegate_end(sid, slug, status: "failed", error: error)
          ensure
            # The run is over, so its actor has nothing left to do. Dropping it
            # keeps a conversation that delegates often from holding one Ractor
            # per run until the process ends.
            @pool&.invalidate(handle.session_id)
            # Last one to land hands the whole batch back to the conversation
            # that asked for it (see #report_subagents_when_done).
            report_subagents_when_done(sid)
          end
        end
      end

      # The audit row the parent actor opened is closed here, because the run
      # outlived the actor that started it.
      def finish_delegate_run(run_id, status:, sub_session: nil, result: nil, error: nil)
        store = Rubot::Archive.current
        return unless store

        store.finish_subagent_run(run_id: run_id, status: status, sub_session: sub_session,
                                  error: error, result: result)
      rescue StandardError => e
        warn "[subagent] could not close run #{run_id}: #{e.class}: #{e.message}"
      end

      # A background run finishes after the turn that asked for it is over, so
      # there is nothing on screen waiting to be told. The lock screen is the one
      # place that can still reach a reader who walked away, so a finished
      # delegation rings: this is news they asked for, arriving when it is
      # ready, not a report on something they are already watching.
      def notify_delegate_end(sid, slug, status:, result: nil, error: nil)
        persona_slug = owner_slug(sid) || default_slug
        body = if status.to_s == "failed"
          "#{slug} gagal: #{error}"
        else
          line = result.to_s.lines.map(&:strip).reject(&:empty?).first
          line ? "#{slug}: #{line}" : "#{slug} selesai."
        end

        notify_push(persona_slug,
                    title: persona_title(persona_slug),
                    body: shorten(body, TURN_NOTIFY_CHARS),
                    url: session_url(sid))
      rescue StandardError => e
        warn "[web] subagent notification: #{e.class}: #{e.message}"
      end

      # Hand a finished batch back to the conversation that asked for it.
      #
      # Delegation is asynchronous, so the answer cannot be the return value of
      # the `delegate` call; waiting for the model to remember `subagent_results`
      # meant answers sat unread for hours. When the last run of a batch lands,
      # the conversation gets a turn of its own carrying what came back, and the
      # reader sees the agent react without having asked again.
      #
      # Only when nothing is still running: the batch is the unit, so three runs
      # finishing together produce one report, not three. Answers the model has
      # already pulled with `subagent_results` are not repeated — the store marks
      # what it handed over.
      #
      # `ticket` is the arm this report answered (see #report_later), handed on
      # only so the re-arm below can recognise the mark it finds as its own. A
      # report started any other way — the `ensure` of a delegate run, the
      # failed-persona path — passes nothing.
      def report_subagents_when_done(sid, ticket: nil)
        claim = claim_subagent_results(sid)
        return unless claim

        failed = false
        begin
          prepare_delivery(sid)
          deliver_subagent_report(sid, claim)
          # The answer is on the page from here on, so the redraw around it is
          # best effort: a session list that failed to render must not hand
          # answers that have already been shown back to the unread pile, where
          # the next report would say the same thing a second time.
          broadcast_after_report(sid)
        rescue StandardError => e
          failed = true
          warn "[subagent] could not report results: #{e.class}: #{e.message}"
          # Answers marked read and then lost are the one thing a background run
          # cannot come back from, so a report that failed hands them back — a
          # report that ran out of time included: it marks them read on the way
          # in exactly like a report that answers.
          release_report(sid, claim)
        ensure
          @subagent_mutex.synchronize { @subagent_reporting.delete(sid) }
          # The claim is gone, so this is the moment the pile is fair game again.
          # Nothing else asks: the only other arming is the end of a turn, and a
          # batch that landed from the `ensure` of a run while the conversation
          # sat idle would wait for the reader to happen to speak.
          #
          # `ticket` is what makes that ask possible from here: the mark this
          # thread left while it was on its way is still standing, and passing
          # the ticket in is how the arm below tells it from another thread's.
          #
          # A report that just failed is not re-armed from here. Its answers are
          # back in the pile, and retrying a provider that just failed in a loop
          # is worse than waiting for the next turn, which asks again anyway.
          #
          # A report that quoted a batch while naming what is still waiting does
          # not arm itself either: the instalments of a backlog were deferred on
          # purpose, with a line telling the model how to fetch the rest, and
          # turning that into another turn nobody asked for is how one long
          # backlog becomes a chain of report turns. What has to be armed is the
          # batch this report could not even see — it landed while the lock was
          # held, so it was skipped with nothing said about it at all.
          report_later(sid, mine: ticket) unless failed || claim[:more]
        end
      end

      # The page around a report that has already been drawn. Never raises: the
      # answers it sits beside are already marked read, and losing them to a
      # failed redraw is worse than a stale sidebar.
      def broadcast_after_report(sid)
        broadcast_sessions
        broadcast_usage(sid)
      rescue StandardError => e
        warn "[subagent] could not redraw after a report: #{e.class}: #{e.message}"
      end

      # Best effort, and never a second failure: the pile is for the next
      # attempt, not for this one.
      def release_report(sid, claim)
        store = Rubot::Archive.current
        return unless store

        store.release_subagent_results(Array(claim[:results]).map { |run| run[:run_id] })
      rescue StandardError => e
        warn "[subagent] could not release results: #{e.class}: #{e.message}"
      end

      # The report a finished batch becomes: what came back, handed to the shared
      # delivery (see Reports#deliver_report). Only the text belongs here.
      #
      # This is the one report that acts. The turn is given the toolset and a
      # handful of rounds, so it can carry on with what the reader already asked
      # for in this conversation — "kalau reviewer bilang aman, langsung commit
      # dan buat PR" — instead of only describing it. Nothing here decides
      # whether that request exists: no verdict is parsed and no switch is read,
      # because the reader's own words are in the transcript and the model is the
      # one reading them. Without a request like that it says what came back and
      # changes nothing (see Reports::REPORT_ACT_INSTRUCTION).
      def deliver_subagent_report(sid, claim)
        text = subagent_report_text(claim[:results], more: claim[:more])
        label = "Hasil subagent yang sudah selesai, dari kerja yang kamu delegasikan:\n\n"

        deliver_report(sid, text: text, label: label, act: true,
                       max_rounds: ACTING_REPORT_MAX_ROUNDS,
                       timeout: ACTING_REPORT_TIMEOUT_SECONDS)
      end

      # The report runs a turn of its own, so it must never hold the caller: a
      # delegation that failed on the way in still has to return at once, and
      # that path is the turn's own thread.
      def report_subagents_later(sid)
        Thread.new do
          Thread.current.report_on_exception = false
          report_subagents_when_done(sid)
        end
      end

      # Takes the claim and reads the answers under one lock, so two runs
      # finishing in the same breath cannot both decide they were the last one.
      #
      # Newest first: the batch that just landed is the news, and a backlog
      # waiting behind it must not push it into the next report. One row more
      # than will be quoted is read, which is how the report knows to say that
      # something is still waiting.
      def claim_subagent_results(sid)
        @subagent_mutex.synchronize do
          # A claim is a timestamp, not a flag: if the report thread dies without
          # its ensure (a hung provider read), a permanent "in progress" would
          # block every later report for this conversation. Past the window the
          # claim is worthless and the pile is taken again.
          claimed_at = @subagent_reporting[sid]
          next nil if claimed_at && (Time.now - claimed_at) < REPORT_CLAIM_SECONDS
          next nil unless @running
          # A report turn is queued behind whatever the actor is doing, and a
          # turn of the reader's own can take minutes. Waiting inside that queue
          # is not the report hanging, so it is never started from here: the end
          # of a turn asks again (see Web#report_later).
          next nil if live_turn(sid)
          next nil if @subagent_jobs.running_count(sid).positive?
          # One report turn at a time per conversation, and a report may now
          # act: it can hold the actor for minutes (see
          # ACTING_REPORT_TIMEOUT_SECONDS). Claiming these answers while one is
          # still running would only queue a second turn behind it — the reader
          # waiting again for the same silence — so the pile is left where it is.
          # The report that holds the lock asks again the moment it lets go
          # (see #report_subagents_when_done); waiting for a turn to end instead
          # meant a batch that landed with nobody typing stayed unread.
          next nil if report_in_flight?(sid)

          store = Rubot::Archive.current
          next nil unless store

          pending = store.pending_subagent_results(sid, limit: SUBAGENT_REPORT_LIMIT + 1,
                                                   newest_first: true)
          next nil if pending.empty?

          results = pending.first(SUBAGENT_REPORT_LIMIT)
          store.mark_subagent_results_reported(results.map { |run| run[:run_id] })
          @subagent_reporting[sid] = Time.now
          { results: results, more: pending.size > results.size }
        end
      end

      # What the conversation is told. It reads as a report rather than as the
      # reader speaking, and it keeps the question each run was given: an answer
      # without its task is unreadable a day later.
      def subagent_report_text(results, more: false)
        lines = []
        results.each do |run|
          lines << "## #{run[:agent_slug]}"
          task = run[:task].to_s.strip
          lines << "Tugas: #{task}" unless task.empty?
          lines << ""
          lines << run[:result].to_s.strip
          lines << ""
        end
        if more
          lines << "Masih ada hasil lain yang belum dibaca: panggil `subagent_results` untuk sisanya."
          lines << ""
        end
        lines.join("\n").rstrip
      end

      # Hand a finished batch over on a thread of its own: the turn that just
      # ended is done, and a report is a provider request the reader should not
      # wait for through this one.
      #
      # Arming is idempotent, because the callers overlap — the end of a turn,
      # the end of a report, a run finishing — and each of them would otherwise
      # start a thread for the same pile of answers. `@subagent_armed` is the
      # claim a thread leaves while it is on its way, before it has anything to
      # show in `@subagent_reporting`.
      #
      # The claim is a ticket rather than a flag, and it is handed to the thread
      # that runs it: a report that re-arms from its own `ensure` is asking while
      # that claim is still standing, and a mark nobody may take back would have
      # it wait for the very thread asking. `mine` is the ticket this thread is
      # finishing under, which is what turns "already armed" into "armed by me".
      def report_later(sid, mine: nil)
        ticket = arm_report(sid, mine: mine)
        return unless ticket

        Thread.new do
          Thread.current.report_on_exception = false
          begin
            report_subagents_when_done(sid, ticket: ticket)
          ensure
            release_arm(sid, ticket)
          end
        end
      rescue ThreadError => e
        # A mark that outlives the thread it was waiting for silences the
        # conversation for good: every later arm finds it and gives up, so a
        # batch landing with nobody typing is never reported again.
        release_arm(sid, ticket)
        warn "[subagent] could not start the report thread: #{e.class}: #{e.message}"
        nil
      end

      # Whether a report is worth starting: nothing claimed, no thread already on
      # its way, and something the conversation was never told about. Answers
      # with the ticket the new thread will hold, or nil.
      #
      # What is unread is the question, not what is still running. The sheet a
      # page draws is forgotten once its finished mark times out
      # (see SubagentJobs#forget), so asking `runs` whether there is anything to
      # report means the answer is "no" exactly when the news is oldest — the
      # batch that landed from the `ensure` of a run with nothing else going on.
      def arm_report(sid, mine: nil)
        ticket = @subagent_mutex.synchronize do
          next nil if @subagent_reporting[sid]

          held = @subagent_armed[sid]
          next nil if held && !held.equal?(mine)

          @subagent_armed[sid] = Object.new
        end
        return nil unless ticket
        return ticket if pending_subagent_answers?(sid)

        release_arm(sid, ticket)
        nil
      end

      # Drop a claim, but only the one this thread is holding. A report that
      # re-armed itself leaves the ticket of the thread it started, and the
      # thread that came before it must not take that thread's claim away.
      def release_arm(sid, ticket)
        return unless ticket

        @subagent_mutex.synchronize { @subagent_armed.delete(sid) if @subagent_armed[sid].equal?(ticket) }
      end

      # One question to the store, cheaper than the report turn that follows it.
      def pending_subagent_answers?(sid)
        store = Rubot::Archive.current
        return false unless store

        !store.pending_subagent_results(sid, limit: 1, newest_first: true).empty?
      rescue StandardError => e
        warn "[subagent] could not read pending answers: #{e.class}: #{e.message}"
        false
      end

      # The delegated runs of a conversation, and the note that they have just
      # been drawn whole on a page. Both the page itself and the stream opening
      # put the sheet on screen, so both leave the same record behind: the next
      # event may then swap only the slots inside it instead of replacing the
      # element under a reader whose panel is open.
      def subagent_runs_for_page(sid)
        runs = @subagent_jobs.runs(sid)
        @subagent_mutex.synchronize do
          @subagent_visible[sid] = Rubot::Web::SubagentJobs.visible?(runs)
        end
        runs
      end

      # The footer's sheet, whole, as an out-of-band swap. Used when what it
      # shows has to appear or disappear: the element in the page carries
      # `hidden` while there is nothing to say, so replacing it is the only way
      # to bring it into the row — and the only way to take it back out.
      def subagent_sheet_markup(subagents)
        View.render("_subagent_sheet", subagents: subagents)
            .sub(%(<details class="usage-sheet usage-sheet-subagents" id="subagent-sheet"),
                 %(<details class="usage-sheet usage-sheet-subagents" id="subagent-sheet" hx-swap-oob="true"))
      end

      # The slots inside that sheet, for every event while it stays on screen.
      # Only these are replaced, never the <details> holding them: a reader who
      # opened the panel keeps it open while the run it is describing moves on.
      def subagent_slots_markup(subagents)
        state = %(<span class="subagent-state" id="subagent-state" hx-swap-oob="innerHTML">) +
                View.render("_subagent_state", subagents: subagents) + %(</span>)
        rows = %(<div id="subagent-sheet-body" hx-swap-oob="innerHTML">) +
               View.render("_subagent_rows", subagents: subagents) + %(</div>)
        state + rows
      end
    end
  end
end
