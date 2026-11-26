# frozen_string_literal: true

require "test_helper"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # The status row and the live numbers it carries across a turn.
    class TestWebStatus < Minitest::Test
      include WebChannelSupport

      # The compaction note is drawn in Indonesian here, the language the view
      # was written in before the dictionary existed; the switch itself, en
      # against id, is test_i18n.rb's business. Pinning it keeps these tests
      # reading the wording instead of matching whichever language is default.
      def setup
        super
        Rubot::I18n.locale = "id"
      end

      def teardown
        Rubot::I18n.locale = Rubot::I18n::DEFAULT_LOCALE
        super
      end

      # --- status row -----------------------------------------------------

      # The row the TUI footer became: same three figures, words replaced by
      # drawn icons. `metrics` is what makes that possible without the channel
      # parsing a string built for a terminal.
      def test_usage_metrics_drops_the_words
        report = { cost: { "total" => 1.23456 }, requests: 2, prompt_tokens: 1000,
                   cache_hit_rate: 0.92, context_percent: 8.24, context_window: 200_000 }

        metrics = Rubot::UsageReport.metrics(report)

        assert_equal "$1.235", metrics[:cost]
        assert_equal "92%", metrics[:cache]
        assert_equal "8.2%", metrics[:context]
      end

      # The footer's text form stays exactly as it was, so the TUI is untouched.
      def test_footer_still_renders_the_text_form
        report = { cost: { "total" => 0.0004 }, requests: 1, prompt_tokens: 1000,
                   cache_hit_rate: 0.6, context_percent: 8.2, context_window: 200_000,
                   provisional: true }

        assert_equal "~$0.0004 · cache 60% · ctx 8.2%", Rubot::UsageReport.footer(report)
      end

      # Nothing known yet is not zero: `nil` tells the caller to show a dash.
      def test_usage_metrics_reports_unknown_figures_as_nil
        metrics = Rubot::UsageReport.metrics({ requests: 0, prompt_tokens: 0, context_used: 900 })

        assert_nil metrics[:cost]
        assert_nil metrics[:cache]
        assert_equal "900", metrics[:context], "a raw token count is the honest fallback"
      end

      def test_status_row_renders_three_icons_and_no_words
        html = View.render("_usage", cost: "$0.023", cache: "99.6%", ctx: "2.5%")

        assert_equal 3, html.scan(%(<svg class="metric-icon")).size
        assert_includes html, "$0.023"
        assert_includes html, "99.6%"
        assert_includes html, "2.5%"
        assert_includes html, %(id="usage")

        # The label must live in the tooltip, not in the row. The tooltip also
        # has to say which scope each figure covers: the cost is the session
        # total while the cache share is the latest request, and a reader who
        # does not know that reads the pair as a contradiction.
        assert_includes html, "Total biaya sesi ini, akumulatif"
        assert_includes html, "permintaan terakhir — bukan rata-rata sesi"
        assert_includes html, "context window model"
        refute_match(%r{class="value">cost}, html)
        refute_includes html, "cache 99"
      end

      # The row is three figures and nothing else. Why the last request missed
      # is a log line (see Session#log_cache_cause): a phrase like "cache
      # kedaluwarsa (>5 menit)" in a row of figures reads as a fault, and half
      # the time there is nothing to fix — the provider's five minutes simply
      # ran out.
      def test_status_row_never_names_the_cause_of_a_miss
        html = View.render("_usage", cost: "$0.1", cache: "0%", ctx: "1%")

        refute_includes html, "metric-cause"
        refute_includes html, "model berganti"
        refute_includes html, "kedaluwarsa"
      end

      # Each icon is a different drawing; a copy-paste slip would make two
      # figures indistinguishable at a glance.
      # The button behind the usage panel is the page's door out of the pinned
      # prompt (see Agent#repin_system_prompt). Three answers, because the repo
      # has three states and a reader has to be able to tell them apart.
      def test_the_repin_button_reports_what_it_did
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        asked = 0
        handle = Object.new
        handle.define_singleton_method(:repin_system_prompt) { asked += 1; true }
        channel.define_singleton_method(:session_for) { |_sid| handle }

        res = FakeResponse.new
        channel.repin_prompt(res, "web_kanyaah")

        assert_equal 1, asked, "the button has to ask, not just describe"
        assert_includes res.body, "dibangun ulang"
      end

      # A turn owns the actor; a request queued behind it would look like a hang,
      # and the running answer needs no repin.
      def test_the_repin_button_refuses_while_a_turn_is_running
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }
        channel.define_singleton_method(:session_running?) { |_sid| true }

        res = FakeResponse.new
        channel.repin_prompt(res, "web_kanyaah")

        assert_includes res.body, "Turn masih berjalan"
        refute_includes res.body, "akan dibangun ulang"
      end

      def test_the_manual_compaction_button_posts_to_a_route_that_reaches_the_handler
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        asked = Queue.new
        handle = Object.new
        handle.define_singleton_method(:compact_session) do
          asked << :asked
          { summarized_messages: 8 }
        end
        channel.define_singleton_method(:session_for) { |_sid| handle }

        req = Struct.new(:query) do
          def [](key) = key == "HX-Request" ? "true" : nil
        end.new({})
        res = FakeResponse.new
        channel.send(:dispatch, req_with_path(req, "/s/web_kanyaah/compact", "POST"), res)

        assert_equal 204, res.status
        # WEBrick rejects a 204 with no body as LengthRequired, which the
        # browser sees as a failed request and the button as doing nothing.
        assert_equal "", res.body
        # The request is answered at once; the summarizer runs in the background
        # and must not hold the response (or the page's refresh) open.
        assert_nil res.headers["HX-Refresh"]
        assert_equal :asked, asked.pop, "the button has to ask, not just describe"
      end

      def test_a_second_press_is_refused_while_a_compaction_is_running
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        release = Queue.new
        asked = Queue.new
        handle = Object.new
        handle.define_singleton_method(:compact_session) do
          asked << :asked
          release.pop
          { summarized_messages: 8 }
        end
        channel.define_singleton_method(:session_for) { |_sid| handle }

        first = FakeResponse.new
        channel.compact_session_now(first, "web_kanyaah", form_post({}))
        assert_equal 204, first.status
        assert_equal :asked, asked.pop

        # The first compaction is still in flight; a second press must be
        # refused instead of starting a second summarizer against the same
        # transcript.
        second = FakeResponse.new
        channel.compact_session_now(second, "web_kanyaah", form_post({}))
        assert_includes second.body, "Turn masih berjalan"
        assert asked.empty?, "only the first press may reach the summarizer"

        release << :go
        sleep 0.05
      end

      def test_the_manual_compaction_button_refuses_while_a_turn_is_running
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }
        channel.define_singleton_method(:session_running?) { |_sid| true }

        res = FakeResponse.new
        channel.compact_session_now(res, "web_kanyaah", form_post({}))

        assert_includes res.body, "Turn masih berjalan"
        refute_includes res.body, "berhasil diringkas"
      end

      def test_the_manual_compaction_button_says_when_there_is_nothing_to_summarize
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        handle = Object.new
        handle.define_singleton_method(:compact_session) { nil }
        channel.define_singleton_method(:session_for) { |_sid| handle }

        queue = Queue.new
        channel.listen_for_events("web_kanyaah", queue)

        res = FakeResponse.new
        channel.compact_session_now(res, "web_kanyaah", form_post({}))

        assert_equal 204, res.status
        assert_nil res.headers["HX-Refresh"]
        # The reason is pushed over SSE, not held in the response body.
        running = queue.pop
        assert_includes running[1], "Merangkum percakapan"
        cleared = queue.pop
        assert_includes cleared[1], 'id="compaction-slot"'
        note = queue.pop
        assert_equal :"compact-note", note[0]
        assert_includes note[1], 'id="compact-note"'
        assert_includes note[1], "terlalu pendek"
        assert_equal :"compact-done", queue.pop[0]
      end

      def test_the_manual_compaction_button_is_drawn_in_the_usage_panel
        html = render_page

        assert_includes html, 'hx-post="/s/web_rubot/compact"'
        assert_includes html, 'title="Ringkas konteks sekarang"'
        assert_includes html, 'id="compaction-slot"'
      end

      def test_the_compact_button_sits_right_after_the_context_usage_metric
        html = render_page

        context = html.index('title="Porsi context window model yang terpakai permintaan berikutnya"')
        compact = html.index('hx-post="/s/web_rubot/compact"')
        refute_nil context
        refute_nil compact
        assert_operator compact, :>, context, "the button belongs beside the context figure"
        # Nothing but the closing metric span and the button may sit between.
        assert_operator compact - context, :<, 600
      end

      def test_the_composer_is_disabled_while_compacting
        erb = File.read(File.expand_path("../lib/rubot/web/views/_composer.erb", __dir__))

        assert_includes erb, 'x-bind:disabled="!text.trim() || compacting"'
      end

      # The note slot sits between the compact button and the two sheets, and a
      # flex row charges its gap on both sides of every item, empty or not. Left
      # in the row when it says nothing, it made the button read further from
      # the sheets than they are from each other.
      def test_an_empty_compaction_note_does_not_hold_a_gap
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        assert_match(/#compact-note:empty\s*\{\s*display:\s*none;/, css)
      end

      # The button is pressed while the page is idle, so the progress row goes
      # out over the always-on /events stream before the summarizer is called.
      # A handle that blocks lets us assert the reader sees "in progress" while
      # the work is still running, not only once the result is in hand.
      def test_the_manual_compaction_button_broadcasts_progress_then_the_seam
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        release = Queue.new
        handle = Object.new
        handle.define_singleton_method(:compact_session) do
          release.pop
          { summarized_messages: 8, context_before: 2029, context_after: 1565 }
        end
        channel.define_singleton_method(:session_for) { |_sid| handle }

        queue = Queue.new
        channel.listen_for_events("web_kanyaah", queue)

        res = FakeResponse.new
        channel.compact_session_now(res, "web_kanyaah", form_post({}))

        # The handler answered before the summarizer was released: the page is
        # free to refresh while the work continues in the background.
        assert_equal 204, res.status
        running = queue.pop
        assert_includes running[1], "compaction-row is-running"
        assert_includes running[1], "Merangkum percakapan"

        release << :go

        seam = queue.pop
        assert_includes seam[1], "Konteks diringkas."
        assert_includes seam[1], "2029 → 1565 token"
        refute_includes seam[1], "pesan diringkas"
        # The explicit "done" line under the button is the confirmation the
        # reader was waiting for.
        note = queue.pop
        assert_equal :"compact-note", note[0]
        assert_includes note[1], "berhasil diringkas"
        # The composer is held closed for the whole compaction and there is no
        # reload any more, so it must be released explicitly.
        done = queue.pop
        assert_equal :"compact-done", done[0]
        # The footer's context figure is refreshed in place over /events, so
        # the percentage moves without a reload.
        usage = queue.pop
        assert_equal :usage, usage[0]
        assert_includes usage[1], 'id="usage"'
      end

      def test_the_manual_compaction_button_clears_the_progress_row_when_there_is_nothing_to_summarize
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        handle = Object.new
        handle.define_singleton_method(:compact_session) { nil }
        channel.define_singleton_method(:session_for) { |_sid| handle }

        queue = Queue.new
        channel.listen_for_events("web_kanyaah", queue)

        res = FakeResponse.new
        channel.compact_session_now(res, "web_kanyaah", form_post({}))

        running = queue.pop
        assert_includes running[1], "Merangkum percakapan"
        cleared = queue.pop
        assert_includes cleared[1], 'id="compaction-slot"'
        refute_includes cleared[1], "compaction-row"
        note = queue.pop
        assert_equal :"compact-note", note[0]
        assert_includes note[1], 'id="compact-note"'
        assert_includes note[1], "terlalu pendek"
        # No reload (the transcript was not rewritten), but the composer must
        # still be released so Send is not left disabled forever.
        done = queue.pop
        assert_equal :"compact-done", done[0]
        assert_equal "done", done[1]
        assert queue.empty?
      end

      def test_the_page_has_a_slot_for_the_compaction_reload_signal
        html = render_page

        assert_includes html, 'id="compaction-refresh"'
        assert_includes html, 'sse-swap="refresh"'
      end

      def test_the_page_has_a_visible_slot_for_the_compaction_note
        html = render_page

        assert_includes html, 'id="compact-note"'
        assert_includes html, 'sse-swap="compact-note"'
      end

      # A restart sends TERM, and stopping has to reach the work that is not a
      # request: the learning queue may be naming a conversation or writing
      # memory when the signal arrives. The order matters too — it is drained
      # while the process still has a store to write to, before the loop that
      # owns everything lets go. The three seconds are the share of the restart's
      # window the queue gets; past it the KILL would cut the drain anyway.
      def test_stopping_drains_the_learning_queue_before_the_server_loop
        channel = channel_with_sessions(personas: { "rubot" => { "name" => "Rubot" } })
        channel.instance_variable_set(:@running, true)

        calls = []
        channel.define_singleton_method(:stop_learning_worker) { |timeout: nil| calls << [ :learning, timeout ] }
        server = Object.new
        server.define_singleton_method(:shutdown) { calls << [ :server, nil ] }
        channel.instance_variable_set(:@server, server)

        channel.stop

        assert_equal [ [ :learning, 3 ], [ :server, nil ] ], calls
        refute channel.running?
      end

      # htmx finds a `sse-swap` element by walking up to the one that owns the
      # EventSource, and nowhere else. A slot drawn outside that element is
      # silently orphaned: the server pushes, htmx knows nobody is listening, and
      # the page keeps showing what it had. That is how the footer's subagent
      # sheet went missing — drawn correctly, pushed correctly, heard by nobody —
      # so the rule is asserted here instead of remembered.
      def test_every_idle_slot_sits_inside_the_event_stream
        html = render_page
        stream = html[/<div class="session-events".*?<\/div>/m]

        assert stream, "the idle page carries an event stream of its own"
        slots = html.scan(/sse-swap="([^"]+)"/).flatten
        assert_includes slots, "subagent-sheet"
        assert_includes slots, "compact-note"
        assert_equal slots.sort, stream.scan(/sse-swap="([^"]+)"/).flatten.sort,
                     "a slot outside the stream is a slot that never hears anything"
      end

      # The footer's context figure is refreshed over the always-on /events
      # stream, so that stream needs its own usage slot. The one inside a turn
      # only exists while that turn is on screen and cannot serve a manual
      # compaction, which has no turn at all.
      def test_the_events_stream_has_a_usage_slot
        html = render_page

        events = html[/<div class="session-events".*?<\/div>/m]
        refute_nil events, "the always-on events stream must be on the page"
        assert_includes events, 'sse-swap="usage"',
                        "the context figure must be refreshable without a reload"
      end

      def test_the_compact_button_disables_itself_while_compacting
        erb = File.read(File.expand_path("../lib/rubot/web/views/_compact_button.erb", __dir__))

        assert_includes erb, 'hx-disabled-elt="this"'
        assert_includes erb, 'x-bind:disabled="$store.turn.compacting"'
      end

      # A compaction that raised has to leave the reader a line they can act on,
      # so the failure branch is rendered here rather than only found in the
      # template's source.
      def test_the_compact_note_has_a_failure_branch
        html = View.render("_compact_note", state: :error)

        assert_includes html, "Ringkasan gagal"
        refute_includes html, View.render("_compact_note", state: :done)
      end

      def test_broadcast_refresh_reaches_only_the_page_showing_that_session
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        mine = Queue.new
        elsewhere = Queue.new
        channel.listen_for_events("web_kanyaah", mine)
        channel.listen_for_events("web_english-tutor", elsewhere)

        channel.broadcast_refresh("web_kanyaah")

        assert_equal 1, mine.size
        item = mine.pop
        assert_equal :refresh, item[0]
        assert_equal "reload", item[1]
        assert elsewhere.empty?, "another session's page must not reload"
      end

      def test_compaction_broadcast_only_reaches_the_page_showing_that_session
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        mine = Queue.new
        elsewhere = Queue.new
        channel.listen_for_events("web_kanyaah", mine)
        channel.listen_for_events("web_english-tutor", elsewhere)

        channel.compaction_broadcast("web_kanyaah", nil)

        refute mine.empty?
        assert elsewhere.empty?, "another session's thread must not be touched"
      end

      def test_the_repin_button_says_when_there_was_nothing_pinned
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        handle = Object.new
        handle.define_singleton_method(:repin_system_prompt) { false }
        channel.define_singleton_method(:session_for) { |_sid| handle }

        res = FakeResponse.new
        channel.repin_prompt(res, "web_kanyaah")

        assert_includes res.body, "belum di-pin"
      end

      def test_each_usage_icon_draws_a_different_shape
        bodies = View::SVG_ICONS.values

        assert_equal 8, bodies.size,
                     "cost, cache, context, the report, the allowance, compact, subagent and loop"
        assert_equal 8, bodies.uniq.size
        bodies.each { |body| assert_includes body, "<", "every icon needs at least one shape" }
      end

      # The report's button used to draw its own three bars, a fraction of a
      # millimetre away from the bars that mean "context": two different figures
      # announced by the same shape. It draws the shared mark now, so the shapes
      # can only collide by being added to the one set that is checked above.
      def test_the_report_button_draws_the_shared_mark
        erb = File.read(File.expand_path("../lib/rubot/web/views/_usage_sheet.erb", __dir__))
        toggle = erb[/<summary class="usage-toggle".*?<\/summary>/m]

        refute_nil toggle, "the report button is missing from the usage sheet"
        assert_includes toggle, "usage_icon(:usage)"
        refute_includes toggle, "<path", "the button must not carry geometry of its own"
        refute_includes toggle, "<rect"
      end

      # The out-of-band copy has to carry the marker, while the page's own copy
      # must not — otherwise the first swap would try to swap twice.
      def test_usage_markup_marks_the_fragment_as_out_of_band
        channel = Rubot::Channels::Web.new(channel_config: {})
        markup = channel.usage_markup_with({ cost: "$0.1", cache: "50%", ctx: "1%" })

        assert_includes markup, %(hx-swap-oob="true")
        refute_includes View.render("_usage", cost: "$0.1", cache: "50%", ctx: "1%"), "hx-swap-oob"
      end

      # The figures have to move while the turn is still running, and the
      # session cannot be asked for them then: in actor mode the turn owns the
      # Ractor. The report the agent pushes is what the row is drawn from.
      def test_the_status_row_is_drawn_from_the_live_report
        channel = Rubot::Channels::Web.new(channel_config: {})
        report = { cost: { "total" => 0.0004 }, requests: 1, prompt_tokens: 1000,
                   cache_hit_rate: 0.6, context_percent: 8.2, context_window: 200_000,
                   provisional: true }

        markup = channel.usage_markup_from(report)

        assert_includes markup, "~$0.0004", "an estimate is marked as one"
        assert_includes markup, "60%"
        assert_includes markup, "8.2%"
        assert_includes markup, %(hx-swap-oob="true"),
                        "it lands on #usage from outside the turn"
      end

      # The panel is 47% of the payload and nobody reads a breakdown that moves
      # four times a second, so a report for a request still in flight carries
      # the row alone. It follows with the report that lands at the end of the
      # round, which is why an open panel still moves — once per request.
      def test_a_live_report_carries_the_row_without_the_panel
        channel = Rubot::Channels::Web.new(channel_config: {})
        live = { cost: { "total" => 0.0004 }, requests: 1, prompt_tokens: 1000,
                 cache_hit_rate: 0.6, context_percent: 8.2, context_window: 200_000,
                 provisional: true }

        markup = channel.usage_markup_from(live)

        assert_includes markup, "8.2%", "the row still moves"
        refute_includes markup, "usage-facts", "the breakdown waits for a measured report"
      end

      def test_a_measured_report_carries_the_panel
        channel = Rubot::Channels::Web.new(channel_config: {})
        measured = { cost: { "total" => 0.0004 }, requests: 1, prompt_tokens: 1000,
                     cache_hit_rate: 0.6, context_percent: 8.2, context_window: 200_000,
                     provisional: false }

        markup = channel.usage_markup_from(measured)

        assert_includes markup, "usage-facts", "a measured report brings the breakdown with it"
        assert_includes markup, %(hx-swap-oob="true")
      end

      # Nothing to draw must not become an empty swap: that would blank the
      # row and lose the last figure the reader had.
      def test_an_empty_live_report_draws_nothing
        channel = Rubot::Channels::Web.new(channel_config: {})

        assert_nil channel.usage_markup_from(nil)
        assert_nil channel.usage_markup_from("bukan report")
      end
      # --- the mark that a run is working --------------------------------

      # The ring on the subagent toggle is drawn large enough to be seen, which
      # is exactly the kind of mark that quietly makes a row taller — and this
      # row has the composer sitting on top of it. Two properties keep that from
      # happening and neither is visible in the markup, so they are held here:
      # the box around the ring is pinned to the line's height rather than to the
      # ring's, and the ring itself is the size the working row's mark is, so the
      # two are read as one language instead of two sizes a few pixels apart.
      #
      # The numbers are read out of the stylesheet rather than restated, because
      # a test that repeats "9px" is a test that passes while the rule says 13.
      def test_the_running_ring_is_the_size_of_the_working_mark
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        box = css[/^\.subagent-run \{[^}]*\}/]
        ring = css[/^\.subagent-run \.subagent-spinner \{[^}]*\}/]
        row = css[/^\.row \{[^}]*\}/]
        working_mark = css[/^\.row \.mark \{[^}]*\}/]
        row_ring = css[/^\.subagent-mark \.subagent-spinner \{[^}]*\}/]

        refute_nil box, "the .subagent-run rule is missing from app.css"
        refute_nil ring, "the ring has no rule of its own"
        refute_nil row, "the .row rule is missing from app.css"
        refute_nil working_mark, "the working mark has no rule of its own"

        assert_includes box, "height: 1em",
                        "the box follows the line, not the ring: a box that grew with the " \
                        "ring pushed the toggle past the status row's floor and moved the composer"

        drawing = working_mark[/width:\s*([\d.]+)em/, 1].to_f
        line = row[/font-size:\s*([\d.]+)px/, 1].to_f
        width = ring[/width:\s*([\d.]+)px/, 1].to_f
        height = ring[/height:\s*([\d.]+)px/, 1].to_f

        assert_operator drawing, :>, 0, "the working mark is sized against its line"
        assert_operator width, :>, 0, "the ring is drawn at a size of its own"
        assert_in_delta line * drawing, width, 1.0,
                        "the toggle's ring and the working row's mark are one size, or the " \
                        "one that is a note reads as a second thing to look at"
        assert_in_delta width, height, 0.01, "a ring that is not square wobbles as it turns"
        assert_operator width, :<=, line,
                        "the ring must fit the line it is pinned to; 1em is the line"

        refute_nil row_ring, "the ring inside a row has no rule of its own"
        assert_includes row_ring, "width: 0.8em",
                        "a row's ring is sized by the line it sits in, like the working mark"
      end
    end
  end
end
