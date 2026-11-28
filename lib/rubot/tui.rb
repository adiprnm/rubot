# frozen_string_literal: true

require "base64"
require "open3"
require "shellwords"
require "tmpdir"

require_relative "usage"
require_relative "persona_store"
require_relative "opencode_usage"
require_relative "clipboard_image"
require_relative "tui/compat"
require_relative "tui/log_view"
require_relative "tui/jump_bottom"
require_relative "tui/log_pane"
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
require_relative "tui/commands"
require_relative "tui/events"
require_relative "tui/bindings"


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
      "/repin"    => "Rebuild the system prompt on the next message (picks up memory and skills, costs one uncached request)",
      "/clear"    => "Clear conversation history",
      "/session"  => "Show current session ID",
      "/session NAME" => "Switch to a new session",
      "/resume"   => "Pick a saved session to resume",
      "/resume N|NAME" => "Resume a saved session",
      "/search KATA" => "Search every stored message, including compacted turns",
      "/info"     => "Show agent info (provider, model, tools)",
      "/context"  => "Show context usage, cache hit rate, and estimated cost",
      "/usage"    => "Show OpenCode Go subscription usage",
      "/timing"   => "Where provider requests spend their time (needs RUBOT_TIMING=1 on launch)",
      "/models"   => "List the models the provider supports",
      "/model"    => "Show current active model",
      "/use-model NAME" => "Switch to a model for this session",
      "/tools"    => "List available tools",
      "/soul"     => "Show the bot's soul (SOUL.md)",
      "/memory"   => "Show persistent memory (MEMORY.md)",
      "/agents"   => "Show agent rules (AGENTS.md)",
      "/delegates" => "List personas available for sub-agent delegation",
      "/cron"     => "List scheduled cron jobs",
      "/web-restart" => "Restart the web channel (bin/rubot web)",
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

    # Skills are loaded by reading their SKILL.md through file_read (see
    # SkillRegistry#to_system_prompt). The TUI spots that path so a skill load
    # gets its own transcript row instead of hiding inside a file row; the
    # reading of the path itself lives in Rubot::SkillLoad, because the web
    # timeline and the Telegram card have to spot the same call.

    # How many archive hits /search prints. A terminal is a scrollback, not a
    # page: the best of a query is worth reading and the rest is a narrower
    # query away.
    SEARCH_RESULTS = 15

    # The slash commands: see tui/commands.rb.
    include Commands

    # Actor events and the rows they write: see tui/events.rb.
    include Events

    # The keyboard: see tui/bindings.rb.
    include Bindings

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
      # Naming, memory extraction and correction-learning run after the answer
      # is on screen: the prompt should come back the moment the agent stops
      # talking, not when the provider is done being asked about it.
      @learning = Learning.new
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
      @learning&.stop
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
      # The log plus the "jump to bottom" pill that floats over its last row
      # while the newest row is off screen. It takes no row of its own.
      @pane = Rubot::TUI::LogPane.new(@log)
      @jump = @pane.button
      @status = Rubot::TUI::StatusLine.new
      @workspace_line = Rubot::TUI::WorkspaceLine.new
      @workspace_line.workspace = Dir.pwd
      @menu = Rubot::TUI::CommandMenu.new(DESCRIPTIONS)
      @prompt = Rubot::TUI::PromptInput.new(@history, COMPLETABLE)
      @confirm_prompt = Rubot::TUI::ConfirmPrompt.new(log: @log)
      # The list goes back to the normal prompt on any answer, and "Other"
      # leaves a line saying the box is now where the answer is typed.
      @confirm_prompt.on_answer do |value|
        @prompt.list = nil
        publish_answer_hint(value == :custom ? "Type your answer, then enter ⏎" : nil)
        # Escaping a question stops the turn. The worker is already being
        # released by the prompt itself, so this only has to cancel the turn:
        # signalling the worker's own queue would end the thread for good, and
        # the terminal would never answer again.
        cancel_turn if value == :stop
      end
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
      # The row that says the next typed line is the answer to a question, put
      # up when "Other" is chosen and taken back when the line arrives.
      @answer_hint = nil

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
      stack.add(::TUI::Layout::Padding.new(@pane, left: 1), size: ::TUI.flex(1))
      stack.add(@working, size: ::TUI.fixed(3))
      stack.add(@menu, size: ::TUI.auto)         # slash-command palette
      stack.add(@prompt_box, size: ::TUI.auto)   # grows with multiline input
      stack.add(@workspace_line, size: ::TUI.fixed(1))
      stack.add(@status, size: ::TUI.fixed(1))

      @app = ::TUI::App.new(::TUI::Layout::Padding.new(stack, left: 1))

      wire_bindings
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
      # Consecutive answer fragments are joined before they reach the log: each
      # one re-parsed the whole answer so far and re-wrapped the block, and a
      # provider sends many per frame. One parse per tick instead of one per
      # chunk is the same text on screen — 40 chunks of a 7KB answer measured
      # 89ms of parsing for 40 identical redraws of a block that had grown by
      # one sentence.
      queued = nil
      flush = lambda do
        next if queued.nil?

        apply_event([ :chunk, queued ])
        queued = nil
      end

      loop do
        event = begin
          @events.pop(true)
        rescue ThreadError
          break
        end

        if event[0] == :chunk
          (queued ||= +"") << event[1].to_s
          next
        end

        flush.call
        apply_event(event)
      end
      flush.call
    end

    # ------------------------------------------------------------------
    # Turn processing (worker thread)
    # ------------------------------------------------------------------

    def process_message(message)
      on_confirm = @tui ? confirm_callback : stdin_confirm_callback
      # A question needs a screen and a keyboard; the plain-stdin path has
      # neither in a shape that can wait, so it passes no reader and the model
      # is told to decide on its own.
      on_ask = @tui ? ask_callback : nil

      @events << [ :stream_start ]
      streamed = +""
      stopped = false
      final = agent.process(message,
                            on_confirm: on_confirm,
                            on_ask: on_ask,
                            on_tool_call: proc do |name, args, _snapshot|
                              @events << [ :tool_call, name, args ]
                            end,
                            on_tool_result: proc do |name, result, ui_diff|
                              @events << [ :tool_done, name, file_diff(ui_diff), result ]
                            end,
                            on_stopped: -> { stopped = true },
                            on_reasoning: proc { |delta| @events << [ :thinking, delta.to_s ] },
                            on_subagent: proc { |info| @events << [ :subagent, info ] },
                            on_usage: ->(report) { live_usage(report) },
                            stream: @stream) do |chunk|
        @events << [ :chunk, chunk.to_s ]
        streamed << chunk.to_s
      end
      show_unstreamed_tail(final, streamed, stopped: stopped)
      # The answer is on screen, so learning may safely run now — on the
      # queue, so the prompt comes back without waiting for a naming request.
      learn_in_background
    rescue Interrupt
      agent&.cancel! if agent.respond_to?(:cancel!)
    rescue Rubot::RateLimitError => e
      # Already retried with backoff by the provider, so this is the final
      # word: say what happened and what to do, without a stack trace.
      @events << [ :error_text, "⏳ #{e.message}" ]
    rescue Rubot::QuotaExhaustedError => e
      @events << [ :error_text, "🚫 #{e.message}" ]
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

    # The turn's answer arrives twice: in pieces as the model writes it, and
    # whole as the return value — and the whole one also carries what never
    # streamed at all.
    #
    # Without this, a turn could end with nothing on the screen: with `/stream
    # off` the provider is called without a stream, so no chunk is ever yielded
    # and the answer went nowhere. The same held for everything appended after
    # the last chunk — the notice that the round limit was hit, the note that an
    # answer was cut off at the output limit, cron results, and the fallback
    # used when the model returns nothing readable at all.
    def show_unstreamed_tail(final, streamed, stopped: false)
      # A stopped turn is reported by the status row above the input; the
      # sentence the agent appends for it would say the same thing twice.
      return if stopped

      text = final.to_s
      return if text.strip.empty?

      rest = if streamed.empty?
               text
      elsif text.start_with?(streamed)
               # The reader has the prefix already; only the tail is news.
               text[streamed.length..]
      end
      # nil means the streamed pieces were not this answer: a steered turn
      # streams one message and returns the next, and both are wanted as they
      # came.
      return if rest.nil? || rest.strip.empty?

      @events << [ :chunk, rest ]
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

    # The same queue-shaped wait as the confirmation above, with the question's
    # own rows. Blocks the worker until a chip is picked or a line is typed.
    def ask_callback
      proc do |payload|
        answered = Queue.new
        @events << [ :question, payload, answered ]
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
      learn_in_background
    rescue Interrupt
      agent&.cancel! if agent.respond_to?(:cancel!)
      puts "\n⏹️ Cancelled.\n"
    rescue StandardError => e
      puts "\n❌ Error: #{e.message}\n"
    end

    # Post-answer learning, off the worker's back: the prompt comes back the
    # moment the answer is complete, and naming or memory extraction happens
    # while the reader is already typing the next thing. The handle is read
    # here rather than inside the job, so switching session (or the pool
    # handing out another one) cannot redirect the work to the wrong session.
    def learn_in_background
      handle = agent
      return unless handle.respond_to?(:flush_learning)

      session_id = @session_id
      @learning.submit(session_id) { handle.flush_learning }
    rescue StandardError => e
      warn "[learning] #{e.class}: #{e.message}" if Rubot.debug?
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

    # What a test may drive: the App loop is the only caller of most of these
    # in production — one tick (pump), one event (apply_event), one command
    # (handle_command) — and a real terminal is the only other way in. They are
    # public on purpose so a test does not have to reach for send; everything
    # not named here stays private.
    public :add_steer_echo, :apply_event, :build_ui, :confirm_callback, :copy_selection,
           :edit_prompt, :editor_command, :file_diff, :handle_command, :monotonic_now,
           :paint_banner, :paste_clipboard, :process_message, :prompt_echo, :pump,
           :push_status_info, :refresh_slow_tools, :refresh_thinking, :resume_entries,
           :spawn_command_lane, :start_fresh_session, :stop_command_lane, :tool_summary
  end
end
