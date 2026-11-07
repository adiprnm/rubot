# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The edit-diff view for a file the agent just wrote, styled after
    # pi's pi-claude-code-ui (the pi-diff look): every row carries a colored
    # ▌ stripe, a tinned gutter with the line number, a bold + or - sign,
    # a thin │ divider, then the content on a soft tint; gaps between
    # changed regions collapse into "── N unmodified lines ──" rules. A
    # summary row ("Updated <path> +A -M · K hunks") leads the block.
    # TUI-only — the file tool keeps reporting a plain "Written
    # N characters" result to the model.
    #
    # The diff is line-based (LCS) with the common leading and trailing
    # lines trimmed, so an ordinary edit costs little. Files too large to
    # diff in memory fall back to "all old lines removed, all new lines
    # added", and the body is capped at `max_rows` rows with an
    # "… N more diff lines" row so a rewrite cannot flood the transcript.
    module Diff
      CONTEXT   = 3            # unchanged rows kept around each change
      MAX_ROWS  = 30           # body rows shown before the "more" row
      MAX_LINES = 5_000        # per side; beyond this the fallback is used
      MAX_CELLS = 1_000_000    # cap on the LCS table (side_a * side_b)
      MAX_LINE  = 300          # cells per rendered line, before the log wraps
      MAX_LABEL = 60           # path cells in the summary row

      STYLES = {
        diff_mark_add: { fg: 114, bold: true },  # ▌ stripe and + sign, green
        diff_mark_del: { fg: 174, bold: true },  # ▌ stripe and - sign, red
        diff_num:      { fg: 245, bg: 237 },     # gutter line numbers
        diff_num_add:  { fg: 114, bg: 237 },
        diff_num_del:  { fg: 174, bg: 237 },
        diff_add:      { fg: 114, bg: 235 },     # + content on a green-ish tint
        diff_del:      { fg: 174, bg: 235 },     # - content on a red-ish tint
        diff_ctx:      { fg: 245 },              # unchanged content
        diff_rule:     { fg: 238 },              # │ dividers and ─ rules
        diff_stat:     { fg: 244 }
      }.freeze

      class << self
        def registered?
          !!@registered
        end

        def register_styles!
          STYLES.each { |name, opts| ::TUI::Style.define(name, opts) }
          @registered = true
        end

        # before/after are file contents (String, or nil for a file that did
        # not exist). Returns nil when nothing changed or the content cannot
        # be shown, otherwise a list of segment rows for LogView.
        def rows(before, after, path:, max_rows: MAX_ROWS)
          return nil if before.nil? && after.nil?

          before = before.to_s
          after = after.to_s
          return nil if before == after
          return nil unless before.valid_encoding? && after.valid_encoding?
          return nil if before.include?("\0") || after.include?("\0")

          before_lines = split(before)
          after_lines = split(after)
          return nil if before_lines == after_lines

          register_styles! unless registered?

          ops = marked_ops(before_lines, after_lines)
          adds = ops.count { |op| op[:kind] == :add }
          dels = ops.count { |op| op[:kind] == :del }
          return nil if adds.zero? && dels.zero?

          clusters = clusters(ops)
          hunks = clusters.count { |cluster| cluster[:ops] }

          rows = summary_row(ops, path, hunks)
          body = clusters.flat_map { |cluster| cluster_rows(cluster) }
          if body.length > max_rows
            hidden = body[max_rows..]
            body = body[0...max_rows] << [ [ "  … ", :muted ],
                                           [ "#{hidden.length} more diff lines", :dim ] ]
          end
          rows.concat(body)
        end

        private

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

        # An LCS walk over two line arrays, as [kind, text].
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

        def summary_row(ops, path, hunks)
          adds = ops.count { |op| op[:kind] == :add }
          dels = ops.count { |op| op[:kind] == :del }
          label = ::TUI::Text.truncate(path.to_s, MAX_LABEL)
          sections = [ [ "Updated ", :muted ], [ label, :accent ],
                       [ "  +#{adds}", :diff_mark_add ], [ "  -#{dels}", :diff_mark_del ] ]
          if hunks.positive?
            sections << [ "  · #{hunks} #{hunks == 1 ? 'hunk' : 'hunks'}", :diff_stat ]
          end
          [ sections ]
        end

        def cluster_rows(cluster)
          return gap_rule(cluster[:gap]) if cluster[:gap]

          width = gutter_width(cluster[:ops])
          cluster[:ops].map { |op| op_row(op, width) }
        end

        # Cells needed by the widest line number on screen (old numbers for
        # deletions, new numbers for additions and context).
        def gutter_width(ops)
          widest = ops.map do |op|
            op[:kind] == :add ? op[:new] : (op[:kind] == :del ? op[:old] : op[:new])
          end.max || 0
          [ widest.to_s.length, 3 ].max
        end

        # One visual row: ▌stripe, gutter number, sign cell, │ divider,
        # content. Deletions number with the old file, additions and context
        # with the new one — the way pi-diff's unified view does.
        def op_row(op, width)
          no = op[:kind] == :del ? op[:old] : op[:new]
          number = " #{no.to_s.rjust(width)} "
          text = ::TUI::Text.truncate(op[:text].to_s, MAX_LINE)

          case op[:kind]
          when :add
            [ [ "▌", :diff_mark_add ], [ number, :diff_num_add ], [ "+ ", :diff_mark_add ],
              [ "│ ", :diff_rule ], [ text, :diff_add ] ]
          when :del
            [ [ "▌", :diff_mark_del ], [ number, :diff_num_del ], [ "- ", :diff_mark_del ],
              [ "│ ", :diff_rule ], [ text, :diff_del ] ]
          else
            [ [ "  ", nil ], [ number, :diff_num ], [ "  ", nil ],
              [ "│ ", :diff_rule ], [ text, :diff_ctx ] ]
          end
        end

        # "──── 12 unmodified lines ────", centred into a fixed 56 cells.
        def gap_rule(gap)
          label = "#{gap} unmodified #{"line#{gap == 1 ? '' : 's'}"}"
          room = 56 - label.length - 2
          left = (room / 2.0).floor
          [ [ [ "─" * left + "  #{label}  " + "─" * (room - left), :diff_rule ] ] ]
        end
      end
    end
  end
end
