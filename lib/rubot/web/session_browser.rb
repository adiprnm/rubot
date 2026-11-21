# frozen_string_literal: true

module Rubot
  module Web
    # The sidebar: which conversations a persona owns, what each is called, how
    # the pinned list and the paginated recent list are cut, and how an unread
    # mark is decided.
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
      UNTITLED_SESSION = "Sesi baru"

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
        return true if (store = Session.store) && store.session?(sid)

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
        rows = if (store = Session.store)
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
          label: title.empty? ? UNTITLED_SESSION : title,
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
        return UNTITLED_SESSION if entry.nil?

        title = entry[:title].to_s.strip
        title.empty? ? UNTITLED_SESSION : title
      end

      # The name a session carries once it has one; nil while it is still
      # untouched, so callers can fall back to the persona alone.
      def named_session_label(slug, sid)
        label = session_label(slug, sid)
        label == UNTITLED_SESSION ? nil : label
      end

      def elapsed_label(epoch)
        Rubot::Formatting.age(epoch)
      end
    end
  end
end
