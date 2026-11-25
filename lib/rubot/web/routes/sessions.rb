# frozen_string_literal: true

module Rubot
  module Web
    module Routes
      # The conversation routes: opening one, creating one, renaming it, pinning
      # it, asking it to summarize itself, and redrawing the page beside it.
      #
      # Every one of them is scoped to an owner: a session id names its persona,
      # and a page that does not belong to this channel answers 404 rather than
      # leaking another channel's conversation.
      #
      # Included into the channel and left public on purpose: the router calls
      # these directly and the tests do the same.
      module Sessions
        # The pin cap lives with the sidebar that enforces it; unpinning the
        # oldest reads the same number.
        PINNED_LIMIT = Rubot::Web::SessionBrowser::PINNED_LIMIT

      # --- page ----------------------------------------------------------

      # /p/<slug> is a doorway, not a page: it opens the persona's newest
      # conversation, so the avatar in the rail always lands somewhere usable.
      def open_persona(res, slug, req)
        return not_found(res) unless known_slug?(slug)

        latest = sessions_for(slug).first
        redirect(res, "/s/#{latest ? latest[:id] : session_id(slug)}", req)
      end

      # The "+" button in the sidebar. It only mints an id and navigates; the
      # session file appears with the first message.
      def create_session(res, slug, req)
        return not_found(res) unless known_slug?(slug)

        redirect(res, "/s/#{new_session_id(slug)}", req)
      end

      # Removing a conversation from the sidebar. The session file is the whole
      # record — messages, title, usage — so the file is what gets deleted; the
      # pool is told to forget the id as well, or an actor holding the old
      # messages would write them back at the end of its next turn. A turn
      # still running is stopped first for the same reason.
      def delete_session(res, sid, req)
        slug = owner_slug(sid)
        return not_found(res) unless slug

        cancel_session(sid)
        @pool&.invalidate(sid)

        path = session_path(sid)
        File.delete(path) if path && File.exist?(path)
        # The archive is the live store now; a file that is not there any more
        # is not enough to make the conversation go away.
        Rubot::Archive.current&.delete_session(sid)

        # Land on what is left: the persona's next newest conversation, or the
        # persona itself when this was the last one. Either way the browser is
        # sent somewhere that still exists.
        remaining = sessions_for(slug).first
        redirect(res, remaining ? "/s/#{remaining[:id]}" : "/p/#{slug}", req)
      end

      # Pinning is how a conversation stops sliding down the list: it moves to
      # the section above, ordered by when it was pinned, and only unpinning
      # puts it back in the flow. The cap is enforced rather than refused —
      # pinning an eleventh conversation unpins the one that has been pinned
      # longest, which is a rule a reader can predict without an error dialog.
      #
      # The archive is where the pin lives, so a channel running without one
      # (JSON files only) answers with the list it already has.
      # The reader naming a conversation by hand. A session's name is not the
      # model's property: the automatic namer only ever fills an empty title, so
      # a name written here is not replaced afterwards (see
      # Agent#run_session_naming). The name is trimmed and flattened — a title is
      # one line in a list, and a newline in it would be drawn as two rows.
      #
      # Refused while a turn runs. The session actor answers requests only
      # between turns, so a rename made now would queue behind the answer and
      # look like a hang; the name is unchanged and can be set once it is done.
      def rename_session(res, sid, req)
        slug = owner_slug(sid)
        return not_found(res) unless slug

        if session_running?(sid)
          # 409 with an empty body: htmx leaves the header alone, so the reader
          # keeps the old name instead of a half-applied one.
          res.status = 409
          res.body = ""
          return
        end

        name = form(req, "name").to_s.gsub(/\s+/, " ").strip
        name = name[0, SessionNamer::MAX_TITLE_CHARS].strip if name.length > SessionNamer::MAX_TITLE_CHARS
        session_for(sid).set_session_title(name) unless name.empty?

        if req && req["HX-Request"].to_s == "true"
          res["Content-Type"] = "text/html; charset=utf-8"
          res["Cache-Control"] = "no-store"
          # The header and the sidebar both carry the name, and the tab reads it
          # from the header: one answer updates all three in place.
          res.body = sidebar_markup(sid)
        else
          redirect(res, "/s/#{sid}", req)
        end
      end

      # Model and thinking level for this session, chosen under the
      # composer. Applied to the live actor so the next turn picks them up,
      # and persisted by the session itself. Refused while a turn is running
      # for the same reason rename is: the actor answers requests only
      # between turns.
      def update_session_settings(res, sid, req)
        slug = owner_slug(sid)
        return not_found(res) unless slug

        if session_running?(sid)
          res.status = 409
          res.body = ""
          return
        end

        model = form(req, "model").to_s.strip
        thinking = form(req, "thinking").to_s.strip

        handle = session_for(sid)
        handle.use_model(model) if !model.empty? && model != session_model(sid) && known_model?(model)
        handle.use_thinking(thinking) unless thinking.empty?

        if req && req["HX-Request"].to_s == "true"
          res["Content-Type"] = "text/html; charset=utf-8"
          res["Cache-Control"] = "no-store"
          res.body = View.render("_session_settings",
                                  session_id: sid, token_query: token_query,
                                  model_choices: model_choices,
                                  session_model: session_model(sid),
                                  session_thinking: session_thinking(sid))
        else
          redirect(res, "/s/#{sid}", req)
        end
      end

      def toggle_pin(res, sid, req)
        slug = owner_slug(sid)
        return not_found(res) unless slug

        if (store = Rubot::Archive.current)
          if form(req, "pin") == "1"
            drop_oldest_pin(slug, sid, store)
            store.pin_session(sid)
          else
            store.unpin_session(sid)
          end
          broadcast_sessions
        end

        # The row that was open when the pin was pressed, which is what the
        # refreshed list has to keep marked. Pin and conversation can differ:
        # the pin is on whichever row was touched, the page is behind it.
        current = form(req, "current")
        current = sid if current.empty? || owner_slug(current) != slug

        page = session_page(req)
        if req && req["HX-Request"].to_s == "true"
          res["Content-Type"] = "text/html; charset=utf-8"
          res["Cache-Control"] = "no-store"
          res.body = View.render("_sessions",
                                 groups: session_groups(slug, current, page: page),
                                 token_query: token_query)
        else
          redirect(res, "/s/#{sid}", req)
        end
      end

      # Keep one persona's pinned list at the ceiling. The oldest stamp is the
      # one that gives way, so the list is the most recent ten things the
      # reader chose to keep rather than the first ten they ever chose.
      def drop_oldest_pin(slug, sid, store)
        others = sessions_for(slug)
                 .select { |entry| pinned_entry?(entry) && entry[:id] != sid }
                 .sort_by { |entry| entry[:pinned_at].to_s }

        while others.size >= PINNED_LIMIT
          stale = others.shift
          break unless stale

          store.unpin_session(stale[:id])
        end
      end

      # Where a conversation lives on disk. One directory holds every session,
      # so the id alone finds the file.
      def session_path(sid)
        dir = @app_config&.sessions_dir
        dir && File.join(dir, "#{sid}.json")
      end

      # The name the browser tab carries. A session that has no name yet does
      # not get a placeholder there — the persona alone is enough for a tab.
      def document_title(persona_label, session_label)
        [ persona_label, session_label ].compact.join(" · ")
      end

      # An older page, fetched by the sentinel at the top of the thread once the
      # reader scrolls within reach of it.
      def render_history(res, sid, req)
        return not_found(res) unless owner_slug(sid)

        before = form(req, "before").to_i
        page = history_page(sid, before: before.positive? ? before : nil)

        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        persona = owner_slug(sid) || default_slug
        res.body = View.render("_history", **page,
                                            older_url: older_url(sid, page[:before]),
                                            token_query: token_query,
                                            ig_persona: persona,
                                            **ig_account_locals(persona))
      end

      # The next block of the recent list, in place of the button that asked for
      # it. Appending is the whole point: a page swap would drop the rows above
      # it, and "load more" that replaces what you were reading is not load
      # more. The control follows the block it just delivered, or disappears
      # when the list has nothing left.
      def render_recent(res, sid, req)
        slug = owner_slug(sid)
        return not_found(res) unless slug

        block = recent_block(slug, sid, session_page(req))
        body = block[:rows].map do |row|
          View.render("_session_row", row: row, token_query: token_query,
                                      page: block[:page], current: block[:current])
        end.join
        if block[:more]
          body += View.render("_recent_more", current: block[:current],
                                               page: block[:next_page],
                                               token_query: token_query)
        end

        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = body
      end

      # The index a search result asked the page to open at, or nil for the
      # ordinary tail of the conversation. 0 is a real index — the first message
      # of a session — which is why this is not a truthiness check.
      def at_index(req)
        return nil if req.nil?

        raw = form(req, "at")
        return nil if raw.empty?

        value = Integer(raw, exception: false)
        value && value >= 0 ? value : nil
      end

      # Which page of the recent list the sidebar is showing. It travels in the
      # URL so a reload keeps the reader where they were.
      def session_page(req)
        return 1 if req.nil?

        value = Integer(form(req, "page"), exception: false)
        value && value.positive? ? value : 1
      end

      # The allowance, fetched when the panel behind the status row is opened.
      # Never cached: it is a reading of an account, not a document.
      def render_quota(res, sid)
        return not_found(res) unless owner_slug(sid)

        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = quota_markup(sid)
      end

      # The footer's loop panel, asked for its rows while it is open. The same
      # partial the page drew (see Web::Loops#loop_rows_markup), so a loop that
      # moved on while nobody was looking arrives without a reload — and a panel
      # whose loops all ended answers with the sentence rather than with an
      # empty list, which is what a reader sees in place of a card.
      def render_loops(res, sid)
        return not_found(res) unless owner_slug(sid)

        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = loop_rows_markup(sid)
      end

      # The reader asking for the pinned prompt to be rebuilt (see
      # Agent#repin_system_prompt): memory written since the session started, an
      # edited skill, a changed AGENTS.md — none of it reaches a running session
      # until the epoch moves, and this is the door.
      #
      # Refused while a turn is running. The actor answers requests only between
      # turns, so a call made now would sit in a queue and look like a hang; and
      # the answer itself needs no repin.
      def repin_prompt(res, sid)
        return not_found(res) unless owner_slug(sid)

        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = View.render("_repin_note", state: repin_state(sid))
      end

      # The reader asking for the transcript to be summarized now, rather than
      # waiting for the automatic threshold. The actor answers requests only
      # between turns, so a press during a running turn would queue behind it
      # and look like a hang; the running turn may also need the very messages
      # that would be summarized away. Refuse it, the way repin does.
      #
      # A successful compaction rewrites the transcript, so the thread the
      # reader is looking at has to be redrawn: HX-Refresh makes htmx reload the
      # page, where the new seam is drawn from the session metadata.
      def compact_session_now(res, sid, req)
        return not_found(res) unless owner_slug(sid)

        htmx = req && req["HX-Request"].to_s == "true"
        # A turn is tracked in two places: @running_handles once process_message
        # starts, and @active as soon as create_turn accepts the prompt. The
        # gap between them is small but real, so check both before touching a
        # transcript a turn may still need. Claim @compacting in the same lock
        # so two quick presses cannot start two compactions against one session.
        claimed = @turns_mutex.synchronize do
          if @active[sid] || @compacting[sid]
            false
          else
            @compacting[sid] = true
            true
          end
        end
        if !claimed || session_running?(sid)
          @turns_mutex.synchronize { @compacting.delete(sid) } if claimed
          if htmx
            res.body = View.render("_compact_note", state: :busy)
          else
            res.status = 409
            res.body = ""
          end
          return
        end

        # The summarizer call is the slow part: several provider requests over
        # a large transcript. It must not hold this response open, or the page
        # cannot refresh until it is done and the button looks hung. Draw the
        # "in progress" row, answer at once, and do the work in the background;
        # the /events stream carries the seam and the reload signal when it is
        # ready. The row is a plain Turn used only as a row accumulator, not a
        # live turn, because no prompt is being answered and there is no turn
        # stream to feed.
        turn = Turn.new(id: "c#{SecureRandom.hex(6)}", session_id: sid)
        turn.compaction_start
        compaction_broadcast(sid, turn)

        Thread.new do
          result = session_for(sid).compact_session
          if result
            turn.compaction(result)
            compaction_broadcast(sid, turn)
            # Say it finished in words, and refresh the footer's context figure
            # in place. No reload: the seam is already drawn live by the row
            # above, and the fresh usage row lands over /events as an OOB swap.
            # The composer was held closed for the whole compaction, so release
            # it here — there is no reload left to reset the flag.
            broadcast_compact_note(sid, :done)
            broadcast_compact_done(sid)
            broadcast_usage(sid)
          else
            compaction_broadcast(sid, nil)
            broadcast_compact_note(sid, :empty)
            broadcast_compact_done(sid)
          end
        rescue StandardError => e
          compaction_broadcast(sid, nil)
            broadcast_compact_note(sid, :error)
            broadcast_compact_done(sid)
          warn "[web] compact: #{e.class}: #{e.message}"
        ensure
          @turns_mutex.synchronize { @compacting.delete(sid) }
        end

        if htmx
          # Accepted: the browser keeps its progress row and waits for the
          # reload event. No HX-Refresh here — that header would make htmx
          # reload now, while the summarizer is still running. An empty body
          # matters: WEBrick rejects a 204 without a Content-Length with
          # LengthRequired, which the browser sees as a failed request.
          res.status = 204
          res.body = ""
        else
          redirect(res, "/s/#{sid}", req)
        end
      rescue StandardError => e
        warn "[web] compact: #{e.class}: #{e.message}"
        res.status = 500
        res.body = ""
      end

      # :busy, :rebuilt or :unpinned — the three things the note can say.
      def repin_state(sid)
        return :busy if session_running?(sid)

        handle = session_for(sid)
        return :unpinned unless handle.respond_to?(:repin_system_prompt)

        handle.repin_system_prompt ? :rebuilt : :unpinned
      rescue StandardError => e
        warn "[web] repin: #{e.class}: #{e.message}"
        :unpinned
      end

      def render_session(res, sid, req = nil)
        slug = owner_slug(sid)
        return not_found(res) unless slug

        # Opening the conversation is what the mark was waiting for. Cleared
        # before the page is drawn so the row it renders is already plain — and
        # the other open pages are told, so their roster, their rows and the
        # drawer's count lose it without a reload. Only when something was
        # really waiting: an ordinary visit changes no other page.
        broadcast_sessions if Rubot::Archive.current&.clear_unread(sid)

        live = live_turn(sid)
        persona = persona_store&.[](slug)
        persona_label = persona ? persona.label : slug.capitalize
        session_label = named_session_label(slug, sid)
        page = history_page(sid, at: at_index(req))
        page = drop_running_tail(page, live) if live && at_index(req).nil?
        live_prompt_shown = live ? prompt_in_tail?(page[:entries], live) : false
        # One report for the whole page. The status row and the panel are the
        # same numbers, so asking the session twice was two round trips into the
        # actor and two scans of the transcript for one glance.
        report = session_report(sid)
        body = View.render(
          "index",
          personas: persona_rows(slug),
          unread_total: unread_total,
          groups: session_groups(slug, sid, page: session_page(req)),
          slug: slug,
          session_id: sid,
          session_short: sid.delete_prefix("web_"),
          persona_label: persona_label,
          persona_emoji: persona ? persona.emoji_or : "🤖",
          emoji_choices: Persona::EMOJI_CHOICES,
          persona_prompt: persona ? persona.system_prompt.to_s : "",
          persona_model: persona_model(persona),
          persona_model_value: persona_model_value(persona),
          persona_thinking: persona_thinking(persona),
          persona_tool_output: persona ? persona.tool_output : Persona::DEFAULT_TOOL_OUTPUT,
          skill_choices: persona_skill_choices(persona),
          skills_dir: skills_dir_label,
          model_choices: model_choices,
          session_model: session_model(sid),
          session_thinking: session_thinking(sid),
          session_label: session_label,
          document_title: document_title(persona_label, session_label),
          page: page,
          older_url: older_url(sid, page[:before]),
          live_turn: live,
          live_prompt_shown: live_prompt_shown,
          usage: metrics_locals(report ? Rubot::UsageReport.metrics(report) : nil),
          usage_facts: usage_facts(report || {}),
          subagent_runs: subagent_runs_for_page(sid),
          loop_runs: loop_rows(sid),
          token_query: token_query,
          ig_persona: slug,
          **ig_account_locals(slug)
        )
        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = View.render("layout", content: body,
                                         title: document_title(persona_label, session_label),
                                         asset_version: asset_version)

        return unless @token

        # WEBrick::Cookie has no httponly accessor in 1.9.x, so the header is
        # written by hand to keep the token out of reach of page scripts.
        res["Set-Cookie"] = token_cookie
      end

      # The manual compaction button is pressed while the page is idle, so there
      # is no live turn to draw its progress into. The always-on /events stream
      # carries the rows instead, out of band, into #compaction-slot in the
      # thread. `turn` holds the row state (a running row, then the seam); nil
      # clears the slot, which is how a failed or empty compaction takes the
      # "in progress" row back off the screen.
      def compaction_broadcast(sid, turn)
        body = turn ? View.turn_body(turn, token_query: token_query) : ""
        markup = %(<div id="compaction-slot" hx-swap-oob="innerHTML">#{body}</div>)
        push_to_session(sid, :notice, markup)
      end

      # The background compaction tells the page to reload once the transcript
      # has been rewritten. A reload event cannot travel as an HTTP header from
      # a request that already answered, so it rides the same /events stream as
      # the progress rows; the browser listens for it and reloads.
      def broadcast_refresh(sid)
        # The payload is the signal itself. The browser reads it from the
        # MessageEvent's `data` rather than from a DOM slot, so an OOB swap
        # landing first cannot take the slot away before the reload is seen.
        push_to_session(sid, :refresh, "reload")
      end

      # An empty or failed compaction leaves the page as it was, so there is no
      # reload to reset the composer. Tell the browser to release the compacting
      # flag explicitly, or the Send button stays disabled until a manual reload.
      def broadcast_compact_done(sid)
        push_to_session(sid, :"compact-done", "done")
      end

      # A compaction that found nothing to do (or failed) leaves the page as it
      # was, so the reader needs the one-line reason under the button. It goes
      # out of band into the note slot, the same way the progress rows reach the
      # thread.
      def broadcast_compact_note(sid, state)
        body = View.render("_compact_note", state: state)
        markup = %(<div id="compact-note" hx-swap-oob="innerHTML">#{body}</div>)
        push_to_session(sid, :"compact-note", markup)
      end
      end
    end
  end
end
