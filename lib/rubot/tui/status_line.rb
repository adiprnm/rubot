# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # One-row status strip: live session metrics on the left (estimated cost,
    # cache hit rate, context usage) and model on the right.
    #
    # The left side is the one that gets cut when the terminal is narrow: the
    # model info makes way for nothing, while the metrics lose their tail with
    # an ellipsis instead of overlapping it.
    class StatusLine < ::TUI::Component
      attr_reader :spinner_idx

      def initialize
        super
        @spinner_idx = 0
        @left = ""
        @right = ""
      end

      def left=(text)
        @left = text.to_s
        self
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
        width = @rect.w
        right = @right.empty? ? "" : ::TUI::Text.truncate(" #{@right} ", width)
        right_w = ::TUI::Text.width(right)

        # Reserve one blank cell between the two blocks; left yields first.
        avail = width - right_w - 1
        left = avail.positive? ? ::TUI::Text.truncate(@left, avail) : ""
        left_w = ::TUI::Text.width(left)
        gap = [ width - left_w - right_w, 0 ].max
        canvas.put(@rect.x, @rect.y, left + (" " * gap) + right, :dim)
      end
    end
  end
end
