# frozen_string_literal: true

require "base64"
require "shellwords"
require "tmpdir"

require_relative "usage"
require_relative "opencode_usage"
require_relative "clipboard_image"
require_relative "tui/compat"
require_relative "tui/log_view"
require_relative "tui/markdown"
require_relative "tui/diff"
require_relative "tui/transcript"
require_relative "tui/command_menu"
require_relative "tui/prompt_input"
require_relative "tui/status_line"
require_relative "tui/workspace_line"
require_relative "tui/working_badge"
require_relative "tui/confirm_prompt"
require_relative "tui/session_list"
require_relative "tui/model_list"


Rubot::TUI::Compat.apply

# The TUI borrows the everforest palette omarchy ships, so the chrome, the
# markdown text and the diffs sit on the same colours as the terminal.
::TUI::Theme.install(:everforest)

# The completed-tool marker is a softened green: the bright ":success"
# green is reserved for explicit confirmations ("✓ Session cleared").
::TUI::Style.define(:tool_ok, fg: ::TUI::Theme::EVERFOREST_PALETTE[:good])

module Rubot
  # Terminal channel REPL for rubot, built on ruby-tui
  # (https://github.com/adiprnm/ruby-tui).
  #
  # Layout (borderless):
  #
  #   scrolled conversation log
  #   prompt box (thin bordered box, no placeholder/hints)
  #   workspace row (launch directory · git branch)
  #   status row (usage metrics · model)
  #
  # Keys: enter send (steer the running turn if one is in flight) ·
  # shift+enter newline · tab completes /commands · ↑↓ history ·
  # ctrl+←/→ jumps between words ·
  # typing / opens the command list (↑↓ picks one, enter takes it) · ctrl+g
  # edits the prompt in $EDITOR · page-up/page-down scroll · esc cancels the
  # running turn · ctrl-c quits.
  #
  # Threading: the ruby-tui App owns the main thread. A worker thread feeds
  # submitted messages to the agent, and a second lane runs /commands so one
  # typed during a turn is answered next to it instead of after it; streaming
  # chunks, tool events and command output flow back through an events Queue
  # and are applied once per App tick, so component state is only ever touched
  # by the App thread.
  #
  # The class is named TUI, while the gem's own top-level module is written
  # `::TUI` everywhere so Ruby's lexical lookup stays unambiguous.
  class TUI
    HISTORY_FILE = File.expand_path("~/.rubot/history")

    # Shown in the metrics half of the status row between launch and the first
    # priced report from the worker.
    COST_PLACEHOLDER = "cost — · cache — · ctx —"

    # Words /auto accepts besides a bare flip.
    AUTO_TOGGLE = { "on" => true, "true" => true, "yes" => true, "1" => true,
                    "off" => false, "false" => false, "no" => false, "0" => false }.freeze

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
      "/models"   => "List the models the provider supports",
      "/model"    => "Show current active model",
      "/use-model NAME" => "Switch to a model for this session",
      "/tools"    => "List available tools",
      "/soul"     => "Show the bot's soul (SOUL.md)",
      "/memory"   => "Show persistent memory (MEMORY.md)",
      "/agents"   => "Show agent rules (AGENTS.md)",
      "/cron"     => "List scheduled cron jobs",
      "/auto on|off" => "Auto mode: run non-destructive actions without asking (remembered)",
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
      "enter (running)" => "Steer the turn that is running instead of waiting",
      "shift+enter" => "Insert a newline (the box grows)",
      "ctrl+g"      => "Edit the prompt in $EDITOR, then take it back",
      "tab"         => "Complete a /command",
      "↑ / ↓"       => "Pick a /command, move between lines, or browse history",
      "ctrl+← / →"  => "Move the caret one word left or right",
      "esc"         => "Cancel the running turn, clear a selection, dismiss the list",
      "pgup/pgdn"   => "Scroll the conversation",
      "ctrl-c"      => "Quit rubot"
    }.freeze

    SPIN = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    MARK = { ok: "✓", warn: "!", err: "✗", info: "·", tool: "⚒", skill: "✦", cron: "⏰", note: "◆",
             think: "◌" }.freeze
    TURN_MARK = "✻"

    # Hanging indent for rows after the first of an echoed prompt or steer: the
    # "❯ " and "↳ " markers are two cells wide, so continuation rows (a soft
    # wrap or a typed newline) start where the text of the first row does.
    ECHO_HANG = 2

    # A tool call slower than this shows how long it took. Quick calls stay a
    # single quiet row; the clock is for the call that makes the reader wonder
    # whether it hung.
    SLOW_TOOL_SECONDS = 3.0

    # A thinking block only earns a line in the transcript when the model
    # thought for longer than this. Under the threshold the pause was not
    # worth recording, so the block is dropped without a trace instead of
    # collapsing to "Thought for 1s".
    THINKING_SECONDS = 3.0

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
      @thinking_entry = nil
      @thinking_started_at = nil
      @thinking_shown = nil
      @thinking_blank = false
      @banner_count = 0
      @turn_started_at = nil
      @turn_total_seconds = 0.0
      @turn_count = 0
      @command_output = nil

      # Queues bridging worker/agent threads into the App thread. Component
      # state is only ever mutated on the App thread (pump + key handlers).
      @events = Queue.new    # worker & channel threads -> UI
      @mailbox = Queue.new   # submitted lines -> worker
      # Commands get a lane of their own so one typed during a turn runs now
      # instead of waiting for the answer. See #spawn_command_lane.
      @command_mailbox = Queue.new
      # Commands print through @command_output, so only one runs at a time no
      # matter which lane picked it up.
      @command_lock = Mutex.new

      @worker = nil
      @command_lane = nil
      @app = nil
      @tui = false
      # The report the turn in flight last published, so /context has an
      # answer while the agent is busy.
      @live_report = nil
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
      stop_command_lane
    end

    private

    # ------------------------------------------------------------------
    # TUI mode
    # ------------------------------------------------------------------

    def run_tui
      require "tui"
      build_ui
      spawn_worker
      spawn_command_lane
      @mailbox << :sync
      paint_banner

      # Wheel scrolling (mouse) and the kitty keyboard protocol (distinct
      # shift/alt+enter) are pushed by Compat.patch_session!, inside the
      # alternate screen, and restored on the way out.
      @app.run

      @mailbox << :stop
      stop_command_lane
      @worker.join(2) if @worker
      puts "\n👋 Goodbye!"
    end

    def start_fresh_session
      switch_session(Rubot::Session.fresh_id(dir: sessions_dir))
    end

    # Sessions live in one place for every project (Config#sessions_dir); what
    # separates them is the directory each one was launched from. In actor mode
    # the pool carries both, otherwise they come from the agent's config.
    def sessions_dir
      if @pool
        @pool.sessions_dir
      else
        cfg = @agent && @agent.config
        cfg.respond_to?(:sessions_dir) ? cfg.sessions_dir : Rubot::Session.sessions_dir(cfg&.workspace)
      end
    rescue StandardError
      nil
    end

    def sessions_cwd
      if @pool
        @pool.sessions_cwd
      else
        cfg = @agent && @agent.config
        cfg.respond_to?(:sessions_cwd) ? cfg.sessions_cwd : nil
      end
    rescue StandardError
      nil
    end

    def build_ui
      @tui = true
      @log = Rubot::TUI::LogView.new
      @status = Rubot::TUI::StatusLine.new
      @workspace_line = Rubot::TUI::WorkspaceLine.new
      @workspace_line.workspace = Dir.pwd
      @menu = Rubot::TUI::CommandMenu.new(DESCRIPTIONS)
      @prompt = Rubot::TUI::PromptInput.new(@history, COMPLETABLE)
      @confirm_prompt = Rubot::TUI::ConfirmPrompt.new(log: @log)
      @confirm_prompt.on_answer { |_value| @prompt.list = nil }
      @working = Rubot::TUI::WorkingBadge.new
      @session_list = Rubot::TUI::SessionList.new(
        log: @log,
        on_select: lambda do |entry|
          @prompt.list = nil
          @mailbox << "/resume #{entry[:id]}"
        end,
        on_cancel: -> { @prompt.list = nil }
      )
      @model_list = Rubot::TUI::ModelList.new(
        log: @log,
        on_select: lambda do |entry|
          @prompt.list = nil
          @mailbox << "/use-model #{entry[:id]}"
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
      stack.add(@workspace_line, size: ::TUI.fixed(1))
      stack.add(@status, size: ::TUI.fixed(1))

      @app = ::TUI::App.new(::TUI::Layout::Padding.new(stack, left: 1))

      wire_bindings
    end

    def wire_bindings
      @app.on_key(:page_up) { @log.scroll_by(-10) }
      @app.on_key(:page_down) { @log.scroll_by(10) }
      @app.on_key(:wheel_up) { @log.scroll_by(-3) }
      @app.on_key(:wheel_down) { @log.scroll_by(3) }

      # Drag with the left button to select; on release the text is copied
      # through OSC 52 (terminal clipboard). A press on the scrollbar column
      # grabs the bar instead: from there the drag scrolls the log until the
      # button comes up, wherever the cursor goes.
      @app.on_key(:mouse_press) do |key|
        next unless key.mouse_button.zero?

        # A fresh press always clears a grab, so a release the terminal
        # never delivered cannot leave the log stuck to the cursor.
        @log.end_scrollbar_drag
        if @log.scrollbar_at?(key.mouse_x, key.mouse_y)
          @log.begin_scrollbar_drag(key.mouse_x, key.mouse_y)
        else
          @log.begin_selection(key.mouse_x, key.mouse_y)
        end
      end
      @app.on_key(:mouse_drag) do |key|
        # Checked before the button, so a terminal that reports motion with
        # no button held (mode 1003) cannot drop the grab halfway through.
        if @log.scrollbar_dragging?
          @log.drag_scrollbar(key.mouse_y)
          next
        end
        next unless key.mouse_button.zero?

        @log.extend_selection(key.mouse_x, key.mouse_y)
      end
      @app.on_key(:mouse_release) do |key|
        if @log.scrollbar_dragging?
          @log.end_scrollbar_drag
          next
        end
        next unless key.mouse_button.zero?

        copy_selection
      end
      @app.on_key(:ctrl_c) { @app.quit }
      # Hand the prompt to $EDITOR and take the result back into the input.
      @app.on_key(:ctrl_g) { edit_prompt }
      # A terminal only forwards text, so a screenshot on the clipboard is
      # fetched and saved here before it can reach the prompt.
      @app.on_key(:ctrl_v) { paste_clipboard }
      @app.on_key(:escape) do
        @log.end_scrollbar_drag
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
        # Collapsed pastes go back to their full text here, once: what the
        # model sees is what was pasted, not the token on screen. Image
        # tokens become the file paths, without a sentence around them.
        line = @prompt.expand(@prompt.expand_images(text)).strip
        @prompt.value = ""
        next if line.empty?

        record_history(line)

        # A message typed while a turn is running steers it instead of
        # waiting behind it: the agent hands it to the model between rounds,
        # after the tool calls of the round in flight. A command is not
        # something the model can act on, so it runs on the command lane
        # instead: now, next to the turn, rather than after the answer.
        if @busy && !line.start_with?("/") && steer_running_turn(line)
          @events << [ :steer, line ]
          next
        end

        # Echo the prompt on screen, ahead of the assistant entry that
        # arrives with :stream_start.
        publish prompt_echo(line), keep_leading: true, hang: ECHO_HANG
        # A command typed while a turn is running skips the mailbox: the
        # worker is inside that turn, so anything left there only runs once
        # the answer is done. The lane runs it now.
        if @busy
          @command_mailbox << line
        else
          @mailbox << line
        end
      end

      @app.every(0.1) do
        pump
        refresh_thinking
        refresh_slow_tools
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
            item.start_with?("/") ? run_command(item) : process_message(item)
          end
        end
      rescue StandardError => e
        @events << [ :error_text, "worker crashed: #{e.class}: #{e.message}" ]
        retry
      end
    end

    # Commands run here instead of on the worker: the worker is inside the
    # turn, and a command must not have to wait for it. Everything the lane
    # asks the agent goes through the actor, whose loop is free while a turn
    # runs, so even a write or a network call comes back with the turn still
    # in flight.
    def spawn_command_lane
      @command_lane = Thread.new do
        loop do
          line = @command_mailbox.pop
          break if line == :stop

          run_command(line)
        end
      rescue StandardError => e
        @events << [ :error_text, "command lane crashed: #{e.class}: #{e.message}" ]
        retry
      end
    end

    # One command at a time, whichever lane picked it up: a command collects
    # its output in @command_output and flushes it as one block.
    def run_command(line)
      @command_lock.synchronize { handle_command(line) }
    end

    # A command that changes the session cannot apply mid-turn, so say when it
    # will instead of leaving the prompt silent until the answer arrives.
    def stop_command_lane
      return unless @command_lane

      @command_mailbox << :stop
      @command_lane.join(2)
      @command_lane = nil
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
      @events << [ :status_badge, status_badge_text(info) ]
      @events << [ :status_right, status_right_text(info) ]
      # The metrics row is part of the launch view, not a reward for the first
      # turn: a fresh session has cost $0, no cache yet, and a system prompt
      # already eating some of the window, and saying so is the point.
      @events << [ :status_left, usage_footer ]
    rescue StandardError => e
      @events << [ :error_text, "#{e.class}: #{e.message}" ]
    end

    # Auto mode gets a word on the status row: an agent that stops asking has
    # to say so somewhere the user sees without scrolling back. The badge is
    # published separately from the model text so it can carry the theme's
    # warning colour instead of the row's dim grey.
    def status_badge_text(info)
      info[:auto_approve] ? "AUTO" : ""
    end

    # The footer names the model only. Which provider serves it is launch
    # detail, already covered by the banner; repeating it here spends the
    # row's scarce width on something that never changes mid-session.
    def status_right_text(info)
      info[:model].to_s
    end

    # Compact cost / cache / context summary for the status row. Called from
    # the worker thread: agent.usage_report may cross a Ractor boundary (and
    # warm the pricing catalog), so it never runs on the App thread.
    def usage_footer
      Rubot::UsageReport.footer(agent.usage_report)
    rescue StandardError
      ""
    end

    # Publish fresh footer metrics from the worker thread. Also runs at launch
    # (via #push_status_info) so the row is populated before the first turn.
    def refresh_usage
      @events << [ :status_left, usage_footer ]
    end

    # Live figures the agent pushes while a turn is running: cost, cache hit
    # rate and context share move as soon as each request lands. The report
    # arrives as plain data, so this path never calls back into the agent (in
    # actor mode that call would wait for a Ractor busy with this same turn).
    def live_usage(report)
      return unless report.is_a?(Hash)

      # Kept for /context: asking the agent for a report mid-turn would wait
      # for the turn, and this is the same figure it would hand back.
      @live_report = report
      @events << [ :status_left, Rubot::UsageReport.footer(report) ]
    rescue StandardError => e
      warn "[tui] live usage failed: #{e.class}: #{e.message}" if Rubot.debug?
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
      when :entry
        @log.add_entry(event[1], keep_leading: event[2] ? true : false, hang: event[3] || 0)
      when :steer then add_steer_echo(event[1])
      when :command_output then add_command_output(event[1])
      when :clear_log
        clear_log_keep_banner
      when :replay_transcript then replay_transcript(event[1])
      when :error_text
        close_thinking
        @log.add_entry([ [ MARK[:err] + " ", :error ], [ event[1].to_s, :error ] ])
      when :status_right then @status.right = event[1]
      when :status_badge then @status.badge = event[1]
      when :status_left then @status.left = event[1]
      when :stream_start
        @working.notice = nil
        @turn_started_at = monotonic_now
        # The answer's row (and the blank above it) is created when the first
        # token lands, in #append_live. Reserving it here would leave two
        # blank rows under the prompt for as long as the model thinks, and a
        # turn that opens with a tool call would flash them before the tool
        # row replaced them.
        @busy = true
        @stopping = false
        @live_text = +""
        @live_entry = nil
        # A block from the previous turn cannot survive into this one: it was
        # already closed by :stream_end, this only clears the state.
        @thinking_entry = nil
        @thinking_started_at = nil
        @thinking_shown = nil
        @thinking_blank = false
      when :thinking then append_thinking(event[1])
      when :chunk
        # The answer has started, so the model is done thinking. The block
        # collapses here rather than at the end of the turn: a long answer
        # must not keep a clock running over a thought that already stopped.
        # An empty chunk is not an answer: gateways open the stream with one
        # (`content: ""`) *before* the reasoning starts, and closing on it
        # would fold the block away before a single thought was shown.
        close_thinking unless event[1].to_s.empty?
        append_live(event[1])
      # Clearance also resets any tool-line bookkeeping.
      when :stream_end
        close_thinking
        # The turn is over; the next /context asks the agent for the settled
        # figures instead of rendering this one's last snapshot.
        @live_report = nil
        # A call whose result never arrived (cancelled mid-flight) keeps its
        # row, but stops being clocked: the turn is over, so the counter would
        # otherwise run on a row nothing is working on.
        @tool_entries.clear
        # A stop on an answer that never had a non-blank token drops its row,
        # so the cancelled turn does not leave a blank line of its own.
        if event[1] && @live_entry && @live_text.to_s.strip.empty?
          @log.remove_last
        end
        @live_entry = nil
        if event[1]
          # A cancelled turn gets no footer: the partial answer is the whole
          # record. Keep one blank after it as the separator the next prompt
          # needs, but not the extra one the footer line would have sat above.
          @log.add_entry([ [ "", nil ] ]) unless @log.last_blank?
          @working.notice = "Operation canceled by user"
        else
          # The separator before the footer, unless the row above already is
          # one: a kept thinking block brings its own blank, and two in a row
          # would push the footer away from what it summarises.
          @log.add_entry([ [ "", nil ] ]) unless @log.last_blank?
          add_turn_summary
        end
      when :reset_turn_totals then reset_turn_totals
      when :assistant_text
        @log.add_entry([ [ MARK[:note] + " ", :muted ] ] + Markdown.to_segments(event[1]), keep_leading: true, indent: 2)
      when :tool_call
        # Thinking is over once the model has decided what to run.
        close_thinking
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
        index = @log.add_entry(tool_call_segments(event[1], summary, skill),
                              keep_leading: true, indent: 2, nowrap: true)
        @tool_entries[event[1].to_s] = { index: index, summary: summary, skill: skill, started_at: monotonic_now, shown: nil }
      when :tool_done
        # The ⚒ line flips to ✓ in place — or to ✗ when the call came back a
        # failure. A file the call wrote gains its diff rows below the row.
        prev = @tool_entries.delete(event[1].to_s)
        failed = Rubot::TUI::Transcript.failure?(event[3])
        mark = failed ? MARK[:err] : MARK[:ok]
        style = failed ? :error : :tool_ok
        index = prev ? prev[:index] : @log.add_entry([ [ "#{mark} ", style ], [ event[1].to_s, :muted ] ], indent: 2)
        set_tool_done(index, event[1].to_s, prev && prev[:summary], prev && prev[:skill], failed, elapsed: tool_elapsed(prev))
        add_file_diff(event[2])
      when :confirm then show_confirm(event)
      when :session_list then show_session_list(event[1])
      when :model_list then show_model_list(event[1], event[2], event[3])
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

    def set_tool_done(index, name, summary, skill = nil, failed = false, elapsed: nil)
      @log.set_entry(index, Rubot::TUI::Transcript.tool_done(name, summary, skill, failed: failed),
                     tail: elapsed && Rubot::TUI::Transcript.elapsed_tail(elapsed), nowrap: true)
    end

    # Seconds the call spent running, or nil when it came back before the
    # threshold — an ordinary call says nothing about its duration.
    def tool_elapsed(entry)
      return nil unless entry && entry[:started_at]

      elapsed = monotonic_now - entry[:started_at]
      elapsed >= SLOW_TOOL_SECONDS ? elapsed : nil
    end

    # A call still in flight past the threshold grows a live counter pinned to
    # the right edge of its row, so a hung tool looks busy instead of frozen.
    # Rewritten only when the label actually changes, once a second rather
    # than on every tick.
    def refresh_slow_tools
      return if @tool_entries.empty?

      now = monotonic_now
      @tool_entries.each do |name, entry|
        next unless entry[:started_at]

        elapsed = now - entry[:started_at]
        next if elapsed < SLOW_TOOL_SECONDS

        label = Rubot::TUI::Transcript.elapsed_label(elapsed)
        next if entry[:shown] == label

        entry[:shown] = label
        @log.set_entry(entry[:index], tool_call_segments(name, entry[:summary], entry[:skill]),
                       tail: Rubot::TUI::Transcript.elapsed_tail(elapsed), nowrap: true)
      end
    end

    # A file the tool just wrote gets its change diff under the tool row,
    # one indented block. The rows arrive already styled from TUI::Diff.
    def add_file_diff(rows)
      return if rows.nil? || rows.empty?

      rows.each { |segments| @log.add_entry(segments, keep_leading: true, indent: 4) }
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

    # Echo a steer mid-transcript. The answer streaming above it is closed
    # first, so what the model writes after the steer appears below it instead
    # of being appended to the fragment the steer interrupted. One blank row
    # above and below sets it apart, without doubling a blank that is already
    # the separator there. Continuation rows hang by the marker's width, so a
    # steer that wraps or spans lines stays under its own text.
    def add_steer_echo(line)
      close_thinking
      close_live_entry
      @log.add_entry([ [ "", nil ] ]) unless @log.last_blank?
      @log.add_entry([ [ "↳ ", :accent ], [ line, :text ], [ "  steered", :dim ] ],
                     keep_leading: true, hang: ECHO_HANG)
      @log.add_entry([ [ "", nil ] ])
    end

    # Finish the answer that is streaming, dropping the entry outright when no
    # token ever arrived, so the steer is not preceded by an empty row.
    def close_live_entry
      @log.remove_last if @live_entry && @live_text.to_s.strip.empty?
      @live_entry = nil
      @live_text = +""
    end

    def append_live(chunk)
      text = chunk.to_s
      # An empty fragment carries no answer: the row it would create stays a
      # blank line until real text arrives.
      return if text.empty?

      if @live_entry.nil?
        # Continuation after tool output starts a fresh spaced answer.
        @log.add_entry([ [ "", nil ] ]) unless @log.last_blank?
        start_live_entry
      end

      @live_text << text
      @log.set_entry(@live_entry, Markdown.to_segments(@live_text), keep_leading: true, indent: 2)
    end

    # The model's thinking, while it is still thinking. Only the state of the
    # wait is ever shown — never the thought itself: the transcript records
    # that the model was thinking, not what it was thinking about.
    #
    # The block is created by the first reasoning fragment that arrives, so a
    # turn that never thinks leaves no empty row behind, and later fragments
    # only feed the clock, not a body.
    def append_thinking(_delta)
      if @thinking_entry.nil?
        # A thought that arrives after the answer started belongs to a new
        # round: the fragment above is finished, so the answer continues below
        # the block instead of being split in half by it.
        close_live_entry if @live_entry
        @thinking_started_at = monotonic_now
        @thinking_shown = thinking_label
        # Remembered so a block that ends up dropped can take its own blank
        # row with it. Without this bookkeeping the row had to be probed for
        # with last_blank? at close time, which was both wrong (a blank that
        # was already there looks the same) and late (the tool row opened in
        # between makes the block no longer last).
        @thinking_blank = !@log.last_blank?
        @log.add_entry([ [ "", nil ] ]) if @thinking_blank
        @thinking_entry = @log.add_entry(thinking_segments(@thinking_shown),
                                        keep_leading: true, indent: 2)
      else
        # Only the clock is kept current; the fragment itself is discarded.
        refresh_thinking
      end
    end

    # Finish the thinking block. A wait worth noticing collapses to one line,
    # "Thought for 12s"; a quick one is dropped outright, blank row included,
    # so the transcript only records pauses the reader could feel.
    def close_thinking
      return if @thinking_entry.nil?

      index = @thinking_entry
      elapsed = monotonic_now - @thinking_started_at
      own_blank = @thinking_blank
      @thinking_entry = nil
      @thinking_shown = nil
      @thinking_blank = false
      @thinking_started_at = nil

      if elapsed > THINKING_SECONDS
        @log.set_entry(index, [ [ MARK[:think] + " ", :muted ],
                                [ "Thought for #{format_duration(elapsed)}", :dim ] ],
                       keep_leading: true, indent: 2)
        # A kept block is set off by a blank row on both sides: its own remark
        # on the turn, not a line of whatever it sits between. The block is
        # still the last entry here — every caller closes it before opening the
        # row that follows — so this blank lands directly beneath it.
        @log.add_entry([ [ "", nil ] ])
      else
        # A thought too short to mention leaves no row at all, and no blank
        # either: the spacer above it goes back with it.
        @log.remove_entry(index)
        @log.remove_entry(index - 1) if own_blank && blank_entry?(@log.entry_at(index - 1))
      end
    end

    # The live block: a header that grows an elapsed counter once the wait is
    # long enough to notice. Nothing of the thought itself is drawn.
    def thinking_segments(elapsed = nil)
      header = [ [ MARK[:think] + " ", :accent ], [ "Thinking…", :muted ] ]
      header << [ " · #{format_duration(elapsed)}", :dim ] if elapsed
      header
    end

    # A block still open past the threshold shows how long it has been
    # thinking. Rewritten only when the label changes, once a second rather
    # than on every tick.
    def refresh_thinking
      return if @thinking_entry.nil? || @thinking_started_at.nil?

      label = thinking_label
      return if @thinking_shown == label

      @thinking_shown = label
      @log.set_entry(@thinking_entry, thinking_segments(label), keep_leading: true, indent: 2)
    end

    # The elapsed label for the live block, or nil while the wait is still
    # short enough that a clock would only be noise.
    def thinking_label
      return nil if @thinking_started_at.nil?

      elapsed = monotonic_now - @thinking_started_at
      elapsed > THINKING_SECONDS ? format_duration(elapsed) : nil
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
                    on_tool_call: proc do |name, args, _snapshot|
                      @events << [ :tool_call, name, args ]
                    end,
                    on_tool_result: proc do |name, result, ui_diff|
                      @events << [ :tool_done, name, file_diff(ui_diff), result ]
                    end,
                    on_stopped: -> { stopped = true },
                    on_reasoning: proc { |delta| @events << [ :thinking, delta.to_s ] },
                    on_usage: ->(report) { live_usage(report) },
                    stream: @stream) do |chunk|
        @events << [ :chunk, chunk.to_s ]
        response << chunk.to_s
      end
      # The answer is on screen, so learning may safely run now.
      agent.flush_learning
    rescue Interrupt
      agent&.cancel! if agent.respond_to?(:cancel!)
      @events << [ :error_text, "⏹️ cancelled" ]
    rescue Rubot::RateLimitError => e
      # Already retried with backoff by the provider, so this is the final
      # word: say what happened and what to do, without a stack trace.
      @events << [ :error_text, "⏳ #{e.message}" ]
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
    # answered. The dialog lives on the App thread, so the request is
    # published as an event and the worker waits on its own answer queue: a
    # stale answer from an earlier confirmation can never be reused. Fail
    # closed (deny) if the channel dies mid-dialog.
    def confirm_callback
      proc do |tool_name, args, reason|
        answered = Queue.new
        @events << [ :confirm, tool_name, args, answered, reason ]
        answered.pop
      end
    end

    # The diff rows for the before/after text the agent attached to a tool
    # result, or nil when the call changed no file. Both sides are already
    # read by then — inside whatever ran the tool, so nothing here races it.
    # A delete leaves no file behind, so its after-content is nil and every
    # line it had renders as a removal.
    def file_diff(ui_diff)
      return nil unless ui_diff.is_a?(Hash)

      Rubot::TUI::Diff.rows(ui_diff["before"], ui_diff["after"], path: ui_diff["path"])
    rescue StandardError
      nil
    end

    def stdin_confirm_callback
      proc do |tool_name, args, reason|
        description = reason || "#{tool_name} #{tool_summary(tool_name, args)}".strip
        print "\n⚠️  #{description}\nConfirm? [y/N] "
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

    # /resume-style: the confirmation writes its question into the log and
    # keeps the keyboard until answered (y allows, enter/esc deny), the way
    # ConfirmDialog did — but as transcript rows above the prompt instead of
    # a floating modal, so the text stays selectable with the mouse.
    def show_confirm(event)
      _, tool_name, args, answered, reason = event
      @confirm_prompt.ask(tool_name, args, answered: answered, reason: reason)
      @prompt.list = @confirm_prompt
    end

    # /resume writes the list into the transcript and hands the prompt over
    # to it; picking an entry feeds a /resume <id> command back into the
    # worker, so the switch itself stays on the worker thread.
    def show_session_list(entries)
      @prompt.list = @session_list if @session_list.open(entries)
    end

    # /models writes the provider's model list into the transcript and hands
    # the prompt over to it; picking a model feeds a /use-model <id> command
    # back into the worker, so the switch itself stays on the worker thread.
    def show_model_list(entries, title = nil, filter = nil)
      @prompt.list = @model_list if @model_list.open(entries, title: title, filter: filter)
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
      # The live rows point at indexes into the log that no longer exist.
      @thinking_entry = nil
      @thinking_started_at = nil
      @thinking_shown = nil
      @thinking_blank = false
      @tool_entries.clear
      @working.notice = nil
      reset_turn_totals
      @status.left = ""
    end

    # Restore a resumed conversation exactly as it looked while it was live:
    # prompt echoes, streamed answers (Markdown), and finished tool rows.
    def replay_transcript(messages)
      clear_log_keep_banner
      Rubot::TUI::Transcript.entries(messages, width: @log.content_width).each do |entry|
        @log.add_entry(entry[:segments], keep_leading: entry[:keep_leading], indent: entry[:indent],
                                          nowrap: entry[:nowrap])
      end
    end

    # ------------------------------------------------------------------
    # External editor (ctrl+g)
    # ------------------------------------------------------------------

    # Paste from the desktop clipboard. The terminal delivers text, never
    # pixels, so images are fetched from the clipboard and stored as temp
    # files; the prompt only shows "Image 1", "Image 2", ... and the token
    # becomes the path on submit. They stay in the temp directory: scratch
    # input for this turn, not something a resumed session should carry.
    def paste_clipboard
      paths = ClipboardImage.capture_all
      unless paths.empty?
        paths.each { |path| @prompt.insert_image(path) }
        @app.focus(@prompt)
        return
      end

      # No image: a clipboard holding text is what a paste key is normally
      # used for, and some terminals do not intercept ctrl+v at all.
      text = ClipboardImage.text
      if text
        @prompt.insert_paste(text)
        @app.focus(@prompt)
      end
    rescue StandardError => e
      publish [ [ MARK[:err] + " ", :error ], [ "paste: #{e.class}: #{e.message}", :error ] ]
    end

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

    # Hand a line typed during a running turn to the agent, which delivers it
    # between rounds. In actor mode the agent lives in another Ractor, so this
    # goes through a non-blocking signal (a request would queue behind the turn
    # it is meant to steer). Returns false when the turn cannot be steered, so
    # the caller can send the line the normal way instead of losing it.
    def steer_running_turn(line)
      return false unless agent.respond_to?(:steer)

      agent.steer(line)
    rescue StandardError
      false
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
      if info[:auto_approve]
        puts "⚡ Auto mode on — non-destructive actions run without asking; destructive patterns stay blocked (/auto off)"
      end
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
      # A command that brings its own blank line (a list, or a wiped
      # transcript) does not get one from the flush.
      @command_owns_blank = false
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
        refresh_usage
      when "/new"
        # Silent restart: wipe the screen and start a fresh session.
        @command_owns_blank = true
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
        # Mid-turn the agent is busy with the answer, so the report it last
        # published is what there is to show — the same numbers the footer
        # is moving.
        report = @live_report || agent.usage_report
        say_text(Rubot::UsageReport.render(report))
        say_text("live — the request in flight is not in these totals yet") if @live_report
        blank
      when "/usage"
        blank
        say_text(Rubot::OpencodeUsageReport.render(agent.opencode_usage))
        blank
      when "/models"
        handle_models_command(parts[1])
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
          memory = agent.memory
          if memory.respond_to?(:global_path)
            say("Memory — global: #{memory.global_path}", :info)
            say("Memory — this workspace: #{memory.workspace_path}", :info)
          else
            say("Memory (MEMORY.md):", :info)
          end
          say_text(memory.read, :text)
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
      when "/auto"
        handle_auto_command(parts[1])
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

    # /auto with no argument flips the current mode, so the common case is one
    # word. The choice is persisted by the agent (config.yml), which is why the
    # next launch starts the same way.
    def handle_auto_command(argument)
      word = argument.to_s.strip.downcase
      wanted = if word.empty?
        !auto_mode?
      elsif AUTO_TOGGLE.key?(word)
        AUTO_TOGGLE[word]
      end

      if wanted.nil?
        say("Usage: /auto on|off (no argument flips it).", :err)
        return
      end

      agent.set_auto_approve(wanted)
      # Publish the new status row straight away instead of queueing a full
      # /sync: the metrics did not change, only the badge that says the agent
      # has stopped asking.
      info = agent.startup_info
      @events << [ :status_badge, status_badge_text(info) ]
      @events << [ :status_right, status_right_text(info) ]
      if wanted
        # The same amber as the status badge, so the colour means one thing:
        # this agent acts without asking.
        say("Auto mode on — non-destructive actions run without asking.", :warn)
        say_text("Destructive patterns (rm -rf /, mkfs, dd onto a device, …) are still refused.")
      else
        say("Auto mode off — every dangerous action asks first.", :info)
      end
    end

    def auto_mode?
      a = agent
      a.respond_to?(:auto_approve?) ? !!a.auto_approve? : false
    rescue StandardError
      false
    end

    def handle_resume(query)
      text = query.to_s.strip
      # /resume all ignores the launch directory: every conversation that was
      # started from some project. Sessions with no recorded origin (Telegram
      # chats, files written before the cwd field existed) are never listed.
      every = text.casecmp?("all")
      text = "" if every
      sessions = resume_entries(all: every)

      if text.empty?
        # Interactively, /resume writes the list into the log; only a plain (piped) REPL
        # has to print the list and take the number on the next line.
        if @tui && !sessions.empty?
          @command_owns_blank = true
          @events << [ :session_list, sessions ]
        else
          list_sessions(sessions)
        end
        return
      end

      entry = find_session(sessions, text)
      # A hidden session (another project, no origin) is still reachable by id
      # when it is named exactly.
      entry ||= Rubot::Session.find(nil, text, dir: sessions_dir)
      unless entry
        say("Session '#{text}' not found.", :err)
        say_text("Type /resume to see saved sessions.")
        return
      end

      resume_session(entry)
    end

    # Saved conversations the user can resume, newest first. Everything is
    # stored in one directory; the launch directory decides what shows up.
    def resume_entries(all: false)
      entries = Rubot::Session.index(nil, cwd: :all, dir: sessions_dir)
      entries = entries.reject { |entry| entry[:cwd].to_s.empty? }
      return entries if all

      cwd = sessions_cwd.to_s
      return entries if cwd.empty?

      entries.select { |entry| entry[:cwd] == cwd }
    end

    # How many saved conversations belong to other directories. Shown as a hint
    # so a project that has never been used does not look empty.
    def other_dir_sessions
      all = Rubot::Session.index(nil, cwd: :all, dir: sessions_dir)
      all.count { |entry| !entry[:cwd].to_s.empty? && entry[:cwd].to_s != sessions_cwd.to_s }
    rescue StandardError
      0
    end

    def list_sessions(sessions)
      if sessions.empty?
        say("No saved sessions yet.", :info)
        say_text("Conversations are saved as they happen; /resume brings one back later.")
        others = other_dir_sessions
        say_text("#{others} conversation(s) from other directories · /resume all") if others.positive?
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
      others = other_dir_sessions
      say_text("#{others} more from other directories · /resume all") if others.positive?
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
      messages = Rubot::Session.transcript(nil, entry[:id], dir: sessions_dir)

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

    # /models lists the models the provider supports and lets the user pick
    # one for the active session. The list comes from the provider's /models
    # endpoint; config.yml entries the provider does not advertise are added
    # at the end, so a configured model stays selectable.
    def handle_models_command(query = nil)
      entries = provider_model_entries
      if entries.empty?
        say("No models available.", :warn)
        say_text("The provider returned no model catalog, and config.yml has no models.")
        return
      end

      filter = query.to_s.strip
      shown = entries.select { |entry| Rubot::TUI::ModelList.matches?(entry, filter) }
      if shown.empty?
        say("No model matches '#{filter}'.", :warn)
        return
      end

      if @tui
        @command_owns_blank = true
        @events << [ :model_list, entries, model_list_title(entries), filter ]
      else
        say("Models supported by #{provider_name}:", :info)
        shown.each do |entry|
          marker = entry[:active] ? MARK[:ok] : " "
          label = entry[:label].to_s
          label = "" if label == entry[:id].to_s
          say_text("  #{marker} #{entry[:id]}#{label.empty? ? "" : " (#{label})"}")
        end
      end
    end

    def model_list_title(entries)
      "Models supported by #{provider_name}"
    end

    def provider_name
      agent.provider.name
    rescue StandardError
      "the provider"
    end

    # The models the provider supports, as picker entries. Each entry has an
    # "id" (what the provider is asked for), a "label" (a friendlier name)
    # and an "active" flag.
    def provider_model_entries
      catalog = provider_catalog_entries
      config_entries = config_model_entries

      known = catalog.map { |model| model["id"] }
      entries = catalog.map do |model|
        { id: model["id"], label: model["name"], active: false }
      end

      # A configured model the provider does not advertise is still usable,
      # so it is listed under its config name.
      config_entries.each do |entry|
        model = entry["model"].to_s
        id = model.include?("/") ? model.split("/").last : model
        next if known.include?(id) || known.include?(entry["name"].to_s)

        entries << { id: entry["name"].to_s, label: model, active: false }
      end

      active = active_model_ids
      entries.each do |entry|
        label_id = entry[:label].to_s.split("/").last
        entry[:active] = active.include?(entry[:id].to_s) || active.include?(label_id)
      end

      entries
    end

    # The provider's own model catalog, as plain hashes.
    def provider_catalog_entries
      models = agent.provider_models
      models = [] unless models.is_a?(Array)
      models.filter_map do |model|
        next unless model.is_a?(Hash)

        id = (model["id"] || model["name"]).to_s.strip
        next if id.empty?

        { "id" => id, "name" => (model["name"] || id).to_s.strip }
      end
    rescue StandardError => e
      say("Could not read the model catalog: #{e.message}", :warn)
      []
    end

    # The models configured in config.yml.
    def config_model_entries
      models = agent.config.models
      return [] unless models.is_a?(Array)

      models.select { |model| model.is_a?(Hash) && model["name"] }
    rescue StandardError
      []
    end

    # Every id the active model can be known by: the provider model id, the
    # config entry name and the model id of that entry.
    def active_model_ids
      ids = []
      name = agent.active_model_name.to_s
      ids << name
      ids << name.split("/").last

      entry = begin
        agent.config.model_entry_by_name(name)
      rescue StandardError
        nil
      end
      if entry.is_a?(Hash)
        model = entry["model"].to_s
        ids << model
        ids << model.split("/").last
      end

      override = begin
        agent.session.model_override.to_s
      rescue StandardError
        ""
      end
      ids << override

      ids.reject(&:empty?).uniq
    end

    def handle_use_model(model_name)
      if model_name.nil?
        say("Usage: /use-model <model-name>", :warn)
        agent.config.models.each { |m| say_text("  - #{m["name"]}") }
        return
      end

      result = agent.use_model(model_name)
      if result
        # A config entry is known by its name, a provider model by its id.
        entry = agent.config.model_entry_by_name(model_name)
        label = entry.is_a?(Hash) && entry["model"] ? entry["model"].to_s : ""
        label = "" if label == result.to_s
        say("Switched to model: #{result}#{label.empty? ? "" : " (#{label})"}", :ok)
        say_text("Provider: #{agent.provider.name}")
        say_text("Persists for this session (cleared on /new).")
        refresh_status
        refresh_usage
      else
        say("Model '#{model_name}' not found in config.yml or the provider catalog.", :err)
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

      if lines.nil? || lines.empty?
        # A command that prints nothing still leaves one blank line below it,
        # so whatever comes next is set apart from it. A list command brings
        # its own spacing.
        publish([ [ "", nil ] ]) unless @command_owns_blank
        return
      end

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
    # plain mode (the plain loop never drains @events). `keep_leading` keeps
    # the spaces a row starts with, and `hang` indents every row after the
    # first — both of which an indented prompt echo needs.
    def publish(segments, keep_leading: false, hang: 0)
      if @tui
        @events << [ :entry, segments, keep_leading, hang ]
      else
        puts segments.map { |t, _s| t.to_s }.join
      end
      nil
    end

    # The "❯ " marker opens the first row only. The entry carries a hanging
    # indent the width of the marker, so every later row of a multiline
    # prompt (typed newlines and soft wraps alike) lines up under the text
    # instead of starting at the left edge.
    def prompt_echo(line)
      [ [ "❯ ", :accent ], [ line.to_s, :text ] ]
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
      if info[:auto_approve]
        @log.add_entry([ [ "⚡ auto mode on", :warning ],
                         [ " — non-destructive actions run without asking; destructive patterns stay blocked (/auto off)", :dim ] ])
      end
      @log.add_entry([ [ "type /help for commands · esc cancels a running turn · type to steer it · pgup/pgdn scrolls", :dim ] ])
      @log.add_entry([ [ "", nil ] ])
      @banner_count = @log.entry_count
      @status.right = model if info[:model]
      @status.badge = status_badge_text(info)
      # The worker fills this in as soon as it has priced the launch (it may
      # read the pricing catalog first); until then the row says what it is
      # waiting for instead of showing an empty half.
      @status.left = COST_PLACEHOLDER
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
