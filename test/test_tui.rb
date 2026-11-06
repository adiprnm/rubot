# frozen_string_literal: true

require "stringio"
require "test_helper"
require "rubot"

module Rubot
  # The TUI is driven by an off-screen App (fixed size, no terminal), the
  # same way ruby-tui's own snapshot modes work.
  class TestTUI < Minitest::Test
    StubInfo = Struct.new(:provider, :model, :tools, :name)

    def stub_agent
      agent = Object.new
      def agent.startup_info
        { provider: "openai", model: "gpt-test", tools: 3 }
      end

      agent
    end

    def build_repl
      repl = TUI.new(stub_agent)
      repl.send(:build_ui)
      repl.send(:paint_banner)
      repl
    end

    def teardown
      FileUtils.rm_f(TUI::HISTORY_FILE)
    end

    # render_lines keeps per-segment SGR resets between differently styled
    # runs; strip them before string matching.
    def plain(lines)
      lines.map { |l| l.gsub(/\e\[[0-9;?]*[a-zA-Z]/, "").gsub(/\e\]8;;\e\\/, "") }
    end

    def test_frame_renders_banner_prompt_and_status
      repl = build_repl
      lines = repl.instance_variable_get(:@app).render_lines

      view = plain(lines)

      assert lines.first.include?("rubot"), "should show the banner title, got: #{lines.first}"
      assert view.any? { |l| l.include?("provider openai") }, "should show banner info"
      refute view.any? { |l| l.include?("ready") }, "no \"ready\" text anywhere"
      assert view.any? { |l| l.include?("\u256d") && l.include?("\u256e") }, "should show the prompt border"
      refute view.any? { |l| l.include?("type a message") }, "no placeholder in the input"
      refute view.any? { |l| l.include?("enter send") }, "no key hints in the input"
    end

    def test_status_line_renders_below_input
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      prompt.handle_key(::TUI::Key.printable("h"))
      app = repl.instance_variable_get(:@app)
      view = plain(app.render_lines)
      status_ix = view.index { |l| l.include?("session default") }
      prompt_ix = view.index { |l| l.include?("h") }

      assert prompt_ix && status_ix, "both must render"
      assert_operator status_ix, :>, prompt_ix, "status row sits under the input"
    end

    def test_start_fresh_session_clears_agent_session
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      cleared = false
      agent.define_singleton_method(:clear_session) { cleared = true }

      repl.send(:start_fresh_session)

      assert cleared
    end

    def test_new_command_clears_conversation_but_keeps_banner
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      log = repl.instance_variable_get(:@log)
      banner_count = log.entry_count
      assert_operator banner_count, :>, 0, "banner present before /new"
      log.add_entry([ [ "hello", :text ] ])
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:clear_session) { nil }

      repl.send(:handle_command, "/new")
      repl.send(:pump)

      texts = log.instance_variable_get(:@entries).map { |e| e.map(&:first).join }
      assert_equal banner_count, texts.size, "conversation is dropped, banner is kept"
      refute texts.any? { |t| t.include?("hello") }, "conversation text is gone"
      assert texts.first.include?("rubot"), "heading still rendered"
      refute plain(app.render_lines).any? { |l| l.include?("Started a new session") }, "no text output"
    end

    def test_prompt_input_has_one_space_padding_inside_the_border
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      "hi".each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }
      view = plain(repl.instance_variable_get(:@app).render_lines)
      prompt_line = view.find { |l| l.include?("hi") }

      assert prompt_line, "prompt row renders"
      assert_equal 3, prompt_line.index("h"), "one space between the border and the text"
    end

    def test_assistant_stream_aligns_under_the_typed_prompt
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :entry, [ [ "❯ ", :accent ], [ "Hi met", :text ] ] ]
      ev << [ :stream_start ]
      ev << [ :chunk, "Halo! Ada yang bisa gue bantu?" ]
      repl.send(:pump)

      view = plain(repl.instance_variable_get(:@app).render_lines)
      user_line = view.find { |l| l.include?("Hi met") }
      reply_line = view.find { |l| l.include?("Halo!") }

      assert user_line && reply_line, "both rows render"
      assert_equal user_line.index("H"), reply_line.index("H"),
                   "agent text sits where the user's text starts, two cells after the marker"
    end

    def test_assistant_wrapped_lines_keep_the_left_padding
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 24, 10))
      view.add_entry([ [ "word " * 20, nil ] ], indent: 2)

      rows = view.instance_variable_get(:@lines)
      assert_operator rows.size, :>, 1, "the paragraph must wrap"
      rows.each { |row| assert_equal "  ", row.first[0], "every wrapped row is padded: #{row.inspect}" }
    end

    def test_prompt_grows_with_newlines
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      "one".each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }
      prompt.handle_key(::TUI::Key.new(:shift_enter))
      "two".each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }

      view = plain(repl.instance_variable_get(:@app).render_lines)
      one = view.index { |l| l.include?("one") }
      two = view.index { |l| l.include?("two") }

      assert one && two, "both prompt lines render"
      assert_equal one + 1, two, "the prompt occupies consecutive rows"
    end

    def test_tool_call_splits_streamed_answer
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :stream_start ]
      ev << [ :chunk, "first answer" ]
      # The answer closes, one blank follows, then the tool call.
      ev << [ :tool_call, "shell_exec", { "command" => "true" } ]
      ev << [ :tool_done, "shell_exec" ]
      ev << [ :chunk, "second answer" ]
      ev << [ :stream_end ]
      repl.instance_variable_get(:@app).send(:run_timers)

      entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
      texts = entries.map { |e| e.map(&:first).join.gsub("\n", "|") }
      tool_ix = texts.index { |t| t.include?("shell_exec") }

      assert_equal "first answer", texts[tool_ix - 2]
      assert_equal [ [ "", nil ] ], entries[tool_ix - 1], "one spacer between answer and tool"
      assert_includes texts, "second answer", "post-tool answer is its own entry"
    end

    def test_turn_footer_reports_duration_and_running_totals
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      ev = repl.instance_variable_get(:@events)
      now = repl.send(:monotonic_now)

      ev << [ :stream_start ]
      repl.send(:pump)
      repl.instance_variable_set(:@turn_started_at, now - 145)
      ev << [ :stream_end ]
      repl.send(:pump)

      line = plain(app.render_lines).find { |l| l.include?("Turn took") }
      assert line, "a turn footer is shown"
      assert_includes line, "\u273b Turn took 2m 25s"
      assert_includes line, "(Total time 2m 25s \u00b7 1 turn)"

      ev << [ :stream_start ]
      repl.send(:pump)
      repl.instance_variable_set(:@turn_started_at, now - 1755)
      ev << [ :stream_end ]
      repl.send(:pump)

      line = plain(app.render_lines).reverse.find { |l| l.include?("Turn took") }
      assert_includes line, "Turn took 29m 15s"
      assert_includes line, "(Total time 31m 40s \u00b7 2 turns)"
    end

    def test_tool_summary_truncates_to_a_cell_budget
      long = { "command" => "x" * 200 }

      summary = build_repl.send(:tool_summary, "shell_exec", long)

      assert summary.end_with?("\u2026"), "ellipsis marks the cut: #{summary.inspect}"
      assert_operator ::TUI::Text.width(summary), :<=, 64
    end

    def test_tool_line_fits_inside_the_log_width
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      ev = repl.instance_variable_get(:@events)
      app.render_lines # lay the log out so it knows its width
      ev << [ :tool_call, "shell_exec", { "command" => "y" * 500 } ]
      repl.send(:pump)

      row = plain(app.render_lines).find { |l| l.include?("shell_exec") }
      assert row, "tool line must render"
      assert_operator ::TUI::Text.width(row.strip), :<=, repl.instance_variable_get(:@log).content_width,
                      "tool row must not exceed the log width: #{row.inspect}"
      assert row.include?("\u2026"), "long arguments are cut"
    end

    def test_submit_echoes_prompt_on_screen
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)

      prompt.handle_key(::TUI::Key.printable("h"))
      prompt.handle_key(::TUI::Key.printable("i"))
      prompt.handle_key(::TUI::Key.new(:enter))
      app.send(:run_timers)

      view = plain(app.render_lines)
      assert view.any? { |l| l.include?("\u276f hi") }, "prompt should echo with a marker: #{view.map(&:strip).inspect}"
    end

    def test_prompt_input_enter_emits_submit
      # Regression: ::TUI::Events::SUBMIT once shadowed by Rubot::TUI's namespace.
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      events = []
      input.on(:submit) { |v| events << v }
      "hi".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      input.handle_key(::TUI::Key.new(:enter))

      assert_equal [ "hi" ], events
    end

    def test_tool_calls_render_pretty
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :tool_call, "shell_exec", { "command" => "ruby --version" } ]
      ev << [ :tool_done, "shell_exec" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      view = plain(app.render_lines)
      # One line per tool call: the ⚒ row is replaced by ✓, args preserved.
      tool_lines = view.select { |l| l.include?("shell_exec") }
      assert_equal 1, tool_lines.size, "single tool line, got: #{tool_lines.inspect}"
      assert tool_lines.first.include?("\u2713") && tool_lines.first.include?("ruby --version"),
             "done line keeps the summary: #{tool_lines.first.inspect}"
      refute tool_lines.first.include?("\u2692")

      entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
      done = entries.find { |e| e.any? { |(t, _)| t.include?("shell_exec") } }
      assert_includes done, [ "✓ ", :tool_ok ], "completed marker uses the calm green"
      assert_includes done, [ "shell_exec", :muted ], "completed name recedes"
    end

    def test_back_to_back_tool_calls_have_no_spacer
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :stream_start ]
      ev << [ :tool_call, "a_tool", { "x" => "1" } ]
      ev << [ :tool_done, "a_tool" ]
      ev << [ :tool_call, "b_tool", { "y" => "2" } ]
      ev << [ :tool_done, "b_tool" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
      texts = entries.map { |e| e.map(&:first).join }
      a_ix  = texts.index { |t| t.include?("a_tool") }
      b_ix  = texts.index { |t| t.include?("b_tool") }

      between = texts[(a_ix + 1)...b_ix] || []
      assert_empty between,
                    "tool rows adjacent"
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
      assert styles.include?([ "  • ", :accent ]), styles.inspect
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

    def test_stream_start_puts_blank_between_prompt_and_answer
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      events = repl.instance_variable_get(:@events)
      events << [ :entry, [ [ "❯ ", :accent ], [ "q", :text ] ] ]
      events << [ :stream_start ]
      events << [ :chunk, "hi" ]
      app.send(:run_timers)

      entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
      assert_equal [ [ "", nil ] ], entries[-2]
    end

    def test_screen_el_comes_before_row_content
      canvas = ::TUI::Canvas.new(3, 1)
      canvas.put(0, 0, "abc", :text)
      out = StringIO.new
      ::TUI::Screen.new(out, size: [ 1, 3 ]).present(canvas)
      seq = out.string

      assert seq.include?("\e[1;1H"), "row must be addressed, got: #{seq.inspect}"
      assert seq.index("\e[K") < seq.index("abc"), "EL must precede the row: #{seq.inspect}"
    end

    def test_prompt_input_history_navigation
      input = TUI::PromptInput.new(%w[msg-a msg-b], TUI::COMPLETABLE)
      input.handle_key(::TUI::Key.new(:up))
      assert_equal "msg-b", input.value
      input.handle_key(::TUI::Key.new(:up))
      assert_equal "msg-a", input.value
      input.handle_key(::TUI::Key.new(:down))
      assert_equal "msg-b", input.value
      input.handle_key(::TUI::Key.new(:down))
      assert_equal "", input.value # back to the empty draft
    end

    def test_prompt_input_completion
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      "/h".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      input.handle_key(::TUI::Key.new(:tab))
      assert_equal "/help", input.value
      input.handle_key(::TUI::Key.new(:tab))
      assert_equal "/help", input.value # only one match for /h
    end

    def test_prompt_input_tab_reaches_all_commands
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      input.handle_key(::TUI::Key.printable("/"))
      input.handle_key(::TUI::Key.new(:tab))
      first = input.value

      30.times do
        input.handle_key(::TUI::Key.new(:tab))
        break if input.value == first
      end

      assert_equal first, input.value, "tab must cycle back to the first match"
    end

    def test_channel_registry_maps_tui
      assert_equal Channels::TuiChannel, Channels::Registry::CHANNEL_MAP["tui"]
      assert_equal Channels::TuiChannel, Channels::Registry::CHANNEL_MAP["repl"]
    end

    # Drag-to-select and wheel scrolling both ride on SGR mouse reports.
    # A compat patch once replaced the gem's parser with a wheel-only one,
    # turning press/drag into :unknown keys and silently killing selection.
    def test_mouse_reports_keep_their_coordinates_and_button
      refute ::TUI::Term.respond_to?(:rubot_original_read_escape),
             "compat must not override Term.read_escape"

      key = ::TUI::Term.mouse_key(/\A\e\[<(\d+);(\d+);(\d+)([Mm])\z/.match("\e[<32;120;40M"))
      assert_equal :mouse_drag, key.name
      assert_equal 0, key.mouse_button
      assert_equal 119, key.mouse_x
      assert_equal 39, key.mouse_y

      press = ::TUI::Term.mouse_key(/\A\e\[<(\d+);(\d+);(\d+)([Mm])\z/.match("\e[<0;12;5M"))
      assert_equal :mouse_press, press.name
      assert_equal 11, press.mouse_x
      assert_equal 4, press.mouse_y
    end

    def test_selection_flow_highlights_and_copies
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 40, 10))
      view.add_entry([ [ "hello world", :text ] ])
      canvas = ::TUI::Canvas.new(40, 10)
      view.render(canvas)

      refute view.selection?
      view.begin_selection(2, 0)
      assert view.selection?
      view.extend_selection(8, 0)
      view.render(canvas) # the App repaints on its next tick

      assert_equal "llo wor", view.selection_text.strip
      assert_equal (2..8).to_a, styled_columns(canvas, 0, :selection)

      view.clear_selection
      refute view.selection?
      assert_nil view.selection_text
    end

    # Text selection behaves like a terminal's: linear, not rectangular.
    # The start row runs to the right edge, the rows between span the full
    # width, and the end row starts at the left edge — so the highlight and
    # the copied text follow the text, instead of being a bounding box.
    def test_selection_is_linear_across_rows
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 20, 5))
      view.add_entry([ [ "line one", :text ] ])
      view.add_entry([ [ "line two", :text ] ])
      view.add_entry([ [ "line three", :text ] ])
      canvas = ::TUI::Canvas.new(20, 5)
      view.render(canvas)

      view.begin_selection(7, 0)
      view.extend_selection(5, 2)
      view.render(canvas)

      assert_equal "e\nline two\nline t", view.selection_text
      assert_equal (7..19).to_a, styled_columns(canvas, 0, :selection)
      assert_equal (0..19).to_a, styled_columns(canvas, 1, :selection)
      assert_equal (0..5).to_a, styled_columns(canvas, 2, :selection)
    end

    # Dragging upwards selects the same text as dragging downwards over the
    # same cells, and blank rows in between stay in the selection.
    def test_selection_dragged_upwards_and_over_blank_rows
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 20, 5))
      view.add_entry([ [ "hello", :text ] ])
      view.add_entry([ [ "", :text ] ])
      view.add_entry([ [ "delta", :text ] ])
      canvas = ::TUI::Canvas.new(20, 5)
      view.render(canvas)

      view.begin_selection(2, 2)
      view.extend_selection(2, 0)
      view.render(canvas)

      assert_equal "llo\n\ndel", view.selection_text
      assert_equal (2..19).to_a, styled_columns(canvas, 0, :selection)
      assert_equal (0..19).to_a, styled_columns(canvas, 1, :selection)
      assert_equal (0..2).to_a, styled_columns(canvas, 2, :selection)
    end

    # The scrollbar and the padding in the copied lines would be noise; the
    # copy reads the log's own rows.
    def test_selection_copy_has_no_scrollbar_or_trailing_padding
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 20, 3))
      6.times { |i| view.add_entry([ [ "row #{i}", :text ] ]) }
      canvas = ::TUI::Canvas.new(20, 3)
      view.render(canvas)

      view.begin_selection(0, 0)
      view.extend_selection(19, 0)
      view.render(canvas)

      assert_equal "row 3", view.selection_text
    end

    # A terminal keeps its selection after the mouse is released; so does
    # the log. The copy still happens on release.
    def test_release_keeps_the_highlight_and_copies
      out = StringIO.new
      original = $stdout
      begin
        # Swapped before the App is built so its own output lands here too.
        $stdout = out
        repl = build_repl
        log = repl.instance_variable_get(:@log)
        log.clear
        log.add_entry([ [ "hello world", :text ] ])
        repl.instance_variable_get(:@app).render_frame

        log.begin_selection(2, 0)
        log.extend_selection(6, 0)
        repl.send(:copy_selection)
      ensure
        $stdout = original
      end

      assert log.selection?, "the highlight must survive the mouse release"
      assert_equal "hello", log.selection_text
      assert_includes out.string, "\e]52;c;#{Base64.strict_encode64("hello")}\a"
    end

    # A click without a drag deselects; it must not put one character on the
    # clipboard.
    def test_click_drops_the_highlight_without_copying
      out = StringIO.new
      original = $stdout
      begin
        $stdout = out
        repl = build_repl
        log = repl.instance_variable_get(:@log)
        log.clear
        log.add_entry([ [ "hello world", :text ] ])
        repl.instance_variable_get(:@app).render_frame

        log.begin_selection(2, 0)
        assert log.point_selection?
        repl.send(:copy_selection)
      ensure
        $stdout = original
      end

      refute log.selection?, "a click must dismiss the highlight"
      refute_includes out.string, "\e]52;"
    end

    # The highlight is screen-anchored, so anything that moves the rows or
    # turns the page drops it instead of leaving it over other text.
    def test_scrolling_and_typing_drop_the_highlight
      repl = build_repl
      log = repl.instance_variable_get(:@log)
      prompt = repl.instance_variable_get(:@prompt)
      5.times { |i| log.add_entry([ [ "row #{i}", :text ] ]) }
      repl.instance_variable_get(:@app).render_frame

      log.begin_selection(0, 0)
      assert log.selection?
      log.scroll_by(1)
      refute log.selection?, "scrolling must drop the highlight"

      log.begin_selection(0, 0)
      prompt.handle_key(::TUI::Key.printable("x"))
      refute log.selection?, "typing must drop the highlight"
    end

    # Column indexes of `row` painted with `style`.
    def styled_columns(canvas, row, style)
      sid = ::TUI::Style.id(style)
      styles = canvas.instance_variable_get(:@styles)[row]
      styles.each_index.select { |i| styles[i] == sid }
    end

    def test_markdown_bold_italic
      segs = TUI::Markdown.to_segments("***big***")

      assert segs.include?([ "big", :md_bold_italic ])
    end
  end
end
