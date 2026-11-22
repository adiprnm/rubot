# frozen_string_literal: true

require "stringio"
require "test_helper"
require "rubot"
require_relative "support/tui_support"

module Rubot
  # The TUI as the reader drives it: the prompt, history, the model list and the commands that answer in place.
  class TestTUI < Minitest::Test
    include TuiSupport

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
      repl.push_status_info
      repl.pump

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
      repl.pump

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
      repl.push_status_info
      repl.pump

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

    def test_working_badge_shows_running_subagents
      badge = TUI::WorkingBadge.new
      badge.layout(::TUI::Rect.new(0, 0, 100, 3))
      badge.tick(:work)
      badge.subagent(run_id: "r1", agent: "writer", phase: "started", detail: "write a poem")
      badge.subagent(run_id: "r2", agent: "researcher", phase: "tool", detail: "search docs")

      assert_equal 2, badge.subagent_count
      canvas = ::TUI::Canvas.new(100, 3)
      badge.render(canvas)
      row = plain(canvas.lines)[1]
      assert_includes row, "2 subagent", row.inspect
      assert_includes row, "writer", row.inspect
      assert_includes row, "researcher", row.inspect

      badge.subagent(run_id: "r1", agent: "writer", phase: "done", detail: "3s")
      assert_equal 1, badge.subagent_count
      badge.clear_subagents
      assert_equal 0, badge.subagent_count
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
      repl.pump

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

      repl.process_message("hi")
      repl.pump

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

      repl.process_message("hi")

      assert_equal [ "$0.0040 · cache 90% · ctx 3.9%", "$0.0090 · cache 80% · ctx 7.0%" ], footers
    end

# The TUI is where a long session lives, so it is where a reader is most
# likely to want memory that was just written to reach the model. The
# command says what it did and what it costs.
def test_repin_command_rebuilds_the_prompt_and_says_what_it_costs
  repl = build_repl
  agent = repl.instance_variable_get(:@agent)
  asked = 0
  agent.define_singleton_method(:repin_system_prompt) { asked += 1; true }
  log = repl.instance_variable_get(:@log)

  repl.handle_command("/repin")
  repl.pump

  assert_equal 1, asked, "the command has to ask the agent, not just describe it"
  texts = log.instance_variable_get(:@entries).map { |segments| segments.map(&:first).join }
  assert texts.any? { |text| text.include?("rebuilt on the next message") }
  assert texts.any? { |text| text.include?("pays in full") },
         "the price is part of the answer, not a surprise on the next request"
end

def test_repin_command_reports_nothing_to_rebuild
  repl = build_repl
  agent = repl.instance_variable_get(:@agent)
  agent.define_singleton_method(:repin_system_prompt) { false }
  log = repl.instance_variable_get(:@log)

  repl.handle_command("/repin")
  repl.pump

  texts = log.instance_variable_get(:@entries).map { |segments| segments.map(&:first).join }
  assert texts.any? { |text| text.include?("not pinned") }
end

# A turn that ends with nothing on the screen is the worst failure this
# interface has: no error, no answer, and no way to tell whether anything
# ran. The answer arrives as the return value as well as in chunks, and with
# `/stream off` only the return value exists.
def test_a_turn_without_streaming_still_shows_its_answer
  repl = build_repl
  agent = repl.instance_variable_get(:@agent)
  agent.define_singleton_method(:process) { |_text, **_callbacks, &_block| "Jawaban tanpa stream." }

  repl.process_message("halo")
  repl.pump

  texts = repl.instance_variable_get(:@log).instance_variable_get(:@entries).map { |segments| segments.map(&:first).join }
  assert texts.any? { |text| text.include?("Jawaban tanpa stream.") },
         "the answer has to reach the log even when nothing streamed"
end

