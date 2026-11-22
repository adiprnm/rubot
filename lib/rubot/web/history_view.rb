# frozen_string_literal: true

module Rubot
  module Web
    # The thread a page draws, the figures under the composer, and the
    # allowance behind the account.
    #
    # A transcript is replayed from whatever the session wrote down, not from
    # the live turn: the tool calls the answer was built from, the files they
    # touched, the seams where an automatic compaction cut the conversation,
    # and the pages an older reader scrolls back through. The figures beside
    # it are read from the same report so the row and the panel cannot show
    # two different numbers.
    #
    # Included into the channel and left public on purpose: the views, the
    # live turn's status row and the tests all ask these questions directly.
    module HistoryView
      # How much of a conversation the page draws at once. A long session is a
      # lot of DOM to build for a reader who only ever looks at the end of it,
      # so the page starts at the tail and earlier turns arrive as the reader
      # scrolls up.
      HISTORY_PAGE = 20
      # The provider names its windows by period; a reader asks by length. The
      # provider's own words stay on the wire — this is only how the panel says
      # them.
      QUOTA_METER_LABELS = { "rolling" => "5 jam", "weekly" => "mingguan",
                             "monthly" => "bulanan" }.freeze

      # The conversation as the thread draws it: a prompt, then the turn it
      # produced — including the tool rows. Without replaying the calls a
      # refresh would quietly hide the work the answer was built from.
      def history(sid)
        return [] unless @app_config

        # The thread is drawn from the first message ever written, not from the
        # point compaction stopped sending it to the model. Those are two
        # different things — the rows are still there, only the request starts
        # later — and drawing the second made a long conversation look like it
        # had been cut in half. The seam itself is drawn as a quiet row: the
        # reader asked to read the conversation, and an automatic compaction is
        # part of what happened in it.
        archived = Session.archive_transcript(
          @app_config.workspace,
          sid,
          dir: @app_config.sessions_dir
        )
        messages = archived[:messages]
        results = tool_results(messages)
        diffs = tool_diffs(messages)
        # Each seam names the absolute index of the first message compaction
        # summarized away. Everything before that index is gone from the
        # transcript; the first surviving turn starts at or after it. Collect
        # the seams as cut points so a refresh can hang each one on the first
        # turn that follows the cut, the same place the live timeline drew it.
        seams = Array(archived[:compaction_events]).map do |event|
          {
            cut: event["index"].to_i,
            item: {
              kind: :compaction,
              summarized: event["summarized"].to_i,
              before: event["before"].to_i,
              after: event["after"].to_i,
              elapsed: event["elapsed"].to_f
            }
          }
        end.sort_by { |seam| seam[:cut] }

        turns = []
        current = nil

        # Reading from the top makes the position the absolute index, which is
        # what search hits are addressed by: a hit names a message, and the
        # entry it lands on is what the browser scrolls to.
        messages.each_with_index do |msg, idx|
          case msg["role"]
          when "user"
            text = Session.text_content(msg["content"]).to_s.strip
            next if text.empty?

            turns << { kind: :prompt, text: text, idx: idx, last: idx }
            current = nil
          when "assistant"
            items = []
            text = Session.text_content(msg["content"]).to_s.strip
            items << { kind: :text, text: text, live: false } unless text.empty?
            Array(msg["tool_calls"]).each do |call|
              items.concat(history_tool_items(call, results, diffs, sid))
            end
            next if items.empty?

            # The assistant messages of one prompt belong to one turn: the
            # model answering, calling out, and answering again is a single
            # exchange, and the compact view reads it top to bottom from the
            # only row it knows how to pick — the last call (see
            # Rubot::Web::ToolRows). The log has no clock, so the pause the live
            # turn would draw between two of them is simply not there; what
            # stands between two calls here is whatever the model wrote, which
            # is what the live turn draws when the thought was too quick to
            # mention.
            #
            # An answer to something the reader never said starts a block of its
            # own: a fired job, a batch of sub agents reporting back. It carries
            # the stamp (see Session#add), because its neighbours cannot say so —
            # an answer followed by another answer is also how a turn that is
            # still working looks.
            if current && !msg["background"]
              current[:items].concat(items)
              current[:last] = idx
            else
              current = { kind: :turn, items: items, idx: idx, last: idx }
              turns << current
            end
            # The seam belongs to the turn that carried on after the cut, not
            # to the messages that were summarized away. Hang each seam on the
            # first surviving turn at or past its cut point, once, so a refresh
            # draws the same row the live timeline showed.
            seams.each do |seam|
              next if seam[:placed] || seam[:cut] > current[:idx]

              current[:items] = [ seam[:item] ] + current[:items]
              seam[:placed] = true
            end
          when "tool"
            # A hit inside a tool result lands on the turn that called it, so
            # the entry's own range has to reach past its last assistant round.
            current[:last] = idx if current
          end
        end

        ToolRows.compact?(session_tool_output(sid)) ? compact_tool_rows(turns) : turns
      end

      # A compact persona's transcript shows the same single tool row its live
      # turn showed: the calls one prompt made are collapsed to the last of
      # them. A prompt is the unit, because that is the unit a live turn is.
      def compact_tool_rows(turns)
        turns.map do |turn|
          next turn unless turn[:kind] == :turn

          turn.merge(items: ToolRows.collapse(turn[:items]))
        end
      end

      # Tool output is stored after the call that asked for it, so the id is
      # what pairs a row with how it ended. The same id pairs it with the
      # before/after of the file it changed.
      def tool_results(messages)
        messages.each_with_object({}) do |msg, acc|
          next unless msg["role"] == "tool"

          acc[msg["tool_call_id"].to_s] = msg["content"].to_s
        end
      end

      # The edit a tool made, keyed the same way: Agent#file_ui_diff hangs it on
      # the tool message so a replayed conversation shows what the live one did.
      def tool_diffs(messages)
        messages.each_with_object({}) do |msg, acc|
          next unless msg["role"] == "tool" && msg["ui_diff"].is_a?(Hash)

          id = msg["tool_call_id"].to_s
          acc[id] = msg["ui_diff"] unless id.empty?
        end
      end

      # The row for a call, plus the files below it when send_files handed one
      # back. Two items rather than one, because a picture is drawn as a
      # picture, a document as a card, and the row as a row. An edit adds a
      # third, the hunks of the file it changed, right under the row that
      # changed it.
      def history_tool_items(call, results, diffs, sid)
        function = call["function"] || {}
        name = function["name"].to_s
        arguments = parse_arguments(function["arguments"])
        result = results[call["id"].to_s]

        row = {
          kind: :tool,
          name: name,
          detail: summarize_arguments(arguments),
          state: result.nil? ? :unknown : (tool_ok?(result) ? :ok : :failed),
          elapsed: nil
        }
        op = arguments["operation"].to_s
        # The instagram tool is named after the service, so its `connect`
        # operation would otherwise read "instagram connect connect" — the
        # name already says the service, the op only adds the verb.
        row[:op] = op unless op.empty? || (name == "instagram" && op == "connect")

        items = [ row ]

        spec = diffs[call["id"].to_s]
        html = spec ? Rubot::Web::Diff.render(spec["before"], spec["after"], path: spec["path"]) : nil
        items << { kind: :diff, html: html } if html

        files = sent_attachments(name, result, sid)
        items << { kind: :attachments, list: files } unless files.empty?
        items
      end

      def parse_arguments(raw)
        parsed = JSON.parse(raw.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, TypeError
        {}
      end

      # One page of the conversation: the entries that end at `before` (an
      # index into the full history) and start HISTORY_PAGE entries earlier.
      # `more` says whether anything older is left, so the page can draw the
      # marker that asks for it.
      #
      # `at` is the other way in, and the one a search result uses: the page
      # ends at the entry holding that message, so the hit is the last thing
      # drawn and the turns that led to it are the page above. With both, `at`
      # wins — a hit is where the reader asked to go.
      #
      # `landed` comes back with it because a hit is not always an entry: one
      # turn wraps many messages, so the message the reader clicked has an index
      # of its own and the entry that holds it has an earlier one. The page marks
      # the entry; the anchor can only name the message.
      def history_page(sid, before: nil, at: nil)
        entries = history(sid)
        focus = at.nil? ? nil : focus_index(entries, at)
        stop = if at.nil?
          before ? before.clamp(0, entries.size) : entries.size
        elsif focus
          focus + 1
        else
          entries.size
        end
        start = [ stop - HISTORY_PAGE, 0 ].max

        { entries: entries[start...stop], more: start.positive?, before: start,
          landed: focus ? entries[focus] : nil }
      end

      # The entry a search hit lands on: the prompt that quoted it, or the turn
      # that answered it. A session trimmed since it was indexed has messages
      # the page no longer holds, so the nearest entry above the index is the
      # fallback rather than the tail of the conversation, which would be a
      # page away from what was asked for.
      def focus_index(entries, at)
        entries.index { |entry| entry[:idx].to_i <= at && entry[:last].to_i >= at } ||
          entries.rindex { |entry| entry[:idx].to_i <= at }
      end

      # Where the page older than this one lives. The token rides in the query
      # string like every other link the page writes; the index is what the
      # marker hands back, so no server-side cursor has to survive a restart.
      def older_url(sid, before)
        params = []
        params << "token=#{CGI.escape(@token)}" if @token
        params << "before=#{before}"
        "/s/#{sid}/history?#{params.join("&")}"
      end

      # --- usage ----------------------------------------------------------

      # The status row under the composer: the TUI footer's three figures, with
      # their words replaced by drawn icons. `ctx` rather than `context` — a
      # local named `context` would shadow Scope#context, which ERB calls to
      # get its binding.
      def usage_locals(sid)
        metrics_locals(usage_metrics(sid))
      end

      # The three figures, from whatever report is at hand: a fresh query of the
      # session, or the live report the agent pushes mid-turn.
      def metrics_locals(metrics)
        {
          cost: metrics&.dig(:cost) || "—",
          cache: metrics&.dig(:cache) || "—",
          ctx: metrics&.dig(:context) || "—"
        }
      end

      # The report itself, or nil. Asking a session that is mid-turn is safe:
      # the actor runs the turn on its own thread, so the report is answered
      # rather than queued behind it.
      def session_report(sid)
        session_for(sid).usage_report
      rescue StandardError
        nil
      end

      def usage_metrics(sid)
        Rubot::UsageReport.metrics(session_report(sid))
      rescue StandardError
        nil
      end

      # The panel's copy of the same report: the row is a glance, this is what
      # the glance is made of. Every figure is a string already — the template
      # fills a two-column list, not a calculator.
      def usage_facts(report)
        report = {} unless report.is_a?(Hash)
        cost = report[:cost]
        {
          model: [ report[:model], report[:provider] ].compact.map(&:to_s).reject(&:empty?).join(" · "),
          cost: cost_fact(report),
          breakdown: cost_breakdown(cost),
          saved: cost.is_a?(Hash) && cost["saved"].to_f.positive? ? Rubot::UsageReport.money(cost["saved"]) : "",
          requests: report[:requests].to_i.to_s,
          messages: report[:messages].to_i.to_s,
          tokens_in: Rubot::UsageReport.tokens(report[:prompt_tokens]),
          tokens_out: Rubot::UsageReport.tokens(report[:completion_tokens]),
          reasoning: report[:reasoning_tokens].to_i.zero? ? "" : Rubot::UsageReport.tokens(report[:reasoning_tokens]),
          re_read: Rubot::UsageReport.tokens(report[:last_re_read_tokens]),
          cache: cache_fact(report),
          cache_history: cache_history_fact(report),
          ctx: context_fact(report)
        }
      end

      # The share of each recent request, in order. This is the line that
      # answers "is the cache actually broken?": a run of zeros means the
      # prefix moves on every request, while a single zero after a compaction
      # is expected. Without it a reader sees one number and cannot tell which
      # of the two they are looking at.
      def cache_history_fact(report)
        history = Array(report[:cache_history])
        return "" if history.size < 2

        history.map { |rate| format("%.0f%%", rate.to_f * 100) }.join(" ")
      end

      # The four parts that add up to the total. A reader who sees $0.04 and no
      # idea why has the same question as one who sees a big cache figure. A
      # report with no breakdown at all gets no line: four zeros under a total
      # is noise pretending to be an explanation.
      # The total, marked when it is an upper bound: a model the catalog has no
      # cache-read rate for is priced at the input rate, and a figure that
      # cannot be exact must not look exact.
      def cost_fact(report)
        cost = report[:cost]
        return "belum diketahui" unless cost.is_a?(Hash)

        total = format("$%s", Rubot::UsageReport.money(cost["total"]))
        cost["cache_price_unknown"] ? "#{total} ≤" : total
      end

      def cost_breakdown(cost)
        return "" unless cost.is_a?(Hash)
        return "" unless %w[input cached_input cache_creation output].any? { |key| cost[key].to_f.positive? }

        parts = []
        parts << "masuk #{Rubot::UsageReport.money(cost['input'])}"
        parts << "cache baca #{Rubot::UsageReport.money(cost['cached_input'])}" if cost["cached_input"].to_f.positive?
        parts << "cache tulis #{Rubot::UsageReport.money(cost['cache_creation'])}" if cost["cache_creation"].to_f.positive?
        parts << "keluar #{Rubot::UsageReport.money(cost['output'])}"
        parts.join(" · ")
      end

      def cache_fact(report)
        total = Rubot::UsageReport.tokens(report[:cached_tokens])
        return "#{total} token dari cache" if report[:prompt_tokens].to_i.zero?

        # Two shares, both labelled. The cost above this line is cumulative,
        # so a lone latest-request figure under it reads as if the session had
        # never cached anything — which is how a $2 bill next to "cache 4%"
        # came to look like a bug in the arithmetic.
        format("%.1f%% permintaan terakhir · %.1f%% rata-rata sesi · %s token total",
               report[:cache_hit_rate].to_f * 100,
               report[:cache_hit_rate_session].to_f * 100,
               total)
      end

      def context_fact(report)
        used = Rubot::UsageReport.tokens(report[:context_used])
        window = report[:context_window] ? Rubot::UsageReport.tokens(report[:context_window]) : "?"
        pct = report[:context_percent] ? format(" · %.1f%%", report[:context_percent]) : ""
        "#{used} / #{window}#{pct}"
      end

      # A fragment meant for the status row rather than for the turn: the swap
      # is out-of-band, so it lands on #usage wherever that element sits.
      def usage_markup(sid)
        report = session_report(sid)
        usage_markup_with(usage_locals(sid), facts: report && usage_facts(report))
      end

      # The same row from a report the agent pushed while the turn was still
      # running. The session cannot be asked for it: in actor mode the turn owns
      # the Ractor, so a query would wait for the answer it is meant to price.
      # The report carries a provisional flag for the request still in flight,
      # and the renderer marks it, so a moving estimate never poses as a
      # measurement.
      #
      # Returns nil when there is nothing worth drawing: an empty swap would
      # blank the row instead of leaving the last figure in place.
      def usage_markup_from(report)
        return nil if report.nil?

        # A report pushed while a request is still in flight carries the panel
        # as well, and the panel is 47% of the payload — a breakdown nobody is
        # reading while the answer is still arriving, re-sent several times a
        # second. Only the row's three figures move during a stream; the panel
        # follows with the report that lands at the end of each round, and with
        # the final one, so an open panel still moves — once per request
        # instead of four times a second.
        facts = report[:provisional] ? nil : usage_facts(report)
        usage_markup_with(metrics_locals(Rubot::UsageReport.metrics(report)), facts: facts)
      rescue StandardError
        nil
      end

      # Split out so the marker can be tested without a live session behind it.
      #
      # Two fragments travel together: the row, and — when there is a report to
      # expand — the list inside the panel that opened from it. Without the
      # second, a reader watching the panel during a turn would see the figures
      # in the row move while the breakdown under them stood still.
      def usage_markup_with(locals, facts: nil)
        body = View.render("_usage", **locals)
        body = body.sub(%(<span class="metrics" id="usage">),
                        %(<span class="metrics" id="usage" hx-swap-oob="true">))

        return body unless facts

        facts_html = View.render("_usage_facts", **facts)
                          .sub(%(<dl class="usage-facts" id="usage-facts">),
                               %(<dl class="usage-facts" id="usage-facts" hx-swap-oob="true">))
        body + facts_html
      end

      # --- quota ----------------------------------------------------------

      # The allowance behind the account, which the page cannot compute: it
      # belongs to the provider, and only the provider knows it. Fetched when
      # the panel opens — it costs a request and an actor round trip, and a
      # reader who never opens the panel should not pay for either.
      def quota_markup(sid)
        report = session_for(sid).opencode_usage
        View.render("_quota", meters: quota_meters(report), note: quota_note(report))
      rescue StandardError => e
        warn "[web] quota: #{e.class}: #{e.message}"
        View.render("_quota", meters: [], note: "Kuota tidak bisa diperiksa sekarang.")
      end

      # One row per meter the provider reports: how much is spent, and when it
      # comes back. The provider's `percent` is already the spent share, so the
      # panel states it as it is — an allowance reads in the direction of the
      # thing a reader is asking about, which is how much of it is gone.
      def quota_meters(report)
        meters = Rubot::OpencodeUsage::METERS.filter_map do |name|
          next unless report.is_a?(Hash)

          meter = report[name]
          next unless meter.is_a?(Hash)

          used = meter["percent"].to_f.clamp(0.0, 100.0)
          {
            name: QUOTA_METER_LABELS.fetch(name) { name.capitalize },
            used: format("%.1f", used),
            used_label: "#{format('%.1f', used)}% terpakai",
            band: quota_band(used),
            reset: quota_reset(meter),
            limited: meter["limited"] ? true : false
          }
        end
        meters
      end

      # How close to the limit the meter is, in the three words the stylesheet
      # knows: under half is fine, past half is worth noticing, four fifths and
      # up is nearly gone. The figure stays exact; this only colours it.
      def quota_band(used)
        return "hot" if used >= 80.0
        return "warm" if used >= 50.0

        "calm"
      end

      def quota_reset(meter)
        time = Rubot::OpencodeUsageReport.parse_time(meter["resets_at"])
        return "" unless time

        "reset dalam #{Rubot::OpencodeUsageReport.relative(time)}"
      end

      # Why there is nothing to draw, in words a reader can act on: a provider
      # that sells tokens by the drink has no allowance at all, and that is not
      # a failure.
      def quota_note(report)
        return "Provider ini tidak punya kuota langganan — biayanya dihitung per token." if report[:unavailable]
        return "Kuota tidak bisa diperiksa — #{report[:error]}." if report[:error]

        ""
      rescue StandardError
        ""
      end
    end
  end
end
