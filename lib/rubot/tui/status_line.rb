# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # One-row status strip: session and model on the right, nothing on the
    # left (the working/cancelling indicator is the badge above the input).
    class StatusLine < ::TUI::Component
      attr_reader :spinner_idx

      def initialize
        super
        @spinner_idx = 0
        @right = ""
      end

      def right=(text)
        @right = text.to_s
        self
      end

      def tick
        @spinner_idx = (@spinner_idx + 1) % 10
        self
      end

      def measure(_max_w, _max_h)
        [ 10, 1 ]
      end

      def render(canvas)
        draw(canvas)
        self
      end

      private

      def draw(canvas)
        right = ::TUI::Text.truncate(" #{@right} ", @rect.w)
        right_w = ::TUI::Text.width(right)
        base = " " * [ @rect.w - right_w, 0 ].max
        canvas.put(@rect.x, @rect.y, base + right, :muted)
      end
    end
  end
end
