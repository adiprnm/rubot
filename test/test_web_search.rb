# frozen_string_literal: true

require "test_helper"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # Searching every stored message, including the turns that were compacted away.
    class TestWebSearch < Minitest::Test
      include WebChannelSupport

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




      # A real PNG signature: the page serves only what it can draw, and a
      # made-up string would not prove the bytes came back unchanged.

      # The model and the thinking level are per-session choices under the
      # composer. A change is applied to the session's actor, and the answer
      # is the row again with the new choice already marked — a stale page
      # cannot drift from what the session really runs on.
      def test_session_settings_applies_the_choice_and_rerenders_the_row
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        # model-b is what the config runs on by default; model-a is the
        # change this test makes.
        channel.instance_variable_get(:@app_config).data["models"] =
          [ { "name" => "model-b", "model" => "openai/gpt-4o", "api_key" => "sk-test" },
            { "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]

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
          [ { "name" => "model-a", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" },
            { "name" => "model-b", "model" => "openai/gpt-4o", "api_key" => "sk-test" } ]

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

      # The dot on the row and the number on the roster are the same fact at two
      # scales, so the swap that carries one has to carry the other: a reader
      # looking at another conversation of the same persona sees the count grow
      # without a reload, and only a reload would say so otherwise.
      def test_a_sidebar_swap_carries_the_roster_count_too
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ %w[user halo], %w[assistant siap] ],
                      "web_kanyaah~20261110-090000" => [ %w[user halo juga] ] }
        )
        Rubot::Session.store.mark_unread("web_kanyaah~20261110-090000")

        markup = channel.send(:sidebar_markup, "web_kanyaah")

        assert_includes markup, %(<ul class="rail-list" id="rail-list" hx-swap-oob="true">)
        assert_includes markup, %(<span class="rail-badge" aria-hidden="true">1</span>),
                        "the roster says how many conversations are waiting"
      end

      # A read roster draws no badge at all, or every persona would carry a zero.
      def test_a_roster_with_nothing_unread_draws_no_badge
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ %w[user halo] ] }
        )

        markup = channel.send(:sidebar_markup, "web_kanyaah")

        refute_includes markup, "rail-badge"
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

      # The count is part of the page a reader lands on, not only of the swap
      # that follows a turn: arriving at a conversation from a link brings the
      # handle up to date in the same breath as the roster.
      def test_a_landed_page_draws_the_handle_count
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          messages: { "web_kanyaah" => [ %w[user halo], %w[assistant siap] ],
                      "web_kanyaah~20261110-090000" => [ %w[user halo juga] ] }
        )
        Rubot::Session.store.mark_unread("web_kanyaah~20261110-090000")
        res = FakeResponse.new

        channel.send(:render_session, res, "web_kanyaah")

        assert_includes res.body, %(data-total="1"),
                        "the drawer's handle is drawn from the same fact as the roster"
      end

      # The handle that opens the drawer speaks for the install, not for the
      # persona on screen: on a phone the roster is behind that drawer, so news
      # from a second persona has no other place to show up.
      def test_the_drawer_handle_counts_every_persona
        channel = channel_with_archive(
          personas: { "kanyaah" => { "name" => "Kanyaah" },
                      "english-tutor" => { "name" => "English Tutor" } },
          messages: { "web_kanyaah" => [ %w[user halo] ],
                      "web_kanyaah~20261110-090000" => [ %w[user halo lagi] ],
                      "web_english-tutor" => [ %w[user hello] ] }
        )
        Rubot::Session.store.mark_unread("web_kanyaah~20261110-090000")
        Rubot::Session.store.mark_unread("web_english-tutor")

        markup = channel.send(:sidebar_markup, "web_kanyaah")

        assert_includes markup, %(<span class="nav-badge" id="nav-badge" data-total="2">),
                        "one waiting conversation here and one in the other persona"
        assert_includes markup, %(id="chat-head" hx-swap-oob="true"),
                        "the count rides the header swap, so it needs no swap of its own"
      end

      # Nothing waiting draws nothing, so a quiet install looks as it always did.
      def test_a_quiet_install_draws_no_handle_badge
        html = View.render("_nav_badge", total: 0)

        refute_includes html, "data-total"
        assert_includes html, %(id="nav-badge"></span>),
                        "an empty handle has to be really empty for :empty to hide it"
      end

      # Same cap as the roster: two digits must not spill out of the pill.
      def test_the_drawer_handle_caps_its_count
        html = View.render("_nav_badge", total: 12)

        assert_includes html, "9+"
        assert_includes html, "12 percakapan belum dibaca"
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
                           session_model: "", session_thinking: "medium", persona_thinking: "medium",
                    persona_tool_output: "verbose",
                    skill_choices: [], skills_dir: "~/.rubot/skills",
                           session_short: "web_a", session_label: "Sesi baru",
                           document_title: "rubot · A", live_turn: nil, live_prompt_shown: false, token_query: "",
                           page: { entries: [], more: false, before: 0 }, older_url: "",
                           usage: { cost: "—", cache: "—", ctx: "—" },
                           usage_facts: { model: "m · openai", cost: "—", breakdown: "", requests: "0",
                                          messages: "0", tokens_in: "0", tokens_out: "0", reasoning: "",
                                          cache: "—", cache_history: "", re_read: "0",
                                          saved: "", ctx: "—" })

        assert_includes html, ">3</span>"
        assert_includes html, "9+"
        assert_includes html, "3 percakapan belum dibaca"
      end
    end
  end
end
