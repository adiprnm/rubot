# frozen_string_literal: true

require "cgi"
require "erb"

module Rubot
  module Web
    # Minimal markdown for chat bubbles. Everything is HTML-escaped first, so
    # the transform below can only ever emit the tags it writes itself.
    #
    # Blocks: headings, lists (bulleted, numbered, task), blockquotes, fenced
    # code, rules, pipe tables. Inline: code, bold, italic, strike, links,
    # images. Footnotes: `[^id]` in the text, `[^id]: text` hoisted to the end.
    module Format
      # A private-use character, not NUL: `String#strip` removes NUL, which
      # would quietly turn a fenced code block back into a paragraph line.
      PLACEHOLDER = "\uE000"

      module_function

      # Line-oriented, because a list is a run of lines and a lone newline is
      # just a line break inside one. Code fences are cut out of the raw text
      # first, so their bodies can be highlighted before anything is escaped;
      # everything else is escaped up front, so the only tags that can appear
      # are the ones written here.
      def markdown(text)
        blocks = []
        source, notes, numbers = extract_footnotes(extract_fences(text.to_s, blocks))
        source = CGI.escapeHTML(source)

        # Footnote references need two facts while the flow is being written:
        # which number each id became, and how many times it has been cited
        # (a note cited twice has to anchor twice). The state lives in this
        # call, not in a module variable, so two answers painted at the same
        # time cannot number each other's notes.
        state = { numbers: numbers, seen: Hash.new(0) }

        paragraphs = []
        paragraph = []
        list = nil

        flush_paragraph = lambda do
          next if paragraph.empty?

          # A paragraph is a <p>, not a bare run of text: without the element
          # there is no block for a margin to sit on, so the heading above it
          # collapsed to nothing and read as glued to the line before.
          paragraphs << "<p>#{paragraph.map { |line| inline(line, state) }.join("<br>")}</p>"
          paragraph.clear
        end

        # Closing a level emits the open item and the list together, which is
        # why a parent's <li> is still open when a nested list starts inside
        # it — and why the nested list's close writes "</li></ul>" before the
        # parent's "</li>" follows.
        close_level = lambda do |html, stack|
          level = stack.pop
          html << "</li>" if level[:open]
          html << "</#{level[:tag]}>"
        end

        flush_list = lambda do
          next if list.nil?

          close_level.call(list[:html], list[:stack]) while list[:stack].any?
          paragraphs << list[:html]
          list = nil
        end

        # Lists nest by indentation, so the open lists are kept on a stack: a
        # deeper item opens a list inside the item above it, and a shallower
        # one closes levels until it has a home.
        add_item = lambda do |tag, indent, body, task|
          list ||= { stack: [], html: +"" }
          html = list[:html]
          stack = list[:stack]

          until stack.empty?
            top = stack.last
            if indent > top[:indent]
              html << "<#{tag}>"
              stack << { tag: tag, indent: indent, open: false }
              break
            elsif indent == top[:indent] && tag == top[:tag]
              break
            else
              close_level.call(html, stack)
            end
          end

          if stack.empty?
            html << "<#{tag}>"
            stack << { tag: tag, indent: indent, open: false }
          end

          top = stack.last
          if top[:open]
            html << "</li>"
            top[:open] = false
          end

          html << (task ? %(<li class="task#{task == :done ? " is-done" : ""}">) : "<li>")
          if task
            done = task == :done
            html << %(<span class="task-box" aria-hidden="true"></span>)
            html << %(<span class="sr-only">#{done ? "selesai" : "belum"}: </span>)
          end
          html << inline(body, state)
          top[:open] = true
        end

        lines = source.lines(chomp: true)
        i = 0
        while i < lines.length
          line = lines[i]
          stripped = line.strip
          indent = line[/\A[ \t]*/].length

          if stripped.empty?
            flush_paragraph.call
            flush_list.call
          elsif (block = stripped[/\A#{PLACEHOLDER}(\d+)#{PLACEHOLDER}\z/, 1])
            flush_paragraph.call
            flush_list.call
            paragraphs << blocks[block.to_i]
          elsif (heading = heading_at(stripped))
            # A heading is its own block: it ends the paragraph above it and
            # the list, the way any other block-level line does.
            flush_paragraph.call
            flush_list.call
            paragraphs << "<h#{heading[:level]}>#{inline(heading[:text], state)}</h#{heading[:level]}>"
          elsif stripped.match?(/\A([-*_])(?:[ \t]*\1){2,}\z/)
            flush_paragraph.call
            flush_list.call
            paragraphs << %(<hr class="rule">)
          elsif (table = table_at(lines, i, state))
            # A table is its own block: the paragraph and the list before it
            # are finished by it, exactly as a fenced code block would.
            flush_paragraph.call
            flush_list.call
            paragraphs << table[:html]
            i = table[:next]
            next
          elsif (task = stripped.match(/\A[-*+] +\[([ xX])\][ \t]*(.*)\z/))
            add_item.call("ul", indent, task[2], task[1].strip.empty? ? :open : :done)
          elsif (item = stripped[/\A[-*+] +(.*)\z/, 1])
            add_item.call("ul", indent, item, nil)
          elsif (item = stripped[/\A\d+[.)] +(.*)\z/, 1])
            add_item.call("ol", indent, item, nil)
          elsif (quote = stripped[/\A&gt;[ \t]?(.*)\z/, 1])
            # One blockquote for the whole run, not one per line: a border per
            # line is a stack of separate rules with a gap between each, which
            # reads as several quotes rather than one. A line that starts with
            # a further "&gt;" is the same run nested one level deeper, so the
            # depth is read per line and the tree is built from it.
            flush_paragraph.call
            flush_list.call
            start = i
            cursor = i
            cursor += 1 while cursor < lines.length && lines[cursor].strip.match?(/\A&gt;/)
            paragraphs << render_quote(lines[start...cursor], state)
            i = cursor
            next
          else
            flush_list.call
            paragraph << line
          end

          i += 1
        end

        flush_paragraph.call
        flush_list.call

        notes_html = render_footnotes(notes, state)
        paragraphs << notes_html unless notes_html.empty?

        paragraphs.join("\n")
      end

      # A run of quote lines becomes one blockquote per level, nested inside
      # each other. Each line carries its own depth — the number of "&gt;"
      # markers in front of it — so the tree is built while walking down, and
      # a shallower line closes the levels above it.
      #
      # Lines at the same depth are one paragraph joined by breaks, because a
      # quoted passage is quoted prose: its lines belong to the same thought,
      # and a border drawn per line would put a gap between each.
      def render_quote(lines, state = nil)
        html = +""
        depth = 0
        open_paragraph = false

        lines.each do |line|
          markers = line.strip[/\A(?:&gt;[ \t]?)*/].to_s
          level = markers.scan("&gt;").size
          text = line.strip.sub(/\A(?:&gt;[ \t]?)*/, "")

          while depth > level
            html << "</p>" if open_paragraph
            html << "</blockquote>"
            open_paragraph = false
            depth -= 1
          end

          if depth < level
            # A deeper line continues the sentence above it, so the paragraph
            # it was in is closed before the nested quote opens.
            html << "</p>" if open_paragraph
            open_paragraph = false
            while depth < level
              html << "<blockquote>"
              depth += 1
            end
          end

          unless open_paragraph
            html << "<p>"
            open_paragraph = true
          else
            html << "<br>"
          end

          html << inline(text, state)
        end

        html << "</p>" if open_paragraph
        # Every level left open has to be closed, and the counter has to move:
        # this used to be `html << "</blockquote>" while depth.positive?`, which
        # never decremented, so a quoted line spun forever appending the same
        # tag and ate all the memory on the machine.
        while depth.positive?
          html << "</blockquote>"
          depth -= 1
        end
        html
      end

      # "#" opens a heading only when a space follows it: "#hashtag" is a word,
      # and a line of "###" alone is the horizontal rule it looks like.
      def heading_at(line)
        match = /\A(\#{1,6})[ \t]+(.+?)\s*#*\z/.match(line)
        return nil unless match

        # A rule of hashes is matched by the rule branch, not here.
        text = match[2].strip
        return nil if text.empty?

        { level: match[1].length, text: text }
      end

      # --- fenced code ----------------------------------------------------
      #
      # Fences are cut out of the raw text, before escaping, so the body of a
      # block can be highlighted token by token: escaping first would turn
      # every quote and ampersand into an entity and there would be nothing
      # left to recognise.

      def extract_fences(text, blocks)
        source = text.gsub(/\r\n?/, "\n")

        source = source.gsub(/^[ \t]*(`{3,}|~{3,})[ \t]*([a-zA-Z0-9+#._-]*)[^\n]*\n(.*?)^[ \t]*\1[ \t]*$/m) do
          blocks << code_block(Regexp.last_match(3), Regexp.last_match(2), streaming: false)
          "#{PLACEHOLDER}#{blocks.size - 1}#{PLACEHOLDER}"
        end

        # An unterminated fence is normal mid-stream: show the tail as code.
        # The body may not have started yet — "```ruby" on its own, the first
        # chunk of a block — so the newline is optional rather than the line
        # falling through to the paragraph and showing its backticks.
        source.gsub(/^[ \t]*(`{3,}|~{3,})[ \t]*([a-zA-Z0-9+#._-]*)[^\n]*(?:\n(.*))?\z/m) do
          blocks << code_block(Regexp.last_match(3).to_s, Regexp.last_match(2), streaming: true)
          "#{PLACEHOLDER}#{blocks.size - 1}#{PLACEHOLDER}"
        end
      end

      def code_block(body, language, streaming: false)
        lang = language.to_s.downcase
        classes = [ "code" ]
        classes << "streaming" if streaming

        pre = +%(<pre class="#{classes.join(" ")}")
        pre << %( data-lang="#{lang}") unless lang.empty?
        pre << ">"
        code_class = lang.empty? ? "" : %( class="language-#{lang}")
        pre << "<code#{code_class}>#{highlight(body, lang)}</code></pre>"
        pre
      end

      # A small highlighter, not a parser: comments, strings, numbers and
      # keywords in four colours. A language it does not know is printed
      # plain — a wrong colour is worse than none.
      STRING_QUOTES = {
        "ruby" => %w[" '], "python" => %w[" '], "bash" => %w[" '], "sh" => %w[" '],
        "javascript" => %w[" ' `], "js" => %w[" ' `], "typescript" => %w[" ' `],
        "ts" => %w[" ' `], "json" => %w["], "css" => %w[" '], "sql" => %w['],
        "go" => %w[" `], "rust" => %w["], "yaml" => %w[" '], "yml" => %w[" '],
        "html" => %w[" '], "php" => %w[" ']
      }.freeze

      # Languages whose comments run to the end of the line, and the marker
      # that starts one.
      LINE_COMMENTS = {
        "ruby" => "#", "python" => "#", "bash" => "#", "sh" => "#", "yaml" => "#",
        "yml" => "#", "dockerfile" => "#", "makefile" => "#", "toml" => "#",
        "javascript" => "//", "js" => "//", "typescript" => "//", "ts" => "//",
        "go" => "//", "rust" => "//", "java" => "//", "c" => "//", "cpp" => "//",
        "php" => "//", "css" => "/*", "sql" => "--"
      }.freeze

      BLOCK_COMMENT_LANGS = %w[javascript js typescript ts go rust java c cpp php css sql].freeze

      KEYWORDS = %w[
        def end class module if elsif else unless while until for do return yield
        begin rescue ensure raise break next redo then and or not in require
        include extend attr_accessor attr_reader attr_writer nil true false self super
        function const let var import export from default async await try catch
        finally throw new this typeof instanceof of delete void
        fn pub use mod match mut impl struct enum trait where loop
        public private protected static final abstract override package namespace
        int float double char bool boolean string void long short byte unsigned
        interface implements extends new null true false
        select insert update delete create table where join group by order limit
        and or not null is in like between
        echo cd ls mkdir rm cp mv export source sudo apt brew
      ].uniq.freeze

      LITERALS = %w[true false nil null undefined None True False yes no on off].freeze

      # Group names become CSS classes: "str" is .tok-str, and so on.
      TOKEN_CLASS = { "str" => "tok-str", "com" => "tok-com", "num" => "tok-num",
                      "kw" => "tok-kw", "lit" => "tok-lit" }.freeze

      def highlight(code, language)
        quotes = STRING_QUOTES[language]
        marker = LINE_COMMENTS[language]
        return CGI.escapeHTML(code) if quotes.nil? && marker.nil?

        patterns = []
        if quotes && !quotes.empty?
          strings = quotes.map do |q|
            e = Regexp.escape(q)
            # A string stops at the end of its line: an unterminated quote in
            # mid-stream must not paint the rest of the block as a string.
            "#{e}(?:\\\\.|[^#{e}\\n])*#{e}?"
          end
          patterns << "(?<str>#{strings.join("|")})"
        end
        if marker == "/*"
          patterns << '(?<com>/\*.*?\*/)'
        elsif marker
          patterns << "(?<com>#{Regexp.escape(marker)}[^\\n]*)"
        end
        patterns << "(?<com>&lt;!--.*?--&gt;)" if language == "html"
        patterns << "(?<num>\\b\\d+(?:\\.\\d+)?\\b)"
        patterns << "(?<lit>\\b(?:#{LITERALS.join("|")})\\b)"
        patterns << "(?<kw>\\b(?:#{KEYWORDS.join("|")})\\b)"

        regex = Regexp.new("(?:#{patterns.join("|")})", Regexp::MULTILINE)
        out = +""
        pos = 0

        code.scan(regex) do
          match = Regexp.last_match
          out << CGI.escapeHTML(code[pos...match.begin(0)]) if match.begin(0) > pos
          name = TOKEN_CLASS.find { |group, _| match[group] }&.last
          out << %(<span class="#{name}">#{CGI.escapeHTML(match[0])}</span>)
          pos = match.end(0)
        end
        out << CGI.escapeHTML(code[pos..].to_s) if pos < code.length
        out
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

      def table_at(lines, start, state = nil)
        return nil unless table_line?(lines[start])

        separator = lines[start + 1]
        return nil unless separator && table_separator?(separator)

        rows = [ split_row(lines[start]) ]
        cursor = start + 2
        while cursor < lines.length && table_line?(lines[cursor])
          rows << split_row(lines[cursor])
          cursor += 1
        end

        { html: render_table(rows, split_row(separator), state), next: cursor }
      end

      def render_table(rows, separator, state = nil)
        cols = rows.map(&:length).max.to_i
        aligns = (0...cols).map { |c| alignment(separator[c]) }
        header = rows.first
        body = rows.drop(1)

        out = [ %(<div class="md-table-wrap"><table class="md-table">), "<thead>" ]
        out << table_row("th", header, cols, aligns, state)
        out << "</thead>"
        out << "<tbody>"
        body.each { |row| out << table_row("td", row, cols, aligns, state) }
        out << "</tbody>"
        out << "</table></div>"
        out.join
      end

      def table_row(tag, cells, cols, aligns, state = nil)
        parts = (0...cols).map do |c|
          style = aligns[c] ? %( style="text-align:#{aligns[c]}") : ""
          %(<#{tag}#{style}>#{inline(cells[c].to_s, state)}</#{tag}>)
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

      # Inline spans. Escaped input only, so these are safe to emit as-is —
      # except for a link or an image, whose URL is attacker-controlled text
      # that lands in an attribute; `safe_url` is the gate for those.
      #
      # Marks nest (`**bold with `code`**`, `[**x**](url)`), so a body that
      # carries marks is parsed again. The code span is the exception: its
      # body is literally what the writer typed.
      INLINE_RE = /
          (?<code>`+)(?<code_body>.+?)\k<code>
        | !\[(?<img_alt>[^\]\n]*)\]\((?<img_url>[^)\s]*)[^)]*\)
        | \[\^(?<fn_id>[^\]\n]+)\]
        | \[(?<link_text>[^\]\n]*)\]\((?<link_url>[^)\s]*)[^)]*\)
        | (?<!\*)\*\*\*(?![\s*])(?<bi>.+?)(?<![\s*])\*\*\*(?!\*)
        | (?<![\w_])___(?![\s_])(?<bii>.+?)(?<![\s_])___(?![\w_])
        | \*\*(?![\s*])(?<bold>.+?)(?<![\s*])\*\*
        | (?<![\w_])__(?![\s_])(?<ibold>.+?)(?<![\s_])__(?![\w_])
        | (?<!\*)\*(?![\s*])(?<em>.+?)(?<![\s*])\*(?!\*)
        | (?<![\w_])_(?![\s_])(?<iem>.+?)(?<![\s_])_(?![\w_])
        | ~~(?![\s~])(?<strike>.+?)(?<![\s~])~~
      /x

      # Only the schemes a chat message has any business carrying. A bare
      # "javascript:" would otherwise run in the page, and "file:" would read
      # the reader's disk. Anything else stays the literal text that was
      # written, which is the honest thing to show.
      SAFE_URL = %r{\A(?:https?|mailto|tel):}i
      RELATIVE_URL = %r{\A(?:/|#|\?|\.{1,2}/)}
      INLINE_IMAGE = %r{\Adata:image/(?:png|jpe?g|gif|webp|svg\+xml)[;,]}

      def safe_url(raw)
        url = raw.to_s.strip
        return nil if url.empty?
        return url if url.match?(RELATIVE_URL)
        return url if url.match?(SAFE_URL)
        return url if url.match?(INLINE_IMAGE)

        nil
      end

      def inline(text, state = nil)
        source = text.to_s
        out = +""
        pos = 0

        source.scan(INLINE_RE) do
          match = Regexp.last_match
          out << source[pos...match.begin(0)] if match.begin(0) > pos
          out << inline_token(match, state)
          pos = match.end(0)
        end

        out << source[pos..].to_s if pos < source.length
        out
      end

      def inline_token(match, state = nil)
        if match[:code_body]
          %(<code>#{match[:code_body]}</code>)
        elsif match[:img_url]
          url = safe_url(match[:img_url])
          if url
            # The picture is a button (open it larger) with a download beside
            # it, the same pair the composer's attachments carry.
            name = match[:img_alt]
            %(<span class="md-image"><button type="button" class="md-image-open" data-lightbox="#{url}" data-name="#{name}" aria-label="Buka #{name}"><img src="#{url}" alt="#{name}" loading="lazy"></button>) +
              %(<a class="md-image-download" href="#{url}" download="#{name}" title="Unduh #{name}" aria-label="Unduh #{name}">↓</a></span>)
          else
            match[0]
          end
        elsif match[:fn_id]
          footnote_ref(match[:fn_id], match[0], state)
        elsif match[:link_url]
          url = safe_url(match[:link_url])
          return match[0] unless url

          %(<a href="#{url}" target="_blank" rel="noopener noreferrer">#{inline(match[:link_text], state)}</a>)
        elsif match[:bi]
          "<strong><em>#{inline(match[:bi], state)}</em></strong>"
        elsif match[:bii]
          "<strong><em>#{inline(match[:bii], state)}</em></strong>"
        elsif match[:bold]
          "<strong>#{inline(match[:bold], state)}</strong>"
        elsif match[:ibold]
          "<strong>#{inline(match[:ibold], state)}</strong>"
        elsif match[:em]
          "<em>#{inline(match[:em], state)}</em>"
        elsif match[:iem]
          "<em>#{inline(match[:iem], state)}</em>"
        else
          "<del>#{inline(match[:strike], state)}</del>"
        end
      end

      # --- footnotes ------------------------------------------------------
      #
      # `[^1]: the note` is not part of the flow: it is lifted out and drawn
      # once, under a rule at the end of the answer, the way every markdown
      # renderer hoists it. The line is cut out before escaping so the note
      # keeps its own inline markup, and after the fences are cut out so a
      # `[^1]:` inside a code block stays code.
      FOOTNOTE_DEF = /\A[ \t]*\[\^([^\]\n]+)\]:[ \t]*(.*)\z/

      def extract_footnotes(source)
        notes = []
        kept  = []

        source.lines(chomp: true).each do |line|
          match = FOOTNOTE_DEF.match(line)
          if match
            notes << { id: match[1], body: match[2].strip }
          else
            kept << line
          end
        end

        [ kept.join("\n"), notes, footnote_numbers(source, notes) ]
      end

      # Numbered by first mention, not by the order the definitions happen to
      # be written: `[^a]` cited before `[^b]` must read 1 then 2, whatever
      # order the two notes are defined in. A note nobody cites still gets a
      # number, so it is not silently dropped.
      def footnote_numbers(source, notes)
        defined = notes.map { |note| note[:id] }
        cited = source.scan(/\[\^([^\]\n]+)\]/).flatten.uniq.select { |id| defined.include?(id) }
        (defined - cited).each { |id| cited << id }
        cited.uniq.each_with_index.to_h { |id, index| [ id, index + 1 ] }
      end

      # The reference in the text: a superscript number that jumps to its
      # note. An id with no definition is not a citation, so it stays the
      # literal text that was written.
      def footnote_ref(id, literal, state)
        number = state && state[:numbers][id]
        return literal unless number

        state[:seen][id] += 1
        anchor = state[:seen][id] == 1 ? "fnref-#{number}" : "fnref-#{number}-#{state[:seen][id]}"

        %(<sup class="fn-ref"><a href="#fn-#{number}" id="#{anchor}">#{number}</a></sup>)
      end

      # The notes themselves, in number order. `state` is spent by the time
      # this runs, so the list is built from the numbers rather than the refs.
      def render_footnotes(notes, state)
        return "" if notes.empty?

        items = notes
                .sort_by { |note| state[:numbers][note[:id]] || Float::INFINITY }
                .map do |note|
          number = state[:numbers][note[:id]] || note[:id]
          body = inline(CGI.escapeHTML(note[:body]), state)
          back = %(<a class="fn-back" href="#fnref-#{number}" aria-label="kembali ke teks">&#8617;</a>)
          %(<li id="fn-#{number}">#{body} #{back}</li>)
        end

        %(<section class="footnotes">\n<hr>\n<ol>\n#{items.join("\n")}\n</ol>\n</section>)
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

      # The round marks are drawn for the same reason: ◌ and ◐ are a fallback
      # font's business, so the ring changed weight and rode low or high beside
      # "Thinking…" depending on the system that painted it. An SVG in a square
      # box is the same size everywhere and centres by construction (see
      # `.row .mark`), which is what a mark beside a line of text has to do.
      MARKS = {
        think: %(<svg class="mark-svg" viewBox="0 0 10 10" fill="none" stroke="currentColor" ) +
               %(stroke-width="1.2" stroke-linecap="round" aria-hidden="true" focusable="false">) +
               %(<circle cx="5" cy="5" r="3.5" stroke-dasharray="1.7 1.5"/></svg>),
        working: %(<svg class="mark-svg" viewBox="0 0 10 10" aria-hidden="true" focusable="false">) +
                 %(<circle cx="5" cy="5" r="3.5" fill="none" stroke="currentColor" stroke-width="1.2"/>) +
                 %(<path d="M5 1.5a3.5 3.5 0 0 1 0 7z" fill="currentColor"/></svg>)
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

        # A drawn mark for the two rows whose glyph was a ring: the thought and
        # the turn that is still running. The state rows keep their glyphs —
        # ✓ and ✗ sit on the baseline where every mono font puts them.
        def mark(kind)
          MARKS.fetch(kind, "")
        end

        # The working row always arrives from the stream, where it has to be
        # swapped out of band into the band above the field. The first paint
        # puts the same row in the page directly, so it passes `oob: false`.
        def oob
          true
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

        # A partial rendered by a test has no pictures unless the caller passes
        # them, and `_attachments` should not have to spell that out.
        def images
          []
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

        # The body of a live turn: everything it has done, and nothing else.
        # The row that says the turn is still running is not part of it — it
        # lives in the band above the composer, so the timeline stays a record
        # of the work rather than a place the last row keeps sliding down.
        def turn_body(turn)
          render("_timeline", items: turn.items)
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
