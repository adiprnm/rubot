# frozen_string_literal: true

require "stringio"
require "test_helper"
require "rubot"
require_relative "support/tui_support"

module Rubot
  # The prompt handed to $EDITOR and taken back, and the commands that answer next to a turn.
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

      repl.edit_prompt

      assert_equal "typed", prompt.value
    end

    def test_ctrl_g_with_a_failing_editor_keeps_the_prompt_and_reports
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      "typed".each_char { |c| prompt.handle_key(::TUI::Key.printable(c)) }
      repl.define_singleton_method(:run_editor) { |_path| raise Errno::ENOENT, "editor" }

      repl.edit_prompt
      repl.pump

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
        assert_equal "vi", repl.editor_command

        ENV["EDITOR"] = "nano --wait"
        assert_equal "nano --wait", repl.editor_command

        ENV["VISUAL"] = "nvim"
        assert_equal "nvim", repl.editor_command
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
      repl.build_ui
      repl.push_status_info

      saved = ENV.to_h.slice("VISUAL", "EDITOR")
      begin
        ENV["VISUAL"] = "nvim"
        ENV["EDITOR"] = "nano"
        assert_equal "omarchy-launch-editor --inline", repl.editor_command
      ensure
        saved.each { |key, value| ENV[key] = value }
        ([ "VISUAL", "EDITOR" ] - saved.keys).each { |key| ENV.delete(key) }
      end
    end

    # /auto flips the mode through the agent handle (which persists it to
    # config.yml) and says so; the status row carries the word, so an agent
    # that stopped asking is visible without scrolling back.
    def test_auto_command_turns_auto_mode_on_and_flags_the_status_row
      agent = auto_agent
      repl = TUI.new(agent)
      repl.build_ui
      repl.paint_banner

      repl.handle_command("/auto on")
      repl.pump

      assert agent.auto_approve?, "the agent must be told"
      view = plain(repl.instance_variable_get(:@app).render_lines)
      assert_includes view.join("\n"), "Mode auto aktif"
      assert_includes view.join("\n"), "AUTO", "the status row must say AUTO"
    end

    # The badge carries the theme's warning colour (everforest amber
    # #dbbc7f) instead of the row's dim grey, so a mode that stops asking is
    # visible at a glance rather than blending into the model text.
    def test_auto_badge_uses_the_theme_warning_colour
      agent = auto_agent
      agent.set_auto_approve(true)
      repl = TUI.new(agent)
      repl.build_ui
      repl.paint_banner

      status = repl.instance_variable_get(:@app).render_lines.last
      warn_sgr = ::TUI::Style.resolve(:warning)

      assert_includes status, "#{warn_sgr}AUTO "
      assert_includes status, ::TUI::Style.resolve(:dim), "the model text stays dim"
    end

    # No argument flips the current mode, so one word is enough to turn it off
    # again after a session started with it on.
    def test_auto_command_without_argument_flips_the_mode
      agent = auto_agent
      agent.set_auto_approve(true)
      repl = TUI.new(agent)
      repl.build_ui
      repl.paint_banner

      repl.handle_command("/auto")
      repl.pump

      refute agent.auto_approve?
      view = plain(repl.instance_variable_get(:@app).render_lines)
      assert_includes view.join("\n"), "Mode auto mati"
      refute_includes view.join("\n"), "AUTO ·"
    end

    def test_help_lists_the_editor_binding
      repl = build_repl
      repl.handle_command("/help")
      repl.pump

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

    def test_prompt_cursor_moves_without_reversing_the_rest_of_the_line
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      "abc".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      2.times { input.handle_key(::TUI::Key.new(:left)) }
      input.layout(::TUI::Rect.new(0, 0, 10, 1))

      canvas = ::TUI::Canvas.new(10, 1)
      input.render(canvas)

      assert_equal [ 1 ], styled_columns(canvas, 0, :cursor),
                   "the cursor must sit where the arrow keys moved it"
      row = canvas.row(0)
      assert_includes row, ::TUI::Style::RESET + ::TUI::Style.resolve(:text),
                      "reverse video must not bleed into the text after the cursor: #{row.inspect}"
    end

    def test_prompt_ctrl_arrows_move_between_words
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      "one two three".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }

      input.handle_key(::TUI::Key.new(:ctrl_left))
      assert_equal [ 0, 8 ], [ input.buffer.row, input.buffer.col ], "start of the last word"

      input.handle_key(::TUI::Key.new(:ctrl_left))
      assert_equal [ 0, 4 ], [ input.buffer.row, input.buffer.col ], "start of the previous word"

      input.handle_key(::TUI::Key.new(:ctrl_right))
      assert_equal [ 0, 7 ], [ input.buffer.row, input.buffer.col ], "end of the next word"

      input.handle_key(::TUI::Key.new(:ctrl_right))
      assert_equal [ 0, 13 ], [ input.buffer.row, input.buffer.col ], "end of the line"
    end

    def test_word_navigation_crosses_hard_newlines
      buffer = ::TUI::TextBuffer.new("one\ntwo", multiline: true)

      buffer.word_left
      assert_equal [ 1, 0 ], [ buffer.row, buffer.col ], "start of the word on this line"

      buffer.word_left
      assert_equal [ 0, 0 ], [ buffer.row, buffer.col ], "ctrl+left crosses onto the previous line"
    end

    def test_canvas_resets_style_between_runs
      canvas = ::TUI::Canvas.new(4, 1)
      canvas.put(0, 0, "a", :text)
      canvas.put(1, 0, "b", :cursor)
      canvas.put(2, 0, "c", :text)

      row = canvas.row(0)
      assert_includes row, ::TUI::Style::RESET + ::TUI::Style.resolve(:text),
                      "a style run must not inherit attributes from the previous run: #{row.inspect}"
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

    # A provider sends many fragments per tick, and each one used to re-parse
    # the whole answer and re-wrap the block. They are joined first: same text
    # on screen, one parse.
    def test_chunks_in_one_tick_are_joined_into_one_block
      repl = build_repl
      log = repl.instance_variable_get(:@log)
      events = repl.instance_variable_get(:@events)
      events << [ :stream_start ]
      events << [ :chunk, "Halo" ]
      events << [ :chunk, " dunia" ]
      repl.pump

      entries = log.instance_variable_get(:@entries)
      drawn = entries.count { |segments| segments.flatten.include?("Halo dunia") }
      assert_equal 1, drawn, "the fragments are one block, not one each"
      lines = plain(repl.instance_variable_get(:@app).render_lines)
      assert lines.any? { |line| line.include?("Halo dunia") }
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

    def test_tui_channel_writes_to_the_configured_workspace_and_records_the_launch_dir
      Dir.mktmpdir do |dir|
        configured = File.join(dir, "configured")
        FileUtils.mkdir_p(configured)
        config = isolated_config(dir).with_workspace(configured)
        config.data["tools"] = false
        channel = Channels::TuiChannel.new(app_config: config)
        begin
          assert_equal File.realpath(configured), File.realpath(channel.pool.workspace),
                       "files belong in the configured workspace, not the cwd"
          assert_equal File.realpath(Dir.pwd), File.realpath(channel.pool.sessions_cwd),
                       "/resume still filters on where rubot was launched"
        ensure
          channel.stop
        end
      end
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

    # A report can arrive in pieces -- a multiplexer, an ssh link, an app
    # that is busy painting. The reader used to give up 30 ms after the ESC
    # and hand the rest of the bytes back as keys, so a wheel notch surfaced
    # as a bare Escape: the running turn was cancelled instead of the log
    # scrolling.
    def test_fragmented_mouse_report_is_not_read_as_escape
      require "pty"
      reader, writer = PTY.open
      previous = $stdin
      $stdin = reader

      writer.write("\e")
      sleep 0.04
      writer.write("[<64;10;10M")

      assert_equal :wheel_up, ::TUI::Term.read_key(0.5)&.name
    ensure
      $stdin = previous
      reader&.close
      writer&.close
    end

    # Wheel and page keys both move the conversation. The prompt used to eat
    # page_up/page_down to move its own caret, so the log never moved however
    # the terminal delivered the key.
    def test_wheel_and_page_keys_scroll_the_conversation
      repl = build_repl
      log = repl.instance_variable_get(:@log)
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      80.times { |i| log.add_entry([ [ "row #{i}", :text ] ]) }
      app.render_frame

      bottom = log.instance_variable_get(:@scroll_y)
      app.send(:dispatch, ::TUI::Key.new(:wheel_up))
      assert_equal bottom - 3, log.instance_variable_get(:@scroll_y), "one wheel notch"

      app.send(:dispatch, ::TUI::Key.new(:page_up))
      assert_equal bottom - 13, log.instance_variable_get(:@scroll_y), "page_up"

      app.send(:dispatch, ::TUI::Key.new(:page_down))
      assert_equal bottom - 3, log.instance_variable_get(:@scroll_y), "page_down"

      assert_empty prompt.value, "scrolling must not type into the prompt"
    end

    # A draft taller than the box is the one case where the keys belong to
    # the prompt: the caret moves through the text instead of the log.
    def test_page_keys_page_a_draft_taller_than_the_prompt_box
      repl = build_repl
      log = repl.instance_variable_get(:@log)
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      80.times { |i| log.add_entry([ [ "row #{i}", :text ] ]) }
      prompt.value = (1..12).map { |i| "line #{i}" }.join("\n")
      app.render_frame

      before = log.instance_variable_get(:@scroll_y)
      row = prompt.buffer.row
      app.send(:dispatch, ::TUI::Key.new(:page_up))

      assert_equal before, log.instance_variable_get(:@scroll_y), "the log stays put"
      assert_operator prompt.buffer.row, :<, row, "the caret moved up the draft"
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

    # Dragging on the scrollbar column scrolls the log; it must not be read
    # as a text selection, which is what a press on any other cell starts.
    def test_scrollbar_drag_scrolls_instead_of_selecting
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 20, 5))
      40.times { |i| view.add_entry([ [ "row #{i}", :text ] ]) }
      view.render(::TUI::Canvas.new(20, 5))

      assert view.scrollbar_at?(19, 0), "the last column is the bar"
      refute view.scrollbar_at?(18, 0), "one cell left of it is text"

      view.begin_scrollbar_drag(19, 0)
      refute view.selection?, "grabbing the bar starts no selection"

      view.drag_scrollbar(4)
      assert_equal 35, scroll_y(view), "dragged to the bottom"

      view.drag_scrollbar(0)
      assert_equal 0, scroll_y(view), "and back to the top"
    end
    # The grab point stays under the cursor, so the bar follows the drag
    # instead of jumping to wherever the pointer happens to be.
    def test_scrollbar_keeps_the_grab_point_under_the_cursor
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 20, 20))
      40.times { |i| view.add_entry([ [ "row #{i}", :text ] ]) }
      view.render(::TUI::Canvas.new(20, 20))
      view.scroll_by(-20) # top, so the thumb starts at the first row
      assert_equal 0, scroll_y(view)

      view.begin_scrollbar_drag(19, 5) # inside the thumb, halfway down
      assert view.scrollbar_dragging?
      assert_equal 0, view.send(:scrollbar_thumb_top), "the press does not jump"

      view.drag_scrollbar(6)
      assert_equal 1, view.send(:scrollbar_thumb_top), "the bar followed by one row"

      view.end_scrollbar_drag
      refute view.scrollbar_dragging?
    end

    # A press on the track beside the thumb centres the thumb there and
    # jumps, the way a click on a scrollbar is expected to behave.
    def test_scrollbar_track_click_jumps
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 20, 20))
      100.times { |i| view.add_entry([ [ "row #{i}", :text ] ]) }
      view.render(::TUI::Canvas.new(20, 20))
      view.scroll_by(-100) # top, so the press lands on the track below the thumb
      assert_equal 0, scroll_y(view)
      view.begin_scrollbar_drag(19, 10)
      view.end_scrollbar_drag

      assert_operator scroll_y(view), :>, 0
      assert_equal 8, view.send(:scrollbar_thumb_top), "centred under the cursor"
    end

    # With nothing to scroll there is no bar on screen, so the last column
    # stays selectable like every other cell.
    def test_no_scrollbar_grab_when_the_content_fits
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 20, 5))
      view.add_entry([ [ "short", :text ] ])
      view.render(::TUI::Canvas.new(20, 5))

      refute view.scrollbar_visible?
      refute view.scrollbar_at?(19, 0)

      view.begin_scrollbar_drag(19, 0)
      refute view.scrollbar_dragging?
    end

    # The bar is brighter while it is held, so the grab has feedback.
    def test_scrollbar_is_highlighted_while_dragged
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 20, 5))
      40.times { |i| view.add_entry([ [ "row #{i}", :text ] ]) }
      canvas = ::TUI::Canvas.new(20, 5)
      view.scroll_by(-100) # top, so the thumb sits on the first row
      view.render(canvas)
      styles = canvas.instance_variable_get(:@styles)
      assert_equal ::TUI::Style.id(:muted), styles[0][19]

      view.begin_scrollbar_drag(19, 0)
      view.render(canvas)

      assert_equal ::TUI::Style.id(:thumb), styles[0][19]
    end

    # The wiring: a press on the bar column must scroll, not select, and the
    # release that ends the grab must not fire a copy at the same time.
    def test_scrollbar_drag_in_the_repl_does_not_select
      repl = build_repl
      log = repl.instance_variable_get(:@log)
      app = repl.instance_variable_get(:@app)
      60.times { |i| log.add_entry([ [ "row #{i}", :text ] ]) }
      app.render_frame

      rect = log.instance_variable_get(:@rect)
      bar_x = rect.right
      log.scroll_by(-10)
      app.render_frame
      before = scroll_y(log)

      app.send(:dispatch, ::TUI::Key.new(:mouse_press).at(bar_x, rect.y + 1, button: 0))
      app.send(:dispatch, ::TUI::Key.new(:mouse_drag).at(bar_x, rect.bottom, button: 0))
      app.send(:dispatch, ::TUI::Key.new(:mouse_release).at(bar_x, rect.bottom, button: 0))

      refute log.selection?, "the bar is not a selection"
      assert_operator scroll_y(log), :>, before
      refute log.scrollbar_dragging?, "the release let go of the bar"
    end

    # The floating pill: out of the way while the newest row is on screen,
    # drawn in the log's last row once the user scrolls away — centred on the
    # screen, right above the working line and the prompt.
    def test_jump_button_appears_only_when_the_newest_row_is_off_screen
      log = TUI::LogView.new
      pane = TUI::LogPane.new(log)
      pane.layout(::TUI::Rect.new(0, 0, 40, 8))
      40.times { |i| log.add_entry([ [ "row #{i}", :text ] ]) }
      canvas = ::TUI::Canvas.new(40, 8)

      pane.render(canvas)
      refute pane.button.visible?, "the bottom is on screen: nothing to jump to"

      log.scroll_by(-10)
      pane.render(canvas)

      assert pane.button.visible?
      rect = pane.button.rect
      assert_equal pane.rect.bottom, rect.bottom, "it floats in the log's last row"
      left = rect.x - pane.rect.x
      right = pane.rect.x + pane.rect.w - 1 - rect.right
      assert_operator (left - right).abs, :<=, 1, "it sits in the middle of the pane"
      assert_includes plain(canvas.lines)[rect.y], "jump to bottom"
      assert_equal log.rect.h, pane.rect.h, "the pill takes no row of its own"
    end

    # The gutter and the log's inset are on the left only, so a pill centred
    # inside the pane would sit right of the middle of the terminal: it is
    # centred on the screen instead.
    def test_jump_button_is_centred_on_the_screen_not_the_pane
      repl = build_repl
      log = repl.instance_variable_get(:@log)
      jump = repl.instance_variable_get(:@jump)
      pane = repl.instance_variable_get(:@pane)
      app = repl.instance_variable_get(:@app)
      80.times { |i| log.add_entry([ [ "row #{i}", :text ] ]) }
      canvas = app.render_frame
      log.scroll_by(-10)
      canvas = app.render_frame

      assert jump.visible?
      assert_operator pane.rect.x, :>, 0, "the gutter pushes the pane right"
      left = jump.rect.x
      right = canvas.w - 1 - jump.rect.right
      assert_operator (left - right).abs, :<=, 1,
                      "the pill is centred on the terminal: #{left} left, #{right} right"
    end

    # A log that fits has nowhere to jump to, and the pill must not leave an
    # invisible click target over the last row either.
    def test_jump_button_stays_out_of_a_log_that_fits
      log = TUI::LogView.new
      pane = TUI::LogPane.new(log)
      pane.layout(::TUI::Rect.new(0, 0, 40, 8))
      log.add_entry([ [ "only row", :text ] ])
      pane.render(::TUI::Canvas.new(40, 8))

      refute pane.button.visible?
      refute pane.button.hit?(pane.rect.right - 1, pane.rect.bottom)
    end

    # A click on the pill jumps back to the newest row instead of starting a
    # selection, and the release after it must not fire a copy.
    def test_clicking_the_jump_button_returns_to_the_bottom
      repl = build_repl
      log = repl.instance_variable_get(:@log)
      jump = repl.instance_variable_get(:@jump)
      app = repl.instance_variable_get(:@app)
      60.times { |i| log.add_entry([ [ "row #{i}", :text ] ]) }
      app.render_frame
      log.scroll_by(-10)
      app.render_frame
      refute log.bottom_visible?

      assert jump.visible?, "the pill is up while the newest row is off screen"
      x = jump.rect.x + 1
      y = jump.rect.y
      app.send(:dispatch, ::TUI::Key.new(:mouse_press).at(x, y, button: 0))
      app.send(:dispatch, ::TUI::Key.new(:mouse_release).at(x, y, button: 0))

      assert log.bottom_visible?, "the pill took the log back to the bottom"
      refute log.selection?, "the pill is not a selection"
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
        repl.copy_selection
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
        repl.copy_selection
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



    def test_markdown_bold_italic
      segs = TUI::Markdown.to_segments("***big***")

      assert segs.include?([ "big", :md_bold_italic ])
    end

    # ------------------------------------------------------------------
    # /resume
    # ------------------------------------------------------------------






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
        repl.pump
        repl.handle_command(mailbox.pop)
        repl.pump

        session_list = repl.instance_variable_get(:@session_list)
        assert_equal %w[work], session_list.entries.map { |entry| entry[:id] }
        assert_same session_list, prompt.list, "the list owns the keyboard"
        refute repl.instance_variable_get(:@overlay), "nothing floats"

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

        repl.handle_command("/resume")
        repl.pump
        prompt.handle_key(::TUI::Key.new(:enter))

        assert_nil prompt.list, "picking hands the keyboard back to the prompt"
        command = mailbox.pop
        assert_equal "/resume work", command

        # The worker runs the queued command: the switch stays off the App thread.
        repl.handle_command(command)
        repl.pump
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

        repl.handle_command("/resume")
        repl.pump
        assert_includes plain(app.render_lines).join("\n"), "fix the parser"

        prompt.handle_key(::TUI::Key.new(:escape))

        assert_nil prompt.list, "escape hands the keyboard back to the prompt"
        assert_empty agent.switched
        view = plain(app.render_lines).join("\n")
        refute_includes view, "fix the parser", "the list is taken back out"
        refute_includes view, "↑/↓ choose"

        entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
        assert_equal "", entries.last.map { |text, _| text.to_s }.join.strip,
                     "one blank line below the cancelled command"
      end
    end

    def test_resume_without_a_tty_prints_the_list
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        saved_session(workspace, "work", "fix the parser")

        repl = build_resume_repl(workspace)
        repl.instance_variable_set(:@tui, false)
        out, _err = capture_io { repl.handle_command("/resume") }

        assert_includes out, "Sesi tersimpan:"
        assert_includes out, "work"
        assert_includes out, "2 pesan"
        assert_includes out, "fix the parser"
        assert_includes out, "/resume <nomor>"
      end
    end

    def test_resume_accepts_a_session_id_and_rejects_unknown_ones
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        saved_session(workspace, "work", "fix the parser")

        repl = build_resume_repl(workspace)
        agent = repl.instance_variable_get(:@agent)

        repl.handle_command("/resume work")
        repl.pump
        assert_equal [ "work" ], agent.switched

        repl.handle_command("/resume ../../etc/passwd")
        repl.pump

        assert_equal [ "work" ], agent.switched, "a path never resolves to a session"
        view = plain(repl.instance_variable_get(:@app).render_lines).join("\n")
        assert_includes view, "tidak ditemukan"
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
              "function" => { "name" => "file_read",
                              "arguments" => JSON.generate("operation" => "read", "path" => "/src/parser.rb") }
            } ] },
          { "role" => "tool", "content" => "1: def parse", "tool_call_id" => "call-1" },
          { "role" => "assistant", "content" => "The blank line was skipped." }
        ])

        repl = build_resume_repl(workspace)
        repl.handle_command("/resume work")
        repl.pump

        view = plain(repl.instance_variable_get(:@app).render_lines).join("\n")

        assert_includes view, "❯ fix the parser", "the user prompt is echoed"
        assert_includes view, "Let me look at the file.", "the narration is restored"
        assert_includes view, "✓ Membaca isi /src/parser.rb", "the finished tool row is restored"
        assert_includes view, "The blank line was skipped.", "the answer is restored"
        assert_operator view.index("❯ fix the parser"), :<, view.index("✓ Membaca isi /src/parser.rb")
        assert_operator view.index("✓ Membaca isi /src/parser.rb"), :<, view.index("The blank line was skipped.")
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
        out, _err = capture_io { repl.handle_command("/resume work") }

        assert_includes out, "❯ fix the parser"
        assert_includes out, "✓ Mencari \"ruby\" di dalam berkas"
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
            "function" => { "name" => "file_read",
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
        repl.handle_command("/resume")
        repl.pump

        view = plain(repl.instance_variable_get(:@app).render_lines).join("\n")
        assert_includes view, "Belum ada sesi tersimpan."
      end
    end

    # ------------------------------------------------------------------
    # /models
    # ------------------------------------------------------------------






    def test_models_lists_the_models_the_provider_supports
      repl = build_models_repl(
        catalog: [
          { "id" => "gpt-5", "name" => "GPT-5" },
          { "id" => "gpt-5-mini", "name" => "GPT-5 mini" }
        ]
      )
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      app.render_frame

      repl.handle_command("/models")
      repl.pump

      model_list = repl.instance_variable_get(:@model_list)
      assert_equal %w[gpt-5 gpt-5-mini], model_list.entries.map { |entry| entry[:id] }
      assert_same model_list, prompt.list, "the list owns the keyboard"

      view = plain(app.render_lines).join("\n")
      assert_includes view, "Model yang didukung openai (2)"
      assert_includes view, "gpt-5"
      assert_includes view, "GPT-5 mini"
      assert_includes view, "↑/↓ choose · enter select · esc cancel"
    end

    def test_models_adds_the_configured_models_the_provider_does_not_list
      repl = build_models_repl(
        catalog: [ { "id" => "gpt-5", "name" => "GPT-5" } ],
        models: [ { "name" => "fast", "model" => "openai/deepseek-v4" } ]
      )
      app = repl.instance_variable_get(:@app)
      app.render_frame

      repl.handle_command("/models")
      repl.pump

      model_list = repl.instance_variable_get(:@model_list)
      assert_equal %w[gpt-5 fast], model_list.entries.map { |entry| entry[:id] }
      assert_includes plain(app.render_lines).join("\n"), "deepseek-v4"
    end

    def test_models_marks_the_active_model
      repl = build_models_repl(
        catalog: [
          { "id" => "gpt-5", "name" => "GPT-5" },
          { "id" => "gpt-5-mini", "name" => "GPT-5 mini" }
        ],
        active: "gpt-5-mini"
      )
      app = repl.instance_variable_get(:@app)
      app.render_frame

      repl.handle_command("/models")
      repl.pump

      model_list = repl.instance_variable_get(:@model_list)
      active = model_list.entries.select { |entry| entry[:active] }.map { |entry| entry[:id] }
      assert_equal [ "gpt-5-mini" ], active

      view = plain(app.render_lines).join("\n")
      line = view.lines.find { |l| l.include?("GPT-5 mini") }
      assert_includes line, "✓"
      assert_includes line, "gpt-5-mini"
    end

    def test_models_enter_switches_the_active_session_to_the_highlighted_model
      repl = build_models_repl(
        catalog: [
          { "id" => "gpt-5", "name" => "GPT-5" },
          { "id" => "gpt-5-mini", "name" => "GPT-5 mini" }
        ]
      )
      agent = repl.instance_variable_get(:@agent)
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      mailbox = repl.instance_variable_get(:@mailbox)
      app.render_frame

      repl.handle_command("/models")
      repl.pump

      prompt.handle_key(::TUI::Key.new(:down))
      prompt.handle_key(::TUI::Key.new(:enter))

      assert_nil prompt.list, "picking hands the keyboard back to the prompt"
      command = mailbox.pop
      assert_equal "/use-model gpt-5-mini", command

      # The worker runs the queued command: the switch stays off the App thread.
      repl.handle_command(command)
      repl.pump

      assert_equal [ "gpt-5-mini" ], agent.used
      view = plain(app.render_lines).join("\n")
      assert_includes view, "Berpindah ke model: gpt-5-mini"
      refute_includes view, "↑/↓ choose", "the list is taken back out"
    end

    def test_models_escape_removes_the_list_without_switching
      repl = build_models_repl(catalog: [ { "id" => "gpt-5", "name" => "GPT-5" } ])
      agent = repl.instance_variable_get(:@agent)
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      app.render_frame

      repl.handle_command("/models")
      repl.pump
      assert_includes plain(app.render_lines).join("\n"), "gpt-5"

      prompt.handle_key(::TUI::Key.new(:escape))

      assert_nil prompt.list, "escape hands the keyboard back to the prompt"
      assert_empty agent.used
      view = plain(app.render_lines).join("\n")
      refute_includes view, "gpt-5", "the list is taken back out"
      refute_includes view, "↑/↓ choose"
    end

    def test_a_cancelled_model_list_leaves_one_blank_line_below_the_command
      repl = build_models_repl(catalog: [ { "id" => "gpt-5", "name" => "GPT-5" } ])
      log = repl.instance_variable_get(:@log)
      prompt = repl.instance_variable_get(:@prompt)
      app = repl.instance_variable_get(:@app)
      mailbox = repl.instance_variable_get(:@mailbox)
      app.render_frame

      prompt.value = "/models"
      prompt.handle_key(::TUI::Key.new(:enter))
      repl.pump
      repl.handle_command(mailbox.pop)
      repl.pump

      prompt.handle_key(::TUI::Key.new(:escape))
      repl.pump

      entries = log.instance_variable_get(:@entries)
      command_ix = entries.rindex { |entry| entry.map { |text, _| text.to_s }.join.include?("/models") }
      assert command_ix, "the command is echoed"
      assert_equal "", entries[command_ix + 1].map { |text, _| text.to_s }.join.strip,
                   "one blank line below the cancelled command"
      assert_equal command_ix + 1, entries.length - 1, "nothing else is left over"
    end

    def test_a_command_without_output_leaves_one_blank_line_below_it
      repl = build_models_repl(catalog: [])
      log = repl.instance_variable_get(:@log)
      app = repl.instance_variable_get(:@app)
      mailbox = repl.instance_variable_get(:@mailbox)
      app.render_frame

      prompt = repl.instance_variable_get(:@prompt)
      prompt.value = "/quit"
      prompt.handle_key(::TUI::Key.new(:enter))
      repl.pump
      repl.handle_command(mailbox.pop)
      repl.pump

      entries = log.instance_variable_get(:@entries)
      command_ix = entries.rindex { |entry| entry.map { |text, _| text.to_s }.join.include?("/quit") }
      assert command_ix, "the command is echoed"
      assert_equal "", entries[command_ix + 1].map { |text, _| text.to_s }.join.strip,
                   "one blank line below the command"
    end

    def test_models_filters_the_list_by_name
      repl = build_models_repl(
        catalog: [
          { "id" => "gpt-5", "name" => "GPT-5" },
          { "id" => "claude-sonnet", "name" => "Claude Sonnet" }
        ]
      )
      app = repl.instance_variable_get(:@app)
      app.render_frame

      repl.handle_command("/models claude")
      repl.pump

      model_list = repl.instance_variable_get(:@model_list)
      assert_equal [ "claude-sonnet" ], model_list.entries.map { |entry| entry[:id] }
    end

    def test_models_list_is_padded_and_surrounded_by_blank_rows
      repl = build_models_repl(catalog: [ { "id" => "gpt-5", "name" => "GPT-5" } ])
      app = repl.instance_variable_get(:@app)
      app.render_frame

      repl.handle_command("/models")
      repl.pump

      view = plain(app.render_lines)
      header_ix = view.index { |line| line.include?("Model yang didukung") }
      search_ix = view.index { |line| line.include?("search:") }
      row_ix = view.index { |line| line.include?("gpt-5") }
      hint_ix = view.index { |line| line.include?("↑/↓ choose") }

      assert_equal "", view[header_ix - 1].strip, "one blank row above the header"
      assert_equal "", view[search_ix - 1].strip, "one blank row above the search"
      assert_equal "", view[row_ix - 1].strip, "one blank row between the search and the rows"
      assert_equal "", view[row_ix + 1].strip, "one blank row below the rows"
      assert_equal "", view[hint_ix - 1].strip, "one blank row above the hint"

      assert_equal 4, view[header_ix][/\A */].length, "the header is padded by two cells"
      assert_equal view[search_ix][/\A */].length, view[header_ix][/\A */].length,
                   "the header lines up with the search row"
    end

    def test_typing_in_the_list_searches_the_models
      repl = build_models_repl(
        catalog: [
          { "id" => "gpt-5", "name" => "GPT-5" },
          { "id" => "claude-sonnet", "name" => "Claude Sonnet" },
          { "id" => "claude-opus", "name" => "Claude Opus" }
        ]
      )
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      app.render_frame

      repl.handle_command("/models")
      repl.pump

      model_list = repl.instance_variable_get(:@model_list)
      assert_equal 3, model_list.entries.length

      "claude".each_char { |char| prompt.handle_key(::TUI::Key.printable(char)) }

      assert_equal %w[claude-sonnet claude-opus], model_list.entries.map { |entry| entry[:id] }
      assert_equal "claude", model_list.filter

      view = plain(app.render_lines).join("\n")
      assert_includes view, "search: claude"
      assert_includes view, "(2/3)"
      refute_includes view, "gpt-5"
    end

    def test_backspace_widens_the_search
      repl = build_models_repl(
        catalog: [
          { "id" => "gpt-5", "name" => "GPT-5" },
          { "id" => "claude-sonnet", "name" => "Claude Sonnet" }
        ]
      )
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      app.render_frame

      repl.handle_command("/models")
      repl.pump

      model_list = repl.instance_variable_get(:@model_list)
      "claude".each_char { |char| prompt.handle_key(::TUI::Key.printable(char)) }
      assert_equal 1, model_list.entries.length

      prompt.handle_key(::TUI::Key.new(:backspace))

      assert_equal "claud", model_list.filter
      assert_equal 1, model_list.entries.length

      5.times { prompt.handle_key(::TUI::Key.new(:backspace)) }

      assert_equal "", model_list.filter
      assert_equal 2, model_list.entries.length
    end

    def test_escape_clears_the_search_before_it_closes_the_list
      repl = build_models_repl(
        catalog: [
          { "id" => "gpt-5", "name" => "GPT-5" },
          { "id" => "claude-sonnet", "name" => "Claude Sonnet" }
        ]
      )
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      app.render_frame

      repl.handle_command("/models")
      repl.pump

      model_list = repl.instance_variable_get(:@model_list)
      "claude".each_char { |char| prompt.handle_key(::TUI::Key.printable(char)) }

      prompt.handle_key(::TUI::Key.new(:escape))

      assert_same model_list, prompt.list, "the first escape clears the search"
      assert_equal "", model_list.filter
      assert_equal 2, model_list.entries.length

      prompt.handle_key(::TUI::Key.new(:escape))

      assert_nil prompt.list, "the second escape closes the list"
      refute_includes plain(app.render_lines).join("\n"), "↑/↓ choose"
    end

    def test_a_search_without_a_match_says_so
      repl = build_models_repl(catalog: [ { "id" => "gpt-5", "name" => "GPT-5" } ])
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      app.render_frame

      repl.handle_command("/models")
      repl.pump

      "zzz".each_char { |char| prompt.handle_key(::TUI::Key.printable(char)) }

      assert_includes plain(app.render_lines).join("\n"), "no model matches"
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
        repl.start_fresh_session

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
