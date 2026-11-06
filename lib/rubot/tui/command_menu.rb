# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The slash-command palette drawn just above the prompt while the buffer
    # is a bare /command prefix. It is deliberately not focusable: the prompt
    # keeps the keyboard, and PromptInput reports which row is highlighted,
    # so ↑/↓ and enter never leave the input box.
    class CommandMenu < ::TUI::Component
      MAX_ROWS = 8
      MARKER = "❯"
      PAD = 1

      def initialize(commands = {})
        super()
        @commands = commands
        @items = []
        @index = 0
        @name_width = 0
        self.visible = false
      end

      # items: the matching command names, index: the highlighted one.
      def set_items(items, index)
        @items = Array(items)
        @index = index.to_i
        @name_width = @items.map { |item| ::TUI::Text.width(item) }.max.to_i
        self.visible = !@items.empty?
        self
      end

      def items
        @items
      end

      def selected
        @items[@index]
      end

      def measure(max_w, max_h)
        return [ 0, 0 ] if @items.empty?

        [ [ max_w, 1 ].min, [ [ @items.length, MAX_ROWS ].min, max_h ].min ]
      end

      def render(canvas)
        return self if @items.empty? || @rect.h <= 0

        rows = [ @rect.h, @items.length, MAX_ROWS ].min
        start = scroll_start(rows)
        canvas.fill(@rect.x, @rect.y, @rect.w, @rect.h, " ", nil)

        rows.times do |i|
          index = start + i
          break if index >= @items.length

          draw_row(canvas, @rect.y + i, index)
        end
        self
      end

      private

      # Keep the highlighted command on screen when the list is taller than
      # the eight rows it is allowed to use.
      def scroll_start(rows)
        return 0 if @items.length <= rows

        top = [ @index - rows + 1, 0 ].max
        [ top, @items.length - rows ].min
      end

      def draw_row(canvas, y, index)
        selected = index == @index
        prefix = selected ? "#{MARKER} " : "  "
        name = @items[index]

        canvas.fill(@rect.x, y, @rect.w, 1, " ", :selection) if selected
        x = @rect.x + PAD
        name_style = selected ? :selection : :accent
        canvas.put(x, y, "#{prefix}#{::TUI::Text.pad(name, @name_width)}", name_style)

        description = @commands[name].to_s
        return if description.empty?

        desc_x = x + ::TUI::Text.width(prefix) + @name_width + 2
        width = @rect.right - desc_x + 1
        return if width <= 1

        canvas.put(desc_x, y, ::TUI::Text.truncate(description, width),
                   selected ? :selection : :dim)
      end
    end
  end
end
