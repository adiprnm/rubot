# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # A small markdown-to-terminal formatter for assistant output.
    #
    # Input is a markdown String — while streaming it is the accumulated
    # answer re-rendered on every chunk, so incomplete syntax must degrade
    # gracefully to raw text. Output is a LogView segments list: a chain of
    # [text, style] pairs where "\n" inside a segment text is a hard row
    # break.
    #
    # Blocks: headings (h1–h4), lists (bulleted and numbered), blockquotes,
    # fenced code, horizontal rules, ON-dash pipe tables. Inline: `code`,
    # **bold**, __bold__, *italic*, _italic_, ~~strike~~, [text](url).
    module Markdown
      STYLES = {
        md_h1:       { fg: 51, bold: true },
        md_h:        { fg: 141, bold: true },
        md_bold:     { bold: true, fg: 255 },
        md_bold_italic: { bold: true, italic: true, fg: 255 },
        md_italic:   { italic: true, fg: 255 },
        md_strike:   { fg: 240 },
        md_code:     { fg: 216, bg: 235 },
        md_code_blk: { fg: 250, bg: 234 },
        md_link:     { fg: 39, underline: true },
        md_rule:     { fg: 238 },
        md_quote:    { fg: 245 }
      }.freeze

      INLINE_RE = /
        (?<code>`+)(?<code_body>.+?)\k<code>            # `code`
        | (?<!\*)\*\*\*(?![\s*])(?<bi>.+?)(?<![\s*])\*\*\*(?!\*)   # ***bold italic***
        | \*\*(?<bold>.+?)\*\*                          # **bold**
        | __(?<ibold>.+?)__                             # __bold__
        | (?<!\*)\*(?<em>[^*\n]+?)\*(?!\*)              # *italic*
        | (?<![\w_])_(?<iem>[^_\n]+?)_(?![\w_])         # _italic_
        | ~~(?<strike>.+?)~~                            # ~~strike~~
        | \[(?<linktext>.*?)\]\((?<link>\S+?)\)         # [text](url)
      /xm.freeze

      RULE_LINE = "─" * 40

      class << self
        def registered?
          !!@registered
        end

        def register_styles!
          STYLES.each { |name, opts| ::TUI::Style.define(name, opts) }
          @registered = true
        end

        # text (markdown) → LogView segments ([[text, style], ...])
        def to_segments(text)
          register_styles! unless registered?

          segments   = []
          lines      = text.to_s.gsub(/\r\n?/, "\n").split("\n", -1)
          @in_code   = false

          i = 0
          while i < lines.length
            table = table_at(lines, i)
            if table
              render_table(table[:rows], segments)
              i = table[:next]
              next
            end

            block_line(lines[i], segments)
            i += 1
          end

          segments[0..-1] = segments[2..-1] if segments.dig(0, 0) == "\n"
          trim_trailing_break!(segments)
          segments
        end

        private

        def block_line(line, segments)
          fence = line.match(/\A\s*(`{3,}|~{3,})\s*(\S*)\s*\z/)
          if !@in_code && fence
            @in_code = true
            new_row(segments)
            segments << [ "  #{fence[2]} (code)", :md_rule ] unless fence[2].empty?
            return
          end

          if @in_code
            if line.match?(/\A\s*(`{3,}|~{3,})\s*\z/)
              @in_code = false
            else
              new_row(segments)
              segments << [ "  #{line}", :md_code_blk ]
            end
            return
          end

          head = line.match(/\A(\#{1,4})\s+(.*\S)?\s*\z/m)
          if head
            level = head[1].length
            new_row(segments)
            segments << [ "#{head[1]} ", level == 1 ? :md_h1 : :md_h ]
            segments.concat(inline(head[2].to_s, level == 1 ? :md_h1 : :md_h))
            return
          end

          rule = line.match(/\A\s*([-*_])\1{2,}\s*\z/)
          if rule
            new_row(segments)
            segments << [ "  #{RULE_LINE}", :md_rule ]
            return
          end

          quote = line.match(/\A\s*>\s?(.*)\z/m)
          if quote
            new_row(segments)
            segments << [ "  ▏ ", :md_quote ]
            segments.concat(inline(quote[1].to_s, :md_quote))
            return
          end

          bullet = line.match(/\A\s*[*+-]\s+(.*\S)?\s*\z/m)
          if bullet
            new_row(segments)
            segments << [ "  • ", :accent ]
            segments.concat(inline(bullet[1].to_s))
            return
          end

          numbered = line.match(/\A\s*(\d+)[.)]\s+(.*\S)?\s*\z/m)
          if numbered
            new_row(segments)
            segments << [ "  #{numbered[1]}. ", :muted ]
            segments.concat(inline(numbered[2].to_s))
            return
          end

          new_row(segments)
          segments.concat(inline(line)) unless line.empty?
        end

        # A table starts at index i when both lines i and i+1 have pipe
        # cells and line i+1 is a markdown table separator. Returns the
        # rows (first is the header) and the index after the table.
        SEP_CELL = /\A\s*:?-+(?::-?-+)*:?\s*\z/.freeze

        def table_sep?(line)
          body = line.strip.sub(/\A\|/, "").sub(/\|\s*\z/, "")
          body.split("|").each { |piece| piece.strip.match?(SEP_CELL) or return false }

          true
        end

        def table_at(lines, i)
          return nil if @in_code

          first = lines[i]
          sep = i + 1 < lines.length ? lines[i + 1] : ""
          return nil unless first.match?(/\S.*\|.*\S/) && table_sep?(sep)

          rows = [ split_row(first) ]
          j = i + 2
          while j < lines.length && lines[j].match?(/\S.*\|.*\S/)
            rows << split_row(lines[j])
            j += 1
          end
          { rows: rows, next: j }
        end

        def split_row(line)
          cells = line.strip.sub(/\A\|/, "").sub(/\|\s*\z/, "").split("|")
          cells.map { |c| c.strip.gsub("\\|", "|") }
        end

        # Full-grid table: every row boxed, columns aligned, header bold.
        def render_table(rows, segments)
          cols   = rows.map(&:length).max
          widths = (0...cols).map { |c| rows.map { |r| ::TUI::Text.width(r[c].to_s) }.max }
          bar    = widths.map { |w| "─" * (w + 2) }

          emit_table_line(segments, "┌" + bar.join("┬") + "┐")
          rows.each_with_index do |row, k|
            emit_table_line(segments, table_row(row, widths, k.zero? ? :md_h : :text))
            emit_table_line(segments, "├" + bar.join("┼") + "┤") if k.zero?
          end
          emit_table_line(segments, "└" + bar.join("┴") + "┘")
        end

        def emit_table_line(segments, text)
          new_row(segments)
          segments << [ text, :md_rule ]
        end

        def table_row(row, widths, style)
          out = +"│"
          (0...widths.length).each do |c|
            cell = row[c].to_s
            pad  = widths[c] - ::TUI::Text.width(cell)
            cell += " " * pad if pad.positive?
            out << " #{cell} │"
          end
          out
        end

        def new_row(segments)
          segments << [ "\n", nil ] unless segments.empty?
        end

        def trim_trailing_break!(segments)
          segments.pop while !segments.empty? && segments[-1] == [ "\n", nil ]
        end

        # Parse inline markup of a line. `style` is the style parsed plain
        # text takes (nested content, e.g. inside headings).
        def inline(text, style = nil)
          text = text.to_s
          out = []
          pos = 0

          text.scan(INLINE_RE) do
            m = Regexp.last_match
            out << [ text[pos...m.begin(0)], style ] if m.begin(0) > pos

            body, span_style =
              if m[:code_body]
                [ m[:code_body], :md_code ]
              elsif m[:bold]
                [ m[:bold], :md_bold ]
              elsif m[:ibold]
                [ m[:ibold], :md_bold ]
              elsif m[:em]
                [ m[:em], :md_italic ]
              elsif m[:iem]
                [ m[:iem], :md_italic ]
              elsif m[:strike]
                [ m[:strike], :md_strike ]
              else
                [ m[:linktext], :md_link ]
              end

            # Marks can nest ([**x**](url)…); re-parse nested bodies.
            if body.match?(INLINE_RE)
              out.concat(inline(body, span_style))
            else
              out << [ body, span_style ]
            end

            pos = m.end(0)
          end

          out << [ text[pos..].to_s, style ] if pos < text.length
          out.empty? ? [ [ text, style ] ] : out
        end
      end
    end
  end
end
