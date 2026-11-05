# frozen_string_literal: true

require_relative "test_helper"

module Rubot
  class TelegramFormatTest < Minitest::Test
    def setup
      @converter = TelegramFormat
    end

    # ---- Plain text ----

    def test_plain_text_is_not_touched
      assert_equal "Hello world", @converter.convert("Hello world")
    end

    def test_markdownv2_escaping_is_gone
      # No more \. \! \- noise: only three characters need escaping in HTML.
      assert_equal "Hello. World! foo-bar_baz", @converter.convert("Hello. World! foo-bar_baz")
    end

    def test_html_specials_are_escaped
      assert_equal "&lt;b&gt; &amp;", @converter.convert("<b> &")
    end

    def test_html_in_model_output_cannot_inject_entities
      result = @converter.convert("<b>not bold</b> <tg-spoiler>x</tg-spoiler>")
      assert_equal "&lt;b&gt;not bold&lt;/b&gt; &lt;tg-spoiler&gt;x&lt;/tg-spoiler&gt;", result
    end

    def test_nil_and_empty
      assert_equal "", @converter.convert(nil)
      assert_equal "", @converter.convert("")
      assert_equal "", @converter.convert("   \n  ")
    end

    # ---- Emphasis ----

    def test_bold
      assert_equal "<b>Hello, world.</b>", @converter.convert("**Hello, world.**")
    end

    def test_italic_with_asterisks
      assert_equal "<i>world</i>", @converter.convert("*world*")
    end

    def test_italic_with_underscores
      assert_equal "Hello <i>world</i>", @converter.convert("Hello _world_")
    end

    def test_bold_italic
      assert_equal "<b><i>Hello</i></b>", @converter.convert("***Hello***")
    end

    def test_italic_containing_bold
      assert_equal "<i>see <b>this</b> now</i>", @converter.convert("*see **this** now*")
    end

    def test_bold_containing_italic
      assert_equal "<b>Note: <i>this</i> matters</b>", @converter.convert("**Note: *this* matters**")
    end

    def test_underline
      assert_equal "<u>underline me</u>", @converter.convert("__underline me__")
    end

    def test_strikethrough
      assert_equal "<s>deleted</s>", @converter.convert("~~deleted~~")
      assert_equal "<s>deleted</s>", @converter.convert("~deleted~")
    end

    def test_spoiler
      assert_equal "<tg-spoiler>secret</tg-spoiler>", @converter.convert("||secret||")
    end

    def test_identifiers_and_math_stay_literal
      assert_equal "use snake_case_name here", @converter.convert("use snake_case_name here")
      assert_equal "2*3*4 = 24", @converter.convert("2*3*4 = 24")
    end

    def test_unterminated_marker_degrades_to_text
      assert_equal "**oops and *also", @converter.convert("**oops and *also")
    end

    # ---- Code ----

    def test_inline_code
      assert_equal "Use <code>foo()</code> here", @converter.convert("Use `foo()` here")
    end

    def test_inline_code_is_not_parsed
      assert_equal "<code>**not bold**</code>", @converter.convert("`**not bold**`")
    end

    def test_inline_code_escapes_html
      assert_equal "<code>a &lt; b &amp;&amp; c &gt; d</code>", @converter.convert("`a < b && c > d`")
    end

    def test_fenced_code_block
      input = "Here is code:\n```\nprint('hello')\n```"
      result = @converter.convert(input)
      assert_includes result, "<pre>"
      assert_includes result, "print(&#39;hello&#39;)".gsub("&#39;", "'")
      assert_includes result, "</pre>"
    end

    def test_fenced_code_block_with_language
      result = @converter.convert("```ruby\nputs 1 < 2\n```")
      assert_equal %(<pre><code class="language-ruby">puts 1 &lt; 2</code></pre>), result
    end

    def test_fenced_code_block_keeps_inner_markdown_literal
      result = @converter.convert("```\n**not bold** `x`\n```")
      assert_equal "<pre>**not bold** `x`</pre>", result
    end

    # ---- Links ----

    def test_link
      assert_equal %(Check <a href="https://google.com">Google</a>),
                   @converter.convert("Check [Google](https://google.com)")
    end

    def test_link_with_parentheses_in_url
      result = @converter.convert("[wiki](https://en.wikipedia.org/wiki/Foo_(bar))")
      assert_equal %(<a href="https://en.wikipedia.org/wiki/Foo_(bar)">wiki</a>), result
    end

    def test_link_with_bold_label
      result = @converter.convert("[**Bold** link](https://example.com)")
      assert_equal %(<a href="https://example.com"><b>Bold</b> link</a>), result
    end

    def test_autolink
      assert_equal %(<a href="https://example.com">https://example.com</a>),
                   @converter.convert("<https://example.com>")
    end

    def test_date_time_entity
      assert_equal %(<tg-time unix="1647531900" format="wDT">tomorrow</tg-time>),
                   @converter.convert("[tomorrow](tg://time?unix=1647531900&format=wDT)")
    end

    def test_custom_emoji
      assert_equal %(<tg-emoji emoji-id="5368324170671202286">🙂</tg-emoji>),
                   @converter.convert("![🙂](tg://emoji?id=5368324170671202286)")
    end

    # ---- Blocks ----

    def test_blockquote
      assert_equal "<blockquote>quote here</blockquote>", @converter.convert("> quote here")
    end

    def test_blockquote_formats_its_content
      assert_equal "<blockquote>line <i>two</i></blockquote>", @converter.convert("> line *two*")
    end

    def test_expandable_blockquote
      assert_equal "<blockquote expandable>hidden</blockquote>", @converter.convert("**> hidden")
    end

    def test_nested_blockquotes_are_flattened
      # Telegram can't nest blockquote entities.
      assert_equal "<blockquote>outer\ninner</blockquote>", @converter.convert("> outer\n> > inner")
    end

    def test_heading_becomes_bold
      assert_equal "<b>Result</b>", @converter.convert("## Result")
    end

    def test_horizontal_rule
      assert_equal "——————————", @converter.convert("---")
    end

    def test_bullet_and_task_lists
      assert_equal "• one\n• two", @converter.convert("- one\n- two")
      assert_equal "☑ done\n☐ todo", @converter.convert("- [x] done\n- [ ] todo")
      assert_equal "text\n  • nested", @converter.convert("text\n  * nested")
    end

    def test_numbered_list_keeps_its_numbers
      assert_equal "1. first\n2. second", @converter.convert("1. first\n2. second")
    end

    # ---- Tables ----

    def test_table_becomes_aligned_monospace
      input = "| Name | Qty |\n|------|-----|\n| apple | 3 |\n| banana | 12 |"
      result = @converter.convert(input)

      assert result.start_with?("<pre>")
      assert result.end_with?("</pre>")
      assert_includes result, "apple"
      assert_includes result, "banana"
      assert_includes result, "│"
      assert_includes result, "┼"
      refute_includes result, "\\|"
    end

    # ---- Splitting ----

    def test_short_message_is_one_chunk
      chunks = @converter.chunks("hello **world**", 4096)
      assert_equal [ "hello <b>world</b>" ], chunks
    end

    def test_chunks_never_exceed_the_limit
      text = (1..80).map { |i| "Paragraph #{i} with a [link](https://example.com/#{i}) and **bold**." }.join("\n\n")
      chunks = @converter.chunks(text, 300)

      assert_operator chunks.size, :>, 1
      assert chunks.all? { |chunk| chunk.length <= 300 }
      assert_includes chunks.join, "Paragraph 80"
    end

    def test_chunks_keep_entities_balanced
      text = (1..40).map { |i| "> quoted **line** #{i} with *italic* and `code`" }.join("\n\n")
      chunks = @converter.chunks(text, 200)

      chunks.each do |chunk|
        assert_equal chunk.scan(/<b>/).size, chunk.scan(%r{</b>}).size, "unbalanced <b> in #{chunk[0, 40]}"
        assert_equal chunk.scan(/<i>/).size, chunk.scan(%r{</i>}).size, "unbalanced <i>"
        assert_equal chunk.scan(%r{<code>}).size, chunk.scan(%r{</code>}).size, "unbalanced <code>"
      end
    end

    def test_a_huge_code_block_is_split_and_reopened
      text = "```ruby\n" + (1..300).map { |i| "puts #{i} # <tag> & stuff" }.join("\n") + "\n```"
      chunks = @converter.chunks(text, 400)

      assert_operator chunks.size, :>, 1
      chunks.each do |chunk|
        assert_operator chunk.length, :<=, 400
        assert_includes chunk, "<pre>"
        assert_includes chunk, "</pre>"
      end
      assert_includes chunks.join, "puts 300"
    end

    def test_chunks_measure_length_in_utf16_units
      # Telegram's 4096 limit counts UTF-16 code units, so every emoji is two.
      text = "😀 party " * 400
      chunks = @converter.chunks(text, 100)

      chunks.each do |chunk|
        utf16 = chunk.length + chunk.gsub(/[^\u{0}-\u{FFFF}]/, "").length
        assert_operator utf16, :<=, 100, "chunk exceeds 100 UTF-16 units"
      end
    end

    def test_split_does_not_break_an_html_entity
      text = ("a&b " * 200)
      chunks = @converter.chunks(text, 40)

      chunks.each { |chunk| refute_match(/&[a-z]*\z/, chunk) }
    end

    # ---- Plain text fallback ----

    def test_to_plain_strips_tags_and_decodes_entities
      html = %(<b>Hi</b> <a href="https://x.y/a_(b)">link</a> &amp; &lt;tag&gt;)
      assert_equal "Hi link & <tag>", @converter.to_plain(html)
    end

    def test_to_plain_of_converted_text
      assert_equal "a & b", @converter.to_plain(@converter.convert("**a** & b"))
    end
  end
end
