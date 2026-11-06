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

      # Cells available to a single row of content. Used to truncate lines
      # that must not wrap (tool call rows). Zero before the first layout.
      def content_width
        @rect ? @rect.w : 0
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

      # Plain text of the selected cells, read back from the composed
      # canvas of the frame that drew the highlight.
      def selection_text
        return nil unless @sel && @canvas

        x = @sel[:ax]..@sel[:hx]
        ys = @sel[:ay]..@sel[:hy]
        @canvas.excerpt(x.min, ys.min, x.max, ys.max)
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
        self
      end

      def scroll_by(delta)
        @follow = false
        @scroll_y = (@scroll_y + delta).clamp(0, [ @lines.size - @rect.h, 0 ].max)
        @follow = @scroll_y >= [ @lines.size - @rect.h, 0 ].max
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
          @lines[i].each do |text, style|
            next if text.empty?

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
        return unless selection?

        ys = [ @sel[:ay], @sel[:hy] ].min..[ @sel[:ay], @sel[:hy] ].max
        x_min = [ @sel[:ax], @sel[:hx] ].min
        x_max = [ @sel[:ax], @sel[:hx] ].max
        ys.each do |y|
          canvas.overlay(x_min, y, [ x_max - x_min + 1, 1 ].max, :selection)
        end
      end

      def wrap(index)
        indent = [ @indents[index].to_i, [ @rect.w - 1, 0 ].max ].min
        width = [ @rect.w - indent, 1 ].max
        lines = wrap_segments(@entries[index], width, keep_leading: @keep_leading[index])
        @entry_lines[index] = indent.positive? ? indent_lines(lines, indent) : lines
      end

      def rewrap_all
        @wrap_w = @rect.w
        @entry_lines = @entries.each_with_index.map do |entry, i|
          indent = [ @indents[i].to_i, [ @rect.w - 1, 0 ].max ].min
          width = [ @rect.w - indent, 1 ].max
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
        lines = [ [] ]
        used = 0

        segments.each do |(text, style)|
          # "\n" in segment text is a hard row break (multiline input,
          # markdown blocks).
          parts = text.to_s.split("\n", -1)
          parts.each_with_index do |part, i|
            if i.positive?
              lines << []
              used = 0
              next if part.empty?
            end

            part.split(/(?<= )|(?= )/).each do |token|
              if token.strip.empty?
                space_w = ::TUI::Text.width(token)
                next if used.zero? && !keep_leading
                next if used + space_w > width

                lines.last << [ token, style ]
                used += space_w
                next
              end

              token_w = ::TUI::Text.width(token)
              if used + token_w > width && used.positive?
                lines << []
                used = 0
              end

              if token_w > width
                used = push_hard_broken(lines, token, style, width)
              else
                lines.last << [ token, style ]
                used += token_w
              end
            end
          end
        end

        lines
      end

      # Break a token that does not fit on any line, cell by cell.
      def push_hard_broken(lines, token, style, width)
        token.to_s.each_char do |ch|
          cw = ::TUI::Text.width(ch)
          used = ::TUI::Text.width(lines.last.map(&:first).join)
          lines << [] if used + cw > width
          lines.last << [ ch, style ]
        end
        ::TUI::Text.width(lines.last.map(&:first).join)
      end

      def follow_bottom
        @scroll_y = [ @lines.size - @rect.h, 0 ].max
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
