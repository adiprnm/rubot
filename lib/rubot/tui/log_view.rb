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

      # A right-pinned tail keeps one blank column between itself and the
      # scrollbar column, so the duration and the bar never fuse into one
      # blob when both are on screen.
      TAIL_GAP = 1

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
        @hangs = []          # hanging indent for the rows after the first
        @tails = []          # right-pinned segment list per entry, or nil
        @nowraps = []        # entries kept to one row, overflow cut to a …
        @entry_lines = []    # wrapped rows per entry
        @lines = []          # flattened rows, cached for rendering
        @line_tails = []     # right-pinned tail per flattened row, or nil
        @wrap_w = 0
        @scroll_y = 0
        @follow = true
        @dragging_bar = nil
        @bar_grab = 0
      end

      # Append an entry. `segments` is a list of [text, style] pairs.
      # `hang` indents every row of the entry except the first, which is how
      # a prompt echo keeps its continuation lines under the "❯ " marker.
      # `tail` is a short segment list (a duration, a state) pinned to the
      # right edge of the entry's last row: it is drawn after the content, in
      # the text columns the scrollbar leaves free, and the content wraps one
      # cell short of it so nothing is ever written underneath.
      # `nowrap` keeps the entry on a single row, cutting the overflow to an
      # ellipsis instead. Tool rows use it: a call is one line in the
      # transcript, however long its arguments are.
      # Returns the entry index so it can be updated later via #set_entry
      # while a response streams in.
      def add_entry(segments, keep_leading: false, indent: 0, hang: 0, tail: nil, nowrap: false)
        @entries << segments
        @keep_leading << keep_leading
        @indents << indent
        @hangs << hang
        @tails << tail
        @nowraps << nowrap
        wrap @entries.length - 1
        refresh_lines
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

      # The segments of one entry, nil when the index is out of range.
      def entry_at(index)
        return nil if index.nil? || index.negative?

        @entries[index]
      end

      def remove_last
        return if @entries.empty?

        @entries.pop
        @keep_leading.pop
        @indents.pop
        @hangs.pop
        @tails.pop
        @nowraps.pop
        @entry_lines.pop
        refresh_lines
        follow_bottom if @follow
        self
      end

      # Drop an entry that is not the last one, for a row the view opened and
      # now has to take back after output landed below it. Removing the last
      # entry is a pop (see #remove_last); this is the general form.
      def remove_entry(index)
        return unless @entries[index]

        @entries.delete_at(index)
        @keep_leading.delete_at(index)
        @indents.delete_at(index)
        @hangs.delete_at(index)
        @tails.delete_at(index)
        @nowraps.delete_at(index)
        @entry_lines.delete_at(index)
        refresh_lines
        follow_bottom if @follow
        self
      end

      # Replace an entry in place; `segments` is a list of [text, style] pairs.
      # `tail: false` clears a tail set before, `tail: nil` leaves it alone.
      def set_entry(index, segments, keep_leading: nil, indent: nil, hang: nil, tail: false, nowrap: nil)
        return unless index && @entries[index]

        @entries[index] = segments
        @keep_leading[index] = keep_leading unless keep_leading.nil?
        @indents[index] = indent unless indent.nil?
        @hangs[index] = hang unless hang.nil?
        @tails[index] = tail unless tail == false
        @nowraps[index] = nowrap unless nowrap.nil?
        wrap index
        refresh_lines
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

      # --- scrollbar (drag the bar with the mouse to scroll) -------------

      # The bar is drawn only when the content outgrows the page; below that
      # there is nothing to grab, so a press on the last column still
      # selects text like any other cell.
      def scrollbar_visible?
        return false unless @rect

        @lines.size > @rect.h
      end

      def scrollbar_at?(x, y)
        return false unless scrollbar_visible?
        return false unless x == @rect.right

        y >= @rect.y && y <= @rect.bottom
      end

      # Grabbing the bar turns the drag into a scroll instead of a selection.
      # A press on the thumb keeps the grab point under the cursor; a press
      # on the track next to it centres the thumb there and jumps, which is
      # what a click on a scrollbar is expected to do.
      def begin_scrollbar_drag(x, y)
        return self unless scrollbar_at?(x, y)

        _page_h, bar_h, = scrollbar_metrics
        grab = y - (@rect.y + scrollbar_thumb_top)
        grab = bar_h / 2 unless grab.between?(0, bar_h - 1)

        @dragging_bar = true
        @bar_grab = grab
        @sel = nil
        scroll_to_bar(y - grab)
        self
      end

      def scrollbar_dragging?
        !!@dragging_bar
      end

      def drag_scrollbar(y)
        return self unless @dragging_bar

        scroll_to_bar(y - @bar_grab)
        self
      end

      def end_scrollbar_drag
        @dragging_bar = nil
        @bar_grab = nil
        self
      end

      # Drop entries; used by /new (the screen is wiped silently). `keep`
      # retains the first N entries — the banner — so a new session clears
      # the conversation without losing the heading.
      def clear(keep: 0)
        keep = [ [ keep, 0 ].max, @entries.length ].min
        @entries = @entries[0, keep] || []
        @keep_leading = @keep_leading[0, keep] || []
        @indents = @indents[0, keep] || []
        @hangs = @hangs[0, keep] || []
        @tails = @tails[0, keep] || []
        @nowraps = @nowraps[0, keep] || []
        @entry_lines = @entry_lines[0, keep] || []
        refresh_lines
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

          paint_tail(canvas, i, row)
        end

        paint_selection(canvas)
        draw_scrollbar(canvas) if @lines.size > @rect.h
        self
      end

      private

      # A pinned tail (a tool call's duration) is drawn last, right-aligned in
      # the text columns and one cell clear of the scrollbar column, so the
      # bar can never sit on top of it and the two characters never fuse. The
      # content of the row was wrapped that much narrower, so a long summary
      # is broken before it reaches the tail instead of running underneath it.
      def paint_tail(canvas, index, row)
        tail = @line_tails[index]
        return if tail.nil? || tail.empty?

        width = ::TUI::Text.width(tail.map { |(text, _style)| text.to_s }.join(""))
        x = @rect.x + text_width - width - TAIL_GAP
        return if x < @rect.x

        tail.each do |text, style|
          canvas.put(x, row, text.to_s, style)
          x += ::TUI::Text.width(text.to_s)
        end
      end

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

      # Flatten the wrapped entries into the rows the renderer walks, and
      # remember which row carries a pinned tail (the last row of an entry
      # that has one). One pass keeps the two arrays in step; the tail is
      # aligned at render time, so a resize needs no bookkeeping here.
      def refresh_lines
        @lines = []
        @line_tails = []
        @entry_lines.each_with_index do |rows, index|
          tail = @tails[index]
          rows.each_with_index do |row, row_index|
            @lines << row
            @line_tails << (tail && row_index == rows.length - 1 ? tail : nil)
          end
        end
      end

      def wrap(index)
        indent = [ @indents[index].to_i, [ text_width - 1, 0 ].max ].min
        width = [ text_width - indent - tail_reserve(@tails[index]), 1 ].max
        lines = if @nowraps[index]
          [ truncate_row(@entries[index], width) ]
        else
          wrap_segments(@entries[index], width, keep_leading: @keep_leading[index], hang: hang_for(index, width))
        end
        @entry_lines[index] = indent.positive? ? indent_lines(lines, indent) : lines
      end

      def rewrap_all
        @wrap_w = @rect.w
        @entry_lines = @entries.each_with_index.map do |entry, i|
          indent = [ @indents[i].to_i, [ text_width - 1, 0 ].max ].min
          width = [ text_width - indent - tail_reserve(@tails[i]), 1 ].max
          lines = if @nowraps[i]
            [ truncate_row(entry, width) ]
          else
            wrap_segments(entry, width, keep_leading: @keep_leading[i], hang: hang_for(i, width))
          end
          indent.positive? ? indent_lines(lines, indent) : lines
        end
        refresh_lines
        @scroll_y = [ @lines.size - @rect.h, 0 ].max if @follow
      end

      # One row, cut to `width` cells with a trailing ellipsis. Used by tool
      # rows, where a long argument list must never push the row onto a
      # second line and away from the clock at its end.
      def truncate_row(segments, width)
        cells = segments.flat_map do |(text, style, _mode)|
          text.to_s.each_char.map { |ch| [ ch, style ] }
        end
        return segments if cells.size <= width

        kept = []
        used = 0
        cells.each do |(ch, style)|
          w = ::TUI::Text.width(ch)
          break if used + w > width - 1

          kept << [ ch, style ]
          used += w
        end
        style = cells[kept.size] ? cells[kept.size][1] : nil
        rebuild_segments(kept) + [ [ "…", style ] ]
      end

      # Regroup a run of cells back into [text, style] segments, so the
      # renderer still paints one colour per stretch.
      def rebuild_segments(cells)
        cells.chunk_while { |(_, a), (_, b)| a == b }.map do |run|
          [ run.map(&:first).join, run.first[1] ]
        end
      end

      # Cells kept free on the right for a pinned tail: its own width, the
      # blank cell that clears the scrollbar, and one more so the content
      # stops a cell short of the tail instead of touching it.
      def tail_reserve(tail)
        return 0 if tail.nil? || tail.empty?

        ::TUI::Text.width(tail.map { |(text, _style)| text.to_s }.join) + TAIL_GAP + 1
      end

      # A hanging indent must leave at least one cell of content, or a long
      # marker would wrap the row into nothing.
      def hang_for(index, width)
        [ @hangs[index].to_i, [ width - 1, 0 ].max ].min
      end

      # Pad every non-empty wrapped row, including soft-wrap continuations.
      def indent_lines(lines, indent)
        pad = " " * indent
        lines.map { |line| line.empty? ? line : [ [ pad, nil ] ] + line }
      end

      def wrap_segments(segments, width, keep_leading: false, hang: 0)
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

        hard_lines.each_with_index.flat_map do |line, index|
          # The entry's own hang (a prompt echo) skips the entry's first row,
          # where the "❯ " marker sits, and covers every later one.
          wrap_hard_line(line, width, keep_leading: keep_leading, hang: hang,
                                      continuation: !index.zero?)
        end
      end

      # `hang` is the entry's hanging indent and only reaches rows that come
      # after its first one. A row a soft wrap produced takes the wider of
      # that and the row's own list marker, so a wrapped bullet stays under
      # its item text.
      def wrap_hard_line(segments, width, keep_leading: false, hang: 0, continuation: false)
        limit = [ width - 1, 0 ].max
        own = [ hanging_indent(segments, keep_leading: keep_leading), limit ].min
        wrap_indent = [ own, [ hang, limit ].min ].max
        lead_indent = continuation ? [ hang, limit ].min : 0
        prefix = wrap_indent.positive? ? [ [ " " * wrap_indent, nil ] ] : []

        lines = [ lead_indent.positive? ? [ [ " " * lead_indent, nil ] ] : [] ]
        used = lead_indent
        at_start = true

        # A soft-wrapped row starts under the hanging indent, so the cells
        # the prefix takes are already spoken for: counting from `hang`
        # instead made every continuation row overflow by the marker width
        # and lose its last characters off the right edge.
        new_row = lambda do
          lines << prefix.dup
          used = wrap_indent
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

            # Compare against what is left on the current row, not against
            # the full width: a prefixed row has that much less to give.
            if token_w > width - line_width(lines.last)
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
        _page_h, bar_h, = scrollbar_metrics
        y0 = scrollbar_thumb_top
        # Brighter while held, so the grab has feedback on screen.
        style = @dragging_bar ? :thumb : :muted
        (@rect.y + y0..[ @rect.y + y0 + bar_h - 1, @rect.bottom ].min).each do |y|
          # The bar owns the rect's last column. Text is wrapped one cell
          # narrower (see #text_width), so this is the only cell it can take.
          canvas.put(@rect.right, y, "▐", style)
        end
      end

      # Page height, thumb height, thumb travel and the largest scroll
      # offset, in one place: the bar is drawn, hit-tested and dragged from
      # these numbers, so a press on the thumb never jumps under the cursor.
      def scrollbar_metrics
        content_h = @lines.size
        page_h = [ @rect.h, 1 ].max
        bar_h = [ page_h * page_h / content_h, 1 ].max
        [ page_h, bar_h, [ page_h - bar_h, 0 ].max, [ content_h - page_h, 0 ].max ]
      end

      # Rows from the top of the view to the top of the thumb.
      def scrollbar_thumb_top
        _page_h, _bar_h, travel, max_scroll = scrollbar_metrics
        return 0 if travel.zero? || max_scroll.zero?

        (@scroll_y * travel / max_scroll).round
      end

      # Inverse of #scrollbar_thumb_top: scroll so the thumb sits at
      # `thumb_top` rows below the top of the view.
      def scroll_to_bar(thumb_top)
        _page_h, _bar_h, travel, max_scroll = scrollbar_metrics
        offset = thumb_top.clamp(0, travel)
        @scroll_y = travel.zero? ? 0 : (offset.to_f * max_scroll / travel).round
        @follow = @scroll_y >= max_scroll
        # The rows under the highlight just moved.
        clear_selection
        self
      end
    end
  end
end
