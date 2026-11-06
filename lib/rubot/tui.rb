# frozen_string_literal: true

require "base64"
require "shellwords"
require "tmpdir"

require_relative "usage"
require_relative "opencode_usage"
require_relative "tui/compat"
require_relative "tui/log_view"
require_relative "tui/markdown"
require_relative "tui/transcript"
require_relative "tui/command_menu"
require_relative "tui/prompt_input"
require_relative "tui/status_line"
require_relative "tui/working_badge"
require_relative "tui/confirm_dialog"
require_relative "tui/session_list"


Rubot::TUI::Compat.apply

# The completed-tool marker is a softened green: the bright ":success"
# green is reserved for explicit confirmations ("✓ Session cleared").
::TUI::Style.define(:tool_ok, fg: 71)

module Rubot
  # Terminal channel REPL for rubot, built on ruby-tui
  # (https://github.com/adiprnm/ruby-tui).
  #
  # Layout (borderless):
  #
  #   scrolled conversation log
  #   prompt box (thin bordered box, no placeholder/hints)
  #   status row (spinner · session/model)
  #
  # Keys: enter send · shift+enter newline · tab completes /commands · ↑↓ history ·
  # typing / opens the command list (↑↓ picks one, enter takes it) · ctrl+g
  # edits the prompt in $EDITOR · page-up/page-down scroll · esc cancels the
  # running turn · ctrl-c quits.
  #
  # Threading: the ruby-tui App owns the main thread. A worker thread feeds
  # submitted lines (messages and /commands) to the agent; streaming chunks,
  # tool events and command output flow back through an events Queue and are
  # applied once per App tick, so component state is only ever touched by the
  # App thread.
  #
  # The class is named TUI, while the gem's own top-level module is written
  # `::TUI` everywhere so Ruby's lexical lookup stays unambiguous.
  class TUI
    HISTORY_FILE = File.expand_path("~/.rubot/history")

    COMMANDS = {
      "/help"     => "Show this help message",
      "/new"      => "Clear conversation and start a new session",
      "/stop"     => "Stop the task that is running",
      "/compact"  => "Summarize older messages to free context",
      "/clear"    => "Clear conversation history",
      "/session"  => "Show current session ID",
      "/session NAME" => "Switch to a new session",
      "/resume"   => "Pick a saved session to resume",
      "/resume N|NAME" => "Resume a saved session",
      "/info"     => "Show agent info (provider, model, tools)",
      "/context"  => "Show context usage, cache hit rate, and estimated cost",
      "/usage"    => "Show OpenCode Go subscription usage",
      "/models"   => "List available models from config",
      "/model"    => "Show current active model",
      "/use-model NAME" => "Switch to a model for this session",
      "/tools"    => "List available tools",
      "/soul"     => "Show the bot's soul (SOUL.md)",
      "/memory"   => "Show persistent memory (MEMORY.md)",
      "/agents"   => "Show agent rules (AGENTS.md)",
      "/cron"     => "List scheduled cron jobs",
      "/stream on|off" => "Toggle streaming output",
      "/use SKILL" => "Force a specific skill for the next message",
      "/unuse"    => "Clear the forced skill",
      "/quit"     => "Exit rubot"
    }.freeze

    # Command names offered by tab completion and the slash-command
    # palette. The parameterized variants read better in /help, but their
    # base name is what gets listed and completed (/stream, /use-model, …).
    COMPLETABLE = COMMANDS.keys.map { |syntax| syntax.split.first }.uniq.freeze

    # One description per completion target, so the palette can put it next
    # to the command name. The first syntax that mentions a name wins.
    DESCRIPTIONS = COMMANDS.each_with_object({}) do |(syntax, desc), out|
      out[syntax.split.first] ||= desc
    end.freeze

    # Key bindings listed by /help. Only the discoverable ones: typing and
    # the arrows need no explanation, the rest do.
    KEYS = {
      "enter"       => "Send the prompt, or take the highlighted /command",
      "shift+enter" => "Insert a newline (the box grows)",
      "ctrl+g"      => "Edit the prompt in $EDITOR, then take it back",
      "tab"         => "Complete a /command",
      "↑ / ↓"       => "Pick a /command, move between lines, or browse history",
      "esc"         => "Cancel the running turn, clear a selection, dismiss the list",
      "pgup/pgdn"   => "Scroll the conversation",
      "ctrl-c"      => "Quit rubot"
    }.freeze

    SPIN = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    MARK = { ok: "✓", warn: "!", err: "✗", info: "·", tool: "⚒", skill: "✦", cron: "⏰", note: "◆" }.freeze
    TURN_MARK = "✻"

    # Skills are loaded by reading their SKILL.md through the file tool (see
    # SkillRegistry#to_system_prompt). The TUI spots that path so a skill load
    # gets its own transcript row instead of hiding inside a file_ops row.
    SKILL_PATH = %r{/skills/([^/\s]+)/SKILL\.md}

    # Shell commands that only dump a file's contents count as reading.
    READ_COMMANDS = /\b(cat|bat|less|more|head|tail)\b/

    def initialize(agent = nil, stream: true, pool: nil, on_cron: nil)
      @agent = agent
      @pool = pool
      @session_id = "default"
      @stream = stream
      @on_cron = on_cron
      @logo = "🤖"
      @history = load_history
      @busy = false
      @stopping = false
      @live_entry = nil
      @live_text = +""
      @banner_count = 0
      @turn_started_at = nil
      @turn_total_seconds = 0.0
      @turn_count = 0
      @command_output = nil

      # Queues bridging worker/agent threads into the App thread. Component
      # state is only ever mutated on the App thread (pump + key handlers).
      @events = Queue.new    # worker & channel threads -> UI
      @confirm = Queue.new   # confirm dialog -> worker
      @mailbox = Queue.new   # submitted lines -> worker

      @worker = nil
      @app = nil
      @tui = false
      # Resolved on the worker thread (agent.config may cross a Ractor
      # boundary), then only read from the App thread.
      @external_editor = nil
    end

    # Current session handle: a legacy in-process Agent or a Ractor-backed
    # SessionHandle.
    def agent
      @pool ? @pool.for(@session_id) : @agent
    end

    # Switch the active session. In actor mode this points the REPL at
    # another session handle (one actor per session).
    def switch_session(name)
      @session_id = name.to_s
      if @pool
        agent
      else
        @agent.switch_session(name)
      end
    end

    # Background cron occurrences, delivered from the channel. Safe from any
    # thread: it only publishes an event.
    def deliver_cron(text)
      @events << [ :entry, [ [ MARK[:cron] + " ", :warning ], [ text.to_s, :text ] ] ]
    end

    # Request a stop from any thread (signal traps, channel lifecycle).
    def stop
      @stopped = true
      @app&.quit
    end

    def run
      # Every launch starts a new conversation. The session file is only
      # written once it has a message, so an untouched launch leaves nothing
      # behind; previous conversations keep their own ids and stay resumable.
      start_fresh_session
      if $stdout.tty? && $stdin.tty?
        run_tui
      else
        run_plain
      end
    ensure
      stop_worker
    end

    private

    # ------------------------------------------------------------------
    # TUI mode
    # ------------------------------------------------------------------

    def run_tui
      require "tui"
      build_ui
      spawn_worker
      @mailbox << :sync
      paint_banner

      # Wheel scrolling (mouse) and the kitty keyboard protocol (distinct
      # shift/alt+enter) are pushed by Compat.patch_session!, inside the
      # alternate screen, and restored on the way out.
      @app.run

      @mailbox << :stop
      @worker.join(2) if @worker
      puts "\n👋 Goodbye!"
    end

    def start_fresh_session
      switch_session(Rubot::Session.fresh_id(session_workspace))
    end

    def session_workspace
      @pool ? @pool.workspace : agent.config.workspace
    rescue StandardError
      nil
    end

    def build_ui
      @tui = true
      @log = Rubot::TUI::LogView.new
      @status = Rubot::TUI::StatusLine.new
      @menu = Rubot::TUI::CommandMenu.new(DESCRIPTIONS)
      @prompt = Rubot::TUI::PromptInput.new(@history, COMPLETABLE)
      @dialog = Rubot::TUI::ConfirmDialog.new
      @working = Rubot::TUI::WorkingBadge.new
      @session_list = Rubot::TUI::SessionList.new(
        log: @log,
        on_select: lambda do |entry|
          @prompt.list = nil
          @mailbox << "/resume #{entry[:id]}"
        end,
        on_cancel: -> { @prompt.list = nil }
      )
      @tool_entries = {}

      # The prompt box grows with newlines (shift+enter) and wraps long
      # lines. One column of padding on each side keeps the typed text off
      # the frame. The working badge reserves a 3-row band above it (text
      # with one blank row of padding above and below), so the layout never
      # jumps.
      @prompt_box = ::TUI::Layout::Box.new(title_style: :hint)
      @prompt_box.add(::TUI::Layout::Padding.new(@prompt, left: 1, right: 1))

      # The window gutter plus the log's own one-column inset put every
      # conversation row exactly two characters in.
      stack = ::TUI::Layout::Stack.new(direction: :vertical)
      stack.add(::TUI::Layout::Padding.new(@log, left: 1), size: ::TUI.flex(1))
      stack.add(@working, size: ::TUI.fixed(3))
      stack.add(@menu, size: ::TUI.auto)         # slash-command palette
      stack.add(@prompt_box, size: ::TUI.auto)   # grows with multiline input
      stack.add(@status, size: ::TUI.fixed(1))

      @overlay = ::TUI::Layout::Overlay.new(::TUI::Layout::Padding.new(stack, left: 1))
      @overlay.add(@dialog)
      @app = ::TUI::App.new(@overlay)

      wire_bindings
    end

    def wire_bindings
      @app.on_key(:page_up) { @log.scroll_by(-10) }
      @app.on_key(:page_down) { @log.scroll_by(10) }
      @app.on_key(:wheel_up) { @log.scroll_by(-3) }
      @app.on_key(:wheel_down) { @log.scroll_by(3) }

      # Drag with the left button to select; on release the text is copied
      # through OSC 52 (terminal clipboard).
      @app.on_key(:mouse_press) do |key|
        next unless key.mouse_button.zero?

        @log.begin_selection(key.mouse_x, key.mouse_y)
      end
      @app.on_key(:mouse_drag) do |key|
        next unless key.mouse_button.zero?

        @log.extend_selection(key.mouse_x, key.mouse_y)
      end
      @app.on_key(:mouse_release) do |key|
        next unless key.mouse_button.zero?

        copy_selection
      end
      @app.on_key(:ctrl_c) { @app.quit }
      # Hand the prompt to $EDITOR and take the result back into the input.
      @app.on_key(:ctrl_g) { edit_prompt }
      @app.on_key(:escape) do
        @log.clear_selection
        cancel_turn
      end

      # Typing, scrolling and new output all move the rows out from under a
      # highlight that was left on screen after a copy.
      @prompt.on(:change) { @log.clear_selection }
      # The prompt owns the palette keys; it only reports what should be on
      # screen. See PromptInput#handle_key.
      @prompt.on(:menu) { |items, index| @menu.set_items(items, index) }

      @prompt.on(:submit) do |text|
        line = text.strip
        @prompt.value = ""
        next if line.empty?

        record_history(line)
        # Echo the prompt on screen, ahead of the assistant entry that
        # arrives with :stream_start.
        publish [ [ "❯ ", :accent ], [ line, :text ] ]
        @mailbox << line
      end

      @app.every(0.1) do
        pump
        @working.tick(@busy ? (@stopping ? :cancel : :work) : nil)
      end
    end

    # ------------------------------------------------------------------
    # Worker thread: everything blocking runs here
    # ------------------------------------------------------------------

    def spawn_worker
      @worker = Thread.new do
        loop do
          item = @mailbox.pop
          break if item == :stop

          case item
          when :sync then push_status_info
          when String
            item.start_with?("/") ? handle_command(item) : process_message(item)
          end
        end
      rescue StandardError => e
        @events << [ :error_text, "worker crashed: #{e.class}: #{e.message}" ]
        retry
      end
    end

    def stop_worker
      return unless @worker

      @mailbox << :stop
      @worker.join(2)
      @worker = nil
    end

    def push_status_info
      # Read here, not on the App thread: agent.config is a Ractor view in
      # actor mode, and the App thread must never block on a request.
      @external_editor = configured_editor
      info = agent.startup_info
      @events << [ :status_right,
                  "session #{agent.session.id} · #{info[:provider]} · #{info[:model]}" ]
    rescue StandardError => e
      @events << [ :error_text, "#{e.class}: #{e.message}" ]
    end

    # Compact cost / cache / context summary for the status row. Called from
    # the worker thread: agent.usage_report may cross a Ractor boundary (and
    # warm the pricing catalog), so it never runs on the App thread.
    def usage_footer
      Rubot::UsageReport.footer(agent.usage_report)
    rescue StandardError
      ""
    end

    # Publish fresh footer metrics from the worker thread. Not called on
    # startup: a fresh session has nothing to price, and usage_report would
    # warm the pricing catalog (a possible network fetch) for nothing.
    def refresh_usage
      @events << [ :status_left, usage_footer ]
    end

    # ------------------------------------------------------------------
    # Event pump (runs on the App thread, once per tick)
    # ------------------------------------------------------------------

    def pump
      loop do
        event = begin
          @events.pop(true)
        rescue ThreadError
          break
        end

        apply_event(event)
      end
    end

    def apply_event(event)
      case event[0]
      when :entry then @log.add_entry(event[1])
      when :command_output then add_command_output(event[1])
      when :clear_log
        clear_log_keep_banner
      when :replay_transcript then replay_transcript(event[1])
      when :error_text then @log.add_entry([ [ MARK[:err] + " ", :error ], [ event[1].to_s, :error ] ])
      when :status_right then @status.right = event[1]
      when :status_left then @status.left = event[1]
      when :stream_start
        @turn_started_at = monotonic_now
        # One blank line between the echoed prompt and the answer.
        @log.add_entry([ [ "", nil ] ])
        start_live_entry
      when :chunk then append_live(event[1])
      # Clearance also resets any tool-line bookkeeping.
      when :stream_end
        # A stop before the first token leaves an empty live entry behind; drop
        # it so the cancelled turn does not leave a blank row of its own.
        if event[1] && @live_entry && @live_text.to_s.strip.empty?
          @log.remove_last
        end
        @live_entry = nil
        if event[1]
          # A cancelled turn gets no footer: the partial answer is the whole
          # record. Keep one blank after it as the separator the next prompt
          # needs, but not the extra one the footer line would have sat above.
          @log.add_entry([ [ "", nil ] ]) unless @log.last_blank?
        else
          @log.add_entry([ [ "", nil ] ])
          add_turn_summary
        end
      when :reset_turn_totals then reset_turn_totals
      when :assistant_text
        @log.add_entry([ [ MARK[:note] + " ", :muted ] ] + Markdown.to_segments(event[1]), keep_leading: true, indent: 2)
      when :tool_call
        # The answer never continues inside the entry that preceded the
        # tool. A phantom continuation live entry (start of the turn's next
        # call) is dropped outright rather than leaving stray blanks, so
        # back-to-back tool rows sit adjacent.
        if @live_entry
          if @live_text.strip.empty?
            @log.remove_last
            @log.remove_last if @log.last_blank?
          elsif !@log.last_blank?
            @log.add_entry([ [ "", nil ] ])
          end
          @live_entry = nil
        end
        skill = skill_load(event[1], event[2])
        summary = if skill
          ::TUI::Text.truncate(skill, tool_summary_limit("skill"))
        else
          tool_summary(event[1], event[2], max: tool_summary_limit(event[1]))
        end
        index = @log.add_entry(tool_call_segments(event[1], summary, skill), keep_leading: true, indent: 2)
        @tool_entries[event[1].to_s] = [ index, summary, skill ]
      when :tool_done
        # The ⚒ line flips to ✓ in place — one line per tool call.
        prev = @tool_entries.delete(event[1].to_s)
        set_tool_done(prev ? prev[0] : @log.add_entry([ [ "✓ ", :tool_ok ], [ event[1].to_s, :muted ] ], indent: 2),
                      event[1].to_s,
                      prev && prev[1],
                      prev && prev[2])
      when :confirm then show_confirm(event)
      when :session_list then show_session_list(event[1])
      when :idle then
        @busy = false
        @stopping = false
      end
    end

    # The row for a tool call in flight. A skill load is not shown as
    # `file_ops read …/SKILL.md` but as its own line, so the transcript says
    # plainly that the agent picked a skill up — the same way a tool call shows.
    def tool_call_segments(name, summary, skill)
      Rubot::TUI::Transcript.tool_call(name, summary, skill)
    end

    def set_tool_done(index, name, summary, skill = nil)
      @log.set_entry(index, Rubot::TUI::Transcript.tool_done(name, summary, skill))
    end

    # Returns the skill name when this tool call reads a skill's SKILL.md,
    # nil otherwise. Only reads count: writing a skill file is not loading it.
    def skill_load(tool_name, args)
      Rubot::TUI::Transcript.skill_load(tool_name, args)
    end

    def start_live_entry
      @busy = true
      @stopping = false
      @live_text = +""
      @live_entry = @log.add_entry([ [ "", :text ] ], keep_leading: true, indent: 2)
    end

    def append_live(chunk)
      if @live_entry.nil?
        # Continuation after tool output starts a fresh spaced answer.
        @log.add_entry([ [ "", nil ] ]) unless @log.last_blank?
        start_live_entry
      end

      @live_text << chunk.to_s
      @log.set_entry(@live_entry, Markdown.to_segments(@live_text), keep_leading: true, indent: 2)
    end

    # Footer after a turn: how long the model took, plus the running total
    # for this session. Called once per :stream_end, on the App thread.
    def add_turn_summary
      duration = @turn_started_at ? [ monotonic_now - @turn_started_at, 0 ].max : 0.0
      @turn_started_at = nil
      @turn_total_seconds += duration
      @turn_count += 1

      turns = @turn_count == 1 ? "turn" : "turns"
      text = "Turn took #{format_duration(duration)} " \
             "(Total time #{format_duration(@turn_total_seconds)} · #{@turn_count} #{turns})"
      @log.add_entry([ [ "#{TURN_MARK} ", :muted ], [ text, :dim ] ])
      @log.add_entry([ [ "", nil ] ])
    end

    def reset_turn_totals
      @turn_started_at = nil
      @turn_total_seconds = 0.0
      @turn_count = 0
    end

    def format_duration(seconds)
      total = seconds.to_i
      hours, rest = total.divmod(3600)
      minutes, secs = rest.divmod(60)

      parts = []
      parts << "#{hours}h" if hours.positive?
      parts << "#{minutes}m" if minutes.positive? || hours.positive?
      parts << "#{secs}s" if secs.positive? || parts.empty?
      parts.join(" ")
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # ------------------------------------------------------------------
    # Turn processing (worker thread)
    # ------------------------------------------------------------------

    def process_message(message)
      on_confirm = @tui ? confirm_callback : stdin_confirm_callback

      @events << [ :stream_start ]
      response = +""
      stopped = false
      agent.process(message,
                    on_confirm: on_confirm,
                    on_tool_call: ->(name, args) { @events << [ :tool_call, name, args ] },
                    on_tool_result: ->(name, _result) { @events << [ :tool_done, name ] },
                    on_stopped: -> { stopped = true },
                    stream: @stream) do |chunk|
        @events << [ :chunk, chunk.to_s ]
        response << chunk.to_s
      end
      # The answer is on screen, so learning may safely run now.
      agent.flush_learning
    rescue Interrupt
      agent&.cancel! if agent.respond_to?(:cancel!)
      @events << [ :error_text, "⏹️ cancelled" ]
    rescue StandardError => e
      @events << [ :error_text, "#{e.class}: #{e.message}" ]
    ensure
      @events << [ :stream_end, stopped ]
      @events << [ :idle ]
      # Fresh cost, cache and context figures for the footer under the input.
      # Published after :idle so the working badge does not linger while the
      # pricing catalog is read.
      refresh_usage
    end

    # Allow a dangerous tool, blocking the worker until the dialog is
    # answered. Fail closed (deny) if the channel dies mid-dialog.
    def confirm_callback
      proc { |_tool_name, _args| @confirm.pop }
    end

    def stdin_confirm_callback
      proc do |tool_name, args|
        description = "#{tool_name} #{tool_summary(tool_name, args)}".strip
        print "\n⚠️  Dangerous action (could cause data loss): #{description}\nConfirm? [y/N] "
        $stdout.flush
        answer = $stdin.gets&.strip&.downcase
        answer == "y" || answer == "yes"
      end
    end

    # Send a selection to the terminal clipboard (OSC 52) and leave the
    # highlight on screen, the way a terminal keeps its selection after the
    # mouse is released; it is dropped by the next keystroke, scroll or
    # batch of new output.
    def copy_selection
      # A click (press and release without a drag) dismisses the highlight
      # instead of overwriting the clipboard with a single cell.
      if @log.point_selection?
        @log.clear_selection
        return @app.render
      end

      text = @log.selection_text
      return @app.render if text.nil? || text.empty?

      ::TUI::Term.write($stdout, "\e]52;c;#{Base64.strict_encode64(text)}\a")
      ::TUI::Term.flush($stdout)
      @app.render
    rescue StandardError => e
      # Never let a copy attempt take the TUI down, but do not swallow the
      # reason either: on a broken clipboard path this is the only clue.
      publish [ [ "copy failed: #{e.class}: #{e.message}", :muted ] ]
    end

    # One-line argument preview shown next to a tool call in the log. It is
    # cut to `max` cells so the row never wraps: the call marker, the tool
    # name and the separator are reserved by the caller.
    def tool_summary(tool_name, args, max: 64)
      Rubot::TUI::Transcript.tool_summary(tool_name, args, max: max)
    end

    # Cells left for the argument preview after " ⚒ ", the tool name and
    # the separating space, keeping one cell clear of the scrollbar.
    def tool_summary_limit(tool_name)
      Rubot::TUI::Transcript.summary_limit(tool_name, @log.content_width)
    end

    def show_confirm(event)
      _, tool_name, args, answered = event
      @dialog.show(tool_name, args)
      @dialog.on_answer do |value|
        @overlay.hide
        answered << value
        @app.focus(@prompt)
      end
      @overlay.show(@dialog)
      @app.focus(@dialog)
    end

    # /resume writes the list into the transcript and hands the prompt over
    # to it; picking an entry feeds a /resume <id> command back into the
    # worker, so the switch itself stays on the worker thread.
    def show_session_list(entries)
      @prompt.list = @session_list if @session_list.open(entries)
    end

    # One blank line above and below, two cells of left padding.
    def add_command_output(lines)
      return if lines.nil? || lines.empty?

      @log.add_entry([ [ "", nil ] ]) unless @log.last_blank?
      lines.each { |segments| @log.add_entry(segments, indent: 2) }
      @log.add_entry([ [ "", nil ] ])
    end

    def clear_log_keep_banner
      @log.clear(keep: @banner_count)
      @live_entry = nil
      @tool_entries.clear
      reset_turn_totals
      @status.left = ""
    end

    # Restore a resumed conversation exactly as it looked while it was live:
    # prompt echoes, streamed answers (Markdown), and finished tool rows.
    def replay_transcript(messages)
      clear_log_keep_banner
      Rubot::TUI::Transcript.entries(messages, width: @log.content_width).each do |entry|
        @log.add_entry(entry[:segments], keep_leading: entry[:keep_leading], indent: entry[:indent])
      end
    end

    # ------------------------------------------------------------------
    # External editor (ctrl+g)
    # ------------------------------------------------------------------

    # Edit the prompt in the configured editor and take back what it wrote.
    # The draft starts as the current buffer, so ctrl+g on a half-typed
    # message continues where the input box left off. An editor that writes
    # nothing back (or cannot start) leaves the prompt exactly as it was,
    # and nothing is lost either way: the draft is the same text.
    def edit_prompt
      path = draft_path
      File.write(path, @prompt.value.to_s)
      run_editor(path)
      # Editors end the file with a newline; in the prompt box that would be
      # a blank last line, not part of the message.
      @prompt.value = File.read(path).gsub("\r\n", "\n").sub(/\n+\z/, "")
      @app.focus(@prompt)
    rescue StandardError => e
      publish [ [ MARK[:err] + " ", :error ], [ "editor: #{e.class}: #{e.message}", :error ] ]
    ensure
      # The alternate screen came back blank, so the diff cache is stale.
      @app&.invalidate!
      begin
        File.delete(path) if path && File.exist?(path)
      rescue StandardError
        nil
      end
    end

    # The editor owns the terminal while it runs: the alternate screen, raw
    # input, mouse tracking and the keyboard protocol all step aside and
    # come back afterwards. The command runs through the shell so an editor
    # entry like "code -w" or "omarchy-launch-editor --inline" works.
    def run_editor(path)
      Compat.hand_over($stdout) { system("#{editor_command} #{Shellwords.escape(path)}") }
    end

    # Config `external_editor`, then $VISUAL, $EDITOR, then vi.
    def editor_command
      [ @external_editor, ENV["VISUAL"], ENV["EDITOR"], "vi" ]
        .map { |candidate| candidate.to_s.strip }
        .find { |candidate| !candidate.empty? }
    end

    # Worker thread only: agent.config may be a Ractor view.
    def configured_editor
      agent.config.external_editor
    rescue StandardError
      nil
    end

    # One draft at a time per process; the `.md` suffix gives the editor
    # markdown highlighting, which is what the prompt is written in.
    def draft_path
      File.join(Dir.tmpdir, "rubot-prompt-#{Process.pid}.md")
    end

    def cancel_turn
      return unless @busy
      return if @stopping

      @stopping = true
      agent&.cancel! if agent.respond_to?(:cancel!)
    rescue StandardError
      nil
    end

    # ------------------------------------------------------------------
    # Plain (non-tty) fallback: pipes, CI, docker logs
    # ------------------------------------------------------------------

    def run_plain
      print_banner_text
      loop do
        print "#{@logo} You: "
        input = $stdin.gets&.strip
        break if input.nil?
        next if input.empty?

        record_history(input)
        input.start_with?("/") ? handle_command(input) : process_message_plain(input)
      end
    rescue Interrupt
      puts
    end

    def process_message_plain(message)
      response = agent.process(message, on_confirm: stdin_confirm_callback, stream: @stream) do |chunk|
        print chunk
        $stdout.flush
      end
      puts "\n"
      agent.flush_learning
    rescue Interrupt
      agent&.cancel! if agent.respond_to?(:cancel!)
      puts "\n⏹️ Cancelled.\n"
    rescue StandardError => e
      puts "\n❌ Error: #{e.message}\n"
    end

    def print_banner_text
      info = agent.startup_info
      puts Rubot::NAME
      puts "Provider: #{info[:provider]} · Model: #{info[:model]} · Tools: #{info[:tools]} loaded"
      puts "Type /help for commands, /quit to exit."
      puts
    rescue StandardError
      nil
    end

    # ------------------------------------------------------------------
    # Commands (both modes emit through #say/#say_text)
    # ------------------------------------------------------------------

    def handle_command(input)
      @command_output = []
      parts = input.split
      cmd = parts.first.downcase

      case cmd
      when "/help"
        blank
        say("Available commands:", :info)
        COMMANDS.each do |syntax, desc|
          say_text(format("  %-20s %s", syntax, desc))
        end
        blank
        say("Keys:", :info)
        KEYS.each do |keys, desc|
          say_text(format("  %-20s %s", keys, desc))
        end
        blank
      when "/clear"
        agent.clear_session
        @events << [ :reset_turn_totals ]
        say("Session cleared.", :ok)
        @events << [ :status_left, "" ]
      when "/new"
        # Silent restart: wipe the screen and start a fresh session.
        agent.clear_session
        @events << [ :clear_log ]
        refresh_status
      when "/stop"
        agent.cancel!
        say("Stop requested.", :ok)
      when "/compact"
        result = agent.compact_session
        if result
          say("Compaction complete.", :ok)
          say_text("Summarized: #{result[:summarized_messages]} messages")
          say_text("Kept:       #{result[:kept_messages]} messages")
          say_text("Context:    ~#{result[:context_before]} → ~#{result[:context_after]} tokens (estimated)")
        else
          say("Nothing to compact yet (conversation is short or summarization failed).", :info)
        end
        refresh_usage
      when "/session"
        if parts[1]
          switch_session(parts[1])
          say("Session switched to: #{parts[1]}", :ok)
          refresh_status
          refresh_usage
        else
          say("Current session: #{agent.session.id}", :info)
          say_text("Model: #{agent.active_model_name}")
          say_text("Type /resume to browse saved sessions.")
        end
      when "/resume"
        handle_resume(parts[1])
      when "/info"
        say("Agent info:", :info)
        agent.startup_info.each { |k, v| say_text("#{k}: #{v}") }
      when "/context"
        blank
        say_text(Rubot::UsageReport.render(agent.usage_report))
        blank
      when "/usage"
        blank
        say_text(Rubot::OpencodeUsageReport.render(agent.opencode_usage))
        blank
      when "/models"
        models = agent.config.models
        if models.empty?
          say("No models configured in config.yml.", :warn)
        else
          active = agent.active_model_name
          say("Available models:", :info)
          models.each do |m|
            marker = m["name"] == active ? MARK[:ok] : " "
            say_text("  #{marker} #{m["name"]} (#{m["model"]})")
          end
        end
      when "/model"
        active = agent.active_model_name
        entry = agent.config.model_entry_by_name(active) || agent.config.active_model_entry
        say("Current model: #{active} (#{entry["model"]})", :info)
        say("Session override — cleared on /new.", :warn) if agent.session.model_override
      when "/use-model"
        handle_use_model(parts[1])
      when "/tools"
        say("Available tools:", :info)
        agent.tools.all.each do |tool|
          say_text("  - #{tool.name}: #{tool.description.lines.first.strip}")
        end
      when "/soul"
        if agent.soul.enabled?
          say("Soul (SOUL.md):", :info)
          say_text(agent.soul.read, :text)
        else
          say("No soul file (SOUL.md) found in workspace.", :warn)
        end
      when "/memory"
        if agent.memory.enabled?
          say("Memory (MEMORY.md):", :info)
          say_text(agent.memory.read, :text)
        else
          say("Memory not available (no workspace configured).", :warn)
        end
      when "/agents"
        if agent.agents_file.enabled?
          say("Agent rules (AGENTS.md):", :info)
          say_text(agent.agents_file.raw, :text)
        else
          say("No AGENTS.md found in workspace.", :warn)
        end
      when "/cron"
        cron_tool = agent.tools.get("cron")
        if cron_tool
          say_text(cron_tool.execute({ "operation" => "list" }).to_s, :text)
        else
          say("Cron tool not available.", :warn)
        end
      when "/stream"
        @stream = parts[1].downcase == "on" if parts[1]
        say("Streaming #{@stream ? "on" : "off"}.", :info)
      when "/use"
        handle_use_skill(parts[1])
      when "/unuse"
        if agent.session.forced_skill
          agent.session.forced_skill = nil
          agent.session.save! if agent.session.respond_to?(:save!)
          say("Forced skill cleared.", :ok)
        else
          say("No forced skill is set.", :info)
        end
      when "/quit", "/exit"
        @app ? @app.quit : exit
      else
        say("Unknown command: #{cmd}.", :err)
        say_text("Type /help for available commands.")
      end
    rescue StandardError => e
      say("#{e.class}: #{e.message}", :err)
      raise if Rubot.debug?
    ensure
      flush_command_output
    end

    def handle_resume(query)
      sessions = Rubot::Session.index(agent.config.workspace)

      if query.nil? || query.strip.empty?
        # Interactively, /resume writes the list into the log; only a plain (piped) REPL
        # has to print the list and take the number on the next line.
        if @tui && !sessions.empty?
          @events << [ :session_list, sessions ]
        else
          list_sessions(sessions)
        end
        return
      end

      entry = find_session(sessions, query)
      unless entry
        say("Session '#{query}' not found.", :err)
        say_text("Type /resume to see saved sessions.")
        return
      end

      resume_session(entry)
    end

    def list_sessions(sessions)
      if sessions.empty?
        say("No saved sessions yet.", :info)
        say_text("Conversations are saved as they happen; /resume brings one back later.")
        return
      end

      current = agent.session.id
      blank
      say("Saved sessions:", :info)
      sessions.each_with_index do |session, index|
        marker = session[:id] == current ? MARK[:ok] : " "
        say_text(format("  %s %-2d %-28s %4d msgs · %-10s %s",
                        marker, index + 1, session[:id], session[:messages],
                        relative_time(session[:updated_at]), session[:last_prompt]))
      end
      blank
      say_text("Resume one with /resume <number> or /resume <id>.")
    end

    # Only ids that are actually on disk resolve, which also keeps a crafted
    # argument from escaping the sessions directory.
    def find_session(sessions, query)
      text = query.to_s.strip
      return nil if text.empty?
      return sessions[text.to_i - 1] if text.match?(/\A\d+\z/)

      sessions.find { |session| session[:id] == text }
    end

    def resume_session(entry)
      switch_session(entry[:id])
      messages = Rubot::Session.transcript(agent.config.workspace, entry[:id])

      # The App thread owns the log, so the whole restored transcript is
      # handed over as one event and laid out there with the live renderer.
      if @tui
        @events << [ :replay_transcript, messages ]
      else
        print_transcript(messages)
      end

      refresh_status
      refresh_usage
    end

    # Plain (piped) REPL: the same entries, without styles. Routed through
    # #emit so it gets the same padding as any other command output.
    def print_transcript(messages)
      Rubot::TUI::Transcript.entries(messages).each do |entry|
        indent = " " * entry[:indent].to_i
        text = entry[:segments].map { |segment| segment[0].to_s }.join
        text.split("\n", -1).each { |line| emit([ [ "#{indent}#{line}", :text ] ]) }
      end
    end

    def relative_time(iso)
      Rubot::TUI::SessionList.age(iso)
    end

    def handle_use_model(model_name)
      if model_name.nil?
        say("Usage: /use-model <model-name>", :warn)
        agent.config.models.each { |m| say_text("  - #{m["name"]}") }
        return
      end

      result = agent.use_model(model_name)
      if result
        entry = agent.config.model_entry_by_name(result)
        say("Switched to model: #{result} (#{entry["model"]})", :ok)
        say_text("Provider: #{agent.provider.name}")
        say_text("Persists for this session (cleared on /new).")
        refresh_status
        refresh_usage
      else
        say("Model '#{model_name}' not found in config.yml.", :err)
        agent.config.models.each { |m| say_text("  - #{m["name"]}") }
      end
    end

    def handle_use_skill(skill_name)
      skills = agent.skill_registry
      if skill_name.nil?
        say("Usage: /use <skill-name>", :warn)
        say_text("Available skills: #{skills.all.keys.join(', ') || '(none)'}")
        return
      end

      if skills.get(skill_name)&.enabled?
        agent.session.forced_skill = skill_name
        agent.session.save! if agent.session.respond_to?(:save!)
        say("Skill '#{skill_name}' will be used for the next message.", :ok)
      else
        say("Skill '#{skill_name}' not found or not enabled.", :err)
        say_text("Available skills: #{skills.all.keys.join(', ') || '(none)'}")
      end
    end

    # ------------------------------------------------------------------
    # Output — always routed as events; the pump owns every mutation
    # ------------------------------------------------------------------

    def say(text, kind = :info)
      segments = case kind
      when :ok then [ [ MARK[:ok] + " ", :success ], [ text, :text ] ]
      when :warn then [ [ MARK[:warn] + " ", :warning ], [ text, :text ] ]
      when :err then [ [ MARK[:err] + " ", :error ], [ text, :text ] ]
      when :text then [ [ text, :text ] ]
      else [ [ MARK[:info] + " ", :muted ], [ text, :dim ] ]
      end
      emit segments
    end

    def say_text(text, style = :dim)
      text.to_s.each_line(chomp: true) do |line|
        emit [ [ line, style ] ]
      end
    end

    def blank
      emit [ [ "", nil ] ]
    end

    # A command's output is collected first, so the padding above and below it
    # can be applied once, no matter how many say() calls it made.
    def emit(segments)
      if @command_output
        @command_output << segments
      else
        publish segments
      end
    end

    # Give every command output one blank line above and below and two cells
    # of left padding. Commands may print their own blank lines; the edges are
    # trimmed here so the result is always exactly one.
    def flush_command_output
      lines = @command_output
      @command_output = nil
      return if lines.nil? || lines.empty?

      lines.shift while blank_entry?(lines.first)
      lines.pop while blank_entry?(lines.last)
      return if lines.empty?

      if @tui
        @events << [ :command_output, lines ]
      else
        publish [ [ "", nil ] ]
        lines.each do |segments|
          segments.map { |text, _style| text.to_s }.join.split("\n", -1).each do |line|
            publish [ [ "  #{line}", :text ] ]
          end
        end
        publish [ [ "", nil ] ]
      end
    end

    def blank_entry?(segments)
      return false unless segments

      segments.all? { |text, _style| text.to_s.empty? }
    end

    # Output goes to the TUI log when running, else straight to stdout in
    # plain mode (the plain loop never drains @events).
    def publish(segments)
      if @tui
        @events << [ :entry, segments ]
      else
        puts segments.map { |t, _s| t.to_s }.join
      end
      nil
    end

    def refresh_status
      @mailbox << :sync
    end

    # ------------------------------------------------------------------
    # Banner
    # ------------------------------------------------------------------

    def paint_banner
      info = begin
        agent.startup_info
      rescue StandardError
        {}
      end
      provider = info[:provider] || "?"
      model = info[:model] || "starting…"
      tools = info[:tools] ? "#{info[:tools]} tools" : "…"

      @log.add_entry([ [ Rubot::NAME, :title ] ])
      @log.add_entry([ [ "provider #{provider} · model #{model} · #{tools}", :dim ] ])
      @log.add_entry([ [ "type /help for commands · esc cancels a running turn · pgup/pgdn scrolls", :dim ] ])
      @log.add_entry([ [ "", nil ] ])
      @banner_count = @log.entry_count
      @status.right = "session #{@session_id} · #{provider} · #{model}" if info[:provider]
    end

    # ------------------------------------------------------------------
    # History
    # ------------------------------------------------------------------

    def load_history
      return [] unless File.exist?(HISTORY_FILE)

      File.readlines(HISTORY_FILE, chomp: true).reject(&:empty?)
    rescue StandardError
      []
    end

    def record_history(input)
      @history << input
      File.open(HISTORY_FILE, "a") { |f| f.puts(input) }
    rescue StandardError
      # ignore history save errors
    end
  end
end
