# frozen_string_literal: true
#
# MultiLine -- a prompt that supports hard newlines.
#
# Enter still emits SUBMIT (for the Shift+Enter-newline flow the app maps
# :shift_enter); the buffer is a full TextBuffer so the component tracks a
# cursor row/col. Lines longer than the laid-out width wrap onto as many
# rows as they need, and the widget renders the slice of rows around the
# cursor when the text exceeds the laid-out height.
#
#   edit = TUI::MultiLine.new(max_rows: 6)
#   edit.on(:submit) { |value| ... }     # Enter
#

require_relative '../component'
require_relative 'text_buffer'
require_relative 'input'

module TUI
  class MultiLine < Component
    MAX_ROWS = 8

    attr_reader :buffer

    def initialize(max_rows: MAX_ROWS, style: :text, cursor_style: :cursor, **opts)
      super(**opts)
      @buffer = TextBuffer.new('', multiline: true)
      @max_rows = max_rows
      @style = style
      @cursor_style = cursor_style
      @scroll_row = 0
    end

    def focusable?
      true
    end

    def value
      @buffer.value
    end

    def value=(text)
      @buffer.set(text)
      emit(Events::CHANGE, value)
    end

    def empty?
      @buffer.empty?
    end

    def measure(max_w, _max_h)
      [1, [[visual_rows([max_w, 1].max).size, @max_rows].min, 1].max]
    end

    def layout(rect)
      @rect = rect
      keep_cursor_visible
      self
    end

    def handle_key(key)
      changed = false
      case key.name
      when :shift_enter then @buffer.newline; changed = true
      when :enter       then emit(Events::SUBMIT, value)
      when :backspace   then @buffer.backspace; changed = true
      when :delete      then @buffer.delete; changed = true
      when :up          then @buffer.up
      when :down        then @buffer.down
      when :left        then @buffer.left
      when :right       then @buffer.right
      when :home        then @buffer.home
      when :end         then @buffer.end_of_line
      when :page_up
        ([@rect&.h || 8, 1].max).times { @buffer.up }
      when :page_down
        ([@rect&.h || 8, 1].max).times { @buffer.down }
      else
        return false unless key.printable? && !key.ctrl?('c')

        @buffer.insert(key.char)
        changed = true
      end

      keep_cursor_visible if changed
      emit(Events::CHANGE, value) if changed
      true
    end

    def render(canvas)
      canvas.fill(@rect.x, @rect.y, @rect.w, @rect.h, ' ', nil)

      width = content_width
      rows = visual_rows(width)
      height = [@rect.h, 1].max
      last = [@scroll_row + height - 1, rows.size - 1].min

      @scroll_row.upto(last) do |index|
        entry = rows[index]
        next if entry.nil?

        canvas.put(@rect.x, @rect.y + (index - @scroll_row), entry[:text], @style)
      end

      draw_cursor(canvas, rows)
      self
    end

    private

    def content_width
      [@rect ? @rect.w : 1, 1].max
    end

    # One entry per rendered row: the logical line it belongs to, the cell
    # in that line where the row starts, and the text to paint.
    def visual_rows(width)
      width = [width, 1].max
      rows = []

      @buffer.lines.each_with_index do |line, index|
        chunks = wrap_line(line, width)
        # A cursor sitting just past the last cell of a full row needs a row
        # of its own, or it would be drawn over the last glyph.
        chunks << { start: chunks.last[:start] + width, text: '' } if index == @buffer.row && extra_cursor_row?(chunks, width)
        chunks.each { |chunk| rows << chunk.merge(line: index) }
      end

      rows
    end

    def extra_cursor_row?(chunks, width)
      cell = @buffer.cursor_cell
      cell.positive? && cell >= chunks.last[:start] + width
    end

    # Split one logical line into rows of at most `width` cells, breaking at
    # the last space that fits so words are not cut in half. The break space
    # stays at the end of the row it was typed on, which keeps every cell of
    # the line accounted for and cursor mapping a simple lookup.
    def wrap_line(line, width)
      return [ { start: 0, text: '' } ] if line.empty?

      chars = line.each_char.map { |ch| [ ch, ::TUI::Term.codepoint_width(ch.ord) ] }
      rows = []
      first = 0
      start = 0

      while first < chars.length
        used = 0
        last = first
        space = nil

        while last < chars.length
          cell_w = chars[last][1]
          break if used + cell_w > width && last > first

          used += cell_w
          space = last if chars[last][0] == ' '
          last += 1
        end

        # `last` is the first character that does not fit. Back up to the
        # last space so the word moves to the next row whole, space included.
        if last < chars.length && space && space > first
          last = space + 1
          used = chars[first...last].sum { |char| char[1] }
        end

        rows << { start: start, text: chars[first...last].map(&:first).join }
        start += used
        first = last
      end

      rows
    end

    def cursor_row_index(rows)
      indices = []
      rows.each_with_index { |row, index| indices << index if row[:line] == @buffer.row }
      return 0 if indices.empty?

      cell = @buffer.cursor_cell
      indices.select { |index| rows[index][:start] <= cell }.last || indices.first
    end

    def draw_cursor(canvas, rows)
      index = cursor_row_index(rows)
      row = @rect.y + (index - @scroll_row)
      return if row < @rect.y || row > @rect.bottom

      ch = @buffer.current_line[@buffer.col].to_s
      canvas.put(@rect.x + (@buffer.cursor_cell - rows[index][:start]), row,
                 ch.empty? ? ' ' : ch, @cursor_style)
    end

    def keep_cursor_visible
      width = content_width
      rows = visual_rows(width)
      index = cursor_row_index(rows)
      height = [@rect&.h || @max_rows, 1].max

      @scroll_row = index if index < @scroll_row
      @scroll_row = index - height + 1 if index >= @scroll_row + height
      @scroll_row = [@scroll_row, [rows.size - height, 0].max].min
      @scroll_row = 0 if @scroll_row.negative?
    end
  end
end
