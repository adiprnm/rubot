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

      # A launch has spent nothing yet but already carries a system prompt.
      def agent.usage_report
        { requests: 0, prompt_tokens: 0, cache_hit_rate: 0.0,
          context_used: 3_100, context_window: 128_000, context_percent: 2.4,
          cost: { "total" => 0.0 } }
      end

      agent
    end

    def build_repl
      repl = TUI.new(stub_agent)
      repl.send(:build_ui)
      repl.send(:paint_banner)
      repl
    end

    # Stub that remembers auto mode, the way the real handle does.
    def auto_agent
      agent = stub_agent
      def agent.auto_approve?
        @auto == true
      end

      def agent.set_auto_approve(value)
        @auto = value
      end

      def agent.startup_info
        info = { provider: "openai", model: "gpt-test", tools: 3 }
        info[:auto_approve] = true if auto_approve?
        info
      end

      agent
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
      status_ix = view.index { |l| l.include?("gpt-test") && !l.include?("provider") }
      prompt_ix = view.index { |l| l.include?("h") }

      assert prompt_ix && status_ix, "both must render"
      assert_operator status_ix, :>, prompt_ix, "status row sits under the input"
    end

    def test_status_row_shows_metrics_before_the_first_turn
      repl = build_repl
      repl.send(:push_status_info)
      repl.send(:pump)

      row = plain(repl.instance_variable_get(:@app).render_lines).find { |l| l.include?("cache") }

      assert row, "the metrics row is part of the launch view"
      assert_includes row, "$0.000", row.inspect
      assert_includes row, "cache —", row.inspect
      assert_includes row, "ctx 2.4%", row.inspect
    end

    def test_status_line_puts_metrics_left_of_the_model_info
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :status_right, "gpt-test" ]
      ev << [ :status_left, "$0.001 · cache 60% · ctx 8.2%" ]
      repl.send(:pump)

      line = plain(repl.instance_variable_get(:@app).render_lines)
        .find { |l| l.include?("$0.001") }

      assert line, "the metrics row renders"
      assert_includes line, "cache 60%"
      assert_includes line, "ctx 8.2%"
      assert_includes line, "gpt-test", "model info keeps its spot on the right"
      assert_operator line.index("$0.001"), :<, line.index("gpt-test"),
                      "metrics sit on the left: #{line.inspect}"
    end

    def test_status_line_hides_the_session_name
      repl = build_repl
      repl.send(:push_status_info)
      repl.send(:pump)

      status = repl.instance_variable_get(:@status)
      assert_equal "gpt-test", status.instance_variable_get(:@right)
      lines = plain(repl.instance_variable_get(:@app).render_lines)
      refute lines.any? { |l| l.include?("session") }, "the footer does not name the session"
      footer = lines.find { |l| l.include?("$0.000") }
      assert footer, "the metrics row renders"
      refute_includes footer, "openai", "the footer does not name the provider: #{footer.inspect}"
    end

    def test_status_line_truncates_metrics_before_model_info
      status = TUI::StatusLine.new
      status.layout(::TUI::Rect.new(0, 0, 30, 1))
      status.left = "$0.001 · cache 60% · ctx 8.2% · extra-wide-metric"
      status.right = "gpt-test"
      canvas = ::TUI::Canvas.new(30, 1)
      status.render(canvas)

      row = plain(canvas.lines).first
      assert_operator ::TUI::Text.width(row), :<=, 30, row.inspect
      assert_includes row, "gpt-test", "model info survives: #{row.inspect}"
      assert_includes row, "\u2026", "the cut is marked: #{row.inspect}"
    end

    def test_working_badge_shows_the_elapsed_clock_next_to_working
      badge = TUI::WorkingBadge.new
      badge.layout(::TUI::Rect.new(0, 0, 80, 3))
      badge.tick(:work)

      canvas = ::TUI::Canvas.new(80, 3)
      badge.render(canvas)

      row = plain(canvas.lines)[1]
      assert_includes row, "working · 0s · esc cancels", row.inspect
      assert_match(/working · \d+s · esc cancels/, row)
    end

    def test_working_badge_counts_minutes_and_clears_when_idle
      badge = TUI::WorkingBadge.new
      badge.layout(::TUI::Rect.new(0, 0, 80, 3))
      badge.tick(:work)
      badge.instance_variable_set(:@started_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 125)

      canvas = ::TUI::Canvas.new(80, 3)
      badge.render(canvas)
      assert_includes plain(canvas.lines)[1], "working · 2m 05s · esc cancels"

      badge.tick(nil)
      canvas = ::TUI::Canvas.new(80, 3)
      badge.render(canvas)
      assert_nil badge.elapsed, "the clock stops with the turn"
      refute plain(canvas.lines).join.include?("working"), "idle band is blank"
    end

    def test_workspace_line_sits_between_the_prompt_and_the_usage_footer
      repl = build_repl
      line = repl.instance_variable_get(:@workspace_line)
      ev = repl.instance_variable_get(:@events)
      ev << [ :status_left, "$0.001 · cache 60% · ctx 8.2%" ]
      repl.send(:pump)

      lines = plain(repl.instance_variable_get(:@app).render_lines)
      workspace_ix = lines.index { |l| l.include?(line.label) }
      prompt_ix = lines.index { |l| l.include?("\u256d") }
      usage_ix = lines.index { |l| l.include?("$0.001") }

      assert workspace_ix && prompt_ix && usage_ix, "all three rows render: #{lines.inspect}"
      assert_operator workspace_ix, :>, prompt_ix, "the working directory sits under the prompt box"
      assert_operator usage_ix, :>, workspace_ix, "the price estimate sits below the working directory"
    end

    def test_workspace_line_shows_the_launch_directory_without_a_prefix
      Dir.mktmpdir do |dir|
        line = TUI::WorkspaceLine.new
        line.workspace = dir
        line.layout(::TUI::Rect.new(0, 0, 120, 1))
        canvas = ::TUI::Canvas.new(120, 1)
        line.render(canvas)

        row = plain(canvas.lines).first.rstrip
        assert_equal dir, row
        refute_includes row, "workspace "
      end
    end

    def test_workspace_line_shows_the_git_branch
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".git"))
        File.write(File.join(dir, ".git", "HEAD"), "ref: refs/heads/feature/x\n")

        line = TUI::WorkspaceLine.new
        line.workspace = dir

        assert_equal "#{dir} @ feature/x", line.label
      end
    end

    def test_workspace_line_finds_the_branch_from_a_subdirectory
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".git"))
        File.write(File.join(dir, ".git", "HEAD"), "ref: refs/heads/main\n")
        sub = File.join(dir, "app", "models")
        FileUtils.mkdir_p(sub)

        line = TUI::WorkspaceLine.new
        line.workspace = sub

        assert_equal "#{sub} @ main", line.label
      end
    end

    def test_workspace_line_shortens_a_detached_head
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".git"))
        File.write(File.join(dir, ".git", "HEAD"), "#{"a" * 40}\n")

        line = TUI::WorkspaceLine.new
        line.workspace = dir

        assert_equal "#{dir} @ aaaaaaa", line.label
      end
    end

    def test_workspace_line_abbreviates_the_home_directory
      line = TUI::WorkspaceLine.new

      assert_equal "~/work/rubot", line.send(:abbreviate, File.join(Dir.home, "work", "rubot"))
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
      assert view.any? { |l| l.include?("$0.0012 · cache 60% · ctx 8.2%") },
             "the footer carries the turn's usage: #{view.last(3).inspect}"
    end

    LAYERED_REPORTS = [
      { requests: 1, prompt_tokens: 1_000, cache_hit_rate: 0.9,
        context_used: 5_000, context_window: 128_000, context_percent: 3.9,
        cost: { "total" => 0.004 } },
      { requests: 2, prompt_tokens: 2_000, cache_hit_rate: 0.8,
        context_used: 9_000, context_window: 128_000, context_percent: 7.0,
        cost: { "total" => 0.009 } }
    ].freeze

    # The footer is not a post-mortem: each request's figures have to reach the
    # status row while the turn is still running, not only when it ends.
    def test_usage_footer_tracks_each_request_mid_turn
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      queue = repl.instance_variable_get(:@events)
      footers = []

      agent.define_singleton_method(:process) do |_msg, on_usage: nil, **_opts, &_blk|
        LAYERED_REPORTS.each do |report|
          on_usage&.call(report)
          # Read before the turn ends: whatever is already queued is what the
          # status row will show next tick.
          footer = nil
          until queue.empty?
            event = queue.pop(true)
            next unless event[0] == :status_left

            footer = event[1]
            break
          end
          footers << footer
        end
        "ok"
      end
      agent.define_singleton_method(:flush_learning) { nil }

      repl.send(:process_message, "hi")

      assert_equal [ "$0.0040 · cache 90% · ctx 3.9%", "$0.0090 · cache 80% · ctx 7.0%" ], footers
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

    def test_resume_lists_only_sessions_from_the_launch_directory
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        other = File.join(dir, "other-project")
        saved_session(workspace, "mine", "work on this project")
        saved_session(workspace, "theirs", "work on another project", cwd: other)
        saved_session(workspace, "chat", "telegram chatter", cwd: nil)

        repl = build_resume_repl(workspace)

        assert_equal %w[mine], repl.send(:resume_entries).map { |entry| entry[:id] }
        assert_equal %w[theirs mine], repl.send(:resume_entries, all: true).map { |entry| entry[:id] },
                     "all ignores the directory but still hides sessions with no origin"
      end
    end

    def test_resume_keeps_other_directories_reachable_by_id
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        other = File.join(dir, "other-project")
        saved_session(workspace, "theirs", "work on another project", cwd: other)

        repl = build_resume_repl(workspace)

        assert_empty repl.send(:resume_entries)

        repl.send(:handle_command, "/resume all")
        assert_equal %w[theirs], repl.send(:resume_entries, all: true).map { |entry| entry[:id] }

        out, _err = capture_io { repl.send(:handle_command, "/resume theirs") }
        refute_includes out, "not found"
      end
    end

    def test_the_plain_list_mentions_conversations_from_other_directories
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        saved_session(workspace, "theirs", "work on another project", cwd: File.join(dir, "other-project"))

        repl = build_resume_repl(workspace)
        repl.instance_variable_set(:@tui, false)

        out, _err = capture_io { repl.send(:handle_command, "/resume") }

        assert_includes out, "1 conversation(s) from other directories · /resume all"
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

    # A multiline prompt echo keeps its continuation rows under the text of
    # the first row: the "❯ " marker opens the entry, and every later row —
    # typed newline or soft wrap — hangs by the marker's width.
    def test_prompt_echo_continuation_rows_hang_under_the_marker
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 24, 10))
      view.add_entry([ [ "❯ ", :accent ],
                       [ "first line\nsecond line wraps on and on\nthird", :text ] ],
                     keep_leading: true, hang: 2)

      rows = view.instance_variable_get(:@lines).map do |line|
        line.map { |(text, _style)| text }.join
      end

      assert_equal "❯ first line", rows[0], "the marker opens the first row"
      assert_operator rows.size, :>, 3, "the second row must soft-wrap"
      rows.drop(1).each do |row|
        assert_equal "  ", row[0, 2], "every later row hangs by two cells: #{row.inspect}"
      end
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

    # A turn that opens with a tool call used to reserve the answer's row (and
    # the blank above it) at stream_start: two blank rows sat under the prompt
    # while the model thought, then vanished when the tool row replaced them.
    def test_a_turn_that_opens_with_a_tool_call_reserves_no_blank_rows
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      log = repl.instance_variable_get(:@log)

      ev << [ :entry, [ [ "❯ ", :accent ], [ "list the files", :text ] ] ]
      base = log.entry_count
      ev << [ :stream_start ]
      repl.send(:pump)
      assert_equal base + 1, log.entry_count, "the model thinking must not open blank rows"

      ev << [ :tool_call, "shell_exec", { "command" => "ls" } ]
      repl.send(:pump)
      texts = log.instance_variable_get(:@entries).map { |entry| entry.map(&:first).join }
      assert_equal [ "❯ list the files", "⚒ shell_exec ls" ], texts.last(2),
                   "the tool row sits directly under the prompt"
    end

    def test_the_first_token_still_opens_one_blank_and_the_answer
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      log = repl.instance_variable_get(:@log)

      ev << [ :entry, [ [ "❯ ", :accent ], [ "halo", :text ] ] ]
      ev << [ :stream_start ]
      ev << [ :chunk, "Halo!" ]
      repl.send(:pump)

      texts = log.instance_variable_get(:@entries).map { |entry| entry.map(&:first).join }
      assert_equal [ "❯ halo", "", "Halo!" ], texts.last(3),
                   "one blank separates the prompt from the answer"
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
      assert_includes line, "38;2;230;126;128", "the notice is red"

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

    # A steer that spans lines or wraps keeps its later rows under the text of
    # the first one: the "↳ " marker opens the entry, and every row after it
    # hangs by the marker's width, the same way a prompt echo does.
    def test_steer_echo_continuation_rows_hang_under_the_marker
      repl = build_repl
      repl.send(:add_steer_echo,
                "first line of the steer\n" + "second line that runs long enough to soft-wrap at any sane width " * 2)

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
      repl.send(:spawn_command_lane)

      begin
        lane << "/help"
        rows = []
        deadline = Time.now + 5
        while Time.now < deadline
          repl.send(:pump)
          app.render_lines
          rows = repl.instance_variable_get(:@log).instance_variable_get(:@lines).map do |line|
            line.map { |(text, _style)| text }.join
          end
          break if rows.any? { |row| row.include?("Available commands") }

          sleep 0.02
        end

        assert rows.any? { |row| row.include?("Available commands") },
               "the lane's output lands mid-turn: #{rows.map(&:strip).first(5).inspect}"
        assert repl.instance_variable_get(:@busy), "the turn is still running"
      ensure
        repl.send(:stop_command_lane)
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

      repl.send(:handle_command, "/clear")
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

      out, _err = capture_io { repl.send(:handle_command, "/context") }

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
      assert_equal %w[/session], input.menu_items

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

    # A temporary tree with a nested file, used by the @-mention tests.
    def with_files
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "README.md"), "")
        File.write(File.join(dir, "lib", "app.rb"), "")
        yield TUI::PromptInput.new([], TUI::COMPLETABLE, files: TUI::FileIndex.new(dir))
      end
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

    def test_failed_tool_call_flips_the_marker_to_a_cross
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :tool_call, "shell_exec", { "command" => "exit 1" } ]
      ev << [ :tool_done, "shell_exec", nil, "[Exit code: 1]\nboom" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      line = plain(app.render_lines).find { |l| l.include?("shell_exec") }
      assert line, "the tool row is still there"
      assert_includes line, "\u2717", "a failed call is marked with a cross: #{line.inspect}"
      refute_includes line, "\u2713"

      entries = repl.instance_variable_get(:@log).instance_variable_get(:@entries)
      done = entries.find { |e| e.any? { |(t, _)| t.include?("shell_exec") } }
      assert_includes done, [ "✗ ", :error ]
    end

    def test_zero_exit_shell_call_stays_a_check
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :tool_call, "shell_exec", { "command" => "true" } ]
      ev << [ :tool_done, "shell_exec", nil, "[Exit code: 0]\n" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      line = plain(app.render_lines).find { |l| l.include?("shell_exec") }
      assert_includes line, "\u2713"
      refute_includes line, "\u2717"
    end

    def test_error_tool_result_is_marked_as_a_failure
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      ev << [ :tool_call, "file_ops", { "operation" => "read", "path" => "/nope" } ]
      ev << [ :tool_done, "file_ops", nil, "ERROR: Errno::ENOENT: no such file" ]
      app = repl.instance_variable_get(:@app)
      app.send(:run_timers)

      line = plain(app.render_lines).find { |l| l.include?("file_ops") }
      assert_includes line, "\u2717"
    end

    def test_a_tool_call_past_the_threshold_shows_a_live_clock
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      app = repl.instance_variable_get(:@app)
      ev << [ :tool_call, "shell_exec", { "command" => "sleep 10" } ]
      repl.send(:pump)

      # The call started 4.5 seconds ago and has not come back yet.
      entries = repl.instance_variable_get(:@tool_entries)
      entries["shell_exec"][:started_at] -= 4.5
      repl.send(:refresh_slow_tools)

      line = plain(app.render_lines).find { |l| l.include?("shell_exec") }
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
      repl.send(:pump)
      ev << [ :tool_done, "shell_exec", nil, "[Exit code: 0]\n" ]
      repl.send(:pump)

      line = plain(app.render_lines).find { |l| l.include?("shell_exec") }
      assert_includes line, "\u2713"
      refute_includes line, "\u00b7", "a quick call keeps its quiet one-line row: #{line.inspect}"
    end

    def test_a_slow_tool_call_keeps_its_duration_once_done
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      app = repl.instance_variable_get(:@app)
      ev << [ :tool_call, "shell_exec", { "command" => "sleep 5" } ]
      repl.send(:pump)
      repl.instance_variable_get(:@tool_entries)["shell_exec"][:started_at] -= 12.2

      ev << [ :tool_done, "shell_exec", nil, "[Exit code: 0]\n" ]
      repl.send(:pump)

      line = plain(app.render_lines).find { |l| l.include?("shell_exec") }
      assert_includes line, "\u2713", "the row still ends a check: #{line.inspect}"
      assert_includes line, "\u00b7 12s", "the finished row keeps how long it took: #{line.inspect}"
    end

    # The duration is pinned in the text columns, one cell short of the
    # scrollbar column, so the bar can never be drawn over it.
    def test_a_tool_clock_never_reaches_the_scrollbar_column
      repl = build_repl
      ev = repl.instance_variable_get(:@events)
      app = repl.instance_variable_get(:@app)
      ev << [ :tool_call, "shell_exec", { "command" => "sleep 10" } ]
      repl.send(:pump)
      repl.instance_variable_get(:@tool_entries)["shell_exec"][:started_at] -= 4.5
      repl.send(:refresh_slow_tools)

      log = repl.instance_variable_get(:@log)
      row = plain(app.render_lines).find { |l| l.include?("shell_exec") }
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
      ev << [ :tool_call, "shell_exec", { "command" => "sleep 10" } ]
      repl.send(:pump)
      repl.instance_variable_get(:@tool_entries)["shell_exec"][:started_at] -= 4.5
      repl.send(:refresh_slow_tools)

      rows = plain(app.render_lines)
      log_row = rows.index { |l| l.include?("shell_exec") }
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
      ev << [ :tool_call, "shell_exec", { "command" => "echo #{'y' * 400}" } ]
      repl.send(:pump)
      repl.instance_variable_get(:@tool_entries)["shell_exec"][:started_at] -= 7.0
      repl.send(:refresh_slow_tools)

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
      view.add_entry([ [ "\u2692 shell_exec sleep 10", :text ] ],
                     indent: 2, tail: TUI::Transcript.elapsed_tail(7))
      view.render(::TUI::Canvas.new(60, 6))

      view.layout(::TUI::Rect.new(0, 0, 30, 6))
      canvas = ::TUI::Canvas.new(30, 6)
      view.render(canvas)

      row = plain(canvas.lines).find { |l| l.include?("shell_exec") }
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
      row = texts.find { |t| t.include?("shell_exec") }
      assert_includes row, "\u2717", "restored session keeps the failure marker: #{row.inspect}"
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

    # --- file diffs ----------------------------------------------------

    # Run one turn whose tool writes `after` into `path`, the way the agent
    # loop does it: on_tool_call fires before the write, on_tool_result after,
    # and both carry the file's before/after text. The TUI never reads the file
    # itself — that raced the tool, so a delete's diff came out empty.
    def run_file_tool(repl, operation:, path:, after:, snapshot_after_write: false)
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:process) do |_message, on_tool_call: nil, on_tool_result: nil, **_opts, &_blk|
        before = File.exist?(path) ? File.read(path, encoding: "UTF-8") : nil
        args = { "operation" => operation, "path" => path }
        on_tool_call&.call("file_ops", args, { path: path, expanded: File.expand_path(path), before: before })
        # nil after means the call removed the file, as `delete` does.
        after.nil? ? FileUtils.rm_f(path) : File.write(path, after)
        # The before-content is the one taken before the write; reading it now
        # (snapshot_after_write) is what a racing caller would see.
        seen = snapshot_after_write && File.exist?(path) ? File.read(path, encoding: "UTF-8") : before
        ui_diff = { "path" => path, "before" => seen, "after" => after }
        on_tool_result&.call("file_ops", "ok", ui_diff)
        "done"
      end
      agent.define_singleton_method(:flush_learning) { nil }
      agent.define_singleton_method(:usage_report) { nil }

      repl.send(:process_message, "edit it")
      repl.send(:pump)
      repl
    end

    def entry_texts(repl)
      repl.instance_variable_get(:@log).instance_variable_get(:@entries)
          .map { |entry| entry.map(&:first).join }
    end

    def git_texts(rows)
      rows.map { |segments| segments.map(&:first).join }
    end

    def test_write_shows_a_pi_diff_under_the_tool_row
      Dir.mktmpdir do |dir|
        path = File.join(dir, "notes.md")
        File.write(path, "one\ntwo\nthree\n")
        repl = run_file_tool(build_repl, operation: "write", path: path,
                             after: "one\nTWO\nthree\n")

        texts = entry_texts(repl)
        tool_ix = texts.index { |text| text.include?("file_ops") }
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

      assert_nil repl.send(:file_diff, nil), "no payload, no diff"
      assert_nil repl.send(:file_diff, {}), "an empty payload has nothing to draw"
      assert_nil repl.send(:file_diff, { "path" => "x", "before" => nil, "after" => nil }),
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
          "name" => "file_ops",
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
            "function" => { "name" => "file_ops",
                            "arguments" => JSON.generate({ "operation" => "write",
                                                           "path" => "notes.md" }) } }
        ] },
        { "role" => "tool", "tool_call_id" => "call_1", "content" => "Written 1 characters" }
      ]

      texts = TUI::Transcript.entries(messages, width: 73)
                    .map { |entry| entry[:segments].map(&:first).join }

      refute(texts.any? { |text| text.match?(/\A[+-]\d/) }, "no metadata, no diff")
    end

    # --- dangerous-action confirmation ---------------------------------

    # A write to an existing file is a dangerous action: the worker must ask
    # through the prompt instead of blocking forever on an answer nothing
    # could give.
    def test_dangerous_action_asks_through_the_prompt_and_allows
      repl = build_repl
      callback = repl.send(:confirm_callback)
      answer = nil
      worker = Thread.new do
        answer = callback.call("file_ops", { "operation" => "write", "path" => "/tmp/notes.md" })
      end

      event = repl.instance_variable_get(:@events).pop
      assert_equal :confirm, event[0], "the ask is published to the App thread"
      assert_equal "file_ops", event[1]
      list = repl.instance_variable_get(:@confirm_prompt)
      log = repl.instance_variable_get(:@log)
      before = log.entry_count
      repl.send(:apply_event, event)

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
        answer = replit.send(:confirm_callback)
                     .call("file_ops", { "operation" => "write", "path" => "/tmp/a" })
      end
      replit.send(:apply_event, replit.instance_variable_get(:@events).pop)

      list = replit.instance_variable_get(:@confirm_prompt)

      list.handle_key(::TUI::Key.new(:enter))
      assert worker.join(2)
      assert_equal false, answer, "a blind enter rejects, it never allows"
    end

    def test_right_arrow_moves_to_reject_and_esc_rejects
      replit = build_repl
      answer = nil
      worker = Thread.new do
        answer = replit.send(:confirm_callback)
                     .call("shell_exec", { "command" => "rm -rf build" })
      end
      replit.send(:apply_event, replit.instance_variable_get(:@events).pop)

      list = replit.instance_variable_get(:@confirm_prompt)
      list.handle_key(::TUI::Key.new(:right))
      list.handle_key(::TUI::Key.new(:enter))
      assert worker.join(2)
      assert_equal false, answer
    end

    def test_each_confirmation_gets_its_own_answer_queue
      repl = build_repl
      callback = repl.send(:confirm_callback)

      first = Thread.new { callback.call("file_ops", { "operation" => "write", "path" => "/tmp/a" }) }
      first_event = repl.instance_variable_get(:@events).pop
      repl.send(:apply_event, first_event)
      repl.instance_variable_get(:@confirm_prompt).handle_key(::TUI::Key.new(:left))
      repl.instance_variable_get(:@confirm_prompt).handle_key(::TUI::Key.new(:enter))
      assert first.join(2)

      second = Thread.new { callback.call("file_ops", { "operation" => "write", "path" => "/tmp/b" }) }
      second_event = repl.instance_variable_get(:@events).pop
      refute_equal first_event[3], second_event[3], "an old answer cannot leak into the next ask"
      repl.send(:apply_event, second_event)
      repl.instance_variable_get(:@confirm_prompt).handle_key(::TUI::Key.new(:escape))
      assert second.join(2)
      assert_equal false, second.value
    end

    # While the question is up the mouse stays with the log, so the path or
    # command can be drag-selected and copied before answering.
    def test_selection_keys_reach_the_log_while_the_confirmation_is_up
      list = Rubot::TUI::ConfirmPrompt.new(log: Rubot::TUI::LogView.new)
      list.ask("file_ops", { "operation" => "write", "path" => "/tmp/x" }, answered: Queue.new)

      refute list.handle_key(::TUI::Key.new(:mouse_press)), "mouse keys pass through to the log bindings"
      refute list.handle_key(::TUI::Key.new(:page_up)), "scrolling passes through too"
    end

    # A stray keystroke during the ask is swallowed, never smuggled into the
    # prompt buffer and never read as an answer.
    def test_stray_keys_are_swallowed_while_the_confirmation_is_up
      list = Rubot::TUI::ConfirmPrompt.new(log: Rubot::TUI::LogView.new)
      answered = Queue.new
      list.ask("file_ops", { "operation" => "write", "path" => "/tmp/x" }, answered: answered)

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

    # The wrapped rows of one markdown list, each as the plain text the log
    # paints, with the entry indent already applied.
    def list_rows(markdown)
      view = TUI::LogView.new
      view.layout(::TUI::Rect.new(0, 0, 24, 14))
      view.add_entry(TUI::Markdown.to_segments(markdown), keep_leading: true, indent: 2)
      rows = view.instance_variable_get(:@lines).map { |row| row.map(&:first).join }
      rows.reject(&:empty?)
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

    # /auto flips the mode through the agent handle (which persists it to
    # config.yml) and says so; the status row carries the word, so an agent
    # that stopped asking is visible without scrolling back.
    def test_auto_command_turns_auto_mode_on_and_flags_the_status_row
      agent = auto_agent
      repl = TUI.new(agent)
      repl.send(:build_ui)
      repl.send(:paint_banner)

      repl.send(:handle_command, "/auto on")
      repl.send(:pump)

      assert agent.auto_approve?, "the agent must be told"
      view = plain(repl.instance_variable_get(:@app).render_lines)
      assert_includes view.join("\n"), "Auto mode on"
      assert_includes view.join("\n"), "AUTO", "the status row must say AUTO"
    end

    # The badge carries the theme's warning colour (everforest amber
    # #dbbc7f) instead of the row's dim grey, so a mode that stops asking is
    # visible at a glance rather than blending into the model text.
    def test_auto_badge_uses_the_theme_warning_colour
      agent = auto_agent
      agent.set_auto_approve(true)
      repl = TUI.new(agent)
      repl.send(:build_ui)
      repl.send(:paint_banner)

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
      repl.send(:build_ui)
      repl.send(:paint_banner)

      repl.send(:handle_command, "/auto")
      repl.send(:pump)

      refute agent.auto_approve?
      view = plain(repl.instance_variable_get(:@app).render_lines)
      assert_includes view.join("\n"), "Auto mode off"
      refute_includes view.join("\n"), "AUTO ·"
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

    def test_tui_channel_takes_the_launch_directory_as_its_workspace
      Dir.mktmpdir do |dir|
        config = isolated_config(dir).with_workspace(File.join(dir, "configured"))
        config.data["tools"] = false
        channel = Channels::TuiChannel.new(app_config: config)
        begin
          assert_equal File.realpath(Dir.pwd), File.realpath(channel.pool.workspace),
                       "files must be looked up in the cwd, not the configured workspace"
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
    # The log keeps its scroll offset private; the scrollbar tests read it
    # the same way the other view tests do.
    def scroll_y(view)
      view.instance_variable_get(:@scroll_y)
    end

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
      attr_reader :workspace, :sessions_dir, :sessions_cwd

      def initialize(workspace)
        @workspace = workspace
        # Central storage plus the directory sessions are tagged with; the real
        # Config keeps them apart, the fake keeps both inside the tmpdir.
        @sessions_dir = File.join(workspace, "sessions")
        @sessions_cwd = workspace
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

    def saved_session(workspace, id, content, updated_at: Time.now.iso8601, messages: nil, cwd: :default)
      dir = File.join(workspace, "sessions")
      FileUtils.mkdir_p(dir)
      messages ||= [
        { "role" => "user", "content" => content },
        { "role" => "assistant", "content" => "answer to #{content}" }
      ]
      payload = {
        "id" => id,
        "updated_at" => updated_at,
        "messages" => messages
      }
      # Sessions are tagged with the directory they were launched from; :default
      # means "this workspace", nil means "no origin at all".
      tag = cwd == :default ? workspace : cwd
      payload["cwd"] = tag if tag
      File.write(File.join(dir, "#{id}.json"), JSON.pretty_generate(payload))
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

    # ------------------------------------------------------------------
    # /models
    # ------------------------------------------------------------------

    class ModelsConfigView
      def initialize(models)
        @models = models
      end

      def models
        @models
      end

      def model_entry_by_name(name)
        @models.find { |model| model["name"] == name }
      end
    end

    class ModelsSessionView
      attr_accessor :model_override

      def initialize
        @model_override = nil
      end

      def id
        "default"
      end
    end

    class ModelsProviderView
      def name
        "openai"
      end
    end

    # An agent that knows a provider catalog, so /models has something to
    # list that config.yml does not mention.
    class ModelsAgent
      attr_reader :config, :session, :provider, :used

      def initialize(models:, catalog:, active: "gpt-test")
        @config = ModelsConfigView.new(models)
        @session = ModelsSessionView.new
        @provider = ModelsProviderView.new
        @catalog = catalog
        @active = active
        @used = []
      end

      def startup_info
        { provider: "openai", model: @active, tools: 3 }
      end

      def provider_models
        @catalog
      end

      def active_model_name
        @active
      end

      def use_model(name)
        @used << name.to_s
        @active = name.to_s
        @session.model_override = name.to_s
        name.to_s
      end

      def usage_report
        nil
      end
    end

    def build_models_repl(models: [], catalog: [], active: "gpt-test")
      repl = TUI.new(ModelsAgent.new(models: models, catalog: catalog, active: active))
      repl.send(:build_ui)
      repl.send(:paint_banner)
      repl
    end

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

      repl.send(:handle_command, "/models")
      repl.send(:pump)

      model_list = repl.instance_variable_get(:@model_list)
      assert_equal %w[gpt-5 gpt-5-mini], model_list.entries.map { |entry| entry[:id] }
      assert_same model_list, prompt.list, "the list owns the keyboard"

      view = plain(app.render_lines).join("\n")
      assert_includes view, "Models supported by openai (2)"
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

      repl.send(:handle_command, "/models")
      repl.send(:pump)

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

      repl.send(:handle_command, "/models")
      repl.send(:pump)

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

      repl.send(:handle_command, "/models")
      repl.send(:pump)

      prompt.handle_key(::TUI::Key.new(:down))
      prompt.handle_key(::TUI::Key.new(:enter))

      assert_nil prompt.list, "picking hands the keyboard back to the prompt"
      command = mailbox.pop
      assert_equal "/use-model gpt-5-mini", command

      # The worker runs the queued command: the switch stays off the App thread.
      repl.send(:handle_command, command)
      repl.send(:pump)

      assert_equal [ "gpt-5-mini" ], agent.used
      view = plain(app.render_lines).join("\n")
      assert_includes view, "Switched to model: gpt-5-mini"
      refute_includes view, "↑/↓ choose", "the list is taken back out"
    end

    def test_models_escape_removes_the_list_without_switching
      repl = build_models_repl(catalog: [ { "id" => "gpt-5", "name" => "GPT-5" } ])
      agent = repl.instance_variable_get(:@agent)
      app = repl.instance_variable_get(:@app)
      prompt = repl.instance_variable_get(:@prompt)
      app.render_frame

      repl.send(:handle_command, "/models")
      repl.send(:pump)
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
      repl.send(:pump)
      repl.send(:handle_command, mailbox.pop)
      repl.send(:pump)

      prompt.handle_key(::TUI::Key.new(:escape))
      repl.send(:pump)

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
      repl.send(:pump)
      repl.send(:handle_command, mailbox.pop)
      repl.send(:pump)

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

      repl.send(:handle_command, "/models claude")
      repl.send(:pump)

      model_list = repl.instance_variable_get(:@model_list)
      assert_equal [ "claude-sonnet" ], model_list.entries.map { |entry| entry[:id] }
    end

    def test_models_list_is_padded_and_surrounded_by_blank_rows
      repl = build_models_repl(catalog: [ { "id" => "gpt-5", "name" => "GPT-5" } ])
      app = repl.instance_variable_get(:@app)
      app.render_frame

      repl.send(:handle_command, "/models")
      repl.send(:pump)

      view = plain(app.render_lines)
      header_ix = view.index { |line| line.include?("Models supported by") }
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

      repl.send(:handle_command, "/models")
      repl.send(:pump)

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

      repl.send(:handle_command, "/models")
      repl.send(:pump)

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

      repl.send(:handle_command, "/models")
      repl.send(:pump)

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

      repl.send(:handle_command, "/models")
      repl.send(:pump)

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
        repl.send(:start_fresh_session)

        assert File.exist?(previous), "the earlier conversation keeps its file and id"
        assert_equal [ "keep me" ], JSON.parse(File.read(previous))["messages"].map { |m| m["content"] }

        fresh_id = repl.instance_variable_get(:@session_id)
        refute_equal "default", fresh_id
        refute File.exist?(File.join(workspace, "sessions", "#{fresh_id}.json")),
               "the new session is only written once it has a message"
      end
    end

    # --- clipboard paste ---------------------------------------------------

    # The clipboard is read through desktop tools, which no test can rely on;
    # what the paste key does with what it finds is what is checked here.
    def stub_clipboard(images: [], text: nil)
      originals = { capture_all: ClipboardImage.method(:capture_all), text: ClipboardImage.method(:text) }
      ClipboardImage.define_singleton_method(:capture_all) { |dir: nil| images }
      ClipboardImage.define_singleton_method(:text) { text }
      yield
    ensure
      originals.each { |name, method| ClipboardImage.define_singleton_method(name, method) }
    end

    # A PNG header is enough for ImageInfo to read the dimensions.
    def png_file(dir, width: 40, height: 30, name: "shot.png")
      ihdr = [ width, height, 8, 2, 0, 0, 0 ].pack("N2C5")
      path = File.join(dir, name)
      File.binwrite(path, "\x89PNG\r\n\x1A\n".b + [ 13 ].pack("N") + "IHDR" + ihdr + [ 0 ].pack("N"))
      path
    end

    def test_paste_key_puts_an_image_token_in_the_prompt
      Dir.mktmpdir do |dir|
        path = png_file(dir)
        repl = build_repl
        app = repl.instance_variable_get(:@app)
        prompt = repl.instance_variable_get(:@prompt)

        stub_clipboard(images: [ path ]) do
          assert_equal false, prompt.handle_key(::TUI::Key.new(:ctrl_v)),
                       "the prompt passes the key on, so the app binding runs"
          app.send(:dispatch, ::TUI::Key.new(:ctrl_v))
        end

        assert_equal "[Image 1]", prompt.value,
                     "the box shows a token, not a sentence and not a path"
        assert_equal [ path ], prompt.images
      end
    end

    def test_paste_key_numbers_several_images
      Dir.mktmpdir do |dir|
        first = png_file(dir, name: "a.png")
        second = png_file(dir, name: "b.png")
        third = png_file(dir, name: "c.png")
        repl = build_repl
        prompt = repl.instance_variable_get(:@prompt)

        stub_clipboard(images: [ first, second, third ]) { repl.send(:paste_clipboard) }

        assert_equal "[Image 1] [Image 2] [Image 3]", prompt.value
        assert_equal [ first, second, third ], prompt.images
      end
    end

    def test_a_second_paste_continues_the_numbering
      Dir.mktmpdir do |dir|
        first = png_file(dir, name: "a.png")
        second = png_file(dir, name: "b.png")
        repl = build_repl
        prompt = repl.instance_variable_get(:@prompt)

        stub_clipboard(images: [ first ]) { repl.send(:paste_clipboard) }
        stub_clipboard(images: [ second ]) { repl.send(:paste_clipboard) }

        assert_equal "[Image 1] [Image 2]", prompt.value
        assert_equal [ first, second ], prompt.images
      end
    end

    def test_the_submitted_message_carries_the_image_paths_and_no_prose
      Dir.mktmpdir do |dir|
        path = png_file(dir)
        repl = build_repl
        prompt = repl.instance_variable_get(:@prompt)
        mailbox = repl.instance_variable_get(:@mailbox)

        stub_clipboard(images: [ path ]) { repl.send(:paste_clipboard) }
        prompt.insert(" jelaskan ini")
        prompt.handle_key(::TUI::Key.new(:enter))

        line = mailbox.pop
        assert_equal "#{path} jelaskan ini", line,
                     "the token becomes the path, with nothing else added"
        refute_match(/attached/i, line)
      end
    end

    def test_paste_key_keeps_the_prompt_text_around_the_image
      Dir.mktmpdir do |dir|
        path = png_file(dir)
        repl = build_repl
        prompt = repl.instance_variable_get(:@prompt)
        prompt.value = "lihat:"

        stub_clipboard(images: [ path ]) { repl.send(:paste_clipboard) }

        assert_equal "lihat: [Image 1]", prompt.value, "a space separates the token from the text"
      end
    end

    def test_paste_key_says_nothing_when_the_clipboard_is_empty
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      events = repl.instance_variable_get(:@events)

      stub_clipboard { repl.send(:paste_clipboard) }

      assert_equal "", prompt.value
      assert_empty events, "an empty clipboard is not worth a line of output"
    end

    def test_paste_key_inserts_clipboard_text_when_there_is_no_image
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)

      stub_clipboard(text: "one\ntwo") { repl.send(:paste_clipboard) }

      assert_equal "one\ntwo", prompt.value
    end

    def test_insert_places_text_at_the_cursor
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      "ac".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      input.handle_key(::TUI::Key.new(:left))

      changes = 0
      input.on(:change) { changes += 1 }
      input.insert("b")

      assert_equal "abc", input.value
      assert_equal 1, changes, "one change event per insertion"
    end

    # --- long pastes -------------------------------------------------------

    def long_text(lines)
      (1..lines).map { |i| "line #{i} of a pasted passage" }.join("\n")
    end

    def test_a_short_paste_lands_in_the_buffer_as_typed
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      input.handle_key(::TUI::Key.new(:paste, "one\ntwo"))

      assert_equal "one\ntwo", input.value
    end

    def test_a_long_paste_is_collapsed_to_a_token
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      input.handle_key(::TUI::Key.new(:paste, long_text(500)))

      assert_equal "[pasted 500 lines #1]", input.value,
                   "the buffer holds a token, not 500 lines the renderer must draw"
      assert_equal 1, input.buffer.lines.size
    end

    def test_a_long_single_line_paste_is_collapsed_too
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      input.handle_key(::TUI::Key.new(:paste, "x" * 2000))

      assert_match(/\A\[pasted 1 lines #\d+\]\z/, input.value)
    end

    def test_expanding_a_token_gives_back_the_pasted_text
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      pasted = long_text(500)
      input.handle_key(::TUI::Key.new(:paste, pasted))
      input.handle_key(::TUI::Key.printable("?"))
      input.handle_key(::TUI::Key.printable(" "))

      assert_equal "#{pasted}? ", input.expand(input.value),
                   "the text comes back untouched, with what was typed around it"
    end

    def test_expansion_happens_once
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      input.handle_key(::TUI::Key.new(:paste, long_text(20)))
      input.expand(input.value)

      assert_equal "[pasted 20 lines #1]", input.expand(input.value),
                   "a stale token is left alone instead of expanding to nothing"
    end

    def test_several_pastes_each_keep_their_own_text
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      first = long_text(10)
      second = long_text(20).sub("line 1", "other 1")
      input.handle_key(::TUI::Key.new(:paste, first))
      input.handle_key(::TUI::Key.printable("\n"))
      input.handle_key(::TUI::Key.new(:paste, second))

      assert_equal "#{first}\n#{second}", input.expand(input.value)
    end

    def test_the_submitted_message_carries_the_pasted_text
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      mailbox = repl.instance_variable_get(:@mailbox)
      pasted = long_text(300)

      prompt.handle_key(::TUI::Key.new(:paste, pasted))
      prompt.handle_key(::TUI::Key.printable("!"))
      prompt.handle_key(::TUI::Key.new(:enter))

      assert_equal "#{pasted}!", mailbox.pop, "the model sees the paste, not the token"
      assert_equal "", prompt.value
    end

    def test_history_recall_collapses_a_long_message_again
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      pasted = long_text(400)

      prompt.handle_key(::TUI::Key.new(:paste, pasted))
      prompt.handle_key(::TUI::Key.new(:enter))
      prompt.handle_key(::TUI::Key.new(:up))

      assert_equal 1, prompt.buffer.lines.size, "recall must not put 400 rows back"
      assert_equal pasted, prompt.expand(prompt.value)
    end

    def test_repeated_pastes_do_not_grow_the_store_without_bound
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      (TUI::PromptInput::MAX_PASTES + 4).times do |i|
        input.handle_key(::TUI::Key.new(:paste, long_text(10 + i)))
      end

      assert_operator input.instance_variable_get(:@pastes).size,
                      :<=, TUI::PromptInput::MAX_PASTES
    end

    # --- thinking block ------------------------------------------------

    # The transcript as plain text, one string per log entry.
    def log_texts(repl)
      log = repl.instance_variable_get(:@log)
      log.instance_variable_get(:@entries).map { |segments| segments.map(&:first).join }
    end

    # Pretend the thought has been running for `seconds`.
    def age_thinking(repl, seconds)
      repl.instance_variable_set(:@thinking_started_at, repl.send(:monotonic_now) - seconds)
    end

    def test_the_block_shows_the_state_of_the_wait_and_nothing_of_the_thought
      repl = build_repl

      repl.send(:apply_event, [ :thinking, "Let me look at the repo first." ])
      age_thinking(repl, 1.5)
      repl.send(:refresh_thinking)

      texts = log_texts(repl)
      bar = texts.find { |text| text.include?("Thinking") }
      assert bar, "a thinking row appears with the first fragment"
      refute texts.any? { |text| text.include?("Let me look at the repo first.") },
             "the thought itself never reaches the transcript: #{texts.inspect}"
      refute_includes bar, "·", "a wait under the threshold shows no clock"
    end

    def test_thinking_block_shows_elapsed_time_once_it_has_been_a_while
      repl = build_repl

      repl.send(:apply_event, [ :thinking, "Still going." ])
      age_thinking(repl, 5)
      repl.send(:refresh_thinking)

      bar = log_texts(repl).find { |text| text.include?("Thinking") }
      assert_includes bar, "Thinking… · 5s", "the clock starts past the threshold"
    end

    def test_a_long_thought_collapses_to_one_line_when_the_answer_starts
      repl = build_repl

      repl.send(:apply_event, [ :thinking, "Let me look at the repo first." ])
      age_thinking(repl, 5)
      repl.send(:apply_event, [ :chunk, "Here it is." ])

      texts = log_texts(repl)
      assert texts.any? { |text| text.include?("Thought for 5s") }, "the wait is recorded: #{texts.inspect}"
      refute texts.any? { |text| text.include?("Let me look at the repo first.") },
             "the thought itself is folded away"
      assert texts.any? { |text| text.include?("Here it is.") }, "the answer follows it"
    end

    # Every new fragment rewrites the block. The clock must not blink out of
    # the row while the model is still streaming: fragments arrive faster than
    # the tick that would put it back.
    def test_the_clock_survives_a_new_fragment
      repl = build_repl

      repl.send(:apply_event, [ :thinking, "Counting. " ])
      age_thinking(repl, 6)
      repl.send(:apply_event, [ :thinking, "Still counting." ])

      texts = log_texts(repl)
      bar = texts.find { |text| text.include?("Thinking") }
      assert_includes bar, "· 6s", "the elapsed label is kept across fragments"
      refute texts.any? { |text| text.include?("Still counting.") }, "the fragment itself stays hidden"
      assert_equal 1, texts.count { |text| text.include?("Thinking") }, "still one block, not one per fragment"
    end

    # Some gateways open the stream with an empty `content` chunk *before* the
    # reasoning arrives. That is not the answer, so it must not fold the block
    # away before the thought has been seen.
    def test_an_empty_chunk_does_not_close_the_block
      repl = build_repl

      repl.send(:apply_event, [ :thinking, "Let me count." ])
      age_thinking(repl, 4)
      repl.send(:apply_event, [ :chunk, "" ])
      repl.send(:refresh_thinking)

      bar = log_texts(repl).find { |text| text.include?("Thinking") }
      assert bar, "the block survives an empty fragment"
      assert_includes bar, "· 4s", "and keeps its clock"
      refute log_texts(repl).any? { |text| text.include?("Thought for") },
             "the block is not closed by an empty chunk"
    end

    def test_a_quick_thought_is_removed_without_a_trace
      repl = build_repl

      repl.send(:apply_event, [ :thinking, "Quick." ])
      age_thinking(repl, 1)
      repl.send(:apply_event, [ :chunk, "Hi." ])

      texts = log_texts(repl)
      refute texts.any? { |text| text.include?("Thought for") }, "no footer for a pause nobody felt"
      refute texts.any? { |text| text.include?("Quick.") }, "the block is gone"
      refute texts.each_cons(2).any? { |above, below| above.empty? && below.empty? },
             "the blank the block sat under is reused, not doubled"
    end

    # A dropped block has to take its own spacer with it. The tool row that
    # arrives right after it lands *below* the block, so at close time the
    # block is no longer the last entry: probing for "a blank at the end"
    # would find the one already there and leave the spacer orphaned.
    def test_a_quick_thought_leaves_no_orphan_blank_above_a_tool_call
      repl = build_repl

      repl.send(:apply_event, [ :stream_start ])
      repl.send(:apply_event, [ :chunk, "Let me check." ])
      repl.send(:apply_event, [ :tool_call, "shell_exec", { "command" => "ls" } ])
      repl.send(:apply_event, [ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      repl.send(:apply_event, [ :stream_start ])
      repl.send(:apply_event, [ :thinking, "Quick thought." ])
      age_thinking(repl, 1)
      repl.send(:apply_event, [ :tool_call, "shell_exec", { "command" => "cat x" } ])

      texts = log_texts(repl)
      refute texts.each_cons(2).any? { |above, below| above.empty? && below.empty? },
             "no double blank left behind: #{texts.map { |t| t.empty? ? '·' : t }.inspect}"
      assert_equal texts.index { |text| text.include?("✓ shell_exec ls") } + 1,
                   texts.index { |text| text.include?("⚒ shell_exec cat x") },
                   "back-to-back tool rows stay adjacent"
    end

    # The retained block keeps its spacer: the separator above it is what makes
    # it read as a remark about the turn rather than part of the answer.
    def test_a_kept_block_keeps_the_blank_row_above_it
      repl = build_repl

      repl.send(:apply_event, [ :stream_start ])
      repl.send(:apply_event, [ :chunk, "Let me check." ])
      repl.send(:apply_event, [ :tool_call, "shell_exec", { "command" => "ls" } ])
      repl.send(:apply_event, [ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      repl.send(:apply_event, [ :stream_start ])
      repl.send(:apply_event, [ :thinking, "A long thought." ])
      age_thinking(repl, 6)
      repl.send(:apply_event, [ :tool_call, "shell_exec", { "command" => "cat x" } ])

      texts = log_texts(repl)
      thought = texts.index { |text| text.include?("Thought for 6s") }
      assert thought, "the block is kept: #{texts.inspect}"
      assert_equal "", texts[thought - 1], "with a blank row above it"
    end

    # A kept block is set off on both sides, including between two tool rows:
    # it is a remark on the turn, not a step in the tool chain.
    def test_a_kept_block_between_two_tool_calls_is_set_off_both_sides
      repl = build_repl

      repl.send(:apply_event, [ :stream_start ])
      repl.send(:apply_event, [ :chunk, "Let me check." ])
      repl.send(:apply_event, [ :tool_call, "shell_exec", { "command" => "ls" } ])
      repl.send(:apply_event, [ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      repl.send(:apply_event, [ :stream_start ])
      repl.send(:apply_event, [ :thinking, "A long thought." ])
      age_thinking(repl, 6)
      repl.send(:apply_event, [ :tool_call, "shell_exec", { "command" => "cat x" } ])
      repl.send(:apply_event, [ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      texts = log_texts(repl)
      thought = texts.index { |text| text.include?("Thought for 6s") }
      assert thought, "the block is kept: #{texts.inspect}"
      assert_equal "", texts[thought - 1], "with a blank row above it"
      assert_equal "", texts[thought + 1], "and one below it"
      assert texts[thought + 2].include?("cat x"), "the next tool row follows the blank"
    end

    # A quick thought between two tool rows leaves no seed of a blank: the
    # rows sit adjacent, exactly as if the model had never paused.
    def test_a_quick_block_between_two_tool_calls_leaves_the_rows_adjacent
      repl = build_repl

      repl.send(:apply_event, [ :stream_start ])
      repl.send(:apply_event, [ :chunk, "Let me check." ])
      repl.send(:apply_event, [ :tool_call, "shell_exec", { "command" => "ls" } ])
      repl.send(:apply_event, [ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      repl.send(:apply_event, [ :stream_start ])
      repl.send(:apply_event, [ :thinking, "Quick." ])
      age_thinking(repl, 1)
      repl.send(:apply_event, [ :tool_call, "shell_exec", { "command" => "cat x" } ])
      repl.send(:apply_event, [ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      texts = log_texts(repl)
      refute texts.any? { |text| text.include?("Thought for") }, "no block: #{texts.inspect}"
      first = texts.index { |text| text.include?("shell_exec ls") }
      assert_equal first + 1, texts.index { |text| text.include?("shell_exec cat x") },
                   "the two tool rows are adjacent"
    end

    # The block's own blank row is the separator the footer needs. Adding the
    # footer's blank on top of it would leave two in a row.
    def test_a_kept_block_at_the_end_of_a_turn_does_not_double_the_blank
      repl = build_repl

      repl.send(:apply_event, [ :thinking, "A long thought." ])
      age_thinking(repl, 6)
      repl.send(:apply_event, [ :stream_end, false ])

      texts = log_texts(repl)
      thought = texts.index { |text| text.include?("Thought for 6s") }
      assert thought, "the block is kept: #{texts.inspect}"
      assert_equal "", texts[thought + 1], "one blank under the block"
      assert texts[thought + 2].include?("Turn took"), "then the footer, not another blank"
    end

    def test_a_tool_call_closes_the_thinking_block
      repl = build_repl

      repl.send(:apply_event, [ :thinking, "I need the directory listing." ])
      age_thinking(repl, 4)
      repl.send(:apply_event, [ :tool_call, "shell_exec", { "command" => "ls" } ])

      texts = log_texts(repl)
      assert texts.any? { |text| text.include?("Thought for 4s") }
      refute texts.any? { |text| text.include?("I need the directory listing.") }
    end

    # The transcript records that the model was thinking, never what it was
    # thinking about: no fragment of a long chain of thought may leak into it,
    # however long the stream runs.
    def test_a_long_thought_is_never_echoed_into_the_transcript
      repl = build_repl
      thought = (1..12).map { |i| "step #{i}\n" }.join

      repl.send(:apply_event, [ :thinking, thought ])

      texts = log_texts(repl)
      assert_equal 1, texts.count { |text| text.include?("Thinking") }, "one block for the whole thought"
      refute texts.any? { |text| text.include?("step ") }, "not one row of it is shown"
    end

    # The agent hands reasoning over on its own callback; the worker has to
    # turn it into transcript events, not throw it away.
    def test_process_message_forwards_reasoning_to_the_transcript
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:process) do |_msg, on_reasoning: nil, **_opts, &blk|
        on_reasoning&.call("pondering ")
        on_reasoning&.call("deeply")
        blk&.call("Answer.")
        "Answer."
      end
      agent.define_singleton_method(:flush_learning) { nil }
      agent.define_singleton_method(:usage_report) do
        { requests: 1, prompt_tokens: 10, cache_hit_rate: 0.0,
          context_used: 20, context_window: 128_000, context_percent: 0.1,
          cost: { "total" => 0.0 } }
      end

      repl.send(:process_message, "hi")

      events = repl.instance_variable_get(:@events)
      queued = []
      queued << events.pop until events.empty?
      thought = queued.select { |event| event[0] == :thinking }.map { |event| event[1] }
      assert_equal [ "pondering ", "deeply" ], thought

      queued.each { |event| repl.send(:apply_event, event) }
      texts = log_texts(repl)
      assert texts.any? { |text| text.include?("Answer.") }, "the answer is on screen"
      refute texts.any? { |text| text.include?("pondering") },
             "a thought under the threshold is gone by the time the answer lands"
    end
  end
end
