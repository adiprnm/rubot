# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The edit-diff view for a file the agent just wrote, drawn exactly like
    # the pi-claude-code-ui extension (pi-diff's unified view): a dim rule
    # opens and closes the block, every row carries a coloured ▌ stripe, a
    # tinted gutter with the line number, a bold + or -, a thin │ divider,
    # then the content on a full-width tint. Changed words inside a paired
    # -/+ line get a brighter tint, and gaps between regions collapse into
    # "── N unmodified lines ──" rules. A summary row ("+A -M • K hunks at
    # line N") leads the block.
    #
    # The palette mirrors pi-diff's "default" preset with truecolor ANSI, so
    # it lands on any modern terminal. Background bands are emitted as
    # LogView fill segments, which paint to the right edge at render time —
    # the band stays full width when the terminal is resized.
    #
    # The diff is line-based (LCS) with the common leading and trailing
    # lines trimmed, so an ordinary edit costs little. Files too large to
    # diff in memory fall back to "all old lines removed, all new lines
    # added". The body is capped at `max_rows` rows with an
    # "… (N more diff lines)" row so a rewrite cannot flood the transcript.
    # TUI-only — the file tool keeps reporting a plain "Written N
    # characters" result to the model.
    module Diff
      CONTEXT   = 3            # unchanged rows kept around each change
      MAX_ROWS  = 32           # body rows shown before the "more" row
      MAX_LINES = 5_000        # per side; beyond this the fallback is used
      MAX_CELLS = 1_000_000    # cap on the LCS table (side_a * side_b)
      MAX_LINE  = 500          # characters per rendered line
      GAP_MAX   = 72           # pi-diff caps the gap rule at 72 cells

      # pi-diff's "default" preset: fg accents, tinted line/gutter bands and
      # the chrome greys. Truecolor so the look is identical, not an xterm
      # approximation.
      BOLD           = "\e[1m"
      FG_ADD         = "\e[38;2;120;210;145m"  # #78d291
      FG_DEL         = "\e[38;2;235;125;125m"  # #eb7d7d
      FG_DIM         = "\e[38;2;165;165;165m"  # #a5a5a5
      FG_LNUM        = "\e[38;2;190;190;190m"  # #bebebe
      FG_RULE        = "\e[38;2;75;75;75m"     # #4b4b4b
      FG_TEXT        = "\e[38;2;235;235;235m"  # #ebebeb
      FG_CTX         = "\e[38;2;200;200;200m"  # #c8c8c8
      BG_ADD         = "\e[48;2;22;38;32m"     # #162620
      BG_DEL         = "\e[48;2;45;25;25m"     # #2d1919
      BG_ADD_W       = "\e[48;2;35;75;50m"     # #234b32 (changed words)
      BG_DEL_W       = "\e[48;2;80;35;35m"     # #502323 (changed words)
      BG_GUTTER_ADD  = "\e[48;2;18;32;26m"     # #12201a
      BG_GUTTER_DEL  = "\e[48;2;38;22;22m"     # #261616
      BOLD_ADD       = "#{BOLD}#{FG_ADD}"
      BOLD_DEL       = "#{BOLD}#{FG_DEL}"
      WORD_MIN_SIM   = 0.15

      class << self
        def registered?
          true
        end

        # Kept so callers that installed the old named styles keep working;
        # the renderer now emits the pi palette as raw SGR strings.
        def register_styles!
          nil
        end

        # before/after are file contents (String, or nil for a file that did
        # not exist). Returns nil when nothing changed or the content cannot
        # be shown, otherwise a list of segment rows for LogView.
        #
        # `width` is the cells available to the block (already minus the
        # log's scrollbar and the block's indent). When omitted it is read
        # from the terminal so the rule lines span the view.
        def rows(before, after, path: nil, max_rows: MAX_ROWS, width: nil)
          return nil if before.nil? && after.nil?

          before = before.to_s
          after = after.to_s
          return nil if before == after
          return nil unless before.valid_encoding? && after.valid_encoding?
          return nil if before.include?("\0") || after.include?("\0")

          before_lines = split(before)
          after_lines = split(after)
          return nil if before_lines == after_lines

          width = width.to_i
          width = default_width if width < 20

          ops = marked_ops(before_lines, after_lines)
          adds = ops.count { |op| op[:kind] == :add }
          dels = ops.count { |op| op[:kind] == :del }
          return nil if adds.zero? && dels.zero?

          clusters = clusters(ops)
          hunks = clusters.count { |cluster| cluster[:ops] }
          body = clusters.flat_map { |cluster| cluster_rows(cluster, width, ops) }

          rows = summary_row(ops, adds, dels, hunks)
          rows << [ [ "─", FG_RULE, ::Rubot::TUI::LogView::FILL ] ]
          if body.length > max_rows
            hidden = body.length - max_rows
            body = body[0...max_rows]
            rows.concat(body)
            rows << [ [ "─", FG_RULE, ::Rubot::TUI::LogView::FILL ] ]
            rows << [ [ "  … (#{hidden} more diff lines)", FG_DIM ] ]
          else
            rows.concat(body)
            rows << [ [ "─", FG_RULE, ::Rubot::TUI::LogView::FILL ] ]
          end
          rows
        end

        private

        # The log is inset two cells and indented four more, with one cell
        # reserved for the scrollbar: a row owns the rest of the terminal.
        def default_width
          cols = ::TUI::Term.size[0]
          [ cols - 7, 20 ].max
        rescue StandardError
          80
        end

        def split(text)
          text.gsub("\r\n", "\n").split("\n", -1).tap do |lines|
            lines.pop if lines.last == ""
          end
        end

        # Shared leading lines, as :ctx ops numbered in both files.
        def common_head(before, after)
          count = 0
          count += 1 while count < before.length && count < after.length &&
                           before[count] == after[count]
          Array.new(count) { |i| ctx_op(before[i], i + 1, i + 1) }
        end

        # Count of shared trailing lines (after the head was removed first,
        # so it cannot swallow the whole diff).
        def tail_length(before, after)
          head = common_head(before, after).length
          tail = 0
          tail += 1 while tail < before.length - head && tail < after.length - head &&
                           before[before.length - 1 - tail] == after[after.length - 1 - tail]
          tail
        end

        # Diff operations ({ kind:, old:, new:, text }), 1-based; common
        # start and end lines are trimmed first so an ordinary edit only
        # walks the changed middle, and the shared tail is put back as
        # context so hunks can reach over it.
        def marked_ops(before, after)
          ops = common_head(before, after)
          tail = tail_length(before, after)
          head = ops.length
          a = before[head...(before.length - tail)]
          b = after[head...(after.length - tail)]

          # Numbering continues where the shared head stopped: context
          # advances both files, deletions only the old number and additions
          # only the new one.
          o = head
          n = head
          lcs_ops(a, b).each do |kind, text|
            case kind
            when :ctx then o += 1; n += 1
            when :del then o += 1
            else n += 1
            end
            ops << { kind: kind, text: text, old: o, new: n }
          end

          (0...tail).each do |i|
            ops << ctx_op(before[before.length - tail + i],
                          before.length - tail + i + 1,
                          after.length - tail + i + 1)
          end
          ops
        end

        def ctx_op(text, old_no, new_no)
          { kind: :ctx, text: text, old: old_no, new: new_no }
        end

        # An LCS walk over two arrays, as [kind, text].
        def lcs_ops(before, after)
          return after.map { |text| [ :add, text ] } if before.empty?
          return before.map { |text| [ :del, text ] } if after.empty?
          if before.length > MAX_LINES || after.length > MAX_LINES ||
             before.length * after.length > MAX_CELLS
            return before.map { |text| [ :del, text ] } + after.map { |text| [ :add, text ] }
          end

          n = before.length
          m = after.length
          table = Array.new(n + 1) { Array.new(m + 1, 0) }
          (n - 1).downto(0) do |i|
            (m - 1).downto(0) do |j|
              table[i][j] =
                if before[i] == after[j]
                  table[i + 1][j + 1] + 1
                else
                  [ table[i + 1][j], table[i][j + 1] ].max
                end
            end
          end

          ops = []
          i = 0
          j = 0
          while i < n && j < m
            if before[i] == after[j]
              ops << [ :ctx, before[i] ]
              i += 1
              j += 1
            elsif table[i + 1][j] >= table[i][j + 1]
              ops << [ :del, before[i] ]
              i += 1
            else
              ops << [ :add, after[j] ]
              j += 1
            end
          end
          while i < n
            ops << [ :del, before[i] ]
            i += 1
          end
          while j < m
            ops << [ :add, after[j] ]
            j += 1
          end
          ops
        end

        # Cluster the ops into display hunks: CONTEXT rows of context around
        # each change, adjacent clusters merged, hunk edges not on blank
        # lines (a blank at the edge reads as a spacer, not as source). The
        # skipped ops between two clusters collapse into one gap count.
        def clusters(ops)
          changes = ops.each_index.reject { |i| ops[i][:kind] == :ctx }
          return [] if changes.empty?

          ranges = []
          changes.each do |i|
            from = [ i - CONTEXT, 0 ].max
            to = [ i + CONTEXT, ops.length - 1 ].min
            if ranges.any? && from <= ranges.last[1] + 1
              ranges.last[1] = [ ranges.last[1], to ].max
            else
              ranges << [ from, to ]
            end
          end

          out = []
          previous_end = nil
          ranges.each do |(from, to)|
            from += 1 while from <= to && blank_op?(ops[from])
            to -= 1 while to >= from && blank_op?(ops[to])
            next if from > to

            if previous_end
              gap = from - previous_end - 1
              out << { gap: gap } if gap.positive?
            end
            out << { ops: ops[from..to] }
            previous_end = to
          end
          out
        end

        def blank_op?(op)
          op[:kind] == :ctx && op[:text].to_s.empty?
        end

        # "+A -M • K hunks at line N", the finished pi-diff result line.
        def summary_row(ops, adds, dels, hunks)
          sections = []
          sections << [ "+#{adds}", FG_ADD ] if adds.positive?
          sections << [ " ", nil ] if adds.positive? && dels.positive?
          sections << [ "-#{dels}", FG_DEL ] if dels.positive?
          sections << [ " ", nil ] unless sections.empty?
          sections << [ "•", FG_DIM ]
          sections << [ " ", nil ]
          label = "#{hunks} #{hunks == 1 ? 'hunk' : 'hunks'}"
          sections << [ label, FG_DIM ]

          line = first_changed_line(ops)
          sections << [ " at line #{line}", FG_DIM ] if line.positive?
          [ sections ]
        end

        def first_changed_line(ops)
          index = ops.each_index.find { |i| ops[i][:kind] != :ctx }
          return 0 unless index

          op = ops[index]
          return op[:new] if op[:kind] == :add

          added = ops[(index + 1)..].find { |entry| entry[:kind] == :add }
          return added[:new] if added

          op[:new].to_i.positive? ? op[:new] : op[:old].to_i
        end

        def cluster_rows(cluster, width, ops)
          return gap_rule(cluster[:gap], width) if cluster[:gap]

          nw = gutter_width(ops)
          cw = [ width - (nw + 5), 12 ].max
          list = cluster[:ops]
          rows = []
          i = 0

          while i < list.length
            op = list[i]
            if op[:kind] == :ctx
              rows << ctx_row(op, nw, cw)
              i += 1
              next
            end

            dels = []
            adds = []
            while i < list.length && list[i][:kind] == :del
              dels << list[i]
              i += 1
            end
            while i < list.length && list[i][:kind] == :add
              adds << list[i]
              i += 1
            end

            if dels.length == 1 && adds.length == 1
              pair = word_pair(prepare(dels[0][:text]), prepare(adds[0][:text]), cw)
              if pair
                rows << del_row(dels[0], nw, pair[:old])
                rows << add_row(adds[0], nw, pair[:new])
                next
              end
            end

            dels.each do |entry|
              rows << del_row(entry, nw, body_segments(prepare(entry[:text]), cw, BG_DEL, nil))
            end
            adds.each do |entry|
              rows << add_row(entry, nw, body_segments(prepare(entry[:text]), cw, BG_ADD, nil))
            end
          end

          rows
        end

        # Cells needed by the widest line number on screen (old numbers for
        # deletions, new numbers for additions and context). pi-diff floors
        # this at two digits.
        def gutter_width(ops)
          widest = ops.map do |op|
            op[:kind] == :add ? op[:new] : (op[:kind] == :del ? op[:old] : op[:new])
          end.max || 0
          [ widest.to_s.length, 2 ].max
        end

        def prepare(text)
          ::TUI::Text.truncate(text.to_s.gsub("\t", "  "), MAX_LINE)
        end

        def add_row(op, nw, body)
          gutter_row("▌", FG_ADD, op[:new], nw, FG_ADD, "+ ", BOLD_ADD,
                     BG_GUTTER_ADD, body, BG_ADD)
        end

        def del_row(op, nw, body)
          gutter_row("▌", FG_DEL, op[:old], nw, FG_DEL, "- ", BOLD_DEL,
                     BG_GUTTER_DEL, body, BG_DEL)
        end

        def ctx_row(op, nw, cw)
          body = body_segments(prepare(op[:text]), cw, nil, nil, fg: FG_CTX)
          gutter_row(" ", nil, op[:new], nw, FG_LNUM, "  ", FG_DIM, nil, body, nil)
        end

        # A full row: stripe, tinted gutter, divider, then the body segments
        # and a fill segment that paints the band to the right edge.
        def gutter_row(stripe, stripe_style, number, nw, num_fg, sign, sign_style, gutter_bg, body, fill_bg)
          row = []
          row << [ stripe, stripe_style ]
          row << [ number.to_s.rjust(nw), "#{num_fg}#{gutter_bg}" ]
          row << [ sign, "#{sign_style}#{gutter_bg}" ]
          row << [ "│ ", FG_RULE ]
          row.concat(body)
          row << [ " ", fill_bg, ::Rubot::TUI::LogView::FILL ] if fill_bg
          row
        end

        # The content band, cut to `cw` cells with an ellipsis when it does
        # not fit. `ranges` are the changed-word spans (character offsets)
        # that get the brighter highlight tint.
        def body_segments(text, cw, base_bg, hl_bg, fg: FG_TEXT, ranges: nil)
          ranges ||= []
          truncated = ::TUI::Text.width(text) > cw
          limit = truncated ? [ cw - 1, 0 ].max : cw

          out = []
          buffer = +""
          current = nil
          visible = 0

          text.each_char do |ch|
            w = ::TUI::Text.width(ch)
            break if visible + w > limit

            bg = if hl_bg && in_ranges?(ranges, visible)
              hl_bg
            else
              base_bg
            end
            style = "#{fg}#{bg}"
            if !buffer.empty? && style != current
              out << [ buffer, current ]
              buffer = +""
            end
            current = style
            buffer << ch
            visible += w
          end
          out << [ buffer, current ] unless buffer.empty?
          out << [ "…", "#{fg}#{base_bg}" ] if truncated
          out
        end

        def in_ranges?(ranges, pos)
          ranges.any? { |(from, to)| pos >= from && pos < to }
        end

        # "──── N unmodified lines ────" capped at 72 cells, like pi-diff.
        def gap_rule(gap, width)
          label = gap && gap.positive? ? " #{gap} unmodified lines " : "···"
          total = [ [ width, GAP_MAX ].min, label.length + 2 ].max
          pad = [ total - label.length - 2, 0 ].max
          left = pad / 2
          right = pad - left
          [ [ [ "#{'─' * left}#{label}#{'─' * right}", FG_DIM ] ] ]
        end

        # Word-level diff for a single -/+ pair: changed spans get the
        # brighter tint. Returns nil when the lines are too different (then
        # the whole line keeps the plain line tint).
        def word_pair(old_text, new_text, cw)
          old_tokens = word_tokens(old_text)
          new_tokens = word_tokens(new_text)
          return nil if old_tokens.length * new_tokens.length > 40_000

          max_len = [ old_text.length, new_text.length ].max
          return nil if max_len.zero?

          old_ranges = []
          new_ranges = []
          old_pos = 0
          new_pos = 0
          same = 0

          lcs_ops(old_tokens, new_tokens).each do |kind, token|
            case kind
            when :ctx
              same += token.length
              old_pos += token.length
              new_pos += token.length
            when :del
              old_ranges << [ old_pos, old_pos + token.length ]
              old_pos += token.length
            else
              new_ranges << [ new_pos, new_pos + token.length ]
              new_pos += token.length
            end
          end

          return nil if same.to_f / max_len < WORD_MIN_SIM

          {
            old: body_segments(old_text, cw, BG_DEL, BG_DEL_W, ranges: old_ranges),
            new: body_segments(new_text, cw, BG_ADD, BG_ADD_W, ranges: new_ranges)
          }
        end

        def word_tokens(text)
          text.scan(/\s+|[[:alnum:]_]+|[^\s[:alnum:]_]+/)
        end
      end
    end
  end
end
