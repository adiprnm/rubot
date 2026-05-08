# frozen_string_literal: true

require_relative "test_helper"

module Rubot
  class TelegramMarkdownTest < Minitest::Test
    def setup
      @converter = TelegramMarkdown
    end

    # ---- Plain text ----

    def test_plain_text_unchanged
      assert_equal "Hello world", @converter.convert("Hello world")
    end

    def test_special_chars_are_escaped
      result = @converter.convert("Hello. World!")
      assert_equal "Hello\\. World\\!", result
    end

    def test_dash_and_underscore_escaped
      result = @converter.convert("foo-bar_baz")
      assert_equal "foo\\-bar\\_baz", result
    end

    def test_backslash_doubled
      result = @converter.convert("path\\to\\file")
      assert_equal "path\\\\to\\\\file", result
    end

    # ---- Bold ----

    def test_double_asterisk_bold
      result = @converter.convert("Hello **world**")
      assert_equal "Hello *world*", result
    end

    def test_bold_with_special_chars_inside
      result = @converter.convert("**Hello, world.**")
      assert_equal "*Hello, world\\.*", result
    end

    # ---- Italic ----

    def test_single_underscore_italic
      result = @converter.convert("Hello _world_")
      assert_equal "Hello _world_", result
    end

    # ---- Bold italic ----

    def test_triple_asterisk_bold_italic
      result = @converter.convert("***Hello***")
      assert_equal "*_Hello_*", result
    end

    # ---- Strikethrough ----

    def test_double_tilde_strikethrough
      result = @converter.convert("~~deleted~~")
      assert_equal "~deleted~", result
    end

    # ---- Inline code ----

    def test_inline_code_preserved
      # Inside code blocks, content is literal — no escaping for ( ) etc.
      result = @converter.convert("Use `foo()` here")
      assert_equal "Use `foo()` here", result
    end

    def test_inline_code_backslash_escaped
      # Inside code: \ must be escaped
      result = @converter.convert("Path: `C:\\Users`")
      assert_equal "Path: `C:\\\\Users`", result
    end

    # ---- Fenced code block ----

    def test_fenced_code_block_preserved
      input = "Here is code:\n```\nprint('hello')\n```"
      result = @converter.convert(input)
      # Inside code blocks, chars are literal — only \ and ` get escaped
      assert_includes result, "```\n"
      assert_includes result, "print('hello')"
    end

    def test_fenced_code_block_with_lang
      input = "```ruby\nputs 'hi'\n```"
      result = @converter.convert(input)
      assert_includes result, "```ruby"
      refute_includes result, "CODE"
    end

    # ---- Links ----

    def test_link_preserved
      result = @converter.convert("Check [Google](https://google.com)")
      # URL content: only \ ( ) _ need escaping in the URL part
      assert_equal "Check [Google](https://google.com)", result
    end

    def test_link_with_bold_text
      result = @converter.convert("[**Bold** link](https://example.com)")
      assert_includes result, "*Bold*"
      assert_includes result, "](https"
    end

    # ---- Underline ----

    def test_double_underscore_underline
      result = @converter.convert("__underline me__")
      assert_equal "__underline me__", result
    end

    # ---- Blockquote ----

    def test_blockquote
      result = @converter.convert("> quote here")
      assert_equal ">quote here", result
    end

    # ---- Mixed formatting ----

    def test_mixed_bold_and_italic_and_code
      input = "**bold** and _italic_ and `code`"
      result = @converter.convert(input)
      assert_equal "*bold* and _italic_ and `code`", result
    end

    def test_real_world_bot_response
      input = <<~MSG
        Here's the result:

        ```ruby
        def hello
          puts 'Hello, world!'
        end
        ```

        **Done!** Let me know if you need anything else.
      MSG
      result = @converter.convert(input)
      assert_includes result, "```ruby"
      assert_includes result, "*Done\\!*"
      refute_includes result, "CODE"
      refute_includes result, "LINK"
    end

    # ---- Empty / nil ----

    def test_nil_returns_empty_string
      assert_equal "", @converter.convert(nil)
    end

    def test_empty_string_returns_empty_string
      assert_equal "", @converter.convert("")
    end

    # ---- No placeholder leakage ----

    def test_no_control_chars_leak_in_normal_text
      result = @converter.convert("Hello **world**")
      refute_match(/[\x01-\x1F]/, result)
    end

    def test_no_link_placeholder_leaks
      result = @converter.convert("See [this](http://example.com) please")
      refute_includes result, "L0"
      assert_match(/\[this\]/, result)
    end
  end
end
