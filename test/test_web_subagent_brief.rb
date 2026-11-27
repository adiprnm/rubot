# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  module Web
    # The brief a delegated run was given, and how it is read.
    #
    # A task is a whole brief — two kilobytes is ordinary — and the row that
    # owns it is one line wide. It used to ride on the row as a tooltip, which
    # is a control a desktop has and a phone does not, so the row is a
    # <details> now. These tests hold the two halves of that: what the row says
    # when it is closed, and what it opens onto.
    class TestWebSubagentBrief < Minitest::Test
      TASK = "Repo: /home/adipurnm/Projects/oss/rubot. Review the committed change, then " \
             "say what the row has to carry and why it cannot carry it."

      def teardown
        Rubot::I18n.locale = Rubot::I18n::DEFAULT_LOCALE
      end

      def test_a_row_opens_onto_the_whole_task
        rows = render_rows(run_id: "r1", phase: "tool", agent: "code_reviewer",
                           line: "2 langkah · Repo…", task: TASK)

        assert_includes rows, %(<details class="subagent-more" id="subagent-run-r1">)
        assert_includes rows, %(<summary class="subagent-summary")
        assert_includes rows, TASK, "the brief whole, not the beginning the line shows"
        assert_includes rows, Rubot::I18n.t("web.subagents.prompt")
        refute_includes rows, Rubot::I18n.t("web.subagents.result")
      end

      # The footer's list is rewritten on every step the run takes, so the id a
      # row opens under belongs to the run and not to its place in the list: a
      # row keeps its state while the ones above it change, and the browser can
      # find it again after the swap (see app.js, restoreSubagentBriefs).
      def test_the_row_is_identified_by_its_run
        rows = render_rows(run_id: "r1", phase: "tool", task: TASK)

        assert_includes rows, 'id="subagent-run-r1"'
        refute_includes rows, 'id="subagent-run-"', "an empty id is an id nothing can be found by"
      end

      def test_a_finished_run_opens_onto_its_answer
        rows = render_rows(run_id: "r2", phase: "done", line: "1 langkah · 9s",
                           task: TASK, result: "SAFE TO COMMIT, 2 NIT")

        assert_includes rows, Rubot::I18n.t("web.subagents.result")
        assert_includes rows, "SAFE TO COMMIT, 2 NIT"
      end

      def test_a_failed_run_opens_onto_the_reason
        rows = render_rows(run_id: "r3", phase: "failed", line: "rate limited",
                           task: TASK, error: "rate limited")

        assert_includes rows, "subagent-brief-error"
        assert_includes rows, "rate limited"
        assert_includes rows, Rubot::I18n.t("web.subagents.error")
      end

      # An old transcript, or a caller that only has a line, still draws its
      # row: an empty panel under a row that opens to nothing reads as broken.
      def test_a_row_without_a_brief_does_not_open
        rows = render_rows(run_id: "r4", phase: "tool", line: "2 langkah")

        refute_includes rows, "<details"
        assert_includes rows, %(<div class="subagent-summary">)
        assert_includes rows, "2 langkah"
      end

      # A brief is model-written text about code, so it carries angle brackets
      # by the dozen and is never markup.
      def test_the_brief_is_escaped
        rows = render_rows(run_id: "r5", phase: "tool", task: "diff <script>alert(1)</script>")

        refute_includes rows, "<script>"
        assert_includes rows, "&lt;script&gt;"
      end

      # The transcript's row is the same row: a delegation that is over is read
      # the same way it was read while it worked.
      def test_the_transcript_row_opens_the_same_way
        html = View.render("_timeline", items: [
                             { kind: :subagent, run_id: "r1", agent: "code_reviewer",
                               phase: "done", detail: "2 langkah · 9s", task: TASK }
                           ])

        assert_includes html, '<details class="subagent-row subagent-done"'
        assert_includes html, TASK
        assert_includes html, %(<summary class="subagent-summary")
      end

      # A row written before the brief was a thing has no task of its own, and
      # the transcript still has to draw it — as a line the CSS can still cut
      # short: the ellipsis lives on a flex block, so the row that opens and the
      # row that does not have to wear the same one.
      def test_a_transcript_row_without_a_task_stays_a_line
        html = View.render("_timeline", items: [
                             { kind: :subagent, agent: "writer", phase: "done", detail: "1 langkah · 3s" }
                           ])

        refute_includes html, "<details"
        assert_includes html, %(<div class="subagent-row subagent-done">)
        assert_includes html, %(<div class="subagent-summary">)
        assert_includes html, "1 langkah · 3s"
      end

      # The phase is interpolated into a class attribute, so it goes through the
      # same escaping every other attribute value does: a phase is internal
      # today, and a caller that spelled one itself must not be able to end the
      # attribute.
      def test_the_phase_reaches_the_class_escaped
        html = View.render("_timeline", items: [
                             { kind: :subagent, agent: "writer", phase: %(done" onload="x),
                               detail: "1 langkah" }
                           ])

        refute_includes html, %(onload="x")
        assert_includes html, "&quot;"
      end

      # The swap that rewrites the list must leave the id behind, or the brief
      # closes on its own a second after it was opened.
      def test_the_swapped_list_keeps_the_id_of_an_open_brief
        channel = Rubot::Channels::Web.new(channel_config: {})
        markup = channel.subagent_slots_markup([
                                                 { run_id: "r1", agent: "writer", phase: "tool",
                                                   line: "2 langkah · tulis puisi", task: "tulis puisi" }
                                               ])

        assert_includes markup, "hx-swap-oob"
        assert_includes markup, 'id="subagent-run-r1"'
      end

      # The reopen is a browser's job and cannot be seen in a rendered page, so
      # the hook itself is held here: one listener that remembers, and the two
      # swaps that put the memory back.
      def test_an_open_brief_is_reopened_after_a_swap
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "function restoreSubagentBriefs()"
        assert_includes js, %(document.addEventListener("htmx:afterSwap", restoreSubagentBriefs))
        assert_includes js, %(document.addEventListener("htmx:oobAfterSwap", restoreSubagentBriefs))
        assert_includes js, %(document.addEventListener("toggle", rememberSubagentBrief, true))
      end

      # A row that leaves the page takes its id with it, and nothing tells the
      # set: a <details> removed by a swap never fires `toggle`. Without the
      # prune the set keeps every run the conversation ever delegated, and the
      # loop walks them all on every swap.
      def test_a_row_that_left_with_its_run_is_forgotten
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))
        restore = js[/function restoreSubagentBriefs\(\) \{.*?\n\}/m]

        refute_nil restore, "restoreSubagentBriefs is missing from app.js"
        assert_includes restore, "openSubagentBriefs.delete(id)",
                        "a row that no longer resolves has to be dropped from the set"
      end

      # A brief is three kilobytes and the row it belongs to is a footnote: a
      # panel that grows with the text would push the conversation off the
      # screen on the one device this was built for. And the pointer belongs to
      # the rows that actually open — a row with nothing behind it wears the same
      # flex block, and a hand over it promises a tap that does nothing.
      def test_the_brief_cannot_grow_past_the_screen
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        text = css[/^\.subagent-brief-text \{[^}]*\}/]
        summary = css[/^\.subagent-summary \{[^}]*\}/]
        opening = css[/^summary\.subagent-summary \{[^}]*\}/]

        refute_nil text, "the .subagent-brief-text rule is missing from app.css"
        refute_nil summary, "the .subagent-summary rule is missing from app.css"
        refute_nil opening, "the summary-only rule is missing from app.css"
        assert_includes text, "max-height", "the panel has to stop growing somewhere"
        assert_includes text, "overflow: auto", "and the rest has to be reachable"
        assert_includes summary, "list-style: none", "the row already has a mark; no triangle"
        refute_includes summary, "cursor: pointer",
                        "the flex block is worn by rows that do not open as well"
        assert_includes opening, "cursor: pointer", "the row has to say it opens"
      end

      private

      def render_rows(run_id: "r1", phase: "tool", agent: "writer", line: "2 langkah",
                      task: nil, result: nil, error: nil)
        View.render("_subagent_rows", subagents: [
                      { run_id: run_id, agent: agent, phase: phase, line: line,
                        task: task, result: result, error: error }
                    ])
      end
    end
  end
end
