# frozen_string_literal: true
#
# Layout::Padding -- reserves gutters around a single child.
#
#   padded = Layout::Padding.new(stack, left: 2)
#   p = Layout::Padding.new(view, top: 1, bottom: 1)
#

require_relative '../component'

module TUI
  module Layout
    class Padding < Component
      attr_reader :child

      def initialize(child, left: 0, right: 0, top: 0, bottom: 0, **opts)
        super(**opts)
        raise ArgumentError, 'needs a child' unless child

        @left = left
        @right = right
        @top = top
        @bottom = bottom
        @child = child
        add(child)
      end

      def measure(max_w, max_h)
        inset_h = @left + @right
        inset_v = @top + @bottom
        mw, mh = child.measure([max_w - inset_h, 0].max, [max_h - inset_v, 0].max)
        [[mw + inset_h, max_w].min, [mh + inset_v, max_h].min]
      end

      def layout(rect)
        @rect = rect
        child.layout(Rect.new(
                       rect.x + @left,
                       rect.y + @top,
                       [rect.w - @left - @right, 0].max,
                       [rect.h - @top - @bottom, 0].max
                     ))
        self
      end

      def render(canvas)
        @child.render(canvas)
        self
      end

      def clipped_children?
        false
      end
    end
  end
end
