# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # Scrolling log of the conversation. Content is a list of entries; an
    # entry is a sequence of styled segments ([[text, style], ...]) wrapped
    # at the current view width. A "\\n" inside a segment's text is a hard
    # row break (multiline prompts, markdown output). Entries can be updated
    # in place (streaming responses), and the view auto-follows the bottom
    # unless the user has scrolled away from it.
    class LogView < ::TUI::Component
      # The scrollbar owns the last column of the view, so text wraps one
      # cell short of the right edge. Reserved even when no bar is drawn,
      # which keeps the wrap stable as output grows past the page height.
      SCROLLBAR_W = 1

      # A leading list/quote marker. Wrapped rows are indented by the
      # marker's width so continuation lines sit under the item text
      # instead of under the marker itself.
      LIST_PREFIX = /\A(\s*(?:[•▏]|[-*+]|\d+[.)])\s+)/.freeze

      # A segment may carry a third element, :fill, which paints its text
      # cell (" " for a background band, "─" for a rule) from where it
      # starts to the right edge of the view. It lets a renderer ask for a
      # full-width row without knowing the width ahead of time, so the band
      # stays full-width across a resize.
      FILL = :fill

      def initialize
        super
        @entries = []        # [[text, style], ...] per entry
        @keep_leading = []   # entries whose leading spaces are meaningful
        @indents = []        # left padding (cells) applied to every wrapped row
        @entry_lines = []    # wrapped rows per entry
        @lines = []          # flattened rows, cached for rendering
        @wrap_w = 0
        @scroll_y = 0
        @follow = true
      end

      # Append an entry. `segments` is a list of [text, style] pairs.
      # Returns the entry index so it can be updated later via #set_entry
      # while a response streams in.
      def add_entry(segments, keep_leading: false, indent: 0)
        @entries << segments
        @keep_leading << keep_leading
        @indents << indent
        wrap @entries.length - 1
        @lines = @entry_lines.flatten(1)
        follow_bottom if @follow
        @entries.length - 1
      end

      def entry_count
        @entries.length
      end

      # Cells available to a single row of content, scrollbar excluded.
      # Used to truncate lines that must not wrap (tool call rows). Zero
      # before the first layout.
      def content_width
        @rect ? text_width : 0
      end

      def last_blank?
        return false if @entries.empty?

        @entries[-1].all? { |(text, _style)| text.empty? }
      end

      def remove_last
        return if @entries.empty?

        @entries.pop
        @keep_leading.pop
        @indents.pop
        @entry_lines.pop
        @lines = @entry_lines.flatten(1)
        follow_bottom if @follow
        self
      end

      # Replace an entry in place; `segments` is a list of [text, style] pairs.
      def set_entry(index, segments, keep_leading: nil, indent: nil)
        return unless index && @entries[index]

        @entries[index] = segments
        @keep_leading[index] = keep_leading unless keep_leading.nil?
        @indents[index] = indent unless indent.nil?
        wrap index
        @lines = @entry_lines.flatten(1)
        follow_bottom if @follow
        self
      end

      # --- selection (drag to select, release copies via OSC 52) ---------

      attr_reader :sel

      def begin_selection(x, y)
        cx = x.clamp(@rect.x, @rect.right - 1)
        cy = y.clamp(@rect.y, @rect.bottom)
        @sel = { ax: cx, ay: cy, hx: cx, hy: cy }
        self
      end

      def extend_selection(x, y)
        return @sel unless @sel

        @sel[:hx] = x.clamp(@rect.x, @rect.right - 1)
        @sel[:hy] = y.clamp(@rect.y, @rect.bottom)
        @sel
      end

      def clear_selection
        @sel = nil
        self
      end

      def selection?
        !!@sel
      end

      # A press that was released without moving: a click, not a drag.
      def point_selection?
        !!@sel && @sel[:ax] == @sel[:hx] && @sel[:ay] == @sel[:hy]
      end

      # Plain text of the selection, one line per touched row. Only rows
      # the drag actually crossed are included, and each line is the text
      # from where the selection starts on that row to where it ends.
      def selection_text
        return nil unless @sel && @rect

        selection_spans.map { |(y, from, to)| text_between(y, from, to).rstrip }.join("\n")
      end

      # The rows and column ranges the selection covers. This is linear, the
      # way a terminal selects: the row where the drag started runs from the
      # start column to the right edge, the row where it ended runs from the
      # left edge to the end column, and the rows between span the full
      # width. A bounding box would give a rectangle instead -- highlighting
      # (and copying) whole columns the user never dragged over.
      def selection_spans
        return [] unless @sel && @rect

        ax, ay = @sel[:ax], @sel[:ay]
        hx, hy = @sel[:hx], @sel[:hy]

        return [ [ ay, [ ax, hx ].min, [ ax, hx ].max ] ] if ay == hy

        # Dragging up swaps which end is the anchor, but the top row always
        # starts at its own cursor and runs right, and the bottom row always
        # starts at the left edge and stops at its cursor.
        top_x, top_y, bottom_x, bottom_y =
          ay < hy ? [ ax, ay, hx, hy ] : [ hx, hy, ax, ay ]

        spans = [ [ top_y, top_x, @rect.right ] ]
        (top_y + 1...bottom_y).each { |y| spans << [ y, @rect.x, @rect.right ] }
        spans << [ bottom_y, @rect.x, bottom_x ]
        spans
      end

      # Drop entries; used by /new (the screen is wiped silently). `keep`
      # retains the first N entries — the banner — so a new session clears
      # the conversation without losing the heading.
      def clear(keep: 0)
        keep = [ [ keep, 0 ].max, @entries.length ].min
        @entries = @entries[0, keep] || []
        @keep_leading = @keep_leading[0, keep] || []
        @indents = @indents[0, keep] || []
        @entry_lines = @entry_lines[0, keep] || []
        @lines = @entry_lines.flatten(1)
        @scroll_y = 0
        @follow = true
        @sel = nil
        self
      end

      def scroll_by(delta)
        @follow = false
        @scroll_y = (@scroll_y + delta).clamp(0, [ @lines.size - @rect.h, 0 ].max)
        @follow = @scroll_y >= [ @lines.size - @rect.h, 0 ].max
        # The rows under the highlight just moved.
        clear_selection
        self
      end

      def measure(_max_w, _max_h)
        # Only matters for auto sizing; the REPL stacks it with flex(1).
        [ 10, 3 ]
      end

      def layout(rect)
        @rect = rect
        rewrap_all if rect.w != @wrap_w
        self
      end

      def render(canvas)
        @canvas = canvas
        canvas.fill(@rect.x, @rect.y, @rect.w, @rect.h, " ", nil)

        last = [ @scroll_y + @rect.h - 1, @lines.size - 1 ].min
        (@scroll_y..last).each do |i|
          row = @rect.y + (i - @scroll_y)
          x = @rect.x
          @lines[i].each do |text, style, mode|
            next if text.empty?

            if mode == FILL
              cells = @rect.right - x
              unit = ::TUI::Text.width(text)
              if cells.positive? && unit.positive?
                canvas.put(x, row, text * (cells / unit), style)
                x += cells
              end
              break
            end

            canvas.put(x, row, text, style)
            x += ::TUI::Text.width(text)
            break if x >= @rect.right
          end
        end

        paint_selection(canvas)
        draw_scrollbar(canvas) if @lines.size > @rect.h
        self
      end

      private

      def paint_selection(canvas)
        selection_spans.each do |(y, from, to)|
          canvas.overlay(from, y, [ to - from + 1, 1 ].max, :selection)
        end
      end

      # Text on screen row `y` between columns `from` and `to`, read from the
      # log's own wrapped lines rather than the composed canvas, so the
      # scrollbar, gutter padding and unpainted tail never reach the
      # clipboard.
      def text_between(y, from, to)
        line = @lines[y - @rect.y + @scroll_y]
        return "" unless line

        out = +""
        col = @rect.x
        line.each do |text, _style, mode|
          next if mode == FILL

          text.to_s.each_char do |ch|
            width = ::TUI::Text.width(ch)
            out << ch if width.positive? && col + width - 1 >= from && col <= to
            col += width
          end
        end
        out
      end

      # Cells available to text: everything but the scrollbar column.
      def text_width
        [ @rect.w - SCROLLBAR_W, 1 ].max
      end

      def wrap(index)
        indent = [ @indents[index].to_i, [ text_width - 1, 0 ].max ].min
        width = [ text_width - indent, 1 ].max
        lines = wrap_segments(@entries[index], width, keep_leading: @keep_leading[index])
        @entry_lines[index] = indent.positive? ? indent_lines(lines, indent) : lines
      end

      def rewrap_all
        @wrap_w = @rect.w
        @entry_lines = @entries.each_with_index.map do |entry, i|
          indent = [ @indents[i].to_i, [ text_width - 1, 0 ].max ].min
          width = [ text_width - indent, 1 ].max
          lines = wrap_segments(entry, width, keep_leading: @keep_leading[i])
          indent.positive? ? indent_lines(lines, indent) : lines
        end
        @lines = @entry_lines.flatten(1)
        @scroll_y = [ @lines.size - @rect.h, 0 ].max if @follow
      end

      # Pad every non-empty wrapped row, including soft-wrap continuations.
      def indent_lines(lines, indent)
        pad = " " * indent
        lines.map { |line| line.empty? ? line : [ [ pad, nil ] ] + line }
      end

      def wrap_segments(segments, width, keep_leading: false)
        # "\n" in segment text is a hard row break (multiline input,
        # markdown blocks). Split into hard lines first, so each one can
        # carry its own hanging indent.
        hard_lines = [ [] ]
        segments.each do |(text, style, mode)|
          text.to_s.split("\n", -1).each_with_index do |part, i|
            hard_lines << [] if i.positive?
            hard_lines.last << [ part, style, mode ] unless part.empty?
          end
        end

        hard_lines.flat_map do |line|
          wrap_hard_line(line, width, keep_leading: keep_leading)
        end
      end

      def wrap_hard_line(segments, width, keep_leading: false)
        hang = hanging_indent(segments, keep_leading: keep_leading)
        hang = [ hang, [ width - 1, 0 ].max ].min
        prefix = hang.positive? ? [ [ " " * hang, nil ] ] : []

        lines = [ [] ]
        used = 0
        at_start = true

        new_row = lambda do
          lines << prefix.dup
          used = hang
          at_start = true
        end

        segments.each do |(text, style, mode)|
          if mode == FILL
            lines.last << [ text, style, FILL ] unless text.to_s.empty?
            used = width
            at_start = false
            break
          end

          text.to_s.split(/(?<= )|(?= )/).each do |token|
            if token.strip.empty?
              space_w = ::TUI::Text.width(token)
              next if at_start && !keep_leading
              next if used + space_w > width

              lines.last << [ token, style ]
              used += space_w
              next
            end

            token_w = ::TUI::Text.width(token)
            new_row.call if used + token_w > width && used.positive?

            if token_w > width
              used = push_hard_broken(lines, token, style, width, prefix)
            else
              lines.last << [ token, style ]
              used += token_w
            end
            at_start = false
          end
        end

        lines
      end

      # Width of a leading marker like "  • " or "  12. ". Leading spaces
      # only count when they will actually be rendered.
      def hanging_indent(segments, keep_leading:)
        head = segments.map { |(text, _style)| text.to_s }.join
        head = head.lstrip unless keep_leading
        match = head.match(LIST_PREFIX)
        match ? ::TUI::Text.width(match[1]) : 0
      end

      # Break a token that does not fit on any line, cell by cell.
      def push_hard_broken(lines, token, style, width, prefix)
        token.to_s.each_char do |ch|
          cw = ::TUI::Text.width(ch)
          used = line_width(lines.last)
          if used + cw > width
            lines << prefix.dup
          end
          lines.last << [ ch, style ]
        end
        line_width(lines.last)
      end

      def line_width(line)
        line.sum { |(text, _style, mode)| mode == FILL ? 0 : ::TUI::Text.width(text.to_s) }
      end

      def follow_bottom
        before = @scroll_y
        @scroll_y = [ @lines.size - @rect.h, 0 ].max
        # New output pushes the highlighted rows up the screen.
        @sel = nil if @sel && @scroll_y != before
      end

      def draw_scrollbar(canvas)
        content_h = @lines.size
        page_h = [ @rect.h, 1 ].max
        bar_h = [ page_h * page_h / content_h, 1 ].max
        max_scroll = [ content_h - page_h, 1 ].max
        y0 = (@scroll_y * (page_h - bar_h) / max_scroll).round
        (@rect.y + y0..[ @rect.y + y0 + bar_h - 1, @rect.bottom ].min).each do |y|
          canvas.put(@rect.right - 1, y, "▐", :muted)
        end
      end
    end
  end
end
