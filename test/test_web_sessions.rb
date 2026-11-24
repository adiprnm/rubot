# frozen_string_literal: true

require "test_helper"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # The session list side of the page: paging, pinning, renaming and the sessions a reader can reach.
    class TestWebSessions < Minitest::Test
      include WebChannelSupport

      # --- paging through a long conversation -----------------------------

      # The page is opened to read the end of the conversation, not the
      # beginning of it: a session with hundreds of turns should not cost a
      # full render to show its last answer. It is cut by messages, not by
      # entries, so a long session of short turns and a short session of long
      # ones both land at a weight the reader can pay.
      def test_the_page_starts_at_the_end_of_a_long_conversation
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_long_session(channel, "web_kanyaah", 150)

        page = channel.history_page("web_kanyaah")
        prompts = page[:entries].select { |entry| entry[:kind] == :prompt }.map { |entry| entry[:text] }

        assert page[:more], "the older half is left to be fetched"
        assert_includes prompts, "pesan 150", "the newest exchange is on the page"
        refute_includes prompts, "pesan 1", "the oldest one is not"
        # The walk stops once the budget is spent, then reaches back for a
        # prompt, so a page is at least the budget and never many times it.
        assert_operator spanned_messages(page), :>=, Rubot::Channels::Web::HISTORY_PAGE_MESSAGES
        assert_operator spanned_messages(page), :<=, Rubot::Channels::Web::HISTORY_PAGE_MESSAGES * 2,
                        "the page stays in the same order of size as the budget"
      end

      # One turn can be longer than a whole page. It is still drawn in one piece:
      # a page that cut it would show a tool result whose call sits on the page
      # above, and the compact view would draw the wrong call as "the last one".
      def test_a_single_turn_longer_than_the_budget_is_still_drawn_whole
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        # Three pages of messages in one turn, so the budget has to give way. The
        # size comes from the constant: a fixture with the number written in it
        # stops testing anything the day the budget moves.
        steps = Rubot::Channels::Web::HISTORY_PAGE_MESSAGES * 3
        write_messages(channel, "web_kanyaah", [
                         { "role" => "user", "content" => "satu prompt panjang" }
                       ] + Array.new(steps) { |i| { "role" => "assistant", "content" => "langkah #{i}" } })

        page = channel.history_page("web_kanyaah")

        assert_operator spanned_messages(page), :>, Rubot::Channels::Web::HISTORY_PAGE_MESSAGES
        assert_equal 1, page[:entries].count { |entry| entry[:kind] == :turn }
        assert_equal :turn, page[:entries].first[:kind],
                     "the reach cannot afford the prompt three pages up"
        assert page[:more], "the prompt it opens on is still above it"
      end

      # A conversation that fits under the budget is drawn whole, and the sentinel
      # stays out of it.
      def test_a_conversation_that_fits_is_not_paged
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_long_session(channel, "web_kanyaah", 3)

        page = channel.history_page("web_kanyaah")

        assert_equal 6, page[:entries].size
        refute page[:more]
        assert_equal 0, page[:before], "there is nothing above the first page"
      end

      # A cursor that precedes every entry cannot name a page: the link came from
      # a transcript that has since lost its first messages (a session trimmed
      # before it was indexed). Drawing "everything before message 1" would leave
      # the reader with an empty thread, no sentinel below and no way back, so
      # the tail is drawn instead.
      def test_a_cursor_older_than_the_first_entry_does_not_blank_the_thread
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        # A prompt with no text is not an entry, so the first entry starts at
        # message 1 and a cursor of 1 is already older than all of them.
        write_messages(channel, "web_kanyaah",
                       [ { "role" => "user", "content" => "" } ] + (1..3).flat_map do |i|
                         [ { "role" => "user", "content" => "pesan #{i}" },
                           { "role" => "assistant", "content" => "balasan #{i}" } ]
                       end)

        page = channel.history_page("web_kanyaah", before: 1)

        assert page[:entries].any?, "the thread is not blank"
        assert_equal "pesan 1", page[:entries].first[:text],
                     "the tail is drawn, which begins at the first entry"
        refute page[:more]
      end

      # The sentinel hands back the message index the page starts at, so scrolling
      # up walks backwards through the same conversation one page at a time. The
      # turns are several messages long, so a cursor mistaken for an entry count
      # cannot pass as the message index.
      def test_scrolling_up_asks_for_the_page_before
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_multi_message_session(channel, "web_kanyaah", 120)

        page = channel.history_page("web_kanyaah")
        older = channel.history_page("web_kanyaah", before: page[:before])

        assert older[:entries].any?, "there is a page above the first one"
        assert older[:more], "and one above that"
        assert_operator older[:before], :<, page[:before]
        assert_equal older[:before], older[:entries].first[:idx],
                     "the cursor is the message the page starts at, not a count"

        newest = page[:entries].map { |entry| entry[:text] }
        refute (older[:entries].map { |entry| entry[:text] } & newest).any?,
               "two pages of one conversation do not overlap"
      end

      # Walking to the top has to visit every entry exactly once. A cursor read as
      # an entry count instead of a message index would skip or repeat whole
      # blocks, which is invisible one page at a time and obvious when tiled.
      def test_the_pages_tile_the_conversation_with_no_gap_or_overlap
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_multi_message_session(channel, "web_kanyaah", 120)

        walked = []
        before = nil
        loop do
          page = channel.history_page("web_kanyaah", before: before)
          break if page[:entries].empty?

          walked.unshift(*page[:entries].map { |entry| entry[:idx] })
          break unless page[:more]

          before = page[:before]
          assert_operator walked.size, :<=, channel.history("web_kanyaah").size,
                          "the walk must terminate"
        end

        assert_equal channel.history("web_kanyaah").map { |entry| entry[:idx] }, walked,
                     "every entry is drawn once, in order"
      end

      # Every page opens where the reader spoke. A page that began with an answer
      # would draw a reply to a question that is a scroll away, and the reader
      # would read the conversation backwards for a moment before it made sense.
      #
      # The turns are deliberately uneven. With one message per entry a budget of
      # 100 always lands on an even entry index, which is always a prompt, so the
      # fixture would pass even with the snap removed — a test that cannot fail.
      def test_every_page_opens_with_a_prompt
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_messages(channel, "web_kanyaah", (1..300).flat_map do |i|
          [ [ { "role" => "user", "content" => "pesan #{i}" } ],
            Array.new(i.odd? ? 1 : 3) { { "role" => "assistant", "content" => "balasan #{i}" } } ].flatten
        end)

        before = nil
        pages = 0
        loop do
          page = channel.history_page("web_kanyaah", before: before)
          break if page[:entries].empty?

          pages += 1
          assert_equal :prompt, page[:entries].first[:kind],
                       "page #{pages} starts at message #{page[:entries].first[:idx]}"
          break unless page[:more]

          before = page[:before]
          assert_operator pages, :<=, 40, "the walk must terminate"
        end
        assert_operator pages, :>, 1, "the walk covered more than one page"
      end

      # The entry cap alone is what stops the reach here: the prompt is 51 entries
      # away (past the 12) but only 51 messages away, so a walk bounded only by
      # messages would still find it. The page therefore opens on a turn.
      def test_a_run_of_answers_with_no_prompt_does_not_swallow_the_conversation
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_messages(channel, "web_kanyaah",
                       [ { "role" => "user", "content" => "job dimulai" } ] +
                       Array.new(150) { |i| { "role" => "assistant", "content" => "laporan #{i}", "background" => true } })

        page = channel.history_page("web_kanyaah")

        assert_equal :turn, page[:entries].first[:kind], "the entry cap stops the reach"
        assert_operator spanned_messages(page), :<=, Rubot::Channels::Web::HISTORY_PAGE_MESSAGES * 2,
                        "the page is bounded even though it opens on an answer"
        assert page[:more], "the rest is left to the page above"
      end

      # Twelve turns is not twelve messages: a run of very long turns must not be
      # granted twelve turns of reach. The prompt sits exactly at the entry floor
      # (12 turns back) and 2,400 messages away, so only the message cap stops it.
      def test_a_run_of_long_answers_is_bounded_in_messages_too
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        # Each turn is exactly the reach's own ceiling, so one turn of reach is
        # already all it gets: the cap and the fixture move with the budget.
        block = Rubot::Channels::Web::HISTORY_PAGE_MESSAGES * 2
        turns = Array.new(Rubot::Web::HistoryView::HISTORY_SNAP_LIMIT) do |i|
          [ { "role" => "assistant", "content" => "job #{i}", "background" => true } ] +
            Array.new(block - 1) { { "role" => "assistant", "content" => "langkah #{i}" } }
        end
        write_messages(channel, "web_kanyaah",
                       [ { "role" => "user", "content" => "job dimulai" } ] + turns.flatten)

        page = channel.history_page("web_kanyaah")

        assert_equal :turn, page[:entries].first[:kind], "the message cap stops the reach"
        assert_operator spanned_messages(page), :<=, Rubot::Channels::Web::HISTORY_PAGE_MESSAGES * 2,
                        "the reach is measured in messages, not in entries"
        assert page[:more], "the rest is left to the page above"
      end

      def test_the_older_page_comes_back_with_the_sentinel_for_the_one_above_it
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_long_session(channel, "web_kanyaah", 150)
        res = FakeResponse.new
        expected = channel.history_page("web_kanyaah", before: 250)
        # The cursor is the message the page actually begins with, not a count:
        # that is what makes the link mean the same place after a reload.
        assert_equal expected[:entries].first[:idx], expected[:before]

        # Message 250 is the answer to "pesan 125".
        channel.render_history(res, "web_kanyaah", Struct.new(:query).new({ "before" => "250" }))

        assert_includes res.body, "pesan 125", "the page ends where the sentinel was"
        refute_includes res.body, "pesan 140", "and stops there rather than running on"
        assert_includes res.body,
                        %(data-history-url="/s/web_kanyaah/history?before=#{expected[:before]}"),
                        "the page above this one is asked for in turn, from where this one began"
      end

      # The last page has nothing above it, so the sentinel would ask for the same
      # page forever.
      def test_the_first_page_completes_without_a_sentinel
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        write_long_session(channel, "web_kanyaah", 3)
        res = FakeResponse.new

        channel.render_history(res, "web_kanyaah", Struct.new(:query).new({ "before" => "2" }))

        assert_includes res.body, "pesan 1"
        refute_includes res.body, "history-more"
      end

      # The sentinel is what keeps the scroll continuous: it carries the address
      # of the page above and nothing else — no htmx trigger, because htmx only
      # re-checks a revealed element on a *window* scroll and this shell scrolls
      # `#thread` instead (see the note in app.js). No words either: a reader
      # scrolling up should find the conversation going on, not a caption
      # announcing that more exists.
      def test_the_sentinel_is_silent_and_carries_only_the_address
        html = View.render("_history", entries: [], more: true,
                                       older_url: "/s/web_kanyaah/history?before=20")
        sentinel = html[/<div class="history-more".*?<\/div>/m]

        refute_nil sentinel
        assert_includes sentinel, 'data-history-url="/s/web_kanyaah/history?before=20"'
        refute_includes sentinel, "hx-trigger",
                        "the fetch is driven by the thread's scroll, not by htmx"
        assert_empty sentinel[/>(.*)</m, 1].to_s.strip, "the sentinel carries no words"
      end

      def test_the_older_page_request_carries_the_token
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })

        assert_equal "/s/web_kanyaah/history?token=t0k&before=40",
                     channel.older_url("web_kanyaah", 40)
      end

      # Prepending a page moves everything below it down by its own height, and
      # the reader would be thrown out of the sentence they were reading. The
      # distance from the bottom is the one measure the insert cannot change.
      # The scroll that asks for the page is read on the thread, because that is
      # what scrolls; `window` never does in this shell.
      def test_a_prepended_page_keeps_the_reader_in_place
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "askForOlderPage",
                        "the page above is asked for by the thread's own scroll"
        assert_includes js, 'el.id !== "thread"'
        assert_includes js, "thread.scrollTop = thread.scrollHeight - gap",
                        "the distance from the bottom is put back after the insert"
        assert_includes js, 'sentinel.insertAdjacentHTML("beforebegin", html)',
                        "the older page lands above the entries already drawn"
        refute_includes js, 'el.closest(".history-more")',
                        "htmx is no longer asked to swap this element"
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

      # --- sessions -------------------------------------------------------

      # A session id has to survive the trip back to a persona: the SessionPool
      # roots a session's Ractor at the persona's workspace from the id alone.
      # A persona's second conversation must therefore still name its owner.
      def test_a_later_session_still_belongs_to_its_persona
        channel = Rubot::Channels::Web.new(channel_config: {})

        sid = channel.new_session_id("kanyaah")

        assert sid.start_with?("web_kanyaah~"), sid
        assert_equal "kanyaah", Rubot::PersonaStore.key_for_session(sid)
        refute_equal channel.session_id("kanyaah"), sid,
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

        ids = channel.sessions_for("kanyaah").map { |entry| entry[:id] }

        assert_includes ids, "web_kanyaah"
        assert_includes ids, "web_kanyaah~20261108-101010"
        refute_includes ids, "web_rubot"
      end

      def test_subagent_sessions_are_hidden_from_the_sidebar
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: {
            "web_kanyaah" => "Bikin carousel",
            "web_kanyaah~sub-abc123" => "internal work log"
          }
        )

        ids = channel.sessions_for("kanyaah").map { |entry| entry[:id] }

        assert_includes ids, "web_kanyaah"
        refute_includes ids, "web_kanyaah~sub-abc123", "a sub agent's log is not a chat"
      end

      def test_a_session_row_is_named_by_the_prompt_that_started_it
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Riset harga template signature" }
        )

        row = channel.session_rows("kanyaah", "web_kanyaah").first

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

        row = channel.session_rows("kanyaah", "web_kanyaah").first

        assert_equal "Build gagal di CI", row[:label]
      end

      def test_the_header_and_tab_share_the_named_title
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "tolong cek kenapa build gagal" },
          titles: { "web_kanyaah" => "Build gagal di CI" }
        )

        markup = channel.sidebar_markup("web_kanyaah")

        assert_includes markup, %(data-title="Kanyaah · Build gagal di CI")
        assert_includes markup, ">Build gagal di CI</button>"
        assert_includes markup, %(/s/web_kanyaah/rename),
                        "the name is editable from the header it is drawn in"
      end

      # A session that has not been written yet has no file, so the row for the
      # one on screen comes from the caller instead of the index.
      def test_a_conversation_with_no_messages_is_listed_while_it_is_open
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })

        rows = channel.session_rows("kanyaah", "web_kanyaah~20261108-090000")

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
        row = channel.session_rows("kanyaah", "web_kanyaah").first

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
        groups = channel.session_groups("kanyaah", "web_kanyaah")

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

        groups = channel.session_groups("kanyaah", "web_kanyaah~baru")

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

        groups = channel.session_groups("kanyaah", "web_kanyaah~pinned")
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

        groups = channel.session_groups("kanyaah", "web_kanyaah")
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
        channel.rename_session(res, "web_kanyaah", form_post("name" => "  Proyek   Templete  "))

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
        channel.rename_session(FakeResponse.new, "web_kanyaah",
                     form_post("name" => "baris satu\nbaris dua"))

        assert_equal "baris satu baris dua", stored_title("web_kanyaah")

        channel.rename_session(FakeResponse.new, "web_kanyaah", form_post("name" => long))
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
        channel.rename_session(res, "web_kanyaah", form_post("name" => "Nama Baru"))

        assert_equal 409, res.status
        assert_empty res.body
        assert_equal "isi percakapan", stored_title("web_kanyaah")
      end




      # A request that only differs from a form post by its path and method,
      # for the routes a button reaches without a form of its own.

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

        channel.toggle_pin(res, "web_kanyaah~other", req)

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
                           groups: channel.session_groups("kanyaah", "web_kanyaah"),
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
        channel.toggle_pin(FakeResponse.new, ids.last, req)

        pinned = channel.session_groups("kanyaah", ids.last)[:pinned].map { |row| row[:id] }

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

        first = channel.session_groups("kanyaah", "web_kanyaah~01")
        loaded = channel.session_groups("kanyaah", "web_kanyaah~01", page: 2)

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

        first = channel.session_groups("kanyaah", "web_kanyaah~01")
        block = channel.recent_block("kanyaah", "web_kanyaah~01", 2)

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
                           groups: channel.session_groups("kanyaah", "web_kanyaah~01"),
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

        channel.render_recent(res, "web_kanyaah~01", second)

        assert_equal 200, res.status
        assert_equal 20, res.body.scan(%(class="session-link")).size
        assert_includes res.body, %(id="recent-more")
        assert_includes res.body, "page=3", "the control points at the block after this one"

        res = FakeResponse.new
        channel.render_recent(res, "web_kanyaah~01", last)

        assert_equal 1, res.body.scan(%(class="session-link")).size
        refute_includes res.body, %(id="recent-more"), "the list ends without a control"
      end

      def test_the_session_list_refresh_is_an_out_of_band_swap
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Halo" }
        )

        markup = channel.sidebar_markup("web_kanyaah")

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

        markup = channel.sidebar_markup("web_kanyaah")

        assert_includes markup, %(id="chat-head" hx-swap-oob="true")
        assert_includes markup, "Riset harga template signature"
      end

      # The end-to-end version of the test above: a real turn through the channel,
      # the naming request that follows it, and the markup the browser is handed
      # at the end. The name is only known once the turn is over, so a page that
      # does not receive this swap shows the prompt's first words until it is
      # reloaded — which is what the reader reported.
      #
      # Learning is deferred, so the test waits for the worker instead of
      # assuming it has won a race with the turn: naming runs after the answer is
      # delivered, and which of the two finishes first is nothing to rely on.
      def test_the_name_the_model_gives_reaches_the_page_when_the_turn_ends
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        config = channel.instance_variable_get(:@app_config)
        provider = NamingProvider.new(title: "Undangan pernikahan")
        channel.define_singleton_method(:session_for) do |sid|
          Rubot::Agent.new(config: config, provider: provider, session_id: sid)
        end

        res = FakeResponse.new
        channel.create_turn(turn_request("Tolong susun undangan pernikahan"), res, "web_kanyaah")

        # The turn runs on a thread of its own, and the naming job is handed over
        # as it ends: wait for the turn, then for the worker that names it.
        turn = channel.instance_variable_get(:@turns).values.first
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep 0.01 until turn.closed? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        channel.drain_learning

        payload = channel.sidebar_markup("web_kanyaah")

        assert_equal 1, provider.naming_calls, "the conversation is named once the answer is delivered"
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

        assert_nil channel.named_session_label("kanyaah", "web_kanyaah~20261108-090000")
        assert_equal "Kanyaah",
                     channel.document_title("Kanyaah",
                                  channel.named_session_label("kanyaah", "web_kanyaah~x"))
      end

      def test_the_document_title_names_the_session
        channel = Rubot::Channels::Web.new(channel_config: {})

        assert_equal "Kanyaah · Riset harga",
                     channel.document_title("Kanyaah", "Riset harga")
        assert_equal "Kanyaah", channel.document_title("Kanyaah", nil)
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

        channel.delete_session(res, "web_kanyaah~20261108-101010", nil)

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

        channel.delete_session(res, "web_kanyaah", nil)

        assert_equal 303, res.status
        assert_equal "/p/kanyaah", res.headers["Location"]
      end

      # The delete URL is a bare id, so it has to be checked against the
      # personas that exist just as any other route is.
      def test_deleting_a_session_of_an_unknown_persona_is_not_found
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        res = FakeResponse.new

        channel.delete_session(res, "web_ghost", nil)

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

        assert_equal [ channel.session_id ], opened
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

        channel.render_session(res, "web_english-tutor")

        assert_includes res.body, %(sse-connect="/events?sid=web_english-tutor"),
                        "an idle page has no turn stream, so it needs one of its own"
      end

      # Every page hears about it, though each is answered with its own rows:
      # the roster and the drawer's count speak for the install, so a page of
      # another persona gains a number without being handed a row that is not
      # its own.
      def test_a_new_conversation_reaches_every_page_with_its_own_rows
        channel = channel_with_sessions(personas: {
          "english-tutor" => { "name" => "English Tutor" },
          "kanyaah" => { "name" => "Kanyaah" }
        })
        listening = Queue.new
        elsewhere = Queue.new
        channel.listen_for_events("web_english-tutor", listening)
        channel.listen_for_events("web_kanyaah", elsewhere)

        channel.broadcast_sessions

        refute listening.empty?, "the persona's page has a sidebar to redraw"
        refute elsewhere.empty?, "the other page wears the same count on its handle"
        assert_includes elsewhere.pop, %(id="nav-badge"),
                        "the second page is told the count, not the row"
      end

      def test_a_page_that_went_away_stops_being_written_to
        channel = channel_with_sessions(personas: { "english-tutor" => { "name" => "English Tutor" } })
        queue = Queue.new
        channel.listen_for_events("web_english-tutor", queue)
        channel.stop_listening_for_events(queue)

        channel.broadcast_sessions

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
        channel.listen_for_events("web_english-tutor", queue)

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
        groups = channel.session_groups("kanyaah", "web_kanyaah")

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

        channel.open_persona(res, "kanyaah", nil)

        assert_equal 303, res.status
        assert_equal "/s/web_kanyaah", res.headers["Location"]
      end

      # A hand-typed URL must not open a session of a persona that is gone.
      def test_a_session_of_an_unknown_persona_is_not_found
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        res = FakeResponse.new

        channel.render_session(res, "web_ghost")

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

      # The palette and the notification toggle used to sit at the foot of the
      # drawer, then they moved to the settings page — they are settings, chosen
      # once, and a control that exists in two places can end up disagreeing
      # with itself. What the drawer's foot keeps is the facts about this
      # connection; a phone's drawer has no room for more than that.
      def test_the_device_controls_live_in_the_settings_page_and_nowhere_else
        html = render_page
        refute_includes html, "data-theme-choice=",
                        "the palette is a setting, not part of a conversation"
        refute_includes html, "data-push-slug=",
                        "the notification toggle belongs where it can be read once"

        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        narrow = css[/^@media \(max-width: 860px\) \{.*?\n\}/m]

        refute_nil narrow, "the drawer's breakpoint is missing from app.css"
        assert_includes narrow, ".sidebar-foot dl { display: none; }",
                        "the connection facts are what the drawer has no room for"
      end

      # The three choices are pressed buttons laid out in one row that wraps
      # rather than overflows: a settings page is narrow on a phone, and a row
      # that cannot break would push its last choice off the edge. Each swatch
      # carries its own answer in words, so the mark is never the only signal.
      def test_the_appearance_choices_are_pressed_buttons_in_a_wrapping_row
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        rows = css[/^\.theme-picker,\n\.font-picker,\n\.push-picker \{[^}]*\}/]
        swatch = css[/^\.theme-swatch,\n\.font-choice \{[^}]*\}/]

        refute_nil rows, "the three choice rows need a shared rule in app.css"
        refute_nil swatch, "a swatch and a font button are the same kind of control"
        assert_includes rows, "flex-wrap: wrap",
                        "a phone's settings page has to be able to break the row"
        assert_includes swatch, "border: 1px"
        assert_includes swatch, "font-family: var(--mono)",
                        "the control's own name is a label, not prose"
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
    end
  end
end
