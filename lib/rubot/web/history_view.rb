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
      # How much of a conversation the page draws at once, counted in
      # *messages* — the rows the archive holds and the request is built from.
      #
      # It is not counted in entries. A page of twenty turns reads as a sane
      # amount of DOM right up until a turn is a thousand messages long: one
      # session in the real archive answers eleven prompts with 2,402 rows, so
      # twenty entries there is the whole conversation, tool output and all. The
      # unit the reader pays for is the message, so that is the unit the page is
      # cut by.
      #
      # The cut still lands on a turn boundary (see #page_start): a page that
      # began halfway through a turn would draw a tool result whose call lives on
      # the page above, and in the compact view it would draw the wrong call as
      # "the last one". So the budget decides how far back to walk, never where
      # inside a turn to stop.
      HISTORY_PAGE_MESSAGES = 100
      # How much the courtesy below may cost. A page begins where the reader
      # spoke, not on an answer, so the walk is extended back to the prompt that
      # opens it — but a session of fired jobs and sub agent reports is a run of
      # turns with no prompt between them at all, and an unbounded walk there
      # would take back every entry the budget just refused: the whole
      # conversation on one page, which is the thing this paging exists to stop.
      #
      # Two ceilings, because one of them alone is the wrong unit. Counting
      # entries does not bound anything: twelve turns can be twelve thousand
      # messages. The reach is therefore also capped in messages, at twice the
      # page budget, which keeps the page in the same order of size as the budget
      # — unless one turn is that large on its own, in which case it is drawn
      # whole and no reach is added at all.
      HISTORY_SNAP_LIMIT = 12
      HISTORY_SNAP_MESSAGES = HISTORY_PAGE_MESSAGES * 2
      # The provider names its windows by period. The keys are spelled out
      # rather than built from the provider's word, so the guard in
      # test_i18n.rb can see that each one is rendered by this file.
      QUOTA_METER_KEYS = { "rolling" => "web.quota.meters.rolling",
                           "weekly" => "web.quota.meters.weekly",
                           "monthly" => "web.quota.meters.monthly" }.freeze
      # The channel aliases this constant, so it stays defined; but a constant
      # is read once, at load, in the language the process booted in, so
      # nothing a reader sees may use it — the drawing asks
      # `quota_meter_label`, which reads the language of the moment.
      QUOTA_METER_LABELS = QUOTA_METER_KEYS.transform_values { |key| Rubot::I18n.t(key) }.freeze

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
          detail: ToolCaption.caption(name, arguments),
          state: result.nil? ? :unknown : (tool_ok?(result) ? :ok : :failed),
          elapsed: nil
        }
        op = arguments["operation"].to_s
        # The call as the agent made it stays reachable on hover, the same way
        # the live row keeps it: a replayed conversation shows what the live
        # one showed, down to the tooltip.
        tooltip = ToolCaption.tooltip(name, arguments)
        row[:title] = tooltip unless tooltip.empty?
        # The skills the call loaded, when it loaded any: the row reads "Memuat
        # skill <code>brain</code>" and wears the skill class, the same way the
        # live one does (see _timeline.erb), so a replayed conversation and a
        # live one cannot disagree about what happened.
        skills = Rubot::SkillLoad.names(name, arguments)
        row[:skills] = skills unless skills.empty?
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

      # One page of the conversation: the entries that end at the entry boundary
      # at or before the message `before` names, walking back until
      # HISTORY_PAGE_MESSAGES messages are on it. `more` says whether anything
      # older is left, so the page can draw the sentinel that asks for it.
      #
      # `before` is a *message* index, not an entry index. The message index is
      # the only one the archive actually stores (see Store's `idx`), so it is
      # the only one a link can carry and still mean the same place after a
      # reload, a restart, or a change in how turns are grouped.
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
          before ? page_stop(entries, before) : entries.size
        elsif focus
          focus + 1
        else
          entries.size
        end
        start = page_start(entries, stop)

        { entries: entries[start...stop], more: start.positive?,
          before: start.positive? ? entries[start]&.[](:idx).to_i : 0,
          landed: focus ? entries[focus] : nil }
      end

      # How many entries begin before the message `before`. A cursor that
      # precedes every entry — a link carried across a session that was trimmed
      # before it was indexed — counts nothing, and drawing that would leave the
      # reader with an empty thread, no sentinel and no way back. The tail is the
      # answer there, the same one #focus_index gives for a hit it cannot place.
      def page_stop(entries, before)
        count = entries.count { |entry| entry[:idx].to_i < before }
        count.zero? ? entries.size : count
      end

      # Where the page begins: whole entries, counted in messages.
      #
      # A turn is never cut in half, so the budget is a stopping rule rather
      # than a boundary: walk back until the messages on the page reach
      # HISTORY_PAGE_MESSAGES, and always keep at least one entry — a single
      # turn longer than the whole budget has to be drawn somewhere, and the
      # page it starts on is the only place it can go.
      #
      # The budget can land on a turn, and a page that opens with an answer whose
      # question sits on the page above reads as a mistake. So the walk reaches
      # for the prompt — but only so far (see #snap_to_prompt).
      def page_start(entries, stop)
        start = stop
        spent = 0
        while start.positive? && spent < HISTORY_PAGE_MESSAGES
          start -= 1
          spent += entry_messages(entries[start])
        end
        snap_to_prompt(entries, start, spent)
      end

      # `start` moved back to the prompt that opens it, or `start` itself when no
      # prompt is within HISTORY_SNAP_LIMIT entries and HISTORY_SNAP_MESSAGES
      # messages of it: a page that opens on a turn is better than one that
      # swallows the rest of the conversation.
      #
      # `spent` is what the page already holds, so the reach is measured against
      # the whole page rather than against the budget alone. Only the entries the
      # walk actually adds are counted: the entry it starts on is already in
      # `spent`.
      def snap_to_prompt(entries, start, spent)
        return start if entries[start].nil?

        floor = [ start - HISTORY_SNAP_LIMIT, 0 ].max
        candidate = start
        loop do
          break if candidate < floor
          return candidate if entries[candidate][:kind] == :prompt
          break if candidate.zero?

          spent += entry_messages(entries[candidate - 1])
          break if spent > HISTORY_SNAP_MESSAGES

          candidate -= 1
        end
        start
      end

      # How many transcript rows an entry stands for. A prompt is one row; a
      # turn is every message between its first and its last, tool results
      # included — which is why a page counted in entries could hold a whole
      # conversation and a page counted in messages cannot.
      def entry_messages(entry)
        entry[:last].to_i - entry[:idx].to_i + 1
      end

      # The entry a search hit lands on: the prompt that quoted it, or the turn
      # that answered it. When the index is past the last entry the hit still
      # lands somewhere sensible — the newest one. A hit *older* than every entry
      # cannot: an index that predates the archive has no entry above it, so this
      # answers nil, `history_page` draws the tail, and the reader gets the end of
      # the conversation without a mark. That is the cost of a session trimmed
      # since it was indexed, and it is why the fallback does not pretend.
      def focus_index(entries, at)
        entries.index { |entry| entry[:idx].to_i <= at && entry[:last].to_i >= at } ||
          entries.rindex { |entry| entry[:idx].to_i <= at }
      end

      # Where the page older than this one lives. The token rides in the query
      # string like every other link the page writes; `before` is the message
      # index the page starts at, so no server-side cursor has to survive a
      # restart and the link means the same place a day later.
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
        return I18n.t("web.usage.facts.unknown") unless cost.is_a?(Hash)

        total = format("$%s", Rubot::UsageReport.money(cost["total"]))
        cost["cache_price_unknown"] ? "#{total} ≤" : total
      end

      def cost_breakdown(cost)
        return "" unless cost.is_a?(Hash)
        return "" unless %w[input cached_input cache_creation output].any? { |key| cost[key].to_f.positive? }

        parts = []
        parts << I18n.t("web.usage.facts.cost_in", value: Rubot::UsageReport.money(cost["input"]))
        if cost["cached_input"].to_f.positive?
          parts << I18n.t("web.usage.facts.cost_cache_read",
                          value: Rubot::UsageReport.money(cost["cached_input"]))
        end
        if cost["cache_creation"].to_f.positive?
          parts << I18n.t("web.usage.facts.cost_cache_write",
                          value: Rubot::UsageReport.money(cost["cache_creation"]))
        end
        parts << I18n.t("web.usage.facts.cost_out", value: Rubot::UsageReport.money(cost["output"]))
        parts.join(" · ")
      end

      def cache_fact(report)
        total = Rubot::UsageReport.tokens(report[:cached_tokens])
        if report[:prompt_tokens].to_i.zero?
          return I18n.t("web.usage.facts.cache_from", tokens: total)
        end

        # Two shares, both labelled. The cost above this line is cumulative,
        # so a lone latest-request figure under it reads as if the session had
        # never cached anything — which is how a $2 bill next to "cache 4%"
        # came to look like a bug in the arithmetic.
        I18n.t("web.usage.facts.cache_shares",
               last: format("%.1f", report[:cache_hit_rate].to_f * 100),
               session: format("%.1f", report[:cache_hit_rate_session].to_f * 100),
               tokens: total)
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
        View.render("_quota", meters: [], note: I18n.t("web.quota.check_failed"))
      end

      # One row per meter the provider reports: how much is spent, and when it
      # comes back. The provider's `percent` is already the spent share, so the
      # panel states it as it is — an allowance reads in the direction of the
      # thing a reader is asking about, which is how much of it is gone.
      # The window a meter measures, in the active language. A window the
      # dictionary has not learned yet keeps the provider's own word,
      # capitalised: an unseen meter should still read as something.
      def quota_meter_label(name)
        I18n.t("web.quota.meters.#{name}")
      rescue Rubot::I18n::MissingTranslation
        name.capitalize
      end

      def quota_meters(report)
        meters = Rubot::OpencodeUsage::METERS.filter_map do |name|
          next unless report.is_a?(Hash)

          meter = report[name]
          next unless meter.is_a?(Hash)

          used = meter["percent"].to_f.clamp(0.0, 100.0)
          {
            name: quota_meter_label(name),
            used: format("%.1f", used),
            used_label: I18n.t("web.quota.used", percent: format("%.1f", used)),
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

        I18n.t("web.quota.reset_in", when: Rubot::OpencodeUsageReport.relative(time))
      end

      # Why there is nothing to draw, in words a reader can act on: a provider
      # that sells tokens by the drink has no allowance at all, and that is not
      # a failure.
      def quota_note(report)
        return I18n.t("web.quota.unavailable") if report[:unavailable]
        return I18n.t("web.quota.error", error: report[:error]) if report[:error]

        ""
      rescue StandardError
        ""
      end
    end
  end
end
