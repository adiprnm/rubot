# frozen_string_literal: true

require "cgi"

module Rubot
  module Web
    # The edit a tool made, drawn as hunks under the row that made it.
    #
    # The web channel has this of its own rather than borrowing the TUI's
    # renderer: that one emits styled terminal rows for LogView and knows
    # nothing about HTML, and reworking it for the browser would put the TUI
    # at the mercy of a page. What is shared is the idea, not the code — a
    # line diff with some context around each change, which is the shape a
    # reader already knows from `git diff`.
    #
    # Nothing is drawn for a call that changed no file: the tool row alone is
    # the honest record of "read this", "searched that".
    module Diff
      CONTEXT = 3      # unchanged lines kept around each change
      MAX_ROWS = 24    # body rows before the "… N more lines" row
      MAX_LINE = 400   # characters per row, so a minified file cannot run off
      MAX_LINES = 4_000 # per side; past this the file is not worth a diff

      module_function

      # Returns the fragment, or nil when there is nothing to show.
      def render(before, after, path: nil)
        rows = body(before, after)
        return nil if rows.nil?

        summary, hunk_rows = rows
        head = +%(<div class="diff-head">#{summary}</div>)
        head << %(<div class="diff-path">#{CGI.escapeHTML(path.to_s)}</div>) unless path.to_s.empty?
        %(<div class="diff">#{head}<div class="diff-body">#{hunk_rows.join}</div></div>)
      end

      # [summary_html, [row_html, ...]] or nil.
      def body(before, after)
        spec = structure(before, after)
        return nil unless spec

        [ summary(spec), spec[:rows] ]
      end

      # The diff itself: { adds:, dels:, hunks:, line:, rows: [...] }. Public
      # so the shape can be checked without parsing HTML.
      def structure(before, after)
        return nil if before.nil? && after.nil?

        before = before.to_s
        after = after.to_s
        return nil if before == after
        return nil unless before.valid_encoding? && after.valid_encoding?
        return nil if before.include?("\0") || after.include?("\0")

        old_lines = lines(before)
        new_lines = lines(after)
        return nil if old_lines == new_lines

        ops = operations(old_lines, new_lines)
        adds = ops.count { |op| op[:kind] == :add }
        dels = ops.count { |op| op[:kind] == :del }
        return nil if adds.zero? && dels.zero?

        hunks = clusters(ops)
        {
          adds: adds,
          dels: dels,
          hunks: hunks.count { |hunk| hunk[:ops] },
          line: first_changed_line(ops),
          rows: hunk_rows(hunks)
        }
      end

      def lines(text)
        text.gsub("\r\n", "\n").split("\n", -1).tap do |list|
          list.pop if list.last == ""
        end
      end

      # Operations in file order, with 1-based line numbers on each side.
      def operations(before, after)
        head = 0
        head += 1 while head < before.length && head < after.length && before[head] == after[head]

        tail = 0
        tail += 1 while tail < before.length - head && tail < after.length - head &&
                        before[before.length - 1 - tail] == after[after.length - 1 - tail]

        ops = Array.new(head) { |i| { kind: :ctx, text: before[i], old: i + 1, new: i + 1 } }

        old_no = head
        new_no = head
        lcs(before[head...(before.length - tail)], after[head...(after.length - tail)]).each do |kind, text|
          case kind
          when :ctx then old_no += 1; new_no += 1
          when :del then old_no += 1
          else new_no += 1
          end
          ops << { kind: kind, text: text, old: old_no, new: new_no }
        end

        (0...tail).each do |i|
          text = before[before.length - tail + i]
          ops << { kind: :ctx, text: text,
                   old: before.length - tail + i + 1,
                   new: after.length - tail + i + 1 }
        end
        ops
      end

      # An LCS walk over two arrays of lines, as [kind, text] pairs. A file too
      # large to walk is shown as a rewrite instead: the rows are the same
      # shape, and a reader scrolling a diff of a 4000-line file is not reading
      # it anyway.
      def lcs(before, after)
        return after.map { |text| [ :add, text ] } if before.empty?
        return before.map { |text| [ :del, text ] } if after.empty?
        if before.length > MAX_LINES || after.length > MAX_LINES ||
           before.length * after.length > 1_000_000
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
        ops.concat(before[i..].map { |text| [ :del, text ] }) if i < n
        ops.concat(after[j..].map { |text| [ :add, text ] }) if j < m
        ops
      end

      # CONTEXT rows around each change, adjacent ranges merged, and the lines
      # between two hunks collapsed into one gap.
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
          from += 1 while from <= to && ops[from][:kind] == :ctx && ops[from][:text].empty?
          to -= 1 while to >= from && ops[to][:kind] == :ctx && ops[to][:text].empty?
          next if from > to

          out << { gap: from - previous_end - 1 } if previous_end && from - previous_end - 1 > 0
          out << { ops: ops[from..to] }
          previous_end = to
        end
        out
      end

      # The line the first change lands on, on the new side where there is one.
      def first_changed_line(ops)
        index = ops.each_index.find { |i| ops[i][:kind] != :ctx }
        return 0 unless index

        op = ops[index]
        return op[:new] if op[:kind] == :add

        added = ops[(index + 1)..].find { |entry| entry[:kind] == :add }
        return added[:new] if added

        op[:new].to_i.positive? ? op[:new] : op[:old].to_i
      end

      # "+3 -1 · 2 hunks at line 12", the same sentence the terminal draws.
      def summary(spec)
        parts = []
        parts << %(<span class="diff-adds">+#{spec[:adds]}</span>) if spec[:adds].positive?
        parts << %(<span class="diff-dels">-#{spec[:dels]}</span>) if spec[:dels].positive?
        hunks = spec[:hunks]
        parts << %(<span class="diff-hunks">#{hunks} #{hunks == 1 ? 'hunk' : 'hunks'}</span>)
        parts << %(<span class="diff-line">at line #{spec[:line]}</span>) if spec[:line].positive?
        parts.join(%(<span class="diff-sep" aria-hidden="true">·</span>))
      end

      def hunk_rows(hunks)
        rows = []
        body = hunks.flat_map do |hunk|
          if hunk[:gap]
            [ %(<div class="diff-gap">#{hunk[:gap]} baris tidak berubah</div>) ]
          else
            hunk[:ops].map { |op| row(op) }
          end
        end

        if body.length > MAX_ROWS
          hidden = body.length - MAX_ROWS
          rows.concat(body.first(MAX_ROWS))
          rows << %(<div class="diff-gap">… #{hidden} baris lagi</div>)
        else
          rows.concat(body)
        end
        rows
      end

      def row(op)
        text = clip(op[:text].to_s.gsub("\t", "  "))
        sign = case op[:kind]
               when :add then "+"
               when :del then "-"
               else " "
        end
        number = op[:kind] == :del ? op[:old] : op[:new]
        cls = op[:kind] == :add ? "is-add" : (op[:kind] == :del ? "is-del" : "is-ctx")
        %(<div class="diff-row #{cls}"><span class="diff-no">#{number}</span>) +
          %(<span class="diff-sign" aria-hidden="true">#{sign}</span>) +
          %(<code>#{CGI.escapeHTML(text)}</code></div>)
      end

      def clip(text)
        text.length > MAX_LINE ? "#{text[0, MAX_LINE]}…" : text
      end
    end
  end
end
