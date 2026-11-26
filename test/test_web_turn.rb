# frozen_string_literal: true

require "test_helper"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # One turn as it reaches the page: streaming, thinking, the footer and the naming that follows it.
    class TestWebTurn < Minitest::Test
      include WebChannelSupport

      # --- Turn -----------------------------------------------------------

      # A clock the test can move, so the three-second rules are checked
      # without sleeping through them.


      # A provider that answers without a network: one canned reply for the turn
      # and one title for the naming request that follows it. The naming call is
      # told apart by its system prompt, which is the only thing a stub can see.

      # The shell of the page with nothing in it but what these view tests need:
      # a persona, one open session, and whatever turn is still in flight.

      # Enough of a WEBrick::HTTPResponse for the channel's rendering paths: it
      # only ever writes a status, a body and a header or two.

      # The other half of a request: a path, a method and a query string. The
      # routing table is the one thing a view test cannot reach, so a route that
      # is wired to nothing still has to fail here rather than in a browser.

      # A session stand-in that only has to hand out tools: the delivery bind
      # reads nothing else.

      # Stands in for a session actor when only the cron call matters.

      # Says where a conversation is rooted, which is all the channel asks of
      # the pool when it binds the cron tool.



      # A channel whose config points at a throwaway ~/.rubot: personas.json
      # next to config.yml, conversations in <dir>/sessions. The channel is
      # given the config directly, so no session pool (and no Ractor) is
      # spawned just to list files.
      # A delegate request is run outside the turn that asked for it: the job is
      # tracked by the channel, and the answer is kept where the footer and
      # `subagent_results` can both find it.
      def test_a_delegate_request_runs_outside_the_turn_and_lands_in_the_footer
        channel = channel_with_sessions(personas: { "rubot" => { "name" => "Rubot" } },
                                        sessions: { "web_rubot" => "Halo" })
        handle = FakeDelegateHandle.new("jawaban writer")
        pool = Object.new
        pool.define_singleton_method(:delegate) { |**_kwargs| handle }
        channel.instance_variable_set(:@pool, pool)

        channel.start_delegate("web_rubot",
                     { run_id: "r1", agent: "writer", task: "tulis puisi", model: "" })

        jobs = channel.instance_variable_get(:@subagent_jobs)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        while jobs.running_count("web_rubot").positive? &&
              Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.01
        end

        run = jobs.runs("web_rubot").first
        assert_equal "done", run[:phase]
        assert_equal "jawaban writer", run[:result]
        assert_equal "web_rubot~sub-r1", handle.session_id
      end

      def test_a_delegate_request_for_an_unknown_persona_fails_the_run
        channel = channel_with_sessions(personas: { "rubot" => { "name" => "Rubot" } },
                                        sessions: { "web_rubot" => "Halo" })
        pool = Object.new
        pool.define_singleton_method(:delegate) { |**_kwargs| nil }
        channel.instance_variable_set(:@pool, pool)

        channel.start_delegate("web_rubot",
                     { run_id: "r1", agent: "nobody", task: "tulis puisi", model: "" })

        run = channel.instance_variable_get(:@subagent_jobs).runs("web_rubot").first
        assert_equal "failed", run[:phase]
        assert_match(/nobody/, run[:error])
      end

      # A finished delegation is news the reader asked for, and it lands after
      # the turn that asked is over — so it rings, instead of waiting to be
      # noticed in a panel nobody has opened.
      def test_a_finished_delegate_run_rings_the_lock_screen
        channel = channel_with_sessions(personas: { "rubot" => { "name" => "Rubot" } },
                                        sessions: { "web_rubot" => "Halo" })
        handle = FakeDelegateHandle.new("jawaban writer")
        pool = Object.new
        pool.define_singleton_method(:delegate) { |**_kwargs| handle }
        channel.instance_variable_set(:@pool, pool)

        pushes = []
        channel.define_singleton_method(:notify_push) do |slug, title:, body:, url:, **_rest|
          pushes << { slug: slug, title: title, body: body, url: url }
        end

        channel.start_delegate("web_rubot",
                     { run_id: "r1", agent: "writer", task: "tulis puisi", model: "" })

        jobs = channel.instance_variable_get(:@subagent_jobs)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        while jobs.running_count("web_rubot").positive? &&
              Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.01
        end

        # The run is marked finished before it is announced, so watching the
        # count alone can land in the gap between the two and see no push yet.
        sleep 0.01 while pushes.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

        assert_equal 1, pushes.size
        assert_includes pushes.first[:body], "writer"
        assert_includes pushes.first[:body], "jawaban writer"
        assert_includes pushes.first[:url], "/s/web_rubot"
      end

      # The sheet is only replaced when what it should show changes, so the page
      # has to have been told what it shows — otherwise a stale note says
      # "already visible" and the section never appears on a page that is in
      # fact showing nothing. Both the page load and every stream opening leave
      # that note behind, so a delegation that starts right after one redraws
      # the element whole.
      def test_a_run_starting_after_a_page_load_shows_the_whole_sheet
        channel = channel_with_sessions(personas: { "rubot" => { "name" => "Rubot" } },
                                        sessions: { "web_rubot" => "Halo" })
        sent = []
        channel.define_singleton_method(:push_to_session) do |_sid, type, markup|
          sent << [ type, markup ]
        end

        # What the page was just told: nothing to show.
        channel.subagent_runs_for_page("web_rubot")

        jobs = channel.instance_variable_get(:@subagent_jobs)
        jobs.start(session_id: "web_rubot", run_id: "r1", agent: "writer", task: "tulis puisi")

        assert_equal 1, sent.size
        assert_includes sent.first[1], %(id="subagent-sheet" hx-swap-oob="true")
        refute_includes sent.first[1], %(id="subagent-sheet" hidden)
      end

      # A batch belongs to the conversation that asked for it. When the last run
      # lands, what came back becomes a turn of its own, so the reader gets the
      # report without asking a second time — and each answer is handed over
      # once, because the store records what it has already given.
      def test_the_last_run_hands_the_batch_back_to_the_conversation
        channel = channel_with_archive(
          personas: { "rubot" => { "name" => "Rubot" } },
          messages: { "web_rubot" => [ [ "user", "Halo" ], [ "assistant", "Siap." ] ] }
        )
        channel.instance_variable_set(:@running, true)
        store = Rubot::Session.store
        store.start_subagent_run(run_id: "r1", parent_session: "web_rubot",
                                 agent_slug: "writer", task: "tulis puisi")
        store.start_subagent_run(run_id: "r2", parent_session: "web_rubot",
                                 agent_slug: "researcher", task: "cari docs")
        store.finish_subagent_run(run_id: "r1", status: "done", result: "puisi jadi")
        store.finish_subagent_run(run_id: "r2", status: "done", result: "docs ketemu")

        said = record_reports(channel)
        appended = []
        channel.define_singleton_method(:broadcast_report_entry) do |sid, _index, text|
          appended << [ sid, text ]
        end

        jobs = channel.instance_variable_get(:@subagent_jobs)
        jobs.start(session_id: "web_rubot", run_id: "r1", agent: "writer", task: "tulis puisi")
        jobs.start(session_id: "web_rubot", run_id: "r2", agent: "researcher", task: "cari docs")
        jobs.finish(session_id: "web_rubot", run_id: "r1", status: "done", result: "puisi jadi")

        channel.report_subagents_when_done("web_rubot")
        assert_empty said, "one run is still working, so there is nothing to report yet"

        jobs.finish(session_id: "web_rubot", run_id: "r2", status: "done", result: "docs ketemu")
        channel.report_subagents_when_done("web_rubot")

        assert_equal 1, said.size, "one batch, one report"
        payload = said.first
        assert_includes payload[:text], "puisi jadi"
        assert_includes payload[:text], "docs ketemu"
        assert_includes payload[:text], "Tugas: cari docs"
        # Background, not a user message: the label is the framing the model
        # sees, and nothing of it is written into the transcript as the reader.
        assert_includes payload[:label], "Hasil subagent"
        refute payload[:fresh]
        assert_equal "Siap, hasilnya kubaca.", appended.last[1],
                     "the reply is put on the page as its own block"
        assert_equal "web_rubot", appended.last[0]

        channel.report_subagents_when_done("web_rubot")
        assert_equal 1, said.size, "an answer is handed over once"
      end

      # A backlog must not starve the batch that just landed: the report takes
      # the newest answers and says that the rest are still waiting, instead of
      # swallowing them unread or burying the news behind old news.
      def test_a_report_takes_the_fresh_batch_and_names_what_is_still_waiting
        channel = channel_with_archive(
          personas: { "rubot" => { "name" => "Rubot" } },
          messages: { "web_rubot" => [ [ "user", "Halo" ], [ "assistant", "Siap." ] ] }
        )
        channel.instance_variable_set(:@running, true)
        store = Rubot::Session.store
        total = Rubot::Channels::Web::SUBAGENT_REPORT_LIMIT + 1
        (1..total).each do |i|
          store.start_subagent_run(run_id: "r#{i}", parent_session: "web_rubot",
                                   agent_slug: "writer", started_at: "2026-11-10T0#{i}:00:00Z")
          store.finish_subagent_run(run_id: "r#{i}", status: "done", result: "jawaban #{i}")
        end

        said = record_reports(channel)
        channel.report_subagents_when_done("web_rubot")

        assert_equal 1, said.size
        text = said.first[:text]
        assert_includes text, "jawaban #{total}", "the newest answer is the news"
        refute_includes text, "jawaban 1", "the oldest one waits for the next report"
        assert_includes text, "subagent_results"
        assert_equal 1, store.pending_subagent_results("web_rubot").size,
                     "only what was quoted is marked read"
      end

      # A stand-in for a conversation's handle: it records what it was asked to
      # say, and its tools answer nothing (the report only binds delivery
      # context, it does not call a tool).

      # The report becomes a turn nobody is following, so it is appended to the
      # page that is open: written to the archive and announced nowhere, the
      # answer looked like it never came.
      def test_a_report_is_appended_to_the_open_page
        channel = channel_with_archive(
          personas: { "rubot" => { "name" => "Rubot" } },
          messages: { "web_rubot" => [ [ "user", "Halo" ], [ "assistant", "Siap." ] ] }
        )
        channel.instance_variable_set(:@running, true)
        store = Rubot::Session.store
        store.start_subagent_run(run_id: "r1", parent_session: "web_rubot",
                                 agent_slug: "writer", task: "tulis puisi")
        store.finish_subagent_run(run_id: "r1", status: "done", result: "puisi jadi")

        said = record_reports(channel)
        queue = Queue.new
        channel.listen_for_events("web_rubot", queue)

        channel.report_subagents_when_done("web_rubot")

        assert_equal 1, said.size
        assert_equal false, said.first[:tools],
                     "a report is words, not work: the turn must not be handed the toolset"
        sent = []
        sent << queue.pop until queue.empty?
        appends = sent.select { |item| item.is_a?(Array) && item[0] == :append }
        refute_empty appends, "the reply is appended to the thread"

        # First the block where the answer will be written, then the prose inside
        # it — and only the prose. The block is never re-created while it streams:
        # the entry carries the animation that plays when a turn arrives, and
        # replaying that on every passage made the answer blink instead of grow.
        assert_includes appends.first[1], %(id="thread" hx-swap-oob="beforeend")
        assert_includes appends.first[1], %(class="turn is-done is-report")
        assert_includes appends.last[1], %(hx-swap-oob="innerHTML")
        assert_includes appends.last[1], "Siap, hasilnya kubaca."
        refute_includes appends.last[1], %(class="turn"),
                        "the block around the answer is left standing while it is written"
      end

      # A report that could not be delivered must not leave its answers marked
      # read: the model never saw them, and the store would never offer them
      # again. The pile is what the next attempt draws from.
      def test_a_report_that_fails_hands_the_answers_back
        channel = channel_with_archive(
          personas: { "rubot" => { "name" => "Rubot" } },
          messages: { "web_rubot" => [ [ "user", "Halo" ], [ "assistant", "Siap." ] ] }
        )
        channel.instance_variable_set(:@running, true)
        store = Rubot::Session.store
        store.start_subagent_run(run_id: "r1", parent_session: "web_rubot",
                                 agent_slug: "writer", task: "tulis puisi")
        store.finish_subagent_run(run_id: "r1", status: "done", result: "puisi jadi")

        channel.define_singleton_method(:session_for) do |_sid|
          fake = Object.new
          fake.define_singleton_method(:process_background) { |*_args, **_kwargs, &_block| raise "provider mati" }
          fake.define_singleton_method(:tools) do
            tools = Object.new
            tools.define_singleton_method(:get) { |_name| nil }
            tools
          end
          fake
        end

        channel.report_subagents_when_done("web_rubot")

        assert_equal 1, store.pending_subagent_results("web_rubot").size,
                     "an answer that was not delivered is still waiting to be read"
      end

      # A report is a turn of its own, and the actor serves one at a time. Started
      # while the reader's own turn is running, the report spends its whole life
      # in that queue — invisible to a deadline that only ever saw "no answer
      # yet" — and was thrown away instead of arriving late. So it waits: the end
      # of the turn asks again (see Web#report_later).
      def test_a_report_waits_for_the_conversation_to_be_idle
        channel = channel_with_archive(
          personas: { "rubot" => { "name" => "Rubot" } },
          messages: { "web_rubot" => [ [ "user", "Halo" ], [ "assistant", "Siap." ] ] }
        )
        channel.instance_variable_set(:@running, true)
        store = Rubot::Session.store
        store.start_subagent_run(run_id: "r1", parent_session: "web_rubot",
                                 agent_slug: "writer", task: "tulis puisi")
        store.finish_subagent_run(run_id: "r1", status: "done", result: "puisi jadi")

        live = Rubot::Web::Turn.new(id: "t-live", session_id: "web_rubot")
        channel.instance_variable_get(:@turns)["t-live"] = live
        channel.instance_variable_get(:@active)["web_rubot"] = "t-live"

        said = record_reports(channel)
        channel.report_subagents_when_done("web_rubot")

        assert_empty said, "nothing is reported over a turn that is still running"
        assert_equal 1, store.pending_subagent_results("web_rubot").size,
                     "the answers are still waiting for their turn"
      end

      # The toggle has to say whether anything is still working: the mark is the
      # only thing a reader sees without opening the panel.
      def test_the_footer_toggle_marks_a_run_as_still_working
        jobs = Rubot::Web::SubagentJobs.new
        jobs.start(session_id: "web_rubot", run_id: "r1", agent: "writer", task: "tulis puisi")
        jobs.update(session_id: "web_rubot", run_id: "r1", phase: "tool")

        html = Rubot::Web::View.render("_subagent_sheet", subagents: jobs.runs("web_rubot"))
        assert_includes html, %(<span class="subagent-run")
        assert_includes html, "subagent-spinner",
                        "a run in flight wears the drawn ring, not a typed glyph"
        assert_includes html, Rubot::I18n.t("web.subagents.running_one")

        jobs.finish(session_id: "web_rubot", run_id: "r1", status: "done", result: "puisi")
        html = Rubot::Web::View.render("_subagent_sheet", subagents: jobs.runs("web_rubot"))
        refute_includes html, %(<span class="subagent-run")
        assert_includes html, "subagent-done"
      end

      # The rows in the panel and the mark on the toggle say the same three
      # states, so the mark is drawn in one place rather than typed in three: a
      # ⟡ in the list beside a ring on the toggle would be two ways of saying
      # "running" a few pixels apart, and the typed one is the half that got too
      # small to read. Both halves are rendered here, because a helper that only
      # one caller uses is a helper that can drift without a test noticing.
      def test_the_panel_rows_wear_the_same_marks_as_the_toggle
        rows = Rubot::Web::View.render("_subagent_rows", subagents: [
          { phase: "tool", agent: "writer", line: "menulis" },
          { phase: "done", agent: "reader", line: "selesai" },
          { phase: "failed", agent: "critic", line: "gagal" }
        ])
        toggle = Rubot::Web::View.render("_subagent_state", subagents: [
          { phase: "tool", finished_at: Time.now }
        ])

        assert_equal 1, rows.scan("subagent-spinner").size,
                     "one drawn ring, for the one run still working"
        assert_includes toggle, "subagent-spinner",
                        "the toggle wears the ring the rows wear"
        assert_includes rows, "✓"
        assert_includes rows, "✗"
        refute_includes rows, "⟡"
        refute_includes toggle, "⟡"
      end

      # The mark has three states, and the reader should be able to tell "still
      # working" from "finished a moment ago" from "nothing has happened".
      def test_the_toggle_mark_settles_into_a_tick_after_the_last_run
        fresh = Rubot::Web::View.render("_subagent_state", subagents: [
          { phase: "done", finished_at: Time.now }
        ])
        assert_includes fresh, "subagent-settled"
        assert_includes fresh, "✓"
        refute_includes fresh, "subagent-run"

        failed = Rubot::Web::View.render("_subagent_state", subagents: [
          { phase: "failed", finished_at: Time.now }
        ])
        assert_includes failed, "subagent-settled-failed"
        assert_includes failed, "✗"

        stale = Rubot::Web::View.render("_subagent_state", subagents: [
          { phase: "done", finished_at: Time.now - (Rubot::Web::SubagentJobs::DONE_MARK_SECONDS + 60) }
        ])
        assert_empty stale.strip

        working = Rubot::Web::View.render("_subagent_state", subagents: [
          { phase: "tool", finished_at: Time.now }
        ])
        assert_includes working, "subagent-run"
        refute_includes working, "subagent-settled"
      end



      # The same channel, but with the archive open — which is the only thing
      # that can answer a search. Messages go through the store rather than into
      # a JSON file, so history, ranking and the message index all come from the
      # place the page reads them in production.

      # A conversation long enough to need more than one page. Each exchange is
      # a prompt and its answer, so `pairs` of them are twice as many entries.



      def test_chunk_burst_collapses_into_one_turn_event
        turn = build
        10.times { |i| turn.append_chunk("c#{i}") }
        turn.finish("c0c1c2c3c4c5c6c7c8c9")

        events = []
        turn.each_event { |type, _payload| events << type }

        assert_equal [ :turn, :done ], events
        assert_equal [ "c0c1c2c3c4c5c6c7c8c9" ], texts(turn)
      end

      # A live turn is drawn once. Everything after that is a fragment: the row
      # that grew, the row that arrived, the row that left. A page eight rounds
      # into a turn never receives the seven rounds behind it again.
      def test_a_flush_sends_only_the_rows_that_moved
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ [ "user", "Halo" ] ] })
        turn = Rubot::Web::Turn.new(id: "t-live", session_id: "web_rubot")
        turn.tool_started("file", "lib/a.rb")
        turn.tool_finished("file", true)
        turn.append_chunk("jawaban ")
        state = { order: nil, sig: nil }

        first = flushed(channel, turn, state)
        assert_includes first, "event: turn\n", "the first paint is the whole timeline"
        assert_includes first, "lib/a.rb"
        assert_match(/id="t-t-live-\d+"/, first, "every row carries the id it can be replaced by")
        refute_includes first, "hx-swap-oob", "the whole timeline is swapped as a whole"

        # The answer grows: only its own row travels.
        turn.append_chunk("bertambah")
        grown = flushed(channel, turn, state)
        assert_includes grown, "event: turn-patch\n"
        assert_match(/id="t-t-live-\d+" hx-swap-oob="true"/, grown)
        assert_includes grown, "jawaban bertambah"
        refute_includes grown, "lib/a.rb", "the rows behind it are not sent again"

        # A new row arrives: it is appended at the end. The answer above it is
        # sealed by the same call — the live flag comes off its class — so that
        # one block legitimately travels again. The call before it does not: its
        # light went out when the agent started speaking (see
        # Turn#mark_awake_call), so there is nothing left on that row to redraw.
        turn.tool_started("file", "lib/b.rb")
        added = flushed(channel, turn, state)
        assert_includes added, "event: turn-patch\n"
        assert_includes added, "lib/b.rb"
        assert_match(/id="t-t-live-\d+">/, added, "a new row needs an id, not a destination")
        refute_includes added, "beforeend", "the destination is the slot's job, not the row's"
        refute_includes added, "lib/a.rb", "a row whose light is already out is not sent again"
      end

      # A new row is placed by the slot that receives it, not by an attribute
      # on the row: that is what lets a row with no id of its own — a diff, a
      # message the reader sent mid-turn — travel in the same payload.
      def test_the_patch_slot_appends_to_the_timeline
        turn = Rubot::Web::Turn.new(id: "t-live", session_id: "web_rubot")
        turn.thinking("x")

        page = Rubot::Web::View.render("_turn", turn: turn, text: nil)

        assert_includes page, 'id="t-t-live-body"', "the container a new row is appended to"
        assert_includes page, 'hx-target="#t-t-live-body"', "the slot knows where its rows go"
        assert_includes page, 'hx-swap="beforeend"', "and that they go at the end"
      end

      # The cursor belongs to the block being written. A narration that a tool
      # row pushed out of the tail kept its blinking caret for the rest of the
      # turn, though the stylesheet says only the live block gets one. The flag
      # is derived when the rows are read, so it cannot go stale.
      def test_only_the_block_being_written_is_live
        turn = Rubot::Web::Turn.new(id: "t-live", session_id: "web_rubot")
        turn.append_chunk("narasi dulu ")
        assert_equal 1, live_blocks(turn).length, "the answer is being written"

        turn.tool_started("file", "lib/a.rb")
        assert_empty live_blocks(turn), "the narration stopped being the tail"

        turn.tool_finished("file", true)
        turn.append_chunk("jawaban ")
        blocks = live_blocks(turn)
        assert_equal 1, blocks.length, "one block, not two"
        assert_equal "jawaban ", blocks.first[:text]

        turn.finish("jawaban ")
        assert_empty live_blocks(turn), "a finished turn has no caret"
      end

      def live_blocks(turn)
        turn.items.select { |item| item[:kind] == :text && item[:live] }
      end

      # The closing response and the streamed text are the same answer, but a
      # provider's last chunk can carry a trailing newline the final response
      # dropped. Compared apart, that difference appended the whole answer under
      # the answer.
      def test_a_trailing_newline_does_not_open_a_second_answer
        turn = Rubot::Web::Turn.new(id: "t-tail", session_id: "web_rubot")
        turn.append_chunk("Selesai.\n")
        turn.finish("Selesai.")

        texts = turn.items.select { |item| item[:kind] == :text }
        assert_equal 1, texts.length, "one answer, not two"
        assert_equal "Selesai.", texts.first[:text]
      end

      # A row the turn takes back has to leave the page too: a thought too
      # quick to mention is dropped from the timeline, and an incremental page
      # would otherwise keep a "Thinking…" row that never happened.
      def test_a_row_taken_back_is_deleted_from_the_page
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ [ "user", "Halo" ] ] })
        turn = Rubot::Web::Turn.new(id: "t-live", session_id: "web_rubot")
        turn.thinking("sebentar")
        state = { order: nil, sig: nil }

        first = flushed(channel, turn, state)
        assert_includes first, "Thinking…", "the thought is on the page while it lasts"

        turn.append_chunk("jawaban") # well under THINKING_SECONDS: the row is dropped
        after = flushed(channel, turn, state)
        assert_match(/hx-swap-oob="delete:#t-t-live-\d+"/, after, "the dropped row is deleted")
        assert_includes after, "jawaban", "and the answer that replaced it is appended"
      end

      # A page that no longer holds the head of the timeline cannot be patched
      # by appending: the whole timeline is the honest answer. This is also how
      # a reader recovers from a fragment it never received.
      def test_a_page_that_fell_out_of_step_is_redrawn_whole
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ [ "user", "Halo" ] ] })
        turn = Rubot::Web::Turn.new(id: "t-live", session_id: "web_rubot")
        turn.append_chunk("satu ")
        turn.tool_started("file", "lib/a.rb")
        state = { order: nil, sig: nil }
        flushed(channel, turn, state)

        state[:order] = state[:order].reverse # the page holds the rows out of order
        out = flushed(channel, turn, state)
        assert_includes out, "event: turn\n"
        assert_includes out, "lib/a.rb"
        refute_includes out, "hx-swap-oob"
      end

      # A row that changes after it is already on the page is replaced where it
      # stands, not appended a second time. The attachments strip is the row
      # that grows sideways: a second file joins the strip that is drawn.
      def test_a_row_that_changes_is_replaced_in_place
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ [ "user", "Halo" ] ] })
        turn = Rubot::Web::Turn.new(id: "t-live", session_id: "web_rubot")
        turn.add_attachment(url: "/files/1.png", name: "one.png", id: "a1")
        state = { order: nil, sig: nil }

        first = flushed(channel, turn, state)
        assert_includes first, "one.png"
        assert_match(/id="t-t-live-\d+"/, first)

        turn.add_attachment(url: "/files/2.png", name: "two.png", id: "a2")
        after = flushed(channel, turn, state)
        assert_match(/id="t-t-live-\d+" hx-swap-oob="true"/, after, "the strip is replaced in place")
        assert_includes after, "two.png"
        assert_includes after, "one.png", "the strip is drawn whole, cards and all"
        refute_includes after, "hx-swap-oob=\"beforeend", "it is the same row, not a new one"
      end

      # One flush as the stream writer would send it: the same connection
      # state carried across calls, which is what makes the patch possible.
      def flushed(channel, turn, state)
        out = StringIO.new
        channel.write_event(out, turn, :turn, nil, state)
        out.string
      end

      def test_narration_stays_above_the_tool_row
        clock = FakeClock.new
        turn = build(clock)
        turn.append_chunk("Aku cek dulu.")
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        turn.append_chunk("Isinya tiga file.")
        turn.finish("Isinya tiga file.")

        assert_equal [ :text, :tool, :text ], kinds(turn)
        assert_equal [ "Aku cek dulu.", "Isinya tiga file." ], texts(turn)
      end

      def test_narration_block_stops_being_the_live_one_once_the_tool_starts
        turn = build
        turn.append_chunk("sebentar")
        turn.tool_started("shell_exec", "ls")

        refute turn.items.first[:live]
      end

      def test_finish_fills_text_when_nothing_was_streamed
        turn = build
        turn.finish("hanya response")

        assert_equal [ "hanya response" ], texts(turn)
      end

      def test_finish_extends_a_stream_that_stopped_short
        turn = build
        turn.append_chunk("hanya seb")
        turn.finish("hanya sebagian jawaban")

        assert_equal [ "hanya sebagian jawaban" ], texts(turn)
      end

      def test_tool_activity_transitions_from_running_to_done
        clock = FakeClock.new
        turn = build(clock)
        turn.tool_started("shell_exec", "ls -la")
        clock.advance(4.5)
        turn.tool_finished("shell_exec", true)

        entry = turn.items.first

        assert_equal :ok, entry[:state]
        assert_equal "shell_exec", entry[:name]
        assert_in_delta 4.5, entry[:elapsed], 0.001
      end

      def test_failed_tool_is_marked_failed
        turn = build
        turn.tool_started("file_ops", "nope")
        turn.tool_finished("file_ops", false)

        assert_equal :failed, turn.items.first[:state]
      end

      # The newest call keeps its light after it returns, while the turn is
      # between things: one row is alive while the page is still being written,
      # and none once it is done. A reader who looks up mid-turn should find the
      # last thing the agent did still warm, and a finished transcript still.
      def test_the_newest_call_keeps_its_light_until_the_turn_closes
        turn = build
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        turn.tool_started("file_ops", "a.rb")
        turn.tool_finished("file_ops", true)

        awake = turn.items.select { |item| item[:awake] }
        assert_equal %w[a.rb], awake.map { |item| item[:detail] },
                     "only the newest call is lit"

        turn.finish("selesai")

        refute(turn.items.any? { |item| item[:awake] }, "a closed turn has nothing moving in it")
      end

      # The agent's own words end the light. Once an answer is being written the
      # call before it is history: the answer is what the reader is watching, and
      # a machine row still glowing underneath it says work is happening where
      # the work has already been reported.
      def test_the_answer_puts_out_the_light_on_the_call_before_it
        turn = build
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        assert turn.items.last[:awake], "the call is the edge of the work until it is reported"

        turn.append_chunk("Sudah kubaca.")

        refute(turn.items.any? { |item| item[:awake] }, "the answer is the thing being written now")
      end

      # Red is the news on a failed call, and the light is a colour of its own:
      # lit, the row would sweep its red away and say "working" over the one line
      # that is not.
      def test_a_failed_call_does_not_keep_the_light
        turn = build
        turn.tool_started("file_ops", "nope")
        turn.tool_finished("file_ops", false)

        refute turn.items.last[:awake]
      end

      # One row moves at a time. The thought that is still open is already the
      # moving thing on the page, so the call before it gives the light up until
      # the thought closes — two lines glowing at once is two things asking for
      # the same eye, and the reader has one.
      def test_an_open_thought_takes_the_light_from_the_call_it_follows
        clock = FakeClock.new
        turn = build(clock)
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        assert turn.items.last[:awake], "the call is the newest thing while nothing else moves"

        clock.advance(5.0)
        turn.thinking("mikir")

        refute(turn.items.any? { |item| item[:awake] }, "the open thought is the only moving row")

        clock.advance(5.0)
        turn.tool_started("shell_exec", "pwd")

        assert_empty turn.items.select { |item| item[:awake] },
                     "the new call is running instead: still one moving row"
      end

      # The compact view can drop the newest call — an edit that changed nothing
      # has no row of its own — and then no call is lit at all. Lighting whatever
      # row happened to survive would point at work from an earlier round.
      def test_the_light_lands_on_no_row_when_the_newest_call_was_dropped
        clock = FakeClock.new
        turn = Turn.new(id: "t1", session_id: "s1", tool_output: "compact", clock: clock)
        turn.tool_started("file_ops", "catatan.md", op: "write")
        turn.tool_finished("file_ops", true)
        clock.advance(5.0)
        turn.thinking("mikir")
        turn.tool_started("file_ops", "a.rb", op: "edit")
        turn.tool_finished("file_ops", true)

        rows = turn.items
        assert_equal [ "catatan.md" ], rows.select { |item| item[:kind] == :tool }.map { |item| item[:detail] },
                     "the empty edit is not drawn"
        refute(rows.any? { |item| item[:awake] }, "and nothing pretends to be the newest call")
      end

      # --- thinking -------------------------------------------------------

      def test_quick_thought_leaves_no_visible_row
        clock = FakeClock.new
        turn = build(clock)
        turn.thinking("sebentar")
        clock.advance(2.0)
        turn.append_chunk("jawaban")

        # No clock to show, no row: the reader only ever sees the pauses that
        # took long enough to be worth a line.
        assert_equal [ :text ], kinds(turn)
        assert_equal "jawaban", turn.items.last[:text]
      end

      def test_thought_past_the_threshold_is_kept_with_its_duration
        clock = FakeClock.new
        turn = build(clock)
        turn.thinking("sebentar")
        clock.advance(5.0)
        turn.tool_started("shell_exec", "ls")

        item = turn.items.first

        assert_equal :thinking, item[:kind]
        refute_nil item[:closed_at]
        assert_in_delta 5.0, item[:elapsed], 0.001
      end

      # The answer arriving is the end of the thought: a long answer must not
      # keep a clock running over reasoning that already stopped.
      def test_the_answer_closes_an_open_thought
        clock = FakeClock.new
        turn = build(clock)
        turn.thinking("sebentar")
        clock.advance(6.0)
        turn.append_chunk("jawaban")

        item = turn.items.first

        assert_equal :thinking, item[:kind]
        refute_nil item[:closed_at]
      end

      # Reasoning fragments arrive faster than anyone can read them, and none
      # of them is content: only the first one opens the block.
      def test_repeated_reasoning_fragments_open_only_one_block
        turn = build
        20.times { turn.thinking("fragmen") }

        assert_equal [ :thinking ], kinds(turn)
      end

      # An answer that is still being written is not interrupted by a thought:
      # see below. Once the answer is closed, a thought is a real pause between
      # rounds, and it earns its row — and the answer that follows opens a new
      # block under it rather than continuing the sealed one.
      def test_a_thought_after_a_finished_answer_opens_its_own_row
        turn = build
        turn.append_chunk("awal")
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        turn.thinking("lagi")

        assert_equal [ :text, :tool, :thinking ], kinds(turn)
        refute turn.items.first[:live]
      end

      # The same reasoning fragment, arriving mid-answer: a provider that
      # interleaves its reasoning between two chunks of one word used to split
      # the answer there, and the page drew the seam as a newline ("S", then
      # "aya"). The fragment is dropped, the answer keeps its block.
      def test_a_thought_does_not_interrupt_an_answer_being_written
        turn = build
        turn.append_chunk("S")
        turn.thinking("lagi")
        turn.append_chunk("aya")

        assert_equal [ :text ], kinds(turn)
        assert_equal "Saya", turn.items.first[:text]
        assert turn.items.first[:live], "the answer is still arriving"
      end

      # A provider can interleave its reasoning with the answer, so a thought
      # opens between two chunks of one word. Closed a moment later it is too
      # quick to record and leaves nothing behind but a sealed block — and the
      # rest of the answer used to open a second block below it, which the page
      # drew as a newline in the middle of a word ("Sa", then "ya").
      def test_a_quick_thought_does_not_split_the_answer
        turn = build
        turn.append_chunk("Sa")
        turn.thinking("sebentar")
        turn.append_chunk("ya")

        assert_equal [ :text ], kinds(turn)
        assert_equal "Saya", turn.items.first[:text]
      end

      # A steering message lands in the middle of a round, and a round is not
      # over because the reader spoke. Both blocks used to be found by looking
      # at the last row, which the bubble now *was*: the thought that was open
      # above it never got closed — its clock spun for the rest of the turn —
      # and the next fragment opened a second thought row under the bubble.
      def test_steering_during_a_thought_closes_that_thought_and_opens_no_other
        clock = FakeClock.new
        turn = build(clock)
        turn.thinking("mulai")
        clock.advance(1.0)
        turn.add_steer("Pakai template Grey")
        clock.advance(4.0)
        turn.append_chunk("jawaban")

        assert_equal [ :thinking, :steer, :text ], kinds(turn)
        thought = turn.items.first
        refute_nil thought[:closed_at], "the thought the reader interrupted must still end"
        assert_in_delta 5.0, thought[:elapsed], 0.001
      end

      # The same seam, seen on the answer: a chunk that arrives after the bubble
      # belongs to the block that was already being written, not to a new one
      # below it — otherwise the sentence breaks at the moment the reader typed.
      def test_steering_mid_answer_keeps_the_answer_in_one_block
        turn = build
        turn.append_chunk("Saya ")
        turn.add_steer("Pakai template Grey")
        turn.append_chunk("pakai yang Grey.")

        assert_equal [ :text, :steer ], kinds(turn)
        assert_equal "Saya pakai yang Grey.", turn.items.first[:text]
      end

      # A bubble is not a shield for content it sits above: a tool row still
      # ends the round, and the answer that follows the tool opens below it.
      def test_a_steer_does_not_join_an_answer_to_the_block_above_a_tool
        turn = build
        turn.append_chunk("mau jalankan")
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        turn.add_steer("pakai yang Grey")
        turn.append_chunk("selesai")

        assert_equal [ :text, :tool, :steer, :text ], kinds(turn)
      end

      # The seal still means what it says: once a tool has run, the answer that
      # follows is a new block below the row, not more of the narration above it.
      def test_a_tool_call_still_separates_the_answer_that_follows_it
        turn = build
        turn.append_chunk("mau jalankan")
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        turn.append_chunk("selesai")

        assert_equal [ :text, :tool, :text ], kinds(turn)
      end

      def test_ask_confirm_blocks_until_answered
        turn = build
        answer = nil

        thread = Thread.new { answer = turn.ask_confirm("shell_exec", "deletes files") }
        deadline = Time.now + 2
        sleep 0.01 until turn.ask_prompt || Time.now > deadline

        refute_nil turn.ask_prompt
        turn.answer_confirm(false)
        thread.join(2)

        refute answer
        assert_nil turn.ask_prompt
      end

      # --- the question ---------------------------------------------------
      #
      # The same wait as the confirmation above, with an answer that is a
      # choice or a sentence. What these tests hold is the turn's side of it:
      # what the ask reports when the reader answers, and what it reports when
      # the reader does not.

      # Waits for the pending ask without sleeping on a fixed guess.
      def wait_for_ask(turn)
        deadline = Time.now + 2
        sleep 0.005 until turn.ask_prompt || Time.now > deadline
        turn.ask_prompt
      end

      def ask_options
        [ { label: "New file", description: "Add 019_ask.sql" },
          { label: "Extend 018", description: "Rebuild it in place" } ]
      end

      def test_a_question_publishes_itself_and_carries_the_options
        turn = build
        outcome = nil

        thread = Thread.new do
          outcome = turn.ask_question(question: "Where should it go?", options: ask_options)
        end

        prompt = wait_for_ask(turn)
        refute_nil prompt
        assert_equal :question, prompt[:kind]
        assert_equal "Where should it go?", prompt[:question]
        assert_equal [ "New file", "Extend 018" ], prompt[:options].map { |option| option[:label] }

        turn.answer_ask({ outcome: :option, index: 1 })
        thread.join(2)

        # The label travels back with the choice: the browser sends a number,
        # the model reads words.
        assert_equal({ outcome: :option, index: 1, label: "Extend 018" }, outcome)
        assert_nil turn.ask_prompt
      end

      def test_a_custom_answer_arrives_as_the_words_the_reader_typed
        turn = build
        outcome = nil

        thread = Thread.new { outcome = turn.ask_question(question: "Name?", options: ask_options) }
        wait_for_ask(turn)
        turn.answer_ask({ outcome: :custom, text: "call it something else" })
        thread.join(2)

        assert_equal({ outcome: :custom, text: "call it something else" }, outcome)
      end

      def test_a_question_nobody_answers_expires
        turn = build
        outcome = nil

        thread = Thread.new do
          outcome = turn.ask_question(question: "Anyone?", options: ask_options, timeout: 0.05)
        end
        thread.join(2)

        assert_equal({ outcome: :expired }, outcome)
        assert_nil turn.ask_prompt
      end

      # A turn that ends under a question is not a question that expired: the
      # reader was still deciding, and the turn went away.
      def test_a_turn_that_goes_away_cancels_the_question_it_was_waiting_on
        turn = build
        outcome = nil

        thread = Thread.new { outcome = turn.ask_question(question: "Anyone?", options: ask_options) }
        wait_for_ask(turn)
        turn.finish("done")
        thread.join(2)

        assert_equal({ outcome: :cancelled }, outcome)
        assert_nil turn.ask_prompt
      end

      def test_an_open_question_carries_no_options
        turn = build
        outcome = nil

        thread = Thread.new { outcome = turn.ask_question(question: "What should I call it?") }
        prompt = wait_for_ask(turn)

        assert_equal [], prompt[:options]
        turn.answer_ask({ outcome: :custom, text: "anything" })
        thread.join(2)

        assert_equal({ outcome: :custom, text: "anything" }, outcome)
      end

      # Stopping a turn is the one cancellation that arrives from another
      # thread while the question is up, so it has to release the wait itself.
      def test_stopping_the_turn_cancels_the_question_it_is_waiting_on
        turn = build
        outcome = nil

        thread = Thread.new { outcome = turn.ask_question(question: "Anyone?", options: ask_options) }
        wait_for_ask(turn)

        assert turn.cancel_pending_ask, "a pending question is released"
        thread.join(2)

        assert_equal({ outcome: :cancelled }, outcome)
      end

      # Stopping while nothing is waiting must not arm the next question to
      # answer itself.
      def test_stopping_with_nothing_pending_leaves_the_next_question_alone
        turn = build

        refute turn.cancel_pending_ask, "nothing was waiting"

        outcome = nil
        thread = Thread.new do
          outcome = turn.ask_question(question: "Anyone?", options: ask_options, timeout: 0.05)
        end
        thread.join(2)

        assert_equal({ outcome: :expired }, outcome)
      end

      # A click that outlives its question must not answer the next one: the
      # token names the ask it belongs to.
      def test_an_answer_for_an_older_question_is_dropped
        turn = build
        first = nil
        thread = Thread.new { first = turn.ask_question(question: "First?", options: ask_options) }
        old_token = wait_for_ask(turn)[:token]
        turn.answer_ask({ outcome: :option, index: 0 }, token: old_token)
        thread.join(2)

        second = nil
        two = Thread.new { second = turn.ask_question(question: "Second?", options: ask_options) }
        wait_for_ask(turn)

        refute turn.answer_ask({ outcome: :option, index: 1 }, token: old_token),
               "a late answer is refused"
        assert_nil second, "the second question is still waiting"

        turn.answer_ask({ outcome: :option, index: 1 })
        two.join(2)
        assert_equal "Extend 018", second[:label]
      end

      # A prompt typed while a question is up is that question's answer: the box
      # the reader types in is the box a custom answer goes in, and starting a
      # turn out of it would cut the ask off and leave it standing.
      def test_a_prompt_typed_while_a_question_is_up_answers_it
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ [ "user", "Halo" ] ] })
        turn = Rubot::Web::Turn.new(id: "tabc", session_id: "web_rubot")
        channel.instance_variable_get(:@turns)["tabc"] = turn

        answer = nil
        thread = Thread.new do
          answer = turn.ask_question(question: "Name it?", options: ask_options)
        end
        wait_for_ask(turn)

        res = FakeResponse.new
        channel.create_turn(turn_request("something else"), res, "web_rubot")
        thread.join(2)

        assert_equal 204, res.status
        assert_equal({ outcome: :custom, text: "something else" }, answer)
        assert_equal 1, channel.instance_variable_get(:@turns).size,
                     "answering a question must not start a second turn"
      end

      # With nothing waiting, the same POST starts a turn as it always did.
      def test_a_prompt_with_no_question_up_still_starts_a_turn
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ [ "user", "Halo" ] ] })
        channel.define_singleton_method(:owner_slug) { |_sid| "rubot" }
        # The turn itself is not this test's subject: what matters is that the
        # POST was not taken as an answer, so the thread is stilled here.
        channel.define_singleton_method(:run_turn) { |*_args| }

        res = FakeResponse.new
        channel.create_turn(turn_request("halo lagi"), res, "web_rubot")

        refute_equal 204, res.status, "a prompt with no question is a turn, not an answer"
        assert_equal 1, channel.instance_variable_get(:@turns).size
      end

      # Two questions in one turn must not read each other's answer.
      def test_a_second_question_waits_for_its_own_answer
        turn = build
        first = nil
        second = nil

        one = Thread.new { first = turn.ask_question(question: "First?", options: ask_options) }
        wait_for_ask(turn)
        turn.answer_ask({ outcome: :option, index: 0 })
        one.join(2)

        two = Thread.new { second = turn.ask_question(question: "Second?", options: ask_options) }
        wait_for_ask(turn)
        turn.answer_ask({ outcome: :option, index: 1 })
        two.join(2)

        assert_equal 0, first[:index]
        assert_equal 1, second[:index]
        assert_equal "Extend 018", second[:label]
      end

      def test_each_event_returns_after_done
        turn = build
        turn.finish("done")

        types = []
        turn.each_event { |type, _| types << type }

        assert_equal [ :done ], types
      end
    end
  end
end
