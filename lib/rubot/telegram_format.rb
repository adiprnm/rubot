# frozen_string_literal: true

module Rubot
  # Converts the Markdown a model writes into the HTML dialect Telegram accepts
  # with `parse_mode: "HTML"`, and splits it into valid messages.
  #
  # Why HTML and not MarkdownV2:
  #
  #   * Only three characters need escaping (`&`, `<`, `>`) instead of the
  #     MarkdownV2 set (`_*[]()~`>#+-=|{}.!\`). A stray asterisk in model output
  #     can no longer break the whole message.
  #   * Tags nest for real, so `**Note: *this* matters**` keeps both entities.
  #   * URLs live in an attribute: parentheses and underscores in links need no
  #     escaping.
  #   * The newest entities are reachable: `<pre><code class="language-x">`,
  #     `<blockquote expandable>`, `<tg-spoiler>`, `<tg-emoji>` and `<tg-time>`.
  #
  # Message splitting happens on the *source* Markdown, block by block, so a
  # chunk never starts inside a code fence and never carries a broken entity.
  module TelegramFormat
    # Telegram's hard limit for a single message.
    MAX_LENGTH = 4096

    ESCAPES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;" }.freeze
    UNESCAPES = { "&lt;" => "<", "&gt;" => ">", "&quot;" => '"', "&amp;" => "&" }.freeze

    FENCE      = /\A\s*(`{3,}|~{3,})\s*([A-Za-z0-9_+#.\-]*)\s*\z/
    HEADING    = /\A\s{0,3}(\#{1,6})\s+(.*?)\s*#*\s*\z/
    HR         = /\A\s*([-*_])(?:\s*\1){2,}\s*\z/
    LIST_ITEM  = /\A(?<indent>[ \t]*)(?<marker>[-*+]|\d{1,3}[.)])(?<gap>[ \t]+)(?<body>.*)\z/
    TASK       = /\A\[(?<state>[ xX])\][ \t]+(?<body>.*)\z/
    QUOTE      = /\A\s*(?<mark>\*\*>|>+)[ \t]?(?<body>.*)\z/
    TABLE_SEP  = /\A\s*\|?[ \t]*:?-{1,}:?[ \t]*(?:\|[ \t]*:?-{1,}:?[ \t]*)+\|?\s*\z/
    TAG        = %r{<(/?)([A-Za-z][\w-]*)((?:\s[^<>]*)?)>}

    # One left-to-right scanner instead of a pile of gsub passes. Every branch
    # is non-greedy and stops at a newline, so an unterminated `**` or a stray
    # backtick degrades to literal text instead of eating the rest of the reply.
    INLINE = %r{
        (?<code>`{1,3})(?<code_body>[^`\n]+?)\k<code>
      | !\[(?<emoji_alt>[^\]\n]*)\]\(\s*tg://emoji\?id=(?<emoji_id>\d+)[^)\s]*\s*\)
      | \[(?<link_text>[^\[\]\n]+)\]\(\s*(?<link_url>(?:[^()\s]|\([^()\s]*\))+)\s*\)
      | <(?<autolink>(?:https?|tg)://[^>\s]+)>
      | \*\*\*(?!\*)(?=\S)(?<bold_italic>.+?)(?<=[^\s*])\*\*\*(?!\*)
      | \*\*(?!\*)(?=\S)(?<bold>.+?)(?<=[^\s*])\*\*(?!\*)
      | (?<![\w_])__(?!_)(?=\S)(?<underline>.+?)(?<=[^\s_])__(?![\w_])
      | ~~(?!~)(?=\S)(?<strike>.+?)(?<=[^\s~])~~(?![\w~])
      | \|\|(?!\|)(?=\S)(?<spoiler>.+?)(?<=[^\s|])\|\|(?!\|)
      | (?<![\w~])~(?!~)(?=\S)(?<strike1>.+?)(?<=[^\s~])~(?![\w~])
      | (?<![\w*])\*(?!\*)(?=\S)(?<italic>.+?)(?<=[^\s*])\*(?![\w*])
      | (?<![\w])_(?!_)(?=\S)(?<italic_u>.+?)(?<=[^\s_])_(?![\w_])
    }x

    class << self
      # Markdown → Telegram HTML. Always safe to send with parse_mode: "HTML".
      def convert(markdown)
        text = markdown.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
        return "" if text.strip.empty?

        render(text).sub(/\A\n+/, "").sub(/\n+\z/, "")
      end

      # Markdown → array of HTML chunks, each within +max_length+ where the
      # content allows it. Splits on the source so entities stay balanced.
      def chunks(markdown, max_length = MAX_LENGTH)
        limit = max_length.to_i
        limit = MAX_LENGTH if limit <= 0

        text = markdown.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
        return [] if text.strip.empty?

        parts(text, limit).flat_map do |part|
          html = convert(part)
          measure(html) <= limit ? [ html ] : split_html(html, limit)
        end.reject { |chunk| to_plain(chunk).strip.empty? }
      end

      # Best-effort plain text: tags stripped, entities decoded, links kept as
      # their label. Used when Telegram rejects the entities for any reason.
      def to_plain(html)
        html.to_s
            .gsub(%r{<a\b[^>]*>(.*?)</a>}m) { Regexp.last_match(1) }
            .gsub(/<[^>]*>/, "")
            .gsub(/&(?:lt|gt|quot|amp);/) { |m| UNESCAPES[m] }
      end

      # Escape text so it is safe inside a Telegram HTML message.
      def escape(text)
        text.to_s.gsub(/[&<>]/, ESCAPES)
      end

      private

      # ---------------- Block level ----------------

      def render(text)
        lines = text.split("\n", -1)
        out = []
        i = 0

        while i < lines.length
          line = lines[i]

          if (m = FENCE.match(line))
            body, i = take_code_block(lines, i, m[1])
            out << code_block(body, m[2])
          elsif table_start?(lines, i)
            rows = []
            while i < lines.length && lines[i].include?("|") && !lines[i].strip.empty?
              rows << lines[i]
              i += 1
            end
            out << table_block(rows)
          elsif (m = QUOTE.match(line))
            quote = []
            expandable = false
            while i < lines.length && (qm = QUOTE.match(lines[i]))
              expandable ||= qm[:mark] == "**>"
              # Telegram cannot nest blockquote entities, so deeper levels
              # are flattened into the same quote instead of rejected.
              quote << qm[:body].sub(/\A\s*>+[ \t]?/, "")
              i += 1
            end
            inner = render(quote.join("\n"))
            out << "<blockquote#{expandable ? " expandable" : ""}>#{inner}</blockquote>"
          elsif (m = HEADING.match(line))
            out << "<b>#{inline(m[2])}</b>"
            i += 1
          elsif HR.match?(line)
            out << "——————————"
            i += 1
          elsif (m = LIST_ITEM.match(line))
            out << list_line(m)
            i += 1
          else
            out << inline(line)
            i += 1
          end
        end

        out.join("\n")
      end

      def take_code_block(lines, index, fence)
        body = []
        i = index + 1
        while i < lines.length && !lines[i].strip.start_with?(fence)
          body << lines[i]
          i += 1
        end
        i += 1 if i < lines.length # consume the closing fence
        [ body.join("\n"), i ]
      end

      def code_block(body, lang)
        lang = lang.to_s.downcase.delete("^a-z0-9+#._-")
        escaped = escape(body)
        return "<pre>#{escaped}</pre>" if lang.empty?

        %(<pre><code class="language-#{lang}">#{escaped}</code></pre>)
      end

      def list_line(match)
        indent = match[:indent]
        body   = match[:body]

        return "#{indent}#{match[:marker]}#{match[:gap]}#{inline(body)}" unless match[:marker].match?(/\A[-*+]\z/)

        if (task = TASK.match(body))
          box = task[:state].strip.empty? ? "☐" : "☑"
          "#{indent}#{box} #{inline(task[:body])}"
        elsif body.strip.empty?
          indent
        else
          "#{indent}• #{inline(body)}"
        end
      end

      def table_start?(lines, index)
        line = lines[index]
        nxt  = lines[index + 1]
        return false unless line&.include?("|") && nxt
        return false unless nxt.include?("|") && nxt.include?("-")

        TABLE_SEP.match?(nxt)
      end

      # Telegram has no table entity, so a table is rendered as aligned
      # monospace text inside <pre> — readable, selectable, and never mangled
      # into a wall of escaped pipes.
      def table_block(rows)
        cells = rows.map { |row| split_row(row) }
        header = cells[1]&.all? { |c| c.match?(/\A:?-{1,}:?\z/) }
        cells.delete_at(1) if header

        columns = cells.map(&:length).max.to_i
        cells.each { |row| row << "" while row.length < columns }

        widths = Array.new(columns, 0)
        cells.each do |row|
          row.each_with_index { |cell, idx| widths[idx] = [ widths[idx], cell.length ].max }
        end
        widths = widths.map { |w| w.clamp(1, 28) }

        lines = cells.each_with_index.map do |row, row_idx|
          line = row.each_with_index.map do |cell, idx|
            width = widths[idx]
            cell = "#{cell[0, width - 1]}…" if cell.length > width
            cell.ljust(width)
          end.join(" │ ")
          line = line.rstrip
          next line unless row_idx.zero? && header

          "#{line}\n#{widths.map { |w| "─" * w }.join("─┼─")}"
        end

        "<pre>#{escape(lines.join("\n"))}</pre>"
      end

      def split_row(row)
        row.strip
           .sub(/\A\|/, "").sub(/\|\z/, "")
           .split("|")
           .map { |cell| cell.strip.gsub(/\*\*|__|~~|`/, "") }
      end

      # ---------------- Inline level ----------------

      def inline(text)
        out = +""
        pos = 0

        while (match = INLINE.match(text, pos))
          out << escape(text[pos...match.begin(0)])
          out << render_inline(match)
          pos = match.end(0)
        end

        out << escape(text[pos..])
        out
      end

      def render_inline(match)
        if match[:code]
          "<code>#{escape(match[:code_body])}</code>"
        elsif match[:emoji_id]
          emoji_inline(match)
        elsif match[:link_url]
          link_inline(match[:link_text], match[:link_url])
        elsif match[:autolink]
          url = match[:autolink]
          %(<a href="#{escape_attr(url)}">#{escape(url)}</a>)
        elsif match[:bold_italic]
          "<b><i>#{inline(match[:bold_italic])}</i></b>"
        elsif match[:bold]
          "<b>#{inline(match[:bold])}</b>"
        elsif match[:underline]
          "<u>#{inline(match[:underline])}</u>"
        elsif match[:strike] || match[:strike1]
          "<s>#{inline(match[:strike] || match[:strike1])}</s>"
        elsif match[:spoiler]
          "<tg-spoiler>#{inline(match[:spoiler])}</tg-spoiler>"
        else
          "<i>#{inline(match[:italic] || match[:italic_u])}</i>"
        end
      end

      def link_inline(label, url)
        # Telegram's date-time entity, expressed as a MarkdownV2-style link.
        if url.start_with?("tg://time?")
          query = url.split("?", 2).last.to_s
          unix  = query[/unix=(\d+)/, 1]
          fmt   = query[/format=([A-Za-z]+)/, 1]
          return escape(label) unless unix

          attrs = %( unix="#{unix}")
          attrs += %( format="#{fmt}") if fmt
          return "<tg-time#{attrs}>#{escape(label)}</tg-time>"
        end

        %(<a href="#{escape_attr(url)}">#{inline(label)}</a>)
      end

      def emoji_inline(match)
        alt = match[:emoji_alt].to_s.strip
        alt = "🙂" if alt.empty?

        %(<tg-emoji emoji-id="#{match[:emoji_id]}">#{escape(alt)}</tg-emoji>)
      end

      # Attribute values only need & and " escaped (and < > for safety).
      def escape_attr(value)
        value.to_s.gsub(/[&<>"]/, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;")
      end

      # ---------------- Splitting ----------------

      # Groups source Markdown into blank-line separated blocks, never breaking
      # a fenced code block in half.
      def parts(text, limit)
        blocks = block_split(text)
        packed = []
        buffer = []

        blocks.each do |block|
          candidate = (buffer + [ block ]).join("\n\n")
          if measure(convert(candidate)) <= limit
            buffer << block
          else
            packed << buffer.join("\n\n") unless buffer.empty?
            buffer = [ block ]
          end
        end
        packed << buffer.join("\n\n") unless buffer.empty?
        packed
      end

      def block_split(text)
        blocks = []
        current = []
        fence = nil

        text.split("\n", -1).each do |line|
          if fence
            current << line
            fence = nil if line.strip.start_with?(fence)
            next
          end

          if line.strip.empty?
            blocks << current.join("\n") unless current.empty?
            current = []
          elsif (m = FENCE.match(line))
            fence = m[1]
            current << line
          else
            current << line
          end
        end

        blocks << current.join("\n") unless current.empty?
        blocks.reject { |b| b.strip.empty? }
      end

      # Last resort: an already-converted chunk that is still too long (a single
      # huge code block, a wall of text with no blank lines). Cut on line
      # boundaries and re-open whatever tags were open at the cut.
      def split_html(html, limit)
        out = []
        stack = []
        buffer = +""

        html.split("\n", -1).each do |line|
          # Room for the closers we must append at a cut and the openers we
          # re-emit at the start of the next chunk.
          available = limit - measure(open_tags(stack)) - measure(close_tags(stack)) - 2
          available = limit / 2 if available < 16

          slice_line(line, available).each do |piece|
            reserve = measure(close_tags(stack))
            if !buffer.empty? && measure(buffer) + 1 + measure(piece) + reserve > limit
              out << "#{buffer}\n#{close_tags(stack)}"
              buffer = open_tags(stack).dup
              buffer << "\n" unless buffer.empty?
              buffer << piece
            else
              buffer << "\n" unless buffer.empty?
              buffer << piece
            end
            track_tags(stack, piece)
          end
        end

        out << buffer unless buffer.strip.empty?
        out.map(&:rstrip)
      end

      def slice_line(line, limit)
        return [ line ] if measure(line) <= limit

        pieces = []
        rest = line
        while measure(rest) > limit
          cut = safe_cut(rest, prefix_cut(rest, limit))
          pieces << rest[0...cut]
          rest = rest[cut..]
        end
        pieces << rest unless rest.empty?
        pieces
      end

      # Telegram counts message length in UTF-16 code units, so an emoji costs
      # two. Measuring with #length alone would overflow the 4096 limit on an
      # emoji-heavy reply.
      def measure(text)
        text.length + text.count("\u{10000}-\u{10FFFF}")
      end

      # Longest prefix of +text+ (in characters) that still fits the budget.
      def prefix_cut(text, limit)
        low = 1
        high = text.length
        best = 1

        while low <= high
          mid = (low + high) / 2
          if measure(text[0...mid]) <= limit
            best = mid
            low = mid + 1
          else
            high = mid - 1
          end
        end

        best
      end

      # Never cut inside an HTML entity like &amp;.
      def safe_cut(text, limit)
        cut = limit.clamp(1, text.length)
        return cut unless (entity = text[0...cut].match(/&[A-Za-z#0-9]*\z/))

        [ cut - entity[0].length, 1 ].max
      end

      def track_tags(stack, text)
        text.scan(TAG) do
          closing = Regexp.last_match(1)
          name    = Regexp.last_match(2)
          full    = Regexp.last_match(0)

          if closing == "/"
            idx = stack.rindex { |tag| tag_name(tag) == name }
            stack.slice!(idx..) if idx
          else
            stack << full
          end
        end
      end

      def tag_name(tag)
        tag[/\A<\s*([\w-]+)/, 1]
      end

      def open_tags(stack)
        stack.map { |tag| tag }.join
      end

      def close_tags(stack)
        stack.reverse.map { |tag| "</#{tag_name(tag)}>" }.join
      end
    end
  end
end
