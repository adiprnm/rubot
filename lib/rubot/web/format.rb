# frozen_string_literal: true

require "cgi"

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
      #
      # `quotable` adds the mark that hands a paragraph back to the composer:
      # only the chat views want it, so the plain renderer (and everything that
      # tests it block by block) stays free of page controls.
      def markdown(text, quotable: false)
        blocks = []
        source, notes, numbers = extract_footnotes(extract_fences(text.to_s, blocks))
        source = CGI.escapeHTML(source)

        # Footnote references need two facts while the flow is being written:
        # which number each id became, and how many times it has been cited
        # (a note cited twice has to anchor twice). The state lives in this
        # call, not in a module variable, so two answers painted at the same
        # time cannot number each other's notes.
        state = { numbers: numbers, seen: Hash.new(0) }

        flow = Flow.new(blocks: blocks, state: state, quotable: quotable)
        lines = source.lines(chomp: true)
        i = 0
        i = flow.step(lines, i) while i < lines.length
        flow.finish

        notes_html = render_footnotes(notes, state)
        flow.paragraphs << notes_html unless notes_html.empty?

        flow.paragraphs.join("\n")
      end

      # One block flow while it is being written: the paragraph gathered so
      # far, the list being nested, the fenced blocks already cut out, and the
      # footnotes already cited.
      #
      # It used to be six locals and four lambdas inside #markdown. A
      # block-level line closes whatever was open before it, and that closing is
      # a method per block here, which is easier to follow than a lambda whose
      # only name is the variable it is assigned to.
      class Flow
        attr_reader :paragraphs

        def initialize(blocks:, state:, quotable:)
          @blocks = blocks
          @state = state
          @quotable = quotable
          @paragraphs = []
          @paragraph = []
          @list = nil
        end

        # A paragraph is a <p>, not a bare run of text: without the element
        # there is no block for a margin to sit on, so the heading above it
        # collapsed to nothing and read as glued to the line before.
        def flush_paragraph
          return if @paragraph.empty?

          body = @paragraph.map { |line| Format.inline(line, @state) }.join("<br>")
          @paragraphs << (@quotable ? Format.quotable_paragraph(body, @paragraph) : "<p>#{body}</p>")
          @paragraph.clear
        end

        # Closing a level emits the open item and the list together, which is
        # why a parent's <li> is still open when a nested list starts inside
        # it — and why the nested list's close writes "</li></ul>" before the
        # parent's "</li>" follows.
        def close_level(html, stack)
          level = stack.pop
          html << "</li>" if level[:open]
          html << "</#{level[:tag]}>"
        end

        def flush_list
          return if @list.nil?

          close_level(@list[:html], @list[:stack]) while @list[:stack].any?
          # Every item is counted, nested ones included: the chip says how much
          # context the list carries, and a nested item is quoted with it.
          items = @list[:html].scan("<li").length
          @paragraphs << (@quotable ? Format.quotable_block("div", "para-list", @list[:html], @list[:source],
                                                            label: LIST_QUOTE_LABEL,
                                                            kind: "Daftar · #{items} butir") : @list[:html])
          @list = nil
        end

        # Lists nest by indentation, so the open lists are kept on a stack: a
        # deeper item opens a list inside the item above it, and a shallower
        # one closes levels until it has a home.
        #
        # `line` is the source as it was written, kept in the list's `source` so
        # a list can be quoted as the Markdown it came from rather than as its
        # rendered items.
        def add_item(tag, indent, body, task, line)
          @list ||= { stack: [], html: +"", source: [] }
          @list[:source] << line
          html = @list[:html]
          stack = @list[:stack]

          until stack.empty?
            top = stack.last
            if indent > top[:indent]
              html << "<#{tag}>"
              stack << { tag: tag, indent: indent, open: false }
              break
            elsif indent == top[:indent] && tag == top[:tag]
              break
            else
              close_level(html, stack)
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

          # Every item carries its own source line as well as the list carrying
          # the whole run: a long press on one item quotes just that item, and
          # the line it was written as is the only honest copy of it.
          item_attrs = +""
          item_attrs << %( class="task#{task == :done ? " is-done" : ""}") if task
          item_attrs << Format.quotable_attribute(line.strip) if @quotable
          html << "<li#{item_attrs}>"
          if task
            done = task == :done
            html << %(<span class="task-box" aria-hidden="true"></span>)
            html << %(<span class="sr-only">#{done ? "selesai" : "belum"}: </span>)
          end
          html << Format.inline(body, @state)
          top[:open] = true
        end

        # One line of the flow. Returns the line to read next, which is the one
        # after it unless a block consumed more (a table's rows, a run of quote
        # lines).
        def step(lines, i)
          line = lines[i]
          stripped = line.strip
          indent = line[/\A[ \t]*/].length

          if stripped.empty?
            flush_paragraph
            next_is_item = false
            j = i + 1
            while j < lines.length
              candidate = lines[j].strip
              if candidate.empty?
                j += 1
                next
              end
              next_is_item = !Format.list_item(candidate).nil?
              break
            end
            flush_list unless next_is_item
          elsif (block = stripped[/\A#{PLACEHOLDER}(\d+)#{PLACEHOLDER}\z/, 1])
            flush_paragraph
            flush_list
            @paragraphs << @blocks[block.to_i]
          elsif (heading = Format.heading_at(stripped))
            # A heading is its own block: it ends the paragraph above it and
            # the list, the way any other block-level line does.
            flush_paragraph
            flush_list
            @paragraphs << "<h#{heading[:level]}>#{Format.inline(heading[:text], @state)}</h#{heading[:level]}>"
          elsif stripped.match?(/\A([-*_])(?:[ \t]*\1){2,}\z/)
            flush_paragraph
            flush_list
            @paragraphs << %(<hr class="rule">)
          elsif (table = Format.table_at(lines, i, @state))
            # A table is its own block: the paragraph and the list before it
            # are finished by it, exactly as a fenced code block would.
            flush_paragraph
            flush_list
            @paragraphs << table[:html]
            return table[:next]
          elsif (item = Format.list_item(stripped))
            # A list is a block of its own, so the text above it is closed as a
            # paragraph first: without this the paragraph stayed buffered and
            # the list was emitted ahead of the line that introduced it, then
            # glued the following line onto that same paragraph.
            flush_paragraph
            add_item(item[:tag], indent, item[:body], item[:task], line)
          elsif (quote = stripped[/\A&gt;[ \t]?(.*)\z/, 1])
            # One blockquote for the whole run, not one per line: a border per
            # line is a stack of separate rules with a gap between each, which
            # reads as several quotes rather than one. A line that starts with
            # a further "&gt;" is the same run nested one level deeper, so the
            # depth is read per line and the tree is built from it.
            flush_paragraph
            flush_list
            start = i
            cursor = i
            cursor += 1 while cursor < lines.length && lines[cursor].strip.match?(/\A&gt;/)
            @paragraphs << Format.render_quote(lines[start...cursor], @state)
            return cursor
          else
            flush_list
            @paragraph << line
          end

          i + 1
        end

        def finish
          flush_paragraph
          flush_list
        end
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

      # What a list line is, if it is one: the list it belongs to, its body and
      # — for a task item — whether the box is ticked. One place for the three
      # forms a list can take, so the caller can close the paragraph above it
      # once rather than in each branch.
      def list_item(line)
        if (task = /\A[-*+] +\[([ xX])\][ \t]*(.*)\z/.match(line))
          { tag: "ul", body: task[2], task: task[1].strip.empty? ? :open : :done }
        elsif (item = line[/\A[-*+] +(.*)\z/, 1])
          { tag: "ul", body: item, task: nil }
        elsif (item = line[/\A\d+[.)] +(.*)\z/, 1])
          { tag: "ol", body: item, task: nil }
        end
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

      # A block is a wrapper plus the <pre>: the wrapper is what holds the
      # corner — the language it was tagged with and the button that copies
      # it — outside the scrolling box, so neither scrolls sideways with a
      # long line. The button is written here rather than added by a script
      # because a block that arrives mid-stream is already markup.
      #
      # The button is drawn, not written: a sheet laid over another says copy
      # in a corner that also has to hold a language name, where a word would
      # have crowded it. All three marks sit in the markup and the class on
      # the button decides which one is seen, so a confirmation costs a class
      # and no new markup. The word that is left out stays for a screen
      # reader — it is the button's name, and the one thing a mark cannot say
      # on its own.
      def code_block(body, language, streaming: false)
        lang = language.to_s.downcase
        classes = [ "code" ]
        classes << "streaming" if streaming

        top = +%(<div class="code-top">)
        top << copy_button
        top << %(<span class="code-lang">#{lang}</span>) unless lang.empty?
        top << "</div>"

        pre = +%(<pre class="#{classes.join(" ")}")
        pre << %( data-lang="#{lang}") unless lang.empty?
        pre << ">"
        code_class = lang.empty? ? "" : %( class="language-#{lang}")
        pre << "<code#{code_class}>#{highlight(body, lang)}</code></pre>"
        %(<div class="code-block#{streaming ? " streaming" : ""}">#{top}#{pre}</div>)
      end

      # Three marks on one 12px grid, stroked in the current colour so the
      # button's own colour is what tells a copy from a failure.
      COPY_ICONS = {
        copy: %(<rect x="4.2" y="4.2" width="7" height="7" rx="1.2"/>) +
              %(<path d="M9.4 4.2V3a1 1 0 0 0-1-1H3a1 1 0 0 0-1 1v5.4a1 1 0 0 0 1 1h1.2"/>),
        done: %(<path d="M2.4 6.3 4.9 8.8 9.6 3.3"/>),
        failed: %(<path d="M3.2 3.2l5.6 5.6M8.8 3.2 3.2 8.8"/>)
      }.freeze

      COPY_LABEL = "Salin isi blok kode"

      def copy_button
        icons = COPY_ICONS.map do |name, body|
          %(<svg class="code-copy-icon #{name}" viewBox="0 0 12 12" width="12" height="12" ) +
            %(fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" ) +
            %(stroke-linejoin="round" aria-hidden="true" focusable="false">#{body}</svg>)
        end.join

        # The label is live: the button says nothing visible any more, so the
        # confirmation a sighted reader gets from the mark a screen reader has
        # to get from the words behind it.
        %(<button type="button" class="code-copy" data-copy title="#{COPY_LABEL}">) +
          %(#{icons}<span class="sr-only" aria-live="polite">#{COPY_LABEL}</span></button>)
      end

      # Two filled pairs of marks on the same 24-unit grid the other drawn
      # icons use, scaled down into the gutter. Filled rather than stroked: a
      # quotation mark drawn as an outline reads as a pair of commas.
      QUOTE_ICON =
        %(<svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor" ) +
        %(aria-hidden="true" focusable="false">) +
        %(<path d="M6 17h3l2-4V7H5v6h3zm8 0h3l2-4V7h-6v6h3z"/></svg>)

      QUOTE_LABEL = "Kutip paragraf ini"
      LIST_QUOTE_LABEL = "Kutip daftar ini"

      # A block the reader can take back to the field as context. The mark
      # carries the block's own Markdown in `data-quote` — the source, not the
      # rendered text — so quoting a paragraph full of `code` and **emphasis**
      # hands the model the same thing the page drew, rather than a flattened
      # copy of it. Both the paragraph and the list use this: the tag and class
      # are what the page styles differ on, and the mark sits between the
      # opening tag and the content so a phone can float it into the top-right
      # corner.
      #
      # The button is rendered here rather than injected by a script: a block
      # streamed into the page is already quotable the moment it lands. It comes
      # first rather than last because a mark after a full last line would be
      # pushed onto a line of its own on a phone. On a pointer device the page
      # moves it out into the right gutter, where its order in the DOM does not
      # show. What it does is the composer's business (see app.js).
      def quotable_block(tag, class_name, html, source, label: QUOTE_LABEL, kind: nil)
        attrs = %( class="#{class_name}")
        attrs << quotable_attribute(source.join("\n").strip)
        # What the block is, said in the chip: a list states its size there,
        # because "6 butir" is the part of a list's scope a preview cannot show.
        attrs << %( data-quote-kind="#{CGI.escapeHTML(kind)}") if kind
        %(<#{tag}#{attrs}>) +
          %(<button type="button" class="para-quote" title="#{label}" ) +
          %(aria-label="#{label}">#{QUOTE_ICON}</button>#{html}</#{tag}>)
      end

      # The source, as the attribute that carries it. The lines have already
      # been HTML-escaped once for the renderer, so they are unescaped before
      # being escaped for the attribute: escaping twice would hand the model
      # `&amp;` where the answer said `&`.
      def quotable_attribute(source)
        %( data-quote="#{CGI.escapeHTML(CGI.unescapeHTML(source.to_s))}")
      end

      # The list is the same contract with a different block: `<ul>` may not
      # hold the mark itself (a list's children are items), so the mark and the
      # list share a wrapper that owns the `data-quote` and the gutter.
      def quotable_paragraph(html, source)
        quotable_block("p", "para", html, source)
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

        regex = highlight_regex(language, quotes, marker)
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

      # One compiled pattern per language. The pattern depends only on the
      # language, so building it per code block was pure repetition: 0.088ms of
      # every block of every render, on a page that may hold several blocks and
      # is redrawn while an answer streams.
      HIGHLIGHT_REGEXES = {}
      HIGHLIGHT_MUTEX = Mutex.new

      def highlight_regex(language, quotes, marker)
        HIGHLIGHT_MUTEX.synchronize do
          HIGHLIGHT_REGEXES[language] ||= build_highlight_regex(language, quotes, marker)
        end
      end

      def build_highlight_regex(language, quotes, marker)
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

        Regexp.new("(?:#{patterns.join("|")})", Regexp::MULTILINE)
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
  end
end
