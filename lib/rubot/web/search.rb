# frozen_string_literal: true

module Rubot
  module Web
    # Finding a conversation by what was said in it.
    #
    # The archive already answers with bm25 over three weighted columns, so this
    # module only has to keep the answer inside the conversations this channel
    # can open — a hit in a Telegram chat has no page here — and group it the
    # way the sidebar lists conversations, one block per conversation with its
    # hits underneath.
    #
    # Included into the channel and left public on purpose: the router calls
    # these directly and the tests do the same.
    module Search
      # How many messages one search answers with. The sidebar is a list, not a
      # page: a query that matches hundreds of rows is answered with the best of
      # them, and a narrower query is how the reader asks for more.
      SEARCH_LIMIT = 20

      # --- search ---------------------------------------------------------

      # Search results, drawn the way the sidebar lists conversations: one
      # block per conversation with its hits underneath. The ranking already
      # orders hits best first (bm25 over three weighted columns, see
      # Store#search), and grouping keeps that order — a conversation appears
      # where its best hit does, so a flat list of twenty rows from one session
      # does not read as twenty conversations that all share a title.
      def render_search(res, req)
        query = form(req, "q").strip

        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = View.render("_search", query: query, groups: search_groups(query),
                                          token_query: token_query)
      end

      def search_groups(query)
        return {} if query.empty?

        store = Rubot::Archive.current
        return {} unless store

        # The archive is shared by every channel, so the prefix keeps the answer
        # to conversations this channel can open: a hit in a Telegram chat has
        # no page here. Asking for more than a page of results and then cutting
        # is not the same as asking for a page — the SQL keeps the limit honest.
        hits = store.search(query, limit: SEARCH_LIMIT * 2, prefix: "web_")
        rows = hits.filter_map do |hit|
          sid = hit[:session_id]
          slug = owner_slug(sid)
          next unless slug

          persona = persona_store&.[](slug)
          {
            href: hit_url(sid, hit[:idx]),
            who: role_label(hit[:role]),
            html: hit[:html],
            idx: hit[:idx],
            session_id: sid,
            title: hit[:title].to_s.strip.empty? ? I18n.t("web.sessions.untitled") : hit[:title].to_s.strip,
            emoji: persona ? persona.emoji_or : "🤖",
            persona_label: persona ? persona.label : slug.capitalize,
            age: iso_age(hit[:created_at])
          }
        end

        rows.first(SEARCH_LIMIT).group_by { |row| row[:session_id] }
      end

      # The URL a hit opens: the conversation, asked to land on that message.
      # No fragment — a turn wraps several messages, so `at` is the only thing
      # that names the place, and the page marks the entry that holds it.
      def hit_url(sid, idx)
        params = [ token_query.delete_prefix("?"), "at=#{idx}" ].reject(&:empty?)
        "/s/#{sid}?#{params.join("&")}"
      end

      # Who said it, in the words the thread uses: the person is "kamu", the
      # assistant is the product's own name, and a tool row is a tool.
      def role_label(role)
        case role.to_s
        when "user" then "kamu"
        when "tool" then "tool"
        else "rubot"
        end
      end

      # A stored timestamp is ISO-8601 text, and the sidebar speaks in ages: a
      # difference between two instants needs no timezone, an absolute time
      # would have to assume one.
      def iso_age(value)
        return "" if value.to_s.empty?

        elapsed_label(Time.iso8601(value.to_s).to_f)
      rescue ArgumentError
        ""
      end
    end
  end
end
