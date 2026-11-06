# frozen_string_literal: true

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
      assert view.any? { |l| l.include?("\u256d") && l.include?("\u256e") }, "should show the input box border"
      refute view.any? { |l| l.include?("type a message") }, "no placeholder in the input"
      refute view.any? { |l| l.include?("enter send") }, "no key hints in the input"
    end

    def test_status_line_renders_below_input
      view = plain(build_repl.instance_variable_get(:@app).render_lines)
      status_ix = view.index { |l| l.include?("session default") }
      border_ix = view.index { |l| l.include?("\u256d") && l.include?("\u256e") }

      assert border_ix && status_ix, "both must render"
      assert_operator status_ix, :>, border_ix, "status row sits under the input"
    end

    def test_start_fresh_session_clears_agent_session
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      cleared = false
      agent.define_singleton_method(:clear_session) { cleared = true }

      repl.send(:start_fresh_session)

      assert cleared
    end

    def test_new_command_clears_silently
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      assert_operator app.render_lines.size, :>, 0, "banner present before /new"
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:clear_session) { nil }

      repl.send(:handle_command, "/new")
      app.send(:run_timers)

      assert_equal 0, repl.instance_variable_get(:@log).instance_variable_get(:@entries).size,
                   "screen must be emptied"
      refute plain(app.render_lines).any? { |l| l.include?("Started a new session") }, "no text output"
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
      assert_equal "second answer", texts.select { |t| !t.strip.empty? }.last, "post-tool answer is its own entry"
    end

    def test_tool_summary_truncates_with_ellipsis
      long = { "command" => "x" * 200 }

      expected = "x" * 64 + "\u2026"

      assert_equal expected, build_repl.send(:tool_summary, "shell_exec", long)
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
  end
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
      assert_equal "llo wo".ljust(40).rstrip, view.selection_text.strip
      view.clear_selection
      refute view.selection?
      assert_nil view.selection_text
    end

    def test_markdown_bold_italic
      segs = TUI::Markdown.to_segments("***big***")

      assert segs.include?([ "big", :md_bold_italic ])
    end
