# frozen_string_literal: true

module Rubot
  class TUI
    # Actor events, turned into rows and state: the answer as it streams, the
    # thinking block that collapses when the first token lands, tool rows that
    # flip from ⚒ to ✓ in place, and the footer that closes a turn.
    #
    # Everything the App thread does to the transcript goes through here,
    # including the row primitives apply_event calls (say, emit, publish,
    # prompt_echo). That is why the queue is drained once per tick: nothing in
    # this file runs on the worker thread.
    module Events
      private

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
        when :stream_start then start_stream
        when :thinking then append_thinking(event[1])
        when :subagent
          @working.subagent(event[1])
          # A finished delegation is also a row in the transcript, so a resumed
          # session shows the same work the live turn did.
          info = event[1]
          add_subagent_row(info) unless info[:phase].to_s == "thinking"
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
        when :stream_end then finish_stream(event[1])
        when :reset_turn_totals then reset_turn_totals
        when :assistant_text
          @log.add_entry([ [ MARK[:note] + " ", :muted ] ] + Markdown.to_segments(event[1]), keep_leading: true, indent: 2)
        when :tool_call then start_tool_call(event[1], event[2])
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

      # The turn has started but answered nothing yet, so the working badge
      # takes over and last turn's blocks are cleared.
      def start_stream
        @working.notice = nil
        @working.clear_subagents
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
      end

      # The turn is over, cancelled or not: close the block that was open, drop
      # the clocks, and put either the footer or the cancellation note under
      # the answer.
      def finish_stream(cancelled)
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
        if cancelled && @live_entry && @live_text.to_s.strip.empty?
          @log.remove_last
        end
        @live_entry = nil
        if cancelled
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
      end

      # A tool the model decided to run: the thinking is over, any phantom
      # answer row is cleared, and the tool gets a row that starts its clock.
      def start_tool_call(name, args)
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
        skill = skill_load(name, args)
        summary = if skill
          ::TUI::Text.truncate(skill, tool_summary_limit("skill"))
        else
          tool_summary(name, args, max: tool_summary_limit(name))
        end
        index = @log.add_entry(tool_call_segments(name, summary, skill),
                              keep_leading: true, indent: 2, nowrap: true)
        @tool_entries[name.to_s] = { index: index, summary: summary, skill: skill, started_at: monotonic_now, shown: nil }
      end

      # A delegation as a transcript row: the persona that answered and the
      # phase it reached. Indented like a tool row so it reads as work done on
      # the turn's behalf, not as a message from the reader.
      def add_subagent_row(info)
        mark = case info[:phase].to_s
        when "done" then MARK[:ok]
        when "failed" then MARK[:err]
        else MARK[:tool]
        end
        style = info[:phase].to_s == "failed" ? :error : :muted
        detail = info[:detail].to_s.gsub(/\s+/, " ").strip
        segments = [ [ "#{mark} ", style ], [ "subagent ", :muted ], [ info[:agent].to_s, :accent ] ]
        segments += [ [ " · #{detail}", :dim ] ] unless detail.empty?
        @log.add_entry(segments, keep_leading: true, indent: 2)
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
          # A thought that arrives while the answer is still streaming is an
          # out-of-band fragment: some gateways interleave reasoning_content
          # with content, and closing the answer row here cut the message in
          # two at a chunk boundary — mid-word, with a blank row between the
          # halves ("Sem" / "" / "ua …"). The fragment is dropped instead: only
          # a pause *between* rounds deserves a row, and a real one always
          # starts with no live entry, since :tool_call and :stream_end both
          # close it.
          return if @live_entry

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
      #
      # The prompt is rendered as markdown for the same reason the answer is: a
      # reader who pastes a snippet, a list of paths or a diff wrote it in
      # markdown, and echoing it raw made the one message they typed themselves
      # the only thing on screen without syntax — a shell command came back
      # looking like a paragraph, and a `#` line looked like prose.
      def prompt_echo(line)
        [ [ "❯ ", :accent ] ] + Rubot::TUI::Markdown.to_segments(line.to_s)
      end

      def refresh_status
        @mailbox << :sync
      end

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
end
