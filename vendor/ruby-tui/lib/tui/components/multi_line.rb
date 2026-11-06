# frozen_string_literal: true
#
# MultiLine -- a prompt that supports hard newlines.
#
# Enter still emits SUBMIT (for the Shift+Enter-newline flow the app maps
# :shift_enter); the buffer is a full TextBuffer so the component tracks a
# cursor row/col. The widget renders the slice of lines around the cursor
# when the text exceeds the laid-out height.
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

    def measure(_max_w, _max_h)
      [1, [[@buffer.lines.size, @max_rows].min, 1].max]
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

      each_visible_row do |index, row|
        line = @buffer.lines[index].to_s
        canvas.put(@rect.x, row, line, @style)
      end

      draw_cursor(canvas)
      self
    end

    private

    def each_visible_row
      height = [@rect.h, 1].max
      top = @scroll_row
      top.upto([top + height - 1, @buffer.lines.size - 1].min) do |index|
        yield index, @rect.y + (index - top)
      end
    end

    def draw_cursor(canvas)
      row = @rect.y + (@buffer.row - @scroll_row)
      return if row < @rect.y || row > @rect.bottom

      canvas.put(
        @rect.x + @buffer.cursor_cell,
        row,
        @buffer.current_line[@buffer.col].to_s[0].to_s.empty? ? ' ' : @buffer.current_line[@buffer.col],
        @cursor_style
      )
    end

    def keep_cursor_visible
      height = [@rect&.h || @max_rows, 1].max
      @scroll_row = @buffer.row if @buffer.row < @scroll_row
      @scroll_row = @buffer.row - height + 1 if @buffer.row >= @scroll_row + height
      @scroll_row = [@scroll_row, [@buffer.lines.size - height, 0].max].min
      @scroll_row = 0 if @scroll_row.negative?
    end
  end
end
