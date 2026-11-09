# frozen_string_literal: true

require "cgi"
require "erb"

module Rubot
  module Web
    # Minimal markdown for chat bubbles. Everything is HTML-escaped first, so
    # the transform below can only ever emit the tags it writes itself.
    module Format
      # A private-use character, not NUL: `String#strip` removes NUL, which
      # would quietly turn a fenced code block back into a paragraph line.
      PLACEHOLDER = "\uE000"

      module_function

      # Line-oriented, because a list is a run of lines and a lone newline is
      # just a line break inside one. Everything is escaped before this runs,
      # so the only tags that can appear are the ones written here.
      def markdown(text)
        blocks = []
        source = CGI.escapeHTML(text.to_s)

        source = source.gsub(/```[a-zA-Z0-9+#-]*\n(.*?)```/m) do
          blocks << %(<pre class="code"><code>#{Regexp.last_match(1)}</code></pre>)
          "#{PLACEHOLDER}#{blocks.size - 1}#{PLACEHOLDER}"
        end

        # An unterminated fence is normal mid-stream: show the tail as code.
        source = source.gsub(/```[a-zA-Z0-9+#-]*\n(.*)\z/m) do
          blocks << %(<pre class="code streaming"><code>#{Regexp.last_match(1)}</code></pre>)
          "#{PLACEHOLDER}#{blocks.size - 1}#{PLACEHOLDER}"
        end

        paragraphs = []
        paragraph = []
        list = nil

        flush_paragraph = lambda do
          next if paragraph.empty?

          paragraphs << paragraph.map { |line| inline(line) }.join("<br>")
          paragraph.clear
        end

        flush_list = lambda do
          next if list.nil?

          paragraphs << "<#{list[:tag]}>#{list[:items].join}</#{list[:tag]}>"
          list = nil
        end

        # A list ends when a line that is not one of its items arrives; the
        # two list kinds do not continue each other.
        open_list = lambda do |tag, item|
          flush_paragraph.call
          flush_list.call if list && list[:tag] != tag
          list ||= { tag: tag, items: [] }
          list[:items] << "<li>#{inline(item)}</li>"
        end

        lines = source.lines(chomp: true)
        i = 0
        while i < lines.length
          line = lines[i]
          stripped = line.strip

          if stripped.empty?
            flush_paragraph.call
            flush_list.call
          elsif (block = stripped[/\A#{PLACEHOLDER}(\d+)#{PLACEHOLDER}\z/, 1])
            flush_paragraph.call
            flush_list.call
            paragraphs << blocks[block.to_i]
          elsif (table = table_at(lines, i))
            # A table is its own block: the paragraph and the list before it
            # are finished by it, exactly as a fenced code block would.
            flush_paragraph.call
            flush_list.call
            paragraphs << table[:html]
            i = table[:next]
            next
          elsif (item = stripped[/\A[-*+] +(.*)\z/, 1])
            open_list.call("ul", item)
          elsif (item = stripped[/\A\d+[.)] +(.*)\z/, 1])
            open_list.call("ol", item)
          elsif (quote = stripped[/\A&gt; ?(.*)\z/, 1])
            flush_paragraph.call
            flush_list.call
            paragraphs << "<blockquote>#{inline(quote)}</blockquote>"
          else
            flush_list.call
            paragraph << line
          end

          i += 1
        end

        flush_paragraph.call
        flush_list.call

        paragraphs.join("\n")
      end

      # --- tables ---------------------------------------------------------
      #
      # The same rule the TUI uses to recognise a pipe table: a header line
      # with a pipe on either side of something, then a separator whose every
      # cell is dashes with optional alignment colons. Rows continue while the
      # lines keep having pipes. Mid-stream this degrades to plain text, since
      # the header alone is a paragraph until its separator arrives.
      SEPARATOR_CELL = /\A\s*:?-+(?::-?-+)*:?\s*\z/

      def table_line?(line)
        text = line.to_s
        return false unless text.include?("|")

        # A row is any line with a pipe that carries at least one non-empty
        # cell. Requiring text on both sides of a pipe ("| a |") would drop
        # single-column tables and, worse, the "| 1 |" row of a table whose
        # header has more columns — the row would leak into the paragraph
        # below it.
        split_row(text).any? { |cell| !cell.empty? }
      end

      def table_separator?(line)
        cells = split_row(line.to_s)
        cells.any? && cells.all? { |cell| cell.match?(SEPARATOR_CELL) }
      end

      # Cells are split on a pipe that is not escaped, so a literal "\|" stays
      # inside the cell it was written in instead of starting a new one.
      def split_row(line)
        line.strip.sub(/\A\|/, "").sub(/\|\s*\z/, "").split(/(?<!\\)\|/).map do |cell|
          cell.strip.gsub("\\|", "|")
        end
      end

      def table_at(lines, start)
        return nil unless table_line?(lines[start])

        separator = lines[start + 1]
        return nil unless separator && table_separator?(separator)

        rows = [ split_row(lines[start]) ]
        cursor = start + 2
        while cursor < lines.length && table_line?(lines[cursor])
          rows << split_row(lines[cursor])
          cursor += 1
        end

        { html: render_table(rows, split_row(separator)), next: cursor }
      end

      def render_table(rows, separator)
        cols = rows.map(&:length).max.to_i
        aligns = (0...cols).map { |c| alignment(separator[c]) }
        header = rows.first
        body = rows.drop(1)

        out = [ %(<div class="md-table-wrap"><table class="md-table">), "<thead>" ]
        out << table_row("th", header, cols, aligns)
        out << "</thead>"
        out << "<tbody>"
        body.each { |row| out << table_row("td", row, cols, aligns) }
        out << "</tbody>"
        out << "</table></div>"
        out.join
      end

      def table_row(tag, cells, cols, aligns)
        parts = (0...cols).map do |c|
          style = aligns[c] ? %( style="text-align:#{aligns[c]}") : ""
          %(<#{tag}#{style}>#{inline(cells[c].to_s)}</#{tag}>)
        end
        "<tr>#{parts.join}</tr>"
      end

      # ":---:" centres, "---:" right-aligns, ":---" and "---" leave the
      # column as it is. Alignment is the one table detail HTML can honour and
      # a terminal cannot, so it is honoured here.
      def alignment(cell)
        cell = cell.to_s.strip
        return nil unless cell.include?("-")

        left = cell.start_with?(":")
        right = cell.end_with?(":")
        return "center" if left && right
        return "left" if left
        return "right" if right

        nil
      end

      # Inline spans. Escaped input only, so these are safe to emit as-is.
      def inline(text)
        out = text.gsub(/`([^`\n]+)`/) { %(<code>#{Regexp.last_match(1)}</code>) }
        out.gsub(/\*\*([^*\n]+)\*\*/) { %(<strong>#{Regexp.last_match(1)}</strong>) }
      end

      # Same shape as the TUI's, so a duration reads the same in both channels:
      # "8s", "1m 5s", "1h 2m".
      def duration(seconds)
        total = seconds.to_i
        hours, rest = total.divmod(3600)
        minutes, secs = rest.divmod(60)

        parts = []
        parts << "#{hours}h" if hours.positive?
        parts << "#{minutes}m" if minutes.positive? || hours.positive?
        parts << "#{secs}s" if secs.positive? || parts.empty?
        parts.join(" ")
      end
    end

    # Tiny ERB renderer. Views live next to the channel, locals become methods
    # on the rendering scope, and compiled templates are cached per process.
    module View
      ROOT = File.expand_path("views", __dir__)

      ICONS = {
        running: "◐",
        ok: "✓",
        failed: "✗",
        unknown: "·"
      }.freeze

      # The status row is drawn with inline SVG rather than glyphs: Martian
      # Mono carries only ASCII and a handful of symbols, so a symbol like ⟳ or
      # ⊙ was silently borrowed from whatever fallback font the reader's
      # system happened to supply — differently on every machine.
      #
      # 10×10, stroke only, currentColor, so they inherit the row's colour and
      # none of them carries a fill of its own.
      SVG_ICONS = {
        cost: %(<circle cx="5" cy="5" r="3.4"/>) +
              %(<path d="M5 2.6v4.8"/>),
        cache: %(<path d="M2 5a3 3 0 0 1 5.1-1.1"/>) +
               %(<path d="M7.4 1.9v2.2H5.2"/>) +
               %(<path d="M8 5a3 3 0 0 1-5.1 1.1"/>) +
               %(<path d="M2.6 8.1V5.9h2.2"/>),
        context: %(<path d="M1.6 7.4V5.2"/>) +
                 %(<path d="M5 7.4V2"/> ) +
                 %(<path d="M8.4 7.4V3.6"/>)
      }.freeze

      class Scope
        def initialize(locals)
          locals.each { |key, value| define_singleton_method(key) { value } }
        end

        def h(text)
          CGI.escapeHTML(text.to_s)
        end

        def fmt(text)
          Format.markdown(text)
        end

        def icon(state)
          ICONS.fetch(state, "◐")
        end

        # A 10px stroked mark. Decorative: the row's title carries the meaning,
        # so the drawing is hidden from a screen reader.
        def usage_icon(name)
          body = SVG_ICONS.fetch(name, "")
          %(<svg class="metric-icon" viewBox="0 0 10 10" width="10" height="10" ) +
            %(fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" ) +
            %(stroke-linejoin="round" aria-hidden="true" focusable="false">#{body}</svg>)
        end

        def dur(seconds)
          Format.duration(seconds)
        end

        # The turn body is rendered from Ruby rather than through a nested
        # partial call in ERB, so the template only ever says "draw the
        # timeline up to here".
        def timeline(turn)
          View.turn_body(turn)
        end

        def context
          binding
        end
      end

      @cache = {}
      @mutex = Mutex.new

      class << self
        def render(name, locals = {})
          template = compiled(name)
          template.result(Scope.new(locals).context)
        end

        # The body of a live turn: everything it has done, plus the row that
        # says it is not done. The first render and every later one go through
        # here, so the row cannot go missing because one of them forgot it.
        def turn_body(turn)
          render("_timeline", items: turn.items) + render("_working", since: turn.epoch)
        end

        private

        def compiled(name)
          @mutex.synchronize do
            @cache[name] ||= begin
              path = File.join(ROOT, "#{name}.erb")
              ERB.new(File.read(path), trim_mode: "-")
            end
          end
        end
      end
    end
  end
end
