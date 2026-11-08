# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The conversation area: the scrolling log with the "jump to bottom" pill
    # floating over its bottom row. The pill is drawn on top of the log, so
    # showing it never reflows the conversation — it fills the last row,
    # centred on the screen, right above the working line and the prompt, and
    # only while the newest row is scrolled off screen.
    class LogPane < ::TUI::Component
      attr_reader :log, :button

      def initialize(log, button = JumpBottom.new)
        super()
        @log = log
        @button = button
        add(log)
        add(button)
      end

      def measure(max_w, max_h)
        @log.measure(max_w, max_h)
      end

      def layout(rect)
        @rect = rect
        @log.layout(rect)
        place_button
        self
      end

      def render(canvas)
        place_button
        @log.render(canvas)
        @button.render(canvas) if @button.visible?
        self
      end

      private

      # Re-placed on every frame: whether the log is at the bottom decides
      # both the pill's rect and whether it is on screen at all, and output
      # can push the newest row away between two keystrokes.
      def place_button
        @button.visible = !@log.bottom_visible?
        unless @button.visible
          @button.layout(::TUI::Rect.new(@rect.x, @rect.y, 0, 0))
          return
        end

        # Centred on the terminal, not on the pane: the window gutter and the
        # log's own inset sit on the left only, so a pill centred inside the
        # pane lands a couple of cells right of the middle of the screen.
        screen_w = @rect.x + @rect.w
        w = @button.measure([ screen_w - 2, 0 ].max, 1).first
        w = [ [ w, 2 ].max, [ screen_w, 0 ].max ].min
        x = ((screen_w - w) / 2).clamp(@rect.x, [ @rect.right - w, @rect.x ].max)
        @button.layout(::TUI::Rect.new(x, @rect.bottom, w, 1))
      end
    end
  end
end
