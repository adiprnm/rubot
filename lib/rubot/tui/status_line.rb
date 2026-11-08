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
    #
    # A badge (auto mode) sits between them, painted in the theme's warning
    # colour and never truncated away: it is the one word on this row that says
    # the agent has stopped asking before it acts.
    class StatusLine < ::TUI::Component
      BADGE_STYLE = :warning

      attr_reader :spinner_idx

      def initialize
        super
        @spinner_idx = 0
        @left = ""
        @right = ""
        @badge = ""
      end

      def left=(text)
        @left = text.to_s
        self
      end

      def right=(text)
        @right = text.to_s
        self
      end

      def badge=(text)
        @badge = text.to_s
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
        badge = @badge.empty? ? "" : ::TUI::Text.truncate("#{@badge} ", [ width, 1 ].max)
        badge_w = ::TUI::Text.width(badge)
        right = @right.empty? ? "" : ::TUI::Text.truncate(" #{@right} ", width)
        right_w = ::TUI::Text.width(right)

        # The badge and the model block are reserved first; the metrics take
        # whatever is left and yield with an ellipsis.
        tail_w = badge_w + right_w
        avail = width - tail_w - 1
        left = avail.positive? ? ::TUI::Text.truncate(@left, avail) : ""
        left_w = ::TUI::Text.width(left)
        gap = [ width - left_w - tail_w, 0 ].max

        x = @rect.x
        canvas.put(x, @rect.y, left + (" " * gap), :dim)
        x += left_w + gap
        unless badge.empty?
          canvas.put(x, @rect.y, badge, BADGE_STYLE)
          x += badge_w
        end
        canvas.put(x, @rect.y, right, :dim) unless right.empty?
      end
    end
  end
end
