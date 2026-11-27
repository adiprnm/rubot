# frozen_string_literal: true

require "test_helper"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # The view objects the routes render: page chrome, tool rows, diffs and the status they show.
    class TestWebViews < Minitest::Test
      include WebChannelSupport

      # --- the session model and thinking choice ---------------------------

      # Two selects under the composer put a form on the page for a choice made
      # once per conversation. One control reports the choice and a dialog holds
      # it: the model list is long enough to need a field that searches it.
      def test_the_session_choice_is_one_control_opening_a_dialog
        html = View.render("_session_settings",
                           session_id: "web_rubot", token_query: "?token=t",
                           model_choices: [ { value: "m-1", name: "Model Satu", label: "Model Satu (m-1)" },
                                            { value: "m-2", name: "Model Dua", label: "Model Dua (m-2)" } ],
                           session_model: "m-2", session_thinking: "high")

        refute_includes html, "<select", "the two selects are gone"
        assert_includes html, "data-settings-open", "one control opens the choice"
        assert_includes html, 'id="session-settings-dialog"'
        assert_includes html, "data-model-search", "the model list has to be searchable"
        assert_includes html, "Model Satu", "every model is offered"

        assert_match(/name="model" value="m-2"[^>]*checked/, html)
        assert_match(/name="thinking" value="high"[^>]*checked/, html)

        # The post still carries both halves at once, and answers into the row.
        assert_includes html, 'hx-post="/s/web_rubot/settings?token=t"'
        assert_includes html, 'hx-target="this"'
      end

      # The id is a machine's name for the model: the caption and the list say
      # the name a reader recognises. The id stays in the search text, so
      # looking a model up by id still works.
      def test_the_session_choice_shows_the_model_name_and_not_its_id
        html = View.render("_session_settings", session_id: "s", token_query: "",
                           model_choices: [ { value: "glm-4.6", name: "GLM 4.6", label: "GLM 4.6 (glm-4.6)" } ],
                           session_model: "glm-4.6", session_thinking: "high")

        caption = html[%r{<button class="session-trigger".*?</button>}m]
        refute_nil caption
        assert_includes caption, "GLM 4.6"
        refute_includes caption, "glm-4.6", "the caption says the name, not the id"

        row = html[%r{<span class="model-choice-name">[^<]*</span>}]
        assert_equal '<span class="model-choice-name">GLM 4.6</span>', row
        assert_includes html, 'data-search="glm 4.6 (glm-4.6) glm-4.6"',
                        "the id is still findable in the search"
      end

      # The model the session runs on can come from a hand-edited config or a
      # catalog that failed to load. Showing it beats marking nothing, which
      # would let the next save quietly move the session to another model.
      def test_the_session_choice_shows_a_model_the_catalog_does_not_have
        html = View.render("_session_settings", session_id: "s", token_query: "",
                           model_choices: [], session_model: "hand.edited",
                           session_thinking: "low")

        assert_match(/name="model" value="hand\.edited"[^>]*checked/, html)
      end

      def test_the_session_choice_escapes_model_labels
        html = View.render("_session_settings", session_id: "s", token_query: "",
                           model_choices: [ { value: "x", label: "<b>x</b>" } ],
                           session_model: "x", session_thinking: "minimal")

        refute_includes html, "<b>x</b>"
        assert_includes html, "&lt;b&gt;x&lt;/b&gt;"
      end

      # The dialog edits a copy of the choice, so the script has to be able to
      # put it back: a refused save must not leave the row showing a model the
      # session never took.
      def test_the_session_choice_can_be_put_back_after_a_refusal
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "resetSettingsChoices", "a refusal has to restore the choice"
        assert_includes js, "filterModels", "the model list has to be searchable"
        assert_includes js, "showModal", "the dialog is a real modal"
      end

      # --- Views ----------------------------------------------------------

      def test_timeline_escapes_tool_detail
        html = View.render("_timeline", items: [
                             { kind: :tool, name: "shell_exec", detail: "<b>x</b>",
                               state: :ok, epoch: Time.now.to_f, elapsed: nil }
                           ])

        assert_includes html, "shell_exec"
        assert_includes html, "&lt;b&gt;x&lt;/b&gt;"
        refute_includes html, "<b>x</b>"
      end

      # A skill load is marked as one so the eye can find the row it went
      # looking for, every other call wears no mark at all, and the skill's
      # name sits in code because it is the word the reader may type again.
      def test_timeline_marks_a_skill_load_as_one
        rows = lambda do |skills|
          View.render("_timeline", items: [
                        { kind: :tool, name: "file_ops", detail: "Memuat skill brain",
                          state: :ok, epoch: Time.now.to_f, elapsed: nil, skills: skills }
                      ])
        end

        html = rows.call([ "brain" ])
        assert_includes html, "is-skill"
        assert_includes html, "Memuat skill <code>brain</code>"
        assert_equal 1, html.scan("<code>").size, "one tag, around the whole name"

        refute_includes rows.call(nil), "is-skill"
      end

      # Two skills read in one call are two names, each in its own tag, and the
      # sentence around them stays the sentence the dictionary wrote.
      def test_timeline_puts_every_loaded_skill_in_its_own_code_tag
        html = View.render("_timeline", items: [
                             { kind: :tool, name: "file_ops",
                               detail: "Memuat skill brain dan grill",
                               state: :ok, epoch: Time.now.to_f, elapsed: nil,
                               skills: %w[brain grill] }
                           ])

        assert_includes html, "Memuat skill <code>brain</code> dan <code>grill</code>"
        assert_equal 2, html.scan("<code>").size
      end

      # A short skill name must not be found inside a longer word: a skill
      # called `in` used to take "Loading" apart (Load<code>in</code>g).
      def test_a_short_skill_name_is_not_matched_inside_a_longer_word
        args = { "path" => "/x/.rubot/skills/in/SKILL.md" }
        detail = Rubot::I18n.with_locale("en") { ToolCaption.caption("file_ops", args) }
        html = View.render("_timeline", items: [
                             { kind: :tool, name: "file_ops", detail: detail,
                               state: :ok, epoch: Time.now.to_f, elapsed: nil, skills: [ "in" ] }
                           ])

        assert_equal "Loading the in skill", detail, "the sentence the reader sees"
        assert_includes html, "Loading the <code>in</code> skill"
        assert_equal 1, html.scan("<code>").size
      end

      # The row exists to name the skill, so a name the sentence does not carry
      # still gets its tag rather than disappearing from the only row that says
      # it was loaded.
      def test_a_name_missing_from_the_sentence_still_gets_its_tag
        html = View.render("_timeline", items: [
                             { kind: :tool, name: "file_ops", detail: "Memuat skill",
                               state: :ok, epoch: Time.now.to_f, elapsed: nil,
                               skills: [ "brain" ] }
                           ])

        assert_includes html, "<code>brain</code>"
      end

      # A running skill row is the row in flight, so its letters still light up
      # one by one — the tag interrupts the markup, not the pulse.
      def test_a_live_skill_row_keeps_the_light_across_the_code_tag
        html = View.render("_timeline", items: [
                             { kind: :tool, name: "file_ops", detail: "Memuat skill brain",
                               state: :running, epoch: Time.now.to_f, elapsed: nil,
                               skills: [ "brain" ] }
                           ])

        assert_includes html, "<code><span style=\"--i:13\">b</span>"
        assert_includes html, "aria-label=\"Memuat skill brain\""
      end

      # Only the prompt wears a bubble: it is a quotation. The answer is the
      # page speaking, so it takes the full column, with no avatar beside it.
      def test_the_answer_is_full_width_and_the_prompt_is_quoted
        answer = View.render("_timeline", items: [ { kind: :text, text: "jawaban", live: false } ])
        prompt = View.render("_message", role: "user", text: "pertanyaan")
        history = View.render("_message", role: "assistant", text: "jawaban lama")

        refute_includes answer, "bubble"
        refute_includes answer, "avatar"
        assert_includes answer, %(class="text")

        assert_includes prompt, %(class="bubble text"),
                        "the bubble borrows the prose rules, markdown included"
        assert_includes prompt, "pertanyaan"

        refute_includes history, "bubble"
        assert_includes history, %(class="text")
      end

      # A prompt is markdown too. It used to be escaped text, so a list typed
      # into the field came back as asterisks and a code fence as backticks —
      # the answer was rendered and the question was not.
      def test_a_prompt_is_rendered_as_markdown
        html = View.render("_message", role: "user",
                           text: "**tebal** dan `kode`\n\n- satu\n- dua")

        assert_includes html, "<strong>tebal</strong>"
        assert_includes html, "<code>kode</code>"
        assert_includes html, "<li>satu</li>"
        refute_includes html, "**tebal**"
      end

      # The renderer is the only thing allowed to write tags: what the person
      # typed is escaped before anything else, so a prompt cannot inject markup.
      def test_a_prompt_cannot_inject_html
        html = View.render("_message", role: "user",
                           text: "halo <script>alert(1)</script>")

        refute_includes html, "<script>"
        assert_includes html, "&lt;script&gt;"
      end

      # The quote mark hands a paragraph back to the composer. A prompt is the
      # composer's own words already, so its bubble carries none of them.
      def test_a_prompt_carries_no_quote_marks
        html = View.render("_message", role: "user", text: "satu paragraf saja")

        refute_includes html, "para-quote"
      end

      # A prompt is a quotation, and the line breaks in it are part of what was
      # said: the field showed two lines, so the bubble has to. The renderer
      # writes a single newline as <br>, which is what makes that true now that
      # the bubble is a prose block rather than pre-wrapped text.
      def test_the_prompt_keeps_the_line_breaks_that_were_typed
        html = View.render("_message", role: "user", text: "baris satu\nbaris dua")

        assert_includes html, "baris satu<br>baris dua"
      end

      def test_timeline_shows_a_duration_only_past_the_threshold
        item = { kind: :tool, name: "shell_exec", detail: "ls", state: :ok,
                 epoch: Time.now.to_f, elapsed: 12.4 }

        assert_includes View.render("_timeline", items: [ item ]), ">12s<"

        item[:elapsed] = 1.2
        refute_includes View.render("_timeline", items: [ item ]), ">1s<"
      end

      def test_timeline_draws_an_automatic_compaction_seam
        item = { kind: :compaction, summarized: 8, before: 2029, after: 1565,
                 epoch: Time.now.to_f }

        html = View.render("_timeline", items: [ item ])

        assert_includes html, "compaction-row"
        assert_includes html, "Context summarized."
        assert_includes html, "2029 → 1565 token"
        # The counted messages were dropped from the seam: the figures are what
        # a reader checks, and the count only made the line longer.
        refute_includes html, "pesan diringkas"
      end

      def test_timeline_shows_how_long_a_compaction_took
        item = { kind: :compaction, summarized: 8, before: 2029, after: 1565,
                 elapsed: 67.4, epoch: Time.now.to_f }

        html = View.render("_timeline", items: [ item ])

        assert_includes html, "1m 7s"
      end

      def test_timeline_omits_duration_for_old_seams_without_one
        item = { kind: :compaction, summarized: 8, before: 2029, after: 1565,
                 epoch: Time.now.to_f }

        html = View.render("_timeline", items: [ item ])

        refute_includes html, "0s"
      end

      # The running seam is the light a thought wears and nothing else. A mark
      # beside it made the timeline look like it had two kinds of waiting, and
      # now no row in the timeline carries one at all.
      def test_timeline_draws_a_running_compaction_as_a_word_that_glows
        item = { kind: :compaction, state: :running, epoch: Time.now.to_f }

        html = View.render("_timeline", items: [ item ])

        assert_includes html, "compaction-row is-running"
        assert_includes html, "Summarizing the conversation"
        assert_includes html, "compaction-label glow"
        refute_includes html, "compaction-mark", "the seam has no mark left"
        refute_includes html, "mark-svg", "a compaction is not a spinner of its own"
      end

      def test_timeline_collapses_a_kept_thought_to_one_row
        item = { kind: :thinking, epoch: Time.now.to_f, started_at: 0.0,
                 closed_at: Time.now.to_f, elapsed: 12.0 }

        html = View.render("_timeline", items: [ item ])

        assert_includes html, "Thought for 12s"
        refute_includes html, "Thinking…"
      end

      def test_timeline_marks_a_running_row_with_its_start_time
        item = { kind: :thinking, epoch: 1_700_000_000.0, started_at: 0.0,
                 closed_at: nil, elapsed: nil }

        html = View.render("_timeline", items: [ item ])

        assert_includes html, 'data-since="1700000000.0"'
        assert_includes html, "Thinking…"
      end

      def test_ask_view_renders_the_confirmation_as_two_buttons
        html = View.render("_ask", prompt: { kind: :confirm, name: "shell_exec", reason: "rm" },
                                   turn_id: "tabc")

        assert_includes html, "/turns/tabc/confirm"
        assert_includes html, Rubot::I18n.t("web.confirm.continue")
      end

      # One slot, two shapes: the question is not a second kind of interruption,
      # so it renders through the same partial under a different kind.
      def test_ask_view_renders_a_question_as_options_and_a_box
        prompt = {
          kind: :question,
          question: "Where should the migration go?",
          options: [ { label: "New file", description: "Add 019_ask.sql" },
                     { label: "Extend 018", description: "Rebuild it in place" } ]
        }

        html = View.render("_ask", prompt: prompt, turn_id: "tabc")

        assert_includes html, "Where should the migration go?"
        assert_includes html, "/turns/tabc/ask"
        assert_includes html, "New file"
        assert_includes html, "Add 019_ask.sql"
        # The custom answer is always the last choice, and it answers through
        # the same route as the options — a control with its own request, not a
        # form submit on a node that arrived by swap.
        assert_includes html, Rubot::I18n.t("web.ask.custom")
        assert_includes html, 'hx-vals=\'{"choice":"custom","ask":""}\''
        assert_includes html, 'hx-include="closest .ask-custom"'
        assert_includes html, 'class="btn ask-send"'
        # Each option answers with its index, and names the ask it belongs to so
        # a click that outlives its question is dropped rather than answering
        # the next one.
        assert_includes html, 'hx-vals=\'{"choice":"0","ask":""}\''
        assert_includes html, 'hx-vals=\'{"choice":"1","ask":""}\''
        # The ask's identity must never travel as `token`: the auth gate reads
        # `token` out of the body before the query string, so a field by that
        # name replaces the web token and every answer comes back 403.
        refute_includes html, '"token":'
        refute_includes html, 'name="token"'
      end

      # The confirmation that closes a list of questions is a question with two
      # options and no box: a sentence typed there would have nowhere to go.
      def test_the_final_confirmation_offers_its_two_answers_only
        html = View.render("_ask",
                           prompt: { kind: :question, confirm: true, token: 3,
                                     question: "Send these answers?\n\n1. Which? → SQLite",
                                     options: [ { label: "Send" }, { label: "Start over" } ] },
                           turn_id: "tabc")

        assert_includes html, "Send these answers?"
        assert_includes html, "Start over"
        refute_includes html, "ask-custom"
        refute_includes html, Rubot::I18n.t("web.ask.custom")
      end

      def test_ask_view_renders_an_open_question_as_a_box_only
        html = View.render("_ask", prompt: { kind: :question, question: "Name?", options: [] },
                                   turn_id: "tabc")

        assert_includes html, "Name?"
        assert_includes html, Rubot::I18n.t("web.ask.custom")
        refute_includes html, "ask-option"
      end

      def test_ask_view_is_empty_without_a_prompt
        assert_equal "", View.render("_ask", prompt: nil, turn_id: "tabc").strip
      end

      def test_turn_view_opens_the_stream_with_the_token
        turn = build
        html = View.render("_turn", turn: turn, text: "hi", token_query: "?token=s3cret")

        assert_includes html, 'sse-connect="/turns/t1/stream?token=s3cret"'
        assert_includes html, 'sse-close="done"'
        assert_includes html, 'sse-swap="turn"'
      end

      # Enter is handled in JavaScript, which submits through `$refs.form`.
      # The ref used to be missing, so every press of Enter threw before a
      # request was made and the only way to send was the button.
      # A turn says nothing about itself while it runs: a long answer arrives as
      # one block and a slow tool is a row with no clock until it is slow. The
      # working row is what fills that silence, and it counts from the prompt —
      # not from whenever the fragment was rendered, which would restart the
      # clock on every chunk.
      def test_a_page_that_opens_on_a_running_turn_says_it_is_working
        turn = build
        html = render_page(live_turn: turn)

        assert_includes html, "Working…"
        assert_includes html, %(data-since="#{turn.epoch}")
        assert_includes html, %(data-threshold="0")
        assert_equal 1, html.scan('id="working"').size,
                     "one element owns the row, or the swap fills a second copy"
      end

      # The row belongs to the turn, not to the timeline: a turn read back from
      # the session file is over, and nothing in it should claim otherwise.
      def test_a_replayed_turn_does_not_say_it_is_working
        html = View.render("_timeline", items: [ { kind: :text, text: "jawaban", live: false } ])

        refute_includes html, "Working…"
      end

      # The working row is the page saying "not finished", not an entry in the
      # conversation, so it is drawn in its own band above the composer. In the
      # flow it slid the last tool row up every time the answer grew a line, and
      # it read as something the turn had done rather than something it still
      # had to do.
      #
      # The turn fragment carries only the slot the stream swaps through: it
      # used to render the row as well, and a page opened on a live turn then
      # held two elements called #working — the one beside the tool call and
      # the one above the field.
      def test_the_working_row_lives_in_the_band_above_the_composer
        turn = build
        turn.tool_started("shell_exec", "ls")

        timeline = View.turn_body(turn)
        fragment = View.render("_turn", turn: turn, text: "hi", token_query: "")
        page = render_page(live_turn: turn)

        refute_includes timeline, "Working…",
                        "the timeline is a record of the work, not of the waiting"
        refute_includes fragment, 'id="working"',
                        "the turn fragment must not draw a second band"
        assert_equal 1, page.scan('id="working"').size
        assert page.index('id="working"') < page.index('class="composer"'),
               "the band sits above the field, not in the thread"
        assert timeline.index("shell_exec"), "the tool row is still the timeline's"
      end

      # The band is in the page from the first paint, empty: the row appears
      # inside it, so the thread never changes height the moment a turn starts.
      def test_the_page_carries_an_empty_band_for_the_working_row
        html = render_page

        band = html[/<div id="working"[^>]*>.*?<\/div>/m]

        refute_nil band, "the page needs a place for the row to land"
        refute_includes band, "Working…", "the band starts empty"
        assert html.index('id="working"') < html.index('class="composer"'),
               "the band sits above the field, not in the thread"
      end

      # The clock says how long the turn has been running, so a tool call must
      # not take it back to zero: a reader watching a slow call has that call's
      # own clock in the timeline, and a number that kept dropping answered
      # nothing.
      def test_a_tool_call_keeps_the_working_clock_running
        epochs = [ 1000.0, 1012.0 ]
        turn = Turn.new(id: "t1", session_id: "s1", clock: FakeClock.new,
                        epoch_clock: -> { epochs.shift || 1012.0 })

        assert_equal 1000.0, turn.epoch, "the clock counts from the prompt"

        turn.tool_started("shell_exec", "ls")

        assert_equal 1000.0, turn.epoch, "a tool call does not restart it"
      end

      # A phone that puts the app down freezes its sockets, and coming back
      # reopens them: htmx reports the gap as `htmx:sseError` a moment before it
      # reconnects. Retiring the turn on that signal emptied the band and marked
      # the turn done, so after the app came back "Working…" and the call's own
      # clock never appeared again — the row is drawn only when the turn starts,
      # and the live clock only counts inside a turn that is not done. An error
      # is a reconnect, not an ending; the stream that returns is the one that
      # knows how the work ended.
      def test_a_dropped_stream_does_not_end_the_turn
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        refute_includes js, '["htmx:sseClose", "htmx:sseError"]',
                        "a drop and an ending are not the same news"
        assert_includes js, '"htmx:sseClose"'
        assert_includes js, "function retireTurn"
        refute_includes js, 'addEventListener("htmx:sseError"',
                        "the connection coming back must not retire the turn"
      end

      # The idle stream carries the end of a manual compaction. When it closes,
      # the compacting flag would otherwise wait for a message that is not
      # coming, so the page releases the composer itself; the server refuses a
      # prompt while the summarizer is really running.
      def test_a_closed_idle_stream_releases_the_composer
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, 'closest(".session-events")'
        assert_match(/closest\("\.session-events"\)\) return;\s*Alpine\.store\("turn"\)\.compacting = false;/,
                     js, "the idle stream's close has to unlock the composer")
      end

      # The page also keeps an idle stream open for news about other
      # conversations, and it lives as long as the page does. Its closing says
      # nothing about a turn, so the element the stream hangs off decides what
      # is being ended.
      def test_only_a_turn_stream_ends_a_turn
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, %(elt.closest(".turn")),
                        "the stream's own element says what it belongs to"
        assert_includes js, "if (!turn) return;",
                        "the page's own news feed is not a turn"
      end

      # The row is drawn once, at first paint. Re-sending it on every tool call
      # put a fresh node in the band, and the fresh node restarted its own
      # animation: the text the reader was looking at strobed on every call
      # while carrying no new information. One row, drawn once.
      def test_a_tool_call_does_not_re_send_the_working_row
        turn = build
        turn.tool_started("shell_exec", "ls")
        turn.finish("selesai")

        types = []
        turn.each_event { |type, _payload| types << type }

        refute_includes types, :working,
                        "the row never changes, so nothing has to swap it"
      end

      # ...but "once" is still once. A turn started from the page is told about
      # in exactly one place — the answer to the POST — so the band has to be
      # filled there, or a reader who typed the prompt never sees the row at all
      # and only a refresh (first paint) brings it back.
      def test_starting_a_turn_from_the_page_fills_the_working_band
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }
        channel.define_singleton_method(:run_turn) { |turn, _text| turn.finish("ok") }

        res = FakeResponse.new
        channel.create_turn(turn_request("halo"), res, "web_kanyaah")

        band = res.body[/<div class="working-band" id="working"[^>]*>.*?<\/div>/m]

        refute_nil band, "the turn must say it is working from the moment it starts"
        assert_includes band, "Working…"
        assert_includes band, 'hx-swap-oob="true"',
                        "the row belongs to the band above the field, not to the thread"
        assert_equal 1, res.body.scan('id="working"').size,
                     "a second band in the response would be a second copy on the page"
      end

      # A manual compaction rewrites the transcript the prompt would land in, so
      # the server must refuse it even if the browser let go of the composer
      # (a dropped stream can release the flag early). The transcript is the
      # thing that must not be written while it is being summarized.
      def test_a_prompt_is_refused_while_a_compaction_is_running
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }
        channel.instance_variable_get(:@compacting)["web_kanyaah"] = true

        res = FakeResponse.new
        channel.create_turn(turn_request("halo"), res, "web_kanyaah")

        assert_equal 409, res.status
        assert_includes res.body, Rubot::I18n.t("web.turn.compacting")
        refute channel.instance_variable_get(:@turns).any? { |_id, turn| turn.session_id == "web_kanyaah" },
               "no turn may be created against a transcript being rewritten"
      end

      # A page that reconnects its idle stream is often a page that lost it
      # while a compaction ended. The compose flag is cleared by a message on
      # that stream, so without an opening word a lost message would lock the
      # composer for the rest of the day and the button would look dead.
      def test_an_idle_event_stream_releases_the_composer_on_reconnect
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ [ "user", "isi percakapan" ] ] }
        )
        channel.instance_variable_get(:@compacting)["web_kanyaah"] = true

        types = channel.event_stream_opening("web_kanyaah").map(&:first)
        refute_includes types, :"compact-done",
                        "a compaction still running must not be unlocked"

        channel.instance_variable_get(:@compacting).delete("web_kanyaah")
        types = channel.event_stream_opening("web_kanyaah").map(&:first)
        assert_includes types, :"compact-done",
                        "an idle stream has to let a reconnecting page type again"
      end

      def test_the_turn_notification_threshold_comes_from_the_config
        assert_equal 0,
                     Rubot::Channels::Web.new(channel_config: { "turn_notify_after" => 0 })
                                          .instance_variable_get(:@turn_notify_after),
                     "zero is how a reader turns the buzz off"
        assert_equal Rubot::Channels::Web::TURN_NOTIFY_AFTER,
                     Rubot::Channels::Web.new(channel_config: {})
                                          .instance_variable_get(:@turn_notify_after)
      end

      # "Kabari kalau sudah kelar" is the one case where the clock does not
      # decide: the reader asked, so the announcement happens even for a turn
      # that took a second, says what the agent was told to say, and is forced
      # past the "the page is already showing this" rule.
      def test_a_turn_that_was_asked_to_report_back_announces_itself
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        calls = []
        channel.define_singleton_method(:notify_push) do |slug, **options|
          calls << [ slug, options ]
          nil
        end
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:usage_markup) { |_sid| nil }
        channel.define_singleton_method(:sidebar_markup) { |_sid| "" }
        channel.define_singleton_method(:process_message) do |_text, **options|
          options[:on_tool_call].call("notify", { "message" => "Migrasi selesai, 5 test lulus" }, nil)
          "Ringkasan pekerjaan."
        end
        channel.instance_variable_set(:@turn_notify_after, 3600)

        channel.run_turn(Turn.new(id: "t1", session_id: "web_kanyaah", prompt: "kerjain ya"), "kerjain ya")

        assert_equal 1, calls.length, "the request outranks the threshold"
        slug, options = calls[0]
        assert_equal "kanyaah", slug
        assert_equal "Migrasi selesai, 5 test lulus", options[:body],
                     "the notification says what the agent chose to say"
        assert_equal true, options[:force],
                     "the reader asked to be told, so a visible page does not silence it"
        assert_equal "/s/web_kanyaah", options[:url]
      end

      # An automatic compaction rewrites the transcript while the turn is still
      # answering. The seam is drawn live, but the footer's context figure goes
      # stale, so once the answer is complete a fresh usage row must be pushed
      # over /events. No reload: the reader keeps their place and the percentage
      # moves on its own.
      def test_an_automatic_compaction_refreshes_the_context_figure_after_the_turn_ends
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:usage_markup) { |_sid| '<span class="metrics" id="usage" hx-swap-oob="true">25%</span>' }
        channel.define_singleton_method(:sidebar_markup) { |_sid| "" }
        channel.define_singleton_method(:notify_push) { |*_args, **_opts| nil }
        channel.define_singleton_method(:mark_unread_unless_watched) { |_sid| false }
        channel.define_singleton_method(:process_message) do |_text, **options|
          options[:on_compaction_start]&.call
          options[:on_compaction]&.call({ summarized_messages: 8, context_before: 90_000,
                                          context_after: 25_000, elapsed: 3.0 })
          "jawaban siap"
        end

        queue = Queue.new
        channel.listen_for_events("web_kanyaah", queue)

        channel.run_turn(Turn.new(id: "t1", session_id: "web_kanyaah", prompt: "halo"), "halo")

        events = []
        events << queue.pop until queue.empty?
        usage = events.find { |type, _payload| type == :usage }
        refute_nil usage, "an automatic compaction must refresh the context figure"
        assert_includes usage[1], 'id="usage"'
        refute events.any? { |type, _payload| type == :refresh },
               "the page must not reload just to move a number"
      end

      # A turn with no compaction leaves the transcript untouched, so there is
      # no stale figure to correct and no reason to push a usage row either.
      def test_a_turn_without_compaction_does_not_push_a_usage_row
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:usage_markup) { |_sid| '<span class="metrics" id="usage" hx-swap-oob="true">25%</span>' }
        channel.define_singleton_method(:sidebar_markup) { |_sid| "" }
        channel.define_singleton_method(:notify_push) { |*_args, **_opts| nil }
        channel.define_singleton_method(:mark_unread_unless_watched) { |_sid| false }
        channel.define_singleton_method(:process_message) { |_text, **| "jawaban siap" }

        queue = Queue.new
        channel.listen_for_events("web_kanyaah", queue)

        channel.run_turn(Turn.new(id: "t1", session_id: "web_kanyaah", prompt: "halo"), "halo")

        events = []
        events << queue.pop until queue.empty?
        refute events.any? { |type, _payload| type == :usage },
               "no compaction means no stale figure to refresh"
      end

      def test_the_notify_tool_is_registered_and_only_carries_the_request
        tool = Rubot::Tools::Registry.new.get("notify")

        refute_nil tool, "the agent needs a way to ask"
        assert_includes tool.execute({}), "announced"
        assert_includes tool.execute({ "message" => "Selesai" }), "Selesai"
      end

      # A finished turn announces itself only when it ran long enough that the
      # reader plausibly walked away. The wiring is what this checks: the clock
      # starts when the prompt is accepted and stops when the answer is whole,
      # and the notification carries the conversation it belongs to.
      def test_a_slow_turn_notifies_when_it_ends_and_a_quick_one_does_not
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        calls = []
        channel.define_singleton_method(:notify_push) do |slug, title:, body:, url:, **|
          calls << { slug: slug, title: title, body: body, url: url }
          { "sent" => 1 }
        end
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:usage_markup) { |_sid| nil }
        channel.define_singleton_method(:sidebar_markup) { |_sid| "" }
        channel.define_singleton_method(:process_message) { |_text, **| sleep 1.05 and "jawaban siap" }

        channel.instance_variable_set(:@turn_notify_after, 1)
        slow = Turn.new(id: "t1", session_id: "web_kanyaah", prompt: "halo")
        channel.run_turn(slow, "halo")

        assert_equal 1, calls.length, "a turn past the threshold announces itself"
        assert_equal "kanyaah", calls[0][:slug]
        assert_equal "jawaban siap", calls[0][:body]
        assert_equal "/s/web_kanyaah", calls[0][:url],
                     "the notification has to open the conversation that finished"

        # Same work, a threshold it never crossed.
        calls.clear
        channel.define_singleton_method(:process_message) { |_text, **| "cepat" }
        channel.instance_variable_set(:@turn_notify_after, 60)
        channel.run_turn(Turn.new(id: "t2", session_id: "web_kanyaah", prompt: "halo"), "halo")

        assert_empty calls, "a quick reply belongs to the page that asked for it"
      end

      # A refresh during an answer must not look like a conversation whose last
      # prompt was never sent. Nothing is written to the session file until a
      # turn ends, so the page has to find the turn in memory and draw it —
      # prompt, timeline and the stream that reconnects to it.
      def test_a_refreshed_page_draws_the_turn_that_is_still_running
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Halo" }
        )
        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Berapa harga template?")
        turn.append_chunk("Aku cek katalog dulu.")
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.instance_variable_get(:@active)["web_kanyaah"] = "tabc"

        res = FakeResponse.new
        channel.render_session(res, "web_kanyaah")
        html = res.body

        assert_includes html, "Berapa harga template?",
                        "the prompt the turn is answering is drawn from the turn itself"
        assert_includes html, "Aku cek katalog dulu.",
                        "and so is the text it has written so far"
        assert_includes html, %(sse-connect="/turns/tabc/stream"),
                        "the page has to join the stream again, not sit on a frozen copy"
      end

      # The prompt is written to the session file when the turn starts, so a
      # page opened a moment later holds it in the transcript *and* finds the
      # turn in memory. Drawing both showed the same prompt twice — the double
      # render that appeared after switching persona mid-turn and coming back.
      def test_a_refreshed_page_draws_an_already_written_prompt_once
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Berapa harga template?" }
        )
        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Berapa harga template?")
        turn.append_chunk("Aku cek katalog dulu.")
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.instance_variable_get(:@active)["web_kanyaah"] = "tabc"

        res = FakeResponse.new
        channel.render_session(res, "web_kanyaah")
        html = res.body

        assert_equal 1, html.scan(%(class="msg user")).size,
                     "one prompt, one bubble — the transcript keeps it"
        assert_includes html, "Aku cek katalog dulu.",
                        "the answer in flight is still drawn"
        assert_includes html, %(sse-connect="/turns/tabc/stream"),
                        "the page still joins the stream"
      end

      # The turn writes each round to the session file and keeps the same rows
      # in memory, so a page refreshed between two rounds held both: the call
      # the file already had was drawn from the transcript and then again from
      # the turn, one row under the other. The running turn owns the tail it is
      # writing — the transcript keeps only what came before it.
      def test_a_refreshed_page_draws_an_already_written_call_once
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.instance_variable_get(:@app_config).sessions_dir
        File.write(File.join(dir, "web_kanyaah.json"), JSON.generate(
          "id" => "web_kanyaah", "updated_at" => Time.now.utc.iso8601,
          "messages" => [
            { "role" => "user", "content" => "Cek folder dulu" },
            { "role" => "assistant", "content" => "", "tool_calls" => [
              { "id" => "call_1", "type" => "function",
                "function" => { "name" => "shell_exec",
                                "arguments" => JSON.generate({ "command" => "ls" }) } }
            ] },
            { "role" => "tool", "tool_call_id" => "call_1", "content" => "a.txt" }
          ]
        ))

        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Cek folder dulu")
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.instance_variable_get(:@active)["web_kanyaah"] = "tabc"

        res = FakeResponse.new
        channel.render_session(res, "web_kanyaah")
        html = res.body

        assert_equal 1, html.scan(%(data-tool-key="shell_exec·ls")).size,
                     "one call, one row — the turn is drawing the tail"
        assert_equal 1, html.scan(%(class="msg user")).size,
                     "and one prompt, one bubble"
        assert_includes html, "Cek folder dulu", "the bubble comes from the turn"
        assert_includes html, %(sse-connect="/turns/tabc/stream"),
                        "the page still joins the stream"
      end

      # Steering used to reach the model but not the page: the bubble only
      # appeared after a refresh, which left the reader unsure whether the
      # message had been sent at all.
      def test_steering_a_running_turn_draws_the_message_at_once
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Halo")
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.define_singleton_method(:steer_session) { |_sid, _text| true }

        res = FakeResponse.new
        channel.control_turn(Struct.new(:query).new({ "text" => "Pakai template Grey" }),
                     res, "tabc", "steer")

        assert_equal 204, res.status
        steer = turn.items.find { |item| item[:kind] == :steer }

        refute_nil steer, "the page draws the message it was just handed"
        assert_equal "Pakai template Grey", steer[:text]

        html = View.render("_timeline", items: turn.items)

        assert_includes html, %(class="msg user")
        assert_includes html, "Pakai template Grey"
      end

      # A steering message nobody took is not drawn: the bubble would claim
      # something was delivered that never left the page.
      def test_steering_a_turn_that_cannot_take_it_draws_nothing
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Halo")
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.define_singleton_method(:steer_session) { |_sid, _text| false }

        res = FakeResponse.new
        channel.control_turn(Struct.new(:query).new({ "text" => "Halo?" }),
                     res, "tabc", "steer")

        assert_equal 409, res.status
        assert_empty turn.items.select { |item| item[:kind] == :steer }
      end

      # A turn that has ended is in the session file, where the history loop
      # draws it. Drawing it again would show every answer twice.
      def test_a_page_does_not_draw_a_turn_that_has_already_ended
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Halo")
        turn.finish("Siap.")
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.instance_variable_get(:@active)["web_kanyaah"] = "tabc"

        assert_nil channel.live_turn("web_kanyaah")

        res = FakeResponse.new
        channel.render_session(res, "web_kanyaah")

        refute_includes res.body, %(sse-connect="/turns/tabc/stream")
      end

      # An ask that was already waiting when the page refreshed would otherwise
      # strand the turn behind a question nobody can see: its event is in the
      # part of the log the reconnecting reader skips.
      def test_a_refreshed_page_shows_a_confirmation_that_is_still_waiting
        turn = build
        turn.instance_variable_set(:@ask, { kind: :confirm, name: "shell_exec", reason: "rm -rf build" })

        html = View.render("_turn", turn: turn, text: "hi", token_query: "")

        assert_includes html, Rubot::I18n.t("web.confirm.continue")
        assert_includes html, "rm -rf build"
      end

      # Same reason, for the question: the slot is drawn from turn state, so a
      # reload mid-question still shows the options to click.
      def test_a_refreshed_page_shows_a_question_that_is_still_waiting
        turn = build
        turn.instance_variable_set(:@ask, {
                                     kind: :question,
                                     question: "Where should it go?",
                                     options: [ { label: "New file" }, { label: "Extend 018" } ]
                                   })

        html = View.render("_turn", turn: turn, text: "hi", token_query: "")

        assert_includes html, "Where should it go?"
        assert_includes html, "Extend 018"
        assert_includes html, 'sse-swap="ask"'
      end

      # The stream a refreshed page joins starts at the state the turn is in,
      # not at the beginning of the log. Replaying every :turn in it would be
      # one whole re-render per flush pause, and a long answer would take
      # minutes to catch up with itself.
      def test_a_reader_joining_in_flight_gets_the_latest_state_once
        turn = build
        turn.append_chunk("Bagian pertama.")
        turn.tool_started("shell_exec", "ls")
        turn.append_chunk("Bagian kedua.")

        events = []
        turn.each_event(from_now: true) do |type, _payload|
          events << type
          break
        end

        assert_equal [ :turn ], events,
                     "one paint of the current state, not a replay of how it got there"
        assert_equal [ "Bagian pertama.", "Bagian kedua." ], texts(turn),
                     "the paint carries the whole timeline, in the order it happened"
      end

      def test_joining_a_turn_that_just_ended_still_closes_the_stream
        turn = build
        turn.finish("selesai")

        events = []
        turn.each_event(from_now: true) { |type, _payload| events << type }

        assert_equal [ :turn, :done ], events
      end

      def test_the_composer_form_carries_the_ref_enter_submits_through
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        form = html[/<form\b[^>]*>/m]

        refute_nil form, "the composer must be a form: Enter submits it"
        assert_includes form, 'x-ref="form"'
        assert_includes form, 'hx-post="/s/web_rubot/turn"'
      end

      # The field and its button share one row, which is what keeps the button
      # at the end of the text. Without the row it falls under the field and
      # reads as a left-aligned block the width of the composer.
      def test_the_composer_keeps_the_button_at_the_end_of_the_field_s_row
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        row = html[%r{<div class="composer-row">.*?</div>\s*</div>}m]

        refute_nil row, "the composer needs a row to lay the field and the button out"
        assert_match %r{<div class="composer-row">\s*<textarea\b}, row,
                     "the field opens the row"
        assert_includes row[/<div class="composer-actions">.*/m], 'class="btn primary"',
                        "the button rides along at the end of the same row"
      end

      # A quoted paragraph is carried above the field rather than written into
      # it, so the composer needs a shelf to put the chip on. The spoken count
      # lives outside that shelf: a live region inside a block that hides itself
      # with `x-show` announces nothing.
      def test_the_composer_carries_the_shelf_a_quoted_paragraph_lands_on
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        shelf = html[%r{<div class="composer-quotes".*?</div>}m]

        refute_nil shelf, "quoted paragraphs need a place above the field"
        assert_includes shelf, 'x-show="quotes.length"'
        assert_includes shelf, 'x-for="quote in quotes"'
        assert_includes shelf, 'class="quote-kind"', "a list says its size on the chip"
        assert_includes html, 'x-text="quoteStatus"'
        refute_includes shelf, "quoteStatus", "the count is spoken outside the hiding shelf"
      end

      # A phone has no Enter that sends: during a turn the only key the
      # software keyboard offers makes a new line. So steering needs a button
      # of its own, and so does stopping — one control cannot be both, which
      # is what the send button used to be while a turn ran.
      def test_the_composer_sends_and_stops_while_a_turn_runs
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        buttons = html.scan(/<button\b.*?<\/button>/m)

        send_button = buttons.find { |button| button.include?("btn primary") }
        stop_button = buttons.find { |button| button.include?("composer-stop") }

        refute_nil send_button, "the composer needs its send button"
        refute_nil stop_button, "and a way out of the turn that is running"

        assert_includes send_button, "send()"
        refute_includes send_button, "stop()",
                        "the send button must not stop the turn"
        assert_includes stop_button, "stop()"
        assert_includes stop_button, %(x-show="busy"),
                        "the stop button only exists while there is something to stop"
        assert_includes stop_button, %(x-bind:disabled="stopping")
      end

      # Steering is only reachable if the send button accepts text while the
      # turn runs — the store decides what the press does with it, not whether
      # the button works.
      def test_the_send_button_can_steer_a_running_turn
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "/steer", "the text goes to the running turn"
        assert_includes js, "Alpine.store(\"turn\").active"
        refute_includes js, "sendOrStop",
                        "one button cannot both send and stop once a phone needs both"
      end

      # Stopping is a request, not a fact: the turn keeps running until the
      # server has acted. The button has to say so and stop taking presses for
      # as long as it is true — which is longer than the round trip that asked
      # for the stop, because the server answers "queued" long before the work
      # actually stops.
      def test_the_stop_button_says_it_is_stopping_for_as_long_as_the_turn_lives
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        button = html[/<button\b[^>]*class="btn composer-stop".*?<\/button>/m]

        refute_nil button, "the stop button is the one that ends the turn"
        assert_includes button, %(x-bind:disabled="stopping")
        # The word is the dictionary's, so the button that says it in English
        # says it in Indonesian the moment the language moves.
        assert_includes button, Rubot::I18n.t("web.composer.stop_pending")
        assert_includes button, Rubot::I18n.t("web.composer.stop")

        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "Membatalkan…", "the button has to say what it is doing"

        stop = js[/async stop\(\) \{.*?\n    \},/m]
        refute_nil stop
        assert_includes stop, "store.stopping = true"
        assert_includes stop, "if (!active || store.stopping) return;",
                        "a second press while the first is in flight is a no-op"
        refute_includes stop, "finally",
                        "the round trip is not the end of the turn, so it cannot be where the word is cleared"

        retire = js[/function retireTurn\(turn\) \{.*?\n\}/m]
        refute_nil retire
        assert_includes retire, "store.stopping = false",
                        "the next turn starts with the button back to its plain word"
      end

      # A draft belongs to the conversation it was typed into and to the tab it
      # was typed in. Opening another conversation is a page load, so the field
      # would come back empty and the sentence be lost — the one loss the
      # reader cannot undo.
      def test_a_half_written_prompt_comes_back_with_its_session
        html = View.render("_composer", session_id: "web_rubot~2026", token_query: "")
        assert_includes html, %(data-draft="web_rubot~2026"),
                        "the field has to know which session it is writing for"

        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))
        init = js[/init\(\) \{.*?\n    \},/m]

        refute_nil init
        assert_includes init, "readDraft(this.draftId)", "the draft has to be put back"
        assert_includes init, 'this.$watch("text"', "and kept up to date as it is typed"
        assert_includes js, "sessionStorage",
                        "a draft belongs to this tab, not to every window on the machine"
      end

      # A prompt the server refuses keeps its text in the field and puts
      # nothing in the thread, so the reason has to be said next to the field.
      # Left unsaid, the reader presses a button that appears broken: the text
      # is still there, no bubble came out of it, and nothing explains why.
      def test_a_refused_prompt_has_a_place_to_say_why
        html = View.render("index",
                           personas: [], groups: { pinned: [], recent: [], page: 1, pages: 1, recent_total: 0, pinned_limit: 10, current: "web_rubot" },
                           slug: "rubot", persona_label: "Rubot", persona_emoji: "🤖",
                           persona_prompt: "",
                           persona_model: "m", session_id: "web_rubot",
                    persona_model_value: "", model_choices: [],
                    session_model: "", session_thinking: "medium", persona_thinking: "medium",
                    persona_tool_output: "verbose",
                    skill_choices: [], skills_dir: "~/.rubot/skills",
                           session_short: "web_rubot", session_label: "Sesi baru",
                           document_title: "rubot · Rubot", live_turn: nil, token_query: "",
                           page: { entries: [], more: false, before: 0 }, older_url: "",
                           usage: { cost: "—", cache: "—", ctx: "—" },
                           usage_facts: { model: "m", cost: "—", breakdown: "", requests: "0",
                                          messages: "0", tokens_in: "0", tokens_out: "0",
                                          reasoning: "", cache: "—",
                                          cache_history: "", re_read: "0", saved: "", ctx: "—" })

        assert_includes html, 'id="composer-notice"', "the composer needs a notice slot"
        assert_match(/id="composer-notice"[^>]*hidden/, html,
                     "the slot starts empty and unseen")

        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))
        assert_includes js, "htmx:responseError",
                        "a response the server rejected has to reach the slot"
        assert_includes js, "composer-notice"
        assert_includes js, "htmx:beforeRequest",
                        "a notice about the last attempt must not outlive the next one"

        # A crash answers with plain text, not markup: left as it came it would
        # read as "internal error" on the page, which is not a sentence for a
        # reader and says nothing about the text still in the field.
        refute_includes js, "slot.innerHTML = event.detail.xhr.responseText",
                        "a non-HTML error body has to be turned into words"
      end

      # WEBrick hands form values back as ASCII-8BIT. Encoding them at the
      # edge is what keeps emoji and accented names from blowing up later
      # when the persona is written to personas.json.      # --- history --------------------------------------------------------

      # A refresh reads the session file, so the tool rows have to be rebuilt
      # from it — they are only stored as calls plus their results.
      def test_history_replays_tool_rows_after_a_refresh
        channel = Rubot::Channels::Web.new(channel_config: {})
        messages = [
          { "role" => "user", "content" => "cek dulu" },
          { "role" => "assistant", "content" => "Saya cek jadwalnya.",
            "tool_calls" => [
              { "id" => "c1", "type" => "function",
                "function" => { "name" => "shell_exec",
                                "arguments" => %({"command":"date -u"}) } }
            ] },
          { "role" => "tool", "tool_call_id" => "c1", "content" => "[Exit code: 0]\nSun" },
          { "role" => "assistant", "content" => "Sudah, ini hasilnya." }
        ]

        results = channel.tool_results(messages)
        item = channel.history_tool_items(messages[1]["tool_calls"].first, results, {}, "web_rubot").first

        assert_equal :tool, item[:kind]
        assert_equal "shell_exec", item[:name]
        assert_equal "Showing the date and time", item[:detail]
        assert_equal :ok, item[:state]
      end

      def test_history_marks_a_tool_that_errored_as_failed
        channel = Rubot::Channels::Web.new(channel_config: {})
        results = { "c1" => "ERROR: nope" }
        call = { "id" => "c1",
                 "function" => { "name" => "file_ops", "arguments" => %({"path":"x"}) } }

        assert_equal :failed, channel.history_tool_items(call, results, {}, "web_rubot").first[:state]
      end

      # A call whose result never arrived is neither a success nor a failure:
      # the turn was stopped with the tool in flight.
      def test_history_marks_a_tool_without_a_result_as_unknown
        channel = Rubot::Channels::Web.new(channel_config: {})
        call = { "id" => "c1", "function" => { "name" => "shell_exec", "arguments" => "{}" } }

        assert_equal :unknown, channel.history_tool_items(call, {}, {}, "web_rubot").first[:state]
      end

      def test_history_tolerates_arguments_that_are_not_json
        channel = Rubot::Channels::Web.new(channel_config: {})
        call = { "id" => "c1", "function" => { "name" => "shell_exec", "arguments" => "bukan json" } }

        # The Indonesian label, pinned: this test is about unreadable arguments
        # still getting the tool's own sentence, not about which language.
        detail = Rubot::I18n.with_locale("id") do
          channel.history_tool_items(call, {}, {}, "web_rubot").first[:detail]
        end

        assert_equal "Menjalankan perintah di terminal", detail
      end

      # --- diff -----------------------------------------------------------

      # A tool that changed a file has to show what it did. The row says which
      # file and how long it took; the hunks are the only record of the change
      # itself, and without them the reader has to open the file to find out
      # whether the agent did what was asked.
      def test_a_changed_file_is_drawn_as_hunks
        html = Diff.render("a\nb\nc\n", "a\nB\nc\n", path: "lib/x.rb")

        refute_nil html
        assert_includes html, %(class="diff")
        assert_includes html, %(class="diff-row is-del")
        assert_includes html, %(class="diff-row is-add")
        assert_includes html, %(class="diff-row is-ctx"), "context around the change"
        assert_includes html, "lib/x.rb"
        assert_includes html, "+1"
        assert_includes html, "-1"
      end

      # A create has no before, a delete has no after: the first is every line
      # added, the second every line removed. Those are exactly the calls the
      # reader cannot see any other way.
      def test_a_created_file_is_all_additions
        html = Diff.render(nil, "one\ntwo\n", path: "new.txt")

        assert_includes html, "+2"
        refute_includes html, "is-del"
        assert_equal 2, html.scan(%(class="diff-row is-add")).size
      end

      def test_a_deleted_file_is_all_removals
        html = Diff.render("one\ntwo\n", nil, path: "gone.txt")

        assert_includes html, "-2"
        refute_includes html, "is-add"
        assert_equal 2, html.scan(%(class="diff-row is-del")).size
      end

      # A read, a search, a command: the row is the whole record, and an empty
      # frame under it would say a file changed when none did.
      def test_a_call_that_changed_no_file_draws_nothing
        assert_nil Diff.render("same\n", "same\n")
        assert_nil Diff.render(nil, nil)
        assert_nil Diff.render("", "")
      end

      # The content is someone else's file, so it is text, not markup.
      def test_the_diff_escapes_the_file_it_shows
        html = Diff.render("x = 1\n", "<script>alert(1)</script>\n", path: "x.rb")

        refute_includes html, "<script>"
        assert_includes html, "&lt;script&gt;"
      end

      # A file with two changes far apart is two hunks and a line saying how
      # much was skipped — the same shape `git diff` prints, and the reason a
      # one-word edit in a long file costs a handful of rows.
      def test_lines_between_two_hunks_collapse_into_one_gap
        before = (1..20).map { |i| "line #{i}" }.join("\n")
        after = before.sub("line 2", "line two").sub("line 18", "line eighteen")

        spec = Diff.structure(before, after)

        assert_equal 2, spec[:hunks]
        gap = spec[:rows].find { |row| row.include?("diff-gap") }

        refute_nil gap, "the lines neither hunk needs are collapsed"
        assert_equal 9, gap[/>(\d+) baris/, 1].to_i,
                     "lines 6..14 are shared and shown once as a count"
      end

      # A rewrite of a big file must not push the rest of the conversation off
      # the page.
      def test_a_very_long_diff_is_cut_short
        before = (1..200).map { |i| "old #{i}" }.join("\n")
        after = (1..200).map { |i| "new #{i}" }.join("\n")

        html = Diff.render(before, after, path: "big.rb")

        assert_includes html, "baris lagi", "the block has to say it is showing a part"
        assert_operator html.scan("diff-row").size, :<=, Diff::MAX_ROWS + 1
      end

      # The live turn and a refreshed page have to agree: the hunks arrive with
      # the tool result, and are read back out of the session file afterwards.
      def test_a_tool_result_carries_its_hunks_into_the_timeline
        channel = Rubot::Channels::Web.new(channel_config: {})
        turn = build

        channel.tool_finished(turn, "file_ops", "[Exit code: 0] Written 8 characters",
                     { "path" => "x.rb", "before" => "a\nb\n", "after" => "a\nB\n" })

        diff = turn.items.find { |item| item[:kind] == :diff }

        refute_nil diff, "the hunks belong to the turn, under the row that made them"
        assert_includes diff[:html], %(class="diff-row is-add")
      end

      def test_history_draws_the_hunks_under_their_tool_row
        channel = Rubot::Channels::Web.new(channel_config: {})
        call = { "id" => "c1",
                 "function" => { "name" => "file_ops", "arguments" => %({"path":"x.rb"}) } }
        diffs = { "c1" => { "path" => "x.rb", "before" => "a\n", "after" => "a\nb\n" } }

        items = channel.history_tool_items(call, { "c1" => "[Exit code: 0]" }, diffs, "web_rubot")

        assert_equal [ :tool, :diff ], items.map { |item| item[:kind] }
        assert_includes items.last[:html], %(class="diff-row is-add")
      end

      # A picture a call handed back comes after the hunks: the edit happened
      # first, and the picture is the result the reader is meant to look at.
      def test_a_picture_follows_the_hunks_of_the_call_that_sent_it
        channel = Rubot::Channels::Web.new(channel_config: {})
        call = { "id" => "c1",
                 "function" => { "name" => "send_files", "arguments" => %({"path":"shot.png"}) } }
        diffs = { "c1" => { "path" => "shot.png", "before" => nil, "after" => "a\n" } }

        items = channel.history_tool_items(call, { "c1" => "Sent" }, diffs, "web_rubot")

        assert_equal [ :tool, :diff ], items.map { |item| item[:kind] },
                     "a picture needs an attachment folder; the diff does not"
      end
    end
  end
end
