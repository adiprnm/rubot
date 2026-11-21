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
require_relative "../web/notifier"
require_relative "../web/push"
require_relative "../web/media"
require_relative "../web/router"
require_relative "../web/routes/push"
require_relative "../web/tool_rows"
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
      MAX_TURNS = 30
      DEFAULT_SLUG = "rubot"

      # A persona can own many conversations. The first one keeps the historic
      # id ("web_<slug>"); every later one appends "~<stamp>". "~" cannot occur
      # in a slug, so the id always splits back into persona + session.
      SESSION_SEPARATOR = "~"
      # How often an idle page's event stream says something, so a connection
      # sitting in a proxy is not closed for being quiet.
      EVENT_HEARTBEAT = 20
      # How long a turn has to run before finishing it is worth a notification,
      # measured in seconds. Off by default: a turn ending is not news unless
      # the reader asked to be told (`notify`), and a timer made every long
      # reply announce itself whether or not anyone wanted that. Set
      # `turn_notify_after` to a positive number to bring the clock back; a
      # device with the app in front skips the buzz on its own either way.
      TURN_NOTIFY_AFTER = 0
      # A notification body is read on a lock screen: two or three lines, one
      # glance. The whole answer is one tap away, so what travels is the gist.
      TURN_NOTIFY_CHARS = 140
      # How many subagent answers one automatic report carries. A batch is
      # usually small; a long backlog is handed over in instalments rather than
      # as one wall of text, and only the runs actually quoted are marked read.
      SUBAGENT_REPORT_LIMIT = 5
      # How often a report that is being written reaches the page. Faster than
      # this is a repaint the eye cannot follow; slower is a stall.
      REPORT_STREAM_SECONDS = 0.15
      # How long one report may hold a conversation before its claim is treated
      # as abandoned. Long enough for a report turn that reads a file or two,
      # short enough that a thread which died does not silence the conversation
      # for the rest of the process.
      REPORT_CLAIM_SECONDS = 600
      # How long a report turn may take before it is treated as stuck. Generous:
      # a report is a provider request that may read a file or two, and the
      # answer is streaming to the page while it runs, so nothing is lost by
      # waiting. Long enough that a slow model is not cut, short enough that a
      # dead read does not take the answers with it.
      REPORT_TIMEOUT_SECONDS = 90
      # The bold line of a notification is the shortest thing on the screen, so
      # it gets the least room: a hook that does not fit is not a hook.
      NOTIFY_HOOK_CHARS = 60
      # How many conversations can be pinned for one persona. A pin is a way of
      # saying "this one again", and a list long enough to scroll is not a way
      # of saying it: past ten the oldest pin gives way, so the cap needs no
      # error message and no separate setting.
      PINNED_LIMIT = 10
      # How many unpinned conversations one page of the sidebar holds. The rest
      # are still there, a page link away, so an archive with years in it does
      # not turn the sidebar into an endless scroll.
      RECENT_PAGE = 20
      # How many messages one search answers with. The sidebar is a list, not a
      # page: a query that matches hundreds of rows is answered with the best of
      # them, and a narrower query is how the reader asks for more.
      SEARCH_LIMIT = 20
      # How much of a conversation the page draws at once. A long session is a
      # lot of DOM to build for a reader who only ever looks at the end of it,
      # so the page starts at the tail and earlier turns arrive as the reader
      # scrolls up.
      HISTORY_PAGE = 20
      # What a conversation is called before its first prompt has been saved.
      UNTITLED_SESSION = "Sesi baru"

      # The level a persona starts from, and the one a session falls back to
      # when neither it nor its persona has chosen: the middle of what the
      # models understand, and the one effort a reasoning model accepts.
      DEFAULT_THINKING = "medium"
      # The provider names its windows by period; a reader asks by length. The
      # provider's own words stay on the wire — this is only how the panel says
      # them.
      QUOTA_METER_LABELS = { "rolling" => "5 jam", "weekly" => "mingguan",
                             "monthly" => "bulanan" }.freeze
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
      include Rubot::Web::Media

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
        Session.store&.delete_session(sid)

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

        if (store = Session.store)
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

      # An older page, fetched by the marker at the top of the thread when the
      # reader scrolls it into view.
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

      # --- settings -------------------------------------------------------

      # The provider that is not in the offered list, if any, is added by
      # `settings_provider_choices`; this is only what a fresh install sees.
      PROVIDER_CHOICES = %w[opencode openai anthropic ollama gemini deepseek groq mistral].freeze

      # The three keys that are not scoped to a persona or a conversation: one
      # provider, one key, one default model for the whole install.
      def render_settings(res, req)
        saved = req.query["saved"].to_s == "1"
        if req.query["refresh"].to_s == "1" || req.query["refresh_models"].to_s == "1"
          begin
            Rubot::ModelCatalog.new(config: @app_config).entries if @app_config
          rescue StandardError
            nil
          end
        end
        store = Session.store

        # The back button returns the reader to wherever they came from, not to
        # a fixed page: the settings page is reachable from any conversation,
        # so a hard-coded destination would drop them somewhere unexpected.
        referer = settings_referer(req)
        back_url = referer.empty? ? "/#{token_query}" : referer

        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        # The persona the device-wide controls speak for: the notification test
        # button sends one message to one persona, and the page may have been
        # opened from any conversation. Same resolution the Instagram card uses
        # — named in the query, else the owner of `sid`, else the default.
        persona = ig_persona_for(req)
        res.body = View.render(
          "settings",
          provider: @app_config&.provider.to_s,
          default_model: @app_config&.model.to_s,
          auxiliary_model: @app_config&.auxiliary_model.to_s,
          subagent_model: @app_config&.subagent_model.to_s,
          subagent_rows: settings_subagent_rows,
          preset_rows: settings_preset_rows,
          default_preset: @app_config&.primary_model_preset_name.to_s,
          key_set: !@app_config&.api_key.to_s.empty?,
          key_from_archive: !store&.setting("api_key").to_s.strip.empty?,
          ig_app_id: store&.setting("instagram_app_id").to_s,
          ig_redirect_uri: store&.setting("instagram_redirect_uri").to_s,
          ig_secret_set: !store&.setting("instagram_app_secret").to_s.strip.empty?,
          ig_persona: persona,
          **ig_account_locals(persona),
          push_persona: persona,
          provider_choices: settings_provider_choices,
          model_choices: model_choices,
          saved: saved,
          archived: !store.nil?,
          token_query: token_query,
          back_url: back_url,
          asset_version: asset_version
        )
      end

      def settings_referer(req)
        return "" unless req
        value = nil
        if req.respond_to?(:[])
          value = req["Referer"]
          value = req["HTTP_REFERER"] if value.nil? || value.to_s.strip.empty?
        end
        if (value.nil? || value.to_s.strip.empty?) && req.respond_to?(:header) && req.header.is_a?(Hash)
          value = req.header["Referer"] || req.header["referer"] || req.header["HTTP_REFERER"]
        end
        if (value.nil? || value.to_s.strip.empty?) && req.respond_to?(:referer)
          value = req.referer
        end
        value.to_s.strip
      end

      # The current provider is in the list even when it is not one of the ones
      # offered: an install on an OpenAI-compatible endpoint it spelled itself
      # must not be silently moved to "openai" by opening the page and pressing
      # save.
      def settings_provider_choices
        current = @app_config&.provider.to_s
        list = PROVIDER_CHOICES.dup
        list.unshift(current) unless current.empty? || list.include?(current)
        list
      end

      def save_settings(res, req)
        store = Session.store
        return redirect_to(res, settings_url) unless store

        values = {
          "provider" => form(req, "provider"),
          "default_model" => form(req, "default_model"),
          "auxiliary_model" => form(req, "auxiliary_model"),
          "subagent_model" => form(req, "subagent_model")
        }
        # An empty key field means "leave the key alone": it is a password box,
        # it never carries the current value back, and a form that blanked the
        # key because nobody retyped it would take the install down. Clearing is
        # its own checkbox, and it is what deletes the row.
        if form(req, "clear_api_key") == "1"
          values["api_key"] = nil
        else
          typed = form(req, "api_key").strip
          values["api_key"] = typed unless typed.empty?
        end

        # Instagram credentials are typed here, but the token is not: it is
        # minted by the callback and lives in its own table. Only the three
        # credential keys go through the form, so saving cannot erase a token.
        %w[instagram_app_id instagram_redirect_uri].each do |key|
          values[key] = form(req, key).strip
        end
        if form(req, "clear_ig_secret") == "1"
          values["instagram_app_secret"] = nil
        else
          typed_secret = form(req, "instagram_app_secret").strip
          values["instagram_app_secret"] = typed_secret unless typed_secret.empty?
        end

        store.update_settings(values)
        if form(req, "ig_disconnect") == "1"
          persona = ig_persona_for(req)
          ig = instagram_client(persona: persona)
          ig.accounts.each { |acc| ig.disconnect(username: acc["username"]) }
          instagram_broadcast(persona: persona)
        end
        raw_link = req.query["ig_link"]
        links = raw_link.is_a?(Array) ? raw_link : (raw_link.to_s.empty? ? [] : [ raw_link ])
        links.flat_map { |v| v.to_s.split(",") }.map(&:strip).reject(&:empty?).each do |username|
          persona = ig_persona_for(req)
          begin
            instagram_client(persona: persona).link_account(username: username)
            instagram_broadcast(persona: persona)
          rescue Rubot::Instagram::Error => e
            warn "[web] instagram link: #{e.message}"
          end
        end
        save_settings_presets(req)
        apply_saved_settings
        redirect_to(res, settings_url(saved: true))
      end

      # Presets live in config.yml, not in the settings archive: they are the
      # install's model definitions, edited here with the same form as the
      # provider and key. Each row posts its name and fields; a blank model
      # deletes the preset, and the default picker writes agents.defaults.
      def save_settings_presets(req)
        config = @app_config
        return unless config

        names = form_values(req, "preset_name")

        names.each_with_index do |name, index|
          name = name.to_s.strip
          next if name.empty?

          model = form_values(req, "preset_model")[index].to_s.strip
          if model.empty?
            begin
              config.delete_model_preset(name)
            rescue StandardError => e
              warn "[web] delete preset #{name}: #{e.class}: #{e.message}"
            end
            next
          end

          attrs = { "model" => model }
          %w[preset_max_tokens preset_temperature preset_reasoning_effort].each do |field|
            value = form_values(req, field)[index].to_s.strip
            attrs[field.delete_prefix("preset_")] = value unless value.empty?
          end
          begin
            config.set_model_preset(name, attrs)
          rescue ArgumentError => e
            warn "[web] preset #{name}: #{e.message}"
          end
        end

        new_names = form_values(req, "new_preset_name")
        new_models = form_values(req, "new_preset_model")
        new_temps = form_values(req, "new_preset_temperature")
        new_tokens = form_values(req, "new_preset_max_tokens")
        new_reasoning = form_values(req, "new_preset_reasoning_effort")
        new_names.each_with_index do |raw_name, index|
          name = raw_name.to_s.strip
          model = new_models[index].to_s.strip
          next if name.empty? || model.empty?

          attrs = { "model" => model }
          { "temperature" => new_temps[index], "max_tokens" => new_tokens[index],
            "reasoning_effort" => new_reasoning[index] }.each do |key, value|
            text = value.to_s.strip
            attrs[key] = text unless text.empty?
          end
          begin
            config.set_model_preset(name, attrs)
          rescue ArgumentError => e
            warn "[web] new preset #{name}: #{e.message}"
          end
        end

        default = form(req, "default_preset").to_s.strip
        unless default.empty?
          begin
            config.set_default_model_preset(default)
          rescue ArgumentError => e
            warn "[web] default preset: #{e.message}"
          end
        end

        slugs = form_values(req, "subagent_slug")
        models = form_values(req, "subagent_model_choice")
        thinkings = form_values(req, "subagent_thinking")
        slugs.each_with_index do |slug, index|
          slug = slug.to_s.strip
          next if slug.empty?

          config.set_subagent_settings(slug, {
            "model" => models[index].to_s.strip,
            "thinking" => thinkings[index].to_s.strip
          })
        end
        config.save
      rescue StandardError => e
        warn "[web] save presets: #{e.class}: #{e.message}"
      end

      # Re-fetch the provider's model list and rewrite the on-disk cache, so
      # the pickers on this page (and everywhere else that reads the cache)
      # see the current set instead of a stale snapshot. Nothing is saved to
      # the archive: the catalog is a cache, not a setting.
      def refresh_models(res, req)
        if @app_config
          begin
            Rubot::ModelCatalog.new(config: @app_config).entries
          rescue StandardError => e
            warn "[web] refresh models failed: #{e.class}: #{e.message}"
          end
        end
        redirect_to(res, settings_url)
      end
      alias refresh_model_list refresh_models
      alias refresh_model_catalog refresh_models
      alias refresh_models_list refresh_models
      alias refresh_catalog refresh_models
      alias refresh_models! refresh_models
      alias refresh_model_list! refresh_models
      alias refresh refresh_models

      # Put the saved settings in front of the running process, without a
      # restart: the config is laid over, the pool's copy is refreshed for the
      # actors it spawns next, and the idle actors are dropped so their next turn
      # builds a provider from the new values.
      #
      # A session with a turn in flight is left alone — tearing its actor down
      # mid-answer would lose the answer to save a form — and it picks the
      # setting up on the turn after that.
      def apply_saved_settings
        store = Session.store
        return unless store && @app_config

        @app_config.apply_settings(store.settings)
        return unless @pool

        @pool.refresh_config(@app_config)
        @pool.session_ids.each do |sid|
          next if session_running?(sid)

          @pool.invalidate(sid)
        end
      rescue StandardError => e
        warn "[web] settings applied to this process only: #{e.class}: #{e.message}"
      end

      # --- instagram -----------------------------------------------------

      def instagram_client(persona: "")
        Rubot::Instagram.new(store: Session.store, persona: persona)
      end

      # Which persona's account set a request is about. The card posts the
      # persona it was drawn for; a session id in the query is the fallback for
      # a request that came from a page without that field. A hand-edited form
      # cannot name a persona this install does not have.
      def ig_persona_for(req)
        named = form(req, "persona")
        return named if known_slug?(named)

        sid = req&.query && utf8(req.query["sid"].to_s)
        owner = sid.empty? ? nil : owner_slug(sid)
        owner || default_slug
      end

      # The connect button on the card opens this. A fresh state is minted on
      # every click and kept in its own row, so two handshakes can be in flight
      # at once — one per account.
      def instagram_connect(req, res)
        persona = ig_persona_for(req)
        ig = instagram_client(persona: persona)
        unless Session.store
          return redirect_to(res, "/settings#{token_query}")
        end
        begin
          redirect_to(res, ig.authorize_url(persona: persona))
        rescue Rubot::Instagram::Error => e
          warn "[web] instagram connect: #{e.message}"
          redirect_to(res, "/settings#{token_query}")
        end
      end

      # The "Putuskan" button on the connected card posts here. The account is
      # named so a second connected account can be dropped without touching the
      # default one. The token is deleted from the archive, never echoed back.
      def instagram_disconnect(req, res)
        persona = ig_persona_for(req)
        ig = instagram_client(persona: persona)
        ref = form(req, "account").to_s
        begin
          # The account name comes from the card, but the lookup stays inside
          # this persona's set — a forged name cannot reach another persona's
          # account even if it happens to match one there.
          raise Rubot::Instagram::Error, "Akun Instagram tidak ditemukan" if ref.empty?
          ig.disconnect(username: ref)
          instagram_broadcast(persona: persona)
        rescue Rubot::Instagram::Error => e
          warn "[web] instagram disconnect: #{e.message}"
        end

        # The button is an htmx request targeting #ig-status, so answer with the
        # card itself: htmx swaps it straight back to the connect state. A
        # redirect would reload the whole page and lose the turn's live stream.
        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = instagram_card_markup(persona: persona)
      end

      # Meta sends the browser here with `code` and the state we wrote before
      # leaving. The token never travels through the page: it is written to the
      # archive and the reader is told only the username.
      # Link an account another persona already connected. No OAuth: the token
      # is install-wide, this only grants the current persona access to it.
      def instagram_link(req, res)
        persona = ig_persona_for(req)
        ig = instagram_client(persona: persona)
        ref = form(req, "account").to_s
        begin
          raise Rubot::Instagram::Error, "Akun Instagram tidak ditemukan" if ref.empty?
          ig.link_account(username: ref)
          instagram_broadcast(persona: persona)
        rescue Rubot::Instagram::Error => e
          warn "[web] instagram link: #{e.message}"
        end

        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = instagram_card_markup(persona: persona)
      end

      def instagram_callback(req, res)
        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        state = form(req, "state")
        persona = instagram_client.state_persona(state)
        ig = instagram_client(persona: persona)
        unless Session.store
          res.status = 500
          return res.body = instagram_result_page("Gagal", "Arsip sesi belum terbuka.")
        end
        # An empty persona is a legacy state minted before scoping; it belongs
        # to the install's default. Anything else must be a real persona.
        persona = default_slug if persona.empty?
        unless known_slug?(persona)
          return res.body = instagram_result_page("Gagal", "State OAuth tidak dikenal — coba lagi.")
        end
        # A state that was already used (or never minted) must not reach Meta's
        # token endpoint. complete_authorization checks this too; checking here
        # keeps the failure on the callback page instead of an API call.
        unless ig.valid_state?(state)
          return res.body = instagram_result_page("Gagal", "State OAuth tidak cocok atau sudah kedaluwarsa — coba lagi.")
        end

        begin
          acc = ig.complete_authorization(form(req, "code"), state)
          instagram_broadcast(persona: persona)
          res.body = instagram_result_page("Terhubung", "Instagram terhubung sebagai @#{acc["username"]}.", close: true)
        rescue Rubot::Instagram::Error => e
          res.body = instagram_result_page("Gagal", e.message)
        end
      end

      # The callback runs in the tab the connect button opened. On success the
      # card in the original tab is already being swapped by the broadcast, so
      # this tab has nothing left to say — close it. A failure keeps the page so
      # the reader can see what went wrong; `window.close()` is a no-op when the
      # tab was not opened by script, so the link stays as a way out either way.
      def instagram_result_page(title, message, close: false)
        close_script = close ? "<script>window.close();</script>" : ""
        <<~HTML
          <!DOCTYPE html><html lang="id"><head><meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>rubot · instagram</title>
          <link rel="stylesheet" href="/assets/app.css">
          </head><body><form class="settings-card">
          <h1>#{CGI.escapeHTML(title)}</h1><p>#{CGI.escapeHTML(message)}</p>
          <a class="btn primary" href="/">Kembali ke rubot</a>
          </form>#{close_script}</body></html>
        HTML
      end

      # Every open page is told the connection changed, so a card that said
      # "Connect" can turn into "Terhubung" without a reload. The whole card is
      # sent with hx-swap-oob, which replaces #ig-status wherever it is drawn —
      # in a live turn or in the archived history. A bare text swap could not do
      # that: it would land in the notice slot instead of on the button.
      def instagram_broadcast(persona: "")
        markup = instagram_card_markup(persona: persona, oob: true)
        @event_mutex.synchronize { @event_subs.dup }.each do |sid, queue|
          # Only pages showing this persona get the swap. A card in another
          # persona's conversation must keep showing that persona's account.
          next unless (owner_slug(sid) || default_slug) == persona

          queue << [ :notice, markup ]
        end
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

      # The footer's subagent sheet, moved without a reload. A background run
      # has no turn to report into, so this is the only thing that tells an open
      # page it started, moved, or came back.
      #
      # Whether the sheet is in the row at all changes with the run: it appears
      # when a delegation starts and leaves once the finished mark has timed
      # out. Only that transition replaces the whole element — every other event
      # rewrites the slots inside it, so an open panel is not closed by its own
      # progress.
      def broadcast_subagents(sid)
        runs = @subagent_jobs.runs(sid)
        visible = Rubot::Web::SubagentJobs.visible?(runs)
        changed = @subagent_mutex.synchronize do
          previous = @subagent_visible[sid]
          @subagent_visible[sid] = visible
          previous != visible
        end

        markup = changed ? subagent_sheet_markup(runs) : subagent_slots_markup(runs)
        push_to_session(sid, :"subagent-sheet", markup)
      end

      # Close a run, and arm the footer's hiding with it.
      #
      # The hiding cannot wait for the next event: a finished batch produces no
      # more events, so the row would keep its tick until something unrelated
      # moved. Every finish re-arms, and only the last timer finds nothing
      # running when it wakes — three seconds later, per
      # SubagentJobs::DONE_MARK_SECONDS.
      def finish_subagent(sid, run_id, **state)
        @subagent_jobs.finish(session_id: sid, run_id: run_id, **state)
        hide_subagents_later(sid)
      end

      def hide_subagents_later(sid, after: Rubot::Web::SubagentJobs::DONE_MARK_SECONDS)
        token = @subagent_mutex.synchronize do
          @subagent_hide_token[sid] = @subagent_hide_token[sid].to_i + 1
        end

        Thread.new do
          Thread.current.report_on_exception = false
          sleep after
          hide_finished_subagents(sid, token: token)
        end
      end

      # The hiding itself: the sheet as the page should now show it, which is
      # nothing at all once the finished mark has had its time. Only the
      # transition is acted on — a page that was never told the row was there
      # has nothing to take back, and a timer that woke to a conversation where
      # something is running again is not the current one.
      def hide_finished_subagents(sid, token: nil)
        runs = @subagent_jobs.runs(sid)
        due = @subagent_mutex.synchronize do
          current = token.nil? || @subagent_hide_token[sid] == token
          current && @subagent_visible[sid] && !Rubot::Web::SubagentJobs.visible?(runs)
        end
        broadcast_subagents(sid) if due
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

      # One page, identified by the session it is showing, gets the event. The
      # roster broadcasts reach every page because counts are install-wide; a
      # compaction row or a reload belongs only to the conversation it changed.
      def push_to_session(sid, type, markup)
        @event_mutex.synchronize { @event_subs.dup }.each do |sub, queue|
          next unless sub == sid

          queue << [ type, markup ]
        end
      end

      # The connect card as it should look now. Two callers need it: the SSE
      # broadcast (which needs hx-swap-oob so htmx replaces #ig-status instead
      # of dropping the markup into the notice slot) and the disconnect button's
      # own response (which already has hx-target + outerHTML, so the extra
      # attribute would make htmx swap the same element twice).
      # The locals every render of the connect card needs: the accounts linked
      # to this persona. The card always offers Connect (that is how a second
      # account is added) and lists whatever is already linked below it.
      def ig_account_locals(persona)
        ig = instagram_client(persona: persona)
        { ig_accounts: ig.accounts.map do |a|
            { "id" => a["id"], "username" => a["username"].to_s, "is_default" => a["is_default"] }
          end,
          ig_linkable_accounts: ig.linkable_accounts.map do |a|
            { "id" => a["id"], "username" => a["username"].to_s }
          end }
      end

      def instagram_card_markup(persona: "", oob: false)
        locals = ig_account_locals(persona)
        card = View.render("_instagram_connect", token_query: token_query,
                                                 ig_persona: persona,
                                                 ig_accounts: locals[:ig_accounts],
                                                 ig_linkable_accounts: locals[:ig_linkable_accounts])
        return card unless oob

        card.sub(/<div class="ig-connect-card" id="ig-status">/,
                 '<div class="ig-connect-card" id="ig-status" hx-swap-oob="true">')
      end

      # Due posts are published on a minute ticker, not on a user turn: a
      # schedule is a promise to publish at 07:00 whether or not anyone is
      # talking to the bot then.
      def start_instagram_ticker
        return unless Session.store

        @instagram_thread = Thread.new do
          loop do
            sleep 60
            break unless @running
            begin
              instagram_client.publish_due
            rescue StandardError => e
              warn "[web] instagram ticker: #{e.class}: #{e.message}"
            end
          end
        end
      end

      def settings_url(saved: false)
        query = []
        query << "saved=1" if saved
        query << "token=#{CGI.escape(@token)}" if @token
        query.empty? ? "/settings" : "/settings?#{query.join("&")}"
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

      # The allowance, fetched when the panel behind the status row is opened.
      # Never cached: it is a reading of an account, not a document.
      def render_quota(res, sid)
        return not_found(res) unless owner_slug(sid)

        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = quota_markup(sid)
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
        broadcast_sessions if Session.store&.clear_unread(sid)

        live = live_turn(sid)
        persona = persona_store&.[](slug)
        persona_label = persona ? persona.label : slug.capitalize
        session_label = named_session_label(slug, sid)
        page = history_page(sid, at: at_index(req))
        page = drop_running_tail(page, live) if live && at_index(req).nil?
        live_prompt_shown = live ? prompt_in_tail?(page[:entries], live) : false
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
          usage: usage_locals(sid),
          usage_facts: index_usage_facts(sid),
          subagent_runs: subagent_runs_for_page(sid),
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

      # The model this persona actually talks to. A preset it inherited from
      # the Telegram wizard still resolves, so the header never shows "default"
      # for a persona that is plainly using something else.
      def persona_model(persona)
        return @app_config&.model.to_s if persona.nil?

        if persona.preset
          preset = @app_config&.model_preset(persona.preset)
          return preset["model"] if preset && preset["model"]
        end

        persona.model || @app_config&.model || "default"
      end

      # What the model picker shows as selected. A persona that only carries a
      # preset is offered the preset's model, because saving the form replaces
      # the preset with an explicit model.
      def persona_model_value(persona)
        return "" unless persona
        return persona.model if persona.model

        preset = persona.preset && @app_config&.model_preset(persona.preset)
        preset ? preset["model"].to_s : ""
      end

      # Every model a persona can be pinned to, by id. The provider's cached
      # catalog comes first because that is where the real choices are;
      # config.yml entries follow as named aliases that still resolve through
      # Config. Nothing here reaches the network.
      # One editable row per built-in sub agent, with its current model and
      # thinking override (blank means it follows the built-in definition).
      def settings_subagent_rows
        config = @app_config
        return [] unless config

        Rubot::SubagentRegistry.slugs.map do |slug|
          settings = config.respond_to?(:subagent_settings) ? config.subagent_settings(slug) : {}
          {
            slug: slug,
            name: Rubot::SubagentRegistry[slug]["name"].to_s,
            model: settings["model"].to_s,
            thinking: settings["thinking"].to_s
          }
        end
      end

      # The model presets as editable rows for the settings page. The implicit
      # `default` preset is built from the direct model fields, so it has no
      # stored attributes to edit here and is left out.
      def settings_preset_rows
        config = @app_config
        return [] unless config

        config.model_preset_names.filter_map do |name|
          next if name.casecmp?("default")

          raw = config.model_presets.find { |key, _| key.to_s.casecmp?(name) }&.last
          next unless raw.is_a?(Hash)

          {
            name: name,
            model: raw["model"].to_s,
            max_tokens: raw["max_tokens"].to_s,
            temperature: raw["temperature"].to_s,
            reasoning_effort: raw["reasoning_effort"].to_s
          }
        end
      end

      def model_choices
        config = @app_config
        return [] unless config

        choices = []
        seen = {}

        ModelCatalog.cached_entries(config.catalog_dir).each do |entry|
          id = entry["id"].to_s
          next if id.empty? || seen[id]

          seen[id] = true
          label = entry["name"].to_s
          choices << { value: id, label: label.empty? || label == id ? id : "#{label} (#{id})" }
        end

        Array(config.models).each do |entry|
          next unless entry.is_a?(Hash)

          name = entry["name"].to_s
          next if name.empty? || seen[name]

          seen[name] = true
          choices << { value: name, label: "#{name} (#{entry['model']})" }
        end

        choices.sort_by { |choice| [ choice[:label].downcase, choice[:value] ] }
      end

      # A model from a form, checked against what the provider and config
      # actually offer so a stale form cannot pin a persona to a model that
      # does not exist. Empty means "follow the default model"; an unknown
      # non-empty name falls back to `fallback` so editing a persona does not
      # quietly wipe the choice it already had.
      def persona_model_from(req, fallback: nil)
        name = form(req, "model").strip
        return nil if name.empty?
        return name if known_model?(name)

        fallback
      end

      # The face a persona form submits, or `fallback` when it names none.
      # The picker offers a fixed roster plus a free field ("Emoji lain…"); the
      # free field wins when it is filled, since that is the only way to say
      # "none of those". Either answer is clipped to a single grapheme — the
      # rail draws a face in a twenty-pixel circle, and a pasted string would
      # overflow it.
      def emoji_from(req, fallback: nil, current: nil)
        custom = form(req, "emoji_custom").strip
        choice = form(req, "emoji").strip
        # The field is filled only when the face in use is not on the roster, so
        # a field that still holds exactly that face was not typed — it is the
        # panel's own echo, and a cell clicked afterwards must win over it.
        typed = custom.empty? || custom == current.to_s ? nil : custom
        clipped = (typed || choice).scan(/\X/).first.to_s
        clipped.empty? ? fallback : clipped
      end

      def known_model?(name)
        config = @app_config
        return false unless config
        return true if config.model_entry_by_name(name)

        ModelCatalog.cached_model_ids(config.catalog_dir).include?(name)
      end

      # The model and thinking level this session runs on, read from the
      # store's meta block rather than from the actor: a turn may be running
      # in it, and the page has to render without waiting for that turn.
      # A persona's default effort, as its edit form shows it: what it stores,
      # or the floor every persona starts from.
      def persona_thinking(persona)
        persona&.thinking || DEFAULT_THINKING
      end

      # A level from the persona form, checked against the ones a model
      # understands. An unknown word falls back to what the persona already
      # had, so a stale form cannot erase the default.
      def persona_thinking_from(req, fallback: nil)
        level = form(req, "thinking").to_s.strip.downcase
        return fallback if level.empty?
        return level if Persona::THINKING_LEVELS.include?(level)

        fallback
      end

      # The tool-row view a posted form asks for. A value the picker cannot
      # produce is not a third mode nothing draws, it is a fallback.
      def persona_tool_output_from(req, fallback: nil)
        mode = form(req, "tool_output").to_s.strip.downcase
        return fallback if mode.empty?
        return mode if Persona::TOOL_OUTPUT_MODES.include?(mode)

        fallback
      end

      # How this conversation draws the tool calls of its turns: its persona's
      # choice, since a call log is noisy in the same way for every turn.
      def session_tool_output(sid)
        persona = persona_store&.[](owner_slug(sid))
        persona ? persona.tool_output : Persona::DEFAULT_TOOL_OUTPUT
      end

      # The model this session runs on. The picker lists real models only, so
      # it has to start on the one the session would actually use: its own
      # override, the persona's, or the config's default.
      def session_model(sid)
        meta = session_meta(sid)
        return meta["model_override"].to_s unless meta["model_override"].to_s.empty?

        persona = persona_store&.[](owner_slug(sid))
        return persona.model if persona && persona.model

        config = @app_config
        return "" unless config

        entry = config.active_model_entry
        name = entry["name"].to_s
        name.empty? ? config.name : name
      end

      # Its own choice, then the persona's default, then the effort the
      # persona's preset carries. There is no "default" entry in the picker, so
      # this always answers a concrete level.
      def session_thinking(sid)
        meta = session_meta(sid)
        return meta["thinking_level"].to_s unless meta["thinking_level"].to_s.empty?

        persona = persona_store&.[](owner_slug(sid))
        return persona.thinking if persona && persona.thinking

        preset = @app_config&.model_preset(persona&.preset)
        level = preset.is_a?(Hash) ? preset["reasoning_effort"].to_s : ""
        return level unless level.empty?

        DEFAULT_THINKING
      end

      def session_meta(sid)
        store = Session.store
        return {} unless store

        store.session_meta(sid)
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

      # The facts for the panel on first paint. The report is asked for once and
      # used twice — by the row and by the panel — so the page never shows two
      # different numbers side by side.
      def index_usage_facts(sid)
        usage_facts(session_report(sid) || {})
      rescue StandardError
        usage_facts({})
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

      # --- personas (create, edit) ---------------------------------------

      # The skills directory as the agent sees it: one tree for the whole
      # install, so what the form lists and what a session may load are the
      # same set of names. The same legacy fallbacks the agent reads are
      # included, or the form would hide skills the prompt still advertises.
      # Scanned per render rather than kept, because a skill installed by hand
      # should show up on the next page load and not on the next restart.
      def skills_for_form
        config = @app_config
        SkillRegistry.new(workspace: config&.skills_workspace,
                          extra_workspaces: config ? config.legacy_skills_workspaces : [])
      end

      # Where a skill has to be dropped to show up in the picker, shortened to
      # ~ so the hint stays one line. The picker is a list of switches, so it
      # says where skills live instead of offering to install one.
      def skills_dir_label
        dir = skills_for_form.skills_dir
        return "" if dir.nil? || dir.to_s.empty?

        home = Dir.home.to_s
        home != "/" && dir.start_with?("#{home}/") ? "~#{dir.delete_prefix(home)}" : dir
      end

      # One row per installed skill, carrying the state both persona forms need:
      # whether this persona has it switched on, and whether the persona
      # requires it (a required skill cannot be switched off from here).
      def persona_skill_choices(persona = nil)
        skills_for_form.all.values.map do |skill|
          {
            name: skill.name,
            description: skill.description.to_s,
            enabled: persona.nil? || persona.skill_enabled?(skill.name),
            required: persona ? Array(persona.skills).include?(skill.name) : false
          }
        end
      end

      # The skills a submitted persona form left unticked, or nil when the form
      # carried no list at all — another editor of the same record, which must
      # not be read as "switched everything off". The list is stored as the
      # exceptions, so a skill installed later is on for every persona until
      # someone decides otherwise.
      def persona_disabled_from(req, required: [])
        return nil unless form_field?(req, "skills_present")

        chosen = form_values(req, "skill")
        skills_for_form.names - chosen - Array(required).map(&:to_s)
      end

      def create_persona(req, res)
        store = persona_store
        return bad_request(res) unless store

        slug = form(req, "slug").strip.downcase.tr(" ", "-")
        unless PersonaStore.valid_slug?(slug) && !known_slug?(slug)
          res.status = 422
          res.body = %(<p class="form-error">Slug tidak valid atau sudah dipakai. Pakai huruf kecil, angka, tanda hubung.</p>)
          return
        end

        prompt = form(req, "system_prompt").strip
        store.set(slug, Persona.new(
          slug: slug,
          name: form(req, "name").strip.empty? ? nil : form(req, "name").strip,
          emoji: emoji_from(req, fallback: Persona::EMOJI_CHOICES.first),
          model: persona_model_from(req),
          thinking: persona_thinking_from(req, fallback: DEFAULT_THINKING),
          tool_output: persona_tool_output_from(req, fallback: Persona::DEFAULT_TOOL_OUTPUT),
          system_prompt: prompt.empty? ? nil : prompt,
          disabled_skills: persona_disabled_from(req)
        ))
        store.prepare_workspace(slug, seed_from: @app_config&.workspace)

        redirect(res, "/p/#{slug}", req)
      end

      # Changing a persona that already exists: its face, its name and the
      # prompt it speaks with. The slug is not one of the fields — it is the
      # key in personas.json and the name of the workspace directory, so
      # renaming it would strand the SOUL.md, skills and memory the persona
      # already owns.
      def edit_persona(req, res, slug)
        store = persona_store
        return bad_request(res) unless store
        return not_found(res) unless known_slug?(slug)

        current = store[slug]
        return not_found(res) unless current

        name = form(req, "name").strip
        emoji = form(req, "emoji").strip
        prompt = form(req, "system_prompt").strip

        # A form without a model field is not asking about the model. `form`
        # cannot tell "absent" from "empty" — both answer "" — so the field's
        # presence is read from the query itself: an editor that only knows
        # name, face and prompt leaves the model and a preset inherited from
        # the Telegram wizard alone, instead of silently dropping both and
        # pinning the persona to the global default.
        keeps_model = !form_field?(req, "model")
        model = keeps_model ? current.model : persona_model_from(req, fallback: current.model)
        keeps_thinking = !form_field?(req, "thinking")
        thinking = keeps_thinking ? current.thinking : persona_thinking_from(req, fallback: current.thinking)
        keeps_tool_output = !form_field?(req, "tool_output")
        tool_output = keeps_tool_output ? current.tool_output : persona_tool_output_from(req, fallback: current.tool_output)

        # The same rule for the skills: a form that posts no list is not
        # saying anything about them, and the personas created by the Telegram
        # wizard never post one.
        disabled_skills = persona_disabled_from(req, required: current.skills)
        disabled_skills = current.disabled_skills if disabled_skills.nil?

        store.set(slug, Persona.new(
          slug: slug,
          name: name.empty? ? nil : name,
          emoji: emoji_from(req, fallback: current.emoji, current: current.emoji),
          accent: current.accent,
          # The picker edits the model itself, so a preset inherited from the
          # Telegram wizard is replaced rather than left to win the tie — but
          # only by a form that actually carries the picker.
          preset: keeps_model ? current.preset : nil,
          model: model,
          thinking: thinking,
          tool_output: tool_output,
          system_prompt: prompt.empty? ? nil : prompt,
          skills: current.skills,
          disabled_skills: disabled_skills,
          ref: current.ref,
          created_at: current.created_at
        ))
        reload_persona_actors(slug)

        redirect(res, return_to(slug, form(req, "session_id").strip), req)
      end

      # Back to the conversation the form was opened from, as long as it is
      # still this persona's; otherwise to the persona's newest one.
      def return_to(slug, sid)
        return "/s/#{sid}" if sid.match?(/\A[a-z0-9][a-z0-9_~-]{0,90}\z/) && owner_slug(sid) == slug

        "/p/#{slug}"
      end

      # An actor that is already spawned holds the old prompt in its agent, so
      # the next turn would still answer in the old voice. Idle sessions are
      # dropped and rebuilt from the store on their next message; a session
      # with a turn in flight is left alone, because invalidating it would kill
      # the answer being written — its next turn picks the edit up instead.
      def reload_persona_actors(slug)
        pool = @pool
        return unless pool

        pool.session_ids.each do |sid|
          next unless owner_slug(sid) == slug
          next if @active[sid]

          begin
            pool.invalidate(sid)
          rescue StandardError => e
            warn "[persona] could not reload #{sid}: #{e.class}: #{e.message}"
          end
        end
      end

      # Point the agent's file tools at this conversation, so a picture they
      # hand back lands where the page can serve it. Telegram sets the same
      # field with a chat id; here it is a folder. Plain strings only, because
      # the value crosses into the session's Ractor.
      #
      # The cron tool is told which workspace the conversation runs in, so a
      # reminder written in a persona's chat is filed with that persona — the
      # same thing a Telegram topic does.
      def prepare_delivery(sid)
        bind_file_delivery(sid)
        bind_cron_delivery(sid)
      end

      def bind_cron_delivery(sid)
        cron = session_for(sid).tools.get("cron")
        return unless cron

        cron.delivery_context = {
          channel: "web",
          workspace: workspace_for_session(sid),
          # Which persona the reminder belongs to, so a fired job can open a
          # conversation there instead of falling back to the default one.
          slug: owner_slug(sid)
        }
      end

      def workspace_for_session(sid)
        rooted = @pool.workspace_for_session(sid) if actor_mode? && @pool.respond_to?(:workspace_for_session)
        rooted || @app_config&.workspace
      rescue StandardError
        @app_config&.workspace
      end

      # What a file is called when it is downloaded: the stored name minus the
      # id in front of it. A name the slug could not keep — a file called only
      # in symbols — falls back to a word for what it is.
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
          res.body = %(<div class="notice"><div class="error">Pesan kosong.</div></div>)
          return
        end

        turn = Turn.new(id: "t#{SecureRandom.hex(6)}", session_id: sid, prompt: text,
                        tool_output: session_tool_output(sid))

        @turns_mutex.synchronize do
          # A second POST while one turn is running must not queue behind it:
          # the browser is expected to steer or stop instead.
          if @active[sid]
            res.status = 409
            res.body = %(<div class="notice"><div class="error">Masih ada giliran yang berjalan. Tunggu sebentar atau tekan Stop.</div></div>)
            return
          end
          # A compaction rewrites the transcript this prompt would be appended
          # to, so a prompt must not start while one is running. The browser
          # normally holds the composer closed, but a dropped stream can make it
          # let go early; the truth is kept here, where the transcript is.
          if @compacting[sid]
            res.status = 409
            res.body = %(<div class="notice"><div class="error">Sedang meringkas percakapan. Tunggu sebentar, lalu kirim lagi.</div></div>)
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
      # Hand a delegated run to an actor of its own and return at once.
      #
      # The parent turn is not held: the conversation can take the next prompt
      # while this works. State goes into @subagent_jobs, which is what the
      # footer draws and what survives the turn; the answer goes to the archive,
      # where `subagent_results` picks it up.
      def start_delegate(sid, request)
        run_id = request[:run_id].to_s
        slug = request[:agent].to_s
        task = request[:task].to_s
        return if run_id.empty?

        @subagent_jobs.start(session_id: sid, run_id: run_id, agent: slug, task: task)

        handle = @pool&.delegate(parent_session: sid, slug: slug, run_id: run_id, model: request[:model])
        unless handle
          finish_subagent(sid, run_id, status: "failed",
                          error: "persona #{slug} tidak dikenal")
          finish_delegate_run(run_id, status: "failed", error: "persona #{slug} tidak dikenal")
          report_subagents_later(sid)
          return
        end

        Thread.new do
          Thread.current.report_on_exception = false
          begin
            answer = handle.process(
              task,
              stream: false,
              on_tool_call: ->(name, args, _snapshot) {
                @subagent_jobs.update(session_id: sid, run_id: run_id, phase: "tool",
                                      detail: "#{name} #{summarize_arguments(args)}")
              }
            )
            finish_subagent(sid, run_id, status: "done", result: answer.to_s)
            finish_delegate_run(run_id, status: "done", sub_session: handle.session_id, result: answer.to_s)
            notify_delegate_end(sid, slug, status: "done", result: answer.to_s)
          rescue StandardError => e
            error = "#{e.class}: #{e.message}"
            finish_subagent(sid, run_id, status: "failed", error: error)
            finish_delegate_run(run_id, status: "failed", sub_session: handle.session_id, error: error)
            notify_delegate_end(sid, slug, status: "failed", error: error)
          ensure
            # The run is over, so its actor has nothing left to do. Dropping it
            # keeps a conversation that delegates often from holding one Ractor
            # per run until the process ends.
            @pool&.invalidate(handle.session_id)
            # Last one to land hands the whole batch back to the conversation
            # that asked for it (see #report_subagents_when_done).
            report_subagents_when_done(sid)
          end
        end
      end

      # The audit row the parent actor opened is closed here, because the run
      # outlived the actor that started it.
      def finish_delegate_run(run_id, status:, sub_session: nil, result: nil, error: nil)
        store = Session.store
        return unless store

        store.finish_subagent_run(run_id: run_id, status: status, sub_session: sub_session,
                                  error: error, result: result)
      rescue StandardError => e
        warn "[subagent] could not close run #{run_id}: #{e.class}: #{e.message}"
      end

      # A background run finishes after the turn that asked for it is over, so
      # there is nothing on screen waiting to be told. The lock screen is the one
      # place that can still reach a reader who walked away, so a finished
      # delegation rings: this is news they asked for, arriving when it is
      # ready, not a report on something they are already watching.
      def notify_delegate_end(sid, slug, status:, result: nil, error: nil)
        persona_slug = owner_slug(sid) || default_slug
        body = if status.to_s == "failed"
          "#{slug} gagal: #{error}"
        else
          line = result.to_s.lines.map(&:strip).reject(&:empty?).first
          line ? "#{slug}: #{line}" : "#{slug} selesai."
        end

        notify_push(persona_slug,
                    title: persona_title(persona_slug),
                    body: shorten(body, TURN_NOTIFY_CHARS),
                    url: session_url(sid))
      rescue StandardError => e
        warn "[web] subagent notification: #{e.class}: #{e.message}"
      end

      # Hand a finished batch back to the conversation that asked for it.
      #
      # Delegation is asynchronous, so the answer cannot be the return value of
      # the `delegate` call; waiting for the model to remember `subagent_results`
      # meant answers sat unread for hours. When the last run of a batch lands,
      # the conversation gets a turn of its own carrying what came back, and the
      # reader sees the agent react without having asked again.
      #
      # Only when nothing is still running: the batch is the unit, so three runs
      # finishing together produce one report, not three. Answers the model has
      # already pulled with `subagent_results` are not repeated — the store marks
      # what it handed over.
      def report_subagents_when_done(sid)
        claim = claim_subagent_results(sid)
        return unless claim

        begin
          prepare_delivery(sid)
          deliver_subagent_report(sid, claim)
          broadcast_sessions
          broadcast_usage(sid)
        rescue StandardError => e
          warn "[subagent] could not report results: #{e.class}: #{e.message}"
          # Answers marked read and then lost are the one thing a background run
          # cannot come back from, so a report that failed hands them back.
          release_report(sid, claim)
        ensure
          @subagent_mutex.synchronize { @subagent_reporting.delete(sid) }
        end
      end

      # Best effort, and never a second failure: the pile is for the next
      # attempt, not for this one.
      def release_report(sid, claim)
        store = Session.store
        return unless store

        store.release_subagent_results(Array(claim[:results]).map { |run| run[:run_id] })
      rescue StandardError => e
        warn "[subagent] could not release results: #{e.class}: #{e.message}"
      end

      # The report itself.
      #
      # Background, not a user message: the answers are handed to the model as
      # context and only its reply joins the transcript. The reader asked for the
      # work; they did not say "Hasil subagent yang sudah selesai".
      #
      # Where the reply goes depends on what the page is showing. Idle, it is
      # appended to the thread and filled in as it is written, so the reader
      # watches it arrive. While a turn of their own is running, a block appended
      # now would sit before the answer still being written, and only a redraw
      # can put the two in the archive's order.
      def deliver_subagent_report(sid, claim)
        text = subagent_report_text(claim[:results], more: claim[:more])
        label = "Hasil subagent yang sudah selesai, dari kerja yang kamu delegasikan:\n\n"

        index = next_entry_index(sid)
        broadcast_report_entry(sid, index, "")

        last_sent = 0.0
        begin
          reply = with_report_deadline(sid) do
            session_for(sid).process_background(text, label: label) do |written|
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              next if now - last_sent < REPORT_STREAM_SECONDS

              last_sent = now
              broadcast_report_entry(sid, index, written)
            end
          end
          # The last passage is always sent: a fixed cadence must not be what
          # decides whether the reader sees the end of the answer.
          broadcast_report_entry(sid, index, reply.to_s)
        rescue StandardError
          # The block opened for the answer would stand there empty, which is
          # worse than nothing: take it back and let the caller log the failure.
          if index
            push_to_session(sid, :append, %(<div id="m-#{index}" hx-swap-oob="delete"></div>))
          end
          raise
        end
      end

      # A report turn is a provider request nobody is watching, so a read that
      # never returns would hold the conversation's answers out of sight for good
      # — the claim never released and no line in the log.
      #
      # The deadline is watched by a thread that reads the stuck thread's stack
      # before it interrupts it: an exception raised by `Timeout` carries the
      # timer's stack, not the place the work was blocked, which is the one thing
      # that matters here.
      def with_report_deadline(sid)
        target = Thread.current
        watchdog = Thread.new do
          Thread.current.report_on_exception = false
          sleep REPORT_TIMEOUT_SECONDS
          next unless target.alive?

          warn "[subagent] report for #{sid} still running after #{REPORT_TIMEOUT_SECONDS}s at: " \
               "#{Array(target.backtrace).first(12).join(" | ")}"
          target.raise(Timeout::Error, "report deadline")
        end

        yield
      ensure
        watchdog&.kill
      end

      # The entry the report becomes, as the page draws it.
      #
      # Two shapes, and the difference is the whole point. The first passage
      # appends the block; every passage after it replaces only the prose
      # *inside* that block. Replacing the block each time re-created the
      # element, and `.turn` carries the animation that plays when a turn
      # arrives — replayed every 150ms it read as a blinking answer instead of a
      # growing one.
      def broadcast_report_entry(sid, index, text)
        if index.nil?
          # Nothing to anchor the block to (no archive): draw it whole, once.
          return if text.to_s.empty?

          entry = { kind: :turn, idx: nil, items: [ { kind: :text, text: text.to_s } ] }
          markup = View.render("_entry", entry: entry, landed: false, token_query: token_query,
                                         ig_accounts: [], ig_linkable_accounts: [], ig_persona: "")
          push_to_session(sid, :append, %(<div id="thread" hx-swap-oob="beforeend">#{markup}</div>))
          return
        end

        if text.to_s.empty?
          # `is-report` is what the page reads to know this block is not the turn
          # the reader is watching: the script follows a turn's own text, and
          # following this one scrolled the answer being read upward.
          block = %(<div class="turn is-done is-report" id="m-#{index}">) +
                  %(<div class="turn-body"><div class="text" id="report-#{index}"></div></div></div>)
          push_to_session(sid, :append, %(<div id="thread" hx-swap-oob="beforeend">#{block}</div>))
        else
          push_to_session(sid, :append,
                          %(<div id="report-#{index}" hx-swap-oob="innerHTML">#{View.prose(text)}</div>))
        end
      end

      # Where the next message of a conversation will land. The report is drawn
      # with it so that the block the page is given and the block a later load
      # draws share one anchor.
      def next_entry_index(sid)
        store = Session.store
        return nil unless store

        store.last_index(sid).to_i + 1
      end

      # The report runs a turn of its own, so it must never hold the caller: a
      # delegation that failed on the way in still has to return at once, and
      # that path is the turn's own thread.
      def report_subagents_later(sid)
        Thread.new do
          Thread.current.report_on_exception = false
          report_subagents_when_done(sid)
        end
      end

      # Takes the claim and reads the answers under one lock, so two runs
      # finishing in the same breath cannot both decide they were the last one.
      #
      # Newest first: the batch that just landed is the news, and a backlog
      # waiting behind it must not push it into the next report. One row more
      # than will be quoted is read, which is how the report knows to say that
      # something is still waiting.
      def claim_subagent_results(sid)
        @subagent_mutex.synchronize do
          # A claim is a timestamp, not a flag: if the report thread dies without
          # its ensure (a hung provider read), a permanent "in progress" would
          # block every later report for this conversation. Past the window the
          # claim is worthless and the pile is taken again.
          claimed_at = @subagent_reporting[sid]
          next nil if claimed_at && (Time.now - claimed_at) < REPORT_CLAIM_SECONDS
          next nil unless @running
          # A report turn is queued behind whatever the actor is doing, and a
          # turn of the reader's own can take minutes. Waiting inside that queue
          # is not the report hanging, so it is never started from here: the end
          # of a turn asks again (see Web#report_later).
          next nil if live_turn(sid)
          next nil if @subagent_jobs.running_count(sid).positive?

          store = Session.store
          next nil unless store

          pending = store.pending_subagent_results(sid, limit: SUBAGENT_REPORT_LIMIT + 1,
                                                   newest_first: true)
          next nil if pending.empty?

          results = pending.first(SUBAGENT_REPORT_LIMIT)
          store.mark_subagent_results_reported(results.map { |run| run[:run_id] })
          @subagent_reporting[sid] = Time.now
          { results: results, more: pending.size > results.size }
        end
      end

      # What the conversation is told. It reads as a report rather than as the
      # reader speaking, and it keeps the question each run was given: an answer
      # without its task is unreadable a day later.
      def subagent_report_text(results, more: false)
        lines = []
        results.each do |run|
          lines << "## #{run[:agent_slug]}"
          task = run[:task].to_s.strip
          lines << "Tugas: #{task}" unless task.empty?
          lines << ""
          lines << run[:result].to_s.strip
          lines << ""
        end
        if more
          lines << "Masih ada hasil lain yang belum dibaca: panggil `subagent_results` untuk sisanya."
          lines << ""
        end
        lines.join("\n").rstrip
      end

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
            turn.tool_started(name, summarize_arguments(args), op: args.to_h["operation"])
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

      # Hand a finished batch over on a thread of its own: the turn that just
      # ended is done, and a report is a provider request the reader should not
      # wait for through this one.
      def report_later(sid)
        return unless @subagent_reporting[sid].nil?
        return if @subagent_jobs.runs(sid).empty?

        Thread.new do
          Thread.current.report_on_exception = false
          report_subagents_when_done(sid)
        end
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

      # The footer's sheet, whole, as an out-of-band swap. Used when what it
      # shows has to appear or disappear: the element in the page carries
      # `hidden` while there is nothing to say, so replacing it is the only way
      # to bring it into the row — and the only way to take it back out.
      def subagent_sheet_markup(subagents)
        View.render("_subagent_sheet", subagents: subagents)
            .sub(%(<details class="usage-sheet usage-sheet-subagents" id="subagent-sheet"),
                 %(<details class="usage-sheet usage-sheet-subagents" id="subagent-sheet" hx-swap-oob="true"))
      end

      # The slots inside that sheet, for every event while it stays on screen.
      # Only these are replaced, never the <details> holding them: a reader who
      # opened the panel keeps it open while the run it is describing moves on.
      def subagent_slots_markup(subagents)
        state = %(<span class="subagent-state" id="subagent-state" hx-swap-oob="innerHTML">) +
                View.render("_subagent_state", subagents: subagents) + %(</span>)
        rows = %(<div id="subagent-sheet-body" hx-swap-oob="innerHTML">) +
               View.render("_subagent_rows", subagents: subagents) + %(</div>)
        state + rows
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

        usage_markup_with(metrics_locals(Rubot::UsageReport.metrics(report)),
                          facts: usage_facts(report))
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

      def summarize_arguments(args)
        return "" unless args.is_a?(Hash) && !args.empty?

        key = %w[command path query url pattern title].find { |k| args.key?(k) } || args.keys.first
        args[key].to_s.split("\n").first.to_s[0, 100]
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
          turn.each_event(from_now: true) do |type, payload|
            break unless @running

            write_event(out, turn, type, payload)
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
        opening = [[:sidebar, sidebar_markup(sid)]]
        opening << [:"subagent-sheet", subagent_sheet_markup(subagent_runs_for_page(sid))] unless sid.to_s.empty?
        opening << [:"compact-done", "done"] unless compacting?(sid)
        opening
      end

      # The delegated runs of a conversation, and the note that they have just
      # been drawn whole on a page. Both the page itself and the stream opening
      # put the sheet on screen, so both leave the same record behind: the next
      # event may then swap only the slots inside it instead of replacing the
      # element under a reader whose panel is open.
      def subagent_runs_for_page(sid)
        runs = @subagent_jobs.runs(sid)
        @subagent_mutex.synchronize do
          @subagent_visible[sid] = Rubot::Web::SubagentJobs.visible?(runs)
        end
        runs
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

      def listen_for_events(sid, queue)
        @event_mutex.synchronize { @event_subs << [ sid, queue ] }
      end

      def stop_listening_for_events(queue)
        @event_mutex.synchronize { @event_subs.reject! { |_sid, other| other.equal?(queue) } }
      end

      def write_event(out, turn, type, payload)
        case type
        when :turn
          sse(out, "turn", render_timeline(turn))
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
        when :sidebar
          # Same trick for the sidebar and the header: what the conversation is
          # called is only known after the first turn has been saved.
          sse(out, "sidebar", payload.to_s)
        when :heartbeat
          out.write(": keepalive\n\n")
          out.flush if out.respond_to?(:flush)
        when :done
          sse(out, "turn", render_timeline(turn))
          # The footer's own sheet is not touched here: a background run has
          # already reported itself through the jobs registry, and a synchronous
          # one has no footer row at all. Writing it from the turn as well would
          # put two sources on one element.
          sse(out, "done", " ")
        end
      end

      def render_timeline(turn)
        persona = owner_slug(turn.session_id) || default_slug
        View.turn_body(turn, token_query: token_query, ig_persona: persona,
                             **ig_account_locals(persona))
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

      # A fired job has no browser waiting on it, so it is delivered by
      # writing to a conversation: the page shows it the next time it asks for
      # the persona's sessions. A job that asked for its own conversation gets
      # a new session each run, which is how a daily practice prompt arrives as
      # a fresh chat instead of piling up in one.
      def handle_cron_fire(result)
        case result[:mode]
        when "agent_turn"
          deliver_cron_turn(result)
        when "deliver"
          # A "deliver" job has no turn to run: it is a message written for the
          # moment it fires. There is no session to open, so the notification
          # points at the persona's own conversation instead.
          slug = result[:slug].to_s
          slug = default_slug unless known_slug?(slug)
          notify_push(
            slug,
            title: persona_title(slug),
            body: result[:result][:deliver_message].to_s.strip.then { |text| text.empty? ? cron_note(result) : text },
            url: session_url(session_id(slug))
          )
        else
          warn "[web] cron fired (#{result[:mode]}) with nowhere to put it in the browser"
        end
      rescue StandardError => e
        warn "[web] cron delivery failed: #{e.class}: #{e.message}"
      end

      def deliver_cron_turn(result)
        slug = result[:slug].to_s
        slug = default_slug unless known_slug?(slug)

        sid = if result[:new_session]
          new_session_id(slug)
        else
          session_id(slug)
        end

        prepare_delivery(sid)
        session = session_for(sid)
        reply = session.process_cron(
          result[:result][:agent_message],
          fresh: result[:new_session] ? true : false
        )

        # A conversation the job opened has no user message to be named after,
        # so it takes the job's own description and the day it ran.
        if result[:new_session] && session.respond_to?(:set_session_title)
          session.set_session_title(cron_session_title(result))
        end

        # Whoever has the app open hears about it now, rather than on the next
        # reload — any persona's page, because the roster and the drawer's count
        # are the install's.
        broadcast_sessions

        # And whoever does not: a reminder is the whole point of firing while
        # the app is closed. Pages that are open are skipped by the worker
        # itself, so this cannot ring twice for the same news.
        #
        # A conversation the job just opened has already been given its first
        # line by the persona, and that line is the better invitation: the
        # job's description says what the job is ("Daily English speaking
        # practice"), while the opening says why to unlock the phone ("What's
        # one small win you had this week?"). So a new conversation announces
        # itself in its own words, and a reminder — which has no opening worth
        # quoting — keeps saying what it is.
        title, note = if result[:new_session]
          hook = cron_hook(slug, reply)
          [ hook, cron_note(result, reply: reply, spoken: hook) ]
        else
          [ persona_title(slug), cron_note(result) ]
        end

        notify_push(slug, title: title, body: note, url: session_url(sid))
      end

      # What a notification says about a fired job.
      #
      # With a reply to quote, it says whatever the persona asked — a question
      # is the one thing a reader can answer straight from the lock screen. A
      # reply with no question is quoted by its first line. Nothing to quote
      # leaves the description, which is the reader's own words for the job
      # ("minum air", "cek inbox") and more useful than a timestamp — and it is
      # sealed to the device, so a push service never reads it.
      def cron_note(result, reply: nil, spoken: nil)
        lines = cron_lines(reply).reject { |candidate| candidate == spoken }
        # A question is what a reader can answer straight from the lock screen,
        # so it is preferred over a line that only sets the scene.
        line = lines.find { |candidate| candidate.include?("?") } || lines.first
        return shorten(line, TURN_NOTIFY_CHARS) if line

        label = result[:description].to_s.gsub(/\s+/, " ").strip
        label.empty? ? "Sesi terjadwal sudah siap." : shorten(label, TURN_NOTIFY_CHARS)
      end

      # The bold line on the lock screen for a conversation that just began: the
      # first thing the persona said, which is the invitation itself.
      def cron_hook(slug, reply)
        line = cron_lines(reply).first
        line ? shorten(line, NOTIFY_HOOK_CHARS) : persona_title(slug)
      end

      # A reply is markdown written for a page — headings, bold, code spans and
      # blank lines between paragraphs. A notification is one glance at one
      # line, so the punctuation that only means something next to a stylesheet
      # is dropped and the lines are handed back in the order they were spoken.
      def cron_lines(reply)
        reply.to_s.split("\n").map do |line|
          line.strip
              .sub(/\A[#>*\-]+\s*/, "")
              .gsub(/\*\*|__|`/, "")
              .gsub(/\s+/, " ")
              .strip
        end.reject(&:empty?)
      end

      def shorten(text, limit)
        Rubot::Formatting.shorten(text, limit)
      end

      def cron_session_title(result)
        label = result[:description].to_s.strip
        label = "Scheduled session" if label.empty?
        "#{label} — #{Time.now.strftime('%Y-%m-%d')}"
      end
    end
  end
end
