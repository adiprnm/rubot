# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The turn indicator above the input: one blank row, the "working ·
    # esc cancels" line, one blank row. Idle, it renders as empty space so
    # the layout never jumps — unless there is a notice to show, which takes
    # the same row and stays until the next turn starts.
    class WorkingBadge < ::TUI::Component
      SPINS = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      def initialize
        super
        @frame = 0
        @mode = nil
        @notice = nil
      end

      def tick(mode)
        @frame += 1
        # A running turn owns the row; a notice only fills the idle band.
        @notice = nil unless mode.nil?
        @mode = mode
        self
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
        canvas.put(x, y, "#{spin} ", :accent)
        canvas.put(x + 2, y, @mode == :cancel ? "cancelling" : "working", :accent)
        canvas.put(x + 2 + (@mode == :cancel ? 10 : 7), y, " · esc cancels", :hint)
      end

      def render_notice(canvas)
        text = ::TUI::Text.truncate(@notice, [ @rect.w - 4, 0 ].max)
        canvas.put(@rect.x + 2, @rect.y + 1, text, :error)
      end
    end
  end
end
