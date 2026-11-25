# frozen_string_literal: true

module Rubot
  module Web
    # A turn: the unit a prompt becomes. It is created from a request, run on a
    # thread of its own, drawn as it goes, and watched by the browser over one
    # Server-Sent Events connection.
    #
    # The stream is an idempotent render of the turn's current state, which is
    # what makes a reconnect safe: replaying from the top paints the same
    # content. An idle page holds a second stream whose events carry the sidebar
    # and the footer whole, because a roster or a delegated run can change with
    # no turn behind it.
    #
    # Included into the channel and left public on purpose: the router, the
    # views and the tests all call these methods directly.
    module Turns
      # How many turns one process keeps in memory. A turn is held until the
      # page that watches it is done, and a conversation left open for a day
      # would otherwise keep every one of them.
      MAX_TURNS = 30
      # How often an idle page's event stream says something, so a connection
      # sitting in a proxy is not closed for being quiet.
      EVENT_HEARTBEAT = 20

      # --- turn lifecycle ------------------------------------------------

      # The turn this session is running right now, if any. Nothing is written
      # to the session file until a turn ends, so without this a page opened —
      # or refreshed — mid-answer would show a conversation that looks as if
      # the last prompt was never sent. The fragment it draws opens the stream
      # again, so the reader is back on the same turn rather than watching a
      # frozen copy of it.
      def live_turn(sid)
        @turns_mutex.synchronize do
          turn = @turns[@active[sid]]
          turn && !turn.closed? ? turn : nil
        end
      end

      # A turn in flight is drawn from the turn itself, because the session file
      # may not hold that prompt yet. It usually does: the user message is
      # written when the turn starts, so a page opened a second later holds the
      # prompt *and* the live turn, and drew it twice — the "sometimes double
      # prompt" seen after switching persona mid-turn and coming back. Whichever
      # of the two arrived first, only one bubble is drawn: the transcript keeps
      # it when it is there, and the turn supplies it otherwise.
      #
      # The last prompt in the file is the one this turn is answering, not the
      # last entry: by the time the reader comes back the file usually holds the
      # answer's opening rounds too. A second prompt cannot be sent while a turn
      # runs (the server answers 409), so a repeated text cannot be mistaken for
      # an older turn.
      def prompt_in_tail?(entries, live)
        last_prompt = entries.reverse.find { |entry| entry[:kind] == :prompt }
        return false unless last_prompt

        last_prompt[:text].to_s.strip == live.prompt.to_s.strip
      end

      # A running turn writes each round to the session as it goes and keeps
      # the same rows in memory, so a page opened mid-turn held both: the
      # transcript drew the calls the file already had, and the turn drew them
      # again under the same prompt. When the prompt being answered is the last
      # one written, the turn owns the whole tail — the transcript drops it and
      # the turn draws it from its own items. Anything older stays where it is,
      # including the earlier turns' calls, which no one is holding in memory.
      def drop_running_tail(page, live)
        return page unless prompt_in_tail?(page[:entries], live)

        last = page[:entries].rindex { |entry| entry[:kind] == :prompt }
        return page unless last

        page.merge(entries: page[:entries][0...last])
      end

      def create_turn(req, res, sid)
        return not_found(res) unless owner_slug(sid)

        text = form(req, "message").strip
        if text.empty?
          res.status = 400
          res.body = %(<div class="notice"><div class="error">#{CGI.escapeHTML(I18n.t("web.turn.empty_message"))}</div></div>)
          return
        end

        turn = Turn.new(id: "t#{SecureRandom.hex(6)}", session_id: sid, prompt: text,
                        tool_output: session_tool_output(sid))

        @turns_mutex.synchronize do
          # A second POST while one turn is running must not queue behind it:
          # the browser is expected to steer or stop instead.
          if @active[sid]
            res.status = 409
            res.body = %(<div class="notice"><div class="error">#{CGI.escapeHTML(I18n.t("web.turn.busy"))}</div></div>)
            return
          end
          # A compaction rewrites the transcript this prompt would be appended
          # to, so a prompt must not start while one is running. The browser
          # normally holds the composer closed, but a dropped stream can make it
          # let go early; the truth is kept here, where the transcript is.
          if @compacting[sid]
            res.status = 409
            res.body = %(<div class="notice"><div class="error">#{CGI.escapeHTML(I18n.t("web.turn.compacting"))}</div></div>)
            return
          end

          @turns[turn.id] = turn
          @active[sid] = turn.id
          prune_turns
        end

        Thread.new { run_turn(turn, text) }

        res["Content-Type"] = "text/html; charset=utf-8"
        # The row above the field is filled here, once, because this response is
        # the only moment the page is told a turn has begun. Nothing re-sends it
        # while the turn runs (the row never changes, and a replacement only made
        # the text flash), so without this the band stayed empty for every prompt
        # typed into the page and "Working…" was seen only after a refresh.
        res.body = working_markup(turn.epoch) +
                   View.render("_turn", turn: turn, text: text, token_query: token_query)
      end

      # The turn the browser is following, in one place: the agent reads the
      # prompt, and everything it hands back lands in the timeline. `send_files`
      # is aimed at this conversation first — a picture the agent sends is the
      # whole point of this channel's attachment folder.
      def run_turn(turn, text)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # The agent asking to be announced at the end: nil until it does, then
        # the line it wants said. A request outranks the clock below — the
        # reader asked, so the wait is not what decides.
        announcement = nil
        # An automatic compaction rewrites the transcript mid-turn. The seam is
        # drawn live in the timeline, but the footer's context figure goes
        # stale, so remember that it happened and push a fresh usage row once
        # the answer is complete (see the end of this method). No reload: the
        # reader keeps their place and the percentage moves on its own.
        compacted = false
        Thread.current[:rubot_web_turn] = turn
        prepare_delivery(turn.session_id)

        response = process_message(
          text,
          session_id: turn.session_id,
          on_tool_call: lambda do |name, args, _snapshot|
            announcement = args.to_h["message"].to_s.strip if name.to_s == "notify"
            announcement ||= ""
            turn.tool_started(name, ToolCaption.caption(name, args),
                              op: args.to_h["operation"], title: ToolCaption.tooltip(name, args))
          end,
          on_tool_result: ->(name, result, diff) { tool_finished(turn, name, result, diff) },
          on_reasoning: ->(delta) { turn.thinking(delta) },
          on_subagent: lambda do |info|
            turn.subagent(info)
            turn.subagent_item(info)
          end,
          # A delegation the channel is expected to run. It leaves this turn
          # behind on purpose: the run gets a session actor of its own, so the
          # reader can send the next prompt while it works.
          on_delegate: ->(request) { start_delegate(turn.session_id, request) },
          # A loop the channel is expected to work, for the same reason and in
          # the same shape: the tool runs inside the session Ractor, where a
          # thread, a pool and a lambda cannot be handed to it, so the request
          # travels out as data and the run happens on this side.
          on_loop: ->(request) { handle_loop_request(turn.session_id, request) },
          on_compaction: lambda do |result|
            turn.compaction(result)
            compacted = true
          end,
          on_compaction_start: -> { turn.compaction_start },
          on_compaction_failed: -> { turn.compaction_failed },
          on_usage: ->(report) {
            markup = usage_markup_from(report)
            turn.emit(:usage, markup) if markup
          },
          on_confirm: ->(name, _args, reason) { turn.ask_confirm(name, reason) }
        )

        # The footer figures move with every request, so the row is re-rendered
        # once the turn has nothing left to spend — before :done, which ends
        # the stream.
        turn.emit(:usage, usage_markup(turn.session_id))
        # The first prompt names the conversation, and that name only exists
        # once the turn has been written to the session file.
        turn.emit(:sidebar, sidebar_markup(turn.session_id))
        turn.finish(response)
        # An automatic compaction rewrote the transcript mid-turn, so the
        # footer's context figure is stale. Push the fresh row over /events as
        # an OOB swap; the seam itself was already drawn live in the timeline.
        # No reload: the answer is complete and the reader keeps their place.
        broadcast_usage(turn.session_id) if compacted
        # A turn that finished while the conversation was not on screen gets a
        # mark in the list; every open page is told, so the row and the counts
        # appear without a reload.
        broadcast_sessions if mark_unread_unless_watched(turn.session_id)
        # Measured to the moment the answer was complete, not to the moment the
        # page finished drawing it — the reader waited for the first, and a slow
        # network is not a slow turn.
        notify_turn_end(turn, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
                        requested: announcement)
      rescue StandardError => e
        turn.fail_with(handle_error(e, text))
      ensure
        Thread.current[:rubot_web_turn] = nil
        @turns_mutex.synchronize do
          @active.delete(turn.session_id) if @active[turn.session_id] == turn.id
        end
        # The conversation is idle again, which is the moment a batch that came
        # back while it was working can be reported. Waiting for it here rather
        # than queueing behind the turn is what keeps the report's own deadline
        # about the report: a message that sits in an actor's inbox is not a slow
        # provider, and timing it as one threw it away.
        report_later(turn.session_id)
      end

      # The row that says a turn is running, marked for the band it belongs to
      # rather than for the thread it travels beside. The turn fragment is a
      # fragment of the conversation; this row is a state of the page, and htmx
      # only knows that from the out-of-band marker.
      def working_markup(since)
        View.render("_working", since: since)
            .sub(%(<div class="working-band" id="working">),
                 %(<div class="working-band" id="working" hx-swap-oob="true">))
      end

      def prune_turns
        return if @turns.size <= MAX_TURNS

        stale = @turns.select { |_id, turn| turn.closed? }.keys
        stale = stale.first(stale.size - MAX_TURNS) if stale.size > MAX_TURNS
        stale.each { |id| @turns.delete(id) }
      end

      def tool_ok?(result)
        !result.to_s.start_with?("ERROR")
      end

      # A tool row, and — when the tool handed files back — the files
      # themselves, drawn under the row that produced them. `send_files` names
      # several in one result; they land in the same strip, in the order sent.
      #
      # A call that changed a file also carries its before/after, which is
      # drawn between the two: the hunks belong to the edit, and the files a
      # call produced come after it.
      def tool_finished(turn, name, result, diff = nil)
        turn.tool_finished(name, tool_ok?(result))
        add_diff(turn, diff)
        sent_attachments(name, result, turn.session_id).each { |file| turn.add_attachment(**file) }
        if name.to_s == "instagram" && result.to_s.include?(Tools::Instagram::CONNECT_MARKER)
          turn.add_instagram_card
        end
      end

      # The fragment for a file the call changed, or nothing when it changed
      # none. A delete arrives with `after` nil and every line it had renders as
      # a removal; a create arrives with `before` nil and every line is new.
      def add_diff(turn, spec)
        return unless spec.is_a?(Hash)

        html = Rubot::Web::Diff.render(spec["before"], spec["after"], path: spec["path"])
        turn.add_diff(html) if html
      rescue StandardError => e
        warn "[web] diff: #{e.class}: #{e.message}"
      end

      # --- sse -----------------------------------------------------------

      def stream_turn(res, turn_id)
        turn = @turns_mutex.synchronize { @turns[turn_id] }
        return not_found(res) unless turn

        res.status = 200
        res["Content-Type"] = "text/event-stream"
        res["Cache-Control"] = "no-cache, no-store"
        res["Connection"] = "keep-alive"
        res["X-Accel-Buffering"] = "no"
        res.chunked = true

        res.body = proc do |out|
          # A page that has just been painted already shows the turn's current
          # state, so the stream continues from here instead of replaying the
          # log: a refresh mid-answer lands on the latest text at once.
          #
          # `state` is this connection's memory of what was last sent, which is
          # what lets a streaming flush carry one item instead of the timeline.
          state = { order: nil, sig: nil }
          turn.each_event(from_now: true) do |type, payload|
            break unless @running

            write_event(out, turn, type, payload, state)
          end
        rescue IOError, Errno::EPIPE, Errno::ECONNRESET
          nil
        end
      end

      # A page that is open and idle has no turn to carry news, and news still
      # arrives: a fired job that opens a conversation. One connection per page
      # stays open for it, and what it carries is the sidebar itself, marked
      # out of band, so the list redraws without a reload and the page never
      # asks again.
      def stream_events(res, req)
        sid = utf8(req.query["sid"].to_s)
        return not_found(res) unless sid.empty? || owner_slug(sid)

        queue = Queue.new
        res.status = 200
        res["Content-Type"] = "text/event-stream"
        res["Cache-Control"] = "no-cache, no-store"
        res["Connection"] = "keep-alive"
        res["X-Accel-Buffering"] = "no"
        res.chunked = true

        listen_for_events(sid, queue)

        res.body = proc do |out|
          # What the page already shows, sent first: a stream that was dropped
          # and reopened must not sit on a list that has moved on.
          event_stream_opening(sid).each do |type, markup|
            sse(out, type.to_s, markup)
          end

          loop do
            break unless @running

            item = queue.pop(timeout: EVENT_HEARTBEAT)
            if item.nil?
              # A comment line costs nothing and keeps the connection from
              # being closed for silence by whatever sits in between.
              out.write(": keepalive\n\n")
              out.flush if out.respond_to?(:flush)
            else
              type, markup = item.is_a?(Array) ? item : [ :sidebar, item ]
              sse(out, type.to_s, markup)
            end
          end
        rescue IOError, Errno::EPIPE, Errno::ECONNRESET
          nil
        ensure
          stop_listening_for_events(queue)
        end
      end

      # What a page is told first, when it opens or reopens its idle stream. The
      # roster, because a page that was away has missed moves; and, when nothing
      # is being summarized, the release for the compacting flag. That release
      # is what makes the lock self-healing: a page whose stream dropped while a
      # compaction ended would otherwise keep its composer shut until someone
      # reloaded, and a manual compaction would look like a dead button.
      #
      # The footer's delegated runs are here for the same reason. They are the
      # one thing on the page that only ever arrives as a diff: a run's progress
      # rewrites the slots inside the sheet and nothing else. A single event lost
      # — a phone that put the page to sleep, a connection that dropped between
      # two runs finishing — left those rows frozen, so a run that had come back
      # still wore the mark it had while it worked. Drawing the sheet whole on
      # every (re)connect is what repairs that without a reload.
      def event_stream_opening(sid)
        opening = [ [ :sidebar, sidebar_markup(sid) ] ]
        opening << [ :"subagent-sheet", subagent_sheet_markup(subagent_runs_for_page(sid)) ] unless sid.to_s.empty?
        # The loop panel is the other one that only ever arrives as a diff: a
        # loop begins on a thread nobody is watching, and a page that dropped
        # its stream while that happened would keep a footer without the toggle
        # that watches it until someone reloaded.
        opening << [ :"loop-sheet", loop_sheet_markup(sid) ] unless sid.to_s.empty?
        opening << [ :"compact-done", "done" ] unless compacting?(sid)
        opening
      end

      def listen_for_events(sid, queue)
        @event_mutex.synchronize { @event_subs << [ sid, queue ] }
      end

      def stop_listening_for_events(queue)
        @event_mutex.synchronize { @event_subs.reject! { |_sid, other| other.equal?(queue) } }
      end

      def write_event(out, turn, type, payload, state = {})
        case type
        when :turn
          # Only the rows that moved travel. A row added at the end is appended,
          # a row whose content changed is replaced where it stands, and a row
          # that left is deleted — all as out-of-band fragments, so a page that
          # is eight rounds into a turn never receives the seven rounds behind
          # it again. Measured on the turn this replaced: 31 rows, ~32KB per
          # structural change, now a couple of KB.
          items = turn.items
          update = turn_updates(turn, items, state)
          if update.nil?
            remember(state, items)
            sse(out, "turn", render_timeline(turn, items))
          elsif !update.empty?
            sse(out, "turn-patch", update)
          end
        when :confirm
          sse(out, "confirm", View.render("_confirm", prompt: turn.confirm_prompt, turn_id: turn.id))
        when :notice
          sse(out, "notice", payload.to_s)
        when :usage
          # An out-of-band swap: the reader applies it to #usage, so the turn
          # itself is unaffected and the slot stays empty.
          sse(out, "usage", payload.to_s)
        when :"subagent-sheet"
          # Same trick for the footer's delegated runs: they outlive the turn,
          # so they cannot ride on the turn event.
          sse(out, "subagent-sheet", payload.to_s)
        when :"loop-sheet"
          # And for the loop panel, which is drawn from files a turn can change
          # without telling the channel: pausing a loop is one write to its
          # state file.
          sse(out, "loop-sheet", payload.to_s)
        when :sidebar
          # Same trick for the sidebar and the header: what the conversation is
          # called is only known after the first turn has been saved.
          sse(out, "sidebar", payload.to_s)
        when :heartbeat
          out.write(": keepalive\n\n")
          out.flush if out.respond_to?(:flush)
        when :done
          # The one full render of the turn: the reader ends on exactly the
          # timeline the server would have drawn, whatever the incremental
          # updates did or did not land. It is also the resync point, so a
          # missed fragment costs one turn at worst.
          items = turn.items
          remember(state, items)
          sse(out, "turn", render_timeline(turn, items))
          # The footer's own sheet is not touched here: a background run has
          # already reported itself through the jobs registry, and a synchronous
          # one has no footer row at all. Writing it from the turn as well would
          # put two sources on one element.
          #
          # The loop panel is the one footer fact a turn can change without
          # telling anyone: pausing a loop is a single write to its state file,
          # and a panel left open would keep drawing a loop the reader had
          # already stopped. Once per turn is the cheap, certain moment, and the
          # sheet redraws only its rows when the toggle's visibility has not
          # changed, so an open panel keeps its place.
          push_loop_sheet(turn.session_id)
          sse(out, "done", " ")
        end
      end

      def render_timeline(turn, items = nil)
        persona = owner_slug(turn.session_id) || default_slug
        View.turn_body(turn, items: items, token_query: token_query, ig_persona: persona,
                             **ig_account_locals(persona))
      end

      # The same rows, drawn as their own out-of-band fragments: `:append` puts
      # a new row at the end of the timeline, `:replace` swaps one in place by
      # its id. Nothing else about the turn is re-sent.
      def render_items(turn, items, mode)
        persona = owner_slug(turn.session_id) || default_slug
        View.render("_timeline", items: items, token_query: token_query,
                                  item_prefix: "t-#{turn.id}", item_oob: mode,
                                  ig_persona: persona, **ig_account_locals(persona))
      end

      # What this reader has not seen yet, as out-of-band fragments, or nil
      # when the page has to be redrawn whole.
      #
      # A row is identified by `item[:seq]` — a number the turn gives it once
      # and never reuses — so a row the compact view drops and later puts back
      # is recognised as the row it was, not as a new one in the wrong place.
      #
      # The whole timeline is the answer in two cases: a reader that has not
      # been written to yet, and a page whose rows are no longer the head of
      # the timeline (an old row reappearing in the middle), where appending
      # would put the new rows in the wrong order.
      def turn_updates(turn, items, state)
        seqs = items.map { |item| item[:seq] }
        return nil if state[:order].nil? || seqs.any?(&:nil?)

        order = state[:order]
        sigs = state[:sig] || {}
        now = {}
        items.each { |item| now[item[:seq]] = item_signature(item) }

        kept = order.select { |seq| now.key?(seq) }
        return nil unless kept == seqs.first(kept.length)

        gone = order.reject { |seq| now.key?(seq) }
        changed = items.select { |item| sigs.key?(item[:seq]) && sigs[item[:seq]] != now[item[:seq]] }
        added = items.reject { |item| sigs.key?(item[:seq]) }

        body = +""
        gone.each { |seq| body << %(<div hx-swap-oob="delete:##{item_id(turn, seq)}"></div>) }
        body << render_items(turn, changed, :replace) unless changed.empty?
        body << render_items(turn, added, :append) unless added.empty?

        # Only once the fragments exist: a render that raised leaves the reader
        # where it was, and the next flush offers the same rows again.
        state[:order] = seqs
        state[:sig] = now
        body
      end

      # What the page was last given, so the next flush can tell what moved.
      def remember(state, items)
        state[:order] = items.map { |item| item[:seq] }
        state[:sig] = items.each_with_object({}) do |item, sigs|
          sigs[item[:seq]] = item_signature(item)
        end
      end

      # What counts as "this row changed". The fade-in delay is per-draw
      # bookkeeping rather than content: it moves a few milliseconds at a time
      # for a row that was only just added, and re-sending a row whose mark did
      # not change would be churn. Everything else — the text, a tool's state,
      # a thought closing — is the row.
      def item_signature(item)
        item.reject { |key, _| key == :swap_ms }.hash
      end

      # The id the row is drawn with. The same string the template writes (see
      # View#item_attrs), which is why the escaping is the same no-op for the
      # hex turn ids the channel hands out.
      def item_id(turn, seq)
        "t-#{turn.id}-#{seq}"
      end

      def sse(out, event, html)
        body = html.to_s
        body = " " if body.empty?

        out.write("event: #{event}\n")
        body.each_line(chomp: true) { |line| out.write("data: #{line}\n") }
        out.write("\n")
        out.flush if out.respond_to?(:flush)
      end

      # --- control -------------------------------------------------------

      def control_turn(req, res, turn_id, action)
        turn = @turns_mutex.synchronize { @turns[turn_id] }
        return not_found(res) unless turn

        case action
        when "steer"
          text = form(req, "text").strip
          return bad_request(res) if text.empty?

          if steer_session(turn.session_id, text)
            # The page draws the message the moment it is handed over, rather
            # than waiting for the model to reach it: a steering message that
            # only appeared after a refresh read as one that was never sent.
            turn.add_steer(text)
            res.status = 204
          else
            res.status = 409
          end
        when "stop"
          cancel_session(turn.session_id)
          res.status = 204
        when "confirm"
          turn.answer_confirm(%w[1 true yes approve].include?(form(req, "value")))
          res.status = 204
        end

        res.body = ""
      end
    end
  end
end