# Streaming already drew the answer; the return value must not draw it a
# second time, but the notice appended after the last chunk is news.
def test_the_tail_of_a_turn_is_shown_once
  repl = build_repl
  agent = repl.instance_variable_get(:@agent)
  answer = "Selesai."
  notice = "\n\n⚠️ Turn stopped after 25 rounds"
  agent.define_singleton_method(:process) do |_text, **_callbacks, &block|
    block.call(answer)
    answer + notice
  end

  repl.process_message("halo")
  repl.pump

  log = repl.instance_variable_get(:@log).instance_variable_get(:@entries).map { |segments| segments.map(&:first).join }
  joined = log.join
  assert_equal 1, joined.scan("Selesai.").size, "the streamed answer must not be drawn twice"
  assert_includes joined, "Turn stopped after 25 rounds"
end

# A prompt is written in markdown as often as an answer is — a snippet, a
# list of paths, a diff. Echoing it raw made the one message the reader typed
# the only thing on screen without syntax.
def test_the_prompt_echo_carries_markdown
  repl = build_repl
  plain = repl.prompt_echo("**penting**: lihat `app.rb`")
  styles = plain.map(&:last)

  assert_equal "❯ ", plain.first.first
  assert_includes styles, :md_code, "an inline code span is rendered"
  assert(styles.any? { |s| s.to_s.start_with?("md_bold") }, "bold is rendered")

  fence = repl.prompt_echo("```ruby
puts 1
```")
  assert_includes fence.map(&:last), :md_code_blk, "a fenced block is rendered"
end

    # The prompt still starts at the marker: the markdown is drawn inside the
    # entry, not around it.
    def test_the_prompt_echo_keeps_the_marker_on_the_first_row
      repl = build_repl
      segments = repl.prompt_echo("- satu\n- dua")

      assert_equal [ "❯ ", :accent ], segments.first, "the marker opens the entry"
      text = segments.map(&:first).join
      assert_includes text, "satu"
      assert_includes text, "dua", "both list items are echoed"
    end

    def test_command_output_gets_one_blank_line_above_and_below_and_left_padding
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:clear_session) { nil }
      log = repl.instance_variable_get(:@log)

      repl.handle_command("/clear")
      repl.pump

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

      repl.handle_command("/clear")
      repl.handle_command("/stop")
      repl.pump

      texts = log.instance_variable_get(:@entries).map { |segments| segments.map(&:first).join }
      first = texts.index { |text| text.include?("Session cleared.") }
      second = texts.index { |text| text.include?("Stop requested.") }

      assert_equal first + 2, second, "only the shared blank line sits between them"
    end

    def test_web_restart_command_reports_the_line_the_script_prints
      Dir.mktmpdir do |dir|
        script = File.join(dir, "stub-restart.rb")
        File.write(script, <<~RUBY)
          puts "[web-restart] stopping 1 process: 4242"
          puts "[web-restart] up: pid 4343 on http://127.0.0.1:4567"
        RUBY

        repl = build_repl
        repl.define_singleton_method(:web_restart_command) { [ RbConfig.ruby, script ] }
        repl.handle_command("/web-restart")
        repl.pump

        texts = log_texts(repl)
        assert_includes texts, "#{TUI::MARK[:ok]} Web server restarted."
        assert_includes texts, "[web-restart] up: pid 4343 on http://127.0.0.1:4567"
        refute texts.any? { |text| text.include?("stopping 1 process") },
               "only the last line is quoted, not the whole log"
      end
    end

    def test_web_restart_command_surfaces_a_failed_restart
      Dir.mktmpdir do |dir|
        script = File.join(dir, "stub-restart.rb")
        File.write(script, <<~RUBY)
          warn "[web-restart] ERROR: port 4567 is still in use by another process"
          exit 1
        RUBY

        repl = build_repl
        repl.define_singleton_method(:web_restart_command) { [ RbConfig.ruby, script ] }
        repl.handle_command("/web-restart")
        repl.pump

        texts = log_texts(repl)
        assert_includes texts, "#{TUI::MARK[:err]} Web server restart failed."
        assert(texts.any? { |text| text.include?("still in use by another process") },
               "the reason is quoted: #{texts.inspect}")
      end
    end

    def test_plain_command_output_is_padded_with_blanks_and_two_spaces
      Dir.mktmpdir do |dir|
        repl = build_resume_repl(File.join(dir, "workspace"))
        repl.instance_variable_set(:@tui, false)
        out, _err = capture_io { repl.handle_command("/resume") }

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

        assert_equal %w[mine], repl.resume_entries.map { |entry| entry[:id] }
        assert_equal %w[theirs mine], repl.resume_entries(all: true).map { |entry| entry[:id] },
                     "all ignores the directory but still hides sessions with no origin"
      end
    end

    def test_resume_keeps_other_directories_reachable_by_id
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        other = File.join(dir, "other-project")
        saved_session(workspace, "theirs", "work on another project", cwd: other)

        repl = build_resume_repl(workspace)

        assert_empty repl.resume_entries

        repl.handle_command("/resume all")
        assert_equal %w[theirs], repl.resume_entries(all: true).map { |entry| entry[:id] }

        out, _err = capture_io { repl.handle_command("/resume theirs") }
        refute_includes out, "not found"
      end
    end

    def test_the_plain_list_mentions_conversations_from_other_directories
      Dir.mktmpdir do |dir|
        workspace = File.join(dir, "workspace")
        saved_session(workspace, "theirs", "work on another project", cwd: File.join(dir, "other-project"))

        repl = build_resume_repl(workspace)
        repl.instance_variable_set(:@tui, false)

        out, _err = capture_io { repl.handle_command("/resume") }

        assert_includes out, "1 conversation(s) from other directories · /resume all"
      end
    end

    def test_clear_wipes_the_usage_footer
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:clear_session) { nil }
      ev = repl.instance_variable_get(:@events)
      ev << [ :status_left, "$0.001 · cache 60% · ctx 8.2%" ]
      repl.pump
      assert plain(repl.instance_variable_get(:@app).render_lines).any? { |l| l.include?("$0.001") }

      repl.handle_command("/clear")
      repl.pump

      refute plain(repl.instance_variable_get(:@app).render_lines).any? { |l| l.include?("$0.001") },
             "a cleared session has nothing to price"
    end

    def test_start_fresh_session_switches_to_a_new_id
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      switched = nil
      agent.define_singleton_method(:switch_session) { |name| switched = name }

      repl.start_fresh_session

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

      repl.handle_command("/new")
      repl.pump

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
      repl.pump

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
      repl.pump
      assert_equal base + 1, log.entry_count, "the model thinking must not open blank rows"

      ev << [ :tool_call, "shell_exec", { "command" => "ls" } ]
      repl.pump
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
      repl.pump

      texts = log.instance_variable_get(:@entries).map { |entry| entry.map(&:first).join }
      assert_equal [ "❯ halo", "", "Halo!" ], texts.last(3),
                   "one blank separates the prompt from the answer"
    end

    def test_turn_footer_reports_duration_and_running_totals
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      ev = repl.instance_variable_get(:@events)
      now = repl.monotonic_now

      ev << [ :stream_start ]
      repl.pump
      repl.instance_variable_set(:@turn_started_at, now - 145)
      ev << [ :stream_end ]
      repl.pump

      line = plain(app.render_lines).find { |l| l.include?("Turn took") }
      assert line, "a turn footer is shown"
      assert_includes line, "\u273b Turn took 2m 25s"
      assert_includes line, "(Total time 2m 25s \u00b7 1 turn)"

      ev << [ :stream_start ]
      repl.pump
      repl.instance_variable_set(:@turn_started_at, now - 1755)
      ev << [ :stream_end ]
      repl.pump

      line = plain(app.render_lines).reverse.find { |l| l.include?("Turn took") }
      assert_includes line, "Turn took 29m 15s"
      assert_includes line, "(Total time 31m 40s \u00b7 2 turns)"
    end
  end
end
