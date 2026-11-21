# frozen_string_literal: true

require "webrick"
require "securerandom"
require "uri"
require "fileutils"
require "json"
require "timeout"

require_relative "../channel"
require_relative "../formatting"
require_relative "../opencode_usage"
require_relative "../persona_store"
require_relative "../session"
require_relative "../tools/send_files"
require_relative "../web/auth"
require_relative "../web/diff"
require_relative "../web/highlight"
require_relative "../web/history_view"
require_relative "../web/notifier"
require_relative "../web/push"
require_relative "../web/media"
require_relative "../web/router"
require_relative "../web/routes/cron"
require_relative "../web/routes/instagram"
require_relative "../web/routes/push"
require_relative "../web/session_browser"
require_relative "../web/routes/sessions"
require_relative "../web/routes/settings"
require_relative "../web/subagents"
require_relative "../web/tool_rows"
require_relative "../web/turns"
require_relative "../web/subagent_jobs"
require_relative "../web/subagent_line"
require_relative "../web/turn"
require_relative "../web/view"

module Rubot
  module Channels
    # Browser channel: an HTMX page backed by Server-Sent Events.
    #
    # Ruby renders every HTML fragment; the page itself carries no rendering
    # logic. A POST starts a turn and answers with a fragment that opens the
    # SSE stream on its own, so the browser never needs to poll.
    #
    # Events are idempotent renders of the turn's current state, which makes a
    # reconnect safe: replaying from the start just paints the same content.
    #
    # Each persona is its own agent, rooted at the persona's workspace by
    # SessionPool, so SOUL.md, skills and memory are not shared between
    # specialists. A persona owns many conversations: the first is
    # `web_<slug>`, later ones are `web_<slug>~<stamp>`, and the sidebar lists
    # them beside the avatar rail.
    class Web < Channel
      DEFAULT_HOST = "127.0.0.1"
      DEFAULT_PORT = 4567
      DEFAULT_SLUG = "rubot"

      # How long a turn has to run before finishing it is worth a notification,
      # measured in seconds. Off by default: a turn ending is not news unless
      # the reader asked to be told (`notify`), and a timer made every long
      # reply announce itself whether or not anyone wanted that. Set
      # `turn_notify_after` to a positive number to bring the clock back; a
      # device with the app in front skips the buzz on its own either way.
      TURN_NOTIFY_AFTER = 0
      # A notification body is read on a lock screen: two or three lines, one
      # glance. The whole answer is one tap away, so what travels is the gist.
      # The number lives with the cron delivery, which is where most of it is
      # spent; the turn note below reads the same one.
      TURN_NOTIFY_CHARS = Rubot::Web::Routes::Cron::TURN_NOTIFY_CHARS
      # How many subagent answers one automatic report carries. A batch is
      # usually small; a long backlog is handed over in instalments rather than
      # as one wall of text, and only the runs actually quoted are marked read.
      # The number belongs to the report, so it lives with it.
      SUBAGENT_REPORT_LIMIT = Rubot::Web::Subagents::SUBAGENT_REPORT_LIMIT
      # The pin cap lives with the sidebar that enforces it, because the sidebar
      # is where the number is drawn; unpinning the oldest reads the same one.
      PINNED_LIMIT = Rubot::Web::SessionBrowser::PINNED_LIMIT
      # How many messages one search answers with. The sidebar is a list, not a
      # page: a query that matches hundreds of rows is answered with the best of
      # them, and a narrower query is how the reader asks for more.
      SEARCH_LIMIT = 20
      # How much of a conversation the page draws at once. A long session is a
      # lot of DOM to build for a reader who only ever looks at the end of it,
      # so the page starts at the tail and earlier turns arrive as the reader
      # scrolls up.
      HISTORY_PAGE = Rubot::Web::HistoryView::HISTORY_PAGE
      # What a conversation is called before its prompt has been saved. The
      # sidebar names it, and the search results below fall back to it too.
      UNTITLED_SESSION = Rubot::Web::SessionBrowser::UNTITLED_SESSION

      # The level a persona starts from, and the one a session falls back to
      # when neither it nor its persona has chosen: the middle of what the
      # models understand, and the one effort a reasoning model accepts. The
      # level belongs to the settings page that offers it, so it lives there.
      DEFAULT_THINKING = Rubot::Web::Routes::Settings::DEFAULT_THINKING
      # The provider names its windows by period; a reader asks by length. The
      # provider's own words stay on the wire — this is only how the panel says
      # them.
      QUOTA_METER_LABELS = Rubot::Web::HistoryView::QUOTA_METER_LABELS
      ASSETS = File.expand_path("../web/assets", __dir__)
      VENDOR = File.expand_path("../../../vendor/web", __dir__)

      MIME = {
        ".js" => "text/javascript; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".html" => "text/html; charset=utf-8",
        ".svg" => "image/svg+xml",
        ".png" => "image/png",
        ".woff2" => "font/woff2"
      }.freeze

      LOOPBACK = %w[127.0.0.1 localhost ::1].freeze

      # Rubot::Web lives outside Rubot::Channels, so plain constant lookup from
      # inside this class would resolve `Web` to this channel itself.
      Turn = Rubot::Web::Turn
      View = Rubot::Web::View
      Format = Rubot::Web::Format
      # The rule that decides how much of a turn's tool log survives on the
      # page. Replayed pages and the live turn must agree, so both read it here.
      ToolRows = Rubot::Web::ToolRows
      # Web Push, named apart from `Web` for the same reason. `Push` is the
      # protocol (seal a payload, sign a request); `Vapid` is the key that
      # signs, kept in one file for this install.
      PushTransport = Rubot::Web::Push
      VapidKey = Rubot::Web::Vapid
      # The part that decides who gets told and what it costs in round trips.
      PushNotifier = Rubot::Web::Notifier

      # The way in and the route table. Both are written as modules so each can
      # be read on its own; including them keeps every call site inside this
      # class, which is what the views and the tests already expect.
      include Rubot::Web::Auth
      include Rubot::Web::Router
      include Rubot::Web::Routes::Push
      include Rubot::Web::Routes::Cron
      include Rubot::Web::Routes::Instagram
      include Rubot::Web::Routes::Sessions
      include Rubot::Web::Routes::Settings
      include Rubot::Web::Media
      include Rubot::Web::SessionBrowser
      include Rubot::Web::HistoryView
      include Rubot::Web::Subagents
      include Rubot::Web::Turns

      attr_reader :host, :port

      def initialize(agent: nil, pool: nil, app_config: nil, channel_config: {})
        @host = (channel_config["host"] || DEFAULT_HOST).to_s
        @port = (channel_config["port"] || DEFAULT_PORT).to_i
        @default_slug = (channel_config["persona"] || DEFAULT_SLUG).to_s
        @token = channel_config["token"]&.to_s
        @access_log = channel_config["access_log"]
        @turns = {}
        @active = {}
        @compacting = {}
        @turns_mutex = Mutex.new
        # Pages that are open and idle, listening for news that arrives on its
        # own. Each one keeps its session id, which is what decides the active
        # row and the persona it should hear about.
        @event_subs = []
        @event_mutex = Mutex.new
        # Delegated runs that outlive the turn that asked for them. Kept here
        # because the turn is gone by the time they finish: their state is what
        # the footer draws, and the channel is the only thing still listening.
        @subagent_jobs = Rubot::Web::SubagentJobs.new
        @subagent_jobs.on_change { |sid| broadcast_subagents(sid) }
        # Whether each conversation's sheet is currently in its footer, so the
        # stream only has to replace the whole element when that answer changes.
        @subagent_visible = {}
        # Which conversations are having a finished batch reported back right
        # now. Set before the report turn is run, so a second run landing in the
        # same breath cannot report the same answers twice.
        @subagent_reporting = {}
        # Which scheduled hiding is still the current one. A run that starts
        # while an older timer is asleep bumps the token, so that timer wakes up
        # to a conversation it no longer speaks for and does nothing.
        @subagent_hide_token = {}
        @subagent_mutex = Mutex.new
        @personas = nil
        # Built on first use: reading (or generating) the key is a file that
        # most boots never need, and a channel with push unused should not have
        # written one. The mutex matters on that first use: two threads racing
        # to build it could each generate a key, and the one that lost the file
        # would sign with a key the browsers never subscribed to.
        @vapid = nil
        @vapid_mutex = Mutex.new
        @vapid_subject = (channel_config["vapid_subject"] || VapidKey::SUBJECT).to_s

        # How hard a push service should work to wake a sleeping phone. The
        # default is `high` because the symptom of `normal` is a notification
        # that appears only once the app is opened — by which time the reader
        # had to find out on their own. An install that would rather be quiet
        # at night sets `normal` and accepts the delay.
        @push_urgency = PushTransport.normalize_urgency(channel_config["push_urgency"] ||
                                                        PushTransport::DEFAULT_URGENCY)

        # How long a turn has to run before its ending is worth a knock on the
        # door. Zero turns the notifications off; a reader who finds the buzz
        # too eager raises the number rather than hunting for a switch.
        @turn_notify_after = (channel_config["turn_notify_after"] || TURN_NOTIFY_AFTER).to_i
        super
      end

      def start
        @running = true
        # A restart sends TERM, and without a handler that killed the process
        # where it stood: the server loop never returned, the pool was never
        # closed, and the learning queue — a name being written, a memory
        # extraction halfway — went with it. The TUI and the Telegram channel
        # have always trapped these; this one was the exception.
        register_signal_handlers
        start_cron_listener { |result| handle_cron_fire(result) } if actor_mode?
        start_instagram_ticker
        ensure_default_persona

        @server = WEBrick::HTTPServer.new(
          BindAddress: @host,
          Port: @port,
          Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
          AccessLog: @access_log ? WEBrick::AccessLog::COMMON_LOG_FORMAT : [],
          DoNotReverseLookup: true
        )
        @server.mount_proc("/") { |req, res| dispatch(req, res) }

        warn "[web] listening on http://#{@host}:#{@port} — default persona #{default_slug}"
        if @token.nil? && !LOOPBACK.include?(@host)
          warn "[web] WARNING: bound to #{@host} with no token. This channel can run shell commands."
        end

        @server.start
      ensure
        stop_cron_listener
        shutdown_pool
      end

      # Stopping by signal has to reach the work that is not a request: the
      # learning queue, where a name or a memory extraction may be halfway, and
      # the server loop. The cron listener and the pool are closed by #start's
      # ensure, which runs the moment the loop this method stops lets go.
      #
      # The drain is three seconds on purpose: `bin/web-restart` gives the
      # process eight before KILL, and the pool still needs its share of what is
      # left. A longer drain would not be honoured, it would only be cut.
      def stop
        @running = false
        stop_learning_worker(timeout: 3)
        @instagram_thread&.join(2)
        @server&.shutdown
      end

      # Chunks arrive on the turn's own thread; the thread-local is how this
      # callback finds the turn that is producing them.
      def on_stream_chunk(chunk)
        Thread.current[:rubot_web_turn]&.append_chunk(chunk)
      end

      # The persona's first session, which is also the id older bookmarks and
      # the pre-sessions UI used.
      private

      # --- personas ------------------------------------------------------

      def persona_store
        return @personas if @personas
        return nil unless @app_config

        @personas = PersonaStore.new(
          dir: File.dirname(@app_config.config_path),
          legacy_workspace: @app_config.workspace,
          available_models: Array(@app_config.models).filter_map { |model| model["name"] if model.is_a?(Hash) },
          available_presets: @app_config.model_preset_names
        )
      end

      def personas
        store = persona_store
        store ? store.specialists : []
      end

      def default_slug
        list = personas
        return @default_slug unless list.empty?
        return @default_slug if PersonaStore.valid_slug?(@default_slug)

        DEFAULT_SLUG
      end

      def known_slug?(slug)
        return true if slug == default_slug && personas.empty?

        personas.any? { |key, _persona| key == slug }
      end

      # A store with nothing in it would leave the sidebar empty on a fresh
      # install, so the channel creates one usable persona.
      def ensure_default_persona
        store = persona_store
        return unless store
        return unless store.specialists.empty?
        return unless PersonaStore.valid_slug?(@default_slug)

        store.set(@default_slug, Persona.new(slug: @default_slug, name: "Rubot", emoji: "🤖"))
        store.prepare_workspace(@default_slug, seed_from: @app_config&.workspace)
      end

      # --- routing -------------------------------------------------------

      # WEBrick delivers form/query values as ASCII-8BIT, so anything past
      # ASCII explodes later when a persona is serialised to JSON. Decode to
      # UTF-8 at the edge so the rest of the code can assume valid text.
      def form(req, key)
        raw = req.query[key]
        return "" if raw.nil?

        utf8(raw)
      end

      # Whether the request carried the field at all. `form` answers "" for a
      # missing key and for an empty one, which is the right default for a text
      # field and not enough for a picker: "left on Ikut default" and "the form
      # has no picker" are two different instructions.
      def form_field?(req, key)
        query = req.query
        query.respond_to?(:key?) && query.key?(key)
      end

      # Every value a form field carried, in the order it appeared. #query keeps
      # only the last of a repeated key, which is right for a text input and
      # useless for a group of checkboxes: `skill=a&skill=b` has to come back as
      # both, and the raw query string is the only place both still exist.
      def form_values(req, key)
        raw = +""
        query = req.respond_to?(:request_uri) ? req.request_uri&.query : nil
        raw << query.to_s if query
        body = req.respond_to?(:body) ? req.body.to_s : ""
        raw << "&" << body unless body.empty?

        values = raw.split(/[&;]/).filter_map do |pair|
          name, value = pair.split("=", 2)
          next if name.nil?

          utf8(WEBrick::HTTPUtils.unescape(name)) == key ? utf8(WEBrick::HTTPUtils.unescape(value.to_s)) : nil
        end
        # Test doubles and non-WEBrick requests may carry repeated keys as an
        # array in #query instead of a raw body.
        if values.empty? && req.respond_to?(:query)
          candidate = req.query[key]
          values = candidate.is_a?(Array) ? candidate.map { |v| utf8(v) } : []
        end
        values
      end

      def serve_static(res, path)
        root = path.start_with?("/vendor/") ? VENDOR : ASSETS
        file = File.join(root, File.basename(path))
        return not_found(res) unless File.file?(file)

        res["Content-Type"] = MIME[File.extname(file)] || "application/octet-stream"
        res["Cache-Control"] = "public, max-age=3600"
        res.body = File.binread(file)
      end

      # The app's description, as the browser asks for it. Cached like any other
      # asset: it changes only when the page does.
      def serve_manifest(res)
        file = File.join(ASSETS, "manifest.webmanifest")
        return not_found(res) unless File.file?(file)

        res["Content-Type"] = "application/manifest+json; charset=utf-8"
        res["Cache-Control"] = "public, max-age=3600"
        res.body = File.binread(file)
      end

      # The service worker. Served at "/" because a worker only controls the
      # paths under its own, and never cached by the browser itself: a worker
      # the browser keeps for an hour is a deploy that reached nobody.
      #
      # The stamp is what keeps the shell cache honest: the worker names its
      # cache from the mtime of the assets it installs, so a stylesheet or
      # script that changed renames it, and an installed app rebuilds the shell
      # instead of serving the copy it kept. That used to be a constant someone
      # had to remember to bump, which is a promise that only holds until it is
      # forgotten.
      def serve_worker(res)
        file = File.join(ASSETS, "sw.js")
        return not_found(res) unless File.file?(file)

        res["Content-Type"] = "text/javascript; charset=utf-8"
        res["Cache-Control"] = "no-cache"
        res["Service-Worker-Allowed"] = "/"
        res.body = File.binread(file).sub("__VERSION__", asset_version.to_s)
      end

      # The end of a turn somebody asked to hear about.
      #
      # The rule is the request, not the clock: a turn ends where it was typed,
      # so announcing it unprompted says nothing the reader does not already
      # see. Two things can still ring — the agent was told "kabari kalau sudah
      # kelar" and called `notify`, or the install opted back into the old
      # time-based rule with a positive `turn_notify_after`, where a turn that
      # ran a long time is a turn the reader plausibly walked away from. Which
      # devices actually ring is their own decision: a page that is in front
      # skips the notification in its worker.
      def notify_turn_end(turn, elapsed, requested: nil)
        slug = owner_slug(turn.session_id) || default_slug
        # The agent was asked to report back, so the announcement happens even
        # for a turn that took a second — and it says what it was told to say.
        # `force` follows from the same thing: this news is for the person at
        # the screen, not a report they might already be reading.
        if requested
          note = requested.to_s.strip
          notify_push(slug,
                      title: persona_title(slug),
                      body: note.empty? ? turn_note(turn) : note,
                      url: session_url(turn.session_id),
                      force: true)
          return
        end

        return if @turn_notify_after <= 0
        return if elapsed < @turn_notify_after

        notify_push(slug,
                    title: persona_title(slug),
                    body: turn_note(turn),
                    url: session_url(turn.session_id))
      rescue StandardError => e
        # A turn that finished is a turn that succeeded; a push service having a
        # bad day must not turn that into an error the reader sees.
        warn "[web] turn notification: #{e.class}: #{e.message}"
      end

      # What the lock screen says about a finished turn: the first line or so of
      # the answer, folded flat. The answer itself is a tap away.
      def turn_note(turn)
        text = turn.response.to_s.gsub(/\s+/, " ").strip
        return "Balasan sudah siap." if text.empty?

        text.length > TURN_NOTIFY_CHARS ? "#{text[0, TURN_NOTIFY_CHARS - 1].rstrip}…" : text
      end

      # What a notification is signed as: the persona's own name, so a phone
      # with three of them knows which one is talking before it is unlocked.
      def persona_title(slug)
        _key, persona = personas.find { |key, _persona| key == slug }
        label = persona&.label.to_s.strip
        label.empty? ? "rubot · #{slug}" : "rubot · #{label}"
      end

      def json(res, status, body)
        res.status = status
        res["Content-Type"] = "application/json; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = JSON.generate(body)
      end

      # A subscription is an endpoint someone else chose, and every later
      # notification is delivered to it — sealed to that stranger's key, so they
      # can read it. A page on another origin can POST one here without ever
      # being able to read the answer, and with no token on a loopback install
      # nothing else would stop it. So the push writes ask where the request
      # came from. `Sec-Fetch-Site` is what current browsers send; `Origin` is
      # the older proof; a client sending neither (curl, a test) is not a
      # browser that could be tricked into this.
      def not_found(res)
        res.status = 404
        res.body = "not found"
      end

      def bad_request(res)
        res.status = 400
        res.body = "bad request"
      end

      def redirect(res, location, req = nil)
        target = "#{location}#{token_query}"

        # htmx issues XHR, so a 303 would just be followed silently and its
        # body swapped into the form. HX-Redirect makes the browser navigate.
        if req && req["HX-Request"].to_s == "true"
          res.status = 204
          res["HX-Redirect"] = target
        else
          res.status = 303
          res["Location"] = target
        end
        res.body = ""
      end

      # Compaction rewrites the transcript, so the context figure in the footer
      # is stale until it is redrawn. A turn already emits :usage when it ends,
      # but a manual compaction has no turn of its own, and an automatic one can
      # finish before the turn's own :usage is emitted. Push the fresh row over
      # the always-on /events stream so the percentage moves on its own, with
      # no reload. The payload carries hx-swap-oob, so it replaces #usage in
      # place wherever the footer is drawn.
      def broadcast_usage(sid)
        markup = usage_markup(sid)
        push_to_session(sid, :usage, markup) if markup
      end

      # One page, identified by the session it is showing, gets the event. The
      # roster broadcasts reach every page because counts are install-wide; a
      # compaction row or a reload belongs only to the conversation it changed.
      def push_to_session(sid, type, markup)
        @event_mutex.synchronize { @event_subs.dup }.each do |sub, queue|
          next unless sub == sid

          queue << [ type, markup ]
        end
      end

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

        store = Session.store
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
            title: hit[:title].to_s.strip.empty? ? UNTITLED_SESSION : hit[:title].to_s.strip,
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

      # Static assets are cached for an hour, so the URL carries the mtime of
      # the newest of them. One stamp for the whole shell: a JS-only change has
      # to reach the browser just as a CSS change does, and the stylesheet alone
      # as its version was a promise the stylesheet could not keep. The worker
      # takes the same stamp as its cache name, which is why it is in the list:
      # a change to the worker is a change to the shell.
      def asset_version
        %w[app.css app.js sw.js].map { |name| File.mtime(File.join(ASSETS, name)).to_i }.max
      rescue SystemCallError
        0
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
        store = Session.store
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

      # Read under the same lock the button claims, so a stream opening at the
      # moment a compaction starts cannot report a state that is already stale.
      def compacting?(sid)
        @turns_mutex.synchronize { @compacting[sid] }
      end

      # Naming, memory extraction and correction-learning are a provider
      # request or two that say nothing about the answer the reader already
      # has, so this channel hands them to the learning queue and ends the turn
      # as soon as the answer is complete. When the queue is done with the
      # session, the open pages are told: that is the moment the new name
      # exists, and redrawing the header and the sidebar is all it takes to
      # show it.
      def defer_learning?
        true
      end

      def after_learning(session_id)
        broadcast_sessions if owner_slug(session_id)
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
        store = Session.store
        return false unless store
        return false if watched?(sid)

        store.mark_unread(sid)
        true
      end

      def watched?(sid)
        @event_mutex.synchronize { @event_subs.any? { |sub, _queue| sub == sid } }
      end

      def shorten(text, limit)
        Rubot::Formatting.shorten(text, limit)
      end

    end
  end
end
