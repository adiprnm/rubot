# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The turn indicator above the input: one blank row, the "working ·
    # esc cancels" line, one blank row. Idle, it renders as empty space so
    # the layout never jumps.
    class WorkingBadge < ::TUI::Component
      SPINS = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      def initialize
        super
        @frame = 0
        @mode = nil
      end

      def tick(mode)
        @frame += 1
        @mode = mode
        self
      end

      def spin
        SPINS[@frame % SPINS.length]
      end

      def measure(_max_w, _max_h)
        [ 10, 3 ]
      end

      def render(canvas)
        canvas.fill(@rect.x, @rect.y, @rect.w, @rect.h, " ", nil)
        return self if @mode.nil?

        y = @rect.y + 1
        x = @rect.x + 2
        canvas.put(x, y, "#{spin} ", :accent)
        canvas.put(x + 2, y, @mode == :cancel ? "cancelling" : "working", :accent)
        canvas.put(x + 2 + (@mode == :cancel ? 10 : 7), y, " · esc cancels", :hint)
        self
      end
    end
  end
end
