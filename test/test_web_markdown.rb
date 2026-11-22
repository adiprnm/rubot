# frozen_string_literal: true

require "test_helper"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # Markdown as the page renders it: blocks, inline marks, quotes and the styles around them.
    class TestWebMarkdown < Minitest::Test
      include WebChannelSupport

      # --- Format ---------------------------------------------------------

      def test_markdown_escapes_html
        assert_equal "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>", Format.markdown("<script>alert(1)</script>")
      end

      def test_markdown_renders_fenced_code_without_escaped_newlines
        html = Format.markdown("before\n```ruby\nputs 1\n```\nafter")

        # The language is carried on both boxes: the <pre> for the label, the
        # <code> for a highlighter to hook onto.
        assert_includes html, %(<pre class="code" data-lang="ruby"><code class="language-ruby">)
        assert_includes html, "</code></pre>"
        refute_includes html, "&#10;", "a newline inside code is a newline, not an entity"
        assert_includes html, "before"
        assert_includes html, "after"
      end

      def test_markdown_keeps_unterminated_fence_as_streaming_code
        html = Format.markdown("```ruby\nx = 1")

        assert_includes html, "streaming"
        assert_includes html, %(data-lang="ruby")
        assert_includes html, %(<span class="tok-num">1</span>)
      end

      def test_a_code_block_carries_a_copy_button
        html = Format.markdown("```ruby\nputs 1\n```")

        # The button is markup, not something a script adds afterwards: a
        # block that streamed in has to arrive already copyable. The label
        # follows it, so the language stays in the corner it was in.
        assert_includes html, %(<div class="code-block"><div class="code-top"><button type="button" class="code-copy" data-copy)
        assert_includes html, %(<span class="code-lang">ruby</span>)
      end

      def test_the_copy_button_is_a_mark_with_its_words_kept_for_a_reader
        html = Format.markdown("```ruby\nputs 1\n```")

        # A mark says nothing out loud, so the name stays behind it: the
        # button is the thing a screen reader announces, and the three marks
        # are decorative — one of them is shown, the CSS picks which.
        assert_includes html, %(<svg class="code-copy-icon copy")
        assert_includes html, %(<svg class="code-copy-icon done")
        assert_includes html, %(<svg class="code-copy-icon failed")
        html.scan(/<svg class="code-copy-icon[^>]*>/) do |tag|
          assert_includes tag, %(aria-hidden="true"), "a drawn mark must not be read out"
        end
        assert_includes html, %(<span class="sr-only" aria-live="polite">Salin isi blok kode</span>)
        refute_includes html, ">Salin</button>", "the word is no longer what is seen"
      end

      def test_a_block_without_a_language_still_offers_the_copy_button
        html = Format.markdown("```\nplain\n```")

        assert_includes html, %(<button type="button" class="code-copy" data-copy)
        refute_includes html, "code-lang", "there is no language to name"
      end

      def test_a_streaming_block_is_marked_so_the_button_stays_hidden
        html = Format.markdown("```ruby\nputs 1")

        assert_includes html, %(<div class="code-block streaming">)
      end

      # --- quoting a paragraph --------------------------------------------

      # In the page every paragraph can be handed back to the field as context.
      # The source Markdown rides in `data-quote` rather than the rendered text,
      # so a paragraph full of emphasis and code arrives in the composer the way
      # the model wrote it, and the mark sits beside the text so a paragraph
      # streamed into the page is already quotable when it lands.
      def test_a_quotable_paragraph_carries_its_markdown_and_a_mark
        html = Format.markdown("Halo **dunia** & `kode`.", quotable: true)

        assert_includes html, %(<p class="para" data-quote="Halo **dunia** &amp; `kode`.")
        assert_includes html, %(<button type="button" class="para-quote")
        assert_includes html, %(aria-label="Kutip paragraf ini")
      end

      def test_the_quote_mark_is_opt_in_so_plain_markdown_stays_plain
        assert_equal "<p>Halo <strong>dunia</strong> &amp; <code>kode</code>.</p>",
                     Format.markdown("Halo **dunia** & `kode`.")
      end

      def test_every_paragraph_gets_its_own_quote_mark
        html = Format.markdown("satu\n\ndua", quotable: true)

        assert_equal 2, html.scan('class="para-quote"').length
        assert_includes html, %(data-quote="satu")
        assert_includes html, %(data-quote="dua")
      end

      # A list is quotable too, and it takes a wrapper: `<ul>` may only hold
      # items, so the mark cannot live inside it as a child. The wrapper owns
      # the source and the gutter, and the list keeps its own margins.
      def test_a_quotable_list_carries_its_own_markdown_and_label
        html = Format.markdown("- satu\n- dua", quotable: true)

        assert_includes html, %(<div class="para-list" data-quote="- satu\n- dua")
        assert_includes html, %(data-quote-kind="Daftar · 2 butir")
        assert_includes html, %(aria-label="Kutip daftar ini")
        assert_includes html, "<ul><li data-quote=\"- satu\">satu</li>"
      end

      # Each item carries the line it was written as, so a long press on one
      # item quotes that item alone. The line is unescaped before being escaped
      # for the attribute: escaping it twice would send the model `&amp;`.
      def test_every_list_item_carries_its_own_source_line
        html = Format.markdown("- satu & dua\n- tiga", quotable: true)

        assert_includes html, %(<li data-quote="- satu &amp; dua">satu &amp; dua</li>)
        assert_includes html, %(<li data-quote="- tiga">tiga</li>)
      end

      # The source is kept line for line, so a numbered list with a nested one
      # arrives in the composer as the same structure rather than as one run.
      def test_a_quoted_list_keeps_its_numbering_and_nesting
        html = Format.markdown("1. satu\n2. dua\n   - anak", quotable: true)

        assert_includes html, %(data-quote="1. satu\n2. dua\n   - anak")
      end

      def test_a_list_is_not_wrapped_unless_the_page_asks
        assert_equal "<ul><li>satu</li><li>dua</li></ul>", Format.markdown("- satu\n- dua")
      end

      def test_markdown_inline_code_and_bold
        assert_equal "<p><code>x</code> <strong>y</strong></p>", Format.markdown("`x` **y**")
      end

      # --- lists ----------------------------------------------------------

      def test_markdown_renders_bullets_as_a_list_not_broken_lines
        html = Format.markdown("Ringkasnya:\n- satu\n- dua\n- tiga")

        assert_includes html, "<ul><li>satu</li><li>dua</li><li>tiga</li></ul>"
        refute_includes html, "- satu"
      end

      def test_markdown_renders_numbered_items_as_an_ordered_list
        html = Format.markdown("1. pertama\n2. kedua")

        assert_includes html, "<ol><li>pertama</li><li>kedua</li></ol>"
      end

      def test_markdown_formats_marks_inside_list_items
        html = Format.markdown("- **dua** dengan `kode`")

        assert_includes html, "<li><strong>dua</strong> dengan <code>kode</code></li>"
      end

      def test_a_plain_line_ends_the_list
        html = Format.markdown("- satu\ncatatan biasa")

        assert_includes html, "</ul>", "the list must be closed before the paragraph"
        assert_includes html, "catatan biasa"
        refute_includes html, "<li>catatan biasa"
      end

      # The line that introduces a list is a paragraph of its own, and it comes
      # before the list — not buffered until the block after it, which used to
      # put the list above its own introduction and glue the following line
      # onto it.
      def test_the_line_above_a_list_stays_above_it
        html = Format.markdown("Ringkasnya:\n- satu\ncatatan biasa")

        assert_equal "<p>Ringkasnya:</p>\n<ul><li>satu</li></ul>\n<p>catatan biasa</p>", html
      end

      # --- tables ---------------------------------------------------------

      def test_a_pipe_table_becomes_a_real_table
        html = Format.markdown(<<~MD)
          | Tier | Harga |
          |------|------:|
          | Signature | 179000 |
          | Favorit | 129000 |
        MD

        assert_includes html, %(<table class="md-table">)
        assert_includes html, "<thead><tr><th"
        assert_includes html, "<tbody><tr><td"
        assert_includes html, "Signature"
        assert_includes html, "129000"

        # The separator is decoration for the reader, never a row.
        refute_includes html, "|------|"
        refute_includes html, "<td>---"
      end

      def test_a_table_header_is_th_and_the_body_is_td
        html = Format.markdown("| a | b |\n|---|---|\n| 1 | 2 |")

        assert_equal 2, html.scan(/<th[ >]/).size
        assert_equal 2, html.scan(/<td[ >]/).size
        assert_includes html, "<th>a</th>"
        assert_includes html, "<td>1</td>"
      end

      def test_the_separator_colons_set_the_column_alignment
        html = Format.markdown("| kiri | tengah | kanan |\n|:---|:---:|---:|\n| a | b | c |")

        assert_includes html, %(<th style="text-align:left">kiri</th>)
        assert_includes html, %(<th style="text-align:center">tengah</th>)
        assert_includes html, %(<th style="text-align:right">kanan</th>)
        assert_includes html, %(<td style="text-align:right">c</td>)
      end

      def test_a_column_without_colons_carries_no_alignment
        html = Format.markdown("| a |\n|---|\n| 1 |")

        refute_includes html, "text-align"
      end

      # A row with fewer cells than the header still lines up instead of
      # shifting the columns after it.
      def test_a_ragged_row_is_padded_to_the_widest_row
        html = Format.markdown("| a | b | c |\n|---|---|---|\n| 1 |")

        assert_equal 3, html.scan(/<td/).size
        assert_includes html, "<td></td>"
      end

      # Pipes inside a cell are written "\|"; splitting on them naively would
      # turn one cell into two.
      def test_an_escaped_pipe_stays_inside_its_cell
        html = Format.markdown("| ekspresi | arti |\n|---|---|\n| a \\| b | atau |")

        assert_equal 2, html.scan(/<td/).size
        assert_includes html, "<td>a | b</td>"
      end

      def test_cell_markup_is_parsed_inside_the_table
        html = Format.markdown("| nama | nilai |\n|---|---|\n| **tebal** | `kode` |")

        assert_includes html, "<td><strong>tebal</strong></td>"
        assert_includes html, "<td><code>kode</code></td>"
        refute_includes html, "**tebal**"
      end

      # GFM does not require the outer pipes, and models write it both ways.
      def test_a_table_without_the_outer_pipes_still_renders
        html = Format.markdown("Tier | Harga\n--- | ---\nSignature | 179000")

        assert_includes html, "<th>Tier</th>"
        assert_includes html, "<td>179000</td>"
      end

      # Indentation is how a table sits inside a list item, and the leading
      # spaces must not stop it being recognised.
      def test_an_indented_table_still_renders
        html = Format.markdown("- pilihan:\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |")

        assert_includes html, "<ul><li>pilihan:</li></ul>"
        assert_includes html, "<th>a</th>"
        assert_includes html, "<td>2</td>"
      end

      def test_a_table_ends_where_the_pipes_stop
        html = Format.markdown("| a |\n|---|\n| 1 |\nsetelah tabel")

        assert_includes html, "</table></div>"
        assert_includes html, "setelah tabel"
        refute_match(%r{<td>setelah tabel}, html)
      end

      # While streaming, the header arrives before its separator. Nothing is a
      # table yet, and the half-written line must not vanish.
      def test_a_header_without_its_separator_is_still_text
        html = Format.markdown("| Tier | Harga |")

        refute_includes html, "<table"
        assert_includes html, "Tier"
      end

      # The separator alone is not a table either: a table needs a header.
      def test_a_separator_without_a_header_is_not_a_table
        html = Format.markdown("teks\n|---|---|")

        refute_includes html, "<table"
      end

      def test_a_table_inside_a_message_keeps_its_own_block
        html = Format.markdown("Harga:\n\n| a |\n|---|\n| 1 |\n\nSelesai.")

        assert_includes html, "Harga:"
        assert_includes html, "Selesai."
        assert_operator html.index("Harga:"), :<, html.index("<table")
        assert_operator html.index("Selesai."), :>, html.index("</table>")
      end

      # Cells are escaped before the block parser runs, so a table cannot
      # smuggle a tag through.
      def test_a_table_escapes_its_cells
        html = Format.markdown("| a |\n|---|\n| <b>x</b> |")

        assert_includes html, "&lt;b&gt;x&lt;/b&gt;"
        refute_includes html, "<b>x</b>"
      end

      def test_a_bullet_list_and_a_numbered_list_do_not_merge
        html = Format.markdown("- satu\n1. pertama")

        assert_includes html, "</ul>"
        assert_includes html, "<ol><li>pertama</li></ol>"
      end

      # A list that is still arriving is a list: the closing tag only has to
      # come from the formatter, not from the stream.
      def test_an_unterminated_list_still_renders_while_streaming
        assert_includes Format.markdown("- setengah terkirim"), "<ul><li>setengah terkirim</li></ul>"
      end

      # A fenced block used to be replaced by a NUL placeholder, which
      # `String#strip` deletes — the block then fell through and was printed
      # as a paragraph. The marker has to survive stripping.
      def test_a_code_block_between_lines_keeps_its_own_block
        html = Format.markdown("sebelum\n```ruby\nx = 1\n```\n- sesudah")

        assert_includes html, %(<pre class="code" data-lang="ruby">)
        assert_includes html, "<ul><li>sesudah</li></ul>"
        refute_includes html, "sebelum<br><pre", "the code block is its own block, not a line"
      end

      def test_blank_lines_separate_blocks_without_stray_breaks
        refute_includes Format.markdown("satu\n\ndua"), "<br><br>"
      end

      # --- headings -------------------------------------------------------

      def test_hashes_open_a_heading_only_when_a_space_follows
        assert_equal "<h1>Judul</h1>", Format.markdown("# Judul")
        assert_equal "<h2>Sub</h2>", Format.markdown("## Sub")
        assert_equal "<h3>Kecil</h3>", Format.markdown("### Kecil")

        # A tag is not a heading, and a line of hashes alone is not one either.
        assert_equal "<p>#hashtag</p>", Format.markdown("#hashtag")
      end

      def test_a_heading_ends_the_paragraph_and_the_list_above_it
        html = Format.markdown("- satu\n# Bagian\nisi")

        assert_includes html, "<ul><li>satu</li></ul>"
        assert_includes html, "<h1>Bagian</h1>"
        assert_includes html, "isi"
      end

      def test_marks_inside_a_heading_are_parsed
        assert_equal "<h2>Halo <strong>dunia</strong></h2>", Format.markdown("## Halo **dunia**")
      end

      # --- task lists -----------------------------------------------------

      def test_a_task_list_draws_a_box_and_says_which_one_it_is
        html = Format.markdown("- [ ] belum\n- [x] sudah")

        assert_includes html, %(<li class="task"><span class="task-box")
        assert_includes html, %(<li class="task is-done"><span class="task-box")
        assert_includes html, "belum"
        assert_includes html, "sudah"
        refute_includes html, "[ ]", "the box is drawn, not spelled"
        refute_includes html, "[x]"
      end

      def test_a_task_list_closes_every_item
        html = Format.markdown("- [ ] satu\n- [ ] dua")

        assert_equal 2, html.scan("</li>").size
        assert_includes html, "</li><li class=\"task\">"
      end

      def test_a_bare_box_is_still_a_task
        assert_includes Format.markdown("- [ ]"), %(class="task")
      end

      # --- nested lists ---------------------------------------------------

      def test_a_deeper_item_opens_a_list_inside_the_item_above_it
        html = Format.markdown("- satu\n  - anak\n- dua")

        assert_equal "<ul><li>satu<ul><li>anak</li></ul></li><li>dua</li></ul>", html
      end

      def test_a_nested_ordered_list_inside_a_bulleted_one_keeps_both_kinds
        html = Format.markdown("1. satu\n   - a\n   - b\n2. dua")

        assert_equal "<ol><li>satu<ul><li>a</li><li>b</li></ul></li><li>dua</li></ol>", html
      end

      # --- blockquotes ----------------------------------------------------

      # One element for the whole run: a border drawn per line is a stack of
      # separate rules with a gap between each, which reads as several quotes.
      def test_a_multi_line_quote_is_one_blockquote
        html = Format.markdown("> satu\n> dua\n> tiga")

        assert_equal "<blockquote><p>satu<br>dua<br>tiga</p></blockquote>", html
      end

      def test_a_blank_line_still_ends_a_quote
        html = Format.markdown("> satu\n\nbiasa")

        assert_includes html, "<blockquote><p>satu</p></blockquote>"
        assert_includes html, "biasa"
      end

      # "> > x" is a quote inside a quote: the depth is read per line, so the
      # tree is built while walking down and a shallower line closes the
      # levels above it.
      def test_a_nested_quote_becomes_a_quote_inside_a_quote
        html = Format.markdown("> luar\n> > dalam\n> luar lagi")

        assert_equal "<blockquote><p>luar</p><blockquote><p>dalam</p></blockquote><p>luar lagi</p></blockquote>",
                     html
      end

      def test_three_levels_of_quote_nest_three_deep
        html = Format.markdown("> > > tiga")

        assert_equal "<blockquote><blockquote><blockquote><p>tiga</p></blockquote></blockquote></blockquote>",
                     html
      end

      def test_consecutive_lines_at_one_depth_share_a_paragraph
        html = Format.markdown("> > satu\n> > dua")

        assert_equal "<blockquote><blockquote><p>satu<br>dua</p></blockquote></blockquote>", html
      end

      # --- footnotes ------------------------------------------------------

      # A note leaves the flow and is drawn once, under a rule at the end, the
      # way every markdown renderer hoists it: `[^1]: ...` sitting in the
      # middle of an answer would read as prose.
      def test_a_footnote_is_hoisted_under_a_rule
        html = Format.markdown("Harga naik[^1].\n\n[^1]: Mulai November.")

        assert_includes html, %(<sup class="fn-ref"><a href="#fn-1" id="fnref-1">1</a></sup>)
        assert_includes html, %(<section class="footnotes">)
        assert_includes html, %(<li id="fn-1">Mulai November.)
        refute_includes html, "<p>[^1]: Mulai November.</p>", "the definition is not part of the prose"
      end

      # Numbered by first mention, not by the order the definitions happen to
      # be written.
      def test_footnote_numbers_follow_the_reference_not_the_definition
        html = Format.markdown("Dua[^b] lalu satu[^a].\n\n[^a]: catatan a\n[^b]: catatan b")

        assert_includes html, %(id="fn-1">catatan b)
        assert_includes html, %(id="fn-2">catatan a)
        assert_includes html, %(<a href="#fn-1" id="fnref-1">1</a></sup> lalu)
      end

      def test_a_note_keeps_its_inline_markup
        html = Format.markdown("Lihat[^n]\n\n[^n]: **wajib** `dp` [situs](https://x.test)")

        assert_includes html, %(<li id="fn-1"><strong>wajib</strong> <code>dp</code> )
        assert_includes html, %(<a href="https://x.test")
      end

      # An id with no definition is not a citation: it is the text that was
      # written, which is what a half-streamed answer has.
      def test_a_reference_without_a_definition_stays_literal
        html = Format.markdown("Harga[^1]")

        assert_equal "<p>Harga[^1]</p>", html
      end

      def test_a_definition_inside_a_code_block_stays_code
        html = Format.markdown("```\n[^1]: bukan catatan\n```\n[^1]: catatan asli")

        assert_includes html, "[^1]: bukan catatan"
        assert_includes html, %(<li id="fn-1">catatan asli)
      end

      # A note cited twice has to anchor twice: two ids in one document is
      # invalid HTML and the back link would land on the first only.
      def test_a_note_cited_twice_anchors_twice
        html = Format.markdown("Satu[^a] dua[^a]\n\n[^a]: catatan")

        assert_includes html, %(id="fnref-1")
        assert_includes html, %(id="fnref-1-2")
      end

      def test_a_document_without_notes_draws_no_section
        refute_includes Format.markdown("biasa saja"), "footnotes"
      end

      # --- paragraphs -----------------------------------------------------

      # A paragraph is an element, not a bare run of text. Without a block the
      # margins of the heading around it have nothing to sit on, and a heading
      # after a paragraph reads as glued to the line before it.
      def test_a_paragraph_is_a_p_element
        assert_equal "<p>satu</p>", Format.markdown("satu")
        assert_equal "<p>satu<br>dua</p>", Format.markdown("satu\ndua")
      end

      def test_a_heading_keeps_its_room_after_a_paragraph
        html = Format.markdown("sebelum\n\n# Judul\n\nsesudah")

        assert_includes html, "<p>sebelum</p>\n<h1>Judul</h1>\n<p>sesudah</p>"
        refute_includes html, "<h1>Judul</h1>sebelum",
                        "the heading must not be the first child of the run"
      end

      # --- inline marks ---------------------------------------------------

      def test_bold_italic_bold_italic_and_strikethrough
        assert_equal "<p><strong>b</strong></p>", Format.markdown("**b**")
        assert_equal "<p><em>i</em></p>", Format.markdown("*i*")
        assert_equal "<p><em>i</em></p>", Format.markdown("_i_")
        assert_equal "<p><strong><em>x</em></strong></p>", Format.markdown("***x***")
        assert_equal "<p><del>d</del></p>", Format.markdown("~~d~~")
      end

      def test_the_other_spelling_of_bold_and_italic
        assert_equal "<p><strong>b</strong></p>", Format.markdown("__b__")
        assert_equal "<p><em>i</em></p>", Format.markdown("_i_")
      end

      # An underscore inside a word is a name, not an emphasis: snake_case
      # must survive a message about code.
      def test_an_underscore_inside_a_word_is_not_italic
        assert_equal "<p>snake_case_name</p>", Format.markdown("snake_case_name")
      end

      def test_marks_nest
        assert_equal "<p><strong>bold with <code>code</code></strong></p>",
                     Format.markdown("**bold with `code`**")
      end

      # --- links and images -----------------------------------------------

      def test_a_link_becomes_an_anchor
        html = Format.markdown("lihat [situs](https://kanyaah.com)")

        assert_includes html, %(<a href="https://kanyaah.com")
        assert_includes html, ">situs</a>"
        assert_includes html, 'rel="noopener noreferrer"'
      end

      def test_an_image_becomes_an_img_with_its_alt_text
        html = Format.markdown("![papan](/img/a.png)")

        assert_includes html, %(<img src="/img/a.png" alt="papan")
      end

      # A link is text from the model landing in an attribute. Only the
      # schemes a chat has business carrying get through; anything else is
      # shown as the literal text that was written.
      def test_a_dangerous_url_stays_literal_text
        html = Format.markdown("[klik](javascript:alert(1))")

        refute_includes html, "href="
        assert_includes html, "javascript:alert(1)"
      end

      def test_an_image_cannot_smuggle_a_script_url
        html = Format.markdown("![x](javascript:alert(1))")

        refute_includes html, "<img"
      end

      def test_a_relative_link_and_a_mail_link_are_allowed
        assert_includes Format.markdown("[a](/s/web_rubot)"), %(href="/s/web_rubot")
        assert_includes Format.markdown("[m](mailto:a@b.c)"), %(href="mailto:a@b.c")
      end

      # --- rules ----------------------------------------------------------

      def test_a_line_of_dashes_is_a_rule_not_a_list
        assert_equal %(<hr class="rule">), Format.markdown("---")
        assert_equal %(<hr class="rule">), Format.markdown("***")
        assert_equal %(<hr class="rule">), Format.markdown("- - -")
      end

      # --- markdown styles ------------------------------------------------

      # The hero heading needs the space above it to read as a heading rather
      # than as the last line of the paragraph before it.
      def test_headings_carry_room_above_them
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        heading = css[/^\.text h1,.*?^  font-weight: 600;/m]

        refute_nil heading, "the heading rule is missing from app.css"
        margin = heading[/margin:\s*([^;]+);/, 1].to_s

        refute_empty margin, "a heading needs a margin, or it sticks to the text above"
        refute_equal "0", margin.split.first
      end

      # The tick is drawn from two borders and rotated; it is centred by
      # translating half its own size back, because pinning it by left/top put
      # it in the corner of the box instead of in the middle.
      def test_the_tick_is_centred_by_translation
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        tick = css[/^\.text li\.task\.is-done > \.task-box::after \{.*?\n\}/m]

        refute_nil tick, "the tick rule is missing from app.css"
        assert_includes tick, "translate(-50%, -50%)"
      end
    end
  end
end
