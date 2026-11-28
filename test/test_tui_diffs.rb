# frozen_string_literal: true

require "stringio"
require "test_helper"
require "rubot"
require_relative "support/tui_support"

module Rubot
  # What a file tool leaves on screen: the diff rows under a row, and the confirmation before a dangerous action.
  class TestTUI < Minitest::Test
    include TuiSupport

    # --- file diffs ----------------------------------------------------




    def test_write_shows_a_pi_diff_under_the_tool_row
      Dir.mktmpdir do |dir|
        path = File.join(dir, "notes.md")
        File.write(path, "one\ntwo\nthree\n")
        repl = run_file_tool(build_repl, operation: "write", path: path,
                             after: "one\nTWO\nthree\n")

        texts = entry_texts(repl)
        tool_ix = texts.index { |text| text.include?("Writing ") }
        diff_ix = texts.index { |text| text.match?(/\A[+-]\d/) }

        assert tool_ix, "the tool row still renders: #{texts.inspect}"
        assert diff_ix, "the pi-diff block follows the write: #{texts.inspect}"
        assert_equal tool_ix + 1, diff_ix, "the diff sits right under the tool row"

        indents = repl.instance_variable_get(:@log).instance_variable_get(:@indents)
        assert_equal 4, indents[diff_ix], "the diff hangs under the tool row"

        git = texts[(diff_ix)..]
        assert(git.first.include?("+1") && git.first.include?("-1") && git.first.include?("1 hunk"),
               "the summary keeps pi-diff's counts: #{git.first.inspect}")
        assert(git.any? { |row| row.include?("│ one") })
        assert(git.any? { |row| row.include?("│ two") && row.include?("- ") })
        assert(git.any? { |row| row.include?("│ TWO") && row.include?("+ ") })
        assert_equal "─", git[1], "a full-width rule opens the block"
        assert_operator git.count("─"), :>=, 2, "and one closes it"

        entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
        deleted = entries.find { |entry| entry.map(&:first).join.include?("│ two") }
        assert_includes deleted, [ "▌", TUI::Diff::FG_DEL ], "deletions carry the red stripe"
        assert(deleted.any? { |(text, style)| text == "- " && style.include?(TUI::Diff::FG_DEL) },
               "the sign cell marks the removal")
        assert_includes deleted.map { |(t, _)| t }.join, "2", "the gutter shows the old line number"
        added = entries.find { |entry| entry.map(&:first).join.include?("│ TWO") }
        assert_includes added, [ "▌", TUI::Diff::FG_ADD ], "additions carry the green stripe"
      end
    end

    def test_append_shows_a_pi_diff_too
      Dir.mktmpdir do |dir|
        path = File.join(dir, "log.md")
        File.write(path, "first\n")
        repl = run_file_tool(build_repl, operation: "append", path: path,
                             after: "first\nsecond\n")

        git = entry_texts(repl).drop_while { |text| !text.match?(/\A[+-]\d/) }
        assert git.any?, "append gets a diff too"
        assert(git.any? { |row| row.include?("│ first") })
        assert(git.any? { |row| row.include?("│ second") && row.include?("+ ") })
      end
    end

    def test_an_edit_shows_a_pi_diff_too
      Dir.mktmpdir do |dir|
        path = File.join(dir, "notes.md")
        File.write(path, "one\ntwo\nthree\n")
        repl = run_file_tool(build_repl, operation: "edit", path: path,
                             after: "one\nTWO\nthree\n")

        git = entry_texts(repl).drop_while { |text| !text.match?(/\A[+-]\d/) }
        assert git.any?, "an edit gets a diff like a write: #{entry_texts(repl).inspect}"
        assert(git.any? { |row| row.include?("│ two") && row.include?("- ") })
        assert(git.any? { |row| row.include?("│ TWO") && row.include?("+ ") })
      end
    end

    def test_a_delete_shows_every_line_it_removed
      Dir.mktmpdir do |dir|
        path = File.join(dir, "gone.md")
        File.write(path, "one\ntwo\n")
        repl = run_file_tool(build_repl, operation: "delete", path: path, after: nil)

        git = entry_texts(repl).drop_while { |text| !text.match?(/\A[+-]\d/) }
        assert git.any?, "a delete gets a diff: #{entry_texts(repl).inspect}"
        assert_includes git.first, "-2", "both lines count as removals"
        assert(git.any? { |row| row.include?("│ one") && row.include?("- ") })
        assert(git.any? { |row| row.include?("│ two") && row.include?("- ") })
        refute(git.any? { |row| row.include?("+ ") }, "nothing was added")
      end
    end

    def test_a_delete_that_did_not_happen_shows_no_diff
      Dir.mktmpdir do |dir|
        path = File.join(dir, "kept.md")
        File.write(path, "still here\n")
        # The tool refused, so the file never went away: nothing to show.
        repl = run_file_tool(build_repl, operation: "delete", path: path, after: "still here\n")

        refute entry_texts(repl).any? { |text| text.match?(/\A[+-]\d/) },
               "a refused delete changes nothing"
      end
    end

    def test_a_write_that_changes_nothing_shows_no_diff
      Dir.mktmpdir do |dir|
        path = File.join(dir, "same.md")
        File.write(path, "same\n")
        repl = run_file_tool(build_repl, operation: "write", path: path, after: "same\n")

        refute entry_texts(repl).any? { |text| text.match?(/\A[+-]\d/) },
               "no change, no diff"
      end
    end

    def test_a_tool_that_changed_no_file_gets_no_diff
      repl = build_repl

      assert_nil repl.file_diff(nil), "no payload, no diff"
      assert_nil repl.file_diff({}), "an empty payload has nothing to draw"
      assert_nil repl.file_diff({ "path" => "x", "before" => nil, "after" => nil }),
                 "a file that never existed did not change"
    end

    # The delete runs before the TUI ever sees the result, so a renderer that
    # reads the file itself finds nothing. The before-content has to come from
    # the payload, and the removal still has to draw every line it took away.
    def test_a_delete_draws_from_the_payload_though_the_file_is_gone
      Dir.mktmpdir do |dir|
        path = File.join(dir, "gone.md")
        File.write(path, "one\ntwo\n")
        repl = run_file_tool(build_repl, operation: "delete", path: path, after: nil)

        refute File.exist?(path), "the file is gone by the time the diff is drawn"
        git = entry_texts(repl).drop_while { |text| !text.match?(/\A[+-]\d/) }
        assert git.any?, "a delete gets a diff: #{entry_texts(repl).inspect}"
        assert_includes git.first, "-2"
        assert(git.any? { |row| row.include?("│ one") && row.include?("- ") })
        assert(git.any? { |row| row.include?("│ two") && row.include?("- ") })
      end
    end

    def test_pi_diff_keeps_three_context_lines_and_numbers_the_rows
      before = (1..40).map { |i| "line #{i}" }.join("\n")
      after = before.sub("line 20", "line twenty")

      git = git_texts(TUI::Diff.rows(before, after, path: "long.txt", width: 80))

      assert_includes git.first, "+1"
      assert_includes git.first, "-1"
      assert_includes git.first, "1 hunk"
      assert_includes git.first, "at line 20"
      assert(git.any? { |row| row.include?("│ line 17") })
      assert(git.any? { |row| row.include?("│ line 18") })
      assert(git.any? { |row| row.include?("- │ line 20") && row.include?("▌") },
             "the deletion is striped and numbered: #{git.inspect}")
      assert(git.any? { |row| row.include?("+ │ line twenty") })
      assert(git.any? { |row| row.include?("│ line 21") })
      assert(git.any? { |row| row.include?("│ line 23") })
      refute(git.any? { |row| row.include?("│ line 16") }, "context beyond the hunk is not shown")
      refute(git.any? { |row| row.include?("│ line 40") })
      refute git.any? { |row| row.include?("unmodified lines") }, "one hunk has no gap"
    end

    def test_pi_diff_collapses_distant_regions_into_a_gap_rule
      before = (1..40).map { |i| "line #{i}" }.join("\n")
      after = before.sub("line 20", "line twenty").sub("line 30", "line thirty")

      git = git_texts(TUI::Diff.rows(before, after, path: "long.txt", width: 80))

      assert_includes git.first, "2 hunks"
      assert(git.any? { |row| row.include?("unmodified lines") && row.include?("─") },
             "gaps render as a rule")
            gap_row = git.find { |row| row.include?("unmodified lines") }
      assert gap_row && gap_row.include?("3 unmodified lines"), "the skipped run is counted: #{gap_row.inspect}"
      refute_includes git, "│ line 25", "hidden gap lines are not echoed"
    end

    def test_new_files_number_the_new_lines_from_one
      git = git_texts(TUI::Diff.rows(nil, "alpha\nbeta\n", path: "fresh.md", width: 80))

      assert(git.first.include?("+2") && git.first.include?("1 hunk"),
             "the summary carries the count: #{git.first.inspect}")
      assert(git.any? { |row| row.include?("+ │ alpha") }, "a new file is all additions")
      assert(git.any? { |row| row.start_with?("▌") && row.include?("│ alpha") && row.include?("+ ") },
             "the row keeps the add stripe")
      assert_operator git.length, :==, 5, "summary + opening rule + 2 lines + closing rule"
    end

    def test_a_large_rewrite_is_capped_with_a_more_row
      before = (1..1000).map { |i| "old #{i}" }.join("\n")
      after = (1..1000).map { |i| "new #{i}" }.join("\n")

      rows = TUI::Diff.rows(before, after, path: "big.txt", width: 80)
      git = git_texts(rows)

      assert_equal 2 + TUI::Diff::MAX_ROWS + 2, rows.length,
                   "summary + opening rule + capped body + closing rule + the more row"
      assert_includes git, "  … (1968 more diff lines)"
    end

    def test_diff_is_nil_for_binary_and_identical_content
      assert_nil TUI::Diff.rows("a\0b", "a\0c", path: "bin")
      assert_nil TUI::Diff.rows("same\n", "same\n", path: "same.md")
    end

    def test_long_diff_lines_are_truncated_to_the_view_width
      rows = TUI::Diff.rows("a" * 300, "b" * 300, path: "long.txt", width: 60)
      body = rows.select { |segments| segments.first[0] == "▌" }

      assert_equal 2, body.length, "one deletion and one addition"
      assert(body.all? { |segments| segments.any? { |(text, _)| text.end_with?("…") } },
             "the content is cut with an ellipsis, not wrapped: #{body.inspect}")
    end

    def test_diff_bands_fill_the_full_width
      rows = TUI::Diff.rows("one\n", "two\n", path: "f.rb", width: 60)
      bands = rows.select { |segments| segments.first[0] == "▌" }

      assert_equal 2, bands.length
      bands.each do |segments|
        fill = segments.last
        assert_equal " ", fill[0]
        assert_equal TUI::LogView::FILL, fill[2], "the band asks LogView to paint to the edge"
        assert_includes [ TUI::Diff::BG_ADD, TUI::Diff::BG_DEL ], fill[1]
      end
    end

    def test_resumed_writes_replay_their_diff
      call = {
        "id" => "call_1",
        "type" => "function",
        "function" => {
          "name" => "file_write",
          "arguments" => JSON.generate({ "operation" => "write", "path" => "notes.md",
                                          "content" => "one\nTWO\nthree\n" })
        }
      }
      messages = [
        { "role" => "user", "content" => "edit it" },
        { "role" => "assistant", "content" => "", "tool_calls" => [ call ] },
        { "role" => "tool", "tool_call_id" => "call_1",
          "content" => "Written 14 characters",
          "ui_diff" => { "path" => "notes.md", "before" => "one\ntwo\nthree\n",
                         "after" => "one\nTWO\nthree\n" } },
        { "role" => "assistant", "content" => "done" }
      ]

      entries = TUI::Transcript.entries(messages, width: 73)
      texts = entries.map { |entry| entry[:segments].map(&:first).join }

      diff_ix = texts.index { |text| text.match?(/\A[+-]\d/) }
      assert diff_ix, "the diff is rebuilt under the tool row: #{texts.inspect}"
      assert(texts.any? { |text| text.include?("│ two") && text.include?("- ") })
      assert(texts.any? { |text| text.include?("│ TWO") && text.include?("+ ") })
      assert_equal 4, entries[diff_ix + 1][:indent], "the replayed diff uses the live indent"
      assert_equal "─", texts[diff_ix + 1], "with its opening rule"
    end

    def test_resume_without_a_saved_diff_keeps_the_tool_row_only
      messages = [
        { "role" => "user", "content" => "edit it" },
        { "role" => "assistant", "content" => "", "tool_calls" => [
          { "id" => "call_1", "type" => "function",
            "function" => { "name" => "file_write",
                            "arguments" => JSON.generate({ "operation" => "write",
                                                           "path" => "notes.md" }) } }
        ] },
        { "role" => "tool", "tool_call_id" => "call_1", "content" => "Written 1 characters" }
      ]

      texts = TUI::Transcript.entries(messages, width: 73)
                    .map { |entry| entry[:segments].map(&:first).join }

      refute(texts.any? { |text| text.match?(/\A[+-]\d/) }, "no metadata, no diff")
    end

    def test_subagent_event_adds_a_transcript_row
      repl = build_repl
      log = repl.instance_variable_get(:@log)
      before = log.entry_count
      repl.apply_event([ :subagent, { run_id: "r1", agent: "writer", phase: "started", detail: "write a poem" } ])
      repl.apply_event([ :subagent, { run_id: "r1", agent: "writer", phase: "done", detail: "3s" } ])

      assert_equal before + 2, log.entry_count
      texts = (before...(before + 2)).map do |i|
        log.entry_at(i).map(&:first).join
      end
      assert_includes texts.first, "subagent"
      assert_includes texts.first, "writer"
      assert_includes texts.first, "write a poem"
    end

    # --- dangerous-action confirmation ---------------------------------

    # A write to an existing file is a dangerous action: the worker must ask
    # through the prompt instead of blocking forever on an answer nothing
    # could give.
    def test_dangerous_action_asks_through_the_prompt_and_allows
      repl = build_repl
      callback = repl.confirm_callback
      answer = nil
      worker = Thread.new do
        answer = callback.call("file_write", { "operation" => "write", "path" => "/tmp/notes.md" })
      end

      event = repl.instance_variable_get(:@events).pop
      assert_equal :confirm, event[0], "the ask is published to the App thread"
      assert_equal "file_write", event[1]
      list = repl.instance_variable_get(:@confirm_prompt)
      log = repl.instance_variable_get(:@log)
      before = log.entry_count
      repl.apply_event(event)

      texts = log.instance_variable_get(:@entries).map { |entry| entry.map(&:first).join }
      assert texts.any? { |t| t.include?("⚠ write /tmp/notes.md") },
             "the question is in the transcript: #{texts.inspect}"
      assert_same list, repl.instance_variable_get(:@prompt).list

      # ← moves the highlight onto Allow, enter commits it.
      list.handle_key(::TUI::Key.new(:left))
      list.handle_key(::TUI::Key.new(:enter))

      assert worker.join(2), "answering the prompt releases the worker"
      assert_equal true, answer, "the highlighted choice commits"
      assert_nil repl.instance_variable_get(:@prompt).list, "the keyboard is back"

      # The exchange is collapsed back out: nothing of it remains but one
      # blank row where it used to be.
      after = log.instance_variable_get(:@entries).map { |entry| entry.map(&:first).join }
      assert_equal before, after.length - 1, "everything except one blank is taken out"
      refute after.any? { |t| t.include?("⚠") || t.include?("Allow") || t.include?("✓ allowed") },
             "the ask is not kept in the record: #{after.inspect}"
    end

    def test_the_highlight_starts_on_reject_and_enter_then_denies
      replit = build_repl
      answer = nil
      worker = Thread.new do
        answer = replit.confirm_callback
                     .call("file_write", { "operation" => "write", "path" => "/tmp/a" })
      end
      replit.apply_event(replit.instance_variable_get(:@events).pop)

      list = replit.instance_variable_get(:@confirm_prompt)

      list.handle_key(::TUI::Key.new(:enter))
      assert worker.join(2)
      assert_equal false, answer, "a blind enter rejects, it never allows"
    end

    def test_right_arrow_moves_to_reject_and_esc_rejects
      replit = build_repl
      answer = nil
      worker = Thread.new do
        answer = replit.confirm_callback
                     .call("shell_exec", { "command" => "rm -rf build" })
      end
      replit.apply_event(replit.instance_variable_get(:@events).pop)

      list = replit.instance_variable_get(:@confirm_prompt)
      list.handle_key(::TUI::Key.new(:right))
      list.handle_key(::TUI::Key.new(:enter))
      assert worker.join(2)
      assert_equal false, answer
    end

    def test_each_confirmation_gets_its_own_answer_queue
      repl = build_repl
      callback = repl.confirm_callback

      first = Thread.new { callback.call("file_write", { "operation" => "write", "path" => "/tmp/a" }) }
      first_event = repl.instance_variable_get(:@events).pop
      repl.apply_event(first_event)
      repl.instance_variable_get(:@confirm_prompt).handle_key(::TUI::Key.new(:left))
      repl.instance_variable_get(:@confirm_prompt).handle_key(::TUI::Key.new(:enter))
      assert first.join(2)

      second = Thread.new { callback.call("file_write", { "operation" => "write", "path" => "/tmp/b" }) }
      second_event = repl.instance_variable_get(:@events).pop
      refute_equal first_event[3], second_event[3], "an old answer cannot leak into the next ask"
      repl.apply_event(second_event)
      repl.instance_variable_get(:@confirm_prompt).handle_key(::TUI::Key.new(:escape))
      assert second.join(2)
      assert_equal false, second.value
    end

    # --- the question ---------------------------------------------------

    def test_picking_an_option_answers_the_question_with_that_option
      repl = build_repl
      answer = nil
      worker = Thread.new do
        answer = repl.send(:ask_callback).call(question: "Where should it go?",
                                        options: [ { label: "New file" }, { label: "Extend 018" } ])
      end
      repl.apply_event(repl.instance_variable_get(:@events).pop)
      list = repl.instance_variable_get(:@confirm_prompt)

      list.handle_key(::TUI::Key.new(:right))
      list.handle_key(::TUI::Key.new(:enter))

      assert worker.join(2)
      assert_equal({ outcome: :option, index: 1, label: "Extend 018" }, answer)
    end

    # "Other" is the last chip on every question, and choosing it moves the
    # answer to the prompt box: a second inline editor inside a prompt that
    # already is one would be the wrong shape.
    def test_other_takes_the_next_typed_line_as_the_answer
      repl = build_repl
      answer = nil
      worker = Thread.new do
        answer = repl.send(:ask_callback).call(question: "What should I call it?",
                                        options: [ { label: "A" }, { label: "B" } ])
      end
      repl.apply_event(repl.instance_variable_get(:@events).pop)
      list = repl.instance_variable_get(:@confirm_prompt)

      list.handle_key(::TUI::Key.new(:right))
      list.handle_key(::TUI::Key.new(:right))
      list.handle_key(::TUI::Key.new(:enter))

      assert list.awaiting_text?, "Other hands the keyboard back to the prompt"
      list.deliver_text("something else")

      assert worker.join(2)
      assert_equal({ outcome: :custom, text: "something else" }, answer)
    end

    # A confirmation escapes to "no". A question has no safe default to escape
    # to, so esc must not answer it: the deadline does.
    # A question has no deadline, so esc is the only way out of one: it stops
    # the turn and tells the worker it was cancelled.
    #
    # The bug this test exists for: the first fix released the worker by putting
    # `:stop` on the worker's own queue, which is the signal that ends the
    # thread — one esc and the terminal never answered again. So the test asks
    # both halves: the worker is released, and nothing was asked to stop the
    # thread for good.
    def test_escape_stops_the_turn_instead_of_the_worker
      repl = build_repl
      repl.instance_variable_set(:@busy, true)
      answer = :unset
      worker = Thread.new do
        answer = repl.send(:ask_callback).call(question: "Anyone?", options: [ { label: "A" }, { label: "B" } ])
      end
      repl.apply_event(repl.instance_variable_get(:@events).pop)
      list = repl.instance_variable_get(:@confirm_prompt)

      list.handle_key(::TUI::Key.new(:escape))

      assert worker.join(2), "the worker is released from the question"
      assert_equal({ outcome: :cancelled }, answer)
      assert repl.instance_variable_get(:@stopping), "the turn is cancelled"
      assert_empty repl.instance_variable_get(:@mailbox),
                   "escaping must not signal the worker thread to stop"
      refute list.active?, "the exchange is taken back out of the transcript"
    end

    # While the question is up the mouse stays with the log, so the path or
    # command can be drag-selected and copied before answering.
    def test_selection_keys_reach_the_log_while_the_confirmation_is_up
      list = Rubot::TUI::ConfirmPrompt.new(log: Rubot::TUI::LogView.new)
      list.ask("file_write", { "operation" => "write", "path" => "/tmp/x" }, answered: Queue.new)

      refute list.handle_key(::TUI::Key.new(:mouse_press)), "mouse keys pass through to the log bindings"
      refute list.handle_key(::TUI::Key.new(:page_up)), "scrolling passes through too"
    end

    # A stray keystroke during the ask is swallowed, never smuggled into the
    # prompt buffer and never read as an answer.
    def test_stray_keys_are_swallowed_while_the_confirmation_is_up
      list = Rubot::TUI::ConfirmPrompt.new(log: Rubot::TUI::LogView.new)
      answered = Queue.new
      list.ask("file_write", { "operation" => "write", "path" => "/tmp/x" }, answered: answered)

      assert list.handle_key(::TUI::Key.printable("n")), "unchosen keys are eaten"
      assert_empty answered, "typewriting never answers"
      assert list.active?
    end

    def test_log_view_wraps_long_entries
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 20, 10))
      index = view.add_entry([ [ "hello ", :text ], [ "world " * 10, :text ] ])

      assert_equal 0, index
      # 50-char message wrapped at 20 cells must exceed one row
      assert view.instance_variable_get(:@lines).size > 1
    end

    def test_log_view_set_entry_replaces_in_place
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 40, 10))
      index = view.add_entry([ [ "one", :text ] ])
      view.set_entry(index, [ [ "two", :text ] ])

      lines = view.instance_variable_get(:@lines)
      assert_equal 1, lines.size
      assert_equal [ [ "two", :text ] ], lines.first
    end

    def test_log_view_hard_breaks_on_newlines
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 40, 10))
      view.add_entry([ [ "one\ntwo", :text ] ])

      rows = view.instance_variable_get(:@lines)
      assert_equal 2, rows.size
      assert_equal [ [ "one", :text ] ], rows[0]
      assert_equal [ [ "two", :text ] ], rows[1]
    end

    # The scrollbar sits in the last column; wrapped text must stop one cell
    # short of it instead of running underneath it.
    def test_wrapped_rows_stay_clear_of_the_scrollbar_column
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 20, 4))
      6.times { |i| view.add_entry([ [ "row #{i}", :text ] ]) }
      view.add_entry([ [ "x" * 100, :text ] ])
      view.render(::TUI::Canvas.new(20, 4))

      width = view.content_width
      assert_equal 19, width
      view.instance_variable_get(:@lines).each do |row|
        assert_operator row.sum { |(text, _)| ::TUI::Text.width(text.to_s) }, :<=, width,
                        "row reaches the scrollbar: #{row.inspect}"
      end
    end

    # A continuation row of a list item starts under the marker indent, so
    # the cells that indent takes are not free for text. Counting the row
    # from zero made every wrapped item overflow by the marker width and
    # lose its last characters off the right edge.
    def test_wrapped_list_item_rows_do_not_overflow_the_marker_indent
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 24, 14))
      view.add_entry(TUI::Markdown.to_segments("- alpha beta gamma delta epsilon zeta eta theta iota\n"),
                     keep_leading: true, indent: 2)

      rows = view.instance_variable_get(:@lines)
      assert_operator rows.size, :>, 2, "the item must wrap twice: #{rows.inspect}"
      rows.each do |row|
        assert_operator row.sum { |(text, _style)| ::TUI::Text.width(text.to_s) }, :<=, view.content_width,
                        "wrapped item row overflows by the marker width: #{row.inspect}"
      end
    end

    # A wrapped list item should continue under the item's text, not under
    # the bullet.
    def test_wrapped_list_items_hang_under_the_item_text
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 30, 10))
      view.add_entry([ [ "  • alpha beta gamma delta epsilon zeta eta theta", nil ] ],
                     keep_leading: true, indent: 2)

      rows = view.instance_variable_get(:@lines).map { |row| row.map(&:first).join }
      assert_operator rows.size, :>, 1, "the item must wrap"
      first_text = rows[0].index("alpha")
      rows[1..].each do |row|
        assert_equal first_text, row.index(row.strip),
                     "continuation starts under the item text: #{row.inspect}"
      end
    end

    # End to end through the markdown renderer: the marker sits at the
    # paragraph indent, and a wrapped item continues under its text. The
    # bullet and the number share one marker column, so the item text — and
    # every wrapped row under it — starts at the same column in both kinds.
    def test_markdown_list_items_hang_under_their_text
      bullet = list_rows("- alpha beta gamma delta epsilon zeta\n")
      numbered = list_rows("1. alpha beta gamma delta epsilon zeta\n")

      assert bullet.first.start_with?("  •  "), "the bullet sits at the entry indent: #{bullet.inspect}"
      assert numbered.first.start_with?("  1. "), "the number sits at the entry indent: #{numbered.inspect}"

      bullet_text = bullet.first.index("alpha")
      numbered_text = numbered.first.index("alpha")
      assert_equal bullet_text, numbered_text, "both markers put the text in the same column"

      [ [ bullet, "a bullet" ], [ numbered, "a number" ] ].each do |rows, label|
        rows.drop(1).each do |row|
          assert_equal bullet_text, row.index(row.strip),
                       "#{label} continues under its text: #{row.inspect}"
        end
      end
    end


    def test_markdown_formatter_blocks_and_inline
      segs = TUI::Markdown.to_segments("# Title\n\n**bold** *em* `code` [link](http://x)~~s~~\n\n- a\n- b\n\n```ruby\nputs 1\n```")
      styles = segs

      assert styles.include?([ "# ", :md_h1 ]), styles.inspect
      assert styles.any? { |(t, _)| t == "Title" }
      assert styles.include?([ "bold", :md_bold ]), styles.inspect
      assert styles.include?([ "em", :md_italic ]), styles.inspect
      assert styles.include?([ "code", :md_code ]), styles.inspect
      assert styles.include?([ "link", :md_link ]), styles.inspect
      assert styles.include?([ "s", :md_strike ]), styles.inspect
      assert styles.include?([ "•  ", :accent ]), styles.inspect
      assert styles.include?([ "  puts 1", :md_code_blk ]), styles.inspect
      # No leading or trailing row break: the log handles spacing.
      refute_equal "\n", styles.first[0]
      refute_equal "\n", styles.last[0]
    end

    def test_markdown_table_renders_full_grid
      rows = TUI::Markdown.to_segments("| col a | col b |\n|---|---|\n| short | big value |\n| x | y |")
        .slice_when { |(t, _), (u, _)| t == "\n" }.map { |r| r.map(&:first).join }

      assert rows.first.start_with?("\u250c"), "top border: #{rows.first.inspect}"
      assert rows.any? { |r| r.start_with?("\u251c") }, "header separator"
      assert rows.last.start_with?("\u2514"), "bottom border"
      assert rows[1].include?("\u2502 col a \u2502"), "cells boxed: #{rows[1].inspect}"
    end

    def test_markdown_table_styles_header_and_inline_cells
      segs = TUI::Markdown.to_segments("| a | **b** |\n|---|---|\n| c | **d** |")

      assert segs.include?([ "a", :md_table_head ]), "header text is bold: #{segs.inspect}"
      assert segs.include?([ "b", :md_bold ]), "header markup parses"
      assert segs.include?([ "d", :md_bold ]), "body markup parses"
      assert segs.include?([ "c", nil ]), "body text keeps the default style"
      assert segs.any? { |(t, s)| t.start_with?("\u250c") && s == :md_table_border }, "bright border"
    end

    def test_markdown_table_width_ignores_markup
      rows = TUI::Markdown.to_segments("| **b** | y |\n|---|---|\n| x | z |")
        .slice_when { |(t, _), (u, _)| t == "\n" }.map { |r| r.map(&:first).join.chomp }

      assert_equal "\u2502 b \u2502 y \u2502", rows[1],
                   "bold markers do not count for column width: #{rows[1].inspect}"
      assert_equal rows[1].length, rows[3].length, "cells line up"
    end

    def test_markdown_plain_text_unchanged
      assert_equal [ [ "plain", nil ] ], TUI::Markdown.to_segments("plain")
    end

    def test_prompt_shift_enter_adds_newline_and_enter_submits
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      submits = []
      input.on(:submit) { |v| submits << v }
      "one".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      input.handle_key(::TUI::Key.new(:shift_enter))
      "two".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }

      assert_equal "one\ntwo", input.value
      input.handle_key(::TUI::Key.new(:enter))
      assert_equal [ "one\ntwo" ], submits

      # With a multiline buffer, up/down navigate lines instead of history.
      input2 = TUI::PromptInput.new(%w[msg-a], TUI::COMPLETABLE)
      "x".each_char { |c| input2.handle_key(::TUI::Key.printable(c)) }
      input2.handle_key(::TUI::Key.new(:shift_enter))
      input2.handle_key(::TUI::Key.new(:up))
      assert_equal [ "x", "" ], input2.buffer.lines
      # Single-line buffers still hit history.
      input3 = TUI::PromptInput.new(%w[msg-a], TUI::COMPLETABLE)
      input3.handle_key(::TUI::Key.new(:up))
      assert_equal "msg-a", input3.value
    end

    def test_shift_enter_sequences_from_kitty_xterm_and_tmux
      assert_equal :shift_enter, ::TUI::Term::SEQUENCES["\e[13;2u"], "kitty keyboard protocol"
      assert_equal :shift_enter, ::TUI::Term::SEQUENCES["\e[27;2;13~"], "xterm modifyOtherKeys / tmux"
      assert_equal :enter, ::TUI::Term::SEQUENCES.fetch("\r", :enter)
    end

    def test_ctrl_arrow_sequences_are_understood
      table = ::TUI::Term::SEQUENCES

      assert_equal :ctrl_left, table["\e[1;5D"], "xterm/kitty/iTerm2 ctrl+left"
      assert_equal :ctrl_right, table["\e[1;5C"], "xterm/kitty/iTerm2 ctrl+right"
      assert_equal :ctrl_left, table["\e[5D"], "terminals that omit the leading 1;"
      assert_equal :ctrl_right, table["\e[5C"]
      assert_equal :ctrl_left, table["\e[57350;5u"], "kitty CSI-u arrow code"
      assert_equal :ctrl_right, table["\e[57351;5u"]
    end

    def test_keys_the_keyboard_protocol_disambiguates
      table = ::TUI::Term::SEQUENCES

      assert_equal :escape, table["\e[27u"], "esc arrives as CSI 27u once the protocol is on"
      assert_equal :ctrl_c, table["\e[99;5u"], "ctrl+c arrives as CSI 99;5u, not 0x03"
      assert_equal :ctrl_d, table["\e[100;5u"]
      assert_equal :enter, table["\e[13u"]
      assert_equal :shift_enter, table["\e[13;3u"], "alt+enter also inserts a newline"
      assert_nil table["\e[97;3u"], "alt+letter stays unbound"
    end

    def test_read_key_understands_the_disambiguated_forms
      require "pty"
      reader, writer = PTY.open
      previous = $stdin
      $stdin = reader

      { "\e[13;2u" => :shift_enter, "\e[99;5u" => :ctrl_c,
        "\e[27u" => :escape, "\e[13u" => :enter, "\e[27;2;13~" => :shift_enter }.each do |sequence, expected|
        writer.write(sequence)
        assert_equal expected, ::TUI::Term.read_key(0.5)&.name,
                     "#{sequence.inspect} should read as #{expected.inspect}"
      end
    ensure
      $stdin = previous
      reader&.close
      writer&.close
    end
  end
end
