# frozen_string_literal: true

require "webrick"
require "securerandom"
require "uri"
require "fileutils"
require "json"

require_relative "../channel"
require_relative "../opencode_usage"
require_relative "../persona_store"
require_relative "../session"
require_relative "../tools/send_file"
require_relative "../web/diff"
require_relative "../web/highlight"
require_relative "../web/notifier"
require_relative "../web/push"
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
      # How long a turn has to run before finishing it is worth a notification.
      # A reply that takes a second is answered while the reader is still
      # looking at the box they typed into; one that takes a minute is the kind
      # of thing people walk away from. Devices with the app in front skip the
      # buzz themselves, so this number only decides what counts as "a wait".
      TURN_NOTIFY_AFTER = 20
      # A notification body is read on a lock screen: two or three lines, one
      # glance. The whole answer is one tap away, so what travels is the gist.
      TURN_NOTIFY_CHARS = 140
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

      # What the page hands back: the pictures the agent sends through
      # send_file, and the two documents a browser already opens on its own —
      # a PDF and a markdown note. The name the server writes is a hex id this
      # channel generated, an optional slug of the file's own name, and a known
      # extension — the slug is what makes a download read like a file, the id
      # is what makes it impossible to guess.
      MEDIA_EXTENSIONS = %w[png jpg gif webp pdf md].freeze
      # A markdown note is served as text, not as text/markdown: a browser
      # downloads a type it has no viewer for, and a note the reader has to
      # save first is a note they cannot read. PDFs are served as PDFs and
      # opened by the browser's own viewer.
      MEDIA_TYPES = {
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".pdf" => "application/pdf",
        ".md" => "text/plain; charset=utf-8"
      }.freeze
      # The shape a stored name always has, spelled once and used by the route
      # that serves it and by the reader that picks it back out of a tool
      # result.
      MEDIA_NAME_SOURCE = "[0-9a-f]{32}(?:-[a-z0-9-]{1,60})?\\.(?:#{MEDIA_EXTENSIONS.join("|")})"
      MEDIA_NAME = /\A#{MEDIA_NAME_SOURCE}\z/

      SLUG_PATH = %r{\A/p/([a-z0-9][a-z0-9_-]{0,31})\z}
      SESSION_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})\z}
      SESSION_HISTORY_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/history\z}
      SESSION_RECENT_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/recent\z}
      SESSION_TURN_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/turn\z}
      SESSION_MEDIA_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/media/(#{MEDIA_NAME_SOURCE})\z}
      SESSION_DELETE_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/delete\z}
      SESSION_PIN_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/pin\z}
      SESSION_QUOTA_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/quota\z}
      SESSION_REPIN_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/repin\z}
      PERSONA_SESSIONS_PATH = %r{\A/p/([a-z0-9][a-z0-9_-]{0,31})/sessions\z}
      PERSONA_EDIT_PATH = %r{\A/p/([a-z0-9][a-z0-9_-]{0,31})/edit\z}
      # Where the token form posts. Not under /s/ or /p/ because it belongs to
      # the way in rather than to any conversation behind it.
      UNLOCK_PATH = "/unlock"

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
      # Web Push, named apart from `Web` for the same reason. `Push` is the
      # protocol (seal a payload, sign a request); `Vapid` is the key that
      # signs, kept in one file for this install.
      PushTransport = Rubot::Web::Push
      VapidKey = Rubot::Web::Vapid
      # The part that decides who gets told and what it costs in round trips.
      PushNotifier = Rubot::Web::Notifier

      # What a newly created persona starts with when the form leaves a field
      # blank.
      EMOJI_CHOICES = %w[🤖 🧭 ✍️ 📚 🧪 🎨 🛠️ 🔍 🧠 💼].freeze

      attr_reader :host, :port

      def initialize(agent: nil, pool: nil, app_config: nil, channel_config: {})
        @host = (channel_config["host"] || DEFAULT_HOST).to_s
        @port = (channel_config["port"] || DEFAULT_PORT).to_i
        @default_slug = (channel_config["persona"] || DEFAULT_SLUG).to_s
        @token = channel_config["token"]&.to_s
        @access_log = channel_config["access_log"]
        @turns = {}
        @active = {}
        @turns_mutex = Mutex.new
        # Pages that are open and idle, listening for news that arrives on its
        # own. Each one keeps its session id, which is what decides the active
        # row and the persona it should hear about.
        @event_subs = []
        @event_mutex = Mutex.new
        @personas = nil
        # Built on first use: reading (or generating) the key is a file that
        # most boots never need, and a channel with push unused should not have
        # written one. The mutex matters on that first use: two threads racing
        # to build it could each generate a key, and the one that lost the file
        # would sign with a key the browsers never subscribed to.
        @vapid = nil
        @vapid_mutex = Mutex.new
        @vapid_subject = (channel_config["vapid_subject"] || VapidKey::SUBJECT).to_s

        # How long a turn has to run before its ending is worth a knock on the
        # door. Zero turns the notifications off; a reader who finds the buzz
        # too eager raises the number rather than hunting for a switch.
        @turn_notify_after = (channel_config["turn_notify_after"] || TURN_NOTIFY_AFTER).to_i
        super
      end

      def start
        @running = true
        start_cron_listener { |result| handle_cron_fire(result) } if actor_mode?
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

      def stop
        @running = false
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

            Session.entry_from_row(row)
          end
        else
          dir = @app_config&.sessions_dir
          return [] unless dir && Dir.exist?(dir)

          Dir.glob(File.join(dir, "#{base}*.json"))
            .filter_map { |path| Session.describe(path) }
            .select { |entry| entry[:id] == base || entry[:id].to_s.start_with?(prefix) }
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
        pinned = entries.select { |entry| pinned_entry?(entry) }
                        .sort_by { |entry| entry[:pinned_at].to_s }
                        .reverse
                        .first(PINNED_LIMIT)
        recent = recent_entries(entries, current_sid)
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

      # One block of the recent list, the way the "load more" button asks for
      # it: exactly the rows after the ones already on screen, so appending the
      # answer cannot repeat a row. Past the last block the answer is empty —
      # the list shrank while the button was in hand — and the control goes
      # away with it.
      def recent_block(slug, current_sid, page)
        recent = recent_entries(sessions_for(slug), current_sid)
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
      def recent_entries(entries, current_sid)
        recent = entries.reject { |entry| pinned_entry?(entry) }
        unless recent.any? { |entry| entry[:id] == current_sid }
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
          active: entry[:id] == current_sid
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

      # How long ago, in the units a reader actually uses. Absolute times would
      # have to assume a timezone; a difference between two instants does not.
      def elapsed_label(epoch)
        seconds = Time.now.to_f - epoch.to_f
        return "baru saja" if seconds < 90
        return "#{(seconds / 60).round} mnt" if seconds < 3600
        return "#{(seconds / 3600).round} jam" if seconds < 86_400
        return "#{(seconds / 86_400).round} hr" if seconds < 2_592_000

        date = Time.at(epoch).utc.strftime("%d %b").sub(/\A0/, "")
        "#{date} lalu"
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

      def dispatch(req, res)
        # WEBrick hands over the request line as ASCII-8BIT, so every capture
        # from `path` inherits that encoding. A session id built from one was
        # bound to SQLite as a BLOB, and a BLOB never equals the TEXT id of the
        # same bytes: the conversation got a second row that no lookup found.
        # Decode once, here, so every route works with plain UTF-8 text.
        path = utf8(req.path)
        method = req.request_method

        return serve_static(res, path) if path.start_with?("/assets/", "/vendor/")
        # The installed app reads these before it has a page: the manifest is a
        # description of the app and the worker is its cache, and neither holds
        # anything about a conversation. The worker has to live at the root —
        # its scope is its own path — so it is read out of the asset folder
        # rather than served from under /assets.
        return serve_manifest(res) if method == "GET" && path == "/manifest.webmanifest"
        return serve_worker(res) if method == "GET" && path == "/sw.js"

        # The way in: the gate posts here, and a match writes the same cookie a
        # rendered page does. It has to run before the check below, obviously —
        # the token is what it is asking for.
        return unlock(req, res) if method == "POST" && path == UNLOCK_PATH

        return refuse(res, req) unless authorized?(req)

        if method == "GET" && path == "/"
          redirect(res, "/p/#{default_slug}")
        elsif method == "GET" && (match = SLUG_PATH.match(path))
          open_persona(res, match[1], req)
        elsif method == "POST" && (match = PERSONA_SESSIONS_PATH.match(path))
          create_session(res, match[1], req)
        elsif method == "GET" && path == "/search"
          render_search(res, req)
        elsif method == "GET" && (match = SESSION_PATH.match(path))
          render_session(res, match[1], req)
        elsif method == "GET" && (match = SESSION_HISTORY_PATH.match(path))
          render_history(res, match[1], req)
        elsif method == "GET" && (match = SESSION_RECENT_PATH.match(path))
          render_recent(res, match[1], req)
        elsif method == "POST" && path == "/personas"
          create_persona(req, res)
        elsif method == "POST" && (match = PERSONA_EDIT_PATH.match(path))
          edit_persona(req, res, match[1])
        elsif method == "POST" && (match = SESSION_TURN_PATH.match(path))
          create_turn(req, res, match[1])
        elsif method == "GET" && (match = SESSION_MEDIA_PATH.match(path))
          serve_media(res, match[1], match[2])
        elsif method == "GET" && path == "/events"
          stream_events(res, req)
        elsif method == "GET" && (match = SESSION_QUOTA_PATH.match(path))
          render_quota(res, match[1])
        elsif method == "POST" && (match = SESSION_REPIN_PATH.match(path))
          repin_prompt(res, match[1])
        elsif method == "POST" && (match = SESSION_DELETE_PATH.match(path))
          delete_session(res, match[1], req)
        elsif method == "POST" && (match = SESSION_PIN_PATH.match(path))
          toggle_pin(res, match[1], req)
        elsif method == "GET" && path == "/push/key"
          push_public_key(res)
        elsif method == "POST" && path == "/push/subscribe"
          push_subscribe(req, res)
        elsif method == "POST" && path == "/push/unsubscribe"
          push_unsubscribe(req, res)
        elsif method == "POST" && path == "/push/test"
          push_test(req, res)
        elsif method == "GET" && (match = %r{\A/turns/([\w-]+)/stream\z}.match(path))
          stream_turn(res, match[1])
        elsif method == "POST" && (match = %r{\A/turns/([\w-]+)/(steer|stop|confirm)\z}.match(path))
          control_turn(req, res, match[1], match[2])
        else
          not_found(res)
        end
      rescue StandardError => e
        warn "[web] #{e.class}: #{e.message}"
        warn e.backtrace.first(5).join("\n") if Rubot.debug?
        res.status = 500
        res.body = "internal error"
      end

      # WEBrick delivers form/query values as ASCII-8BIT, so anything past
      # ASCII explodes later when a persona is serialised to JSON. Decode to
      # UTF-8 at the edge so the rest of the code can assume valid text.
      def form(req, key)
        raw = req.query[key]
        return "" if raw.nil?

        utf8(raw)
      end

      def utf8(raw)
        value = raw.to_s
        value = value.dup.force_encoding(Encoding::UTF_8) if value.encoding == Encoding::ASCII_8BIT
        value.valid_encoding? ? value : value.scrub
      end

      def authorized?(req)
        return true if @token.nil?

        # WEBrick parses only the body for a form POST, so `?token=` in the
        # action URL is invisible to #form. Every link the page writes carries
        # it, and the "+" button submits before any cookie exists, so read the
        # query string directly before falling back to the cookie.
        given = form(req, "token")
        given = query_token(req) if given.empty?
        given = cookie_token(req) if given.empty?
        !given.empty? && given == @token
      end

      def query_token(req)
        raw = req.query_string.to_s
        return "" if raw.empty?

        # URI, not CGI: `CGI.parse` is gone in Ruby 4 (and `CGI.escape`, which
        # the links use, is still there, so this is easy to get wrong).
        URI.decode_www_form(raw).to_h["token"].to_s
      rescue StandardError
        ""
      end

      def cookie_token(req)
        cookie = req.cookies.find { |c| c.name == "rubot_token" }
        cookie ? cookie.value : ""
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

      # --- web push ------------------------------------------------------

      # The key pair that signs a notification request. Beside config.yml,
      # because it is this install's identity to the push services and outlives
      # every conversation; never in the repository, because anyone holding it
      # could notify the devices that subscribed here.
      def vapid
        @vapid_mutex.synchronize { @vapid ||= VapidKey.new(vapid_path, subject: @vapid_subject) }
      end

      def vapid_path
        dir = @app_config ? @app_config.catalog_dir : File.expand_path("~/.rubot")
        File.join(dir, "vapid.json")
      end

      # What the page needs before it may subscribe: the public half only.
      def push_public_key(res)
        json(res, 200, { "key" => vapid.public_key, "subject" => @vapid_subject })
      rescue StandardError => e
        warn "[web] push key: #{e.class}: #{e.message}"
        json(res, 500, { "error" => "key unavailable" })
      end

      # `pushManager.subscribe` hands over three strings and no identity: the
      # endpoint is what identifies the device, so subscribing again is an
      # update of the keys, not a second device.
      #
      # The subscription belongs to the device, not to the conversation it was
      # made in — the browser keeps exactly one per registration, so a row
      # tagged with a persona would make the drawer say "aktif" in every other
      # persona while their notifications silently went nowhere. Hence a null
      # persona, which means "all of them".
      def push_subscribe(req, res)
        return cross_site(res) unless same_origin?(req)

        endpoint = form(req, "endpoint")
        p256dh = form(req, "p256dh")
        auth = form(req, "auth")
        return bad_request(res) if endpoint.empty? || p256dh.empty? || auth.empty?

        unless store = Session.store
          json(res, 503, { "error" => "archive unavailable" })
          return
        end

        store.add_push_subscription(endpoint: endpoint, p256dh: p256dh, auth: auth, persona: nil)
        json(res, 200, { "ok" => true })
      end

      def push_unsubscribe(req, res)
        return cross_site(res) unless same_origin?(req)

        endpoint = form(req, "endpoint")
        return bad_request(res) if endpoint.empty?

        Session.store&.drop_push_subscription(endpoint)
        json(res, 200, { "ok" => true })
      end

      # A notification now, to the device that asked. The drawer's button is
      # how a reader finds out whether the permission, the keys and the push
      # service all work — better than waiting for a reminder hours later.
      def push_test(req, res)
        return cross_site(res) unless same_origin?(req)

        slug = form(req, "persona")
        slug = default_slug unless !slug.empty? && known_slug?(slug)

        result = notify_push(slug,
                             title: persona_title(slug),
                             body: "Notifikasi percobaan. Kalau ini muncul, semuanya sudah tersambung.",
                             url: "/s/#{session_id(slug)}",
                             sync: true,
                             # The page that presses this button is on screen,
                             # and the worker's "the reader is already looking"
                             # rule would swallow the very notification that is
                             # meant to prove the path works.
                             force: true)
        json(res, 200, result)
      end

      # Tell a persona's devices that something arrived.
      #
      # Delivering means one HTTPS round trip per device to a push service, so
      # it never happens on the caller's thread: a turn or a cron fire must not
      # wait on Apple's or Google's edge. The exception is the test button,
      # which exists precisely to report the result. The sending itself lives in
      # `Notifier`, because the same job has to be possible from the command
      # line — this method is the channel's doorway to it.
      def notify_push(slug, title:, body:, url:, sync: false, force: false)
        notifier = push_notifier
        return { "sent" => 0, "reason" => "no archive" } unless notifier

        if sync
          notifier.deliver(slug, title: title, body: body, url: url, force: force)
        else
          notifier.notify(slug, title: title, body: body, url: url, force: force)
        end
      end

      # Built per call rather than memoised: the archive behind `Session.store`
      # is a setting tests swap between one call and the next, and a notifier
      # holding the old one would answer from a stale list of devices.
      def push_notifier
        store = Session.store
        store && PushNotifier.new(store: store, vapid: vapid, subject: @vapid_subject)
      end

      # The end of a turn nobody was waiting on.
      #
      # A prompt typed into a page is answered in that page; a prompt that left
      # the reader to do something else is answered into a conversation they
      # have to be told about. The only honest signal available is time: a turn
      # that took a while is a turn somebody probably walked away from, so the
      # threshold is the whole rule. Which devices actually ring is their own
      # decision — a page that is in front skips the notification in its worker,
      # so a desk with the app open does not announce itself.
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
                      url: "/s/#{turn.session_id}",
                      force: true)
          return
        end

        return if @turn_notify_after <= 0
        return if elapsed < @turn_notify_after

        notify_push(slug,
                    title: persona_title(slug),
                    body: turn_note(turn),
                    url: "/s/#{turn.session_id}")
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
      def same_origin?(req)
        site = req["Sec-Fetch-Site"].to_s
        return %w[same-origin none].include?(site) unless site.empty?

        origin = req["Origin"].to_s
        return true if origin.empty?

        host = req["Host"].to_s.sub(/:\d+\z/, "")
        URI.parse(origin).host.to_s == host
      rescue URI::InvalidURIError
        false
      end

      def cross_site(res)
        json(res, 403, { "error" => "cross-origin request refused" })
      end

      def deny(res)
        res.status = 403
        res["Content-Type"] = "text/plain; charset=utf-8"
        res.body = "token required"
      end

      # Only a browser asking for a page can be shown a form: htmx swaps a
      # fragment into the page it is already on, and an SSE client or curl has
      # nowhere to put a card, so those keep the plain refusal.
      def navigation?(req)
        return false unless req.request_method == "GET"
        return false if req["HX-Request"].to_s == "true"

        accept = req["Accept"].to_s
        accept.empty? || accept.include?("text/html")
      end

      def refuse(res, req)
        return deny(res) unless navigation?(req)
        return deny(res) if @token.nil?

        gate(res, req)
      end

      # The way in. The token used to ride in every URL, so arriving without
      # one — a bookmark, a URL typed from the address bar, the installed app's
      # start_url — answered "token required" and left the reader nothing to do
      # about it. The field writes the cookie the pages already read and takes
      # them on to the page they asked for, so the token stops being something
      # you have to keep in the address.
      def gate(res, req, error: nil, next_path: nil, status: 403)
        body = View.render("gate",
                           error: error,
                           next_path: next_path || gate_next(req),
                           asset_version: asset_version)
        res.status = status
        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = body
      end

      # Where the reader was trying to go. The token is dropped rather than
      # carried: the point of the form is that the next URL does not need it.
      def gate_next(req)
        path = utf8(req.path).to_s
        return "/" unless path.start_with?("/") && !path.start_with?("//")

        query = utf8(req.query_string).to_s
        return path if query.empty?

        kept = URI.decode_www_form(query).reject { |key, _value| key == "token" }
        kept.empty? ? path : "#{path}?#{URI.encode_www_form(kept)}"
      rescue StandardError
        path
      end

      def unlock(req, res)
        given = form(req, "token").strip
        nxt = safe_next(form(req, "next"))

        # No token on this install: there is nothing to check and nothing to
        # write, so the reader goes on to the page they asked for.
        return redirect_to(res, nxt) if @token.nil?

        unless given == @token
          error = given.empty? ? nil : "Token tidak cocok."
          return gate(res, req, error: error, next_path: nxt)
        end

        # The same cookie #render_session writes, so from here on the browser
        # reads the app without a token in the address bar at all.
        res["Set-Cookie"] = token_cookie
        redirect_to(res, nxt)
      end

      # A `next` is a path this app chose, so anything that is not one — an
      # absolute URL a stranger wrote into the form — goes to the doorway.
      def safe_next(raw)
        path = raw.to_s.strip
        return "/" unless path.start_with?("/") && !path.start_with?("//")
        return "/" if path.match?(/[\r\n]/)

        path
      end

      def token_cookie
        "rubot_token=#{@token}; Path=/; HttpOnly; SameSite=Lax"
      end

      # A plain 303, without the token every other redirect appends: the cookie
      # has just been set, and putting it back in the URL would undo the reason
      # the form exists.
      def redirect_to(res, location)
        res.status = 303
        res["Location"] = location
        res.body = ""
      end

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

      def token_query
        @token ? "?token=#{CGI.escape(@token)}" : ""
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
          broadcast_sessions(slug)
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
        res.body = View.render("_history", **page,
                                            older_url: older_url(sid, page[:before]))
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

        live = live_turn(sid)
        persona = persona_store&.[](slug)
        persona_label = persona ? persona.label : slug.capitalize
        session_label = named_session_label(slug, sid)
        page = history_page(sid, at: at_index(req))
        body = View.render(
          "index",
          personas: persona_rows(slug),
          groups: session_groups(slug, sid, page: session_page(req)),
          slug: slug,
          session_id: sid,
          session_short: sid.delete_prefix("web_"),
          persona_label: persona_label,
          persona_emoji: persona ? persona.emoji_or : "🤖",
          persona_prompt: persona ? persona.system_prompt.to_s : "",
          persona_model: persona_model(persona),
          session_label: session_label,
          document_title: document_title(persona_label, session_label),
          page: page,
          older_url: older_url(sid, page[:before]),
          live_turn: live,
          usage: usage_locals(sid),
          usage_facts: index_usage_facts(sid),
          token_query: token_query
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

      # What the status line shows: the model this persona actually talks to.
      def persona_model(persona)
        return @app_config&.model.to_s if persona.nil?

        persona.model || persona.preset || @app_config&.model || "default"
      end

      def persona_rows(current_slug)
        personas.map do |key, persona|
          {
            slug: key,
            label: persona.label,
            emoji: persona.emoji_or,
            active: key == current_slug,
            model: persona.model || persona.preset || "default"
          }
        end
      end

      # The conversation as the thread draws it: a prompt, then the turn it
      # produced — including the tool rows. Without replaying the calls a
      # refresh would quietly hide the work the answer was built from.
      def history(sid)
        return [] unless @app_config

        # The transcript's position in the file is not the same number as its
        # position in the archive: a trimmed session starts at `start`, so the
        # absolute index of a message is `start + position`. Search hits are
        # addressed by that index, and it is attached here — on the entry that
        # will be drawn — because it is the only thing that can send a reader
        # back to the message a hit came from.
        messages, start = Session.transcript_with_start(
          @app_config.workspace,
          sid,
          dir: @app_config.sessions_dir
        )
        results = tool_results(messages)
        diffs = tool_diffs(messages)

        turns = []
        current = nil

        messages.each_with_index do |msg, position|
          idx = start + position

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
            Array(msg["tool_calls"]).each { |call| items.concat(history_tool_items(call, results, diffs, sid)) }
            next if items.empty?

            # Rounds of one prompt belong to one turn: the model answering,
            # calling out, and answering again is a single exchange.
            if current
              current[:items].concat(items)
              current[:last] = idx
            else
              current = { kind: :turn, items: items, idx: idx, last: idx }
              turns << current
            end
          when "tool"
            # A hit inside a tool result lands on the turn that called it, so
            # the entry's own range has to reach past its last assistant round.
            current[:last] = idx if current
          end
        end

        turns
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

      # The row for a call, plus the files below it when send_file handed one
      # back. Two items rather than one, because a picture is drawn as a
      # picture, a document as a card, and the row as a row. An edit adds a
      # third, the hunks of the file it changed, right under the row that
      # changed it.
      def history_tool_items(call, results, diffs, sid)
        function = call["function"] || {}
        name = function["name"].to_s
        result = results[call["id"].to_s]

        items = [ {
          kind: :tool,
          name: name,
          detail: summarize_arguments(parse_arguments(function["arguments"])),
          state: result.nil? ? :unknown : (tool_ok?(result) ? :ok : :failed),
          elapsed: nil
        } ]

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
          cost: cost ? format("$%s", Rubot::UsageReport.money(cost["total"])) : "belum diketahui",
          breakdown: cost_breakdown(cost),
          requests: report[:requests].to_i.to_s,
          messages: report[:messages].to_i.to_s,
          tokens_in: Rubot::UsageReport.tokens(report[:prompt_tokens]),
          tokens_out: Rubot::UsageReport.tokens(report[:completion_tokens]),
          reasoning: report[:reasoning_tokens].to_i.zero? ? "" : Rubot::UsageReport.tokens(report[:reasoning_tokens]),
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
        return [] unless report.is_a?(Hash)

        Rubot::OpencodeUsage::METERS.filter_map do |name|
          meter = report[name]
          next unless meter.is_a?(Hash)

          used = meter["percent"].to_f.clamp(0.0, 100.0)
          {
            name: name.capitalize,
            used: format("%.1f", used),
            used_label: "#{format('%.1f', used)}% terpakai",
            reset: quota_reset(meter),
            limited: meter["limited"] ? true : false
          }
        end
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
          emoji: form(req, "emoji").strip.empty? ? EMOJI_CHOICES.first : form(req, "emoji").strip,
          system_prompt: prompt.empty? ? nil : prompt
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

        store.set(slug, Persona.new(
          slug: slug,
          name: name.empty? ? nil : name,
          emoji: emoji.empty? ? current.emoji : emoji,
          accent: current.accent,
          preset: current.preset,
          model: current.model,
          system_prompt: prompt.empty? ? nil : prompt,
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

      # --- pictures -------------------------------------------------------

      # Where this conversation's pictures live: the folder that send_file
      # copies into, inside the persona's own workspace. It is the same
      # per-session folder the Telegram channel writes to, so a tool call that
      # worked in one channel has somewhere to land in the other.
      def attachments_dir(sid)
        store = persona_store
        slug = owner_slug(sid)
        return nil unless store && slug

        workspace = store.workspace_for(slug)
        workspace && File.join(workspace, "attachments", sid)
      end

      # Where a picture is drawn from. The token rides in it like every other
      # URL the page writes: an <img> cannot send a cookie it was not given.
      def media_url(sid, name)
        "/s/#{sid}/media/#{name}#{token_query}"
      end

      # The files a call handed back, read out of the result the call left in
      # the transcript. The markers are the only record of which stored files it
      # produced — that is how a conversation drawn from disk a week later can
      # still show them. One result can name several: `send_files` sends a batch
      # in a single call and writes a marker per file.
      #
      # A picture is drawn as a picture and anything else as a document card,
      # and the type the route serves it under is what decides which: the two
      # questions have one answer.
      def sent_attachments(name, result, sid)
        return [] unless %w[send_file send_files].include?(name.to_s)

        result.to_s.scan(Rubot::Tools::SendFile::WEB_MARKER_RE).flatten.filter_map do |stored|
          next unless MEDIA_NAME.match?(stored)

          extension = File.extname(stored)
          url = media_url(sid, stored)

          # The stored file's own id is its stable identity on the page: the
          # timeline is redrawn on every token, and a file that kept its node
          # is not fetched or decoded again while the answer grows under it.
          { url: url, name: download_name(stored), id: stored[0, 32],
            kind: picture?(stored) ? :picture : :document,
            label: extension.delete_prefix(".").upcase }
        end.uniq { |attachment| attachment[:id] }
      end

      def picture?(name)
        MEDIA_TYPES.fetch(File.extname(name), "").start_with?("image/")
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

      def bind_file_delivery(sid)
        dir = attachments_dir(sid)
        return unless dir

        %w[send_file send_files].each do |name|
          tool = session_for(sid).tools.get(name)
          tool.delivery_context = { channel: "web", dir: dir } if tool
        end
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
      def download_name(name)
        extension = File.extname(name)
        base = File.basename(name, extension).sub(/\A[0-9a-f]{32}-?/, "")
        return "#{base}#{extension}" unless base.empty?

        "#{picture?(name) ? "gambar" : "berkas"}#{extension}"
      end

      def serve_media(res, sid, name)
        return not_found(res) unless owner_slug(sid) && MEDIA_NAME.match?(name)

        dir = attachments_dir(sid)
        path = dir && File.join(dir, name)
        return not_found(res) unless path && File.file?(path)

        res["Content-Type"] = MEDIA_TYPES.fetch(File.extname(name), "application/octet-stream")
        res["Content-Length"] = File.size(path).to_s
        res["Cache-Control"] = "private, max-age=3600"
        # The name the reader can download as is set by the `download`
        # attribute on the anchor; inline keeps a click from navigating away
        # from the conversation on browsers that ignore it.
        res["Content-Disposition"] = %(inline; filename="#{download_name(name)}")
        res.body = File.binread(path)
      end

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

      def create_turn(req, res, sid)
        return not_found(res) unless owner_slug(sid)

        text = form(req, "message").strip
        if text.empty?
          res.status = 400
          res.body = %(<div class="notice"><div class="error">Pesan kosong.</div></div>)
          return
        end

        turn = Turn.new(id: "t#{SecureRandom.hex(6)}", session_id: sid, prompt: text)

        @turns_mutex.synchronize do
          # A second POST while one turn is running must not queue behind it:
          # the browser is expected to steer or stop instead.
          if @active[sid]
            res.status = 409
            res.body = %(<div class="notice"><div class="error">Masih ada giliran yang berjalan. Tunggu sebentar atau tekan Stop.</div></div>)
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
      # prompt, and everything it hands back lands in the timeline. `send_file`
      # is aimed at this conversation first — a picture the agent sends is the
      # whole point of this channel's attachment folder.
      def run_turn(turn, text)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # The agent asking to be announced at the end: nil until it does, then
        # the line it wants said. A request outranks the clock below — the
        # reader asked, so the wait is not what decides.
        announcement = nil
        Thread.current[:rubot_web_turn] = turn
        prepare_delivery(turn.session_id)

        response = process_message(
          text,
          session_id: turn.session_id,
          on_tool_call: lambda do |name, args, _snapshot|
            announcement = args.to_h["message"].to_s.strip if name.to_s == "notify"
            announcement ||= ""
            turn.tool_started(name, summarize_arguments(args))
          end,
          on_tool_result: ->(name, result, diff) { tool_finished(turn, name, result, diff) },
          on_reasoning: ->(delta) { turn.thinking(delta) },
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
        head = View.render("_chathead",
                           persona_emoji: persona ? persona.emoji_or : "🤖",
                           persona_label: persona_label,
                           session_label: label,
                           document_title: document_title(persona_label, label))
                   .sub(%(<header class="chat-head" id="chat-head"),
                        %(<header class="chat-head" id="chat-head" hx-swap-oob="true"))

        nav + head
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
          sse(out, "sidebar", sidebar_markup(sid))

          loop do
            break unless @running

            markup = queue.pop(timeout: EVENT_HEARTBEAT)
            if markup.nil?
              # A comment line costs nothing and keeps the connection from
              # being closed for silence by whatever sits in between.
              out.write(": keepalive\n\n")
              out.flush if out.respond_to?(:flush)
            else
              sse(out, "sidebar", markup)
            end
          end
        rescue IOError, Errno::EPIPE, Errno::ECONNRESET
          nil
        ensure
          stop_listening_for_events(queue)
        end
      end

      # Tell every open page of this persona that its sidebar has changed. Each
      # page is answered in its own session id, because that is what decides
      # which row is the active one.
      def broadcast_sessions(slug)
        subs = @event_mutex.synchronize { @event_subs.dup }
        subs.each do |sid, queue|
          next unless (owner_slug(sid) || default_slug) == slug

          markup = sidebar_markup(sid)
          queue << markup unless markup.to_s.empty?
        end
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
        when :sidebar
          # Same trick for the sidebar and the header: what the conversation is
          # called is only known after the first turn has been saved.
          sse(out, "sidebar", payload.to_s)
        when :heartbeat
          out.write(": keepalive\n\n")
          out.flush if out.respond_to?(:flush)
        when :done
          sse(out, "turn", render_timeline(turn))
          sse(out, "done", " ")
        end
      end

      def render_timeline(turn)
        View.turn_body(turn)
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
            url: "/s/#{session_id(slug)}"
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
        session.process_cron(
          result[:result][:agent_message],
          fresh: result[:new_session] ? true : false
        )

        # A conversation the job opened has no user message to be named after,
        # so it takes the job's own description and the day it ran.
        if result[:new_session] && session.respond_to?(:set_session_title)
          session.set_session_title(cron_session_title(result))
        end

        # Whoever has this persona open hears about it now, rather than on the
        # next reload.
        broadcast_sessions(slug)

        # And whoever does not: a reminder is the whole point of firing while
        # the app is closed. Pages that are open are skipped by the worker
        # itself, so this cannot ring twice for the same news.
        notify_push(
          slug,
          title: persona_title(slug),
          body: cron_note(result),
          url: "/s/#{sid}"
        )
      end

      # What a notification says about a fired job. The description is the
      # reader's own words for it ("minum air", "cek inbox"), which is more
      # useful than a timestamp — and it is sealed to the device, so a push
      # service never reads it.
      def cron_note(result)
        label = result[:description].to_s.gsub(/\s+/, " ").strip
        label.empty? ? "Sesi terjadwal sudah siap." : label
      end

      def cron_session_title(result)
        label = result[:description].to_s.strip
        label = "Scheduled session" if label.empty?
        "#{label} — #{Time.now.strftime('%Y-%m-%d')}"
      end
    end
  end
end
