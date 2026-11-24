# frozen_string_literal: true

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
      # How many subagent answers one automatic report carries. A batch is
      # usually small; a long backlog is handed over in instalments rather than
      # as one wall of text, and only the runs actually quoted are marked read.
      SUBAGENT_REPORT_LIMIT = 5
      # How often a report that is being written reaches the page. Faster than
      # this is a repaint the eye cannot follow; slower is a stall.
      REPORT_STREAM_SECONDS = 0.15
      # How long one report may hold a conversation before its claim is treated
      # as abandoned. Long enough for a report turn that reads a file or two,
      # short enough that a thread which died does not silence the conversation
      # for the rest of the process.
      REPORT_CLAIM_SECONDS = 600
      # How long a report turn may take before it is treated as stuck. Generous:
      # a report is a provider request that may read a file or two, and the
      # answer is streaming to the page while it runs, so nothing is lost by
      # waiting. Long enough that a slow model is not cut, short enough that a
      # dead read does not take the answers with it.
      REPORT_TIMEOUT_SECONDS = 90
      # A notification body is read on a lock screen, so a finished delegation
      # says no more than a turn note does. The number is the cron delivery's,
      # which is where most of it is spent.
      TURN_NOTIFY_CHARS = Rubot::Web::Routes::Cron::TURN_NOTIFY_CHARS

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
      def report_subagents_when_done(sid)
        claim = claim_subagent_results(sid)
        return unless claim

        begin
          prepare_delivery(sid)
          deliver_subagent_report(sid, claim)
          broadcast_sessions
          broadcast_usage(sid)
        rescue StandardError => e
          warn "[subagent] could not report results: #{e.class}: #{e.message}"
          # Answers marked read and then lost are the one thing a background run
          # cannot come back from, so a report that failed hands them back.
          release_report(sid, claim)
        ensure
          @subagent_mutex.synchronize { @subagent_reporting.delete(sid) }
        end
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

      # The report itself.
      #
      # Background, not a user message: the answers are handed to the model as
      # context and only its reply joins the transcript. The reader asked for the
      # work; they did not say "Hasil subagent yang sudah selesai".
      #
      # Where the reply goes depends on what the page is showing. Idle, it is
      # appended to the thread and filled in as it is written, so the reader
      # watches it arrive. While a turn of their own is running, a block appended
      # now would sit before the answer still being written, and only a redraw
      # can put the two in the archive's order.
      def deliver_subagent_report(sid, claim)
        text = subagent_report_text(claim[:results], more: claim[:more])
        label = "Hasil subagent yang sudah selesai, dari kerja yang kamu delegasikan:\n\n"

        index = next_entry_index(sid)
        broadcast_report_entry(sid, index, "")

        last_sent = 0.0
        begin
          reply = with_report_deadline(sid) do
            session_for(sid).process_background(text, label: label) do |written|
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              next if now - last_sent < REPORT_STREAM_SECONDS

              last_sent = now
              broadcast_report_entry(sid, index, written)
            end
          end
          # The last passage is always sent: a fixed cadence must not be what
          # decides whether the reader sees the end of the answer.
          broadcast_report_entry(sid, index, reply.to_s)
        rescue StandardError
          # The block opened for the answer would stand there empty, which is
          # worse than nothing: take it back and let the caller log the failure.
          if index
            push_to_session(sid, :append, %(<div id="m-#{index}" hx-swap-oob="delete"></div>))
          end
          raise
        end
      end

      # A report turn is a provider request nobody is watching, so a read that
      # never returns would hold the conversation's answers out of sight for good
      # — the claim never released and no line in the log.
      #
      # The deadline is watched by a thread that reads the stuck thread's stack
      # before it interrupts it: an exception raised by `Timeout` carries the
      # timer's stack, not the place the work was blocked, which is the one thing
      # that matters here.
      def with_report_deadline(sid)
        target = Thread.current
        watchdog = Thread.new do
          Thread.current.report_on_exception = false
          sleep REPORT_TIMEOUT_SECONDS
          next unless target.alive?

          warn "[subagent] report for #{sid} still running after #{REPORT_TIMEOUT_SECONDS}s at: " \
               "#{Array(target.backtrace).first(12).join(" | ")}"
          target.raise(Timeout::Error, "report deadline")
        end

        yield
      ensure
        watchdog&.kill
      end

      # The entry the report becomes, as the page draws it.
      #
      # Two shapes, and the difference is the whole point. The first passage
      # appends the block; every passage after it replaces only the prose
      # *inside* that block. Replacing the block each time re-created the
      # element, and `.turn` carries the animation that plays when a turn
      # arrives — replayed every 150ms it read as a blinking answer instead of a
      # growing one.
      def broadcast_report_entry(sid, index, text)
        if index.nil?
          # Nothing to anchor the block to (no archive): draw it whole, once.
          return if text.to_s.empty?

          entry = { kind: :turn, idx: nil, items: [ { kind: :text, text: text.to_s } ] }
          markup = View.render("_entry", entry: entry, landed: false, token_query: token_query,
                                         ig_accounts: [], ig_linkable_accounts: [], ig_persona: "")
          push_to_session(sid, :append, %(<div id="thread" hx-swap-oob="beforeend">#{markup}</div>))
          return
        end

        if text.to_s.empty?
          # `is-report` is what the page reads to know this block is not the turn
          # the reader is watching: the script follows a turn's own text, and
          # following this one scrolled the answer being read upward.
          block = %(<div class="turn is-done is-report" id="m-#{index}">) +
                  %(<div class="turn-body"><div class="text" id="report-#{index}"></div></div></div>)
          push_to_session(sid, :append, %(<div id="thread" hx-swap-oob="beforeend">#{block}</div>))
        else
          push_to_session(sid, :append,
                          %(<div id="report-#{index}" hx-swap-oob="innerHTML">#{View.prose(text)}</div>))
        end
      end

      # Where the next message of a conversation will land. The report is drawn
      # with it so that the block the page is given and the block a later load
      # draws share one anchor.
      def next_entry_index(sid)
        store = Rubot::Archive.current
        return nil unless store

        store.last_index(sid).to_i + 1
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
      def report_later(sid)
        return unless @subagent_reporting[sid].nil?
        return if @subagent_jobs.runs(sid).empty?

        Thread.new do
          Thread.current.report_on_exception = false
          report_subagents_when_done(sid)
        end
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
