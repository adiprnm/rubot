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

    def test_status_line_puts_session_metrics_left_of_session_info
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :status_right, "session default · openai · gpt-test" ]
      ev << [ :status_left, "$0.001 · cache 60% · ctx 8.2%" ]
      repl.send(:pump)

      line = plain(repl.instance_variable_get(:@app).render_lines)
        .find { |l| l.include?("$0.001") }

      assert line, "the metrics row renders"
      assert_includes line, "cache 60%"
      assert_includes line, "ctx 8.2%"
      assert_includes line, "session default", "session info keeps its spot on the right"
      assert_operator line.index("$0.001"), :<, line.index("session default"),
                      "metrics sit on the left: #{line.inspect}"
    end

    def test_status_line_truncates_metrics_before_session_info
      status = TUI::StatusLine.new
      status.layout(::TUI::Rect.new(0, 0, 30, 1))
      status.left = "$0.001 · cache 60% · ctx 8.2% · extra-wide-metric"
      status.right = "session default"
      canvas = ::TUI::Canvas.new(30, 1)
      status.render(canvas)

      row = plain(canvas.lines).first
      assert_operator ::TUI::Text.width(row), :<=, 30, row.inspect
      assert_includes row, "session default", "session info survives: #{row.inspect}"
      assert_includes row, "\u2026", "the cut is marked: #{row.inspect}"
    end

    def test_usage_footer_updates_after_a_turn
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:process) { |_msg, **_opts, &_blk| "ok" }
      agent.define_singleton_method(:flush_learning) { nil }
      agent.define_singleton_method(:usage_report) do
        { requests: 1, prompt_tokens: 1_000, cache_hit_rate: 0.6,
          context_used: 10_500, context_window: 128_000, context_percent: 8.2,
          cost: { "total" => 0.001234 } }
      end

      repl.send(:process_message, "hi")
      repl.send(:pump)

      view = plain(repl.instance_variable_get(:@app).render_lines)
      assert view.any? { |l| l.include?("$0.001 · cache 60% · ctx 8.2%") },
             "the footer carries the turn's usage: #{view.last(3).inspect}"
    end

    def test_command_output_gets_one_blank_line_above_and_below_and_left_padding
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:clear_session) { nil }
      log = repl.instance_variable_get(:@log)

      repl.send(:handle_command, "/clear")
      repl.send(:pump)

      texts = log.instance_variable_get(:@entries).map { |segments| segments.map(&:first).join }
      ix = texts.index { |text| text.include?("Session cleared.") }

      assert ix, "the command printed its message"
      assert_equal "", texts[ix - 1], "one blank line above"
      assert_equal "", texts[ix + 1], "one blank line below"
      refute_equal "", texts[ix - 2], "no double blank above"
      assert_equal 2, log.instance_variable_get(:@indents)[ix], "two cells of left padding"
    end

    def test_command_output_keeps_a_single_blank_between_consecutive_commands
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:clear_session) { nil }
      agent.define_singleton_method(:cancel!) { nil }
      log = repl.instance_variable_get(:@log)

      repl.send(:handle_command, "/clear")
      repl.send(:handle_command, "/stop")
      repl.send(:pump)

      texts = log.instance_variable_get(:@entries).map { |segments| segments.map(&:first).join }
      first = texts.index { |text| text.include?("Session cleared.") }
      second = texts.index { |text| text.include?("Stop requested.") }

      assert_equal first + 2, second, "only the shared blank line sits between them"
    end

    def test_plain_command_output_is_padded_with_blanks_and_two_spaces
      Dir.mktmpdir do |dir|
        repl = build_resume_repl(File.join(dir, "workspace"))
        repl.instance_variable_set(:@tui, false)
        out, _err = capture_io { repl.send(:handle_command, "/resume") }

        assert_includes out, "\n  · No saved sessions yet.\n"
      end
    end

    def test_clear_wipes_the_usage_footer
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:clear_session) { nil }
      ev = repl.instance_variable_get(:@events)
      ev << [ :status_left, "$0.001 · cache 60% · ctx 8.2%" ]
      repl.send(:pump)
      assert plain(repl.instance_variable_get(:@app).render_lines).any? { |l| l.include?("$0.001") }

      repl.send(:handle_command, "/clear")
      repl.send(:pump)

      refute plain(repl.instance_variable_get(:@app).render_lines).any? { |l| l.include?("$0.001") },
             "a cleared session has nothing to price"
    end

    def test_start_fresh_session_switches_to_a_new_id
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      switched = nil
      agent.define_singleton_method(:switch_session) { |name| switched = name }

      repl.send(:start_fresh_session)

      assert switched, "the launch switches to a fresh session"
      refute_equal "default", switched, "the id belongs to this launch only"
      assert_equal switched, repl.instance_variable_get(:@session_id)
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

    def test_a_cancelled_turn_skips_the_footer_and_the_blank_above_it
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:process) do |_message, on_stopped: nil, **_opts, &on_chunk|
        on_chunk&.call("half an answer")
        on_stopped&.call
        "half an answer\n\n#{Rubot::Agent::STOP_NOTICE}"
      end
      agent.define_singleton_method(:flush_learning) { nil }
      agent.define_singleton_method(:usage_report) { nil }

      repl.send(:process_message, "stop me")
      repl.send(:pump)

      entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
      texts = entries.map { |segments| segments.map(&:first).join }

      refute texts.any? { |t| t.include?("Turn took") }, "no turn footer after a stop"
      assert_equal "half an answer", texts[-2]
      assert_equal "", texts[-1], "one separator blank remains, no double blank"

      app = repl.instance_variable_get(:@app)
      line = app.render_lines.find { |l| l.include?("Operation canceled by user") }
      refute_nil line, "the cancellation notice shows above the input"
      assert_includes line, "38;5;203", "the notice is red"

      ev = repl.instance_variable_get(:@events)
      ev << [ :stream_start ]
      repl.send(:pump)
      repl.instance_variable_get(:@app).send(:run_timers)
      refute plain(app.render_lines).any? { |l| l.include?("Operation canceled by user") },
             "a new turn clears the notice"
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

    def test_submit_while_a_turn_runs_steers_it_instead_of_queueing
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      steered = []
      agent.define_singleton_method(:steer) do |text|
        steered << text
        true
      end
      repl.instance_variable_set(:@busy, true)
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      mailbox = repl.instance_variable_get(:@mailbox)

      "change course".each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }
      prompt.handle_key(::TUI::Key.new(:enter))
      app.send(:run_timers)

      assert_equal [ "change course" ], steered, "the line goes to the running turn"
      assert mailbox.empty?, "a steered line does not wait in the mailbox"
      view = plain(app.render_lines)
      steer_ix = view.index { |l| l.include?("\u21b3 change course") }
      assert steer_ix, "the steer is echoed with its own marker: #{view.map(&:strip).inspect}"
      assert_includes view[steer_ix], "steered", "the echo says it steered the turn"
      assert_equal "", view[steer_ix - 1].strip, "one blank row above the steer"
      assert_equal "", view[steer_ix + 1].strip, "one blank row below the steer"
      refute_equal "", view[steer_ix - 2].strip, "no double blank above"
    end

    def test_a_steer_splits_the_streaming_answer_around_it
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:steer) { |_text| true }
      app = repl.instance_variable_get(:@app)
      events = repl.instance_variable_get(:@events)
      prompt = repl.instance_variable_get(:@prompt)

      events << [ :stream_start ]
      events << [ :chunk, "before the steer" ]
      repl.send(:pump)

      "use /tmp instead".each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }
      prompt.handle_key(::TUI::Key.new(:enter))
      app.send(:run_timers)

      events << [ :chunk, "after the steer" ]
      repl.send(:pump)

      view = plain(app.render_lines)
      before_ix = view.index { |l| l.include?("before the steer") }
      steer_ix = view.index { |l| l.include?("\u21b3 use /tmp instead") }
      after_ix = view.index { |l| l.include?("after the steer") }

      assert before_ix && steer_ix && after_ix, "all three rows render: #{view.map(&:strip).inspect}"
      assert_operator before_ix, :<, steer_ix
      assert_operator steer_ix, :<, after_ix,
                      "the answer after the steer starts below it, not above"
      refute_includes view[before_ix], "after the steer"
    end

    def test_commands_typed_while_a_turn_runs_still_queue
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      steered = []
      agent.define_singleton_method(:steer) do |text|
        steered << text
        true
      end
      repl.instance_variable_set(:@busy, true)
      prompt = repl.instance_variable_get(:@prompt)
      mailbox = repl.instance_variable_get(:@mailbox)

      prompt.value = "/help"
      prompt.handle_key(::TUI::Key.new(:enter))

      assert_empty steered, "a command is not something the model can act on"
      assert_equal "/help", mailbox.pop
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

    def test_slash_opens_the_command_menu
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      assert_empty input.menu_items

      input.handle_key(::TUI::Key.printable("/"))

      assert input.menu_open?, "a bare slash lists the commands"
      assert_equal TUI::COMPLETABLE, input.menu_items
      assert_equal 0, input.menu_index
      assert_equal "/help", input.menu_items[input.menu_index], "the help command leads"
    end

    def test_menu_filters_as_the_prefix_grows
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      "/m".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      assert_equal %w[/models /model /memory], input.menu_items
      assert_equal 0, input.menu_index

      input.handle_key(::TUI::Key.printable("o"))
      assert_equal %w[/models /model], input.menu_items
      assert_equal 0, input.menu_index, "filtering starts the highlight over"
    end

    def test_escape_closes_the_menu_without_submitting_or_cancelling
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      submits = []
      input.on(:submit) { |v| submits << v }
      input.handle_key(::TUI::Key.printable("/"))

      assert input.handle_key(::TUI::Key.new(:escape)), "the prompt swallows the key while the menu is up"
      refute input.menu_open?
      assert_equal "/", input.value
      assert_empty submits
    end

    def test_arrow_keys_move_the_menu_highlight
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      input.handle_key(::TUI::Key.printable("/"))

      input.handle_key(::TUI::Key.new(:down))
      assert_equal 1, input.menu_index
      input.handle_key(::TUI::Key.new(:down))
      assert_equal 2, input.menu_index
      input.handle_key(::TUI::Key.new(:up))
      assert_equal 1, input.menu_index

      input.handle_key(::TUI::Key.new(:up))
      input.handle_key(::TUI::Key.new(:up))
      assert_equal TUI::COMPLETABLE.length - 1, input.menu_index, "up wraps to the last row"
    end

    def test_enter_takes_the_highlighted_command_then_runs_it
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      submits = []
      input.on(:submit) { |v| submits << v }
      "/se".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      assert_equal %w[/session], input.menu_items

      input.handle_key(::TUI::Key.new(:enter))
      assert_equal "/session", input.value, "enter selects the command into the prompt"
      refute input.menu_open?, "the list closes once the command is in the box"
      assert_empty submits, "selecting is not sending"

      input.handle_key(::TUI::Key.new(:enter))
      assert_equal [ "/session" ], submits
    end

    def test_enter_runs_a_command_typed_in_full
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      submits = []
      input.on(:submit) { |v| submits << v }
      "/help".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      assert input.menu_open?, "the exact command is still highlighted"

      input.handle_key(::TUI::Key.new(:enter))

      assert_equal [ "/help" ], submits, "the highlight must not swallow a complete command"
    end

    def test_menu_closes_once_an_argument_is_typed
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      "/session".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      assert input.menu_open?

      input.handle_key(::TUI::Key.printable(" "))
      refute input.menu_open?, "a space marks the start of the argument"

      input.handle_key(::TUI::Key.new(:enter))
      assert_equal "/session ", input.value
    end

    def test_palette_renders_above_the_prompt
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)

      "/m".each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }
      prompt.handle_key(::TUI::Key.new(:down))
      view = plain(app.render_lines)

      menu_ix = view.index { |l| l.include?("\u276f /model") }
      prompt_ix = view.index { |l| l.include?("\u2502 /m") }
      refute_nil menu_ix, "the highlighted command is drawn: #{view.map(&:strip).inspect}"
      refute_nil prompt_ix
      assert_operator menu_ix, :<, prompt_ix, "the palette sits above the input box"
      assert view[menu_ix].include?("Show current active model"),
             "the description stays on the row: #{view[menu_ix].inspect}"
    end

    def test_menu_only_opens_when_the_slash_starts_the_prompt
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      "hello /".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }

      refute input.menu_open?, "a slash inside a message is just text"
    end

    def test_command_menu_scrolls_the_highlight_into_view
      items = TUI::COMPLETABLE
      menu = TUI::CommandMenu.new(TUI::COMMANDS)
      menu.set_items(items, items.length - 1)
      menu.layout(::TUI::Rect.new(0, 0, 60, 3))

      canvas = ::TUI::Canvas.new(60, 3)
      menu.render(canvas)
      rows = plain(canvas.lines)

      assert_equal 3, rows.length
      assert rows.any? { |l| l.include?("\u276f #{items.last}") },
             "the last row stays visible on a short list: #{rows.inspect}"
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

    def test_skill_load_gets_its_own_transcript_line
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      path = File.expand_path("~/.rubot/workspace/skills/kanyaah-brand/SKILL.md")
      ev << [ :tool_call, "file_ops", { "operation" => "read", "path" => path } ]
      ev << [ :tool_done, "file_ops" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      view = plain(app.render_lines)
      refute view.any? { |l| l.include?("file_ops") }, "the skill load is not a plain file row"
      skill_lines = view.select { |l| l.include?("kanyaah-brand") }
      assert_equal 1, skill_lines.size, "one line for the skill, got: #{skill_lines.inspect}"
      line = skill_lines.first
      assert_includes line, "\u2713 skill kanyaah-brand", "read skill reads as a completed skill row: #{line.inspect}"
      refute_includes line, "SKILL.md"
      refute_includes line, "\u2726"
    end

    def test_skill_load_in_flight_shows_the_skill_marker
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      path = File.expand_path("~/.rubot/workspace/skills/writing/SKILL.md")
      ev << [ :tool_call, "file_ops", { "operation" => "read", "path" => path } ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      line = plain(app.render_lines).find { |l| l.include?("writing") }
      assert line, "skill row renders while reading"
      assert_includes line, "\u2726 skill writing"
    end

    def test_shell_cat_of_a_skill_file_also_counts
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :tool_call, "shell_exec", { "command" => "cat ~/.rubot/workspace/skills/writing/SKILL.md | head -40" } ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      line = plain(app.render_lines).find { |l| l.include?("writing") }
      assert line, "cat of SKILL.md renders as a skill row"
      assert_includes line, "\u2726 skill writing"
    end

    def test_writing_a_skill_file_stays_a_tool_row
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      path = File.expand_path("~/.rubot/workspace/skills/new-skill/SKILL.md")
      ev << [ :tool_call, "file_ops", { "operation" => "write", "path" => path } ]
      ev << [ :tool_done, "file_ops" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      view = plain(app.render_lines)
      assert view.any? { |l| l.include?("file_ops") }, "writes keep the tool row: #{view.inspect}"
      refute view.any? { |l| l.include?("skill new-skill") }
    end

    def test_regular_file_read_stays_a_tool_row
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :tool_call, "file_ops", { "operation" => "read", "path" => "/tmp/notes.md" } ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      line = plain(app.render_lines).find { |l| l.include?("notes.md") }
      assert line, "regular read renders"
      assert_includes line, "file_ops read /tmp/notes.md"
      refute_includes line, "\u2726"
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

    def test_shift_enter_sequences_from_kitty_xterm_and_tmux
      assert_equal :shift_enter, ::TUI::Term::SEQUENCES["\e[13;2u"], "kitty keyboard protocol"
      assert_equal :shift_enter, ::TUI::Term::SEQUENCES["\e[27;2;13~"], "xterm modifyOtherKeys / tmux"
      assert_equal :enter, ::TUI::Term::SEQUENCES.fetch("\r", :enter)
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

    # --- ctrl+g: edit the prompt in $EDITOR ---------------------------

    def test_ctrl_g_hands_the_prompt_to_the_editor_and_takes_it_back
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      app = repl.instance_variable_get(:@app)
      "hello".each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }

      drafts = []
      repl.define_singleton_method(:run_editor) do |path|
        drafts << path
        # What an editor does: starts from the prompt, writes it back.
        File.write(path, File.read(path) + "\nsecond line\n")
      end

      handler = app.instance_variable_get(:@keys)[:ctrl_g]
      refute_nil handler, "ctrl+g must have an app binding"
      assert_equal false, prompt.handle_key(::TUI::Key.new(:ctrl_g)),
                   "the prompt must not swallow ctrl+g"
      handler.call(::TUI::Key.new(:ctrl_g))

      assert_equal "hello\nsecond line", prompt.value, "the editor output replaces the buffer"
      assert_equal 1, drafts.length
      refute File.exist?(drafts.first), "the draft file must not outlive the edit"
    end

    def test_ctrl_g_keeps_the_prompt_when_the_editor_writes_nothing
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      "typed".each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }
      repl.define_singleton_method(:run_editor) { |_path| nil }

      repl.send(:edit_prompt)

      assert_equal "typed", prompt.value
    end

    def test_ctrl_g_with_a_failing_editor_keeps_the_prompt_and_reports
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      "typed".each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }
      repl.define_singleton_method(:run_editor) { |_path| raise Errno::ENOENT, "editor" }

      repl.send(:edit_prompt)
      repl.send(:pump)

      assert_equal "typed", prompt.value
      view = plain(repl.instance_variable_get(:@app).render_lines)
      assert view.any? { |line| line.include?("editor: Errno::ENOENT") }, "the failure must be reported"
    end

    def test_editor_command_prefers_visual_over_editor_and_falls_back_to_vi
      repl = build_repl
      saved = ENV.to_h.slice("VISUAL", "EDITOR")
      begin
        ENV.delete("VISUAL")
        ENV.delete("EDITOR")
        assert_equal "vi", repl.send(:editor_command)

        ENV["EDITOR"] = "nano --wait"
        assert_equal "nano --wait", repl.send(:editor_command)

        ENV["VISUAL"] = "nvim"
        assert_equal "nvim", repl.send(:editor_command)
      ensure
        saved.each { |key, value| ENV[key] = value }
        ([ "VISUAL", "EDITOR" ] - saved.keys).each { |key| ENV.delete(key) }
      end
    end

    def test_configured_editor_wins_over_the_environment
      agent = stub_agent
      def agent.config
        Struct.new(:external_editor).new("omarchy-launch-editor --inline")
      end
      repl = TUI.new(agent)
      repl.send(:build_ui)
      repl.send(:push_status_info)

      saved = ENV.to_h.slice("VISUAL", "EDITOR")
      begin
        ENV["VISUAL"] = "nvim"
        ENV["EDITOR"] = "nano"
        assert_equal "omarchy-launch-editor --inline", repl.send(:editor_command)
      ensure
        saved.each { |key, value| ENV[key] = value }
        ([ "VISUAL", "EDITOR" ] - saved.keys).each { |key| ENV.delete(key) }
      end
    end

    def test_help_lists_the_editor_binding
      repl = build_repl
      repl.send(:handle_command, "/help")
      repl.send(:pump)

      view = plain(repl.instance_variable_get(:@app).render_lines)
      line = view.find { |l| l.include?("ctrl+g") }
      refute_nil line, "the ctrl+g key must be documented in /help"
      assert_includes line, "EDITOR"
    end

    def test_ctrl_g_reads_as_a_control_byte_and_as_a_protocol_sequence
      # With the keyboard protocol on, ctrl+g arrives as CSI 103;5u.
      assert_equal :ctrl_g, ::TUI::Term::SEQUENCES["\e[103;5u"]

      # Without it, it is a bare 0x07 (BEL) that must not be typed into the
      # prompt as a character.
      require "pty"
      reader, writer = PTY.open
      previous = $stdin
      $stdin = reader
      begin
        writer.write("\a")
        assert_equal :ctrl_g, ::TUI::Term.read_key(0.5)&.name
        writer.write("\x02")
        assert_equal :ctrl_b, ::TUI::Term.read_key(0.5)&.name
      ensure
        $stdin = previous
        reader&.close
        writer&.close
      end
    end

    def test_hand_over_leaves_the_alternate_screen_and_restores_it
      out = StringIO.new
      handed_over = false
      Rubot::TUI::Compat.hand_over(out) { handed_over = true }
      seq = out.string

      assert handed_over, "the child process must run between the two halves"

      pop = seq.index("\e[<u")
      alt_off = seq.index("\e[?1049l")
      alt_on = seq.index("\e[?1049h")
      push = seq.index("\e[>1u")

      assert pop && alt_off && alt_on && push, "all four switches must be written: #{seq.inspect}"
      assert_operator pop, :<, alt_off, "the key protocol is popped before the screen is handed over"
      assert_operator alt_off, :<, alt_on, "the child gets the main screen"
      assert_operator alt_on, :<, push, "the key protocol is pushed back on the alternate screen"
    end

    def test_keyboard_protocol_is_pushed_after_the_alternate_screen_switch
      out = StringIO.new
      ::TUI::Term.session(out) { nil }
      seq = out.string

      alt_on = seq.index("\e[?1049h")
      push = seq.index("\e[>1u")
      pop = seq.index("\e[<u")
      alt_off = seq.index("\e[?1049l")

      refute_nil alt_on, "session must enter the alternate screen: #{seq.inspect}"
      refute_nil push, "session must push the kitty keyboard protocol: #{seq.inspect}"
      assert_operator alt_on, :<, push,
                      "terminals keep a per-screen flag stack, so the push has to come after the switch"
      assert_operator pop, :<, alt_off, "the flags must be popped before leaving the alternate screen"
    end

    def test_prompt_grows_when_a_line_wraps
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      assert_equal 1, input.measure(20, 24).last

      ("a" * 45).each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      assert_equal 3, input.measure(20, 24).last, "45 cells at 20 wide should need three rows"

      input.handle_key(::TUI::Key.new(:shift_enter))
      input.handle_key(::TUI::Key.new(:shift_enter))
      assert_equal 5, input.measure(20, 24).last, "wrapped rows and hard newlines add up"
    end

    def test_prompt_wraps_a_long_line_across_rows
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      ("a" * 12).each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      input.layout(::TUI::Rect.new(0, 0, 10, 3))

      canvas = ::TUI::Canvas.new(10, 3)
      input.render(canvas)
      rows = plain(canvas.lines)

      assert_equal "aaaaaaaaaa", rows[0], "first row is a full slice: #{rows.inspect}"
      assert_equal "aa        ", rows[1], "the rest wraps to the next row: #{rows.inspect}"
    end

    def test_prompt_wraps_at_word_boundaries
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      "hello world".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      input.layout(::TUI::Rect.new(0, 0, 8, 3))

      canvas = ::TUI::Canvas.new(8, 3)
      input.render(canvas)
      rows = plain(canvas.lines)

      assert_equal "hello", rows[0].rstrip, "the row ends at the space: #{rows.inspect}"
      assert_equal "world", rows[1].rstrip, "the word moves whole to the next row: #{rows.inspect}"
    end

    def test_prompt_breaks_a_word_that_cannot_fit
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      "abcdefghij".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      input.layout(::TUI::Rect.new(0, 0, 4, 4))

      canvas = ::TUI::Canvas.new(4, 4)
      input.render(canvas)
      rows = plain(canvas.lines)

      assert_equal "abcd", rows[0]
      assert_equal "efgh", rows[1]
      assert_equal "ij", rows[2].rstrip
    end

    def test_prompt_text_keeps_a_column_off_the_right_border
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      ("word " * 60).each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }
      view = plain(repl.instance_variable_get(:@app).render_lines)

      content = view.select { |line| line.end_with?("\u2502") && line.include?("word") }
      refute_empty content, "the wrapped prompt should be on screen"
      content.each do |line|
        assert_equal " ", line[-2], "text must not touch the right border: #{line.inspect}"
      end
    end

    def test_prompt_scrolls_to_the_cursor_row_when_wrapped
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      ("b" * 35).each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      input.layout(::TUI::Rect.new(0, 0, 10, 2))

      canvas = ::TUI::Canvas.new(10, 2)
      input.render(canvas)
      rows = plain(canvas.lines)

      assert_equal "bbbbbbbbbb", rows[0], "the view scrolls to keep the cursor row visible: #{rows.inspect}"
      assert_equal "bbbbb", rows[1].rstrip, "cursor sits on the last wrapped row: #{rows.inspect}"
    end

    def test_multiline_buffer_insert_turns_newlines_into_lines
      buffer = ::TUI::TextBuffer.new("", multiline: true)
      buffer.insert("one\ntwo")

      assert_equal [ "one", "two" ], buffer.lines
      assert_equal 1, buffer.row
      assert_equal 3, buffer.col
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

    # ------------------------------------------------------------------
    # /resume
    # ------------------------------------------------------------------

    class ResumeSessionView
      attr_accessor :id

      def initialize(id)
        @id = id
      end
    end

    class ResumeConfigView
      attr_reader :workspace

      def initialize(workspace)
        @workspace = workspace
      end
    end

    class ResumeAgent
      attr_reader :config, :session, :switched

      def initialize(workspace, session_id: "default")
        @config = ResumeConfigView.new(workspace)
        @session = ResumeSessionView.new(session_id)
        @switched = []
      end

      def startup_info
        { provider: "openai", model: "gpt-test", tools: 3 }
      end

      def active_model_name
        "gpt-test"
      end

      def switch_session(name)
        @switched << name.to_s
        @session = ResumeSessionView.new(name.to_s)
      end

      def clear_session; end

      def usage_report
        nil
      end
    end

    def saved_session(workspace, id, content, updated_at: Time.now.iso8601, messages: nil)
      dir = File.join(workspace, "sessions")
      FileUtils.mkdir_p(dir)
      messages ||= [
        { "role" => "user", "content" => content },
        { "role" => "assistant", "content" => "answer to #{content}" }
      ]
      File.write(File.join(dir, "#{id}.json"), JSON.pretty_generate(
        "id" => id,
        "updated_at" => updated_at,
        "messages" => messages
      ))
    end

    def build_resume_repl(workspace)
      repl = TUI.new(ResumeAgent.new(workspace))
      repl.send(:build_ui)
      repl.send(:paint_banner)
      repl
    end

    def test_resume_writes_the_list_below_the_command_with_the_meta_on_the_right
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        saved_session(workspace, "work", "fix the parser", updated_at: (Time.now - 7200).iso8601)

        repl = build_resume_repl(workspace)
        app = repl.instance_variable_get(:@app)
        prompt = repl.instance_variable_get(:@prompt)
        mailbox = repl.instance_variable_get(:@mailbox)
        app.render_frame # the log knows its width before the first command

        # Submit /resume the way the prompt does: the echo lands first, then
        # the worker answers with the list.
        prompt.value = "/resume"
        prompt.handle_key(::TUI::Key.new(:enter))
        repl.send(:pump)
        repl.send(:handle_command, mailbox.pop)
        repl.send(:pump)

        session_list = repl.instance_variable_get(:@session_list)
        assert_equal %w[work], session_list.entries.map { |entry| entry[:id] }
        assert_same session_list, prompt.list, "the list owns the keyboard"
        refute repl.instance_variable_get(:@overlay).shown?, "nothing floats"

        view = plain(app.render_lines)
        command_ix = view.index { |line| line.include?("❯ /resume") }
        row_ix = view.index { |line| line.include?("fix the parser") }
        assert command_ix, "the command is echoed"
        assert row_ix, "the last prompt labels the row"
        assert_operator row_ix, :>, command_ix, "the list sits under the command"
        assert_equal "", view[row_ix - 1].strip, "one blank row between the command and the list"
        assert_equal command_ix + 2, row_ix

        line = view[row_ix]
        assert_includes line, "2 msgs · 2h ago"
        assert_operator line.index("2 msgs"), :>, line.length / 2, "meta hugs the right edge"
        assert_equal view[command_ix][/\A */].length + 2, line[/\A */].length,
                     "the list has two cells of left padding"
      end
    end

    def test_resume_list_enter_resumes_the_highlighted_session
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        saved_session(workspace, "work", "fix the parser")

        repl = build_resume_repl(workspace)
        agent = repl.instance_variable_get(:@agent)
        prompt = repl.instance_variable_get(:@prompt)
        mailbox = repl.instance_variable_get(:@mailbox)
        repl.instance_variable_get(:@app).render_frame

        repl.send(:handle_command, "/resume")
        repl.send(:pump)
        prompt.handle_key(::TUI::Key.new(:enter))

        assert_nil prompt.list, "picking hands the keyboard back to the prompt"
        command = mailbox.pop
        assert_equal "/resume work", command

        # The worker runs the queued command: the switch stays off the App thread.
        repl.send(:handle_command, command)
        repl.send(:pump)
        assert_equal [ "work" ], agent.switched

        view = plain(repl.instance_variable_get(:@app).render_lines).join("\n")
        assert_includes view, "answer to fix the parser"
        refute_includes view, "Resumed work", "no confirmation line after the replay"
        refute_includes view, "Transcript restored"
      end
    end

    def test_resume_list_escape_removes_the_rows_without_switching
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        saved_session(workspace, "work", "fix the parser")

        repl = build_resume_repl(workspace)
        agent = repl.instance_variable_get(:@agent)
        prompt = repl.instance_variable_get(:@prompt)
        app = repl.instance_variable_get(:@app)
        app.render_frame

        repl.send(:handle_command, "/resume")
        repl.send(:pump)
        assert_includes plain(app.render_lines).join("\n"), "fix the parser"

        prompt.handle_key(::TUI::Key.new(:escape))

        assert_nil prompt.list, "escape hands the keyboard back to the prompt"
        assert_empty agent.switched
        view = plain(app.render_lines).join("\n")
        refute_includes view, "fix the parser", "the list is taken back out"
        refute_includes view, "↑/↓ choose"
      end
    end

    def test_resume_without_a_tty_prints_the_list
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        saved_session(workspace, "work", "fix the parser")

        repl = build_resume_repl(workspace)
        repl.instance_variable_set(:@tui, false)
        out, _err = capture_io { repl.send(:handle_command, "/resume") }

        assert_includes out, "Saved sessions:"
        assert_includes out, "work"
        assert_includes out, "2 msgs"
        assert_includes out, "fix the parser"
        assert_includes out, "/resume <number>"
      end
    end

    def test_resume_accepts_a_session_id_and_rejects_unknown_ones
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        saved_session(workspace, "work", "fix the parser")

        repl = build_resume_repl(workspace)
        agent = repl.instance_variable_get(:@agent)

        repl.send(:handle_command, "/resume work")
        repl.send(:pump)
        assert_equal [ "work" ], agent.switched

        repl.send(:handle_command, "/resume ../../etc/passwd")
        repl.send(:pump)

        assert_equal [ "work" ], agent.switched, "a path never resolves to a session"
        view = plain(repl.instance_variable_get(:@app).render_lines).join("\n")
        assert_includes view, "not found"
      end
    end

    def test_resume_restores_prompts_tool_calls_and_answers
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        saved_session(workspace, "work", "fix the parser", messages: [
          { "role" => "user", "content" => "fix the parser" },
          { "role" => "assistant", "content" => "Let me look at the file.",
            "tool_calls" => [ {
              "id" => "call-1",
              "type" => "function",
              "function" => { "name" => "file_ops",
                              "arguments" => JSON.generate("operation" => "read", "path" => "/src/parser.rb") }
            } ] },
          { "role" => "tool", "content" => "1: def parse", "tool_call_id" => "call-1" },
          { "role" => "assistant", "content" => "The blank line was skipped." }
        ])

        repl = build_resume_repl(workspace)
        repl.send(:handle_command, "/resume work")
        repl.send(:pump)

        view = plain(repl.instance_variable_get(:@app).render_lines).join("\n")

        assert_includes view, "❯ fix the parser", "the user prompt is echoed"
        assert_includes view, "Let me look at the file.", "the narration is restored"
        assert_includes view, "✓ file_ops read /src/parser.rb", "the finished tool row is restored"
        assert_includes view, "The blank line was skipped.", "the answer is restored"
        assert_operator view.index("❯ fix the parser"), :<, view.index("✓ file_ops")
        assert_operator view.index("✓ file_ops"), :<, view.index("The blank line was skipped.")
      end
    end

    def test_resume_prints_the_full_transcript_without_a_tty
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        saved_session(workspace, "work", "fix the parser", messages: [
          { "role" => "user", "content" => "fix the parser" },
          { "role" => "assistant", "content" => "Let me look.",
            "tool_calls" => [ {
              "id" => "call-1",
              "function" => { "name" => "shell_exec", "arguments" => JSON.generate("command" => "grep -n ruby") }
            } ] },
          { "role" => "tool", "content" => "42: ruby", "tool_call_id" => "call-1" },
          { "role" => "assistant", "content" => "Found it." }
        ])

        repl = build_resume_repl(workspace)
        repl.instance_variable_set(:@tui, false)
        out, _err = capture_io { repl.send(:handle_command, "/resume work") }

        assert_includes out, "❯ fix the parser"
        assert_includes out, "✓ shell_exec grep -n ruby"
        assert_includes out, "Found it."
      end
    end

    def test_transcript_hides_continuation_prompts_and_merges_fragments
      messages = [
        { "role" => "user", "content" => "write a long thing" },
        { "role" => "assistant", "content" => "Part one, " },
        { "role" => "user", "content" => Rubot::Agent::CONTINUE_PROMPT },
        { "role" => "assistant", "content" => "part two." }
      ]

      texts = Rubot::TUI::Transcript.entries(messages).map do |entry|
        entry[:segments].map { |segment| segment[0].to_s }.join
      end

      assert_equal [ "❯ write a long thing", "", "Part one, part two.", "" ], texts
      refute texts.any? { |text| text.include?("output limit") }
    end

    def test_transcript_shows_a_skill_load_as_its_own_row
      messages = [
        { "role" => "user", "content" => "use the skill" },
        { "role" => "assistant", "content" => "",
          "tool_calls" => [ {
            "id" => "call-1",
            "function" => { "name" => "file_ops",
                            "arguments" => JSON.generate("operation" => "read", "path" => "/w/skills/omarchy/SKILL.md") }
          } ] },
        { "role" => "tool", "content" => "...", "tool_call_id" => "call-1" }
      ]

      text = Rubot::TUI::Transcript.entries(messages)
        .map { |entry| entry[:segments].map { |segment| segment[0].to_s }.join }
        .join("\n")

      assert_includes text, "✓ skill omarchy"
    end

    def test_resume_says_when_nothing_is_saved
      Dir.mktmpdir do |dir|
        repl = build_resume_repl(File.join(dir, "workspace"))
        repl.send(:handle_command, "/resume")
        repl.send(:pump)

        view = plain(repl.instance_variable_get(:@app).render_lines).join("\n")
        assert_includes view, "No saved sessions yet."
      end
    end

    def test_start_fresh_session_leaves_the_previous_conversation_untouched
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        FileUtils.mkdir_p(File.join(workspace, "sessions"))
        previous = File.join(workspace, "sessions", "default.json")
        File.write(previous, JSON.pretty_generate(
          "id" => "default",
          "updated_at" => Time.now.iso8601,
          "messages" => [ { "role" => "user", "content" => "keep me" } ]
        ))

        repl = build_resume_repl(workspace)
        repl.send(:start_fresh_session)

        assert File.exist?(previous), "the earlier conversation keeps its file and id"
        assert_equal [ "keep me" ], JSON.parse(File.read(previous))["messages"].map { |m| m["content"] }

        fresh_id = repl.instance_variable_get(:@session_id)
        refute_equal "default", fresh_id
        refute File.exist?(File.join(workspace, "sessions", "#{fresh_id}.json")),
               "the new session is only written once it has a message"
      end
    end
  end
end
