# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The turn indicator above the input: one blank row, the "working · 12s ·
    # esc cancels" line, one blank row. Idle, it renders as empty space so
    # the layout never jumps — unless there is a notice to show, which takes
    # the same row and stays until the next turn starts.
    class WorkingBadge < ::TUI::Component
      SPINS = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      # Phases that mean a sub agent is still working.
      RUNNING_PHASES = %w[started thinking tool].freeze

      def initialize
        super
        @frame = 0
        @mode = nil
        @notice = nil
        @started_at = nil
        @subagents = {}
      end

      # Record the latest state of one delegated run. Called from the agent's
      # on_subagent callback through the TUI event pump.
      def subagent(info)
        run_id = info[:run_id].to_s
        return self if run_id.empty?

        @subagents[run_id] = {
          agent: info[:agent].to_s,
          phase: info[:phase].to_s,
          detail: info[:detail].to_s
        }
        self
      end

      def clear_subagents
        @subagents.clear
        self
      end

      def subagent_count
        @subagents.values.count { |s| RUNNING_PHASES.include?(s[:phase]) }
      end

      def tick(mode)
        @frame += 1
        # A running turn owns the row; a notice only fills the idle band.
        @notice = nil unless mode.nil?
        # The clock runs from the first tick of a turn until it ends, so it
        # matches the "Turn took" footer instead of counting idle time.
        @started_at = monotonic_now if mode && @started_at.nil?
        @started_at = nil if mode.nil?
        @mode = mode
        self
      end

      # Seconds the current turn has been running, or nil when idle.
      def elapsed
        return nil if @started_at.nil?

        [ monotonic_now - @started_at, 0.0 ].max
      end

      # Show one line of text in the idle band (red, as an error).
      def notice=(text)
        @notice = text.to_s
        self
      end

      def notice?
        !@notice.nil?
      end

      def spin
        SPINS[@frame % SPINS.length]
      end

      def measure(_max_w, _max_h)
        [ 10, 3 ]
      end

      def render(canvas)
        canvas.fill(@rect.x, @rect.y, @rect.w, @rect.h, " ", nil)

        if @mode
          render_status(canvas)
        elsif @notice
          render_notice(canvas)
        end

        self
      end

      private

      def render_status(canvas)
        y = @rect.y + 1
        x = @rect.x + 2
        label = @mode == :cancel ? "cancelling" : "working"
        canvas.put(x, y, "#{spin} ", :accent)
        canvas.put(x + 2, y, label, :accent)
        x += 2 + label.length

        clock = elapsed_text
        if clock
          canvas.put(x, y, " · #{clock}", :hint)
          x += clock.length + 3
        end

        canvas.put(x, y, " · esc cancels", :hint)
        render_subagents(canvas) unless @subagents.empty?
      end

      # One compact line: how many sub agents are running, then each one's
      # persona and current activity. Kept on the badge's single status row so
      # the layout never grows; a long detail is clipped to the room left.
      def render_subagents(canvas)
        y = @rect.y + 1
        parts = +" · ⟡ #{subagent_count} subagent"
        @subagents.each_value do |s|
          mark = s[:phase] == "done" ? "✓" : (s[:phase] == "failed" ? "✗" : "")
          detail = s[:detail].to_s.gsub(/\s+/, " ").strip
          parts << " · #{mark}#{s[:agent]}#{detail.empty? ? "" : " (#{detail})"}"
        end
        room = [ @rect.w - 2, 0 ].max
        text = ::TUI::Text.truncate(parts, room)
        canvas.put(@rect.x + 2, y, text, :hint)
      end

      # A live counter: seconds while the turn is young, minutes after that.
      def elapsed_text
        seconds = elapsed
        return nil if seconds.nil?

        total = seconds.to_i
        return "#{total}s" if total < 60

        minutes, rest = total.divmod(60)
        format("%dm %02ds", minutes, rest)
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def render_notice(canvas)
        text = ::TUI::Text.truncate(@notice, [ @rect.w - 4, 0 ].max)
        canvas.put(@rect.x + 2, @rect.y + 1, text, :error)
      end
    end
  end
end
