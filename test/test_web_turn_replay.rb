# frozen_string_literal: true

require "test_helper"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # The stream as a browser assembles it.
    #
    # The other turn tests read the payloads and check what a flush says. This
    # one plays them back the way htmx does — replace the whole timeline on a
    # `turn`, append on a `turn-patch`, replace by id on `hx-swap-oob="true"`,
    # remove on `delete:#id` — and then compares the page it built with the
    # timeline the server would have drawn whole. What that catches is the thing
    # the payload assertions cannot: a fragment that lands nowhere, lands twice,
    # or lands out of order. Both times this protocol broke, it broke there.
    class TestWebTurnReplay < Minitest::Test
      include WebChannelSupport

      # Elements that never open a scope, so the splitter below does not wait
      # for a closing tag that will not come.
      VOID = %w[path circle rect ellipse line polyline polygon img br hr input
                source use stop area base col embed link meta param track wbr].freeze

      def setup
        @fixtures = []
        @channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                        messages: { "web_rubot" => [ [ "user", "Halo" ] ] })
      end

      # --- the browser ----------------------------------------------------

      # The elements htmx sees at the top level of a payload.
      def top_level(html)
        out = []
        stack = []
        start = nil
        html.to_s.dup.force_encoding("UTF-8").scan(/<\/?([a-zA-Z][\w-]*)\b[^>]*?(\/?)>/) do
          match = Regexp.last_match
          tag = match[1].downcase
          closing = match[0].start_with?("</")
          selfclose = match[2] == "/" || VOID.include?(tag)
          if stack.empty?
            next if closing

            start = match.begin(0)
            if selfclose
              out << html[match.begin(0)...match.end(0)]
              start = nil
            else
              stack.push(tag)
            end
            next
          end
          if closing
            stack.pop
            if stack.empty? && start
              out << html[start...match.end(0)]
              start = nil
            end
          elsif !selfclose
            stack.push(tag)
          end
        end
        out
      end

      def id_of(element)
        element[/\A<[^>]*?\sid="([^"]*)"/, 1]
      end

      def oob_of(element)
        element[/\A<[^>]*?\shx-swap-oob="([^"]*)"/, 1]
      end

      # Two rows that say the same thing are compared, not two that were drawn
      # the same number of milliseconds apart.
      def normalized(element)
        element
          .gsub(/\s+hx-swap-oob="[^"]*"/, "")
          .gsub(/\s+style="animation-delay: [^"]*"/, "")
          .gsub(" is-swapped", "")
          .gsub(/<span class="live-clock">.*?<\/span>/m, %(<span class="live-clock"></span>))
          .gsub(/>\s+</, "><")
          .strip
      end

      # One flush, parsed the way the stream writes it.
      def flush(events, turn, state)
        out = StringIO.new
        @channel.write_event(out, turn, :turn, nil, state)
        events.concat(parse_events(out.string))
        out.string
      end

      # The close of the stream: one last whole render, then the event that ends
      # the page. A browser ends here, so the replay has to as well — this is the
      # resync that seals the answer and covers anything an incremental step
      # missed.
      def finish_stream(events, turn, state)
        out = StringIO.new
        @channel.write_event(out, turn, :done, nil, state)
        events.concat(parse_events(out.string))
        out.string
      end

      def parse_events(text)
        events = []
        type = nil
        data = nil
        text.each_line do |line|
          line = line.chomp
          if line.start_with?("event: ")
            events << [ type, data.to_s ] if type
            type = line.sub("event: ", "")
            data = nil
          elsif line.start_with?("data: ")
            chunk = line.sub("data: ", "")
            data = data.nil? ? chunk : "#{data}\n#{chunk}"
          end
        end
        events << [ type, data.to_s ] if type
        events
      end

      # Plays the collected events back onto an empty page.
      def page_from(events)
        dom = []
        events.each do |type, data|
          next if data.to_s.strip.empty?

          case type
          when "turn" then dom = top_level(data)
          when "turn-patch"
            top_level(data).each do |element|
              oob = oob_of(element)
              if oob&.start_with?("delete:")
                target = oob.sub("delete:#", "")
                dom.reject! { |row| id_of(row) == target }
              elsif oob == "true"
                id = id_of(element)
                index = dom.index { |row| id_of(row) == id }
                refute_nil index, "a replacement arrived for ##{id}, which the page does not hold"
                dom[index] = element
              else
                dom << element
              end
            end
          end
        end
        dom
      end

      # The page the browser ends up with against the one the server would have
      # drawn from scratch.
      def assert_page_matches_the_whole(dom, turn)
        whole = top_level(@channel.render_timeline(turn))

        assert_equal whole.length, dom.length, "same number of rows"
        whole.each_with_index do |row, index|
          assert_equal normalized(row), normalized(dom[index]),
                       "row #{index} differs:\n  live:   #{normalized(dom[index])[0, 120]}\n" \
                       "  server: #{normalized(row)[0, 120]}"
        end
      end

      # --- the turns -------------------------------------------------------

      def test_every_kind_of_row_rebuilds_the_timeline_the_server_would_draw
        turn = Rubot::Web::Turn.new(id: "t-replay", session_id: "web_rubot")
        state = { order: nil, sig: nil }
        events = []

        flush(events, turn, state)
        turn.append_chunk("Aku cek dulu. ")
        flush(events, turn, state)
        turn.tool_started("file", "lib/a.rb")
        flush(events, turn, state)
        turn.add_diff(%(<div class="diff"><div class="diff-body">+ satu baris</div></div>))
        turn.tool_finished("file", true)
        flush(events, turn, state)
        turn.append_chunk("Isinya tiga file. ")
        flush(events, turn, state)
        turn.add_steer("sebentar, cek dulu")
        flush(events, turn, state)
        turn.add_attachment(url: "/files/1.png", name: "satu.png", id: "p1")
        flush(events, turn, state)
        turn.finish("Isinya tiga file. ")
        finish_stream(events, turn, state)

        dom = page_from(events)
        assert_page_matches_the_whole(dom, turn)

        text = dom.join
        assert_includes text, "diff-body", "the edit the tool made is on the page"
        assert_includes text, "satu.png", "so is the file it sent"
        assert_includes text, "sebentar, cek dulu", "and the message typed mid-turn"
        assert_includes text, "Aku cek dulu.", "the narration above the call"
      end

      # A thought too quick to mention is dropped from the timeline, so the page
      # that already drew it has to take it back.
      def test_a_row_taken_back_leaves_the_page
        turn = Rubot::Web::Turn.new(id: "t-drop", session_id: "web_rubot")
        state = { order: nil, sig: nil }
        events = []

        turn.thinking("sebentar")
        shown = flush(events, turn, state)
        assert_includes shown, "Thinking", "the row is drawn as it starts"

        turn.append_chunk("jawaban") # closing it under THINKING_SECONDS drops it
        dropped = flush(events, turn, state)
        assert_includes dropped, 'hx-swap-oob="delete:#t-t-drop-1"', "the page is told to take it back"

        dom = page_from(events)
        assert_page_matches_the_whole(dom, turn)
        refute_includes dom.join, "Thinking", "and the row it never kept is gone"
      end

      # The seam an automatic compaction leaves is a row that changes state while
      # it runs, which is the replace path on a row already on the page.
      def test_a_compaction_seam_is_replaced_where_it_stands
        turn = Rubot::Web::Turn.new(id: "t-compact", session_id: "web_rubot")
        state = { order: nil, sig: nil }
        events = []

        turn.append_chunk("Sebelum ringkasan. ")
        flush(events, turn, state)
        turn.compaction_start
        running = flush(events, turn, state)
        assert_includes running, "is-running"
        turn.compaction(summarized_messages: 12, context_before: 40_000,
                        context_after: 8_000, elapsed: 6.4)
        flush(events, turn, state)
        turn.append_chunk("Sesudah ringkasan. ")
        flush(events, turn, state)
        turn.finish("Sesudah ringkasan. ")
        finish_stream(events, turn, state)

        dom = page_from(events)
        assert_page_matches_the_whole(dom, turn)

        text = dom.join
        assert_includes text, "compaction-row"
        refute_includes text, "is-running", "the running seam became the finished one"
      end

      # The compact view drops and folds rows, so the list the page holds and the
      # list the server draws stop matching on their own: every step has to be
      # told, and the end has to agree.
      def test_the_compact_view_still_ends_on_the_same_timeline
        turn = Rubot::Web::Turn.new(id: "t-compact-rows", session_id: "web_rubot", tool_output: "compact")
        state = { order: nil, sig: nil }
        events = []

        flush(events, turn, state)
        3.times do |round|
          turn.thinking("ronda #{round}")
          turn.append_chunk("Ronde #{round}. ")
          turn.tool_started("shell", "ls #{round}")
          flush(events, turn, state)
          turn.tool_finished("shell", true)
          flush(events, turn, state)
        end
        turn.finish("Ronde 2. ")
        finish_stream(events, turn, state)

        dom = page_from(events)
        assert_page_matches_the_whole(dom, turn)
        assert_operator top_level(@channel.render_timeline(turn)).length, :<, 12,
                        "the compact view is still folding rows"
      end
    end
  end
end
