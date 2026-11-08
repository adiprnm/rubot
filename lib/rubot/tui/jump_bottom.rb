# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The pill that floats over the bottom-right corner of the conversation
    # while the newest row sits below the viewport. Clicking it jumps back to
    # the bottom. It is painted on top of the log rather than stacked under
    # it, so it takes no rows of its own and the layout never shifts when it
    # appears; the log drives its visibility (see LogPane).
    class JumpBottom < ::TUI::Component
      LABEL = "↓ jump to bottom"
      # A narrow terminal keeps the arrow: the pill is a corner, not a page.
      SHORT = "↓"
      PAD = 1

      def initialize
        super()
        self.visible = false
      end

      def measure(max_w, _max_h)
        [ [ ::TUI::Text.width(LABEL) + PAD * 2, max_w ].min, 1 ]
      end

      # A press inside the pill jumps instead of selecting text.
      def hit?(x, y)
        visible? && @rect.contains?(x, y)
      end

      def render(canvas)
        return self if @rect.empty?

        canvas.fill(@rect.x, @rect.y, @rect.w, 1, " ", :selection)
        label = label_for(@rect.w)
        x = @rect.x + [ (@rect.w - ::TUI::Text.width(label)) / 2, 0 ].max
        canvas.put(x, @rect.y, label, :selection)
        self
      end

      private

      # The label the pill has room for, padding included.
      def label_for(width)
        return LABEL if ::TUI::Text.width(LABEL) + PAD * 2 <= width

        SHORT
      end
    end
  end
end
