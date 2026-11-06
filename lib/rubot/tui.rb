# frozen_string_literal: true

require "base64"

require_relative "usage"
require_relative "opencode_usage"
require_relative "tui/compat"
require_relative "tui/log_view"
require_relative "tui/markdown"
require_relative "tui/prompt_input"
require_relative "tui/status_line"
require_relative "tui/working_badge"
require_relative "tui/confirm_dialog"


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
  # Keys: enter send · tab completes /commands · ↑↓ history ·
  # page-up/page-down scroll · esc cancels the running turn · ctrl-c quits.
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

    # Command names offered by tab completion (the parameterized variants
    # read better in /help than as completion targets).
    COMPLETABLE = COMMANDS.keys.reject { |c| c.include?(" ") }.freeze

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

      # Queues bridging worker/agent threads into the App thread. Component
      # state is only ever mutated on the App thread (pump + key handlers).
      @events = Queue.new    # worker & channel threads -> UI
      @confirm = Queue.new   # confirm dialog -> worker
      @mailbox = Queue.new   # submitted lines -> worker

      @worker = nil
      @app = nil
      @tui = false
    end

    # Current session handle: a legacy in-process Agent or a Ractor-backed
    # SessionHandle.
    def agent
      @pool ? @pool.for(@session_id) : @agent
    end

    # Switch the active session. In actor mode this points the REPL at
    # another session handle (one actor per session).
    def switch_session(name)
      if @pool
        @session_id = name.to_s
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
      # Every launch starts from a fresh session; no leftover work leaks
      # in, while the persona/default preset still apply.
      start_fresh_session
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
      agent.clear_session
    end

    def build_ui
      @tui = true
      @log = Rubot::TUI::LogView.new
      @status = Rubot::TUI::StatusLine.new
      @prompt = Rubot::TUI::PromptInput.new(@history, COMPLETABLE)
      @dialog = Rubot::TUI::ConfirmDialog.new
      @working = Rubot::TUI::WorkingBadge.new
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
      stack.add(@prompt_box, size: ::TUI.auto)   # grows with multiline input
      stack.add(@status, size: ::TUI.fixed(1))

      @overlay = ::TUI::Layout::Overlay.new(
        ::TUI::Layout::Padding.new(stack, left: 1),
        @dialog
      )
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
      @app.on_key(:escape) do
        @log.clear_selection
        cancel_turn
      end

      # Typing, scrolling and new output all move the rows out from under a
      # highlight that was left on screen after a copy.
      @prompt.on(:change) { @log.clear_selection }

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
      when :clear_log
        @log.clear(keep: @banner_count)
        @live_entry = nil
        @tool_entries.clear
        reset_turn_totals
        @status.left = ""
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
        @live_entry = nil
        @log.add_entry([ [ "", nil ] ])
        add_turn_summary
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
      when :idle then
        @busy = false
        @stopping = false
      end
    end

    # The row for a tool call in flight. A skill load is not shown as
    # `file_ops read …/SKILL.md` but as its own line, so the transcript says
    # plainly that the agent picked a skill up — the same way a tool call shows.
    def tool_call_segments(name, summary, skill)
      if skill
        [ [ "#{MARK[:skill]} ", :accent ], [ "skill ", :muted ], [ summary, :accent ] ]
      else
        [ [ "#{MARK[:tool]} ", :muted ], [ name.to_s, :accent ], [ " ", :muted ], [ summary, :dim ] ]
      end
    end

    def set_tool_done(index, name, summary, skill = nil)
      segments = if skill
        # Slightly brighter than a finished tool row (muted): the skill name is
        # what the reader came for, the label only marks the row.
        [ [ "#{MARK[:ok]} ", :tool_ok ], [ "skill ", :dim ], [ summary, :dim ] ]
      else
        [ [ "#{MARK[:ok]} ", :tool_ok ], [ name, :muted ] ]
      end
      if summary && !summary.empty? && !skill
        segments += [ [ " ", :muted ], [ summary, :dim ] ]
      end
      @log.set_entry(index, segments)
    end

    # Returns the skill name when this tool call reads a skill's SKILL.md,
    # nil otherwise. Only reads count: writing a skill file is not loading it.
    def skill_load(tool_name, args)
      args = {} unless args.is_a?(Hash)
      raw = nil
      case tool_name.to_s
      when "file_ops"
        raw = args["path"] if args["operation"].to_s == "read"
      when "shell_exec"
        raw = args["command"] if args["command"].to_s.match?(READ_COMMANDS)
      end
      name = SKILL_PATH.match(raw.to_s)&.[](1)
      name if name && !name.empty?
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
      agent.process(message,
                    on_confirm: on_confirm,
                    on_tool_call: ->(name, args) { @events << [ :tool_call, name, args ] },
                    on_tool_result: ->(name, _result) { @events << [ :tool_done, name ] },
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
      @events << [ :stream_end ]
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
      raw = case tool_name
      when "shell_exec" then args["command"].to_s
      when "file_ops"
              "#{args["operation"]} #{args["path"]}"
      else
              args.inspect
      end
      line = raw.lines.first.to_s.strip
      ::TUI::Text.truncate(line, max)
    end

    # Cells left for the argument preview after " ⚒ ", the tool name and
    # the separating space, keeping one cell clear of the scrollbar.
    def tool_summary_limit(tool_name)
      width = @log.content_width
      return 64 if width <= 0

      [ width - 4 - ::TUI::Text.width(tool_name.to_s) - 2, 0 ].max
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
        end
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
      publish segments
    end

    def say_text(text, style = :dim)
      text.to_s.each_line(chomp: true) do |line|
        publish [ [ line, style ] ]
      end
    end

    def blank
      publish [ [ "", nil ] ]
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
