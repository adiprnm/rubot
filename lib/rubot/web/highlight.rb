# frozen_string_literal: true

require "cgi"

module Rubot
  module Web
    # Colour for the code inside a diff row.
    #
    # A diff says where a line came from; it does not say what the line is.
    # "-   if retries > 3" and "+   if retries > 3 # bounded" are the same shape
    # of noise until the keyword, the number and the comment are told apart —
    # and that is the only thing this module does.
    #
    # One line at a time is the whole design. A row of a diff is a line, and a
    # lexer that carried state across rows would need the hunks around it, the
    # lines the diff hid, and the end of a string that began outside the window
    # it is drawing. A scanner that lives for one line cannot be wrong in a way
    # the reader can see: the worst it can do is take a `#` inside a multi-line
    # string for a comment, on that row only.
    #
    # Deliberately not a syntax tree: no HTML is parsed, nothing is evaluated,
    # and a language this module has never heard of comes back escaped and
    # plain rather than guessed at.
    module Highlight
      # Spans are named for what they are, not for the colour they land on, so
      # the theme decides the palette (see `.tok-*` in app.css).
      CLASSES = {
        keyword: "tok-key",
        string: "tok-str",
        number: "tok-num",
        comment: "tok-com",
        symbol: "tok-sym",
        call: "tok-call"
      }.freeze

      KEYWORDS = {
        ruby: %w[
          BEGIN END alias and begin break case class def defined? do else elsif end
          ensure false for if in include extend module next nil not or puts raise
          redo require require_relative rescue retry return self super then true
          unless until when while yield attr_accessor attr_reader attr_writer freeze
          lambda proc private protected public new loop
        ],
        js: %w[
          as async await break case catch class const continue debugger default
          delete do else export extends false finally for from function get if
          import in instanceof let new null of return set static super switch this
          throw true try typeof undefined var void while yield interface type
        ],
        python: %w[
          and as assert async await break class continue def del elif else except
          False finally for from global if import in is lambda None nonlocal not or
          pass raise return True try while with yield self
        ],
        shell: %w[
          case do done elif else esac fi for function if in local readonly return
          select then time until while export cd echo sudo bundle gem ruby rake
          git curl grep sed awk cat
        ],
        sql: %w[
          add alter and as asc begin by case commit constraint create delete desc
          distinct drop else end exists foreign from group having in index inner
          insert into is join key left limit not null on or order outer primary
          references replace rollback select set table then union unique update
          values view when where with pragma
        ],
        css: %w[
          important inherit initial none auto flex grid block inline absolute
          relative fixed sticky
        ],
        go: %w[
          break case chan const continue default defer else fallthrough for func
          go goto if import interface map package range return select struct switch
          type var true false nil
        ],
        yaml: %w[true false null yes no]
      }.freeze

      LINE_COMMENTS = {
        ruby: [ "#" ], js: [ "//" ], python: [ "#" ], shell: [ "#" ],
        sql: [ "--" ], go: [ "//" ], yaml: [ "#" ], css: [], markup: []
      }.freeze

      BLOCK_COMMENTS = {
        js: [ [ "/*", "*/" ] ],
        css: [ [ "/*", "*/" ] ],
        go: [ [ "/*", "*/" ] ],
        sql: [ [ "/*", "*/" ] ],
        markup: [ [ "<!--", "-->" ] ]
      }.freeze

      QUOTES = {
        shell: %w[" '],
        markup: %w[" '],
        sql: %w['],
        css: %w[" ']
      }.freeze

      EXTENSIONS = {
        "rb" => :ruby, "rake" => :ruby, "ru" => :ruby, "gemspec" => :ruby,
        "erb" => :ruby, "thor" => :ruby,
        "js" => :js, "mjs" => :js, "cjs" => :js, "jsx" => :js, "ts" => :js,
        "tsx" => :js, "mts" => :js, "json" => :js,
        "py" => :python,
        "sh" => :shell, "bash" => :shell, "zsh" => :shell, "fish" => :shell,
        "sql" => :sql,
        "css" => :css, "scss" => :css, "less" => :css,
        "html" => :markup, "htm" => :markup, "xml" => :markup, "svg" => :markup,
        "go" => :go,
        "yml" => :yaml, "yaml" => :yaml, "toml" => :yaml
      }.freeze

      # Files whose name carries the language instead of an extension.
      NAMES = {
        "Gemfile" => :ruby, "Rakefile" => :ruby, "Guardfile" => :ruby,
        "config.ru" => :ruby, "Dockerfile" => :shell, ".bashrc" => :shell,
        ".zshrc" => :shell
      }.freeze

      # A shebang decides the language of a file whose name does not: a script
      # called `bin/rubot` is as much Ruby as `rubot.rb`. The caller passes the
      # first line it already has in hand — this module never opens a file,
      # because a renderer must not depend on what is on the disk.
      # `#!/usr/bin/env ruby` puts the interpreter at the end, not the start,
      # so the pattern looks for the word rather than for the beginning.
      SHEBANGS = [
        [ %r{\b(?:j?ruby)\b}, :ruby ],
        [ %r{\b(?:ba|z|da)?sh\b}, :shell ],
        [ %r{\bpython[0-9.]*\b}, :python ]
      ].freeze

      METHOD_NAME = /\A[a-z_][A-Za-z0-9_]*[?!]?\z/

      module_function

      # The language of a path, or nil when it is not one this module knows.
      def language(path, first_line = nil)
        base = File.basename(path.to_s)
        return NAMES[base] if NAMES.key?(base)

        found = EXTENSIONS[File.extname(base).delete_prefix(".").downcase]
        return found if found

        line = first_line.to_s
        return nil unless line.start_with?("#!")

        SHEBANGS.each { |pattern, lang| return lang if line.match?(pattern) }
        nil
      end

      # The line, escaped, with its tokens wrapped in spans. A line in a
      # language this module does not know comes back escaped and unchanged.
      def line(text, path: nil, language: nil, first_line: nil)
        text = text.to_s
        lang = language || self.language(path, first_line)
        return CGI.escapeHTML(text) if lang.nil?

        scan(text, lang)
      end

      # One pass, left to right. Every branch consumes the whole token it
      # matched, which is what keeps a `#` inside a string from opening a
      # comment and a `"` inside a comment from opening a string.
      def scan(text, lang)
        out = +""
        i = 0
        length = text.length

        while i < length
          char = text[i]
          rest = text[i..]
          prev = i.zero? ? " " : text[i - 1]

          if (block = block_comment_at(rest, lang))
            out << wrap(:comment, block)
            i += block.length
            next
          end

          if (comment = line_comment_at(rest, lang))
            out << wrap(:comment, comment)
            break
          end

          if quotes_for(lang).include?(char)
            token = string_at(rest, char)
            out << wrap(:string, token)
            i += token.length
            next
          end

          # A Ruby regex literal is a string by any other name: it has its own
          # delimiters and its own backslashes.
          if char == "/" && lang == :ruby && !identifier_char?(prev) &&
             (literal = rest[%r{\A/(?:[^/\\\n]|\\.)*/}])
            out << wrap(:string, literal)
            i += literal.length
            next
          end

          if (token = symbol_at(rest, lang, prev))
            out << wrap(:symbol, token)
            i += token.length
            next
          end

          if word?(char) && !identifier_char?(prev)
            token = rest[/\A[A-Za-z_][A-Za-z0-9_]*[?!]?/]
            out << word_span(token, lang, rest[token.length].to_s)
            i += token.length
            next
          end

          if number?(char) && !identifier_char?(prev)
            token = rest[/\A(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?)/]
            out << wrap(:number, token)
            i += token.length
            next
          end

          out << CGI.escapeHTML(char)
          i += 1
        end

        out
      end

      def word_span(token, lang, following)
        if (KEYWORDS[lang] || []).include?(token)
          wrap(:keyword, token)
        elsif following == "(" && METHOD_NAME.match?(token)
          # A word glued to an open paren is a call, and colouring it is what
          # makes a changed line read as "this now calls that".
          wrap(:call, token)
        else
          CGI.escapeHTML(token)
        end
      end

      # `@ivar`, `$global`, and a Ruby `:symbol`. The prefix is part of the
      # token, so it is coloured with it.
      def symbol_at(rest, lang, prev)
        return nil if identifier_char?(prev)

        if lang == :ruby || lang == :shell
          sigil = rest[/\A[@$][A-Za-z_][A-Za-z0-9_]*/]
          return sigil if sigil
        end
        return nil unless lang == :ruby

        rest[/\A:[A-Za-z_][A-Za-z0-9_]*[?!]?/]
      end

      # The comment runs to the end of the line — a diff row is a line, so
      # there is nothing after it to keep.
      def line_comment_at(rest, lang)
        return nil unless (LINE_COMMENTS[lang] || []).any? { |marker| rest.start_with?(marker) }

        rest
      end

      def block_comment_at(rest, lang)
        (BLOCK_COMMENTS[lang] || []).each do |(open, close)|
          next unless rest.start_with?(open)

          finish = rest.index(close, open.length)
          return rest[0...(finish ? finish + close.length : rest.length)]
        end
        nil
      end

      def string_at(rest, quote)
        i = 1
        while i < rest.length
          case rest[i]
          when "\\" then i += 2
          when quote then return rest[0..i]
          else i += 1
          end
        end
        rest
      end

      def quotes_for(lang)
        QUOTES.fetch(lang, %w[" '])
      end

      def word?(char)
        char.match?(/[A-Za-z_]/)
      end

      def number?(char)
        char.match?(/\d/)
      end

      def identifier_char?(char)
        char.to_s.match?(/[A-Za-z0-9_]/)
      end

      def wrap(kind, text)
        %(<span class="#{CLASSES.fetch(kind)}">#{CGI.escapeHTML(text)}</span>)
      end
    end
  end
end
