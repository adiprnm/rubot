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

      def setup
        @fixtures = []
      end

      def teardown
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

      def test_a_thought_after_an_answer_seals_the_answer
        turn = build
        turn.append_chunk("awal")
        turn.thinking("lagi")

        assert_equal [ :text, :thinking ], kinds(turn)
        refute turn.items.first[:live]
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

        assert_includes prompt, %(class="bubble")
        assert_includes prompt, "pertanyaan"

        refute_includes history, "bubble"
        assert_includes history, %(class="text")
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
      def test_a_running_turn_says_it_is_working
        turn = build
        html = View.render("_turn", turn: turn, text: "hi", token_query: "")

        assert_includes html, "Working…"
        assert_includes html, %(data-since="#{turn.epoch}")
        assert_includes html, %(data-threshold="0")
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
      def test_the_working_row_lives_in_the_band_above_the_composer
        turn = build
        turn.tool_started("shell_exec", "ls")

        timeline = View.turn_body(turn)
        fragment = View.render("_turn", turn: turn, text: "hi", token_query: "")

        refute_includes timeline, "Working…",
                        "the timeline is a record of the work, not of the waiting"
        assert_includes fragment, 'id="working"',
                        "the turn fragment has to put the row in the band"
        assert_includes fragment, 'hx-swap-oob="true"',
                        "the band lives outside the thread, so the swap is out of band"
        assert timeline.index("shell_exec"), "the tool row is still the timeline's"
      end

      # The band is in the page from the first paint, empty: the row appears
      # inside it, so the thread never changes height the moment a turn starts.
      def test_the_page_carries_an_empty_band_for_the_working_row
        html = View.render("index",
                           personas: [], sessions: [],
                           slug: "rubot", persona_label: "Rubot", persona_emoji: "🤖",
                           persona_model: "m", session_id: "web_rubot",
                           session_short: "web_rubot", session_label: "Sesi baru",
                           document_title: "rubot · Rubot", live_turn: nil, token_query: "",
                           page: { entries: [], more: false, before: 0 }, older_url: "",
                           usage: { cost: "—", cache: "—", ctx: "—" })

        band = html[/<div id="working"[^>]*>.*?<\/div>/m]

        refute_nil band, "the page needs a place for the row to land"
        refute_includes band, "Working…", "the band starts empty"
        assert html.index('id="working"') < html.index('class="composer"'),
               "the band sits above the field, not in the thread"
      end

      # A clock that only ever climbs says how long the turn has run, which is
      # not what a reader watching a slow tool wants to know. Restarting it on
      # every call answers "how long has this step been quiet" — and a number
      # that visibly drops back to zero is how the page shows the turn is still
      # moving rather than stuck.
      def test_a_tool_call_restarts_the_working_clock
        epochs = [ 1000.0, 1012.0 ]
        turn = Turn.new(id: "t1", session_id: "s1", clock: FakeClock.new,
                        epoch_clock: -> { epochs.shift || 1012.0 })

        assert_equal 1000.0, turn.activity_epoch,
                     "before any work the clock counts from the prompt"

        turn.tool_started("shell_exec", "ls")

        assert_equal 1012.0, turn.activity_epoch, "the call restarts it"

        channel = Rubot::Channels::Web.new(channel_config: {})
        out = StringIO.new
        channel.send(:write_event, out, turn, :working, nil)
        body = out.string

        assert_includes body, "event: working"
        assert_includes body, %(data-since="1012.0")
        assert_includes body, 'hx-swap-oob="true"',
                        "the row is not in the timeline, so the swap is out of band"
      end

      # The signal has to be in the log, or the band would keep the clock the
      # first paint gave it and never restart.
      def test_a_tool_call_signals_the_working_row
        turn = build
        turn.tool_started("shell_exec", "ls")
        turn.finish("selesai")

        types = []
        turn.each_event { |type, _payload| types << type }

        assert_includes types, :working
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

      # One button, two jobs: it sends when the session is free and stops the
      # turn when it is not, in the same place under the same hand. The
      # paperclip beside it is a different job entirely, which is why the
      # primary button is what this looks for.
      def test_the_composer_has_one_button_that_stops_a_running_turn
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        buttons = html.scan(/<button\b.*?<\/button>/m)
        primary = buttons.find { |button| button.include?("btn primary") }

        refute_nil primary, "the composer needs its send/stop button"
        assert_equal 1, buttons.count { |button| button.include?("btn primary") },
                     "the composer should carry a single primary button"
        assert_includes primary, "sendOrStop()"
        assert_includes primary, "buttonLabel"
      end

      # Stopping is a request, not a fact: the turn keeps running until the
      # server has acted. The button has to say so and stop taking presses for
      # that round trip, or it looks untouched and a second press just repeats
      # the same request.
      def test_the_stop_button_says_it_is_stopping_and_locks_itself
        html = View.render("_composer", session_id: "web_rubot", token_query: "")
        button = html[/<button\b[^>]*class="btn primary".*?<\/button>/m]

        refute_nil button, "the primary button is the one that sends and stops"
        assert_includes button, "x-bind:disabled=\"stopping"
        assert_includes button, "is-stopping"

        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "Membatalkan…", "the button has to say what it is doing"
        assert_includes js, "this.stopping = true"
        assert_includes js, "if (this.stopping) return;",
                        "a second press while the first is in flight is a no-op"
      end

      # A prompt the server refuses keeps its text in the field and puts
      # nothing in the thread, so the reason has to be said next to the field.
      # Left unsaid, the reader presses a button that appears broken: the text
      # is still there, no bubble came out of it, and nothing explains why.
      def test_a_refused_prompt_has_a_place_to_say_why
        html = View.render("index",
                           personas: [], sessions: [],
                           slug: "rubot", persona_label: "Rubot", persona_emoji: "🤖",
                           persona_model: "m", session_id: "web_rubot",
                           session_short: "web_rubot", session_label: "Sesi baru",
                           document_title: "rubot · Rubot", live_turn: nil, token_query: "",
                           page: { entries: [], more: false, before: 0 }, older_url: "",
                           usage: { cost: "—", cache: "—", ctx: "—" })

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
        item = channel.send(:history_tool_item, messages[1]["tool_calls"].first, results)

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

        assert_equal :failed, channel.send(:history_tool_item, call, results)[:state]
      end

      # A call whose result never arrived is neither a success nor a failure:
      # the turn was stopped with the tool in flight.
      def test_history_marks_a_tool_without_a_result_as_unknown
        channel = Rubot::Channels::Web.new(channel_config: {})
        call = { "id" => "c1", "function" => { "name" => "shell_exec", "arguments" => "{}" } }

        assert_equal :unknown, channel.send(:history_tool_item, call, {})[:state]
      end

      def test_history_tolerates_arguments_that_are_not_json
        channel = Rubot::Channels::Web.new(channel_config: {})
        call = { "id" => "c1", "function" => { "name" => "shell_exec", "arguments" => "bukan json" } }

        assert_equal "", channel.send(:history_tool_item, call, {})[:detail]
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
        html = View.render("_usage", cost: "$0.023", cache: "99.6%", ctx: "2.5%")

        assert_equal 3, html.scan(%(<svg class="metric-icon")).size
        assert_includes html, "$0.023"
        assert_includes html, "99.6%"
        assert_includes html, "2.5%"
        assert_includes html, %(id="usage")

        # The label must live in the tooltip, not in the row.
        assert_includes html, "Biaya percakapan ini"
        refute_match(%r{class="value">cost}, html)
        refute_includes html, "cache 99"
      end

      # Each icon is a different drawing; a copy-paste slip would make two
      # figures indistinguishable at a glance.
      def test_each_usage_icon_draws_a_different_shape
        bodies = View::SVG_ICONS.values

        assert_equal 3, bodies.size
        assert_equal 3, bodies.uniq.size
        bodies.each { |body| assert_includes body, "<", "every icon needs at least one shape" }
      end

      # The out-of-band copy has to carry the marker, while the page's own copy
      # must not — otherwise the first swap would try to swap twice.
      def test_usage_markup_marks_the_fragment_as_out_of_band
        channel = Rubot::Channels::Web.new(channel_config: {})
        markup = channel.send(:usage_markup_with, { cost: "$0.1", cache: "50%", ctx: "1%" })

        assert_includes markup, %(hx-swap-oob="true")
        refute_includes View.render("_usage", cost: "$0.1", cache: "50%", ctx: "1%"), "hx-swap-oob"
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

      # --- assets ---------------------------------------------------------

      # Both files are served under one version, so the stamp has to move when
      # either of them does. It was the stylesheet's mtime, which left a
      # script change invisible to any browser that already had app.js cached.
      def test_the_asset_stamp_follows_the_newer_file
        channel = Rubot::Channels::Web.new(channel_config: {})
        assets = File.expand_path("../lib/rubot/web/assets", __dir__)
        newest = %w[app.css app.js].map { |name| File.mtime(File.join(assets, name)).to_i }.max

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
        assert_includes markup, %(<span class="session-name">Build gagal di CI</span>)
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

      def test_each_session_row_carries_a_way_to_delete_it
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Halo" }
        )
        rows = channel.send(:session_rows, "kanyaah", "web_kanyaah")

        html = View.render("_sessions", sessions: rows, token_query: "?token=t0k")

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

      # The id the server writes is its own: a hex name, the reader's file name
      # reduced to a slug, and a known extension — so a path typed by hand
      # cannot name a file, while the download still reads like a file name.
      def test_an_uploaded_picture_is_named_by_an_id_and_kept_per_session
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        res = FakeResponse.new

        channel.send(:upload_image, upload_request(png_bytes), res, "web_kanyaah")

        assert_equal 200, res.status
        payload = JSON.parse(res.body)
        assert_match(/\A[0-9a-f]{32}-shot\.png\z/, payload["id"])
        assert_equal "shot.png", payload["name"]
        assert_includes payload["url"], "/s/web_kanyaah/images/#{payload["id"]}"

        dir = channel.send(:images_dir, "web_kanyaah")
        assert File.file?(File.join(dir, payload["id"])), "the bytes have to land on disk"
        assert_equal png_bytes, File.binread(File.join(dir, payload["id"]))
      end

      # A file name can be anything at all; what lands on disk is a slug.
      def test_a_strange_file_name_is_reduced_to_a_slug
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        res = FakeResponse.new

        channel.send(:upload_image,
                     upload_request(png_bytes, name: "../../Desain Final (v2)!.PNG"),
                     res, "web_kanyaah")

        payload = JSON.parse(res.body)

        assert_match(/\A[0-9a-f]{32}-desain-final-v2\.png\z/, payload["id"])
        assert_equal "desain-final-v2.png", payload["name"]
      end

      # A declared type is only a claim. The bytes decide whether the file is
      # served back as an image.
      def test_an_upload_that_is_not_really_a_picture_is_refused
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        res = FakeResponse.new

        channel.send(:upload_image, upload_request("<html>hi</html>"), res, "web_kanyaah")

        assert_equal 415, res.status
        assert_empty Dir.glob(File.join(channel.send(:images_dir, "web_kanyaah").to_s, "*"))
      end

      def test_an_upload_of_an_unsupported_type_is_refused
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        res = FakeResponse.new

        channel.send(:upload_image, upload_request("GIF89a....", type: "image/tiff"), res, "web_kanyaah")

        assert_equal 415, res.status
        assert_includes res.body, "PNG"
      end

      # A picture belongs to a conversation. Resolving an id looks only inside
      # that conversation's own folder, so an id borrowed from another session
      # simply does not resolve.
      def test_a_picture_from_another_session_does_not_resolve
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Halo", "web_kanyaah~20261108-101010" => "Hai" }
        )

        res = FakeResponse.new
        channel.send(:upload_image, upload_request(png_bytes), res, "web_kanyaah")
        id = JSON.parse(res.body)["id"]

        assert_equal 1, channel.send(:resolve_images, "web_kanyaah", [ id ]).size
        assert_empty channel.send(:resolve_images, "web_kanyaah~20261108-101010", [ id ])
        assert_empty channel.send(:resolve_images, "web_kanyaah", [ "../../etc/passwd" ])
      end

      def test_a_picture_is_served_back_with_the_type_its_bytes_prove
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        upload = FakeResponse.new
        channel.send(:upload_image, upload_request(png_bytes), upload, "web_kanyaah")
        id = JSON.parse(upload.body)["id"]

        res = FakeResponse.new
        channel.send(:serve_image, res, "web_kanyaah", id)

        assert_equal 200, res.status
        assert_equal "image/png", res.headers["Content-Type"]
        assert_equal png_bytes, res.body
      end

      def test_a_picture_that_does_not_exist_is_not_found
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        res = FakeResponse.new

        channel.send(:serve_image, res, "web_kanyaah", "a" * 32 + ".png")

        assert_equal 404, res.status
      end

      # The note is what the model reads; the bubble is what the reader sees.
      # The note names the file and how big it is, exactly as the Telegram
      # channel says it.
      def test_the_prompt_tells_the_agent_where_the_picture_is
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        upload = FakeResponse.new
        channel.send(:upload_image, upload_request(png_bytes), upload, "web_kanyaah")
        images = channel.send(:resolve_images, "web_kanyaah", [ JSON.parse(upload.body)["id"] ])

        prompt = channel.send(:prompt_with_images, "Ini desainnya", images)

        assert prompt.start_with?("Ini desainnya")
        assert_includes prompt, "📎 User attached an image: #{images.first[:path]}"
        assert_includes prompt, images.first[:path]
      end

      # A session file holds the note because that is what the agent was
      # given. Drawn back, it becomes a picture again — and the paragraph the
      # reader typed stays a paragraph of its own.
      def test_history_turns_the_note_back_into_a_picture
        sid = "web_kanyaah"
        id = "b" * 32 + ".png"
        prompt = "Lihat ini\n\n📎 User attached an image: /tmp/x/#{id} (10×10, 1 KB)"
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { sid => prompt }
        )

        entry = channel.send(:history, sid).first

        assert_equal :prompt, entry[:kind]
        assert_equal "Lihat ini", entry[:text]
        assert_equal 1, entry[:images].size
        assert_includes entry[:images].first[:url], "/s/#{sid}/images/#{id}"
      end

      # The bubble: the pictures are a strip inside the message, and each one
      # is a button (open it larger) with a download beside it.
      def test_a_message_with_pictures_draws_a_strip_with_a_download
        image = { id: "c" * 32 + ".png", url: "/s/web_kanyaah/images/x.png", name: "shot.png" }

        html = View.render("_message", role: "user", text: "Halo", images: [ image ])

        assert_includes html, %(class="msg user has-attachments")
        assert_includes html, %(class="attachments")
        assert_includes html, %(data-lightbox="#{image[:url]}")
        assert_includes html, %(download="shot.png")
        assert_includes html, "Halo"
      end

      # A picture sent without a caption is a whole message: no empty bubble
      # text above it.
      def test_a_picture_without_text_is_a_message_of_its_own
        image = { id: "d" * 32 + ".png", url: "/s/web_kanyaah/images/y.png", name: "y.png" }

        html = View.render("_message", role: "user", text: "", images: [ image ])

        refute_includes html, %(class="bubble-text")
        assert_includes html, %(class="attachments")
      end

      # The composer uploads as soon as a file is chosen, and the form carries
      # the ids that came back — not bytes, and not a path.
      def test_the_composer_has_a_place_to_choose_pictures
        html = View.render("_composer", session_id: "web_rubot", token_query: "?token=t0k")

        assert_includes html, %(data-upload="/s/web_rubot/images?token=t0k")
        assert_includes html, %(type="file")
        assert_includes html, %(accept="image/*")
        assert_includes html, %(name="images")
        assert_includes html, "attachment-remove"

        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "async attach(files)"
        assert_includes js, "X-Filename"
        assert_includes js, "if (!text && this.images.length === 0) return;",
                        "a picture on its own is something to send"
        assert_includes js, "body.append(\"images\", image.id)",
                        "a picture sent mid-turn rides along with the steer"
      end

      # One sheet per page, not one per picture. A thread can hold a hundred
      # images; the lightbox is filled in when one of them is pressed.
      def test_the_page_carries_one_lightbox
        html = View.render("index",
                           personas: [], sessions: [],
                           slug: "rubot", persona_label: "Rubot", persona_emoji: "🤖",
                           persona_model: "m", session_id: "web_rubot",
                           session_short: "web_rubot", session_label: "Sesi baru",
                           document_title: "rubot · Rubot", live_turn: nil, token_query: "",
                           page: { entries: [], more: false, before: 0 }, older_url: "",
                           usage: { cost: "—", cache: "—", ctx: "—" })

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

      # "Still working" sits directly above the field, and at a quarter of a
      # rem the two rows read as one line of text. The gap belongs to the band,
      # not to the composer: the field's own spacing is already spoken for.
      # Sending a prompt with a picture draws the bubble from the turn, not from
      # the session file (which does not know about it yet), and hands the
      # agent a prompt that names the file it can open.
      def test_a_turn_with_a_picture_draws_it_and_tells_the_agent_where_it_is
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        upload = FakeResponse.new
        channel.send(:upload_image, upload_request(png_bytes), upload, "web_kanyaah")
        id = JSON.parse(upload.body)["id"]

        seen = nil
        channel.define_singleton_method(:run_turn) { |_turn, prompt| seen = prompt }
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }
        channel.define_singleton_method(:process_message) { |*| nil }

        res = FakeResponse.new
        channel.send(:create_turn, turn_request("Ini desainnya", [ id ]), res, "web_kanyaah")
        sleep 0.05

        assert_equal 200, res.status
        assert_includes res.body, %(class="msg user has-attachments")
        assert_includes res.body, %(data-lightbox="/s/web_kanyaah/images/#{id}")
        assert_includes res.body, "Ini desainnya"
        assert_includes seen.to_s, "📎 User attached an image:"
        assert_includes seen.to_s, id
      end

      # A picture on its own is a prompt: nothing typed, something sent.
      def test_a_turn_can_be_a_picture_with_no_text
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        upload = FakeResponse.new
        channel.send(:upload_image, upload_request(png_bytes), upload, "web_kanyaah")
        id = JSON.parse(upload.body)["id"]

        channel.define_singleton_method(:run_turn) { |*| }
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        res = FakeResponse.new
        channel.send(:create_turn, turn_request("", [ id ]), res, "web_kanyaah")

        assert_equal 200, res.status
        assert_includes res.body, "attachments"
        refute_includes res.body, %(class="bubble-text")
      end

      def test_a_turn_that_is_neither_text_nor_picture_is_refused
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        res = FakeResponse.new
        channel.send(:create_turn, turn_request("   ", []), res, "web_kanyaah")

        assert_equal 400, res.status
        assert_includes res.body, "Pesan kosong"
      end

      def test_the_working_row_has_room_under_it
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        rule = css[/^\.working-band \{[^}]*\}/]

        refute_nil rule, "the .working-band rule is missing from app.css"
        assert_match(/margin: 0 auto 0\.75rem;/, rule)
      end

      def upload_request(body, type: "image/png", name: "shot.png")
        headers = name ? { "x-filename" => URI.encode_www_form_component(name) } : {}

        Struct.new(:body, :content_type, :headers) do
          def [](key)
            headers[key.to_s]
          end
        end.new(body, type, headers)
      end

      # A form POST as WEBrick hands it over: repeated `images` fields arrive as
      # an array, which is what form_list reads.
      def turn_request(message, images)
        query = { "message" => message }
        query["images"] = images unless images.empty?

        Struct.new(:query, :query_string) do
          def content_type = "application/x-www-form-urlencoded"
          def body = ""
          def [](_key) = nil
        end.new(query, "")
      end

      # A real PNG signature: the upload is checked against the bytes, so a
      # made-up string would be refused before the test got anywhere.
      def png_bytes
        "\x89PNG\r\n\x1A\n".b + ("\x00".b * 64)
      end
    end
  end
end
