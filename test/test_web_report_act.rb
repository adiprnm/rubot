# frozen_string_literal: true

require "test_helper"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # The report turn that may act.
    #
    # A finished batch of delegated runs is handed back to the conversation as a
    # turn of its own. That turn is now given the toolset, because the reader may
    # already have asked in this conversation for something to happen once the
    # answers land — "kalau reviewer bilang aman, langsung commit dan buat PR" —
    # and the model reading the transcript is the one that decides whether such a
    # request exists. Nothing in the channel decides it: there is no verdict to
    # parse and no switch to read.
    #
    # What the channel still owns is the leash: which report is allowed to act,
    # what it is told, how long it may hold the conversation, and what the reader
    # is left with when it runs out of time. A loop's report and every other
    # report stay exactly what they were — words, one round, no tools.
    class TestWebReportAct < Minitest::Test
      include WebChannelSupport

      SID = "web_rubot"

      # A conversation handle that answers a background turn and remembers how it
      # was asked. It stands in for SessionHandle, which is a Ractor's proxy and
      # opens a real actor in a test.
      class FakeHandle
        attr_reader :calls, :cancelled, :stopped, :peak

        def initialize(answer: "Siap, hasilnya kubaca.", delay: 0.0)
          @answer = answer
          @delay = delay
          @calls = []
          @cancelled = 0
          @stopped = []
          @active = 0
          @peak = 0
          @mutex = Mutex.new
        end

        def process_background(text, label: "", fresh: false, tools: true, max_rounds: nil, id: nil,
                               &chunk)
          @calls << { text: text, label: label, fresh: fresh, tools: tools, max_rounds: max_rounds,
                      id: id }
          @mutex.synchronize do
            @active += 1
            @peak = @active if @active > @peak
          end
          chunk&.call("Siap, ")
          sleep @delay if @delay.positive?
          chunk&.call("hasilnya kubaca.")
          @answer
        ensure
          @mutex.synchronize { @active -= 1 }
        end

        # What SessionHandle#cancel! does: a stop that names the turn it is meant
        # for, which is what actually ends it inside the actor without touching
        # any other turn.
        def cancel!(id = nil)
          @cancelled += 1
          @stopped << id
          true
        end
      end

      # A handle that never answers on its own: the deadline is the only thing
      # that can end its turn.
      class StuckHandle < FakeHandle
        def process_background(_text, **_options, &_chunk)
          @cancelled = 0
          sleep 30
          "tidak akan sampai sini"
        end
      end

      # A conversation handle with a door in the middle of its first report: the
      # test opens it when the report may finish, which is the only way to put a
      # second batch on the pile while one report is still running. Everything
      # after the first report answers at once.
      class GatedReportHandle
        def initialize(entered:, door:)
          @entered = entered
          @door = door
          @texts = []
          @mutex = Mutex.new
        end

        def texts
          @mutex.synchronize { @texts.dup }
        end

        def process_background(text, **_options, &chunk)
          first = @mutex.synchronize do
            @texts << text
            @texts.size == 1
          end
          chunk&.call("Siap.")
          return "Siap, hasilnya kubaca." unless first

          @entered << true
          @door.pop
          "Siap, hasilnya kubaca."
        end

        def cancel!(_id = nil)
          true
        end

        # What binding the loop runner asks of a conversation (see
        # Web::Loops#bind_loop_runner): this fake has no loops, and the report
        # path never binds anything else.
        def tools
          registry = Object.new
          registry.define_singleton_method(:get) { |_name| nil }
          registry
        end
      end

      def acting_channel
        channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                             messages: { SID => [ %w[user Halo], %w[assistant Siap.] ] })
      end

      def handle_for(channel, handle)
        channel.define_singleton_method(:session_for) { |_sid| handle }
        handle
      end

      # The deadline as the report sees it: recorded instead of armed, so a test
      # can read the leash without waiting on it, and the body still runs.
      def record_deadlines(channel)
        seen = []
        channel.define_singleton_method(:with_report_deadline) do |sid, seconds:, what:, &block|
          seen << { sid: sid, seconds: seconds, what: what }
          block.call
        end
        seen
      end

      def drain(queue)
        sent = []
        sent << queue.pop until queue.empty?
        sent
      end

      def claim(result: "puisi jadi", slug: "code_reviewer")
        { results: [ { run_id: "r1", agent_slug: slug, task: "review the diff", result: result } ],
          more: false }
      end

      # --- the acting report --------------------------------------------

      # A batch of answers is the one report that comes with the toolset: the
      # reader's request may be waiting on it.
      def test_a_finished_batch_is_reported_by_a_turn_that_can_act
        channel = acting_channel
        handle = handle_for(channel, FakeHandle.new)
        deadlines = record_deadlines(channel)

        channel.deliver_subagent_report(SID, claim)

        assert_equal 1, handle.calls.size
        call = handle.calls.first
        assert_equal true, call[:tools], "the turn has to be able to carry on"
        assert_equal Rubot::Web::Subagents::ACTING_REPORT_MAX_ROUNDS, call[:max_rounds],
                     "a job whose shape is known does not need the conversation's thousand rounds"
        assert_includes call[:text], "puisi jadi", "the answers are what the turn is read against"

        assert_equal 1, deadlines.size
        assert_equal Rubot::Web::Subagents::ACTING_REPORT_TIMEOUT_SECONDS, deadlines.first[:seconds],
                     "a push and a forge round trip do not fit in a report's ninety seconds"
      end

      # Everything the turn needs to act without a human, and nothing that would
      # let it act without being asked.
      def test_an_acting_report_is_told_what_it_may_do_and_what_it_may_not
        channel = acting_channel
        handle = handle_for(channel, FakeHandle.new)
        record_deadlines(channel)

        channel.deliver_subagent_report(SID, claim)

        label = handle.calls.first[:label]
        assert_includes label, "PUNYA tool", "the turn is told it can act at all"
        assert_includes label, "sudah meminta", "and that the request has to come from the reader"
        assert_includes label, "JANGAN mengubah apa pun", "with no request, it changes nothing"
        assert_includes label, "VERDICT: BLOCKERS OPEN", "open blockers forbid the commit"
        assert_includes label, "main", "committing on main is what has to be avoided"
        assert_includes label, "master"
        assert_includes label, "gh pr create"
        assert_includes label, "Push branch", "the push comes first, or gh asks a question nobody can answer"
        assert_operator label.index("Push branch"), :<, label.index("gh pr create"),
                        "pushed before the pull request, not after it"
        refute_includes label, "tidak punya tool",
                        "the note for a turn without tools must never reach this one"
      end

      # The other report paths are untouched: a loop that stopped is still words
      # with one round, on the report's own deadline.
      def test_a_report_that_was_never_asked_to_act_keeps_its_short_leash
        channel = acting_channel
        handle = handle_for(channel, FakeHandle.new)
        deadlines = record_deadlines(channel)

        # Exactly how a finished loop reports itself (see Web::Loops).
        channel.deliver_report(SID, text: "Loop selesai, 3 iterasi.", label: "Loop yang berhenti:\n")

        call = handle.calls.first
        assert_equal false, call[:tools], "a report is words, not work"
        assert_nil call[:max_rounds], "one round is the shape that cannot wander"
        assert_includes call[:label], Rubot::Web::Reports::REPORT_TOOLS_NOTE
        refute_includes call[:label], "PUNYA tool"
        assert_equal Rubot::Web::Reports::REPORT_TIMEOUT_SECONDS, deadlines.first[:seconds]
        assert_equal Rubot::Web::Reports::REPORT_TIMEOUT_SECONDS, 90,
                     "the loop's report keeps the ninety seconds it always had"
      end

      # --- the leash -----------------------------------------------------

      # A deadline that only unblocks the caller leaves the turn working inside
      # the actor, where the reader's next message queues behind it. The turn has
      # to be stopped, and what the reader is told may not claim a repo that was
      # never touched: the stop can land after a commit.
      #
      # The deadline is not swallowed on the way out, not even for a report that
      # may act: its answers were marked read when they were claimed, and only an
      # exception makes the caller give them back to the pile.
      def test_an_acting_report_that_overruns_is_stopped_and_admits_the_state_is_unknown
        channel = acting_channel
        handle = handle_for(channel, StuckHandle.new)
        queue = Queue.new
        channel.listen_for_events(SID, queue)

        assert_raises(Timeout::Error) do
          channel.deliver_report(SID, text: "hasil review", act: true,
                                     max_rounds: Rubot::Web::Subagents::ACTING_REPORT_MAX_ROUNDS,
                                     timeout: 0.05)
        end

        assert_equal 1, handle.cancelled, "the turn goes with the deadline"
        assert_equal 1, handle.stopped.size
        refute_nil handle.stopped.first,
                   "the stop names the turn it is for, or it would end the reader's own"
        said = drain(queue).last[1]
        assert_includes said, "kuhentikan", "the reader is told the report was cut, not left blank"
        assert_includes said, "git status", "the reader is told where to look"
        assert_includes said, "belum pasti", "the state is unknown, not untouched"
        refute_includes said, "tidak akan sampai sini",
                        "a turn cut at its deadline has no answer of its own to show"
      end

      # One conversation, one report at a time: a second report waits instead of
      # writing into the block the first one opened.
      def test_two_reports_for_one_conversation_never_run_at_once
        channel = acting_channel
        handle = handle_for(channel, FakeHandle.new(delay: 0.05))
        record_deadlines(channel)

        threads = 2.times.map do
          Thread.new do
            Thread.current.report_on_exception = false
            channel.deliver_report(SID, text: "hasil", act: true,
                                       max_rounds: 20, timeout: 5)
          end
        end
        threads.each { |thread| thread.join(10) }

        assert_equal 1, handle.peak, "the second report waits for the first to finish"
        assert_equal 2, handle.calls.size, "waited, not dropped"
      end

      # The deadline's production shape: the report is not sleeping, it is
      # blocked on the event port of a turn that has not answered yet. The end of
      # it is the join, not a sleep, so there is no version of this that comes
      # out differently on a slow machine — the body is blocked when the deadline
      # arrives, and it is the only thread that can be blocked there.
      def test_a_deadline_reaches_a_report_blocked_in_a_port_receive
        channel = Rubot::Channels::Web.new(channel_config: {})
        port = Ractor::Port.new
        closed = false

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        error = assert_raises(Timeout::Error) do
          channel.with_report_deadline(SID, seconds: 0.05, what: "report") do
            begin
              port.receive
            ensure
              # What a killed report thread still does: its ensure closes the
              # port of the turn it was reading, which is how the actor learns
              # nobody is listening any more.
              closed = true
              port.close
            end
          end
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_equal true, closed, "the killed thread still runs its ensure"
        assert_includes error.message, "report deadline"
        assert_operator elapsed, :<, 5, "the deadline is the join, not a client-side timeout"
      ensure
        begin
          port&.close
        rescue StandardError
          nil
        end
      end

      # The other side of the same join: a report that answers ends its own
      # deadline. Nothing is left behind to fire later, at a body that has
      # already returned.
      def test_a_report_that_answers_ends_its_own_deadline
        channel = Rubot::Channels::Web.new(channel_config: {})

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        answer = channel.with_report_deadline(SID, seconds: 30, what: "report") { "selesai" }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_equal "selesai", answer
        assert_operator elapsed, :<, 2, "the answer ends it, not the thirty seconds it was given"
      end

      # --- the pile the report leaves behind ------------------------------

      # A batch that landed while a report was running was skipped, and nothing
      # else asks for it: the only other arm is the end of a turn, so a
      # conversation nobody is typing in keeps it unread. The end of the report
      # is the moment the pile is fair game again.
      def test_the_end_of_a_report_arms_the_batch_that_landed_behind_it
        channel = acting_channel
        armed = []
        channel.define_singleton_method(:claim_subagent_results) do |_sid|
          { results: [ { run_id: "r1", agent_slug: "code_reviewer", task: "review the diff",
                         result: "aman" } ], more: false }
        end
        channel.define_singleton_method(:deliver_subagent_report) { |_sid, _claim| nil }
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:broadcast_sessions) { nil }
        channel.define_singleton_method(:broadcast_usage) { |_sid| nil }
        channel.define_singleton_method(:report_later) do |sid, **_options|
          # Read at the moment it is asked: a re-arm that runs before the claim
          # is dropped would find its own report and do nothing.
          armed << [ sid, instance_variable_get(:@subagent_reporting)[sid] ]
        end
        channel.instance_variable_get(:@subagent_reporting)[SID] = Time.now

        channel.report_subagents_when_done(SID)

        assert_equal [ [ SID, nil ] ], armed, "the claim is gone before the pile is asked again"
      end

      # The bug this closes, and the reason the two arming tests above could not
      # see it: they replace `report_later`, so no mark is ever held while a
      # report runs. Here it is held for real.
      #
      # A batch lands while a report is running. Its own path — the `ensure` of
      # the delegate run — finds the claim taken and says nothing, which is
      # correct: one report at a time. The end of that report is the moment the
      # pile is fair game again, and the thread asking is the one holding the
      # mark. So the arm has to tell "someone else is on their way" apart from
      # "I am the report that just finished", or the batch waits for a reader to
      # happen to type — exactly what a background report exists to avoid.
      def test_a_batch_that_lands_while_a_report_runs_is_reported_without_a_turn
        channel = acting_channel
        channel.instance_variable_set(:@running, true)
        store = Rubot::Session.store
        store.start_subagent_run(run_id: "r1", parent_session: SID, agent_slug: "code_reviewer",
                                 task: "review the diff")
        store.finish_subagent_run(run_id: "r1", status: "done", result: "aman")

        entered = Queue.new
        door = Queue.new
        handle = GatedReportHandle.new(entered: entered, door: door)
        channel.define_singleton_method(:session_for) { |_sid| handle }
        channel.define_singleton_method(:broadcast_report_entry) { |_sid, _index, _text| nil }
        channel.define_singleton_method(:broadcast_sessions) { nil }
        channel.define_singleton_method(:broadcast_usage) { |_sid| nil }

        channel.report_later(SID)
        entered.pop(timeout: 10)
        assert_equal 1, handle.texts.size, "the first report is running"

        # The next batch lands the way a run does (see #start_delegate): the
        # row is closed, and the `ensure` of the run asks for it. That ask runs
        # here, on this thread, so which of the two it meets is fixed rather
        # than raced for.
        store.start_subagent_run(run_id: "r2", parent_session: SID, agent_slug: "implementer",
                                 task: "tulis puisi")
        lander = Thread.new do
          channel.finish_delegate_run("r2", status: "done", result: "puisi jadi")
          channel.report_subagents_when_done(SID)
        end
        lander.join

        assert_equal 1, handle.texts.size, "one report at a time: the second batch waits"

        door << true

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        while handle.texts.size < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.01
        end

        assert_equal 2, handle.texts.size,
                     "the batch that landed behind the report is reported with no turn of its own"
        assert_includes handle.texts.last, "puisi jadi"
      end

      # A mark that outlives the thread it was meant to start is worse than no
      # mark at all: every later arm finds it and gives up, so the conversation
      # is never reported to again.
      def test_a_mark_is_not_left_behind_when_the_report_thread_cannot_start
        channel = acting_channel
        channel.instance_variable_set(:@running, true)
        store = Rubot::Session.store
        store.start_subagent_run(run_id: "r1", parent_session: SID, agent_slug: "code_reviewer",
                                 task: "review the diff")
        store.finish_subagent_run(run_id: "r1", status: "done", result: "aman")

        delivered = Queue.new
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:broadcast_sessions) { nil }
        channel.define_singleton_method(:broadcast_usage) { |_sid| nil }
        channel.define_singleton_method(:deliver_report) { |_sid, text:, **_options| delivered << text }

        no_thread = ->(*_args, **_kwargs, &_block) { raise ThreadError, "no thread for you" }
        Thread.stub(:new, no_thread) { channel.report_later(SID) }

        channel.report_later(SID)

        assert_includes delivered.pop(timeout: 10), "aman",
                        "the arm that failed to start a thread did not silence the conversation"
      end

      # The instalments of a long backlog are not a skipped batch: that report
      # named what is still waiting and how to fetch it, so its end does not
      # start another turn nobody asked for.
      def test_a_report_that_deferred_a_backlog_does_not_arm_itself_again
        channel = acting_channel
        armed = []
        channel.define_singleton_method(:claim_subagent_results) do |_sid|
          { results: [ { run_id: "r1", agent_slug: "code_reviewer", task: "review", result: "aman" } ],
            more: true }
        end
        channel.define_singleton_method(:deliver_subagent_report) { |_sid, _claim| nil }
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:broadcast_sessions) { nil }
        channel.define_singleton_method(:broadcast_usage) { |_sid| nil }
        channel.define_singleton_method(:report_later) { |sid, **_options| armed << sid }

        channel.report_subagents_when_done(SID)

        assert_empty armed, "the backlog waits for a turn, not for another report"
      end

      # A redraw that fails is a stale sidebar, not a lost report. The answers
      # were already on the page when the broadcast went out, so handing them
      # back would have the next report say the same thing a second time.
      def test_a_broadcast_that_fails_after_the_answer_was_shown_keeps_it_read
        channel = acting_channel
        channel.instance_variable_set(:@running, true)
        store = Rubot::Session.store
        store.start_subagent_run(run_id: "r1", parent_session: SID, agent_slug: "code_reviewer",
                                 task: "review the diff")
        store.finish_subagent_run(run_id: "r1", status: "done", result: "aman")

        shown = []
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:deliver_report) { |sid, text:, **_options| shown << [ sid, text ] }
        channel.define_singleton_method(:broadcast_sessions) { raise "sidebar is down" }
        channel.define_singleton_method(:broadcast_usage) { |_sid| nil }

        channel.report_subagents_when_done(SID)

        assert_equal 1, shown.size
        assert_empty store.pending_subagent_results(SID),
                     "what was shown is not handed back as unread"
      end

      # A report that failed gives its answers back instead of arming itself:
      # retrying a provider that just failed in a loop is worse than waiting for
      # the next turn.
      def test_a_failed_report_gives_the_answers_back_and_does_not_arm_itself
        channel = acting_channel
        armed = []
        released = []
        channel.define_singleton_method(:claim_subagent_results) do |_sid|
          { results: [ { run_id: "r1", agent_slug: "code_reviewer", task: "review", result: "aman" } ],
            more: false }
        end
        channel.define_singleton_method(:deliver_subagent_report) { |_sid, _claim| raise "provider down" }
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:release_report) { |sid, claim| released << [ sid, claim[:results].size ] }
        channel.define_singleton_method(:report_later) { |sid, **_options| armed << sid }

        channel.report_subagents_when_done(SID)

        assert_equal [ [ SID, 1 ] ], released, "the answers are back in the unread pile"
        assert_empty armed, "the next turn asks again, not this report"
      end

      # What decides whether there is anything to report is what the store has
      # not handed over, not what the footer is still drawing: a run's sheet is
      # forgotten once its finished mark times out, and the batch that landed
      # with no turn running is exactly the one that outlives it.
      def test_a_batch_is_armed_by_its_unread_answers_not_by_a_sheet_that_is_gone
        channel = acting_channel
        channel.instance_variable_set(:@running, true)
        store = Rubot::Session.store
        store.start_subagent_run(run_id: "r1", parent_session: SID, agent_slug: "code_reviewer",
                                 task: "review the diff")
        store.finish_subagent_run(run_id: "r1", status: "done", result: "puisi jadi")

        assert_empty channel.subagent_runs_for_page(SID), "the footer has nothing left to draw"

        delivered = Queue.new
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:broadcast_sessions) { nil }
        channel.define_singleton_method(:broadcast_usage) { |_sid| nil }
        channel.define_singleton_method(:deliver_report) do |sid, text:, **_options|
          delivered << [ sid, text ]
        end

        channel.report_later(SID)
        sid, text = delivered.pop(timeout: 10)

        assert_equal SID, sid
        assert_includes text, "puisi jadi", "the answer nobody had seen is reported"
      end
    end
  end
end
