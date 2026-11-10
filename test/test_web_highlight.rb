# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  module Web
    class TestWebHighlight < Minitest::Test
      def tokenize(text, path)
        Highlight.line(text, path: path)
      end

      # A diff that shows where a line came from but not what the line is
      # leaves the reader matching shapes: this is the reading it adds.
      def test_a_keyword_and_a_comment_are_named
        html = tokenize("def hello # says hi", "x.rb")

        assert_includes html, %(<span class="tok-key">def</span>)
        assert_includes html, %(<span class="tok-com"># says hi</span>)
      end

      # The whole reason the scanner consumes a token at a time: a string that
      # contains a comment marker is a string, and a comment that contains a
      # quote is a comment. Splitting on `#` would have coloured half of each.
      def test_a_comment_marker_inside_a_string_does_not_start_a_comment
        html = tokenize(%(x = "a # b" # real), "x.rb")

        assert_includes html, %(<span class="tok-str">&quot;a # b&quot;</span>)
        assert_includes html, %(<span class="tok-com"># real</span>)
      end

      def test_a_quote_inside_a_comment_does_not_start_a_string
        html = tokenize(%(x = 1 # he said "hi), "x.rb")

        assert_includes html, %(<span class="tok-com"># he said &quot;hi</span>)
      end

      # Colour is an addition to the escape, never a replacement for it: the
      # file being diffed is untrusted text.
      def test_markup_in_the_source_is_still_escaped
        html = tokenize(%(<script>alert("x")</script>), "x.rb")

        refute_includes html, "<script>"
        assert_includes html, "&lt;script&gt;"
      end

      # A language the module has never heard of is escaped and left plain.
      # Guessing would colour a prose file with the rules of something else.
      def test_an_unknown_file_comes_back_escaped_and_uncoloured
        html = tokenize("def <not> # ruby", "notes.txt")

        assert_equal "def &lt;not&gt; # ruby", html
      end

      def test_numbers_and_calls_are_named
        html = tokenize("retries(3) + 42", "x.rb")

        assert_includes html, %(<span class="tok-call">retries</span>)
        assert_includes html, %(<span class="tok-num">3</span>)
        assert_includes html, %(<span class="tok-num">42</span>)
      end

      def test_an_instance_variable_and_a_symbol_are_named
        html = tokenize("@user = :admin", "x.rb")

        assert_includes html, %(<span class="tok-sym">@user</span>)
        assert_includes html, %(<span class="tok-sym">:admin</span>)
      end

      def test_each_language_keeps_its_own_keywords
        assert_includes tokenize("const x = 1", "x.js"), %(<span class="tok-key">const</span>)
        assert_includes tokenize("def x", "x.py"), %(<span class="tok-key">def</span>)
        assert_includes tokenize("package main", "x.go"), %(<span class="tok-key">package</span>)
        refute_includes tokenize("package main", "x.js"), "tok-key"
      end

      # The name of a script says nothing about its language; its interpreter
      # does. The caller passes the first line it already has, because a
      # renderer must not open a file to draw a row.
      def test_a_shebang_decides_a_file_with_no_extension
        assert_equal :ruby, Highlight.language("bin/rubot", "#!/usr/bin/env ruby")
        assert_equal :shell, Highlight.language("bin/run", "#!/bin/bash -e")
        assert_nil Highlight.language("bin/run", "just a line")
      end

      def test_a_name_carries_the_language_when_the_extension_does_not
        assert_equal :ruby, Highlight.language("Gemfile")
        assert_equal :ruby, Highlight.language("config.ru")
        assert_equal :ruby, Highlight.language("Rakefile")
        assert_nil Highlight.language("README.md")
      end

      # A diff is where this is read, so the row is where it has to appear.
      def test_a_diff_row_carries_the_highlighted_line
        html = Diff.render("a = 1\n", "a = 2 # bump\n", path: "x.rb")

        assert_includes html, %(<span class="tok-num">2</span>)
        assert_includes html, %(<span class="tok-com"># bump</span>)
      end

      # The row's own colouring says whether the line was added or removed;
      # the tokens sit on top of it and must not paint over the tint.
      def test_a_highlighted_row_keeps_the_class_that_marks_it_added
        html = Diff.render("a = 1\n", "a = 2\n", path: "x.rb")

        assert_match(/<div class="diff-row is-add">.*tok-num/, html)
      end
    end
  end
end
