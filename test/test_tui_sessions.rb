# frozen_string_literal: true

require "stringio"
require "test_helper"
require "rubot"
require_relative "support/tui_support"

module Rubot
  # Sessions in the TUI: switching, the resume picker, search and the model presets a session runs on.
  class TestTUI < Minitest::Test
    include TuiSupport

    # These tests pin the Indonesian wording the channels were written in
    # before the dictionary existed (see lib/rubot/i18n.rb).
    def setup
      Rubot::I18n.locale = "id"
    end

    def teardown
      Rubot::I18n.locale = Rubot::I18n::DEFAULT_LOCALE
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

      repl.process_message("stop me")
      repl.pump

      entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
      texts = entries.map { |segments| segments.map(&:first).join }

      refute texts.any? { |t| t.include?("Turn took") }, "no turn footer after a stop"
      assert_equal "half an answer", texts[-2]
      assert_equal "", texts[-1], "one separator blank remains, no double blank"

      app = repl.instance_variable_get(:@app)
      line = app.render_lines.find { |l| l.include?("Operation canceled by user") }
      refute_nil line, "the cancellation notice shows above the input"
      assert_includes line, "38;2;230;126;128", "the notice is red"

      ev = repl.instance_variable_get(:@events)
      ev << [ :stream_start ]
      repl.pump
      repl.instance_variable_get(:@app).send(:run_timers)
      refute plain(app.render_lines).any? { |l| l.include?("Operation canceled by user") },
             "a new turn clears the notice"
    end

    def test_tool_summary_truncates_to_a_cell_budget
      long = { "pattern" => "x" * 200 }

      summary = build_repl.tool_summary("search", long)

      assert summary.end_with?("\u2026"), "ellipsis marks the cut: #{summary.inspect}"
      assert_operator ::TUI::Text.width(summary), :<=, 64
    end

    def test_tool_line_fits_inside_the_log_width
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      ev = repl.instance_variable_get(:@events)
      app.render_lines # lay the log out so it knows its width
      ev << [ :tool_call, "search", { "pattern" => "y" * 500 } ]
      repl.pump

      row = plain(app.render_lines).find { |l| l.include?("Mencari") }
      assert row, "tool line must render"
      assert_operator ::TUI::Text.width(row.strip), :<=, repl.instance_variable_get(:@log).content_width,
                      "tool row must not exceed the log width: #{row.inspect}"
      assert row.include?("\u2026"), "a long sentence is cut"
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

    # A steer that spans lines or wraps keeps its later rows under the text of
    # the first one: the "↳ " marker opens the entry, and every row after it
    # hangs by the marker's width, the same way a prompt echo does.
    def test_steer_echo_continuation_rows_hang_under_the_marker
      repl = build_repl
      repl.add_steer_echo("first line of the steer\n" + "second line that runs long enough to soft-wrap at any sane width " * 2)

      log = repl.instance_variable_get(:@log)
      log.layout(::TUI::Rect.new(0, 0, 60, 24))
      rows = log.instance_variable_get(:@lines).map do |line|
        line.map { |(text, _style)| text }.join
      end
      start = rows.index { |row| row.start_with?("\u21b3 ") }
      assert start, "the steer echo renders: #{rows.inspect}"
      rows = rows.drop(start).take_while { |row| !row.empty? }

      assert_equal "\u21b3 first line of the steer", rows[0], "the marker opens the first row"
      assert_operator rows.size, :>, 2, "the second line must soft-wrap: #{rows.inspect}"
      rows.drop(1).each do |row|
        assert_equal "  ", row[0, 2], "every later row hangs by two cells: #{row.inspect}"
      end
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
      repl.pump

      "use /tmp instead".each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }
      prompt.handle_key(::TUI::Key.new(:enter))
      app.send(:run_timers)

      events << [ :chunk, "after the steer" ]
      repl.pump

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

    def test_commands_typed_while_a_turn_runs_take_the_command_lane
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
      lane = repl.instance_variable_get(:@command_mailbox)

      prompt.value = "/help"
      prompt.handle_key(::TUI::Key.new(:enter))

      assert_empty steered, "a command is not something the model can act on"
      assert_equal "/help", lane.pop
      assert mailbox.empty?, "the command must not wait behind the running turn"
    end

    # The point of the lane: the command is answered while the worker is still
    # inside the turn, not after it.
    def test_the_command_lane_answers_while_a_turn_is_still_running
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      lane = repl.instance_variable_get(:@command_mailbox)
      repl.instance_variable_set(:@busy, true)
      repl.spawn_command_lane

      begin
        lane << "/help"
        rows = []
        deadline = Time.now + 5
        while Time.now < deadline
          repl.pump
          app.render_lines
          rows = repl.instance_variable_get(:@log).instance_variable_get(:@lines).map do |line|
            line.map { |(text, _style)| text }.join
          end
          break if rows.any? { |row| row.include?("Perintah yang tersedia") }

          sleep 0.02
        end

        assert rows.any? { |row| row.include?("Perintah yang tersedia") },
               "the lane's output lands mid-turn: #{rows.map(&:strip).first(5).inspect}"
        assert repl.instance_variable_get(:@busy), "the turn is still running"
      ensure
        repl.stop_command_lane
      end
    end

    # A command that changes the session cannot apply mid-turn; it says so
    # instead of leaving the prompt silent until the answer arrives.
    # No command waits for the turn any more, session-changing ones included:
    # /clear is answered by the lane while the answer is still streaming.
    def test_a_session_changing_command_runs_mid_turn
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      lane = repl.instance_variable_get(:@command_mailbox)
      repl.instance_variable_set(:@busy, true)
      cleared = false
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:clear_session) { cleared = true }

      prompt.value = "/clear"
      prompt.handle_key(::TUI::Key.new(:enter))
      assert_equal "/clear", lane.pop, "the lane takes it, not the busy worker"

      repl.handle_command("/clear")
      assert cleared, "the command runs straight away"
      refute plain(app.render_lines).any? { |line| line.include?("runs when this turn ends") },
             "nothing is deferred any more"
    end

    # /context mid-turn renders the report the turn itself published: asking
    # the agent would wait for the turn to end.
    def test_context_mid_turn_uses_the_live_report
      repl = build_repl
      report = { model: "test-model", provider: "openai", context_used: 1234,
                 context_window: 100_000, messages: 2, requests: 1,
                 prompt_tokens: 900, completion_tokens: 34, cached_tokens: 0 }
      repl.instance_variable_set(:@live_report, report)
      repl.instance_variable_set(:@tui, false)

      agent = repl.instance_variable_get(:@agent)
      asked = false
      agent.define_singleton_method(:usage_report) do |**|
        asked = true
        report
      end

      out, _err = capture_io { repl.handle_command("/context") }

      refute asked, "the agent is not asked while it is busy"
      assert_includes out, "test-model"
      assert_includes out, "live —"
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

    def test_enter_runs_the_highlighted_command
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      submits = []
      input.on(:submit) { |v| submits << v }
      "/se".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      assert_equal %w[/session /search], input.menu_items

      input.handle_key(::TUI::Key.new(:enter))
      assert_equal [ "/session" ], submits, "enter executes the highlighted command"
      refute input.menu_open?, "the list closes with the command"
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


    def test_at_lists_the_files_of_the_working_directory
      with_files do |input|
        assert_empty input.menu_items

        input.handle_key(::TUI::Key.printable("@"))

        assert input.menu_open?, "a bare @ lists the files"
        assert_equal :file, input.menu_mode
        assert_equal %w[README.md lib/ lib/app.rb], input.menu_items
        assert_equal "README.md", input.menu_items[input.menu_index], "the shallowest path leads"
      end
    end

    def test_mention_filters_as_the_path_is_typed
      with_files do |input|
        "@app".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }

        assert_equal [ "lib/app.rb" ], input.menu_items
      end
    end

    def test_arrow_keys_move_the_file_highlight
      with_files do |input|
        input.handle_key(::TUI::Key.printable("@"))

        input.handle_key(::TUI::Key.new(:down))
        assert_equal 1, input.menu_index
        input.handle_key(::TUI::Key.new(:down))
        assert_equal 2, input.menu_index
        input.handle_key(::TUI::Key.new(:up))
        assert_equal 1, input.menu_index
      end
    end

    def test_enter_completes_a_mention_instead_of_submitting
      with_files do |input|
        submits = []
        input.on(:submit) { |v| submits << v }
        "@READ".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }

        input.handle_key(::TUI::Key.new(:enter))

        assert_equal "@README.md ", input.value, "enter drops the path into the prompt"
        assert_empty submits, "a mention is text, not a command"
        refute input.menu_open?, "the trailing space ends the mention"
      end
    end

    def test_picking_a_directory_keeps_the_mention_open
      with_files do |input|
        "@li".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
        input.handle_key(::TUI::Key.new(:enter))

        assert_equal "@lib/", input.value
        assert input.menu_open?, "the mention stays open to walk into the directory"
        assert_equal %w[lib/ lib/app.rb], input.menu_items
      end
    end

    def test_tab_completes_a_mention
      with_files do |input|
        "@app".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
        input.handle_key(::TUI::Key.new(:tab))

        assert_equal "@lib/app.rb ", input.value
      end
    end

    def test_escape_closes_the_file_menu
      with_files do |input|
        input.handle_key(::TUI::Key.printable("@"))
        assert input.handle_key(::TUI::Key.new(:escape))

        refute input.menu_open?
        assert_equal "@", input.value
      end
    end

    def test_at_inside_a_word_does_not_open_the_menu
      with_files do |input|
        "mail a@b".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }

        refute input.menu_open?, "an email address is not a mention"
      end
    end

    def test_file_palette_renders_above_the_prompt
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "README.md"), "")
        repl = build_repl
        app = repl.instance_variable_get(:@app)
        prompt = repl.instance_variable_get(:@prompt)
        prompt.instance_variable_set(:@files, TUI::FileIndex.new(dir))
        prompt.instance_variable_set(:@files_stale, true)

        prompt.handle_key(::TUI::Key.printable("@"))
        view = plain(app.render_lines)

        menu_ix = view.index { |l| l.include?("\u276f README.md") }
        prompt_ix = view.index { |l| l.include?("\u2502 @") }
        refute_nil menu_ix, "the file palette is drawn: #{view.map(&:strip).inspect}"
        refute_nil prompt_ix
        assert_operator menu_ix, :<, prompt_ix, "the palette sits above the input box"
      end
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
      tool_lines = view.select { |l| l.include?("Menjalankan") }
      assert_equal 1, tool_lines.size, "single tool line, got: #{tool_lines.inspect}"
      assert tool_lines.first.include?("\u2713") && tool_lines.first.include?("Menjalankan Ruby"),
             "done line keeps the sentence: #{tool_lines.first.inspect}"
      refute tool_lines.first.include?("\u2692")

      entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
      done = entries.find { |e| e.any? { |(t, _)| t.include?("Menjalankan") } }
      assert_includes done, [ "✓ ", :tool_ok ], "completed marker uses the calm green"
      assert_includes done, [ "Menjalankan Ruby", :dim ], "the sentence is the row"
      refute done.any? { |(text, _)| text.include?("shell_exec") },
             "the tool's own name is not the reader's word for it"
    end

    def test_failed_tool_call_flips_the_marker_to_a_cross
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :tool_call, "shell_exec", { "command" => "exit 1" } ]
      ev << [ :tool_done, "shell_exec", nil, "[Exit code: 1]\nboom" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      line = plain(app.render_lines).find { |l| l.include?("Menjalankan") }
      assert line, "the tool row is still there"
      assert_includes line, "\u2717", "a failed call is marked with a cross: #{line.inspect}"
      refute_includes line, "\u2713"

      entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
      done = entries.find { |e| e.any? { |(t, _)| t.include?("Menjalankan") } }
      assert_includes done, [ "✗ ", :error ]
    end

    def test_zero_exit_shell_call_stays_a_check
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :tool_call, "shell_exec", { "command" => "true" } ]
      ev << [ :tool_done, "shell_exec", nil, "[Exit code: 0]\n" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      line = plain(app.render_lines).find { |l| l.include?("Menjalankan") }
      assert_includes line, "\u2713"
      refute_includes line, "\u2717"
    end

    def test_error_tool_result_is_marked_as_a_failure
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :tool_call, "file_read", { "operation" => "read", "path" => "/nope" } ]
      ev << [ :tool_done, "file_read", nil, "ERROR: Errno::ENOENT: no such file" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      line = plain(app.render_lines).find { |l| l.include?("Membaca isi /nope") }
      assert_includes line, "\u2717"
    end

    def test_a_tool_call_past_the_threshold_shows_a_live_clock
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      app = repl.instance_variable_get(:@app)
      ev << [ :tool_call, "shell_exec", { "command" => "ffmpeg -i a.mp4 b.webm" } ]
      repl.pump

      # The call started 4.5 seconds ago and has not come back yet.
      entries = repl.instance_variable_get(:@tool_entries)
      entries["shell_exec"][:started_at] -= 4.5
      repl.refresh_slow_tools

      line = plain(app.render_lines).find { |l| l.include?("Menjalankan") }
      assert_includes line, "\u2692", "the call is still in flight: #{line.inspect}"
      assert_includes line, "\u00b7 4s", "a slow call shows how long it has been running: #{line.inspect}"
      assert line.rstrip.end_with?("\u00b7 4s"),
             "the clock is pinned to the end of the row: #{line.inspect}"
    end

    def test_a_tool_call_under_the_threshold_shows_no_clock
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      app = repl.instance_variable_get(:@app)
      ev << [ :tool_call, "shell_exec", { "command" => "true" } ]
      repl.pump
      ev << [ :tool_done, "shell_exec", nil, "[Exit code: 0]\n" ]
      repl.pump

      line = plain(app.render_lines).find { |l| l.include?("Menjalankan") }
      assert_includes line, "\u2713"
      refute_includes line, "\u00b7", "a quick call keeps its quiet one-line row: #{line.inspect}"
    end

    def test_a_slow_tool_call_keeps_its_duration_once_done
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      app = repl.instance_variable_get(:@app)
      ev << [ :tool_call, "shell_exec", { "command" => "ffmpeg -i a.mp4 b.webm -c:v libx264" } ]
      repl.pump
      repl.instance_variable_get(:@tool_entries)["shell_exec"][:started_at] -= 12.2

      ev << [ :tool_done, "shell_exec", nil, "[Exit code: 0]\n" ]
      repl.pump

      line = plain(app.render_lines).find { |l| l.include?("Menjalankan") }
      assert_includes line, "\u2713", "the row still ends a check: #{line.inspect}"
      assert_includes line, "\u00b7 12s", "the finished row keeps how long it took: #{line.inspect}"
    end

    # The duration is pinned in the text columns, one cell short of the
    # scrollbar column, so the bar can never be drawn over it.
    def test_a_tool_clock_never_reaches_the_scrollbar_column
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      app = repl.instance_variable_get(:@app)
      ev << [ :tool_call, "shell_exec", { "command" => "ffmpeg -i a.mp4 b.webm" } ]
      repl.pump
      repl.instance_variable_get(:@tool_entries)["shell_exec"][:started_at] -= 4.5
      repl.refresh_slow_tools

      log = repl.instance_variable_get(:@log)
      row = plain(app.render_lines).find { |l| l.include?("Menjalankan") }
      assert row, "the tool row is on screen"

      # The clock ends on the log's last text column; the bar's own column
      # follows it and stays untouched.
      assert_equal log.instance_variable_get(:@rect).right - 2, row.rstrip.length - 1,
                   "the clock ends on the last text column: #{row.inspect}"
    end

    # With enough rows to draw a scrollbar, the bar takes the log's last
    # column and the clock stops just short of it.
    def test_the_scrollbar_does_not_cover_the_tool_clock
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      app = repl.instance_variable_get(:@app)
      40.times { |i| ev << [ :entry, [ [ "filler row #{i}", :text ] ], true, 0 ] }
      ev << [ :tool_call, "shell_exec", { "command" => "ffmpeg -i a.mp4 b.webm" } ]
      repl.pump
      repl.instance_variable_get(:@tool_entries)["shell_exec"][:started_at] -= 4.5
      repl.refresh_slow_tools

      rows = plain(app.render_lines)
      log_row = rows.index { |l| l.include?("Menjalankan") }
      assert log_row, "the tool row is on screen"
      assert_includes rows[log_row], "\u00b7 4s", "the clock is still drawn: #{rows[log_row].inspect}"
      # The clock ends one cell short of the bar's column, which leaves a
      # blank cell between them; the bar keeps the last column.
      assert_equal "\u2590", rows[log_row][-1],
                   "the scrollbar owns the last column: #{rows[log_row].inspect}"
      assert_equal " ", rows[log_row][-2], "one blank cell clears the bar: #{rows[log_row].inspect}"
      refute_includes rows[log_row][0..-2], "\u2590", "only one cell of bar"
    end

    # A summary too long for one row is cut to an ellipsis: a tool call is one
    # line in the transcript, and the clock keeps to the end of that line.
    def test_a_long_summary_is_cut_short_instead_of_pushing_the_clock_away
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      app = repl.instance_variable_get(:@app)
      ev << [ :tool_call, "search", { "pattern" => "y" * 400 } ]
      repl.pump
      repl.instance_variable_get(:@tool_entries)["search"][:started_at] -= 7.0
      repl.refresh_slow_tools

      rows = plain(app.render_lines)
      long_rows = rows.select { |l| l.include?("yyy") }
      assert_equal 1, long_rows.length, "a tool call stays on one row: #{long_rows.inspect}"
      row = long_rows.first
      assert_includes row, "\u2026", "the overflow is an ellipsis: #{row.inspect}"
      assert row.rstrip.end_with?("\u00b7 7s"), "the clock keeps the end of the row: #{row.inspect}"
    end

    def test_tool_elapsed_label_reads_like_the_turn_footer
      assert_equal "4s", TUI::Transcript.elapsed_label(4.9)
      assert_equal "1m 5s", TUI::Transcript.elapsed_label(65)
      assert_equal "1h 2m", TUI::Transcript.elapsed_label(3720)
    end

    # The tail is placed at render time, so a narrower view keeps it at the
    # new right edge instead of leaving it where the wider one ended.
    def test_the_tool_clock_follows_a_resize
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 60, 6))
      view.add_entry([ [ "\u2692 Membaca isi a.rb", :text ] ],
                     indent: 2, tail: TUI::Transcript.elapsed_tail(7))
      view.render(::TUI::Canvas.new(60, 6))

      view.layout(::TUI::Rect.new(0, 0, 30, 6))
      canvas = ::TUI::Canvas.new(30, 6)
      view.render(canvas)

      row = plain(canvas.lines).find { |l| l.include?("Membaca") }
      assert_includes row, "\u00b7 7s"
      assert_equal view.instance_variable_get(:@rect).right - 2, row.rstrip.length - 1,
                   "the clock moved with the right edge: #{row.inspect}"
    end

    def test_replay_marks_a_failed_tool_call
      messages = [
        { "role" => "assistant", "content" => "", "tool_calls" => [
          { "id" => "call_1", "function" => { "name" => "shell_exec", "arguments" => '{"command":"exit 3"}' } }
        ] },
        { "role" => "tool", "tool_call_id" => "call_1", "content" => "[Exit code: 3]\nnope" }
      ]
      texts = TUI::Transcript.entries(messages, width: 73).map { |entry| entry[:segments].map(&:first).join }
      row = texts.find { |t| t.include?("Menjalankan") }
      assert_includes row, "\u2717", "restored session keeps the failure marker: #{row.inspect}"
    end

    def test_skill_load_gets_its_own_transcript_line
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      path = File.expand_path("~/.rubot/workspace/skills/kanyaah-brand/SKILL.md")
      ev << [ :tool_call, "file_read", { "operation" => "read", "path" => path } ]
      ev << [ :tool_done, "file_read" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      view = plain(app.render_lines)
      refute view.any? { |l| l.include?("Membaca isi") }, "the skill load is not a plain file row"
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
      ev << [ :tool_call, "file_read", { "operation" => "read", "path" => path } ]
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
      ev << [ :tool_call, "file_write", { "operation" => "write", "path" => path } ]
      ev << [ :tool_done, "file_read" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      view = plain(app.render_lines)
      assert view.any? { |l| l.include?("Menulis berkas") }, "writes keep the tool row: #{view.inspect}"
      refute view.any? { |l| l.include?("skill new-skill") }
    end

    def test_regular_file_read_stays_a_tool_row
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :tool_call, "file_read", { "operation" => "read", "path" => "/tmp/notes.md" } ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      line = plain(app.render_lines).find { |l| l.include?("notes.md") }
      assert line, "regular read renders"
      assert_includes line, "Membaca isi /tmp/notes.md"
      refute_includes line, "\u2726"
    end

    def test_back_to_back_tool_calls_have_no_spacer
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :stream_start ]
      ev << [ :tool_call, "file_read", { "operation" => "read", "path" => "a.rb" } ]
      ev << [ :tool_done, "file_read" ]
      ev << [ :tool_call, "file_read", { "operation" => "read", "path" => "b.rb" } ]
      ev << [ :tool_done, "file_read" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
      texts = entries.map { |e| e.map(&:first).join }
      a_ix  = texts.index { |t| t.include?("Membaca isi a.rb") }
      b_ix  = texts.index { |t| t.include?("Membaca isi b.rb") }

      between = texts[(a_ix + 1)...b_ix] || []
      assert_empty between,
                    "tool rows adjacent"
    end
  end
end
