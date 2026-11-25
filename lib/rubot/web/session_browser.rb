# frozen_string_literal: true

module Rubot
  module Web
    # The sidebar: which conversations a persona owns, what each is called, how
    # the pinned list and the paginated recent list are cut, how an unread mark
    # is decided, and the markup that draws all of it.
    #
    # Included into the channel and left public on purpose: a channel's own
    # header, the search results and the tests all ask these questions directly,
    # and none of them is a secret.
    module SessionBrowser
      # A persona can own many conversations. The first one keeps the historic
      # id ("web_<slug>"); every later one appends "~<stamp>". "~" cannot occur
      # in a slug, so the id always splits back into persona + session.
      SESSION_SEPARATOR = "~"
      # How many conversations can be pinned for one persona. A pin is a way of
      # saying "this one again", and a list long enough to scroll is not a way of
      # saying it: past ten the oldest pin gives way, so the cap needs no error
      # message and no separate setting.
      PINNED_LIMIT = 10
      # How many unpinned conversations one page of the sidebar holds. The rest
      # are still there, a page link away, so an archive with years in it does
      # not turn the sidebar into an endless scroll.
      RECENT_PAGE = 20
      # What a conversation is called before its first prompt has been saved.
      #
      # The channel aliases this constant, so it stays defined; but a constant
      # is read once, at load, in the language the process booted in, so nothing
      # a reader sees may use it. Every drawing asks `untitled_session`, which
      # reads the language of the moment.
      UNTITLED_SESSION = Rubot::I18n.t("web.sessions.untitled")

      # The name of a conversation that has none yet, in the active language.
      def untitled_session
        Rubot::I18n.t("web.sessions.untitled")
      end

      def session_id(slug = default_slug)
        "web_#{slug}"
      end

      # An id for a conversation that does not exist yet. Nothing is written to
      # disk until it has a message (see Session#save!), so opening a session
      # and leaving it untouched leaves nothing behind.
      def new_session_id(slug)
        base = "#{session_id(slug)}#{SESSION_SEPARATOR}#{Time.now.strftime("%Y%m%d-%H%M%S")}"
        candidate = base
        counter = 1
        while taken_session_id?(candidate)
          counter += 1
          candidate = "#{base}-#{counter}"
        end
        candidate
      end

      def taken_session_id?(sid)
        # The archive is the live store: a session it holds is in use even
        # though no file exists for it any more.
        return true if (store = Rubot::Archive.current) && store.session?(sid)

        dir = @app_config&.sessions_dir
        return true if dir && File.exist?(File.join(dir, "#{sid}.json"))

        # An id the pool already spawned is taken too, even before it is saved.
        @pool ? @pool.session_ids.include?(sid) : @active.key?(sid)
      end

      # Which persona owns a session id, or nil when the id is not a web one.
      def owner_slug(sid)
        slug = PersonaStore.key_for_session(sid)
        return nil unless slug && known_slug?(slug)

        slug
      end

      # The persona's conversations, newest first. Only files are listed, so a
      # session that was opened but never used does not appear; the caller adds
      # the one on screen itself when it is missing.
      def sessions_for(slug)
        base = session_id(slug)
        prefix = "#{base}#{SESSION_SEPARATOR}"
        rows = if (store = Rubot::Archive.current)
          # Straight from the archive: six short columns, no file parsing. A
          # session that was opened but never used has no row, so it does not
          # appear. Every row is read because the list is paginated and the
          # page links have to know how many pages there are.
          store.sidebar(limit: nil).filter_map do |row|
            id = row[:id].to_s
            next unless id == base || id.start_with?(prefix)
            # A sub agent's conversation is an internal work log, not one of
            # the persona's chats. It stays in the archive and is reachable by
            # id, but must not clutter the sidebar.
            next if id.include?("~sub-")

            Session.entry_from_row(row)
          end
        else
          dir = @app_config&.sessions_dir
          return [] unless dir && Dir.exist?(dir)

          Dir.glob(File.join(dir, "#{base}*.json"))
            .filter_map { |path| Session.describe(path) }
            .select { |entry| (entry[:id] == base || entry[:id].to_s.start_with?(prefix)) && !entry[:id].to_s.include?("~sub-") }
        end

        rows.sort_by { |entry| entry[:timestamp] }.reverse
      end

      # Rows for the sidebar: what the conversation is about. The one on screen
      # is always present, even before it is saved.
      #
      # The history is drawn as two sections. `pinned` is the hand-kept list,
      # ordered by when each conversation was pinned; `recent` is everything
      # else, newest first. A pinned conversation does not appear in `recent` at
      # all — it is in one list or the other, never both.
      #
      # `page` counts the blocks of recent rows already asked for, not the one
      # block on screen: "load more" appends, so a reader who asked for forty
      # keeps the first twenty above them. The whole loaded run is returned, a
      # block at a time, so a reload lands back where the reader was.
      def session_groups(slug, current_sid, page: 1)
        entries = sessions_for(slug)
        pinned = drawn_pinned(entries)
        recent = recent_entries(entries, current_sid, drawn: pinned)
        pages = recent_pages(recent)
        loaded = page.to_i.clamp(1, pages)
        window = recent.first(loaded * RECENT_PAGE)
        {
          pinned: pinned.map { |entry| session_row(entry, current_sid) },
          recent: window.map { |entry| session_row(entry, current_sid) },
          page: loaded,
          pages: pages,
          more: loaded < pages,
          next_page: loaded + 1,
          recent_total: recent.size,
          pinned_limit: PINNED_LIMIT,
          current: current_sid
        }
      end

      # The pinned rows the sidebar actually draws, newest pin first. Both the
      # full sidebar and the "load more" block measure the list from here, so the
      # two always agree on where the recent list starts.
      def drawn_pinned(entries)
        entries.select { |entry| pinned_entry?(entry) }
               .sort_by { |entry| entry[:pinned_at].to_s }
               .reverse
               .first(PINNED_LIMIT)
      end

      # One block of the recent list, the way the "load more" button asks for
      # it: exactly the rows after the ones already on screen, so appending the
      # answer cannot repeat a row. Past the last block the answer is empty —
      # the list shrank while the button was in hand — and the control goes
      # away with it.
      def recent_block(slug, current_sid, page)
        entries = sessions_for(slug)
        recent = recent_entries(entries, current_sid, drawn: drawn_pinned(entries))
        pages = recent_pages(recent)
        page = page.to_i
        page = 1 if page < 1
        rows = recent[(page - 1) * RECENT_PAGE, RECENT_PAGE] || []
        {
          rows: rows.map { |entry| session_row(entry, current_sid) },
          page: page,
          pages: pages,
          more: page < pages,
          next_page: page + 1,
          recent_total: recent.size,
          current: current_sid
        }
      end

      # Everything that is not pinned, newest first. A conversation that has
      # not been written yet has no row in the index, so the page supplies one;
      # it belongs at the top, where a reader who just pressed "+" looks.
      #
      # A conversation already drawn in the pinned section is not supplied
      # again: that drew the same conversation twice and rang both rows as the
      # open one, which read as two sessions being active at once.
      def recent_entries(entries, current_sid, drawn: [])
        recent = entries.reject { |entry| pinned_entry?(entry) }
        in_pinned = drawn.any? { |entry| entry[:id] == current_sid }
        unless in_pinned || recent.any? { |entry| entry[:id] == current_sid }
          recent.unshift({ id: current_sid, title: "", timestamp: nil, pinned_at: nil })
        end
        recent
      end

      def recent_pages(recent)
        [ (recent.size + RECENT_PAGE - 1) / RECENT_PAGE, 1 ].max
      end

      # The flat list the older callers expect: the pinned section followed by
      # the loaded recent ones. Tests and the header name only need to look for
      # the active row, not at how the sidebar draws its sections.
      def session_rows(slug, current_sid, page: 1)
        groups = session_groups(slug, current_sid, page: page)
        groups[:pinned] + groups[:recent]
      end

      def session_row(entry, current_sid)
        title = entry[:title].to_s.strip
        {
          id: entry[:id],
          label: title.empty? ? untitled_session : title,
          pinned: pinned_entry?(entry),
          # A conversation with no archive row yet has no stamp and nothing to
          # pin; the row is drawn for the reader who just opened it.
          pinnable: !entry[:timestamp].nil?,
          active: entry[:id] == current_sid,
          # The row that is open is, by definition, seen: a mark on it would sit
          # there until the next reload and say nothing.
          unread: !entry[:unread_at].to_s.strip.empty? && entry[:id] != current_sid
        }
      end

      def pinned_entry?(entry)
        !entry[:pinned_at].to_s.strip.empty?
      end

      # The name of the conversation on screen: the prompt that opened it. It is
      # the one thing that tells two sessions of the same persona apart, so it
      # is used as the name everywhere — sidebar, header, tab — instead of
      # showing it in one place and an id everywhere else.
      #
      # Asked of the whole list rather than of one page: the page a reader is
      # looking at depends on the sidebar's state, and the header does not.
      def session_label(slug, sid)
        entry = sessions_for(slug).find { |candidate| candidate[:id] == sid }
        return untitled_session if entry.nil?

        title = entry[:title].to_s.strip
        title.empty? ? untitled_session : title
      end

      # The name a session carries once it has one; nil while it is still
      # untouched, so callers can fall back to the persona alone. Decided from
      # the title itself rather than by comparing with the drawing above: two
      # languages word that label two ways, and a prompt a reader really wrote
      # must not be mistaken for the placeholder.
      def named_session_label(slug, sid)
        entry = sessions_for(slug).find { |candidate| candidate[:id] == sid }
        title = entry && entry[:title].to_s.strip
        title.nil? || title.empty? ? nil : title
      end

      def elapsed_label(epoch)
        Rubot::Formatting.age(epoch)
      end

      def persona_rows(current_slug)
        counts = unread_counts
        personas.map do |key, persona|
          {
            slug: key,
            label: persona.label,
            emoji: persona.emoji_or,
            active: key == current_slug,
            # How many conversations of this persona finished something unseen.
            # Zero for a roster read before the first turn, which is why the
            # badge only draws when it is positive.
            unread: counts[key].to_i,
            model: persona.model || persona.preset || "default"
          }
        end
      end

      # Sessions with something new, counted per persona. The persona of an id is
      # `PersonaStore.key_for_session`'s answer — the same rule every other
      # screen uses — so a Telegram topic's id is not silently counted twice.
      def unread_counts
        store = Rubot::Archive.current
        return {} unless store

        store.unread_sessions.each_with_object(Hash.new(0)) do |row, counts|
          slug = PersonaStore.key_for_session(row[:id])
          counts[slug] += 1 if slug
        end
      end

      # Everything waiting, across every persona. The roster counts per persona
      # because the roster is a choice between them; the drawer's handle speaks
      # for the install, because the drawer is where all of them live.
      def unread_total
        unread_counts.values.sum
      end

      # Both tool contexts are bound before a turn starts: the file tool at the
      # folder the page serves pictures from, the cron tool at the workspace the
      # reminder belongs to. Each lives with the slice that owns that tool.
      def prepare_delivery(sid)
        bind_file_delivery(sid)
        bind_cron_delivery(sid)
        bind_loop_runner(sid)
      end

      # The sidebar and the header after a turn. A conversation is named by its
      # first prompt, and that prompt only exists in the session file once the
      # turn has been saved — so both have to be re-rendered from the server
      # rather than patched in the browser. Each fragment carries the
      # out-of-band marker, so htmx replaces the element wherever it sits.
      def sidebar_markup(sid)
        slug = owner_slug(sid)
        return "" unless slug

        persona = persona_store&.[](slug)
        persona_label = persona ? persona.label : slug.capitalize
        label = named_session_label(slug, sid)

        nav = View.render("_sessions",
                          groups: session_groups(slug, sid),
                          token_query: token_query)
                  .sub(%(<nav class="sessions" id="sessions">),
                       %(<nav class="sessions" id="sessions" hx-swap-oob="true">))
        # The count on the roster belongs to the same fact as the dot on the
        # row — a conversation of this persona finished unseen — so it travels
        # with the same swap. Without it the number goes stale the moment a
        # mark is written, and only a reload would say how many are waiting.
        rail = View.render("_rail", personas: persona_rows(slug), token_query: token_query)
                   .sub(%(<ul class="rail-list" id="rail-list">),
                        %(<ul class="rail-list" id="rail-list" hx-swap-oob="true">))
        # The header carries the handle that opens the drawer, and the handle
        # wears the install's count — one number across every persona, because
        # on a phone the roster is behind it. Swapping the header is what keeps
        # that number honest after a turn or a mark, so the badge needs no swap
        # of its own.
        head = View.render("_chathead",
                           persona_emoji: persona ? persona.emoji_or : "🤖",
                           persona_label: persona_label,
                           session_label: label,
                           session_id: sid,
                           token_query: token_query,
                           unread_total: unread_total,
                           document_title: document_title(persona_label, label))
                   .sub(%(<header class="chat-head" id="chat-head"),
                        %(<header class="chat-head" id="chat-head" hx-swap-oob="true"))

        nav + rail + head
      end

      # Tell every open page that the sidebar has changed. Each page is answered
      # in its own session id, because that is what decides which row is the
      # active one.
      #
      # Every page, not only the persona's own: the roster and the drawer's
      # count are about the install, so a turn finishing in one persona is news
      # on a page showing another — the avatar there gains a number. The rows a
      # page draws are still its own, so the extra work is a re-render, not a
      # page it should not see.
      def broadcast_sessions
        subs = @event_mutex.synchronize { @event_subs.dup }
        subs.each do |sid, queue|
          markup = sidebar_markup(sid)
          queue << markup unless markup.to_s.empty?
        end
      end

      # A finished turn that nobody had on screen gets a mark in the list.
      #
      # The open pages are the signal: each page holds one event stream,
      # subscribed with the session id it is showing, so a stream with that id
      # means the conversation is being watched and the mark would be about
      # something the reader already saw. Returns whether it marked anything,
      # which is what decides the broadcast.
      def mark_unread_unless_watched(sid)
        store = Rubot::Archive.current
        return false unless store
        return false if watched?(sid)

        store.mark_unread(sid)
        true
      end

      def watched?(sid)
        @event_mutex.synchronize { @event_subs.any? { |sub, _queue| sub == sid } }
      end
    end
  end
end
