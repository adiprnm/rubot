# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  module Web
    class TestWebChannel < Minitest::Test
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

      # --- Turn -----------------------------------------------------------

      # A clock the test can move, so the three-second rules are checked
      # without sleeping through them.
      class FakeClock
        def initialize(now = 100.0)
          @now = now
        end

        def call
          @now
        end

        def advance(seconds)
          @now += seconds
        end
      end

      def build(clock = FakeClock.new)
        Turn.new(id: "t1", session_id: "s1", clock: clock)
      end

      # A provider that answers without a network: one canned reply for the turn
      # and one title for the naming request that follows it. The naming call is
      # told apart by its system prompt, which is the only thing a stub can see.
      class NamingProvider
        attr_reader :calls

        def initialize(title: "Undangan pernikahan")
          @title = title
          @calls = []
        end

        def chat(messages, tools: nil)
          @calls << messages
          if messages.any? { |msg| msg["content"].to_s.include?("You name conversations") }
            { "content" => @title }
          else
            { "content" => "Siap, undangannya sudah saya susun." }
          end
        end

        def chat_stream(messages, tools: nil, &_on_chunk)
          chat(messages, tools: tools)
        end

        def naming_calls
          @calls.count { |messages| messages.any? { |msg| msg["content"].to_s.include?("You name conversations") } }
        end
      end

      # The shell of the page with nothing in it but what these view tests need:
      # a persona, one open session, and whatever turn is still in flight.
      def render_page(live_turn: nil, persona_prompt: "")
        View.render("index",
                    personas: [], groups: { pinned: [], recent: [], page: 1, pages: 1, recent_total: 0, pinned_limit: 10, current: "web_rubot" },
                    slug: "rubot", persona_label: "Rubot", persona_emoji: "🤖",
                    persona_prompt: persona_prompt,
                    persona_model: "m", session_id: "web_rubot",
                    persona_model_value: "", model_choices: [],
                    session_model: "", session_thinking: "medium", session_requests: 3, persona_thinking: "medium",
                    session_short: "web_rubot", session_label: "Sesi baru",
                    document_title: "rubot · Rubot", live_turn: live_turn,
                    live_prompt_shown: false, token_query: "",
                    page: { entries: [], more: false, before: 0 }, older_url: "",
                    usage: { cost: "—", cache: "—", ctx: "—", cause: "" },
                    usage_facts: { model: "m · openai", cost: "—", breakdown: "",
                                   requests: "0", messages: "0", tokens_in: "0",
                                   tokens_out: "0", reasoning: "", cache: "—",
                                   cache_history: "", cache_cause: "", re_read: "0", saved: "", ctx: "—" })
      end

      # Enough of a WEBrick::HTTPResponse for the channel's rendering paths: it
      # only ever writes a status, a body and a header or two.
      class FakeResponse
        attr_accessor :body, :status
        attr_reader :headers

        def initialize
          @headers = {}
          @status = 200
          @body = ""
        end

        def []=(key, value)
          @headers[key] = value
        end
      end

      # The other half of a request: a path, a method and a query string. The
      # routing table is the one thing a view test cannot reach, so a route that
      # is wired to nothing still has to fail here rather than in a browser.
      class FakeRequest
        attr_reader :path, :request_method, :query, :header

        def initialize(path, method: "GET", query: {})
          @path = path
          @request_method = method
          @query = query
          @header = {}
        end
      end

      # A session stand-in that only has to hand out tools: the delivery bind
      # reads nothing else.
      class FakeToolAgent
        def initialize(*tools)
          @tools = Rubot::Tools::Registry.new
          tools.each { |tool| @tools.register(tool) }
        end

        attr_reader :tools
      end

      # Stands in for a session actor when only the cron call matters.
      class RecordingCronSession
        attr_reader :calls, :titles

        def initialize(reply: "done")
          @reply = reply
          @calls = []
          @titles = []
        end

        def process_cron(text, fresh: false)
          @calls << { text: text, fresh: fresh }
          @reply
        end

        def set_session_title(title)
          @titles << title
          title
        end
      end

      # Says where a conversation is rooted, which is all the channel asks of
      # the pool when it binds the cron tool.
      class FakeWorkspacePool
        def initialize(workspace)
          @workspace = workspace
        end

        def workspace_for_session(_sid)
          @workspace
        end
      end

      def setup
        @fixtures = []
      end

      def teardown
        Rubot::Session.store&.close
        Rubot::Session.store = nil
        Array(@fixtures).each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
      end

      # A channel whose config points at a throwaway ~/.rubot: personas.json
      # next to config.yml, conversations in <dir>/sessions. The channel is
      # given the config directly, so no session pool (and no Ractor) is
      # spawned just to list files.
      def channel_with_sessions(personas:, sessions: {}, titles: {})
        dir = Dir.mktmpdir("rubot-web-sessions")
        @fixtures << dir
        workspace = File.join(dir, "workspace")
        FileUtils.mkdir_p(File.join(dir, "sessions"))
        FileUtils.mkdir_p(workspace)

        File.write(File.join(dir, "personas.json"), JSON.generate(personas))
        sessions.each do |id, prompt|
          data = {
            "id" => id,
            "updated_at" => Time.now.utc.iso8601,
            "messages" => [
              { "role" => "user", "content" => prompt },
              { "role" => "assistant", "content" => "Siap." }
            ]
          }
          data["title"] = titles[id] if titles[id]
          File.write(File.join(dir, "sessions", "#{id}.json"), JSON.generate(data))
        end

        config = Rubot::Config.from_data(
          { "agents" => { "defaults" => { "workspace" => workspace } } },
          config_path: File.join(dir, "config.yml")
        )

        channel = Rubot::Channels::Web.new(channel_config: {})
        channel.instance_variable_set(:@app_config, config)
        channel
      end

      # The same channel, but with the archive open — which is the only thing
      # that can answer a search. Messages go through the store rather than into
      # a JSON file, so history, ranking and the message index all come from the
      # place the page reads them in production.
      def channel_with_archive(personas:, messages:, titles: {})
        dir = Dir.mktmpdir("rubot-web-archive")
        @fixtures << dir
        workspace = File.join(dir, "workspace")
        FileUtils.mkdir_p(File.join(dir, "sessions"))
        FileUtils.mkdir_p(workspace)

        File.write(File.join(dir, "personas.json"), JSON.generate(personas))

        store = Rubot::Store.new(Rubot::Store.path_for(File.join(dir, "sessions")))
        messages.each do |sid, rows|
          store.append_messages(sid, rows.map.with_index do |(role, text), offset|
            { "role" => role, "content" => text,
              "timestamp" => (Time.utc(2026, 11, 10, 8, 0) + offset).iso8601 }
          end)
          store.upsert_session(id: sid, title: titles.fetch(sid, rows.first.last),
                               updated_at: "2026-11-10T08:00:00Z")
        end
        Rubot::Session.store = store

        config = Rubot::Config.from_data(
          { "agents" => { "defaults" => { "workspace" => workspace } } },
          config_path: File.join(dir, "config.yml")
        )

        channel = Rubot::Channels::Web.new(channel_config: {})
        channel.instance_variable_set(:@app_config, config)
        channel
      end

      # A conversation long enough to need more than one page. Each exchange is
      # a prompt and its answer, so `pairs` of them are twice as many entries.
      def write_long_session(channel, sid, pairs)
        dir = channel.instance_variable_get(:@app_config).sessions_dir
        messages = (1..pairs).flat_map do |i|
          [ { "role" => "user", "content" => "pesan #{i}" },
            { "role" => "assistant", "content" => "balasan #{i}" } ]
        end

        File.write(File.join(dir, "#{sid}.json"),
                   JSON.generate({ "id" => sid, "updated_at" => Time.now.utc.iso8601,
                                   "messages" => messages }))
      end

      def kinds(turn)
        turn.items.map { |item| item[:kind] }
      end

      def texts(turn)
        turn.items.select { |item| item[:kind] == :text }.map { |item| item[:text] }
      end

      def test_chunk_burst_collapses_into_one_turn_event
        turn = build
        10.times { |i| turn.append_chunk("c#{i}") }
        turn.finish("c0c1c2c3c4c5c6c7c8c9")

        events = []
        turn.each_event { |type, _payload| events << type }

        assert_equal [ :turn, :done ], events
        assert_equal [ "c0c1c2c3c4c5c6c7c8c9" ], texts(turn)
      end

      def test_narration_stays_above_the_tool_row
        clock = FakeClock.new
        turn = build(clock)
        turn.append_chunk("Aku cek dulu.")
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        turn.append_chunk("Isinya tiga file.")
        turn.finish("Isinya tiga file.")

        assert_equal [ :text, :tool, :text ], kinds(turn)
        assert_equal [ "Aku cek dulu.", "Isinya tiga file." ], texts(turn)
      end

      def test_narration_block_stops_being_the_live_one_once_the_tool_starts
        turn = build
        turn.append_chunk("sebentar")
        turn.tool_started("shell_exec", "ls")

        refute turn.items.first[:live]
      end

      def test_finish_fills_text_when_nothing_was_streamed
        turn = build
        turn.finish("hanya response")

        assert_equal [ "hanya response" ], texts(turn)
      end

      def test_finish_extends_a_stream_that_stopped_short
        turn = build
        turn.append_chunk("hanya seb")
        turn.finish("hanya sebagian jawaban")

        assert_equal [ "hanya sebagian jawaban" ], texts(turn)
      end

      def test_tool_activity_transitions_from_running_to_done
        clock = FakeClock.new
        turn = build(clock)
        turn.tool_started("shell_exec", "ls -la")
        clock.advance(4.5)
        turn.tool_finished("shell_exec", true)

        entry = turn.items.first

        assert_equal :ok, entry[:state]
        assert_equal "shell_exec", entry[:name]
        assert_in_delta 4.5, entry[:elapsed], 0.001
      end

      def test_failed_tool_is_marked_failed
        turn = build
        turn.tool_started("file_ops", "nope")
        turn.tool_finished("file_ops", false)

        assert_equal :failed, turn.items.first[:state]
      end

      # --- thinking -------------------------------------------------------

      def test_quick_thought_leaves_no_row_at_all
        clock = FakeClock.new
        turn = build(clock)
        turn.thinking("sebentar")
        clock.advance(2.0)
        turn.append_chunk("jawaban")

        assert_equal [ :text ], kinds(turn)
      end

      def test_thought_past_the_threshold_is_kept_with_its_duration
        clock = FakeClock.new
        turn = build(clock)
        turn.thinking("sebentar")
        clock.advance(5.0)
        turn.tool_started("shell_exec", "ls")

        item = turn.items.first

        assert_equal :thinking, item[:kind]
        refute_nil item[:closed_at]
        assert_in_delta 5.0, item[:elapsed], 0.001
      end

      # The answer arriving is the end of the thought: a long answer must not
      # keep a clock running over reasoning that already stopped.
      def test_the_answer_closes_an_open_thought
        clock = FakeClock.new
        turn = build(clock)
        turn.thinking("sebentar")
        clock.advance(6.0)
        turn.append_chunk("jawaban")

        item = turn.items.first

        assert_equal :thinking, item[:kind]
        refute_nil item[:closed_at]
      end

      # Reasoning fragments arrive faster than anyone can read them, and none
      # of them is content: only the first one opens the block.
      def test_repeated_reasoning_fragments_open_only_one_block
        turn = build
        20.times { turn.thinking("fragmen") }

        assert_equal [ :thinking ], kinds(turn)
      end

      # An answer that is still being written is not interrupted by a thought:
      # see below. Once the answer is closed, a thought is a real pause between
      # rounds, and it earns its row — and the answer that follows opens a new
      # block under it rather than continuing the sealed one.
      def test_a_thought_after_a_finished_answer_opens_its_own_row
        turn = build
        turn.append_chunk("awal")
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        turn.thinking("lagi")

        assert_equal [ :text, :tool, :thinking ], kinds(turn)
        refute turn.items.first[:live]
      end

      # The same reasoning fragment, arriving mid-answer: a provider that
      # interleaves its reasoning between two chunks of one word used to split
      # the answer there, and the page drew the seam as a newline ("S", then
      # "aya"). The fragment is dropped, the answer keeps its block.
      def test_a_thought_does_not_interrupt_an_answer_being_written
        turn = build
        turn.append_chunk("S")
        turn.thinking("lagi")
        turn.append_chunk("aya")

        assert_equal [ :text ], kinds(turn)
        assert_equal "Saya", turn.items.first[:text]
        assert turn.items.first[:live], "the answer is still arriving"
      end

      # A provider can interleave its reasoning with the answer, so a thought
      # opens between two chunks of one word. Closed a moment later it is too
      # quick to record and leaves nothing behind but a sealed block — and the
      # rest of the answer used to open a second block below it, which the page
      # drew as a newline in the middle of a word ("Sa", then "ya").
      def test_a_quick_thought_does_not_split_the_answer
        turn = build
        turn.append_chunk("Sa")
        turn.thinking("sebentar")
        turn.append_chunk("ya")

        assert_equal [ :text ], kinds(turn)
        assert_equal "Saya", turn.items.first[:text]
      end

      # A steering message lands in the middle of a round, and a round is not
      # over because the reader spoke. Both blocks used to be found by looking
      # at the last row, which the bubble now *was*: the thought that was open
      # above it never got closed — its clock spun for the rest of the turn —
      # and the next fragment opened a second thought row under the bubble.
      def test_steering_during_a_thought_closes_that_thought_and_opens_no_other
        clock = FakeClock.new
        turn = build(clock)
        turn.thinking("mulai")
        clock.advance(1.0)
        turn.add_steer("Pakai template Grey")
        clock.advance(4.0)
        turn.append_chunk("jawaban")

        assert_equal [ :thinking, :steer, :text ], kinds(turn)
        thought = turn.items.first
        refute_nil thought[:closed_at], "the thought the reader interrupted must still end"
        assert_in_delta 5.0, thought[:elapsed], 0.001
      end

      # The same seam, seen on the answer: a chunk that arrives after the bubble
      # belongs to the block that was already being written, not to a new one
      # below it — otherwise the sentence breaks at the moment the reader typed.
      def test_steering_mid_answer_keeps_the_answer_in_one_block
        turn = build
        turn.append_chunk("Saya ")
        turn.add_steer("Pakai template Grey")
        turn.append_chunk("pakai yang Grey.")

        assert_equal [ :text, :steer ], kinds(turn)
        assert_equal "Saya pakai yang Grey.", turn.items.first[:text]
      end

      # A bubble is not a shield for content it sits above: a tool row still
      # ends the round, and the answer that follows the tool opens below it.
      def test_a_steer_does_not_join_an_answer_to_the_block_above_a_tool
        turn = build
        turn.append_chunk("mau jalankan")
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        turn.add_steer("pakai yang Grey")
        turn.append_chunk("selesai")

        assert_equal [ :text, :tool, :steer, :text ], kinds(turn)
      end

      # The seal still means what it says: once a tool has run, the answer that
      # follows is a new block below the row, not more of the narration above it.
      def test_a_tool_call_still_separates_the_answer_that_follows_it
        turn = build
        turn.append_chunk("mau jalankan")
        turn.tool_started("shell_exec", "ls")
        turn.tool_finished("shell_exec", true)
        turn.append_chunk("selesai")

        assert_equal [ :text, :tool, :text ], kinds(turn)
      end

      def test_ask_confirm_blocks_until_answered
        turn = build
        answer = nil

        thread = Thread.new { answer = turn.ask_confirm("shell_exec", "deletes files") }
        deadline = Time.now + 2
        sleep 0.01 until turn.confirm_prompt || Time.now > deadline

        refute_nil turn.confirm_prompt
        turn.answer_confirm(false)
        thread.join(2)

        refute answer
        assert_nil turn.confirm_prompt
      end

      def test_each_event_returns_after_done
        turn = build
        turn.finish("done")

        types = []
        turn.each_event { |type, _| types << type }

        assert_equal [ :done ], types
      end

      # --- Views ----------------------------------------------------------

      def test_timeline_escapes_tool_detail
        html = View.render("_timeline", items: [
                             { kind: :tool, name: "shell_exec", detail: "<b>x</b>",
                               state: :ok, epoch: Time.now.to_f, elapsed: nil }
                           ])

        assert_includes html, "shell_exec"
        assert_includes html, "&lt;b&gt;x&lt;/b&gt;"
        refute_includes html, "<b>x</b>"
      end

      # Only the prompt wears a bubble: it is a quotation. The answer is the
      # page speaking, so it takes the full column, with no avatar beside it.
      def test_the_answer_is_full_width_and_the_prompt_is_quoted
        answer = View.render("_timeline", items: [ { kind: :text, text: "jawaban", live: false } ])
        prompt = View.render("_message", role: "user", text: "pertanyaan")
        history = View.render("_message", role: "assistant", text: "jawaban lama")

        refute_includes answer, "bubble"
        refute_includes answer, "avatar"
        assert_includes answer, %(class="text")

        assert_includes prompt, %(class="bubble text"),
                        "the bubble borrows the prose rules, markdown included"
        assert_includes prompt, "pertanyaan"

        refute_includes history, "bubble"
        assert_includes history, %(class="text")
      end

      # A prompt is markdown too. It used to be escaped text, so a list typed
      # into the field came back as asterisks and a code fence as backticks —
      # the answer was rendered and the question was not.
      def test_a_prompt_is_rendered_as_markdown
        html = View.render("_message", role: "user",
                           text: "**tebal** dan `kode`\n\n- satu\n- dua")

        assert_includes html, "<strong>tebal</strong>"
        assert_includes html, "<code>kode</code>"
        assert_includes html, "<li>satu</li>"
        refute_includes html, "**tebal**"
      end

      # The renderer is the only thing allowed to write tags: what the person
      # typed is escaped before anything else, so a prompt cannot inject markup.
      def test_a_prompt_cannot_inject_html
        html = View.render("_message", role: "user",
                           text: "halo <script>alert(1)</script>")

        refute_includes html, "<script>"
        assert_includes html, "&lt;script&gt;"
      end

      # The quote mark hands a paragraph back to the composer. A prompt is the
      # composer's own words already, so its bubble carries none of them.
      def test_a_prompt_carries_no_quote_marks
        html = View.render("_message", role: "user", text: "satu paragraf saja")

        refute_includes html, "para-quote"
      end

      # A prompt is a quotation, and the line breaks in it are part of what was
      # said: the field showed two lines, so the bubble has to. The renderer
      # writes a single newline as <br>, which is what makes that true now that
      # the bubble is a prose block rather than pre-wrapped text.
      def test_the_prompt_keeps_the_line_breaks_that_were_typed
        html = View.render("_message", role: "user", text: "baris satu\nbaris dua")

        assert_includes html, "baris satu<br>baris dua"
      end

      def test_timeline_shows_a_duration_only_past_the_threshold
        item = { kind: :tool, name: "shell_exec", detail: "ls", state: :ok,
                 epoch: Time.now.to_f, elapsed: 12.4 }

        assert_includes View.render("_timeline", items: [ item ]), ">12s<"

        item[:elapsed] = 1.2
        refute_includes View.render("_timeline", items: [ item ]), ">1s<"
      end

      def test_timeline_collapses_a_kept_thought_to_one_row
        item = { kind: :thinking, epoch: Time.now.to_f, started_at: 0.0,
                 closed_at: Time.now.to_f, elapsed: 12.0 }

        html = View.render("_timeline", items: [ item ])

        assert_includes html, "Thought for 12s"
        refute_includes html, "Thinking…"
      end

      def test_timeline_marks_a_running_row_with_its_start_time
        item = { kind: :thinking, epoch: 1_700_000_000.0, started_at: 0.0,
                 closed_at: nil, elapsed: nil }

        html = View.render("_timeline", items: [ item ])

        assert_includes html, 'data-since="1700000000.0"'
        assert_includes html, "Thinking…"
      end

      def test_confirm_view_renders_buttons_for_a_pending_prompt
        html = View.render("_confirm", prompt: { name: "shell_exec", reason: "rm" }, turn_id: "tabc")

        assert_includes html, "/turns/tabc/confirm"
        assert_includes html, "Lanjutkan"
      end

      def test_confirm_view_is_empty_without_a_prompt
        assert_equal "", View.render("_confirm", prompt: nil, turn_id: "tabc").strip
      end

      def test_turn_view_opens_the_stream_with_the_token
        turn = build
        html = View.render("_turn", turn: turn, text: "hi", token_query: "?token=s3cret")

        assert_includes html, 'sse-connect="/turns/t1/stream?token=s3cret"'
        assert_includes html, 'sse-close="done"'
        assert_includes html, 'sse-swap="turn"'
      end

      # Enter is handled in JavaScript, which submits through `$refs.form`.
      # The ref used to be missing, so every press of Enter threw before a
      # request was made and the only way to send was the button.
      # A turn says nothing about itself while it runs: a long answer arrives as
      # one block and a slow tool is a row with no clock until it is slow. The
      # working row is what fills that silence, and it counts from the prompt —
      # not from whenever the fragment was rendered, which would restart the
      # clock on every chunk.
      def test_a_page_that_opens_on_a_running_turn_says_it_is_working
        turn = build
        html = render_page(live_turn: turn)

        assert_includes html, "Working…"
        assert_includes html, %(data-since="#{turn.epoch}")
        assert_includes html, %(data-threshold="0")
        assert_equal 1, html.scan('id="working"').size,
                     "one element owns the row, or the swap fills a second copy"
      end

      # The row belongs to the turn, not to the timeline: a turn read back from
      # the session file is over, and nothing in it should claim otherwise.
      def test_a_replayed_turn_does_not_say_it_is_working
        html = View.render("_timeline", items: [ { kind: :text, text: "jawaban", live: false } ])

        refute_includes html, "Working…"
      end

      # The working row is the page saying "not finished", not an entry in the
      # conversation, so it is drawn in its own band above the composer. In the
      # flow it slid the last tool row up every time the answer grew a line, and
      # it read as something the turn had done rather than something it still
      # had to do.
      #
      # The turn fragment carries only the slot the stream swaps through: it
      # used to render the row as well, and a page opened on a live turn then
      # held two elements called #working — the one beside the tool call and
      # the one above the field.
      def test_the_working_row_lives_in_the_band_above_the_composer
        turn = build
        turn.tool_started("shell_exec", "ls")

        timeline = View.turn_body(turn)
        fragment = View.render("_turn", turn: turn, text: "hi", token_query: "")
        page = render_page(live_turn: turn)

        refute_includes timeline, "Working…",
                        "the timeline is a record of the work, not of the waiting"
        refute_includes fragment, 'id="working"',
                        "the turn fragment must not draw a second band"
        assert_equal 1, page.scan('id="working"').size
        assert page.index('id="working"') < page.index('class="composer"'),
               "the band sits above the field, not in the thread"
        assert timeline.index("shell_exec"), "the tool row is still the timeline's"
      end

      # The band is in the page from the first paint, empty: the row appears
      # inside it, so the thread never changes height the moment a turn starts.
      def test_the_page_carries_an_empty_band_for_the_working_row
        html = render_page

        band = html[/<div id="working"[^>]*>.*?<\/div>/m]

        refute_nil band, "the page needs a place for the row to land"
        refute_includes band, "Working…", "the band starts empty"
        assert html.index('id="working"') < html.index('class="composer"'),
               "the band sits above the field, not in the thread"
      end

      # The clock says how long the turn has been running, so a tool call must
      # not take it back to zero: a reader watching a slow call has that call's
      # own clock in the timeline, and a number that kept dropping answered
      # nothing.
      def test_a_tool_call_keeps_the_working_clock_running
        epochs = [ 1000.0, 1012.0 ]
        turn = Turn.new(id: "t1", session_id: "s1", clock: FakeClock.new,
                        epoch_clock: -> { epochs.shift || 1012.0 })

        assert_equal 1000.0, turn.epoch, "the clock counts from the prompt"

        turn.tool_started("shell_exec", "ls")

        assert_equal 1000.0, turn.epoch, "a tool call does not restart it"
      end

      # A phone that puts the app down freezes its sockets, and coming back
      # reopens them: htmx reports the gap as `htmx:sseError` a moment before it
      # reconnects. Retiring the turn on that signal emptied the band and marked
      # the turn done, so after the app came back "Working…" and the call's own
      # clock never appeared again — the row is drawn only when the turn starts,
      # and the live clock only counts inside a turn that is not done. An error
      # is a reconnect, not an ending; the stream that returns is the one that
      # knows how the work ended.
      def test_a_dropped_stream_does_not_end_the_turn
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        refute_includes js, '["htmx:sseClose", "htmx:sseError"]',
                        "a drop and an ending are not the same news"
        assert_includes js, '"htmx:sseClose"'
        assert_includes js, "function retireTurn"
        refute_includes js, 'addEventListener("htmx:sseError"',
                        "the connection coming back must not retire the turn"
      end

      # The page also keeps an idle stream open for news about other
      # conversations, and it lives as long as the page does. Its closing says
      # nothing about a turn, so the element the stream hangs off decides what
      # is being ended.
      def test_only_a_turn_stream_ends_a_turn
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, %(elt.closest(".turn")),
                        "the stream's own element says what it belongs to"
        assert_includes js, "if (!turn) return;",
                        "the page's own news feed is not a turn"
      end

      # The row is drawn once, at first paint. Re-sending it on every tool call
      # put a fresh node in the band, and the fresh node restarted its own
      # animation: the text the reader was looking at strobed on every call
      # while carrying no new information. One row, drawn once.
      def test_a_tool_call_does_not_re_send_the_working_row
        turn = build
        turn.tool_started("shell_exec", "ls")
        turn.finish("selesai")

        types = []
        turn.each_event { |type, _payload| types << type }

        refute_includes types, :working,
                        "the row never changes, so nothing has to swap it"
      end

      # ...but "once" is still once. A turn started from the page is told about
      # in exactly one place — the answer to the POST — so the band has to be
      # filled there, or a reader who typed the prompt never sees the row at all
      # and only a refresh (first paint) brings it back.
      def test_starting_a_turn_from_the_page_fills_the_working_band
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }
        channel.define_singleton_method(:run_turn) { |turn, _text| turn.finish("ok") }

        res = FakeResponse.new
        channel.send(:create_turn, turn_request("halo"), res, "web_kanyaah")

        band = res.body[/<div class="working-band" id="working"[^>]*>.*?<\/div>/m]

        refute_nil band, "the turn must say it is working from the moment it starts"
        assert_includes band, "Working…"
        assert_includes band, 'hx-swap-oob="true"',
                        "the row belongs to the band above the field, not to the thread"
        assert_equal 1, res.body.scan('id="working"').size,
                     "a second band in the response would be a second copy on the page"
      end

      def test_the_turn_notification_threshold_comes_from_the_config
        assert_equal 0,
                     Rubot::Channels::Web.new(channel_config: { "turn_notify_after" => 0 })
                                          .instance_variable_get(:@turn_notify_after),
                     "zero is how a reader turns the buzz off"
        assert_equal Rubot::Channels::Web::TURN_NOTIFY_AFTER,
                     Rubot::Channels::Web.new(channel_config: {})
                                          .instance_variable_get(:@turn_notify_after)
      end

      # "Kabari kalau sudah kelar" is the one case where the clock does not
      # decide: the reader asked, so the announcement happens even for a turn
      # that took a second, says what the agent was told to say, and is forced
      # past the "the page is already showing this" rule.
      def test_a_turn_that_was_asked_to_report_back_announces_itself
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        calls = []
        channel.define_singleton_method(:notify_push) do |slug, **options|
          calls << [ slug, options ]
          nil
        end
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:usage_markup) { |_sid| nil }
        channel.define_singleton_method(:sidebar_markup) { |_sid| "" }
        channel.define_singleton_method(:process_message) do |_text, **options|
          options[:on_tool_call].call("notify", { "message" => "Migrasi selesai, 5 test lulus" }, nil)
          "Ringkasan pekerjaan."
        end
        channel.instance_variable_set(:@turn_notify_after, 3600)

        channel.send(:run_turn, Turn.new(id: "t1", session_id: "web_kanyaah", prompt: "kerjain ya"), "kerjain ya")

        assert_equal 1, calls.length, "the request outranks the threshold"
        slug, options = calls[0]
        assert_equal "kanyaah", slug
        assert_equal "Migrasi selesai, 5 test lulus", options[:body],
                     "the notification says what the agent chose to say"
        assert_equal true, options[:force],
                     "the reader asked to be told, so a visible page does not silence it"
        assert_equal "/s/web_kanyaah", options[:url]
      end

      def test_the_notify_tool_is_registered_and_only_carries_the_request
        tool = Rubot::Tools::Registry.new.get("notify")

        refute_nil tool, "the agent needs a way to ask"
        assert_includes tool.execute({}), "announced"
        assert_includes tool.execute({ "message" => "Selesai" }), "Selesai"
      end

      # A finished turn announces itself only when it ran long enough that the
      # reader plausibly walked away. The wiring is what this checks: the clock
      # starts when the prompt is accepted and stops when the answer is whole,
      # and the notification carries the conversation it belongs to.
      def test_a_slow_turn_notifies_when_it_ends_and_a_quick_one_does_not
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        calls = []
        channel.define_singleton_method(:notify_push) do |slug, title:, body:, url:, **|
          calls << { slug: slug, title: title, body: body, url: url }
          { "sent" => 1 }
        end
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:usage_markup) { |_sid| nil }
        channel.define_singleton_method(:sidebar_markup) { |_sid| "" }
        channel.define_singleton_method(:process_message) { |_text, **| sleep 1.05 and "jawaban siap" }

        channel.instance_variable_set(:@turn_notify_after, 1)
        slow = Turn.new(id: "t1", session_id: "web_kanyaah", prompt: "halo")
        channel.send(:run_turn, slow, "halo")

        assert_equal 1, calls.length, "a turn past the threshold announces itself"
        assert_equal "kanyaah", calls[0][:slug]
        assert_equal "jawaban siap", calls[0][:body]
        assert_equal "/s/web_kanyaah", calls[0][:url],
                     "the notification has to open the conversation that finished"

        # Same work, a threshold it never crossed.
        calls.clear
        channel.define_singleton_method(:process_message) { |_text, **| "cepat" }
        channel.instance_variable_set(:@turn_notify_after, 60)
        channel.send(:run_turn, Turn.new(id: "t2", session_id: "web_kanyaah", prompt: "halo"), "halo")

        assert_empty calls, "a quick reply belongs to the page that asked for it"
      end

      # A refresh during an answer must not look like a conversation whose last
      # prompt was never sent. Nothing is written to the session file until a
      # turn ends, so the page has to find the turn in memory and draw it —
      # prompt, timeline and the stream that reconnects to it.
      def test_a_refreshed_page_draws_the_turn_that_is_still_running
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Halo" }
        )
        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Berapa harga template?")
        turn.append_chunk("Aku cek katalog dulu.")
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.instance_variable_get(:@active)["web_kanyaah"] = "tabc"

        res = FakeResponse.new
        channel.send(:render_session, res, "web_kanyaah")
        html = res.body

        assert_includes html, "Berapa harga template?",
                        "the prompt the turn is answering is drawn from the turn itself"
        assert_includes html, "Aku cek katalog dulu.",
                        "and so is the text it has written so far"
        assert_includes html, %(sse-connect="/turns/tabc/stream"),
                        "the page has to join the stream again, not sit on a frozen copy"
      end

      # The prompt is written to the session file when the turn starts, so a
      # page opened a moment later holds it in the transcript *and* finds the
      # turn in memory. Drawing both showed the same prompt twice — the double
      # render that appeared after switching persona mid-turn and coming back.
      def test_a_refreshed_page_draws_an_already_written_prompt_once
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Berapa harga template?" }
        )
        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Berapa harga template?")
        turn.append_chunk("Aku cek katalog dulu.")
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.instance_variable_get(:@active)["web_kanyaah"] = "tabc"

        res = FakeResponse.new
        channel.send(:render_session, res, "web_kanyaah")
        html = res.body

        assert_equal 1, html.scan(%(class="msg user")).size,
                     "one prompt, one bubble — the transcript keeps it"
        assert_includes html, "Aku cek katalog dulu.",
                        "the answer in flight is still drawn"
        assert_includes html, %(sse-connect="/turns/tabc/stream"),
                        "the page still joins the stream"
      end

      # Steering used to reach the model but not the page: the bubble only
      # appeared after a refresh, which left the reader unsure whether the
      # message had been sent at all.
      def test_steering_a_running_turn_draws_the_message_at_once
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Halo")
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.define_singleton_method(:steer_session) { |_sid, _text| true }

        res = FakeResponse.new
        channel.send(:control_turn, Struct.new(:query).new({ "text" => "Pakai template Grey" }),
                     res, "tabc", "steer")

        assert_equal 204, res.status
        steer = turn.items.find { |item| item[:kind] == :steer }

        refute_nil steer, "the page draws the message it was just handed"
        assert_equal "Pakai template Grey", steer[:text]

        html = View.render("_timeline", items: turn.items)

        assert_includes html, %(class="msg user")
        assert_includes html, "Pakai template Grey"
      end

      # A steering message nobody took is not drawn: the bubble would claim
      # something was delivered that never left the page.
      def test_steering_a_turn_that_cannot_take_it_draws_nothing
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Halo")
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.define_singleton_method(:steer_session) { |_sid, _text| false }

        res = FakeResponse.new
        channel.send(:control_turn, Struct.new(:query).new({ "text" => "Halo?" }),
                     res, "tabc", "steer")

        assert_equal 409, res.status
        assert_empty turn.items.select { |item| item[:kind] == :steer }
      end

      # A turn that has ended is in the session file, where the history loop
      # draws it. Drawing it again would show every answer twice.
      def test_a_page_does_not_draw_a_turn_that_has_already_ended
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Halo")
        turn.finish("Siap.")
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.instance_variable_get(:@active)["web_kanyaah"] = "tabc"

        assert_nil channel.send(:live_turn, "web_kanyaah")

        res = FakeResponse.new
        channel.send(:render_session, res, "web_kanyaah")

        refute_includes res.body, %(sse-connect="/turns/tabc/stream")
      end

      # A confirmation that was already waiting when the page refreshed would
      # otherwise strand the turn behind a question nobody can see: its event
      # is in the part of the log the reconnecting reader skips.
      def test_a_refreshed_page_shows_a_confirmation_that_is_still_waiting
        turn = build
        turn.instance_variable_set(:@confirm, { name: "shell_exec", reason: "rm -rf build" })

        html = View.render("_turn", turn: turn, text: "hi", token_query: "")

        assert_includes html, "Lanjutkan"
        assert_includes html, "rm -rf build"
      end

      # The stream a refreshed page joins starts at the state the turn is in,
      # not at the beginning of the log. Replaying every :turn in it would be
      # one whole re-render per flush pause, and a long answer would take
      # minutes to catch up with itself.
      def test_a_reader_joining_in_flight_gets_the_latest_state_once
        turn = build
        turn.append_chunk("Bagian pertama.")
        turn.tool_started("shell_exec", "ls")
        turn.append_chunk("Bagian kedua.")

        events = []
        turn.each_event(from_now: true) do |type, _payload|
          events << type
          break
        end

        assert_equal [ :turn ], events,
                     "one paint of the current state, not a replay of how it got there"
        assert_equal [ "Bagian pertama.", "Bagian kedua." ], texts(turn),
                     "the paint carries the whole timeline, in the order it happened"
      end

      def test_joining_a_turn_that_just_ended_still_closes_the_stream
        turn = build
        turn.finish("selesai")

        events = []
        turn.each_event(from_now: true) { |type, _payload| events << type }

        assert_equal [ :turn, :done ], events
      end

      def test_the_composer_form_carries_the_ref_enter_submits_through
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        form = html[/<form\b[^>]*>/m]

        refute_nil form, "the composer must be a form: Enter submits it"
        assert_includes form, 'x-ref="form"'
        assert_includes form, 'hx-post="/s/web_rubot/turn"'
      end

      # The field and its button share one row, which is what keeps the button
      # at the end of the text. Without the row it falls under the field and
      # reads as a left-aligned block the width of the composer.
      def test_the_composer_keeps_the_button_at_the_end_of_the_field_s_row
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        row = html[%r{<div class="composer-row">.*?</div>\s*</div>}m]

        refute_nil row, "the composer needs a row to lay the field and the button out"
        assert_match %r{<div class="composer-row">\s*<textarea\b}, row,
                     "the field opens the row"
        assert_includes row[/<div class="composer-actions">.*/m], 'class="btn primary"',
                        "the button rides along at the end of the same row"
      end

      # A quoted paragraph is carried above the field rather than written into
      # it, so the composer needs a shelf to put the chip on. The spoken count
      # lives outside that shelf: a live region inside a block that hides itself
      # with `x-show` announces nothing.
      def test_the_composer_carries_the_shelf_a_quoted_paragraph_lands_on
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        shelf = html[%r{<div class="composer-quotes".*?</div>}m]

        refute_nil shelf, "quoted paragraphs need a place above the field"
        assert_includes shelf, 'x-show="quotes.length"'
        assert_includes shelf, 'x-for="quote in quotes"'
        assert_includes shelf, 'class="quote-kind"', "a list says its size on the chip"
        assert_includes html, 'x-text="quoteStatus"'
        refute_includes shelf, "quoteStatus", "the count is spoken outside the hiding shelf"
      end

      # A phone has no Enter that sends: during a turn the only key the
      # software keyboard offers makes a new line. So steering needs a button
      # of its own, and so does stopping — one control cannot be both, which
      # is what the send button used to be while a turn ran.
      def test_the_composer_sends_and_stops_while_a_turn_runs
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        buttons = html.scan(/<button\b.*?<\/button>/m)

        send_button = buttons.find { |button| button.include?("btn primary") }
        stop_button = buttons.find { |button| button.include?("composer-stop") }

        refute_nil send_button, "the composer needs its send button"
        refute_nil stop_button, "and a way out of the turn that is running"

        assert_includes send_button, "send()"
        refute_includes send_button, "stop()",
                        "the send button must not stop the turn"
        assert_includes stop_button, "stop()"
        assert_includes stop_button, %(x-show="busy"),
                        "the stop button only exists while there is something to stop"
        assert_includes stop_button, %(x-bind:disabled="stopping")
      end

      # Steering is only reachable if the send button accepts text while the
      # turn runs — the store decides what the press does with it, not whether
      # the button works.
      def test_the_send_button_can_steer_a_running_turn
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "/steer", "the text goes to the running turn"
        assert_includes js, "Alpine.store(\"turn\").active"
        refute_includes js, "sendOrStop",
                        "one button cannot both send and stop once a phone needs both"
      end

      # Stopping is a request, not a fact: the turn keeps running until the
      # server has acted. The button has to say so and stop taking presses for
      # that round trip, or it looks untouched and a second press just repeats
      # the same request.
      def test_the_stop_button_says_it_is_stopping_and_locks_itself
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        button = html[/<button\b[^>]*class="btn composer-stop".*?<\/button>/m]

        refute_nil button, "the stop button is the one that ends the turn"
        assert_includes button, %(x-bind:disabled="stopping")
        assert_includes button, "stopLabel"

        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "Membatalkan…", "the button has to say what it is doing"
        assert_includes js, "this.stopping = true"
        assert_includes js, "if (!active || this.stopping) return;",
                        "a second press while the first is in flight is a no-op"
      end

      # A prompt the server refuses keeps its text in the field and puts
      # nothing in the thread, so the reason has to be said next to the field.
      # Left unsaid, the reader presses a button that appears broken: the text
      # is still there, no bubble came out of it, and nothing explains why.
      def test_a_refused_prompt_has_a_place_to_say_why
        html = View.render("index",
                           personas: [], groups: { pinned: [], recent: [], page: 1, pages: 1, recent_total: 0, pinned_limit: 10, current: "web_rubot" },
                           slug: "rubot", persona_label: "Rubot", persona_emoji: "🤖",
                           persona_prompt: "",
                           persona_model: "m", session_id: "web_rubot",
                    persona_model_value: "", model_choices: [],
                    session_model: "", session_thinking: "medium", session_requests: 3, persona_thinking: "medium",
                           session_short: "web_rubot", session_label: "Sesi baru",
                           document_title: "rubot · Rubot", live_turn: nil, token_query: "",
                           page: { entries: [], more: false, before: 0 }, older_url: "",
                           usage: { cost: "—", cache: "—", ctx: "—", cause: "" },
                           usage_facts: { model: "m", cost: "—", breakdown: "", requests: "0",
                                          messages: "0", tokens_in: "0", tokens_out: "0",
                                          reasoning: "", cache: "—",
                                          cache_history: "", cache_cause: "", re_read: "0", saved: "", ctx: "—" })

        assert_includes html, 'id="composer-notice"', "the composer needs a notice slot"
        assert_match(/id="composer-notice"[^>]*hidden/, html,
                     "the slot starts empty and unseen")

        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))
        assert_includes js, "htmx:responseError",
                        "a response the server rejected has to reach the slot"
        assert_includes js, "composer-notice"
        assert_includes js, "htmx:beforeRequest",
                        "a notice about the last attempt must not outlive the next one"

        # A crash answers with plain text, not markup: left as it came it would
        # read as "internal error" on the page, which is not a sentence for a
        # reader and says nothing about the text still in the field.
        refute_includes js, "slot.innerHTML = event.detail.xhr.responseText",
                        "a non-HTML error body has to be turned into words"
      end

      # WEBrick hands form values back as ASCII-8BIT. Encoding them at the
      # edge is what keeps emoji and accented names from blowing up later
      # when the persona is written to personas.json.      # --- history --------------------------------------------------------

      # A refresh reads the session file, so the tool rows have to be rebuilt
      # from it — they are only stored as calls plus their results.
      def test_history_replays_tool_rows_after_a_refresh
        channel = Rubot::Channels::Web.new(channel_config: {})
        messages = [
          { "role" => "user", "content" => "cek dulu" },
          { "role" => "assistant", "content" => "Saya cek jadwalnya.",
            "tool_calls" => [
              { "id" => "c1", "type" => "function",
                "function" => { "name" => "shell_exec",
                                "arguments" => %({"command":"date -u"}) } }
            ] },
          { "role" => "tool", "tool_call_id" => "c1", "content" => "[Exit code: 0]\nSun" },
          { "role" => "assistant", "content" => "Sudah, ini hasilnya." }
        ]

        results = channel.send(:tool_results, messages)
        item = channel.send(:history_tool_items, messages[1]["tool_calls"].first, results, {}, "web_rubot").first

        assert_equal :tool, item[:kind]
        assert_equal "shell_exec", item[:name]
        assert_equal "date -u", item[:detail]
        assert_equal :ok, item[:state]
      end

      def test_history_marks_a_tool_that_errored_as_failed
        channel = Rubot::Channels::Web.new(channel_config: {})
        results = { "c1" => "ERROR: nope" }
        call = { "id" => "c1",
                 "function" => { "name" => "file_ops", "arguments" => %({"path":"x"}) } }

        assert_equal :failed, channel.send(:history_tool_items, call, results, {}, "web_rubot").first[:state]
      end

      # A call whose result never arrived is neither a success nor a failure:
      # the turn was stopped with the tool in flight.
      def test_history_marks_a_tool_without_a_result_as_unknown
        channel = Rubot::Channels::Web.new(channel_config: {})
        call = { "id" => "c1", "function" => { "name" => "shell_exec", "arguments" => "{}" } }

        assert_equal :unknown, channel.send(:history_tool_items, call, {}, {}, "web_rubot").first[:state]
      end

      def test_history_tolerates_arguments_that_are_not_json
        channel = Rubot::Channels::Web.new(channel_config: {})
        call = { "id" => "c1", "function" => { "name" => "shell_exec", "arguments" => "bukan json" } }

        assert_equal "", channel.send(:history_tool_items, call, {}, {}, "web_rubot").first[:detail]
      end

      # --- diff -----------------------------------------------------------

      # A tool that changed a file has to show what it did. The row says which
      # file and how long it took; the hunks are the only record of the change
      # itself, and without them the reader has to open the file to find out
      # whether the agent did what was asked.
      def test_a_changed_file_is_drawn_as_hunks
        html = Diff.render("a\nb\nc\n", "a\nB\nc\n", path: "lib/x.rb")

        refute_nil html
        assert_includes html, %(class="diff")
        assert_includes html, %(class="diff-row is-del")
        assert_includes html, %(class="diff-row is-add")
        assert_includes html, %(class="diff-row is-ctx"), "context around the change"
        assert_includes html, "lib/x.rb"
        assert_includes html, "+1"
        assert_includes html, "-1"
      end

      # A create has no before, a delete has no after: the first is every line
      # added, the second every line removed. Those are exactly the calls the
      # reader cannot see any other way.
      def test_a_created_file_is_all_additions
        html = Diff.render(nil, "one\ntwo\n", path: "new.txt")

        assert_includes html, "+2"
        refute_includes html, "is-del"
        assert_equal 2, html.scan(%(class="diff-row is-add")).size
      end

      def test_a_deleted_file_is_all_removals
        html = Diff.render("one\ntwo\n", nil, path: "gone.txt")

        assert_includes html, "-2"
        refute_includes html, "is-add"
        assert_equal 2, html.scan(%(class="diff-row is-del")).size
      end

      # A read, a search, a command: the row is the whole record, and an empty
      # frame under it would say a file changed when none did.
      def test_a_call_that_changed_no_file_draws_nothing
        assert_nil Diff.render("same\n", "same\n")
        assert_nil Diff.render(nil, nil)
        assert_nil Diff.render("", "")
      end

      # The content is someone else's file, so it is text, not markup.
      def test_the_diff_escapes_the_file_it_shows
        html = Diff.render("x = 1\n", "<script>alert(1)</script>\n", path: "x.rb")

        refute_includes html, "<script>"
        assert_includes html, "&lt;script&gt;"
      end

      # A file with two changes far apart is two hunks and a line saying how
      # much was skipped — the same shape `git diff` prints, and the reason a
      # one-word edit in a long file costs a handful of rows.
      def test_lines_between_two_hunks_collapse_into_one_gap
        before = (1..20).map { |i| "line #{i}" }.join("\n")
        after = before.sub("line 2", "line two").sub("line 18", "line eighteen")

        spec = Diff.structure(before, after)

        assert_equal 2, spec[:hunks]
        gap = spec[:rows].find { |row| row.include?("diff-gap") }

        refute_nil gap, "the lines neither hunk needs are collapsed"
        assert_equal 9, gap[/>(\d+) baris/, 1].to_i,
                     "lines 6..14 are shared and shown once as a count"
      end

      # A rewrite of a big file must not push the rest of the conversation off
      # the page.
      def test_a_very_long_diff_is_cut_short
        before = (1..200).map { |i| "old #{i}" }.join("\n")
        after = (1..200).map { |i| "new #{i}" }.join("\n")

        html = Diff.render(before, after, path: "big.rb")

        assert_includes html, "baris lagi", "the block has to say it is showing a part"
        assert_operator html.scan("diff-row").size, :<=, Diff::MAX_ROWS + 1
      end

      # The live turn and a refreshed page have to agree: the hunks arrive with
      # the tool result, and are read back out of the session file afterwards.
      def test_a_tool_result_carries_its_hunks_into_the_timeline
        channel = Rubot::Channels::Web.new(channel_config: {})
        turn = build

        channel.send(:tool_finished, turn, "file_ops", "[Exit code: 0] Written 8 characters",
                     { "path" => "x.rb", "before" => "a\nb\n", "after" => "a\nB\n" })

        diff = turn.items.find { |item| item[:kind] == :diff }

        refute_nil diff, "the hunks belong to the turn, under the row that made them"
        assert_includes diff[:html], %(class="diff-row is-add")
      end

      def test_history_draws_the_hunks_under_their_tool_row
        channel = Rubot::Channels::Web.new(channel_config: {})
        call = { "id" => "c1",
                 "function" => { "name" => "file_ops", "arguments" => %({"path":"x.rb"}) } }
        diffs = { "c1" => { "path" => "x.rb", "before" => "a\n", "after" => "a\nb\n" } }

        items = channel.send(:history_tool_items, call, { "c1" => "[Exit code: 0]" }, diffs, "web_rubot")

        assert_equal [ :tool, :diff ], items.map { |item| item[:kind] }
        assert_includes items.last[:html], %(class="diff-row is-add")
      end

      # A picture a call handed back comes after the hunks: the edit happened
      # first, and the picture is the result the reader is meant to look at.
      def test_a_picture_follows_the_hunks_of_the_call_that_sent_it
        channel = Rubot::Channels::Web.new(channel_config: {})
        call = { "id" => "c1",
                 "function" => { "name" => "send_file", "arguments" => %({"path":"shot.png"}) } }
        diffs = { "c1" => { "path" => "shot.png", "before" => nil, "after" => "a\n" } }

        items = channel.send(:history_tool_items, call, { "c1" => "Sent" }, diffs, "web_rubot")

        assert_equal [ :tool, :diff ], items.map { |item| item[:kind] },
                     "a picture needs an attachment folder; the diff does not"
      end

      # --- paging through a long conversation -----------------------------

      # The page is opened to read the end of the conversation, not the
      # beginning of it: a session with hundreds of turns should not cost a
      # full render to show its last answer.
      def test_the_page_starts_at_the_end_of_a_long_conversation
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_long_session(channel, "web_kanyaah", 15)

        page = channel.send(:history_page, "web_kanyaah")
        prompts = page[:entries].select { |entry| entry[:kind] == :prompt }.map { |entry| entry[:text] }

        assert_equal Rubot::Channels::Web::HISTORY_PAGE, page[:entries].size
        assert page[:more], "the older half is left to be fetched"
        assert_includes prompts, "pesan 15", "the newest exchange is on the page"
        refute_includes prompts, "pesan 1", "the oldest one is not"
      end

      def test_a_conversation_that_fits_is_not_paged
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_long_session(channel, "web_kanyaah", 3)

        page = channel.send(:history_page, "web_kanyaah")

        assert_equal 6, page[:entries].size
        refute page[:more]
        assert_equal 0, page[:before], "there is nothing above the first page"
      end

      # The marker hands back the index it was given, so scrolling up walks
      # backwards through the same conversation one page at a time.
      def test_scrolling_up_asks_for_the_page_before
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_long_session(channel, "web_kanyaah", 25)

        page = channel.send(:history_page, "web_kanyaah")
        older = channel.send(:history_page, "web_kanyaah", before: page[:before])

        assert older[:entries].any?, "there is a page above the first one"
        assert older[:more], "and one above that"
        assert_equal 10, older[:before]

        newest = page[:entries].map { |entry| entry[:text] }
        refute (older[:entries].map { |entry| entry[:text] } & newest).any?,
               "two pages of one conversation do not overlap"
      end

      def test_the_older_page_comes_back_with_the_marker_for_the_one_above_it
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_long_session(channel, "web_kanyaah", 25)
        res = FakeResponse.new

        channel.send(:render_history, res, "web_kanyaah", Struct.new(:query).new({ "before" => "22" }))

        assert_includes res.body, "pesan 2", "the page ends where the marker was"
        refute_includes res.body, "pesan 25", "and stops there rather than running on"
        assert_includes res.body, 'hx-get="/s/web_kanyaah/history?before=2"',
                        "the page above this one is asked for in turn"
      end

      # The last page has nothing above it, so the marker would ask for the same
      # page forever.
      def test_the_first_page_completes_without_a_marker
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_long_session(channel, "web_kanyaah", 3)
        res = FakeResponse.new

        channel.send(:render_history, res, "web_kanyaah", Struct.new(:query).new({ "before" => "2" }))

        assert_includes res.body, "pesan 1"
        refute_includes res.body, "history-more"
      end

      def test_the_marker_asks_for_a_page_when_it_is_scrolled_into_view
        html = View.render("_history", entries: [], more: true, before: 20,
                                       older_url: "/s/web_kanyaah/history?before=20")
        marker = html[/<div class="history-more".*?<\/div>/m]

        refute_nil marker
        assert_includes marker, 'hx-get="/s/web_kanyaah/history?before=20"'
        assert_includes marker, 'hx-trigger="revealed"',
                        "the page is fetched when it is reached, not when the page loads"
        assert_includes marker, 'hx-swap="outerHTML"',
                        "the marker is replaced by the page it asked for"
      end

      def test_the_older_page_request_carries_the_token
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })

        assert_equal "/s/web_kanyaah/history?token=t0k&before=40",
                     channel.send(:older_url, "web_kanyaah", 40)
      end

      # Prepending a page moves everything below it down by its own height, and
      # the reader would be thrown out of the sentence they were reading. The
      # distance from the bottom is the one measure the insert cannot change.
      def test_a_prepended_page_keeps_the_reader_in_place
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "holdFromBottom"
        assert_includes js, "thread.scrollTop = thread.scrollHeight - gap"
        assert_includes js, "el.closest(\".history-more\")",
                        "an older page must not trigger the jump to the bottom"
      end

      # A reader who has scrolled up is reading. A chunk that lands at the
      # bottom of the thread — the next sentence of a turn, a tool row — must not
      # drag the viewport back down, or the page argues with the scroll wheel for
      # the whole turn. Only a thread already at its end follows the stream.
      def test_a_streamed_chunk_does_not_move_a_reader_who_scrolled_up
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "noteThreadPosition",
                        "the position has to be measured, not assumed"
        assert_includes js, "thread.dataset.pinned = distance <= BOTTOM_SLACK ? \"true\" : \"false\"",
                        "\"at the end\" is a distance, not an exact match"
        assert_includes js, "if (!thread || thread.dataset.pinned !== \"true\") return;",
                        "a thread that is scrolled up must not follow"
        assert_includes js, "{ capture: true, passive: true }",
                        "scroll events do not bubble, so the listener has to capture"
        refute_includes js, "document.addEventListener(\"htmx:sseMessage\", scrollToBottom)",
                        "the unconditional jump on every chunk is gone"
      end

      # The two moments where the bottom is what the reader wants: opening a
      # session, and their own prompt. Both are allowed to overrule the pin.
      def test_opening_a_session_and_sending_a_prompt_go_to_the_bottom
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_match(/DOMContentLoaded", \(\) => \{.*?jumpToBottom\(\);/m, js,
                     "a conversation is opened at its end")
        assert_match(/send\(\) \{.*?jumpToBottom\(\);/m, js,
                     "a prompt the reader wrote must land where they can see it")
        assert_match(/htmx:beforeRequest", \(event\) => \{.*?jumpToBottom\(\);/m, js,
                     "pressing the send button is the same act as Enter")
      end

      def test_a_turn_renders_its_tool_rows_in_history
        html = View.render("_timeline", items: [
                             { kind: :text, text: "Saya cek dulu.", live: false },
                             { kind: :tool, name: "shell_exec", detail: "date -u",
                               state: :ok, epoch: Time.now.to_f, elapsed: nil },
                             { kind: :text, text: "Hasilnya.", live: false }
                           ])

        assert_includes html, "shell_exec"
        assert_includes html, "date -u"
        assert_operator html.index("Saya cek dulu."), :<, html.index("shell_exec"),
                        "narration must stay above the tool row"
        assert_operator html.index("shell_exec"), :<, html.index("Hasilnya."),
                        "the answer must stay below it"
      end

      # --- status row -----------------------------------------------------

      # The row the TUI footer became: same three figures, words replaced by
      # drawn icons. `metrics` is what makes that possible without the channel
      # parsing a string built for a terminal.
      def test_usage_metrics_drops_the_words
        report = { cost: { "total" => 1.23456 }, requests: 2, prompt_tokens: 1000,
                   cache_hit_rate: 0.92, context_percent: 8.24, context_window: 200_000 }

        metrics = Rubot::UsageReport.metrics(report)

        assert_equal "$1.235", metrics[:cost]
        assert_equal "92%", metrics[:cache]
        assert_equal "8.2%", metrics[:context]
      end

      # The footer's text form stays exactly as it was, so the TUI is untouched.
      def test_footer_still_renders_the_text_form
        report = { cost: { "total" => 0.0004 }, requests: 1, prompt_tokens: 1000,
                   cache_hit_rate: 0.6, context_percent: 8.2, context_window: 200_000,
                   provisional: true }

        assert_equal "~$0.0004 · cache 60% · ctx 8.2%", Rubot::UsageReport.footer(report)
      end

      # Nothing known yet is not zero: `nil` tells the caller to show a dash.
      def test_usage_metrics_reports_unknown_figures_as_nil
        metrics = Rubot::UsageReport.metrics({ requests: 0, prompt_tokens: 0, context_used: 900 })

        assert_nil metrics[:cost]
        assert_nil metrics[:cache]
        assert_equal "900", metrics[:context], "a raw token count is the honest fallback"
      end

      def test_status_row_renders_three_icons_and_no_words
        html = View.render("_usage", cost: "$0.023", cache: "99.6%", ctx: "2.5%", cause: "")

        assert_equal 3, html.scan(%(<svg class="metric-icon")).size
        assert_includes html, "$0.023"
        assert_includes html, "99.6%"
        assert_includes html, "2.5%"
        assert_includes html, %(id="usage")

        # The label must live in the tooltip, not in the row. The tooltip also
        # has to say which scope each figure covers: the cost is the session
        # total while the cache share is the latest request, and a reader who
        # does not know that reads the pair as a contradiction.
        assert_includes html, "Total biaya sesi ini, akumulatif"
        assert_includes html, "permintaan terakhir — bukan rata-rata sesi"
        assert_includes html, "context window model"
        refute_match(%r{class="value">cost}, html)
        refute_includes html, "cache 99"
      end

      # The row says why the last request missed, when it did. Without it a
      # reader sees "cache 0%" and has to open the panel to find out whether
      # their prompt moved or the provider simply had nothing cached.
      def test_status_row_names_the_cause_of_a_miss
        html = View.render("_usage", cost: "$0.1", cache: "0%", ctx: "1%",
                           cause: "model berganti")

        assert_includes html, "model berganti"
        assert_includes html, "metric-cause"
      end

      # A hit is the normal state. A word for it in the row would take width
      # from the composer to say nothing.
      def test_status_row_stays_quiet_when_the_request_hit
        html = View.render("_usage", cost: "$0.1", cache: "99%", ctx: "1%", cause: "")

        refute_includes html, "metric-cause"
      end

      # Each icon is a different drawing; a copy-paste slip would make two
      # figures indistinguishable at a glance.
      # The button behind the usage panel is the page's door out of the pinned
      # prompt (see Agent#repin_system_prompt). Three answers, because the repo
      # has three states and a reader has to be able to tell them apart.
      def test_the_repin_button_reports_what_it_did
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        asked = 0
        handle = Object.new
        handle.define_singleton_method(:repin_system_prompt) { asked += 1; true }
        channel.define_singleton_method(:session_for) { |_sid| handle }

        res = FakeResponse.new
        channel.send(:repin_prompt, res, "web_kanyaah")

        assert_equal 1, asked, "the button has to ask, not just describe"
        assert_includes res.body, "dibangun ulang"
      end

      # A turn owns the actor; a request queued behind it would look like a hang,
      # and the running answer needs no repin.
      def test_the_repin_button_refuses_while_a_turn_is_running
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }
        channel.define_singleton_method(:session_running?) { |_sid| true }

        res = FakeResponse.new
        channel.send(:repin_prompt, res, "web_kanyaah")

        assert_includes res.body, "Turn masih berjalan"
        refute_includes res.body, "akan dibangun ulang"
      end

      def test_the_repin_button_says_when_there_was_nothing_pinned
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                        sessions: { "web_kanyaah" => "Halo" })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        handle = Object.new
        handle.define_singleton_method(:repin_system_prompt) { false }
        channel.define_singleton_method(:session_for) { |_sid| handle }

        res = FakeResponse.new
        channel.send(:repin_prompt, res, "web_kanyaah")

        assert_includes res.body, "belum di-pin"
      end

      def test_each_usage_icon_draws_a_different_shape
        bodies = View::SVG_ICONS.values

        assert_equal 4, bodies.size, "cost, cache, context and the report's own button"
        assert_equal 4, bodies.uniq.size
        bodies.each { |body| assert_includes body, "<", "every icon needs at least one shape" }
      end

      # The report's button used to draw its own three bars, a fraction of a
      # millimetre away from the bars that mean "context": two different figures
      # announced by the same shape. It draws the shared mark now, so the shapes
      # can only collide by being added to the one set that is checked above.
      def test_the_report_button_draws_the_shared_mark
        erb = File.read(File.expand_path("../lib/rubot/web/views/_usage_sheet.erb", __dir__))
        toggle = erb[/<summary class="usage-toggle".*?<\/summary>/m]

        refute_nil toggle, "the report button is missing from the usage sheet"
        assert_includes toggle, "usage_icon(:usage)"
        refute_includes toggle, "<path", "the button must not carry geometry of its own"
        refute_includes toggle, "<rect"
      end

      # The out-of-band copy has to carry the marker, while the page's own copy
      # must not — otherwise the first swap would try to swap twice.
      def test_usage_markup_marks_the_fragment_as_out_of_band
        channel = Rubot::Channels::Web.new(channel_config: {})
        markup = channel.send(:usage_markup_with, { cost: "$0.1", cache: "50%", ctx: "1%", cause: "" })

        assert_includes markup, %(hx-swap-oob="true")
        refute_includes View.render("_usage", cost: "$0.1", cache: "50%", ctx: "1%", cause: ""), "hx-swap-oob"
      end

      # The figures have to move while the turn is still running, and the
      # session cannot be asked for them then: in actor mode the turn owns the
      # Ractor. The report the agent pushes is what the row is drawn from.
      def test_the_status_row_is_drawn_from_the_live_report
        channel = Rubot::Channels::Web.new(channel_config: {})
        report = { cost: { "total" => 0.0004 }, requests: 1, prompt_tokens: 1000,
                   cache_hit_rate: 0.6, context_percent: 8.2, context_window: 200_000,
                   provisional: true }

        markup = channel.send(:usage_markup_from, report)

        assert_includes markup, "~$0.0004", "an estimate is marked as one"
        assert_includes markup, "60%"
        assert_includes markup, "8.2%"
        assert_includes markup, %(hx-swap-oob="true"),
                        "it lands on #usage from outside the turn"
      end

      # Nothing to draw must not become an empty swap: that would blank the
      # row and lose the last figure the reader had.
      def test_an_empty_live_report_draws_nothing
        channel = Rubot::Channels::Web.new(channel_config: {})

        assert_nil channel.send(:usage_markup_from, nil)
        assert_nil channel.send(:usage_markup_from, "bukan report")
      end

      # --- themes ---------------------------------------------------------

      # A theme is a list of names. A block that forgets one inherits it from
      # the default, which mixes two palettes: a light page with dark scrims,
      # or a green accent on a blue-grey one.
      def test_every_theme_defines_the_same_colours
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        blocks = %w[everforest dark light].map do |name|
          match = css.match(/:root\[data-theme="#{name}"\] \{(.*?)\n\}/m)
          refute_nil match, "theme #{name} needs its own block"
          match[1].scan(/--([\w-]+):/).flatten.sort
        end

        assert_equal blocks[0], blocks[1], "dark is missing names everforest sets"
        assert_equal blocks[0], blocks[2], "light is missing names everforest sets"
        assert_includes blocks[0], "scrim", "overlays have to follow the palette too"
        assert_includes blocks[0], "on-accent", "text on a filled button has to"
      end

      # The theme is decided in the head, before the stylesheet can paint. Left
      # to a script at the end of the page, a light reader would get a dark
      # frame first — a flash across the whole screen.
      def test_the_theme_is_set_before_the_first_paint
        html = View.render("layout", title: "x", content: "isi", asset_version: 1)
        script = html.index("rubot-theme")
        stylesheet = html.index("app.css")

        refute_nil script, "the head has to choose a theme"
        assert script < stylesheet, "the choice must land before the stylesheet paints"
        assert_includes html, %(setAttribute("data-theme", theme))
        assert_includes html, "prefers-color-scheme",
                        "with no choice made, the system decides"
      end

      # Three palettes, one press each, each showing its own colours — a select
      # would hide two thirds of a choice that is meant to be looked at.
      def test_the_picker_offers_every_theme_as_its_own_button
        html = render_page

        %w[everforest dark light].each do |name|
          assert_includes html, %(data-theme-choice="#{name}"),
                          "#{name} needs a button of its own"
        end
        assert_equal 3, html.scan("data-theme-choice=").size
        # The picker only: the drawer's notification toggle is also a pressed
        # button, and it is not part of this choice.
        picker = html[/<div class="theme-picker".*?<\/div>/m].to_s
        assert_equal 3, picker.scan("aria-pressed=").size,
                     "the state has to be announceable, not just painted"
        assert_includes html, %(role="group")
      end

      # A choice is the reader's, on their own device: stored locally and never
      # sent to the server, so two people in one conversation keep their own.
      def test_a_theme_choice_is_kept_on_the_device
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, %(localStorage.setItem(THEME_KEY, theme))
        assert_includes js, %(localStorage.getItem(THEME_KEY))
        refute_match(/fetch\([^)]*theme/i, js, "the choice never goes to the server")
        assert_includes js, %(style.colorScheme), "native controls follow the theme too"
      end

      # The three figures in the row are a glance; the panel is what the glance
      # is made of. Every one of them has to be spelled out, or opening the
      # panel answers nothing.
      def test_the_panel_spells_out_the_report_behind_the_row
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.send(:usage_facts, {
          model: "claude-sonnet-4", provider: "anthropic", messages: 42, requests: 17,
          prompt_tokens: 128_400, completion_tokens: 9_120, cached_tokens: 96_000,
          cache_hit_rate: 0.7477, cache_hit_rate_session: 0.9531,
          context_used: 41_200, context_window: 200_000,
          context_percent: 20.6,
          cost: { "total" => 0.0412, "input" => 0.0098, "cached_input" => 0.0028,
                  "cache_creation" => 0.0011, "output" => 0.0275 }
        })
        html = View.render("_usage_facts", **facts)

        assert_includes html, "claude-sonnet-4"
        assert_includes html, "$0.0412"
        assert_includes html, "128,400", "tokens are grouped, not a wall of digits"
        assert_includes html, "9,120"
        assert_includes html, "74.8%", "the cache share of the latest request"
        assert_includes html, "95.3%", "the session-wide share sits beside it"
        assert_includes html, "rata-rata sesi", "and says which one it is"
        assert_includes html, "41,200 / 200,000"
        assert_includes html, "cache baca", "the breakdown answers \"why this cost\""
      end

      # The panel is where a broken cache becomes visible. One figure cannot
      # tell a prefix that moves every request from a single cold request; the
      # run of zeros can, and that is what turns "cache 4%?" into an answer.
      def test_the_panel_shows_the_cache_share_of_each_recent_request
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.send(:usage_facts, {
          model: "m", provider: "openai", messages: 4, requests: 4,
          prompt_tokens: 4_000, completion_tokens: 40, cached_tokens: 90,
          cache_hit_rate: 0.0, cache_hit_rate_session: 0.0225,
          cache_history: [ 0.0, 0.0, 0.0, 0.09 ],
          context_used: 900, context_window: 128_000, context_percent: 0.7,
          cost: { "total" => 0.01 }
        })
        html = View.render("_usage_facts", **facts)

        assert_includes html, "riwayat cache"
        assert_includes html, "0% 0% 0% 9%", "oldest first, so the shape is readable"
        assert_includes html, "prefix prompt berubah terus",
                        "the line explains what a run of zeros means"
      end

      # One request is not a history, and a panel row holding a single number
      # would repeat the line above it.
      def test_the_panel_omits_the_history_row_until_there_is_one
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.send(:usage_facts, {
          model: "m", provider: "openai", messages: 1, requests: 1,
          prompt_tokens: 100, completion_tokens: 10, cached_tokens: 0,
          cache_hit_rate: 0.0, cache_hit_rate_session: 0.0, cache_history: [ 0.0 ],
          context_used: 100, context_window: 128_000, context_percent: 0.1,
          cost: { "total" => 0.001 }
        })
        html = View.render("_usage_facts", **facts)

        refute_includes html, "riwayat cache"
      end

      # A launch has spent nothing and knows nothing yet. It says so rather
      # than printing a confident $0.00 over a conversation no request has
      # touched.
      def test_the_panel_admits_an_empty_report
        channel = Rubot::Channels::Web.new(channel_config: {})
        html = View.render("_usage_facts", **channel.send(:usage_facts, {}))

        assert_includes html, "belum diketahui"
        assert_includes html, %(id="usage-facts")
        refute_includes html, "$0.0000"
      end

      # The panel is where the label is spelled out: the row says a short
      # phrase, this says which of the causes it is and what it means.
      def test_the_panel_names_the_cause_of_a_miss
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.send(:usage_facts, {
          model: "m", provider: "anthropic", messages: 4, requests: 4,
          prompt_tokens: 4_000, completion_tokens: 40, cached_tokens: 0,
          cache_hit_rate: 0.0, cache_hit_rate_session: 0.0,
          cache_cause: :trim_boundary,
          context_used: 900, context_window: 128_000, context_percent: 0.7,
          cost: { "total" => 0.01 }
        })
        html = View.render("_usage_facts", **facts)

        assert_includes html, "sebab miss"
        assert_includes html, "jendela history terpotong",
                        "the label is written out, not the symbol"
      end

      # The panel is where the money is explained: what the last request paid
      # in full, and what the cache kept from being spent.
      def test_the_panel_says_what_was_re_read_and_what_the_cache_saved
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.send(:usage_facts, {
          model: "m", provider: "openai", messages: 4, requests: 4,
          prompt_tokens: 100_000, completion_tokens: 400, cached_tokens: 87_600,
          cache_hit_rate: 0.876, cache_hit_rate_session: 0.9,
          last_re_read_tokens: 12_400,
          context_used: 900, context_window: 128_000, context_percent: 0.7,
          cost: { "total" => 0.0412, "input" => 0.0017, "cached_input" => 0.0004,
                  "cache_creation" => 0.0, "output" => 0.000_2, "saved" => 0.0153 }
        })
        html = View.render("_usage_facts", **facts)

        assert_includes html, "dibaca ulang"
        assert_includes html, "12,400"
        assert_includes html, "dihemat"
        assert_includes html, "$0.0153"
      end

      # A rate the catalog does not have is priced at the input rate, which is
      # an upper bound. The panel says so rather than rounding the doubt away.
      def test_the_panel_marks_a_cost_that_is_only_an_upper_bound
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.send(:usage_facts, {
          model: "m", provider: "google", messages: 1, requests: 1,
          prompt_tokens: 1_000, completion_tokens: 10, cached_tokens: 0,
          context_used: 900, context_window: 128_000, context_percent: 0.7,
          cost: { "total" => 0.4, "input" => 0.4, "cached_input" => 0.0,
                  "cache_creation" => 0.0, "output" => 0.0, "cache_price_unknown" => true }
        })
        html = View.render("_usage_facts", **facts)

        assert_includes html, "≤"
        refute_includes html, "dihemat"
      end

      def test_the_panel_omits_the_cause_row_when_the_request_hit
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.send(:usage_facts, {
          model: "m", provider: "anthropic", messages: 4, requests: 4,
          prompt_tokens: 4_000, completion_tokens: 40, cached_tokens: 3_900,
          cache_hit_rate: 0.97, cache_hit_rate_session: 0.9,
          context_used: 900, context_window: 128_000, context_percent: 0.7,
          cost: { "total" => 0.01 }
        })

        refute_includes View.render("_usage_facts", **facts), "sebab miss"
      end

      # The panel lives inside the page from the first paint — it is a
      # `<details>`, so it needs no request to open — and only the allowance
      # waits for the reader.
      def test_the_usage_panel_is_in_the_page_and_fetches_its_quota_on_open
        html = render_page
        sheet = html[/<details class="usage-sheet".*?<\/details>/m]

        refute_nil sheet, "the status row needs its way into the full report"
        assert_includes sheet, %(id="usage-facts")
        assert_includes sheet, %(hx-get="/s/web_rubot/quota")
        assert_includes sheet, %(hx-target="#usage-quota")
        assert_includes sheet, "toggle[this.open]",
                        "the allowance costs a request, so it waits for the reader"
        assert html.index('class="usage-sheet"') > html.index('id="usage"'),
               "the button sits at the end of the row it expands"
      end

      # A meter says two things: what is spent, and when the window comes back.
      # A provider that already cut the account off says that too.
      def test_the_quota_draws_one_meter_per_allowance
        channel = Rubot::Channels::Web.new(channel_config: {})
        meters = channel.send(:quota_meters,
                              { "rolling" => { "percent" => 12.5,
                                               "resets_at" => (Time.now + 3600).utc.iso8601 },
                                "monthly" => { "percent" => 100.0, "limited" => true } })
        html = View.render("_quota", meters: meters, note: "")

        assert_equal 2, meters.size, "only the windows the provider reported"
        assert_includes html, "Rolling"
        assert_includes html, "12.5% terpakai"
        assert_includes html, %(style="width: 12.5%")
        assert_includes html, "is-limited", "an allowance that is gone is not green"
        assert_includes html, "reset dalam"
      end

      # The provider reports the share that is spent, and the bar has always
      # been drawn as that share. The figure beside it counted down instead —
      # so a quarter gone read "75% sisa" next to a bar a quarter full. Both
      # now say the same thing.
      def test_the_quota_counts_what_is_spent_not_what_is_left
        channel = Rubot::Channels::Web.new(channel_config: {})
        html = View.render("_quota",
                           meters: channel.send(:quota_meters,
                                                { "rolling" => { "percent" => 25.0 } }),
                           note: "")

        assert_includes html, "25.0% terpakai"
        refute_includes html, "sisa", "the panel counts towards the limit, not away from it"
      end

      # A provider that sells tokens by the drink has no allowance at all. That
      # is not a failure, and it must not be drawn as an empty box.
      def test_a_provider_without_an_allowance_says_so_in_one_sentence
        channel = Rubot::Channels::Web.new(channel_config: {})

        html = View.render("_quota", meters: channel.send(:quota_meters, { unavailable: true }),
                                              note: channel.send(:quota_note, { unavailable: true }))

        refute_includes html, "usage-meters"
        assert_includes html, "tidak punya kuota langganan"

        error = View.render("_quota", meters: [], note: channel.send(:quota_note, { error: "HTTP 500" }))
        assert_includes error, "HTTP 500"
      end

      # The panel's facts ride along with the row: a reader watching an open
      # panel during a turn must not see the row move while the breakdown
      # under it stands still.
      def test_the_live_report_refreshes_the_panel_as_well_as_the_row
        channel = Rubot::Channels::Web.new(channel_config: {})
        report = { cost: { "total" => 0.5 }, requests: 3, prompt_tokens: 5000,
                   completion_tokens: 900, cached_tokens: 4000, cache_hit_rate: 0.8,
                   context_percent: 12.0, context_window: 100_000, context_used: 12_000 }

        markup = channel.send(:usage_markup_from, report)

        assert_equal 2, markup.scan(%(hx-swap-oob="true")).size,
                     "the row and the facts both swap out of band"
        assert_includes markup, %(id="usage-facts" hx-swap-oob="true")
        assert_includes markup, "12,000 / 100,000"
        refute_includes markup, "masuk 0", "a breakdown of zeros explains nothing"
      end

      # A persona form asks for three fields and a prompt; a popover beside the
      # rail is too small to write in. It is a dialog in the middle of the
      # screen, with the page dimmed behind it.
      def test_the_new_persona_form_opens_as_a_dialog_in_the_middle
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        rule = css[/^\.rail-panel \{[^}]*\}/]

        refute_nil rule, "the .rail-panel rule is missing from app.css"
        assert_equal "fixed", rule[/position:\s*(\w+)/, 1]
        assert_match(/top:\s*50%/, rule)
        assert_match(/left:\s*50%/, rule)
        assert_match(/translate\(-50%,\s*-50%\)/, rule,
                     "the dialog has to be centred on its own box, not its corner")
        assert_match(/rail-new\[open\]::before \{[^}]*position: fixed/m, css,
                     "an open dialog dims the page behind it")
        assert_match(/side-edit\[open\]::before \{[^}]*position: fixed/m, css,
                     "the edit dialog dims it the same way")
      end

      # Dragging the corner of the prompt used to resize the whole dialog and
      # push the fields under it around. It grows with its text instead.
      def test_the_prompt_field_cannot_be_dragged_open
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        rule = css[/^\.rail-panel input,\n\.rail-panel select,\n\.rail-panel textarea \{[^}]*\}/]

        refute_nil rule, "the field rule is missing from app.css"
        assert_match(/resize:\s*none/, rule)
      end

      # The dimmed page is a way out: a click on it, or Escape, closes the
      # dialog. Without that the only close button is the one it covered. Both
      # persona dialogs — the new one in the rail, the edit one in the sidebar
      # — are the same mechanism, so both have to be wired.
      def test_the_persona_dialog_can_be_dismissed_from_the_page_behind_it
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, %(details.rail-new[open])
        assert_includes js, %(details.side-edit[open])
        assert_includes js, "open.open = false"
        assert_includes js, %(event.key !== "Escape")
      end

      # A persona that already exists had no way to change its name, face or
      # prompt: the only form on the page made a new one. The edit form writes
      # the same record in place.
      def test_a_persona_can_be_edited_in_place
        created = "2026-01-02T03:04:05Z"
        channel = channel_with_sessions(
          personas: {
            "kanyaah" => { "slug" => "kanyaah", "name" => "Kanyaah", "emoji" => "🧠",
                           "preset" => "primary", "system_prompt" => "Lama",
                           "created_at" => created }
          },
          sessions: { "web_kanyaah" => "Halo" }
        )

        res = FakeResponse.new
        channel.send(:edit_persona, edit_request(
                                      "name" => "Kanyaah ID", "emoji" => "✍️",
                                      "system_prompt" => "Baru", "session_id" => "web_kanyaah"
                                    ), res, "kanyaah")

        persona = channel.send(:persona_store)["kanyaah"]

        assert_equal "Kanyaah ID", persona.name
        assert_equal "✍️", persona.emoji
        assert_equal "Baru", persona.system_prompt
        assert_equal "primary", persona.preset, "the model is not one of the form's fields"
        assert_equal created, persona.created_at, "the roster is ordered by creation time"
        assert_equal 303, res.status
        assert_equal "/s/web_kanyaah", res.headers["Location"],
                     "the editor lands back on the conversation it was opened from"
      end

      # Emptying the prompt is how a persona goes back to the default voice:
      # the field means "no prompt of my own", not "keep the old one".
      def test_clearing_the_prompt_gives_the_persona_the_default_voice
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah", "emoji" => "🧠",
                                     "system_prompt" => "Lama" } }
        )

        channel.send(:edit_persona, edit_request("name" => "", "emoji" => "",
                                                 "system_prompt" => ""),
                     FakeResponse.new, "kanyaah")

        persona = channel.send(:persona_store)["kanyaah"]

        assert_nil persona.system_prompt
        assert_nil persona.name, "an emptied name falls back to the slug"
        assert_equal "🧠", persona.emoji, "an empty face keeps the one it had"
      end

      # An id from another persona must not send the editor into a conversation
      # it does not own; the persona's own page is the safe landing.
      def test_an_edit_ignores_a_session_id_that_belongs_to_someone_else
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" },
                      "rubot" => { "name" => "Rubot" } }
        )

        res = FakeResponse.new
        channel.send(:edit_persona, edit_request("name" => "Kanyaah", "session_id" => "web_rubot"),
                     res, "kanyaah")

        assert_equal "/p/kanyaah", res.headers["Location"]
      end

      def test_editing_a_persona_that_does_not_exist_is_not_found
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })

        res = FakeResponse.new
        channel.send(:edit_persona, edit_request("name" => "Hilang"), res, "hilang")

        assert_equal 404, res.status
      end

      # The form's action is a route like any other, so the page it was written
      # into and the handler behind it have to agree on the path.
      def test_the_edit_form_posts_to_a_route_that_reaches_the_handler
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        request = Object.new
        request.define_singleton_method(:path) { "/p/kanyaah/edit" }
        request.define_singleton_method(:request_method) { "POST" }
        request.define_singleton_method(:query) { { "name" => "Kanyaah Baru" } }
        request.define_singleton_method(:[]) { |_key| nil }

        channel.send(:dispatch, request, FakeResponse.new)

        assert_equal "Kanyaah Baru", channel.send(:persona_store)["kanyaah"].name
      end

      # The dialog has to open with what is already saved, or saving would
      # overwrite a prompt with an empty field.
      def test_the_edit_dialog_arrives_with_what_is_already_saved
        html = render_page(persona_prompt: "Kamu spesialis undangan.")

        assert_includes html, %(class="side-edit")
        assert_includes html, %(hx-post="/p/rubot/edit")
        assert_includes html, "Kamu spesialis undangan."
        assert_includes html, %(name="session_id" value="web_rubot")
        assert_includes html, %(class="panel-hint"), "the slug is shown, not asked for"
      end

      def edit_request(values)
        request = Object.new
        request.define_singleton_method(:query) { values }
        request.define_singleton_method(:[]) { |_key| nil }
        request
      end

      def test_form_value_is_forced_to_utf8
        channel = Rubot::Channels::Web.new(channel_config: {})
        req = Object.new
        query = { "emoji" => "\xF0\x9F\xA7\xAA".b, "name" => "Uji Coba".b }
        req.define_singleton_method(:query) { query }

        assert_equal "🧪", channel.send(:form, req, "emoji")
        assert_equal Encoding::UTF_8, channel.send(:form, req, "name").encoding
        assert_equal "", channel.send(:form, req, "missing")
      end

      # WEBrick parses only the body of a form POST, so a URL that carries
      # `?token=` — which is what every link the page writes does — has to
      # authenticate on the query string. The sidebar's "+" button depends on
      # this: it submits before the page has had a chance to set a cookie.
      def test_a_post_authenticates_with_the_token_in_the_query_string
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })
        request = Struct.new(:query_string, :query, :cookies)

        assert channel.send(:authorized?, request.new("token=t0k", {}, []))
        refute channel.send(:authorized?, request.new("token=nope", {}, []))
        refute channel.send(:authorized?, request.new("", {}, []))
      end

      # --- the way in ------------------------------------------------------

      # A request from a browser asking for a page: what the gate answers.
      def gate_request(path, query_string: "", accept: "text/html", htmx: false, method: "GET")
        query = URI.decode_www_form(query_string).to_h
        request = Object.new
        request.define_singleton_method(:path) { path }
        request.define_singleton_method(:request_method) { method }
        request.define_singleton_method(:query) { query }
        request.define_singleton_method(:query_string) { query_string }
        request.define_singleton_method(:cookies) { [] }
        request.define_singleton_method(:[]) do |key|
          case key.to_s
          when "Accept" then accept
          when "HX-Request" then htmx ? "true" : nil
          end
        end
        request
      end

      # Arriving without a token used to answer "token required" as plain text,
      # which left the reader nothing to act on: the token lived in the URL, so
      # a bookmark or a typed address was a dead end. The field is the way in.
      def test_a_page_without_a_token_asks_for_one_in_a_field
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })
        res = FakeResponse.new

        channel.send(:dispatch, gate_request("/s/web_kanyaah"), res)

        assert_equal 403, res.status
        assert_includes res.body, %(action="/unlock")
        assert_includes res.body, %(name="token")
        assert_includes res.body, %(type="password")
        refute_includes res.body, "token required"
      end

      # The token is not carried into the next URL: asking for it here is what
      # lets the address bar stop holding it, so where the reader was going is
      # kept without the one parameter the form is about.
      def test_the_form_carries_where_the_reader_was_going_without_the_token
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })
        res = FakeResponse.new

        channel.send(:dispatch, gate_request("/s/web_kanyaah", query_string: "token=nope&at=41"), res)

        assert_includes res.body, %(name="next" value="/s/web_kanyaah?at=41")
      end

      # htmx swaps a fragment into a page that is already open, and an SSE
      # client has nowhere to show a card: those keep the plain refusal rather
      # than being handed a document to paste somewhere.
      def test_a_fragment_or_a_stream_is_still_refused_plainly
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })

        htmx = FakeResponse.new
        channel.send(:dispatch, gate_request("/s/web_kanyaah/recent", htmx: true), htmx)
        assert_equal 403, htmx.status
        assert_equal "token required", htmx.body

        stream = FakeResponse.new
        channel.send(:dispatch, gate_request("/events", accept: "text/event-stream"), stream)
        assert_equal "token required", stream.body
      end

      def test_the_right_token_writes_the_cookie_and_opens_the_page_that_was_asked_for
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })
        res = FakeResponse.new

        channel.send(:dispatch,
                     gate_request("/unlock", method: "POST", query_string: "token=t0k&next=%2Fs%2Fweb_kanyaah"),
                     res)

        assert_equal 303, res.status
        assert_equal "/s/web_kanyaah", res.headers["Location"]
        assert_equal "rubot_token=t0k; Path=/; HttpOnly; SameSite=Lax", res.headers["Set-Cookie"]
        refute_includes res.headers["Location"].to_s, "token",
                        "the cookie is set: the URL no longer has to carry it"
      end

      def test_a_wrong_token_leaves_the_reader_at_the_field
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })
        res = FakeResponse.new

        channel.send(:dispatch, gate_request("/unlock", method: "POST", query_string: "token=nope"), res)

        assert_equal 403, res.status
        assert_includes res.body, "Token tidak cocok."
        assert_nil res.headers["Set-Cookie"], "a wrong token writes no cookie"
      end

      # `next` is a path this app wrote into the form. An absolute URL typed in
      # by hand would otherwise make the gate an open redirect.
      def test_the_next_page_must_be_a_path_this_app_chose
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })

        [ "https://evil.example/x", "//evil.example/x" ].each do |bad|
          res = FakeResponse.new
          channel.send(:dispatch,
                       gate_request("/unlock", method: "POST",
                                               query_string: URI.encode_www_form("token" => "t0k", "next" => bad)),
                       res)

          assert_equal "/", res.headers["Location"], "#{bad.inspect} is not a path this app wrote"
        end
      end

      # --- assets ---------------------------------------------------------

      # --- installed app --------------------------------------------------

      # A phone installs what the manifest describes, so it has to name the app,
      # open at the doorway rather than at one conversation, and run without a
      # browser frame.
      def test_the_manifest_describes_an_installed_app
        manifest = JSON.parse(File.read(File.expand_path("../lib/rubot/web/assets/manifest.webmanifest", __dir__)))

        assert_equal "rubot", manifest["short_name"]
        assert_equal "standalone", manifest["display"]
        assert_equal "/", manifest["start_url"], "the doorway, not one session id"
        assert_equal "/", manifest["scope"]
        assert_equal "#2b332f", manifest["theme_color"]

        sizes = manifest["icons"].map { |icon| icon["sizes"] }
        assert_includes sizes, "192x192"
        assert_includes sizes, "512x512"
        assert_includes manifest["icons"].map { |icon| icon["purpose"] }, "maskable",
                        "Android crops a square icon, and the glyph has to survive it"
      end

      # Every icon the manifest promises has to exist, or the install offers the
      # app and then shows a blank square.
      def test_every_icon_the_manifest_names_is_on_disk
        assets = File.expand_path("../lib/rubot/web/assets", __dir__)
        manifest = JSON.parse(File.read(File.join(assets, "manifest.webmanifest")))

        manifest["icons"].each do |icon|
          name = File.basename(icon["src"])
          path = File.join(assets, name)

          assert File.file?(path), "#{name} is named in the manifest but missing"
          assert_equal "PNG", File.binread(path, 8)[1, 3], "#{name} has to be a real PNG"
        end
        assert File.file?(File.join(assets, "apple-touch-icon.png")),
               "iOS reads its own icon, not the manifest's"
      end

      # The page has to point at all of it: without the manifest link and the
      # Apple metas a phone offers a bookmark instead of an app.
      def test_the_page_points_at_the_installed_app
        html = View.render("layout", title: "rubot · Rubot", content: "isi", asset_version: 1)

        assert_includes html, %(<link rel="manifest" href="/manifest.webmanifest">)
        assert_includes html, %(rel="apple-touch-icon")
        assert_includes html, %(name="apple-mobile-web-app-capable" content="yes")
        assert_includes html, %(name="theme-color")
        assert_includes html, "viewport-fit=cover",
                        "a standalone window runs to the notch"
      end

      # A worker only controls the paths under its own, so it is served at the
      # root — and never cached by the browser, or a deploy reaches nobody.
      def test_the_service_worker_is_served_from_the_root_and_not_cached
        channel = Rubot::Channels::Web.new(channel_config: {})
        response = FakeResponse.new

        channel.send(:serve_worker, response)

        assert_equal 200, response.status
        assert_equal "text/javascript; charset=utf-8", response.headers["Content-Type"]
        assert_equal "no-cache", response.headers["Cache-Control"]
        assert_equal "/", response.headers["Service-Worker-Allowed"]
        assert_includes response.body, "rubot-shell-", "the worker has to know its own cache"
      end

      # The cache name is the asset stamp, not a constant: a stylesheet that
      # changed renames the cache, and the installed app rebuilds the shell
      # instead of answering with the copy it kept. A version someone has to
      # remember to bump is a promise that holds only until it is forgotten.
      def test_the_worker_names_its_cache_after_the_assets_it_installs
        channel = Rubot::Channels::Web.new(channel_config: {})
        response = FakeResponse.new

        channel.send(:serve_worker, response)

        refute_includes response.body, "__VERSION__", "the placeholder has to be replaced"
        assert_includes response.body, %(const VERSION = "rubot-shell-#{channel.send(:asset_version)}")
      end

      def test_the_manifest_is_served_with_its_own_type
        channel = Rubot::Channels::Web.new(channel_config: {})
        response = FakeResponse.new

        channel.send(:serve_manifest, response)

        assert_equal 200, response.status
        assert_includes response.headers["Content-Type"], "application/manifest+json"
        assert_equal "rubot", JSON.parse(response.body)["name"]
      end

      # The shell is kept, the conversation is not: a cached answer would be
      # handed to whoever opens the app next, and it would be a lie the moment
      # the turn moved on.
      def test_the_worker_keeps_the_shell_and_never_the_conversation
        worker = File.read(File.expand_path("../lib/rubot/web/assets/sw.js", __dir__))

        assert_includes worker, "/assets/app.css"
        assert_includes worker, "/vendor/htmx.min.js"
        assert_includes worker, %(/turns/), "the stream has to be excluded by path"
        assert_includes worker, 'request.mode === "navigate"'
        assert_includes worker, "caches.open(VERSION)"
      end

      # The page asks for app.css?v=<mtime>, and a lookup that ignored the query
      # answered every deploy with the copy the reader already had: the fix
      # looked like it never landed, on that one device, until the version
      # constant was bumped by hand. The query counts online — the network is the
      # only thing that can answer a URL the cache has never seen — and the loose
      # lookup survives as the offline fallback.
      def test_the_worker_asks_the_network_for_a_file_it_has_not_seen
        worker = File.read(File.expand_path("../lib/rubot/web/assets/sw.js", __dir__))
        lookup = worker[/async function cacheFirst.*?\n\}/m]

        refute_nil lookup, "cacheFirst is missing from sw.js"
        assert_match(/const hit = await cache\.match\(request\);/, lookup,
                     "the versioned URL is the key, or a deploy is invisible")
        assert_match(/cache\.match\(request, \{ ignoreSearch: true \}\)/, lookup,
                     "a stylesheet from an older deploy beats none while offline")
        assert_operator lookup.index("cache.match(request);"), :<, lookup.index("ignoreSearch"),
                        "online first; the loose lookup is only after the network said no"
      end

      # Registering is the only thing the page does about it, and it must not
      # stand in front of the first paint.
      def test_the_page_registers_the_worker_after_load
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, 'navigator.serviceWorker.register("/sw.js")'
        assert_includes js, 'window.addEventListener("load"'
      end

      # Every file in the shell is served under one version, so the stamp has to
      # move when any of them changes. It was the stylesheet's mtime, which left
      # a script change invisible to any browser that already had app.js cached;
      # the worker is in the list for the same reason.
      def test_the_asset_stamp_follows_the_newer_file
        channel = Rubot::Channels::Web.new(channel_config: {})
        assets = File.expand_path("../lib/rubot/web/assets", __dir__)
        newest = %w[app.css app.js sw.js].map { |name| File.mtime(File.join(assets, name)).to_i }.max

        assert_equal newest, channel.send(:asset_version)
      end

      # --- sessions -------------------------------------------------------

      # A session id has to survive the trip back to a persona: the SessionPool
      # roots a session's Ractor at the persona's workspace from the id alone.
      # A persona's second conversation must therefore still name its owner.
      def test_a_later_session_still_belongs_to_its_persona
        channel = Rubot::Channels::Web.new(channel_config: {})

        sid = channel.send(:new_session_id, "kanyaah")

        assert sid.start_with?("web_kanyaah~"), sid
        assert_equal "kanyaah", Rubot::PersonaStore.key_for_session(sid)
        refute_equal channel.send(:session_id, "kanyaah"), sid,
                     "a new session must not reuse the persona's first session"
      end

      # The sidebar is a list of conversations, so another persona's work must
      # never appear in it — the Ractors are separate, their files are not.
      def test_the_session_list_holds_only_one_personas_conversations
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" }, "rubot" => { "name" => "Rubot" } },
          sessions: {
            "web_kanyaah" => "Bikin carousel",
            "web_kanyaah~20261108-101010" => "Riset harga",
            "web_rubot" => "Cek repo"
          }
        )

        ids = channel.send(:sessions_for, "kanyaah").map { |entry| entry[:id] }

        assert_includes ids, "web_kanyaah"
        assert_includes ids, "web_kanyaah~20261108-101010"
        refute_includes ids, "web_rubot"
      end

      def test_a_session_row_is_named_by_the_prompt_that_started_it
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Riset harga template signature" }
        )

        row = channel.send(:session_rows, "kanyaah", "web_kanyaah").first

        assert_equal "Riset harga template signature", row[:label]
        assert row[:active]
      end

      # The list holds conversations, so it shows the name the model gave one
      # rather than the sentence that opened it. The prompt is only a fallback
      # for a session that has not been named yet.
      def test_a_named_session_is_listed_under_its_title
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "tolong cek dulu kenapa build-nya gagal di CI tapi lokal aman ya met" },
          titles: { "web_kanyaah" => "Build gagal di CI" }
        )

        row = channel.send(:session_rows, "kanyaah", "web_kanyaah").first

        assert_equal "Build gagal di CI", row[:label]
      end

      def test_the_header_and_tab_share_the_named_title
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "tolong cek kenapa build gagal" },
          titles: { "web_kanyaah" => "Build gagal di CI" }
        )

        markup = channel.send(:sidebar_markup, "web_kanyaah")

        assert_includes markup, %(data-title="Kanyaah · Build gagal di CI")
        assert_includes markup, ">Build gagal di CI</button>"
        assert_includes markup, %(/s/web_kanyaah/rename),
                        "the name is editable from the header it is drawn in"
      end

      # A session that has not been written yet has no file, so the row for the
      # one on screen comes from the caller instead of the index.
      def test_a_conversation_with_no_messages_is_listed_while_it_is_open
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })

        rows = channel.send(:session_rows, "kanyaah", "web_kanyaah~20261108-090000")

        assert_equal 1, rows.size
        assert_equal "Sesi baru", rows.first[:label]
        assert rows.first[:active]
      end

      # --- pinned and paged sessions --------------------------------------

      # The sidebar answers "which conversation", not "how long ago": the age
      # was a second column competing with the one thing the row is for, so it
      # is gone from the row and from what the row is built from.
      def test_a_session_row_does_not_show_how_long_ago_it_moved
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Halo" }
        )
        row = channel.send(:session_rows, "kanyaah", "web_kanyaah").first

        refute row.key?(:meta), "there is no age to draw"
        html = View.render("_session_row", row: row, token_query: "", page: 1,
                                          current: "web_kanyaah")
        refute_includes html, %(class="meta")
      end

      # Two lists in the sidebar, and both start open: a section that starts
      # folded would hide conversations the reader never chose to hide.
      def test_the_sidebar_has_pinned_and_recent_sections_that_start_open
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Halo" }
        )
        groups = channel.send(:session_groups, "kanyaah", "web_kanyaah")

        html = View.render("_sessions", groups: groups, token_query: "")

        assert_equal 2, html.scan(%(<details class="session-group" open>)).size,
                     "pinned and recent are both open"
        assert_includes html, %(<span class="group-name">Pinned</span>)
        assert_includes html, %(<span class="group-name">Recent</span>)
        assert_includes html, "Belum ada sesi yang di-pin."
      end

      def test_a_pinned_conversation_sits_above_the_rest_and_only_once
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: {
            "web_kanyaah" => [ [ "user", "paling lama" ] ],
            "web_kanyaah~pinned" => [ [ "user", "yang di-pin" ] ],
            "web_kanyaah~baru" => [ [ "user", "paling baru" ] ]
          }
        )
        Rubot::Session.store.pin_session("web_kanyaah~pinned", at: "2026-11-10T09:00:00Z")

        groups = channel.send(:session_groups, "kanyaah", "web_kanyaah~baru")

        assert_equal [ "yang di-pin" ], groups[:pinned].map { |row| row[:label] }
        assert groups[:pinned].first[:pinned]
        refute_includes groups[:recent].map { |row| row[:id] }, "web_kanyaah~pinned",
                        "a pinned conversation must not be listed in both sections"
        assert_equal 2, groups[:recent_total]
      end

      # A pinned conversation is drawn in the pinned section. When it is also
      # the one on screen, the recent list used to supply a second row for it —
      # so the same conversation appeared twice and both rows were marked
      # active, which reads as two open sessions.
      def test_an_open_pinned_conversation_is_drawn_once_and_marked_once
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: {
            "web_kanyaah" => [ [ "user", "yang lain" ] ],
            "web_kanyaah~pinned" => [ [ "user", "yang di-pin" ] ]
          }
        )
        Rubot::Session.store.pin_session("web_kanyaah~pinned", at: "2026-11-10T09:00:00Z")

        groups = channel.send(:session_groups, "kanyaah", "web_kanyaah~pinned")
        rows = groups[:pinned] + groups[:recent]

        assert_equal rows.map { |row| row[:id] }.uniq, rows.map { |row| row[:id] },
                     "the open pinned conversation must not be listed twice"
        assert_equal 1, rows.count { |row| row[:active] },
                     "exactly one row may be marked as the open one"
      end

      # The pinned conversation has no archive row of its own when it is brand
      # new, so it must still be drawn — in the pinned section, once.
      def test_a_brand_new_pinned_conversation_keeps_its_single_row
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ [ "user", "yang lain" ] ] }
        )
        Rubot::Session.store.pin_session("web_kanyaah", at: "2026-11-10T09:00:00Z")

        groups = channel.send(:session_groups, "kanyaah", "web_kanyaah")
        rows = groups[:pinned] + groups[:recent]

        assert_equal 1, rows.count { |row| row[:id] == "web_kanyaah" }
        assert_equal 1, rows.count { |row| row[:active] }
      end

      # A name typed by hand outranks the one the model guessed, and it has to
      # land everywhere the name is used: the header, the row in the sidebar, and
      # through the header the browser tab.
      def test_a_conversation_can_be_named_by_hand
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: {
            "web_kanyaah" => [ [ "user", "isi percakapan" ] ],
            "web_kanyaah~other" => [ [ "user", "yang lain" ] ]
          }
        )
        stub_title_writer(channel)

        res = FakeResponse.new
        channel.send(:rename_session, res, "web_kanyaah", form_post("name" => "  Proyek   Templete  "))

        assert_equal "Proyek Templete", stored_title("web_kanyaah"),
                     "the name is flattened and trimmed on the way in"
        assert_includes res.body, "Proyek Templete"
        assert_includes res.body, %(class="chat-head" id="chat-head" hx-swap-oob="true"),
                        "the header carries the new name, and the tab reads it from there"
        assert_includes res.body, %(class="sessions" id="sessions" hx-swap-oob="true"),
                        "the row in the sidebar is renamed with it"
      end

      # The title is a row in a list, not a paragraph: a newline in it would be
      # drawn as two rows, and an essay would push the persona name off the
      # strip. Both are clipped rather than refused, so a paste still works.
      def test_a_hand_written_name_is_one_short_line
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ [ "user", "isi percakapan" ] ] }
        )
        stub_title_writer(channel)

        long = "kata " * 40
        channel.send(:rename_session, FakeResponse.new, "web_kanyaah",
                     form_post("name" => "baris satu\nbaris dua"))

        assert_equal "baris satu baris dua", stored_title("web_kanyaah")

        channel.send(:rename_session, FakeResponse.new, "web_kanyaah", form_post("name" => long))
        clipped = stored_title("web_kanyaah")

        assert_operator clipped.length, :<=, Rubot::SessionNamer::MAX_TITLE_CHARS
        assert_operator clipped.length, :>, 40, "the name is clipped, not thrown away"
        refute_match(/\s\z/, clipped, "no dangling space where the cut fell")
      end

      # The session actor answers requests between turns, so a rename sent during
      # one would queue behind the answer and look like a hang. The old name is
      # left alone and the header is not swapped.
      def test_a_running_turn_refuses_the_rename
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ [ "user", "isi percakapan" ] ] }
        )
        stub_title_writer(channel)
        channel.define_singleton_method(:session_running?) { |_sid| true }

        res = FakeResponse.new
        channel.send(:rename_session, res, "web_kanyaah", form_post("name" => "Nama Baru"))

        assert_equal 409, res.status
        assert_empty res.body
        assert_equal "isi percakapan", stored_title("web_kanyaah")
      end

      def stub_title_writer(channel)
        store = Rubot::Session.store
        channel.define_singleton_method(:session_for) do |sid|
          Object.new.tap do |handle|
            handle.define_singleton_method(:set_session_title) do |title|
              store.upsert_session(id: sid, title: title)
            end
          end
        end
      end

      def stored_title(sid)
        Rubot::Session.store.sidebar(limit: 50).find { |row| row[:id] == sid }&.fetch(:title)
      end

      def form_post(fields)
        request = Struct.new(:query) do
          def [](key) = key == "HX-Request" ? "true" : nil
        end
        request.new(fields)
      end

      # The pin is pressed beside a conversation, not on a page of its own: the
      # answer is the sidebar, and the row the reader was on stays marked.
      def test_pinning_in_place_answers_with_the_sidebar_and_keeps_the_open_row_marked
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: {
            "web_kanyaah" => [ [ "user", "yang dibuka" ] ],
            "web_kanyaah~other" => [ [ "user", "yang di-pin" ] ]
          }
        )
        request = Struct.new(:query) do
          def [](key) = key == "HX-Request" ? "true" : nil
        end
        req = request.new({ "pin" => "1", "page" => "1", "current" => "web_kanyaah" })
        res = FakeResponse.new

        channel.send(:toggle_pin, res, "web_kanyaah~other", req)

        assert_equal 200, res.status
        assert_includes res.body, %(<nav class="sessions" id="sessions">)
        refute_includes res.body, "hx-swap-oob", "this is a targeted swap, not an out-of-band one"
        assert_includes res.body, %(class="session is-active")
        assert_includes res.body, %(aria-pressed="true")
      end

      def test_a_row_carries_a_pin_control_and_a_pinned_row_one_to_unpin_it
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ [ "user", "Halo" ] ] }
        )
        Rubot::Session.store.pin_session("web_kanyaah", at: "2026-11-10T09:00:00Z")

        html = View.render("_sessions",
                           groups: channel.send(:session_groups, "kanyaah", "web_kanyaah"),
                           token_query: "")

        assert_includes html, %(class="session-pin")
        assert_includes html, %(action="/s/web_kanyaah/pin")
        assert_includes html, %(name="pin" value="0")
        assert_includes html, %(aria-pressed="true")
      end

      # Pinning an eleventh conversation is not refused: the pin that has been
      # there longest gives way, so the list is the ten most recent choices.
      def test_pinning_past_the_cap_drops_the_oldest_pin
        ids = (1..11).map { |i| "web_kanyaah~#{format("%02d", i)}" }
        messages = ids.to_h { |id| [ id, [ [ "user", id ] ] ] }
        channel = channel_with_archive(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                       messages: messages)
        store = Rubot::Session.store
        ids.first(10).each_with_index do |id, i|
          store.pin_session(id, at: format("2026-11-%02dT10:00:00Z", i + 1))
        end

        req = Struct.new(:query) { def [](_key) = nil }.new({ "pin" => "1", "page" => "1" })
        channel.send(:toggle_pin, FakeResponse.new, ids.last, req)

        pinned = channel.send(:session_groups, "kanyaah", ids.last)[:pinned].map { |row| row[:id] }

        assert_equal 10, pinned.size
        refute_includes pinned, ids.first, "the oldest pin is the one that goes"
        assert_includes pinned, ids.last
      end

      # Twenty rows in the first block; asking for the next block appends to the
      # ones already loaded rather than replacing them, which is what makes the
      # button "load more" and not "page two".
      def test_recent_sessions_load_a_block_of_twenty_at_a_time
        ids = (1..21).map { |i| "web_kanyaah~#{format("%02d", i)}" }
        messages = ids.to_h { |id| [ id, [ [ "user", id ] ] ] }
        channel = channel_with_archive(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                       messages: messages)

        first = channel.send(:session_groups, "kanyaah", "web_kanyaah~01")
        loaded = channel.send(:session_groups, "kanyaah", "web_kanyaah~01", page: 2)

        assert_equal 20, first[:recent].size
        assert_equal 21, first[:recent_total]
        assert_equal 2, first[:pages]
        assert first[:more]
        assert_equal 2, first[:next_page]

        assert_equal 21, loaded[:recent].size, "the first block is still there"
        assert_equal 2, loaded[:page]
        refute loaded[:more]
      end

      # The block the button asks for is exactly the rows not on screen yet, so
      # appending it cannot repeat one.
      def test_a_recent_block_holds_only_the_rows_after_the_ones_shown
        ids = (1..25).map { |i| "web_kanyaah~#{format("%02d", i)}" }
        messages = ids.to_h { |id| [ id, [ [ "user", id ] ] ] }
        channel = channel_with_archive(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                       messages: messages)

        first = channel.send(:session_groups, "kanyaah", "web_kanyaah~01")
        block = channel.send(:recent_block, "kanyaah", "web_kanyaah~01", 2)

        assert_equal 5, block[:rows].size
        assert_equal 20, first[:recent].size
        assert_empty block[:rows].map { |row| row[:id] } & first[:recent].map { |row| row[:id] }
      end

      def test_the_load_more_control_carries_the_next_block_and_the_token
        ids = (1..21).map { |i| "web_kanyaah~#{format("%02d", i)}" }
        messages = ids.to_h { |id| [ id, [ [ "user", id ] ] ] }
        channel = channel_with_archive(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                       messages: messages)

        html = View.render("_sessions",
                           groups: channel.send(:session_groups, "kanyaah", "web_kanyaah~01"),
                           token_query: "?token=t0k")

        assert_includes html, %(class="recent-more" id="recent-more")
        assert_includes html, %(hx-get="/s/web_kanyaah~01/recent?page=2&amp;token=t0k")
        assert_includes html, %(hx-target="#recent-more")
        assert_includes html, %(hx-swap="outerHTML")
        assert_includes html, "Muat lebih banyak"
        refute_includes html, "page-note", "there are no numbered pages any more"
      end

      # The answer to "load more" is rows plus the control that follows them,
      # laid down where the old control was. On the last block there is no
      # control to follow, and its absence is what ends the list.
      def test_loading_more_answers_with_the_next_rows_and_the_control_that_follows
        ids = (1..41).map { |i| "web_kanyaah~#{format("%02d", i)}" }
        messages = ids.to_h { |id| [ id, [ [ "user", id ] ] ] }
        channel = channel_with_archive(personas: { "kanyaah" => { "name" => "Kanyaah" } },
                                       messages: messages)
        second = Struct.new(:query).new({ "page" => "2" })
        last = Struct.new(:query).new({ "page" => "3" })
        res = FakeResponse.new

        channel.send(:render_recent, res, "web_kanyaah~01", second)

        assert_equal 200, res.status
        assert_equal 20, res.body.scan(%(class="session-link")).size
        assert_includes res.body, %(id="recent-more")
        assert_includes res.body, "page=3", "the control points at the block after this one"

        res = FakeResponse.new
        channel.send(:render_recent, res, "web_kanyaah~01", last)

        assert_equal 1, res.body.scan(%(class="session-link")).size
        refute_includes res.body, %(id="recent-more"), "the list ends without a control"
      end

      def test_the_session_list_refresh_is_an_out_of_band_swap
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Halo" }
        )

        markup = channel.send(:sidebar_markup, "web_kanyaah")

        assert_includes markup, %(id="sessions" hx-swap-oob="true")
        assert_includes markup, "Halo"
      end

      # The name is what separates two conversations of one persona, so the
      # header has to carry it too — and be refreshable, because it does not
      # exist until the first turn is saved.
      def test_the_header_is_refreshed_together_with_the_sidebar
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Riset harga template signature" }
        )

        markup = channel.send(:sidebar_markup, "web_kanyaah")

        assert_includes markup, %(id="chat-head" hx-swap-oob="true")
        assert_includes markup, "Riset harga template signature"
      end

      # The end-to-end version of the test above: a real turn through the channel,
      # the naming request that follows it, and the markup the browser is handed
      # at the end. The name is only known once the turn is over, so a page that
      # does not receive this swap shows the prompt's first words until it is
      # reloaded — which is what the reader reported.
      def test_the_name_the_model_gives_reaches_the_page_when_the_turn_ends
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        config = channel.instance_variable_get(:@app_config)
        provider = NamingProvider.new(title: "Undangan pernikahan")
        channel.define_singleton_method(:session_for) do |sid|
          Rubot::Agent.new(config: config, provider: provider, session_id: sid)
        end

        res = FakeResponse.new
        channel.send(:create_turn, turn_request("Tolong susun undangan pernikahan"), res, "web_kanyaah")

        turn = channel.instance_variable_get(:@turns).values.first
        payload = nil
        turn.each_event { |type, data| payload = data if type == :sidebar }

        assert_equal 1, provider.naming_calls, "the conversation is named once the answer is delivered"
        refute_nil payload, "the turn has to tell the page that it has a name now"
        assert_includes payload, "Undangan pernikahan"
        assert_includes payload, %(id="chat-head" hx-swap-oob="true")
        assert_includes payload, %(id="sessions" hx-swap-oob="true")
        assert_includes payload, %(data-title="Kanyaah · Undangan pernikahan"),
                        "the tab title travels with the same swap"
      end

      # A conversation with no prompt yet has no name, and the header must not
      # invent one: it shows the persona alone.
      def test_an_unnamed_session_adds_nothing_to_the_header
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })

        assert_nil channel.send(:named_session_label, "kanyaah", "web_kanyaah~20261108-090000")
        assert_equal "Kanyaah",
                     channel.send(:document_title, "Kanyaah",
                                  channel.send(:named_session_label, "kanyaah", "web_kanyaah~x"))
      end

      def test_the_document_title_names_the_session
        channel = Rubot::Channels::Web.new(channel_config: {})

        assert_equal "Kanyaah · Riset harga",
                     channel.send(:document_title, "Kanyaah", "Riset harga")
        assert_equal "Kanyaah", channel.send(:document_title, "Kanyaah", nil)
      end

      # A conversation is a file: deleting the row deletes the file, and the
      # browser is sent to whatever is left instead of a page that is now gone.
      def test_deleting_a_conversation_removes_its_file_and_lands_on_what_is_left
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: {
            "web_kanyaah" => "Lama",
            "web_kanyaah~20261108-101010" => "Baru"
          }
        )
        res = FakeResponse.new
        dir = channel.instance_variable_get(:@app_config).sessions_dir

        channel.send(:delete_session, res, "web_kanyaah~20261108-101010", nil)

        refute File.exist?(File.join(dir, "web_kanyaah~20261108-101010.json"))
        assert File.exist?(File.join(dir, "web_kanyaah.json"))
        assert_equal 303, res.status
        assert_equal "/s/web_kanyaah", res.headers["Location"]
      end

      # The last conversation of a persona leaves the sidebar empty, so there is
      # no row to land on: the persona itself opens a fresh one.
      def test_deleting_the_last_conversation_lands_on_the_persona
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Lama" }
        )
        res = FakeResponse.new

        channel.send(:delete_session, res, "web_kanyaah", nil)

        assert_equal 303, res.status
        assert_equal "/p/kanyaah", res.headers["Location"]
      end

      # The delete URL is a bare id, so it has to be checked against the
      # personas that exist just as any other route is.
      def test_deleting_a_session_of_an_unknown_persona_is_not_found
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        res = FakeResponse.new

        channel.send(:delete_session, res, "web_ghost", nil)

        assert_equal 404, res.status
      end

      # A reminder written in a persona's web conversation must be filed with
      # that persona, exactly as in a Telegram topic — otherwise it fires into
      # an agent that never had the persona's memory.
      def test_a_turn_tells_the_cron_tool_which_workspace_it_runs_in
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        config = channel.instance_variable_get(:@app_config)
        cron = Rubot::Tools::Cron.new
        agent = FakeToolAgent.new(cron)
        channel.define_singleton_method(:session_for) { |_sid| agent }

        channel.send(:bind_cron_delivery, "web_kanyaah")

        assert_equal config.workspace, cron.delivery_context[:workspace]
        assert_equal "web", cron.delivery_context[:channel]
      end

      def test_a_personas_conversation_files_its_reminders_with_the_persona
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        pool = FakeWorkspacePool.new(File.join(Dir.tmpdir, "personas", "kanyaah"))
        channel.instance_variable_set(:@pool, pool)

        cron = Rubot::Tools::Cron.new
        agent = FakeToolAgent.new(cron)
        channel.define_singleton_method(:session_for) { |_sid| agent }

        channel.send(:bind_cron_delivery, "web_kanyaah")

        assert_equal File.join(Dir.tmpdir, "personas", "kanyaah"), cron.delivery_context[:workspace]
      end

      # The job names the persona it was written in, so a fired reminder is
      # answered by that persona instead of by whichever one comes first.
      def test_a_reminder_remembers_the_persona_it_was_written_in
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        cron = Rubot::Tools::Cron.new
        agent = FakeToolAgent.new(cron)
        channel.define_singleton_method(:session_for) { |_sid| agent }

        channel.send(:bind_cron_delivery, "web_kanyaah")

        assert_equal "kanyaah", cron.delivery_context[:slug]
      end

      # A daily prompt wants its own conversation: the sidebar shows it as a new
      # chat each day instead of one transcript that grows forever.
      def test_a_fired_job_that_asks_for_a_new_conversation_gets_one
        channel = channel_with_sessions(personas: { "english-tutor" => { "name" => "English Tutor" } })
        session = RecordingCronSession.new
        opened = []
        channel.define_singleton_method(:new_session_id) { |slug| "web_#{slug}~20261110-210000" }
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:session_for) do |sid|
          opened << sid
          session
        end

        channel.send(:deliver_cron_turn,
                     mode: "agent_turn", slug: "english-tutor", new_session: true,
                     description: "Practice", result: { agent_message: "Practice!" })

        assert_equal [ "web_english-tutor~20261110-210000" ], opened
        assert_equal "Practice!", session.calls.first[:text]
        assert session.calls.first[:fresh], "a new conversation should not inherit the old history"
        # Untitled sessions would be impossible to tell apart a week later.
        assert_equal 1, session.titles.size
        assert_includes session.titles.first, "Practice"
        assert_includes session.titles.first, Time.now.strftime("%Y-%m-%d")
      end

      # Without `new_session` the job is one more turn in the conversation the
      # persona already has, which is what a reminder wants.
      def test_a_fired_job_without_a_new_conversation_lands_in_the_personas_chat
        channel = channel_with_sessions(personas: { "english-tutor" => { "name" => "English Tutor" } })
        session = RecordingCronSession.new
        opened = []
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:session_for) do |sid|
          opened << sid
          session
        end

        channel.send(:deliver_cron_turn,
                     mode: "agent_turn", slug: "english-tutor", new_session: false,
                     result: { agent_message: "Minum air" })

        assert_equal [ "web_english-tutor" ], opened
        refute session.calls.first[:fresh]
        assert_empty session.titles, "a reminder must not rename the conversation it lands in"
      end

      # A job whose persona was deleted must still have somewhere to land.
      def test_a_fired_job_with_an_unknown_persona_falls_back_to_the_default
        channel = channel_with_sessions(personas: { "english-tutor" => { "name" => "English Tutor" } })
        session = RecordingCronSession.new
        opened = []
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:session_for) do |sid|
          opened << sid
          session
        end

        channel.send(:deliver_cron_turn,
                     mode: "agent_turn", slug: "ghost", new_session: false,
                     result: { agent_message: "Halo" })

        assert_equal [ channel.send(:session_id) ], opened
      end

      # The page sits idle while a job fires, so nothing is asking: the sidebar
      # has to arrive on its own. It rides a stream the page opens when it
      # loads and keeps open while it is there.
      def test_the_page_listens_for_news_while_it_sits_idle
        channel = channel_with_sessions(
          personas: { "english-tutor" => { "name" => "English Tutor" } },
          sessions: { "web_english-tutor" => "Halo" }
        )
        res = FakeResponse.new

        channel.send(:render_session, res, "web_english-tutor")

        assert_includes res.body, %(sse-connect="/events?sid=web_english-tutor"),
                        "an idle page has no turn stream, so it needs one of its own"
      end

      # Only the persona that gained a conversation hears about it: a page of
      # another persona has no row to redraw.
      def test_a_new_conversation_reaches_only_its_own_personas_pages
        channel = channel_with_sessions(personas: {
          "english-tutor" => { "name" => "English Tutor" },
          "kanyaah" => { "name" => "Kanyaah" }
        })
        listening = Queue.new
        elsewhere = Queue.new
        channel.send(:listen_for_events, "web_english-tutor", listening)
        channel.send(:listen_for_events, "web_kanyaah", elsewhere)

        channel.send(:broadcast_sessions, "english-tutor")

        refute listening.empty?, "the persona's page has a sidebar to redraw"
        assert elsewhere.empty?, "another persona's page has nothing new to draw"
      end

      def test_a_page_that_went_away_stops_being_written_to
        channel = channel_with_sessions(personas: { "english-tutor" => { "name" => "English Tutor" } })
        queue = Queue.new
        channel.send(:listen_for_events, "web_english-tutor", queue)
        channel.send(:stop_listening_for_events, queue)

        channel.send(:broadcast_sessions, "english-tutor")

        assert queue.empty?, "a stream that has gone away must not be written to"
      end

      # The naming request is what a turn used to wait for, and it now runs
      # after the turn has ended. The page therefore has to be told when it is
      # done: that push is the only moment the new name can appear without a
      # reload.
      def test_the_name_learned_after_the_turn_is_pushed_to_the_page
        channel = channel_with_sessions(
          personas: { "english-tutor" => { "name" => "English Tutor" } },
          sessions: { "web_english-tutor" => "Halo" }
        )
        queue = Queue.new
        channel.send(:listen_for_events, "web_english-tutor", queue)

        assert channel.send(:defer_learning?), "the turn must not wait for naming"
        channel.send(:after_learning, "web_english-tutor")

        refute queue.empty?, "the page has a new name to show"
      end

      # The page may not be open at all — that is the whole point of a daily
      # job firing at nine. Whoever is not looking at the app is reached by a
      # notification instead, and it points at the conversation the job opened
      # so the tap lands in the right place.
      def test_a_fired_job_notifies_the_devices_that_have_no_page_open
        channel = channel_with_sessions(personas: { "english-tutor" => { "name" => "English Tutor" } })
        session = RecordingCronSession.new
        pushes = []
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:session_for) { |_sid| session }
        channel.define_singleton_method(:notify_push) do |slug, **options|
          pushes << { slug: slug }.merge(options)
          { "queued" => 1 }
        end

        channel.send(:deliver_cron_turn,
                     mode: "agent_turn", slug: "english-tutor", new_session: true,
                     description: "Practice", result: { agent_message: "Practice!" })

        assert_equal 1, pushes.size, "a fired job has to reach the devices, not only the pages"
        assert_equal "english-tutor", pushes.first[:slug]
        assert_includes pushes.first[:body], "Practice",
                        "the notification says what the job is, in the reader's own words"
        assert_match(%r{\A/s/web_english-tutor}, pushes.first[:url],
                     "tapping it opens the conversation the job just opened")
      end

      # A conversation the job opened already holds the first thing the persona
      # said. That line is the invitation; the job's description is a label. A
      # lock screen is a place to be invited, so the opening wins — the bold
      # line is the greeting and the body is the question worth answering.
      def test_a_new_conversation_announces_itself_in_its_own_words
        channel = channel_with_sessions(personas: { "english-tutor" => { "name" => "English Tutor" } })
        session = RecordingCronSession.new(
          reply: "Hey Met! Today we are talking about **small wins**.\n\nWhat's one small win you had this week?\n\n"
        )
        pushes = []
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:session_for) { |_sid| session }
        channel.define_singleton_method(:notify_push) do |slug, **options|
          pushes << { slug: slug }.merge(options)
          { "queued" => 1 }
        end

        channel.send(:deliver_cron_turn,
                     mode: "agent_turn", slug: "english-tutor", new_session: true,
                     description: "Daily English speaking practice — 21.00 WIB",
                     result: { agent_message: "Practice!" })

        assert_equal "Hey Met! Today we are talking about small wins.", pushes.first[:title],
                     "the bold line is the opening, with the markdown a page needs taken out"
        assert_equal "What's one small win you had this week?", pushes.first[:body],
                     "the body asks the one question the reader can answer from the lock screen"
        refute_includes pushes.first[:body], "21.00 WIB",
                        "a static description is the fallback, not the invitation"
      end

      # A reminder has no opening worth quoting: it is one sentence the reader
      # wrote for themselves, and that sentence is the whole notification.
      def test_a_reminder_still_says_what_it_is
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        session = RecordingCronSession.new(reply: "Sudah diminum?")
        pushes = []
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:session_for) { |_sid| session }
        channel.define_singleton_method(:notify_push) do |slug, **options|
          pushes << { slug: slug }.merge(options)
          { "queued" => 1 }
        end

        channel.send(:deliver_cron_turn,
                     mode: "agent_turn", slug: "kanyaah", new_session: false,
                     description: "Minum air", result: { agent_message: "Minum air" })

        assert_equal "rubot · Kanyaah", pushes.first[:title],
                     "a reminder is signed by the persona so a busy phone knows who is talking"
        assert_equal "Minum air", pushes.first[:body]
      end

      # One glance, one line: a long opening is cut where a word ends, and a
      # bold line that cannot fit stops being a hook.
      def test_a_long_opening_is_cut_to_what_a_lock_screen_shows
        channel = channel_with_sessions(personas: { "english-tutor" => { "name" => "English Tutor" } })
        session = RecordingCronSession.new(
          reply: "Hello and welcome back to your daily English practice, where today we are going to talk about the small things.\n\n" \
                 "Tell me about a small win you had this week, something that made you feel like the day was worth it?"
        )
        pushes = []
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:session_for) { |_sid| session }
        channel.define_singleton_method(:notify_push) do |slug, **options|
          pushes << { slug: slug }.merge(options)
          { "queued" => 1 }
        end

        channel.send(:deliver_cron_turn,
                     mode: "agent_turn", slug: "english-tutor", new_session: true,
                     description: "Practice", result: { agent_message: "Practice!" })

        assert_operator pushes.first[:title].length, :<=, Rubot::Channels::Web::NOTIFY_HOOK_CHARS
        assert_operator pushes.first[:body].length, :<=, Rubot::Channels::Web::TURN_NOTIFY_CHARS
        assert pushes.first[:title].end_with?("…"), "a cut line says so"
        refute_match(/\s\z/, pushes.first[:body].sub(/…\z/, ""), "a cut never leaves a space before it")
      end

      # Nothing is announced when there is nobody to write it for.
      def test_a_job_with_no_description_still_says_something
        channel = channel_with_sessions(personas: { "english-tutor" => { "name" => "English Tutor" } })
        session = RecordingCronSession.new
        pushes = []
        channel.define_singleton_method(:prepare_delivery) { |_sid| nil }
        channel.define_singleton_method(:session_for) { |_sid| session }
        channel.define_singleton_method(:notify_push) do |slug, **options|
          pushes << { slug: slug }.merge(options)
          { "queued" => 1 }
        end

        channel.send(:deliver_cron_turn,
                     mode: "agent_turn", slug: "english-tutor", new_session: false,
                     result: { agent_message: "Minum air" })

        refute_empty pushes.first[:body].to_s.strip, "an empty notification is a notification nobody understands"
      end

      def test_each_session_row_carries_a_way_to_delete_it
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Halo" }
        )
        groups = channel.send(:session_groups, "kanyaah", "web_kanyaah")

        html = View.render("_sessions", groups: groups, token_query: "?token=t0k")

        assert_includes html, %(action="/s/web_kanyaah/delete?token=t0k")
        assert_includes html, %(aria-label="Hapus sesi")
      end

      def test_opening_a_persona_lands_on_its_newest_conversation
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Lama" }
        )
        res = FakeResponse.new

        channel.send(:open_persona, res, "kanyaah", nil)

        assert_equal 303, res.status
        assert_equal "/s/web_kanyaah", res.headers["Location"]
      end

      # A hand-typed URL must not open a session of a persona that is gone.
      def test_a_session_of_an_unknown_persona_is_not_found
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        res = FakeResponse.new

        channel.send(:render_session, res, "web_ghost")

        assert_equal 404, res.status
      end

      # Every bubble carries a `.sr-only` label, which is absolutely
      # positioned. A scroll container that is not a containing block lets
      # them resolve against the initial containing block instead: the
      # browser then grows the *document* to fit them, and the page scrolls
      # through thousands of pixels of empty background below the chat.
      def test_thread_is_a_containing_block_for_its_scrollable_content
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        rule = css[/^\.thread \{[^}]*\}/]

        refute_nil rule, "the .thread rule is missing from app.css"
        assert_includes rule, "position: relative",
                        ".thread must be positioned, or its absolutely positioned " \
                        "descendants escape the scroll clip and stretch the document"
      end

      # The chat column's own column has to be allowed to be narrower than what
      # is in it. Left implicit it is `auto`, which sizes to the widest
      # max-content — the status row, whose figures never wrap. On a phone that
      # column came out wider than the screen, and whatever sat at its far
      # right, the button that opens the usage report, ended up past the edge.
      def test_the_chat_column_cannot_grow_past_the_screen
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        rule = css[/^\.chat \{[^}]*\}/]

        refute_nil rule, "the .chat rule is missing from app.css"
        assert_includes rule, "grid-template-columns: minmax(0, 1fr)"
      end

      # The report opens upward out of a row pinned to the bottom edge of the
      # screen, so that row cannot be a clipping box: `overflow: hidden` there
      # swallowed the panel whole, leaving a button that opened nothing. What
      # has to stay inside is the figures, and they carry the clip instead.
      def test_the_status_row_does_not_clip_the_report_it_opens
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        row = css[/^\.status-line \{[^}]*\}/]
        figures = css[/^\.status-line \.metrics \{[^}]*\}/]

        refute_nil row, "the .status-line rule is missing from app.css"
        refute_includes row, "overflow: hidden",
                        "a clipping status row hides the panel that opens out of it"
        refute_nil figures, "the figures need their own rule to carry the clip"
        assert_includes figures, "overflow: hidden"
      end

      # The picker lives at the foot of the sidebar, and a phone's sidebar is
      # the drawer. Hiding that foot hid the only control that changes the
      # theme, so the palettes were unreachable on the screen where a light
      # page matters most. Only the facts about the connection go.
      def test_the_drawer_keeps_the_theme_picker
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        narrow = css[/^@media \(max-width: 860px\) \{.*?\n\}/m]

        refute_nil narrow, "the drawer's breakpoint is missing from app.css"
        refute_match(/\.sidebar-foot \{ display: none/, narrow,
                     "the phone's sidebar foot holds the theme picker")
        assert_includes narrow, ".sidebar-foot dl { display: none; }",
                        "the connection facts are what the drawer has no room for"
      end

      # "Everforest" is a long word in a 15rem sidebar. Laid out as one wrapped
      # flex row beside its caption, the three swatches fitted two to the first
      # line and left "Terang" stranded on a second — a control that looked
      # broken rather than offered. The caption takes a line of its own and the
      # swatches share an unwrapped row beneath it, so the break is a decision
      # and not an accident of how wide the words happen to be.
      def test_the_theme_swatches_share_one_row_under_their_caption
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        picker = css[/^\.theme-picker \{[^}]*\}/]
        label = css[/^\.theme-label \{[^}]*\}/]

        refute_nil picker, "the .theme-picker rule is missing from app.css"
        refute_nil label, "the .theme-label rule is missing from app.css"
        refute_includes picker, "flex-wrap: wrap",
                        "a wrapped picker strands the last palette on its own line"
        assert_includes picker, "repeat(3, max-content)",
                        "three swatches, each as wide as its own word"
        assert_includes label, "grid-column: 1 / -1",
                        "the caption spans the row, so the three swatches share the next"
      end

      # A list is a column of its own, but the column sits inside the
      # paragraph: the marker starts on the paragraph's left edge and the item
      # text steps in by one gutter. Hanging the marker in the page margin put
      # it on the wrong side of the edge the paragraph draws — a stray bullet
      # rather than a list.
      #
      # The marker is drawn by the stylesheet because a bullet and a digit do
      # not share a box: left to the browser, the numbered list put its numbers
      # in a different column from the bulleted list's bullets.
      def test_a_list_keeps_its_marker_inside_the_paragraph_for_both_kinds
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        list = css[/^\.text ul,\n\.text ol \{[^}]*\}/]

        refute_nil list, "the .text list rule is missing from app.css"
        assert_includes list, "padding-left: var(--marker-gutter)"
        assert_includes list, "list-style: none"

        # One box, shared: the pixel the marker starts on cannot depend on
        # whether the item is numbered.
        box = css[/^\.text li::before \{[^}]*\}/]
        refute_nil box, "the marker needs a rule of its own"
        assert_includes box, "var(--marker-gutter)"
        assert_includes box, "text-align: left"

        assert_includes css, %(.text ul > li::before { content: "•"; })
        assert_includes css, %(.text ol > li::before { content: counter(rubot-item) "."; })

        # A nested list is the one that indents twice: its markers must not
        # land on the parent's, and its text must stay inside the parent's.
        nested = css[/^\.text li > ul,\n\.text li > ol \{[^}]*\}/]
        refute_nil nested, "a nested list needs a rule of its own"
        assert_includes nested, "padding-left: var(--marker-gutter)"
      end

      # --- pictures -------------------------------------------------------

      # The agent hands a picture back through send_file. The web channel has
      # no upload endpoint, so the tool copies the file into the conversation's
      # own folder and says which name it wrote — that name is what the page
      # draws, and what a refreshed page can draw again.
      def test_send_file_hands_a_picture_into_the_conversation
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        source = File.join(Dir.mktmpdir, "Desain Final (v2).png")
        File.binwrite(source, png_bytes)

        tool = Tools::SendFile.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("path" => source)

        stored = result[/\[web-attachment ([^\]]+)\]/, 1]
        refute_nil stored, "the result has to name the file it stored: #{result}"
        assert_match(/\A[0-9a-f]{32}-desain-final-v2\.png\z/, stored)
        assert_equal png_bytes, File.binread(File.join(dir, stored))
      end

      # Only what the page can draw or hand back: a picture, a PDF, a markdown
      # note. A file stored where nothing would ever show it is worse than a
      # refusal.
      def test_send_file_refuses_what_the_page_cannot_draw
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        source = File.join(Dir.mktmpdir, "arsip.zip")
        File.binwrite(source, "PK\x03\x04")

        tool = Tools::SendFile.new
        tool.delivery_context = { channel: "web", dir: channel.send(:attachments_dir, "web_kanyaah") }
        result = tool.execute("path" => source)

        assert result.start_with?("ERROR"), "a file the page cannot draw is refused, not stored"
        assert_includes result, "pictures and documents"
      end

      # A PDF is not a picture, but the browser opens one on its own: it is
      # stored like a picture and named "as a document", which is the word the
      # page reads to decide between a picture and a card.
      def test_send_file_hands_a_pdf_into_the_conversation
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        source = File.join(Dir.mktmpdir, "Laporan Triwulan.pdf")
        File.binwrite(source, "%PDF-1.4\n")

        tool = Tools::SendFile.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("path" => source)

        stored = result[/\[web-attachment ([^\]]+)\]/, 1]
        assert_match(/\A[0-9a-f]{32}-laporan-triwulan\.pdf\z/, stored.to_s)
        assert_includes result, "as a document"
        assert_equal "%PDF-1.4\n", File.binread(File.join(dir, stored))
      end

      # `.markdown` is stored as `.md`, the same way `.jpeg` becomes `.jpg`:
      # one extension per format keeps the route that serves it to one shape.
      def test_send_file_stores_a_markdown_note_as_md
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        source = File.join(Dir.mktmpdir, "Catatan Rapat.markdown")
        File.write(source, "# Rapat\n\n- satu\n")

        tool = Tools::SendFile.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("path" => source)

        stored = result[/\[web-attachment ([^\]]+)\]/, 1]
        assert_match(/\A[0-9a-f]{32}-catatan-rapat\.md\z/, stored.to_s)
        assert_includes result, "as a document"
        assert_includes File.read(File.join(dir, stored)), "# Rapat"
      end

      # "Kirim 5 gambar" is one instruction; one call stores all five and names
      # each of them, so the page draws the batch as one strip under one row.
      def test_send_files_hands_a_batch_into_the_conversation
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        sources = %w[satu dua tiga empat lima].map do |base|
          path = File.join(Dir.mktmpdir, "#{base}.png")
          File.binwrite(path, png_bytes)
          path
        end

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => sources)

        stored = result.scan(/\[web-attachment ([^\]]+)\]/).flatten

        assert_equal 5, stored.size, "every picture in the batch is named: #{result}"
        assert_equal %w[dua empat lima satu tiga], stored.map { |n| n[/-([a-z]+)\.png\z/, 1] }.sort
        stored.each { |name| assert_equal png_bytes, File.binread(File.join(dir, name)) }
      end

      # A batch may mix pictures and documents — a PDF report beside the
      # screenshots it quotes — and one strip holds both: the page decides per
      # file which of the two it draws.
      def test_send_files_hands_pictures_and_documents_into_one_strip
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        sources = [
          File.join(Dir.mktmpdir, "grafik.png").tap { |path| File.binwrite(path, png_bytes) },
          File.join(Dir.mktmpdir, "laporan.pdf").tap { |path| File.write(path, "%PDF-1.4\n") },
          File.join(Dir.mktmpdir, "catatan.md").tap { |path| File.write(path, "# Rapat\n") }
        ]

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => sources)

        stored = result.scan(/\[web-attachment ([^\]]+)\]/).flatten
        assert_equal 3, stored.size, "every file in the batch is named: #{result}"
        assert_includes result, "as attachments"

        attachments = channel.send(:sent_attachments, "send_files", result, "web_kanyaah")
        assert_equal %i[picture document document], attachments.map { |file| file[:kind] }
        assert_equal %w[MD PDF PNG], attachments.map { |file| file[:label] }.sort
        assert_equal %w[catatan.md grafik.png laporan.pdf],
                     attachments.map { |file| file[:name] }.sort
      end

      # A batch is not all-or-nothing: the file that is missing is said out
      # loud, and the rest still arrive.
      def test_send_files_sends_the_rest_when_one_path_is_missing
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        good = File.join(Dir.mktmpdir, "ada.png")
        File.binwrite(good, png_bytes)

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => [ good, File.join(Dir.mktmpdir, "hilang.png") ])

        assert_equal 1, result.scan(/\[web-attachment /).size
        assert_includes result, "hilang.png"
        assert_includes result, "not found"
        refute result.start_with?("ERROR"), "one good file still makes the call a success"
      end

      # Nothing sent, nothing to show: the call has to read as a failure.
      def test_send_files_reports_a_batch_that_sent_nothing
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => [ "/nowhere/a.png", "/nowhere/b.png" ])

        assert result.start_with?("ERROR"), result
        assert_includes result, "a.png"
        assert_includes result, "b.png"
      end

      def test_send_files_refuses_more_than_it_can_send_in_one_call
        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: Dir.mktmpdir }

        count = Tools::SendFiles::MAX_FILES + 1
        result = tool.execute("paths" => Array.new(count) { |i| "x#{i}.png" })

        assert result.start_with?("ERROR"), result
        assert_includes result, Tools::SendFiles::MAX_FILES.to_s
      end

      # A model that has just used send_file answers with "path"; a model
      # wrapping a long list sometimes serialises the array back into a string.
      # The second one used to make every path "not found" at once, because
      # Array() wraps the whole string as a single path.
      def test_send_files_accepts_a_json_encoded_array
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        sources = %w[satu dua tiga].map do |base|
          path = File.join(Dir.mktmpdir, "#{base}.png")
          File.binwrite(path, png_bytes)
          path
        end

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => JSON.generate(sources))

        assert_equal 3, result.scan(/\[web-attachment /).size, result
      end

      # Ten paths in one call is the case that found this: the array arrived as
      # a string and the whole batch failed as nine non-existent files.
      def test_send_files_accepts_ten_paths_in_one_json_string
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        sources = (1..10).map do |n|
          path = File.join(Dir.mktmpdir, "gambar-#{n}.png")
          File.binwrite(path, png_bytes)
          path
        end

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => JSON.generate(sources))

        assert_equal 10, result.scan(/\[web-attachment /).size, result
        refute_includes result, "not found"
      end

      # A path that merely begins with a bracket is still a path: parsing must
      # not swallow a real file name.
      def test_send_files_keeps_a_path_that_only_looks_like_json
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        source = File.join(Dir.mktmpdir, "[draft] catatan.png")
        File.binwrite(source, png_bytes)

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => [ source ])

        assert_equal 1, result.scan(/\[web-attachment /).size, result
      end

      def test_send_files_accepts_a_single_path_key
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        source = File.join(Dir.mktmpdir, "satu.png")
        File.binwrite(source, png_bytes)

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("path" => source)

        assert_equal 1, result.scan(/\[web-attachment /).size, result
      end

      # The marker is read back out of the result the transcript keeps, which is
      # how a conversation drawn a week later still knows which stored file that
      # call produced.
      def test_the_channel_reads_the_picture_back_out_of_the_tool_result
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        stored = "e" * 32 + "-desain.png"
        result = "Sent desain.png (12 bytes) as a picture. [web-attachment #{stored}]"

        picture = channel.send(:sent_attachments, "send_file", result, "web_kanyaah").first

        assert_equal "desain.png", picture[:name]
        assert_includes picture[:url], "/s/web_kanyaah/media/#{stored}"
        assert_equal "e" * 32, picture[:id],
                     "the stored id is what lets the page keep the picture's node"
        assert_equal :picture, picture[:kind]

        assert_empty channel.send(:sent_attachments, "shell", result, "web_kanyaah"),
                     "only a file-sending result names a picture"
        assert_empty channel.send(:sent_attachments, "send_file",
                                  "Sent x. [web-attachment ../../etc/passwd]", "web_kanyaah")
      end

      # A PDF and a markdown note are read out of the same marker as a picture,
      # but they are not pictures: the page hands them over as a card, and the
      # badge on that card names the format.
      def test_a_document_is_read_back_as_a_card_not_a_picture
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        stored = "d" * 32 + "-laporan.pdf"
        result = "Sent laporan.pdf (12 bytes) as a document. [web-attachment #{stored}]"

        document = channel.send(:sent_attachments, "send_file", result, "web_kanyaah").first

        assert_equal :document, document[:kind]
        assert_equal "PDF", document[:label]
        assert_equal "laporan.pdf", document[:name]
        assert_includes document[:url], "/s/web_kanyaah/media/#{stored}"
      end

      # One call, several files: the result of send_files carries a marker
      # per file, and the page turns every one of them into a picture in the
      # same strip.
      def test_a_batch_result_names_every_picture_it_sent
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        names = %w[satu dua tiga].map { |base| "#{SecureRandom.hex(16)}-#{base}.png" }
        result = "Sent 3 files as attachments (png, jpg, gif, webp, pdf, md). " +
                 names.map { |name| "[web-attachment #{name}]" }.join(" ")

        pictures = channel.send(:sent_attachments, "send_files", result, "web_kanyaah")

        assert_equal 3, pictures.size, "every marker becomes a picture"
        assert_equal names.size, pictures.map { |p| p[:url] }.uniq.size
        assert_equal %w[tiga.png satu.png dua.png], pictures.map { |p| p[:name] }.sort.reverse
        assert_equal %i[picture picture picture], pictures.map { |p| p[:kind] }
      end

      # A picture belongs to a conversation: the route looks only inside that
      # conversation's folder, so a name borrowed from another session is a 404
      # rather than a leak.
      def test_a_picture_from_another_session_does_not_resolve
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Halo", "web_kanyaah~20261108-101010" => "Hai" }
        )
        name = write_picture(channel, "web_kanyaah")

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah~20261108-101010", name)
        assert_equal 404, res.status

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah", "../../etc/passwd")
        assert_equal 404, res.status
      end

      # Served inline under the type of its extension, with the reader's own
      # file name in the disposition rather than the stored id.
      def test_a_picture_is_served_back_under_its_own_name
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        name = write_picture(channel, "web_kanyaah", "desain-final.png")

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah", name)

        assert_equal 200, res.status
        assert_equal "image/png", res.headers["Content-Type"]
        assert_includes res.headers["Content-Disposition"], 'filename="desain-final.png"'
        assert_equal png_bytes, res.body
      end

      # A PDF is served as a PDF, so the browser's own viewer opens it. It is
      # inline rather than an attachment: a click on the card is a look at the
      # document, not a save it.
      def test_a_pdf_is_served_as_a_pdf
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        name = write_attachment(channel, "web_kanyaah", "laporan.pdf", "%PDF-1.4\n")

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah", name)

        assert_equal 200, res.status
        assert_equal "application/pdf", res.headers["Content-Type"]
        assert_includes res.headers["Content-Disposition"], 'filename="laporan.pdf"'
        assert_equal "%PDF-1.4\n", res.body
      end

      # A markdown note is served as text, not as text/markdown: a browser
      # downloads a type it has no viewer for, and a note the reader has to
      # save before reading is a note that never arrives.
      def test_a_markdown_note_is_served_as_text
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        name = write_attachment(channel, "web_kanyaah", "catatan.md", "# Rapat\n")

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah", name)

        assert_equal 200, res.status
        assert_equal "text/plain; charset=utf-8", res.headers["Content-Type"]
        assert_equal "# Rapat\n", res.body
      end

      # The route takes the names this channel writes and nothing else: an
      # extension it never generates is a 404, whatever is on disk.
      def test_a_name_the_channel_never_writes_is_not_served
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        name = write_attachment(channel, "web_kanyaah", "skrip.rb", "puts 1\n")

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah", name)

        assert_equal 404, res.status
      end

      def test_a_picture_that_does_not_exist_is_not_found
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        res = FakeResponse.new

        channel.send(:serve_media, res, "web_kanyaah", "a" * 32 + ".png")

        assert_equal 404, res.status
      end

      # A file the agent sent sits in the timeline under the row that produced
      # it, drawn by the same strip the answer's pictures use.
      def test_a_picture_the_agent_sent_is_drawn_in_the_timeline
        image = { url: "/s/web_kanyaah/media/x.png?token=t0k", name: "desain.png", kind: :picture }

        html = View.render("_timeline", items: [ { kind: :attachments, list: [ image ] } ])

        assert_includes html, %(class="attachments")
        assert_includes html, %(data-lightbox="#{image[:url]}")
        assert_includes html, %(download="desain.png")
      end

      # A document is not drawn into a sheet: the card is a link out to the
      # browser's own viewer, with the format written on it and the same
      # download beside it that a picture carries.
      def test_a_document_the_agent_sent_is_drawn_as_a_card
        document = { url: "/s/web_kanyaah/media/laporan.pdf?token=t0k", name: "laporan.pdf",
                     id: "c" * 32, kind: :document, label: "PDF" }

        html = View.render("_timeline", items: [ { kind: :attachments, list: [ document ] } ])

        assert_includes html, %(class="attachment-document")
        assert_includes html, %(href="#{document[:url]}")
        assert_includes html, %(target="_blank")
        assert_includes html, %(rel="noopener")
        assert_includes html, %(<span class="attachment-label" aria-hidden="true">PDF</span>)
        assert_includes html, %(<span class="attachment-name">laporan.pdf</span>)
        assert_includes html, %(download="laporan.pdf")
        refute_includes html, "data-lightbox", "a PDF is not opened into the sheet"
        assert_includes html, %(id="file-#{"c" * 32}"), "a card is kept across a redraw too"
      end

      # A running turn redraws the whole timeline on every event. A picture
      # given a stable id and hx-preserve keeps the node it already has, so it
      # is not fetched and decoded again under a growing answer — which is what
      # made a strip of them blink.
      def test_a_picture_keeps_its_node_when_the_timeline_is_redrawn
        first = { url: "/s/web_kanyaah/media/#{"a" * 32}-satu.png", name: "satu.png", id: "a" * 32 }
        second = { url: "/s/web_kanyaah/media/#{"b" * 32}-dua.png", name: "dua.png", id: "b" * 32 }

        html = View.render("_timeline", items: [ { kind: :attachments, list: [ first, second ] } ])

        assert_equal 2, html.scan(/hx-preserve="true"/).size,
                     "every picture asks to be kept across a redraw"
        assert_includes html, %(id="picture-#{"a" * 32}")
        assert_includes html, %(id="picture-#{"b" * 32}"),
                        "two pictures must not answer to the same id"
      end

      # A caller that names no id — an older session file, or a bare partial in
      # a test — must still render: there is simply nothing to preserve by.
      def test_a_picture_without_an_id_is_drawn_without_a_preserve_marker
        image = { url: "/s/web_kanyaah/media/x.png", name: "x.png" }

        html = View.render("_attachments", attachments: [ image ])

        refute_includes html, "hx-preserve"
        assert_includes html, %(class="attachment")
      end

      # The transcript holds the call and its result; drawn back, the picture is
      # there again — the row first, the picture under it.
      def test_history_draws_a_picture_the_agent_sent
        sid = "web_kanyaah"
        stored = "f" * 32 + "-desain.png"
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { sid => "Buatkan gambar" }
        )
        write_messages(channel, sid, [
          { "role" => "user", "content" => "Buatkan gambar" },
          { "role" => "assistant", "content" => "Ini gambarnya.",
            "tool_calls" => [ { "id" => "call_1",
                                "function" => { "name" => "send_file",
                                                "arguments" => JSON.generate({ "path" => "desain.png" }) } } ] },
          { "role" => "tool", "tool_call_id" => "call_1",
            "content" => "Sent desain.png (12 bytes) as a picture. [web-attachment #{stored}]" }
        ])

        items = channel.send(:history, sid).last[:items]

        assert_equal %i[tool attachments], items.last(2).map { |item| item[:kind] }
        assert_includes items.last[:list].first[:url], "/s/#{sid}/media/#{stored}"
        assert_equal :picture, items.last[:list].first[:kind]
      end

      # A PDF read back from a week-old transcript comes back as a card: the
      # word the tool result used is the only thing that has to survive.
      def test_history_draws_a_document_the_agent_sent
        sid = "web_kanyaah"
        stored = "f" * 32 + "-laporan.pdf"
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { sid => "Buat laporan" }
        )
        write_messages(channel, sid, [
          { "role" => "user", "content" => "Buat laporan" },
          { "role" => "assistant", "content" => "Ini laporannya.",
            "tool_calls" => [ { "id" => "call_1",
                                "function" => { "name" => "send_file",
                                                "arguments" => JSON.generate({ "path" => "laporan.pdf" }) } } ] },
          { "role" => "tool", "tool_call_id" => "call_1",
            "content" => "Sent laporan.pdf (12 bytes) as a document. [web-attachment #{stored}]" }
        ])

        document = channel.send(:history, sid).last[:items].last[:list].first

        assert_equal :document, document[:kind]
        assert_equal "PDF", document[:label]
        assert_equal "laporan.pdf", document[:name]
      end

      # The prompt is what the reader typed, and nothing else: pictures from the
      # composer are not part of this channel yet.
      def test_a_prompt_is_drawn_as_text_only
        html = View.render("_message", role: "user", text: "Halo")

        assert_includes html, %(class="msg user")
        refute_includes html, %(class="attachments")
        assert_includes html, "Halo"
      end

      # The composer is text and one button: no file picker, no drop target.
      def test_the_composer_carries_no_picture_input
        html = View.render("_composer", session_id: "web_rubot", token_query: "?token=t0k")

        refute_includes html, %(type="file")
        refute_includes html, "data-upload"
        refute_includes html, %(name="images")

        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))
        refute_includes js, "async attach(files)"
        refute_includes js, "X-Filename"
      end

      # One sheet per page, not one per picture. A thread can hold a hundred
      # images; the lightbox is filled in when one of them is pressed.
      def test_the_page_carries_one_lightbox
        html = View.render("index",
                           personas: [], groups: { pinned: [], recent: [], page: 1, pages: 1, recent_total: 0, pinned_limit: 10, current: "web_rubot" },
                           slug: "rubot", persona_label: "Rubot", persona_emoji: "🤖",
                           persona_prompt: "",
                           persona_model: "m", session_id: "web_rubot",
                    persona_model_value: "", model_choices: [],
                    session_model: "", session_thinking: "medium", session_requests: 3, persona_thinking: "medium",
                           session_short: "web_rubot", session_label: "Sesi baru",
                           document_title: "rubot · Rubot", live_turn: nil, token_query: "",
                           page: { entries: [], more: false, before: 0 }, older_url: "",
                           usage: { cost: "—", cache: "—", ctx: "—", cause: "" },
                           usage_facts: { model: "m", cost: "—", breakdown: "", requests: "0",
                                          messages: "0", tokens_in: "0", tokens_out: "0",
                                          reasoning: "", cache: "—",
                                          cache_history: "", cache_cause: "", re_read: "0", saved: "", ctx: "—" })

        assert_equal 1, html.scan(%(id="lightbox")).size
        assert_match(/id="lightbox"[^>]*hidden/, html)
        assert_includes html, 'class="btn lightbox-download"'

        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))
        assert_includes js, "function openLightbox", "the sheet has to be able to open"
        assert_includes js, %(event.target.closest("[data-lightbox]")),
                        "the handler is delegated: the thread is rewritten by htmx"
      end

      # An image written in markdown is the same affordance as an attachment.
      def test_a_markdown_image_can_be_opened_and_downloaded
        html = Format.markdown("![papan](/img/a.png)")

        assert_includes html, %(<img src="/img/a.png" alt="papan")
        assert_includes html, %(data-lightbox="/img/a.png")
        assert_includes html, %(download="papan")
      end

      # A prompt is text; anything else is not a prompt this channel can carry.
      def test_a_turn_with_no_text_is_refused
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        res = FakeResponse.new
        channel.send(:create_turn, turn_request("   "), res, "web_kanyaah")

        assert_equal 400, res.status
        assert_includes res.body, "Pesan kosong"
      end

      # "Still working" sits between the conversation and the field, so the room
      # above it is the band's own margin plus the thread's bottom padding, and
      # the room below it is the margin under the band. Both must read the same,
      # or the row looks glued to the last thing the turn said. Measured in a
      # browser: 0.15rem + 0.6rem above, 0.75rem below.
      def test_the_working_row_has_the_same_room_above_and_below
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        band = css[/^\.working-band \{[^}]*\}/]
        thread = css[/^\.thread \{[^}]*\}/]

        refute_nil band, "the .working-band rule is missing from app.css"
        refute_nil thread, "the .thread rule is missing from app.css"

        margin = band[/margin: ([^;]+);/, 1]
        refute_nil margin, "the band needs a margin shorthand so both gaps are visible"
        top, _sides, bottom = margin.split
        padding = thread[/padding: ([^;]+);/, 1].to_s.split

        assert_equal "0.75rem", bottom, "the room under the row is the composer's 0.75rem"
        assert_in_delta 0.75, rem(top) + rem(padding[2] || padding[0]), 0.001,
                        "the room above the row is the band's margin plus the thread's own padding"
      end

      # The header does not stick, so any scroll outside the thread takes it off
      # the screen and it never comes back on its own. On a phone two things do
      # exactly that: the momentum at the end of the conversation chains into the
      # document, and the browser's toolbar collapsing grows `dvh` past the body.
      # Neither can happen once the page itself cannot scroll.
      def test_the_page_itself_cannot_scroll
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        shell = css[/^html, body \{[^}]*\}/]
        thread = css[/^\.thread \{[^}]*\}/]

        refute_nil shell, "the html, body rule is missing from app.css"
        assert_match(/overflow: hidden;/, shell, "the document must not be a scroller")
        assert_match(/overscroll-behavior: none;/, shell, "and pull-to-refresh must not reload a running turn")
        assert_match(/overscroll-behavior-y: contain;/, thread,
                     "the momentum at the end of the thread stops at the thread")
      end

      # A phone's keys do not resize the layout viewport on every browser, and the
      # page cannot scroll to reveal the field any more — it is a page that never
      # scrolls, on purpose. So the shell ends where the keys begin: the browser
      # is asked to resize the layout viewport where it can, and app.js mirrors
      # the visible height into `--vvh` where it cannot.
      def test_the_field_climbs_above_the_keyboard
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))
        layout = File.read(File.expand_path("../lib/rubot/web/views/layout.erb", __dir__))

        assert_includes layout, "interactive-widget=resizes-content"
        assert_match(/height: var\(--vvh, 100dvh\);/, css[/^\.app \{[^}]*\}/],
                     "the shell has to take its height from the visible box")
        assert_includes js, "visualViewport"
        assert_includes js, "--vvh"
        assert_includes js, "view.scale > 1.01",
                        "a pinch-zoom shrinks the visual viewport too, and the shell must not follow it"
      end

      # `dvh` is a dynamic unit, and a browser is free to publish it before it
      # has settled the things that make it dynamic. Installed as an app it did:
      # opening a session laid the shell out at the height of a window that was
      # no longer there, and the field and the figures under it fell past the
      # bottom edge until the browser recounted — which touching the field did.
      # So the height is measured, always, and measured again once the browser
      # has had a paint to settle.
      def test_the_shell_measures_itself_rather_than_trusting_dvh
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "function fitToViewport"
        assert_includes js, 'window.addEventListener("pageshow", fitToViewport)',
                        "a page back out of the cache was laid out for another window"
        assert_includes js, "requestAnimationFrame(fitToViewport)",
                        "a toolbar still moving at `load` reports its old height"
        refute_match(/KEYBOARD_SLACK/, js,
                     "a threshold is what let a viewport the shell had outgrown stand uncorrected")
      end

      # A phone keeps the browser's hover state on whatever was tapped last, so a
      # hover rule is a *stuck* rule there: the send button stayed filled green
      # until something else was touched, which read as a message still going.
      # Hover belongs to a pointer that can leave the button; the press is what a
      # finger gets instead.
      def test_the_send_button_does_not_stay_filled_after_a_tap
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        hover = css[/@media \(hover: hover\) \{\n(.*?)\n\}/m, 1]

        refute_nil hover, "the buttons' hover needs a pointer that can leave"
        assert_includes hover, ".btn.primary:hover"
        assert_includes hover, ".composer-stop:hover"

        elsewhere = css.sub(hover, "")
        refute_includes elsewhere, ".btn.primary:hover",
                        "a hover outside the query sticks to a tapped button"
        refute_includes elsewhere, ".composer-stop:hover"
        assert_includes elsewhere, ".btn.primary:active",
                        "the press has to answer on a screen with no hover"
      end

      def rem(value)
        value.to_s.delete("rem").to_f
      end

      # The page is drawn under the home indicator (`viewport-fit=cover`), so the
      # last row and the field sat inside that strip on a phone: the field ended
      # at the very edge of the screen, where a thumb rests. The inset belongs to
      # the column that holds them, and it is zero everywhere else.
      def test_a_phone_with_a_home_indicator_keeps_the_field_out_of_it
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        chat = css[/^\.chat \{[^}]*\}/]

        refute_nil chat, "the .chat rule is missing from app.css"
        assert_match(/padding-bottom: var\(--safe-bottom, env\(safe-area-inset-bottom, 0px\)\);/,
                     chat, "the bottom of the column has to clear the indicator")
        assert_match(/box-sizing: border-box/, css,
                     "the inset is only free if the height includes it")
      end

      # "Thinking…" and "Thought for 12s" are pauses in the work, and a pause
      # needs air on both sides: with no top margin the row sat hard against
      # the text above it, which made it look like the end of that sentence.
      def test_the_thinking_rows_have_room_above_and_below
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        rule = css[/^\.row\.thinking \{[^}]*\}/]

        refute_nil rule, "the .row.thinking rule is missing from app.css"

        margin = rule.match(/margin:\s*([\d.]+)rem\s+0\s+([\d.]+)rem/)

        refute_nil margin, "the thinking row needs a margin shorthand with a top value"
        assert_operator margin[1].to_f, :>, 0, "a thought needs room above it"
        assert_operator margin[2].to_f, :>, 0, "and room below it"
      end

      # A ring typed as a glyph sits on the baseline, and its size comes from
      # whichever font on the reader's machine happens to carry U+25CC — so
      # beside "Thinking…" it was never the same twice, and on the machine that
      # reported it, never centred. The rows that turn are drawn for that reason,
      # and so is the mark on an open call. The thought keeps the half disc: it
      # is a state rather than a rotation, and a rotation that does not rotate is
      # the worse of the two. The finished states keep ✓ and ✗, which sit on the
      # baseline in every mono face.
      def test_the_marks_that_turn_are_drawn
        thinking = View.render("_timeline",
                               items: [ { kind: :thinking, epoch: 1.0, started_at: 0.0,
                                          closed_at: nil, elapsed: nil } ])
        working = View.render("_working", since: 1.0)
        running = View.render("_timeline",
                              items: [ { kind: :tool, name: "shell", detail: "ls",
                                         state: :running, epoch: 2.0, elapsed: 1.0 } ])
        done = View.render("_timeline",
                           items: [ { kind: :tool, name: "shell", detail: "ls",
                                      state: :ok, elapsed: 0.4 } ])

        assert_includes working, "mark-svg"
        assert_includes running, "mark-svg"
        refute_includes thinking, "◌", "the ring is no longer a borrowed glyph"
        assert_includes thinking, "◐", "the half disc is a state, and keeps its shape"
        assert_includes done, "✓", "a finished state keeps its glyph"
      end

      # The live thought glows one letter at a time, so the word is drawn as one
      # span per letter carrying its own index. "Thought for 12s" is a fact
      # about the past, not a wait, and keeps a plain label.
      def test_the_live_thought_glows_one_letter_at_a_time
        thinking = View.render("_timeline",
                               items: [ { kind: :thinking, epoch: 1.0, started_at: 0.0,
                                          closed_at: nil, elapsed: nil } ])
        thought = View.render("_timeline",
                              items: [ { kind: :thinking, epoch: 1.0, started_at: 0.0,
                                         closed_at: 4.0, elapsed: 12.0 } ])

        assert_includes thinking, %(class="label glow")
        assert_equal 9, thinking.scan(/<span style="--i:\d+">/).size,
                     "one span per letter of \"Thinking…\""
        assert_includes thinking, %(<span style="--i:8">…</span>)
        assert_includes thinking, %(aria-label="Thinking…"),
                        "a screen reader should read the word, not the letters"

        refute_includes thought, "label glow"
      end

      # Motion belongs only where a redraw cannot restart it. The timeline is
      # rewritten on every chunk of an answer — twenty times a second — and a
      # redraw begins every animation in it again, so a thought is the row that
      # can carry one: it is drawn when the wait starts and nothing redraws it
      # until tokens arrive, which is when it is replaced anyway.
      def test_the_glow_travels_across_the_word
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        assert_match(/@keyframes label-glow/, css, "the glow keyframes are missing")
        assert_match(/\.row \.label\.glow span \{[^}]*animation: label-glow/, css)
        assert_match(/animation-delay: calc\(var\(--i/, css, "each letter needs its own phase")
      end

      # A row gets one thing that moves. An open call already has the turning
      # ring on its left, so the sweep that crossed the row was taken back out —
      # two motions saying "still running" sixteen pixels apart is one too many.
      def test_an_open_call_moves_once
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        running = View.render("_timeline",
                              items: [ { kind: :tool, name: "shell", detail: "ls",
                                         state: :running, epoch: 2.0, elapsed: 1.0 } ])

        assert_includes running, "mark-svg spin", "the ring is the row's motion"
        refute_match(/@keyframes tool-sweep/, css, "the sweep is gone")
        refute_match(/\.tool-row\.running::after/, css)
      end

      # The thought wears the half disc and keeps it still: a shape that means
      # "this is happening" does not have to turn, and a drawn ring that is not
      # turning reads as a spinner that stopped. The glow is the thing that
      # moves on this row. The marks that do turn are the ones being turned —
      # the turn that is running, and a call that is open.
      def test_the_thought_keeps_a_still_mark_while_the_word_glows
        thinking = View.render("_timeline",
                               items: [ { kind: :thinking, epoch: 1.0, started_at: 0.0,
                                          closed_at: nil, elapsed: nil } ])
        working = View.render("_working", since: 1.0)
        running = View.render("_timeline",
                              items: [ { kind: :tool, name: "shell", detail: "ls",
                                         state: :running, epoch: 2.0, elapsed: 1.0 } ])
        thought = View.render("_timeline",
                              items: [ { kind: :thinking, epoch: 1.0, started_at: 0.0,
                                         closed_at: 4.0, elapsed: 12.0 } ])

        assert_includes thinking, "◐"
        refute_includes thinking, "spin", "the mark is a state, not a rotation"
        assert_includes thinking, "label glow", "the word is what moves here"
        assert_includes working, "mark-svg spin"
        assert_includes running, "mark-svg spin", "a call that is open is turning"
        assert_includes thought, "Thought for 12s"
        refute_includes thought, "spin", "a finished thought must not keep turning"
      end

      # Spinning a full ring would look exactly like a still ring, so a mark that
      # turns is an arc: the gap is what the eye reads as motion. The thought no
      # longer has one — it wears the half disc and keeps still — so the arc is
      # checked where it is still used: the turn that is running.
      def test_a_mark_that_turns_is_an_arc
        working = View.render("_working", since: 1.0)
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        assert_includes working, "stroke-dasharray", "a full ring cannot show that it turns"
        assert_match(/@keyframes mark-spin/, css, "the spin keyframes are missing")
        assert_match(/\.mark \.mark-svg\.spin \{[^}]*animation: mark-spin/,
                     css, "the live marks have to be the ones that turn")
      end

      # Centring is the box's job: the mark has no baseline to sit on, so the
      # row centres it instead, and a square box means the drawing's own centre
      # is the box's centre. Without the square, a wider mark would drift.
      def test_the_round_marks_are_centred_by_a_square_box
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        row = css[/^\.row \{[^}]*\}/m]
        refute_nil row, "the .row rule is missing from app.css"
        assert_includes row, "align-items: center"

        mark = css[/^\.row \.mark \{[^}]*\}/m]
        refute_nil mark, "the .row .mark rule is missing from app.css"
        assert_includes mark, "width: 0.8em"
        assert_includes mark, "height: 0.8em"
      end

      def turn_request(message)
        Struct.new(:query, :query_string) do
          def content_type = "application/x-www-form-urlencoded"
          def body = ""
          def [](_key) = nil
        end.new({ "message" => message }, "")
      end

      # A picture already in the conversation's folder, named the way the
      # channel names what it serves.
      # A file in a conversation's folder, named the way the channel writes
      # names: an id in front, the reader's own name behind it.
      # --- search ---------------------------------------------------------

      # Search is a dialog in the middle of the screen, not a field in the
      # sidebar: a hit is a place in another conversation, and its sentence
      # needs the width of the page to be worth reading. The dialog is drawn
      # once per page and opened from the button beside "+ Sesi baru".
      def test_the_page_carries_the_search_dialog_and_its_way_in
        html = render_page

        assert_includes html, %(<dialog id="search-dialog")
        assert_includes html, %(hx-get="/search")
        assert_includes html, %(data-search-open)
        assert_includes html, %(data-search-close)
        refute_includes html, "side-search", "no field left in the sidebar"
      end

      # On a phone the button that opens the dialog is inside the drawer, and a
      # panel left open behind a modal reappears the moment the dialog closes —
      # looking like the dialog had not been dismissed. The page closes it when
      # search opens, whichever way it was opened.
      def test_opening_search_shuts_the_mobile_drawer
        html = render_page

        assert_includes html, %(@rubot:search.window="nav = false")
      end

      # The button draws its own magnifier. An emoji is whatever picture the
      # system font carries, so it would change shape and weight per machine
      # beside a row that is otherwise identical everywhere.
      def test_the_search_button_wears_a_drawn_magnifier
        html = render_page
        button = html[/<button class="search-open".*?<\/button>/m]

        refute_nil button
        assert_includes button, %(<svg class="search-icon")
        assert_includes button, %(aria-hidden="true"), "a drawing must not be read out"
        refute_includes button, "🔍"
      end

      # The dialog opens empty. An answer to a query nobody can see any more is
      # a list of strangers, so the pane starts as the hint and app.js puts it
      # back on close.
      def test_the_search_dialog_opens_with_the_hint
        html = render_page

        assert_includes html, %(<p class="search-hint">Cari di seluruh percakapan)
      end

      # The sidebar lists forty conversations and the page draws twenty entries
      # of one of them. The archive is the only place that can answer "where did
      # we talk about this", so the answer names the conversation and the
      # message inside it.
      def test_search_answers_with_the_conversation_and_the_message
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah", "emoji" => "🧭" } },
          messages: { "web_kanyaah" => [ [ "user", "kenapa cache hit anjlok?" ],
                                         [ "assistant", "Karena prefix-nya bergeser." ] ] }
        )

        groups = channel.send(:search_groups, "cache")
        hit = groups.values.flatten.first

        assert_equal [ "web_kanyaah" ], groups.keys
        assert_equal "🧭", hit[:emoji]
        assert_equal "kamu", hit[:who]
        assert_includes hit[:html], "<mark>cache</mark>"
        # The link asks the page to land on that message. No fragment: a turn
        # wraps several messages, so the index names the place and the page
        # marks the entry that holds it (see #history_page).
        assert_equal "/s/web_kanyaah?at=0", hit[:href]
      end

      # The archive is shared by every channel, and a Telegram chat has no page
      # in this one. A hit the reader cannot open is a dead link, not a result.
      def test_search_leaves_out_a_conversation_this_channel_cannot_open
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ [ "user", "cache hit turun" ] ],
                      "tg_12345" => [ [ "user", "cache hit juga di sini" ] ] }
        )

        assert_equal [ "web_kanyaah" ], channel.send(:search_groups, "cache").keys
      end

      def test_an_empty_query_asks_nothing_of_the_archive
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ [ "user", "halo" ] ] }
        )

        assert_empty channel.send(:search_groups, "   ")
      end

      # Opening a hit is a page that ends at the message, not the tail of the
      # conversation: the reader asked for a place, and the turns that led to it
      # are the page above.
      def test_a_hit_opens_the_page_that_ends_at_its_message
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => (1..30).flat_map do |i|
            [ [ "user", "pesan #{i}" ], [ "assistant", "balasan #{i}" ] ]
          end }
        )

        page = channel.send(:history_page, "web_kanyaah", at: 41)

        # Message 41 is the answer to "pesan 21", so the turn drawn last is the
        # one the hit belongs to.
        assert_equal 41, page[:entries].last[:idx]
        assert_equal :turn, page[:entries].last[:kind]
        assert_same page[:entries].last, page[:landed]
        assert page[:more], "everything older is still a page away"
        assert_operator page[:entries].size, :<=, Rubot::Channels::Web::HISTORY_PAGE

        html = View.render("_history", entries: page[:entries], more: false, older_url: "",
                                      landed: page[:landed])
        assert_includes html, %(class="turn is-done is-landed" id="m-41")
      end

      # A turn wraps the whole round — the call, its result and the answer — so a
      # hit in the middle of one lands on the turn, not on the message that
      # happened to open it.
      def test_a_hit_inside_a_turn_lands_on_the_turn_that_holds_it
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_messages(channel, "web_kanyaah", [
          { "role" => "user", "content" => "cek file" },
          { "role" => "assistant", "content" => "", "tool_calls" => [
            { "id" => "c1", "type" => "function",
              "function" => { "name" => "grep", "arguments" => %({"pattern":"wanderer"}) } }
          ] },
          { "role" => "tool", "tool_call_id" => "c1", "content" => "wanderer ada di 12 tempat" },
          { "role" => "assistant", "content" => "Ketemu." }
        ])

        page = channel.send(:history_page, "web_kanyaah", at: 2)

        assert_equal 1, page[:landed][:idx], "the turn opens at the call"
        assert_equal 3, page[:landed][:last], "and reaches the answer"

        html = View.render("_history", entries: page[:entries], more: false, older_url: "",
                                      landed: page[:landed])
        assert_includes html, %(class="turn is-done is-landed" id="m-1")
      end

      # A prompt is an entry of its own, so a hit in the person's own words
      # lands on the bubble rather than on the answer below it.
      def test_a_prompt_hit_lands_on_the_bubble_it_quoted
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => (1..30).flat_map do |i|
            [ [ "user", "pesan #{i}" ], [ "assistant", "balasan #{i}" ] ]
          end }
        )

        page = channel.send(:history_page, "web_kanyaah", at: 40)

        assert_equal 40, page[:entries].last[:idx]
        assert_equal :prompt, page[:entries].last[:kind]

        html = View.render("_history", entries: page[:entries], more: false, older_url: "",
                                      landed: page[:landed])
        assert_includes html, %(class="msg user is-landed" id="m-40")
      end

      # A session trimmed since it was indexed no longer holds the message the
      # hit came from. Landing on the tail would be a page away from what was
      # asked for, so the nearest entry above the index is the place.
      def test_a_hit_whose_message_is_gone_lands_on_the_nearest_entry
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ [ "user", "satu" ], [ "assistant", "dua" ] ] }
        )

        page = channel.send(:history_page, "web_kanyaah", at: 500)

        assert_equal 1, page[:entries].last[:idx], "the last entry, not nothing"
        assert_same page[:entries].last, page[:landed]
        refute page[:more]
      end

      # Without `at` the page is still the tail: the landing parameter must not
      # change what opening a conversation normally does.
      def test_a_page_without_a_hit_is_still_the_tail
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => (1..30).flat_map do |i|
            [ [ "user", "pesan #{i}" ], [ "assistant", "balasan #{i}" ] ]
          end }
        )

        page = channel.send(:history_page, "web_kanyaah")

        assert_equal 59, page[:entries].last[:idx]
        assert_nil page[:landed]
        assert page[:more]
      end

      # The dialog asks this route on every pause in typing, and the answer is a
      # fragment swapped into the pane — never a page.
      def test_the_search_route_answers_a_fragment
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah", "emoji" => "🧭" } },
          messages: { "web_kanyaah" => [ [ "user", "kenapa cache hit anjlok?" ] ] }
        )
        res = FakeResponse.new

        channel.send(:dispatch, FakeRequest.new("/search", query: { "q" => "cache" }), res)

        assert_equal 200, res.status
        assert_includes res.body, %(class="search-group")
        assert_includes res.body, "Kanyaah · kenapa cache hit anjlok?"
        assert_includes res.body, %(href="/s/web_kanyaah?at=0")
      end

      def test_the_search_route_says_so_when_nothing_matches
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ [ "user", "halo" ] ] }
        )
        res = FakeResponse.new

        channel.send(:dispatch, FakeRequest.new("/search", query: { "q" => "zebra" }), res)

        assert_equal 200, res.status
        assert_includes res.body, "Tidak ada yang cocok"
      end

      # The link a hit writes is a page that already lands there: the entry is
      # marked by the server, so no script has to find the message afterwards.
      def test_a_session_opens_at_the_entry_a_hit_named
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => (1..30).flat_map do |i|
            [ [ "user", "pesan #{i}" ], [ "assistant", "balasan #{i}" ] ]
          end }
        )
        res = FakeResponse.new

        channel.send(:dispatch, FakeRequest.new("/s/web_kanyaah", query: { "at" => "41" }), res)

        assert_equal 200, res.status
        assert_includes res.body, %(class="turn is-done is-landed" id="m-41")
      end

      def test_an_index_that_is_not_a_number_is_ignored
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ [ "user", "satu" ], [ "assistant", "dua" ] ] }
        )
        res = FakeResponse.new

        channel.send(:dispatch, FakeRequest.new("/s/web_kanyaah", query: { "at" => "hapus" }), res)

        assert_equal 200, res.status
        assert_includes res.body, %(id="m-1"), "the tail, as if nothing was asked for"
        refute_includes res.body, "is-landed", "an unreadable index marks nothing"
      end

      def write_attachment(channel, sid, basename, body)
        name = "a" * 32 + "-#{File.basename(basename, File.extname(basename))}#{File.extname(basename)}"
        dir = channel.send(:attachments_dir, sid)
        FileUtils.mkdir_p(dir)
        File.binwrite(File.join(dir, name), body)
        name
      end

      def write_picture(channel, sid, basename = "shot.png")
        write_attachment(channel, sid, basename, png_bytes)
      end

      def write_messages(channel, sid, messages)
        dir = channel.instance_variable_get(:@app_config).sessions_dir
        File.write(File.join(dir, "#{sid}.json"),
                   JSON.generate({ "id" => sid, "updated_at" => Time.now.utc.iso8601,
                                   "messages" => messages }))
      end

      # A real PNG signature: the page serves only what it can draw, and a
      # made-up string would not prove the bytes came back unchanged.
      def png_bytes
        "\x89PNG\r\n\x1A\n".b + ("\x00".b * 64)
      end

      # The model and the thinking level are per-session choices under the
      # composer. A change is applied to the session's actor, and the answer
      # is the row again with the new choice already marked — a stale page
      # cannot drift from what the session really runs on.
      def test_session_settings_applies_the_choice_and_rerenders_the_row
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        # model-b is what the config runs on by default; model-a is the
        # change this test makes.
        channel.instance_variable_get(:@app_config).data["models"] =
          [{ "name" => "model-b", "model" => "openai/gpt-4o", "api_key" => "sk-test" },
           { "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" }]

        handle = Class.new do
          attr_reader :model, :thinking

          def use_model(name)
            @model = name
          end

          def use_thinking(level)
            @thinking = level
          end
        end.new
        channel.define_singleton_method(:session_for) { |_sid| handle }
        # No archive in this fixture, so the meta the row reads from is the
        # handle itself: what the actor applied is what the page shows.
        channel.define_singleton_method(:session_meta) do |_sid|
          { "model_override" => handle.model.to_s, "thinking_level" => handle.thinking.to_s }
        end

        res = FakeResponse.new
        channel.send(:update_session_settings, res, "web_kanyaah",
                     form_post({ "model" => "model-a", "thinking" => "low" }))

        assert_equal 200, res.status
        assert_equal "model-a", handle.model
        assert_equal "low", handle.thinking
        assert_includes res.body, 'value="model-a" selected'
        assert_includes res.body, 'value="low" selected'
      end

      # A picker change rewrites the prompt, so it costs a re-read of the whole
      # prefix. Saying so before the change turns a surprising number in the
      # usage panel into an expected one.
      def test_the_picker_warns_that_a_change_costs_a_re_read
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        channel.define_singleton_method(:session_meta) { |_sid| { "usage" => { "requests" => 12 } } }

        html = Rubot::Web::View.render("_session_settings",
                                       session_id: "web_kanyaah", token_query: "",
                                       model_choices: [ { value: "m", label: "m" } ],
                                       session_model: "m", session_thinking: "medium",
                                       session_requests: channel.send(:session_requests, "web_kanyaah"))

        assert_includes html, "session-setting-hint"
        assert_includes html, "prefix dibaca ulang"
      end

      # A session that has not sent a request has no prefix to lose.
      def test_the_picker_says_nothing_on_a_session_without_requests
        html = Rubot::Web::View.render("_session_settings",
                                       session_id: "web_kanyaah", token_query: "",
                                       model_choices: [ { value: "m", label: "m" } ],
                                       session_model: "m", session_thinking: "medium",
                                       session_requests: 0)

        refute_includes html, "session-setting-hint"
      end

      # The pickers offer real choices only, so a hand-crafted post carrying
      # something else must not get past them: an unknown model is dropped
      # rather than pinned, and an empty level leaves the persona's default
      # alone instead of inventing one.
      def test_session_settings_ignores_an_unknown_model_and_an_empty_level
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })

        handle = Class.new do
          attr_reader :model, :thinking

          def use_model(name)
            @model = name
          end

          def use_thinking(level)
            @thinking = level
          end
        end.new
        channel.define_singleton_method(:session_for) { |_sid| handle }
        channel.define_singleton_method(:session_meta) { |_sid| {} }

        res = FakeResponse.new
        channel.send(:update_session_settings, res, "web_kanyaah",
                     form_post({ "model" => "made-up-model", "thinking" => "" }))

        assert_equal 200, res.status
        assert_nil handle.model, "an unknown model is never applied"
        assert_nil handle.thinking, "an empty level leaves the persona's default alone"
        assert_includes res.body, 'value="medium" selected', "the row marks the level it runs on"
        refute_includes res.body, "ikut default"
        refute_includes res.body, 'value="" selected'
      end

      # The persona owns the defaults, so a session that has chosen nothing
      # shows the persona's own choices rather than a "default" entry.
      def test_the_session_row_starts_on_the_persona_defaults
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah", "model" => "model-a",
                                     "thinking" => "high" } }
        )
        channel.instance_variable_get(:@app_config).data["models"] =
          [{ "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" },
           { "name" => "model-b", "model" => "openai/gpt-4o", "api_key" => "sk-test" }]

        res = FakeResponse.new
        channel.send(:render_session, res, "web_kanyaah", FakeRequest.new("/s/web_kanyaah"))

        assert_equal 200, res.status
        assert_includes res.body, 'value="model-a" selected'
        assert_includes res.body, 'value="high" selected'
        refute_includes res.body, "ikut default"
      end

      # A turn owns the actor between rounds, so a settings change is refused
      # the same way a rename is: with a bare 409, not a half-applied row.
      def test_session_settings_is_refused_while_a_turn_is_running
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        turn = Turn.new(id: "tabc", session_id: "web_kanyaah", prompt: "Halo")
        channel.instance_variable_get(:@turns)["tabc"] = turn
        channel.define_singleton_method(:session_running?) { |_sid| true }

        res = FakeResponse.new
        channel.send(:update_session_settings, res, "web_kanyaah",
                     form_post({ "model" => "model-a", "thinking" => "low" }))

        assert_equal 409, res.status
        assert_empty res.body
      end

      # A conversation that finished while its page was closed is marked in the
      # list; the mark must be visible without a reload, so it is drawn from the
      # row itself rather than added by a script afterwards.
      def test_a_session_row_carries_the_unread_dot
        html = View.render("_session_row",
                           row: { id: "web_rubot~x", label: "Sesi", pinned: false, pinnable: true,
                                  active: false, unread: true },
                           page: 1, current: "web_rubot~x", token_query: "")

        assert_includes html, "unread-dot"
        assert_includes html, "belum dibaca"
        assert_includes html, "is-unread"
      end

      def test_a_read_session_row_has_no_mark
        html = View.render("_session_row",
                           row: { id: "web_rubot~x", label: "Sesi", pinned: false, pinnable: true,
                                  active: false, unread: false },
                           page: 1, current: "web_rubot~x", token_query: "")

        refute_includes html, "unread-dot"
      end

      # The roster answers "which persona has something new"; nine and above are
      # drawn as "9+" so a two-digit count cannot spill out of the badge.
      def test_the_persona_rail_shows_a_count_and_caps_it
        html = View.render("index",
                           personas: [ { slug: "a", label: "A", emoji: "🤖", active: false, unread: 3, model: "m" },
                                       { slug: "b", label: "B", emoji: "🧭", active: false, unread: 12, model: "m" } ],
                           groups: { pinned: [], recent: [], page: 1, pages: 1, recent_total: 0, pinned_limit: 10, current: "web_a" },
                           slug: "a", persona_label: "A", persona_emoji: "🤖", persona_prompt: "",
                           persona_model: "m", session_id: "web_a", persona_model_value: "", model_choices: [],
                           session_model: "", session_thinking: "medium", session_requests: 0, persona_thinking: "medium",
                           session_short: "web_a", session_label: "Sesi baru",
                           document_title: "rubot · A", live_turn: nil, live_prompt_shown: false, token_query: "",
                           page: { entries: [], more: false, before: 0 }, older_url: "",
                           usage: { cost: "—", cache: "—", ctx: "—", cause: "" },
                           usage_facts: { model: "m · openai", cost: "—", breakdown: "", requests: "0",
                                          messages: "0", tokens_in: "0", tokens_out: "0", reasoning: "",
                                          cache: "—", cache_history: "", cache_cause: "", re_read: "0",
                                          saved: "", ctx: "—" })

        assert_includes html, ">3</span>"
        assert_includes html, "9+"
        assert_includes html, "3 percakapan belum dibaca"
      end

    end
  end
end
