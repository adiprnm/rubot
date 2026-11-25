# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  module Web
    # The conversation's own chrome, read in both languages.
    #
    # Every test here renders the template that ships — through `View.render`,
    # with the same locals the channel passes — in English and then in
    # Indonesian, and asks two things of the pair: the two pages differ, and
    # each one is written in its own language only. A word left in place
    # (`Kirim` in an English page) is exactly the bug this file exists to catch,
    # and it shows up as an `assert_includes` on the wrong side of that pair.
    class TestWebI18n < Minitest::Test
      def teardown
        # The locale is process-wide, so a test that sets it hands it back:
        # another file in the same worker expects the English default.
        Rubot::I18n.locale = Rubot::I18n::DEFAULT_LOCALE
      end

      # --- the surfaces -----------------------------------------------------

      # The field a message is typed into, with both buttons that end a turn:
      # the send button says what a press does, and the stop button says what it
      # is doing, so both sentences have to move with the language.
      def test_the_composer_speaks_the_chosen_language
        html_en, html_id = both("_composer", session_id: "web_rubot", token_query: "?token=t")

        assert_includes html_en, 'placeholder="Write a message… Enter sends, Shift+Enter starts a new line"'
        assert_includes html_id, 'placeholder="Tulis pesan… Enter mengirim, Shift+Enter baris baru"'
        assert_includes html_en, 'aria-label="Send"'
        assert_includes html_id, 'aria-label="Kirim"'
        assert_includes html_en, 'aria-label="Message"'
        assert_includes html_id, 'aria-label="Pesan"'
        assert_includes html_en, 'aria-label="Remove the quote"'
        assert_includes html_id, 'aria-label="Hapus kutipan"'

        # The two expressions that used to carry their own Indonesian words:
        # the send button's tooltip still branches on state, and the stop
        # button's label is drawn from the same keys as the rest.
        assert_includes html_en, "x-bind:title=\"compacting ? 'Waiting for the compaction to finish' " \
                                 ": (busy ? 'Send as guidance to the running turn' : 'Send')\""
        assert_includes html_id, "x-bind:title=\"compacting ? 'Menunggu compaction selesai' " \
                                 ": (busy ? 'Kirim sebagai arahan ke turn yang berjalan' : 'Kirim')\""
        assert_includes html_en, "x-bind:aria-label=\"stopping ? 'Stopping…' : 'Stop'\""
        assert_includes html_id, "x-bind:aria-label=\"stopping ? 'Membatalkan…' : 'Batal'\""
      end

      # The header: the drawer's handle, the conversation's name and the way
      # back to the settings page.
      def test_the_chathead_speaks_the_chosen_language
        locals = { document_title: "rubot · kanyaah", persona_emoji: "🌱",
                   persona_label: "Kanyaah", session_label: "Nama sesi",
                   session_id: "web_rubot", token_query: "" }
        html_en, html_id = both("_chathead", **locals)

        assert_includes html_en, 'aria-label="Persona and conversations"'
        assert_includes html_id, 'aria-label="Persona dan sesi"'
        assert_includes html_en, 'title="Rename this conversation"'
        assert_includes html_id, 'title="Ubah nama sesi"'
        assert_includes html_en, 'aria-label="Rename this conversation: Nama sesi"'
        assert_includes html_id, 'aria-label="Ubah nama sesi: Nama sesi"'
        assert_includes html_en, 'aria-label="Save the name"'
        assert_includes html_id, 'aria-label="Simpan nama"'
        assert_includes html_en, 'title="Cancel"'
        assert_includes html_id, 'title="Batal"'

        # The settings link is the one word the two languages share with the
        # settings page itself: the same key, so the two can never disagree.
        assert_includes html_en, 'aria-label="settings"'
        assert_includes html_id, 'aria-label="pengaturan"'
      end

      def test_the_emoji_picker_speaks_the_chosen_language
        html_en, html_id = both("_emoji_picker", selected: "🌱", choices: %w[🌱 🤖])

        assert_includes html_en, "<legend>Emoji</legend>"
        assert_includes html_en, 'aria-label="Pick an emoji"'
        assert_includes html_id, 'aria-label="Pilih emoji"'
        assert_includes html_en, 'placeholder="Search emoji…"'
        assert_includes html_id, 'placeholder="Cari emoji…"'
        assert_includes html_en, 'aria-label="Another emoji"'
        assert_includes html_id, 'aria-label="Emoji lain"'
        assert_includes html_en, 'placeholder="Another emoji…"'
        assert_includes html_id, 'placeholder="Emoji lain…"'
      end

      # The card that asks before a dangerous action: the frame moves, the tool
      # name and the reason inside it are the turn's own words.
      def test_the_confirm_card_speaks_the_chosen_language
        locals = { prompt: { name: "rm -rf /tmp/x", reason: "deletes a directory" }, turn_id: 7 }
        html_en, html_id = both("_confirm", **locals)

        assert_includes html_en, "Confirm: rm -rf /tmp/x"
        assert_includes html_id, "Konfirmasi: rm -rf /tmp/x"
        assert_includes html_en, 'hx-swap="none">Continue</button>'
        assert_includes html_id, 'hx-swap="none">Lanjutkan</button>'
        assert_includes html_en, 'hx-swap="none">Cancel</button>'
        assert_includes html_id, 'hx-swap="none">Batalkan</button>'

        # The reason is the tool's, not the dictionary's: it is the same line in
        # both pages, which is what tells the two halves apart.
        [ html_en, html_id ].each { |html| assert_includes html, "deletes a directory" }
      end

      def test_the_search_dialog_speaks_the_chosen_language
        html_en, html_id = both("_search_dialog", token_query: "?token=t")

        assert_includes html_en, 'placeholder="Search every conversation…"'
        assert_includes html_id, 'placeholder="Cari di seluruh percakapan…"'
        assert_includes html_en, 'aria-label="Search conversations"'
        assert_includes html_id, 'aria-label="Cari percakapan"'
        assert_includes html_en, 'title="Close (esc)"'
        assert_includes html_id, 'title="Tutup (esc)"'
        assert_includes html_en, "including the ones no longer in the sidebar"
        assert_includes html_id, "termasuk yang sudah tidak ada di sidebar"

        # `esc` is the name of a key, not a word: it stays as it is in both.
        [ html_en, html_id ].each { |html| assert_includes html, ">esc</button>" }
      end

      # The sidebar: two lists, the count beside each, and the control that
      # continues the recent block. The conversation names belong to the
      # reader; the chrome around them belongs to the dictionary.
      def test_the_sessions_sidebar_speaks_the_chosen_language
        rows = {
          pinned: { id: "rubot~1", label: "Deep work", active: false, pinned: true,
                    unread: false, pinnable: true },
          recent: { id: "rubot~2", label: "Notes", active: true, pinned: false,
                    unread: false, pinnable: true }
        }
        groups = { pinned: [ rows[:pinned] ], pinned_limit: 8,
                   recent: [ rows[:recent] ], recent_total: 3,
                   more: true, page: 0, next_page: 1, current: "rubot~2" }
        html_en, html_id = both("_sessions", groups: groups, token_query: "?token=t")

        assert_includes html_en, ">Pinned<"
        assert_includes html_id, ">Di-pin<"
        assert_includes html_en, ">Recent<"
        assert_includes html_id, ">Terbaru<"
        assert_includes html_en, ">Load more<"
        assert_includes html_id, ">Muat lebih banyak<"
        assert_includes html_en, 'title="Unpin this session"'
        assert_includes html_id, 'title="Lepas pin"'
        assert_includes html_en, 'title="Pin this session"'
        assert_includes html_id, 'title="Pin sesi"'
        assert_includes html_en, "Delete this session? Its whole conversation goes with it."
        assert_includes html_id, "Hapus sesi ini? Seluruh percakapannya ikut hilang."

        # The names are the reader's, not the dictionary's: both pages hold them.
        [ html_en, html_id ].each do |html|
          assert_includes html, ">Deep work<"
          assert_includes html, ">Notes<"
        end
      end

      # The report behind the status row: its labels are words, its figures are
      # numbers, and only the labels move. The report is the channel's own, so
      # the lines it builds (the cost split, the cache share) are under test too.
      def test_the_usage_facts_speak_the_chosen_language
        html_en, html_id = both("_usage_facts") { usage_facts }

        assert_includes html_en, "<dt>cost</dt>"
        assert_includes html_id, "<dt>biaya</dt>"
        assert_includes html_en, "<dt>requests</dt>"
        assert_includes html_id, "<dt>permintaan</dt>"
        assert_includes html_en, "<dt>tokens</dt>"
        assert_includes html_id, "<dt>token</dt>"
        assert_includes html_en, "<dt>context</dt>"
        assert_includes html_id, "<dt>konteks</dt>"
        assert_includes html_en, "50.0% last request · 40.0% session average"
        assert_includes html_id, "50.0% permintaan terakhir · 40.0% rata-rata sesi"
        assert_includes html_en, "cache read"
        assert_includes html_id, "cache baca"

        # The figures are not words: the same numbers on both pages.
        [ html_en, html_id ].each { |html| assert_includes html, "12,000 / 128,000" }
      end

      # One report, built by the channel exactly as a real turn builds it, so a
      # sentence written inside the renderer cannot hide behind a test's stub.
      def usage_facts
        channel = Rubot::Channels::Web.new(channel_config: {})
        channel.usage_facts({
          model: "deepseek-v4.1-flash", provider: "openai", messages: 4, requests: 4,
          prompt_tokens: 4_000, completion_tokens: 40, cached_tokens: 900,
          cache_hit_rate: 0.5, cache_hit_rate_session: 0.4,
          context_used: 12_000, context_window: 128_000, context_percent: 9.4,
          cost: { "total" => 0.01, "input" => 0.002, "cached_input" => 0.0004,
                  "output" => 0.0002 }
        })
      end

      # The dialog under the composer: the model search, the effort chips, the
      # count and the button that saves both choices at once.
      def test_the_session_settings_dialog_speaks_the_chosen_language
        choices = [ { value: "deepseek-v4.1-flash", name: "DeepSeek Flash",
                      label: "deepseek/deepseek-v4.1-flash" } ]
        locals = { session_id: "web_rubot", token_query: "?token=t",
                   model_choices: choices, session_model: "deepseek-v4.1-flash",
                   session_thinking: "high" }
        html_en, html_id = both("_session_settings", **locals)

        assert_includes html_en, 'aria-label="Model and thinking level"'
        assert_includes html_id, 'aria-label="Model dan level thinking"'
        assert_includes html_en, 'placeholder="Search models…"'
        assert_includes html_id, 'placeholder="Cari model…"'
        assert_includes html_en, "1 models"
        assert_includes html_id, "1 model"
        assert_includes html_en, "No model matches."
        assert_includes html_id, "Tidak ada model yang cocok."
        assert_includes html_en, ">Save<"
        assert_includes html_id, ">Simpan<"
      end

      # The files the agent sent: the strip's own name, and the three actions a
      # card offers, one per kind.
      def test_the_attachment_strip_speaks_the_chosen_language
        files = [ { kind: :image, name: "shot.png", url: "/files/1", id: 1 },
                  { kind: :document, name: "notes.md", url: "/files/2", id: 2 },
                  { kind: :video, name: "clip.mp4", url: "/files/3", id: 3 } ]
        html_en, html_id = both("_attachments", attachments: files)

        assert_includes html_en, 'aria-label="Attachments from Rubot"'
        assert_includes html_id, 'aria-label="Lampiran dari Rubot"'
        assert_includes html_en, 'aria-label="Open shot.png"'
        assert_includes html_id, 'aria-label="Buka shot.png"'
        assert_includes html_en, 'aria-label="Play clip.mp4"'
        assert_includes html_id, 'aria-label="Putar clip.mp4"'
        assert_includes html_en, 'aria-label="Download notes.md"'
        assert_includes html_id, 'aria-label="Unduh notes.md"'
        assert_includes html_en, ">FILE<"
        assert_includes html_id, ">BERKAS<"
      end

      # The mark on the subagent toggle: how many runs are working, and the one
      # word that says how the last of them ended.
      def test_the_subagent_mark_speaks_the_chosen_language
        html_en, html_id = both("_subagent_state", subagents: [ { phase: "tool" } ])
        assert_includes html_en, 'aria-label="1 subagent running"'
        assert_includes html_id, 'aria-label="1 subagent berjalan"'

        failed = [ { phase: "failed", finished_at: Time.now } ]
        html_en, html_id = both("_subagent_state", subagents: failed)
        assert_includes html_en, 'title="subagent failed"'
        assert_includes html_id, 'title="subagent gagal"'
      end

      # The roster in the narrow column: the unread count is a sentence a
      # screen reader hears, so it moves with the language. The persona's name
      # is the reader's and stays put.
      def test_the_persona_rail_speaks_the_chosen_language
        personas = [ { slug: "a", label: "A", emoji: "🤖", active: true, unread: 3, model: "m" } ]
        html_en, html_id = both("_rail", personas: personas, token_query: "")

        assert_includes html_en, 'aria-label="A, 3 unread conversations"'
        assert_includes html_id, 'aria-label="A, 3 percakapan belum dibaca"'
      end

      # The allowance panel: the figure beside a meter, the window it measures,
      # and the sentence the channel writes when the provider has no allowance
      # to report. All three are built by the channel, so the locals are built
      # inside each render — a note assembled once before the switch would carry
      # one language into the page of the other.
      def test_the_quota_panel_speaks_the_chosen_language
        channel = Rubot::Channels::Web.new(channel_config: {})

        locals = lambda do
          { meters: channel.quota_meters({ "rolling" => { "percent" => 62.0,
                                                          "resets_at" => (Time.now + 3600).utc.iso8601 } }),
            note: channel.quota_note({ unavailable: true }) }
        end
        html_en, html_id = both("_quota", &locals)

        assert_includes html_en, "62.0% used"
        assert_includes html_id, "62.0% terpakai"
        assert_includes html_en, "5 hours"
        assert_includes html_id, "5 jam"
        assert_includes html_en, "resets in"
        assert_includes html_id, "reset dalam"
        assert_includes html_en, "This provider has no subscription allowance"
        assert_includes html_id, "Provider ini tidak punya kuota langganan"

        # A failure is a sentence too, and the error the provider gave stays
        # the provider's: it is the same line on both pages.
        failed = ->(locale) { Rubot::I18n.with_locale(locale) { channel.quota_note({ error: "HTTP 500" }) } }
        refute_equal failed.call("en"), failed.call("id")
        [ failed.call("en"), failed.call("id") ].each { |note| assert_includes note, "HTTP 500" }
      end

      # A conversation whose first prompt has not been saved has no name of its
      # own, so the sidebar writes one. It is read when the row is drawn, not
      # when the process booted, which is why the browser hands out a method
      # rather than only the constant the channel aliases.
      def test_an_untitled_conversation_is_named_in_the_chosen_language
        channel = Rubot::Channels::Web.new(channel_config: {})

        locals = lambda do
          row = { id: "web_rubot~1", label: channel.untitled_session, active: true,
                  pinned: false, unread: false, pinnable: false }
          { groups: { pinned: [], pinned_limit: 0, recent: [ row ], recent_total: 1,
                      more: false, page: 0, next_page: 1, current: "web_rubot~1" },
            token_query: "?token=t" }
        end
        html_en, html_id = both("_sessions", &locals)

        assert_includes html_en, ">New session<"
        assert_includes html_id, ">Sesi baru<"
        refute_includes html_en, "Sesi baru"
      end

      # The tooltip on each reading face on the settings page. The name of a
      # font reads the same in both languages; the sentence under it does not,
      # so it is a key, resolved each time the page draws its list — the list
      # `font_choices` hands the template, which is what is checked here.
      def test_the_font_tooltips_speak_the_chosen_language
        titles = lambda do |locale|
          Rubot::I18n.with_locale(locale) do
            View::Scope.new({}).font_choices.map { |choice| choice[:title] }
          end
        end
        en = titles.call("en")
        id = titles.call("id")

        refute_equal en, id, "the tooltips read the same in both languages"
        assert_equal Rubot::I18n::DICTIONARY["en"]["web"]["settings"]["appearance"]["font_titles"].values, en
        assert_equal Rubot::I18n::DICTIONARY["id"]["web"]["settings"]["appearance"]["font_titles"].values, id
        assert en.any? { |title| title.include?("Martian Mono") }, "the face a reader is choosing"

        leaked = en.flat_map { |title| title.downcase.scan(/[a-z]+/) } & INDONESIAN_CHROME
        assert_empty leaked, "an English tooltip still holds #{leaked.inspect}"
      end

      # The mark a rendered answer carries back to the field, and the pair on a
      # picture in it. The renderer draws the same page the thread draws, so a
      # label written inside it would reach the reader of either language.
      def test_the_markdown_marks_speak_the_chosen_language
        render = lambda do |locale|
          Rubot::I18n.with_locale(locale) do
            Format.markdown("Halo **dunia**.\n\n- satu\n- dua\n\n![gambar](https://x/y.png)",
                            quotable: true)
          end
        end
        html_en = render.call("en")
        html_id = render.call("id")

        refute_equal html_en, html_id, "the marks read the same in both languages"
        assert_includes html_en, %(aria-label="Quote this paragraph")
        assert_includes html_id, %(aria-label="Kutip paragraf ini")
        assert_includes html_en, %(data-quote-kind="List · 2 items")
        assert_includes html_id, %(data-quote-kind="Daftar · 2 butir")
        assert_includes html_en, %(aria-label="Open gambar")
        assert_includes html_id, %(aria-label="Buka gambar")
        assert_includes html_en, %(title="Download gambar")
        assert_includes html_id, %(title="Unduh gambar")

        # The picture's own name is the reader's, and the address is an address.
        [ html_en, html_id ].each do |html|
          assert_includes html, %(alt="gambar")
          assert_includes html, %(data-lightbox="https://x/y.png")
        end
      end

      # One more reading of the same pages, this time without a phrase to look
      # for: every word a reader or a screen reader can reach is collected, and
      # a handful of words that only Indonesian writes is looked for. A phrase
      # left in place by a template the tests above do not name shows up here.
      def test_an_english_page_holds_no_indonesian_chrome
        channel = Rubot::Channels::Web.new(channel_config: {})
        page = Rubot::I18n.with_locale("en") do
          [
            View.render("_composer", session_id: "web_rubot", token_query: ""),
            View.render("_session_settings", session_id: "web_rubot", token_query: "",
                        model_choices: [ { value: "m", name: "M", label: "m" } ],
                        session_model: "m", session_thinking: "high"),
            View.render("_usage_facts", **usage_facts),
            View.render("_attachments", attachments: [ { kind: :image, name: "a.png",
                                                         url: "/f", id: 1 } ]),
            View.render("_quota",
                        meters: channel.quota_meters({ "rolling" => { "percent" => 12.5 } }),
                        note: channel.quota_note({ unavailable: true })),
            View.render("_search_dialog", token_query: ""),
            View.render("_emoji_picker", selected: "🌱", choices: %w[🌱])
          ].join("\n")
        end

        leaked = visible_words(page) & INDONESIAN_CHROME
        assert_empty leaked, "an English page still holds #{leaked.inspect}"
      end

      # Words that belong to Indonesian chrome only. A page in English that
      # holds one of them has a phrase written in place instead of read from
      # the dictionary.
      INDONESIAN_CHROME = %w[
        semua pesan kirim simpan tutup batal pilih cari muat lampiran berkas
        pengaturan akun hubungkan pratinjau ringkas kuota percakapan sesi
        nama baru lanjut unduh putar buka permintaan rata masuk keluar
        diketahui berubah
      ].freeze

      # Every word a reader sees or hears: the text between tags, plus the
      # values of the attributes that are read out loud or shown as a tooltip.
      def visible_words(html)
        text = html.gsub(%r{<(script|style)\b[^>]*>.*?</\1>}m, "")
        spoken = text.scan(/(?:placeholder|title|aria-label|alt)="([^"]*)"/).flatten
        "#{text.gsub(/<[^>]*>/m, " ")} #{spoken.join(" ")}".downcase.scan(/[a-z]+/)
      end

      # --- the pair, checked the same way everywhere -----------------------

      # Every surface is read the same way: rendered twice, then compared. A
      # template that still holds a word in place renders the same page twice,
      # and the first assertion of the second half fails on the pair.
      #
      # Locals built by the caller (`usage_facts`) hold sentences the channel
      # writes while it builds them, so they are built inside each render: a
      # report assembled once before the switch would carry English into the
      # Indonesian page, which is the very leak the pair is here to catch.
      private

      def both(name, **locals)
        render = lambda do |locale|
          Rubot::I18n.with_locale(locale) do
            View.render(name, block_given? ? yield : locals)
          end
        end
        en = render.call("en")
        id = render.call("id")

        refute_equal en, id, "#{name} reads the same in both languages"
        [ en, id ]
      end
    end
  end
end
