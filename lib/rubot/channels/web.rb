# frozen_string_literal: true

require "webrick"
require "securerandom"
require "uri"
require "fileutils"
require "json"

require_relative "../channel"
require_relative "../persona_store"
require_relative "../session"
require_relative "../tools/send_file"
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
      # How many conversations the sidebar lists. Older ones stay on disk and
      # are still reachable by their URL.
      MAX_SESSION_ROWS = 40
      # How much of a conversation the page draws at once. A long session is a
      # lot of DOM to build for a reader who only ever looks at the end of it,
      # so the page starts at the tail and earlier turns arrive as the reader
      # scrolls up.
      HISTORY_PAGE = 20
      # What a conversation is called before its first prompt has been saved.
      UNTITLED_SESSION = "Sesi baru"

      # What the page hands back: the pictures the agent sends through
      # send_file. The name the server writes is a hex id this channel
      # generated, an optional slug of the file's own name, and a known
      # extension — the slug is what makes a download read like a file, the id
      # is what makes it impossible to guess.
      MEDIA_TYPES = {
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp"
      }.freeze
      MEDIA_NAME = /\A[0-9a-f]{32}(?:-[a-z0-9-]{1,60})?\.(?:png|jpg|gif|webp)\z/

      SLUG_PATH = %r{\A/p/([a-z0-9][a-z0-9_-]{0,31})\z}
      SESSION_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})\z}
      SESSION_HISTORY_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/history\z}
      SESSION_TURN_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/turn\z}
      SESSION_MEDIA_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/media/([0-9a-f]{32}(?:-[a-z0-9-]{1,60})?\.(?:png|jpg|gif|webp))\z}
      SESSION_DELETE_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/delete\z}
      PERSONA_SESSIONS_PATH = %r{\A/p/([a-z0-9][a-z0-9_-]{0,31})/sessions\z}

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
        @personas = nil
        super
      end

      def start
        @running = true
        start_cron_listener { |result| log_cron(result) } if actor_mode?
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
        dir = @app_config&.sessions_dir
        return [] unless dir && Dir.exist?(dir)

        base = session_id(slug)
        prefix = "#{base}#{SESSION_SEPARATOR}"
        Dir.glob(File.join(dir, "#{base}*.json"))
          .filter_map { |path| Session.describe(path) }
          .select { |entry| entry[:id] == base || entry[:id].to_s.start_with?(prefix) }
          .sort_by { |entry| entry[:timestamp] }
          .reverse
      end

      # Rows for the sidebar: what the conversation is about and how long ago it
      # moved. The one on screen is always present, even before it is saved.
      def session_rows(slug, current_sid)
        rows = sessions_for(slug).first(MAX_SESSION_ROWS).map do |entry|
          {
            id: entry[:id],
            label: entry[:title].to_s.strip.empty? ? UNTITLED_SESSION : entry[:title].to_s,
            meta: elapsed_label(entry[:timestamp]),
            active: entry[:id] == current_sid
          }
        end

        return rows if rows.any? { |row| row[:active] }

        [ { id: current_sid, label: UNTITLED_SESSION, meta: "", active: true }, *rows ]
      end

      # The name of the conversation on screen: the prompt that opened it. It is
      # the one thing that tells two sessions of the same persona apart, so it
      # is used as the name everywhere — sidebar, header, tab — instead of
      # showing it in one place and an id everywhere else.
      def session_label(slug, sid)
        row = session_rows(slug, sid).find { |entry| entry[:active] }
        row ? row[:label] : UNTITLED_SESSION
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
        path = req.path
        method = req.request_method

        return serve_static(res, path) if path.start_with?("/assets/", "/vendor/")
        return deny(res) unless authorized?(req)

        if method == "GET" && path == "/"
          redirect(res, "/p/#{default_slug}")
        elsif method == "GET" && (match = SLUG_PATH.match(path))
          open_persona(res, match[1], req)
        elsif method == "POST" && (match = PERSONA_SESSIONS_PATH.match(path))
          create_session(res, match[1], req)
        elsif method == "GET" && (match = SESSION_PATH.match(path))
          render_session(res, match[1])
        elsif method == "GET" && (match = SESSION_HISTORY_PATH.match(path))
          render_history(res, match[1], req)
        elsif method == "POST" && path == "/personas"
          create_persona(req, res)
        elsif method == "POST" && (match = SESSION_TURN_PATH.match(path))
          create_turn(req, res, match[1])
        elsif method == "GET" && (match = SESSION_MEDIA_PATH.match(path))
          serve_media(res, match[1], match[2])
        elsif method == "POST" && (match = SESSION_DELETE_PATH.match(path))
          delete_session(res, match[1], req)
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

      def deny(res)
        res.status = 403
        res["Content-Type"] = "text/plain; charset=utf-8"
        res.body = "token required"
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

        # Land on what is left: the persona's next newest conversation, or the
        # persona itself when this was the last one. Either way the browser is
        # sent somewhere that still exists.
        remaining = sessions_for(slug).first
        redirect(res, remaining ? "/s/#{remaining[:id]}" : "/p/#{slug}", req)
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
      def history_page(sid, before: nil)
        entries = history(sid)
        stop = before ? before.clamp(0, entries.size) : entries.size
        start = [ stop - HISTORY_PAGE, 0 ].max

        { entries: entries[start...stop], more: start.positive?, before: start }
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

      def render_session(res, sid)
        slug = owner_slug(sid)
        return not_found(res) unless slug

        live = live_turn(sid)
        persona = persona_store&.[](slug)
        persona_label = persona ? persona.label : slug.capitalize
        session_label = named_session_label(slug, sid)
        page = history_page(sid)
        body = View.render(
          "index",
          personas: persona_rows(slug),
          sessions: session_rows(slug, sid),
          slug: slug,
          session_id: sid,
          session_short: sid.delete_prefix("web_"),
          persona_label: persona_label,
          persona_emoji: persona ? persona.emoji_or : "🤖",
          persona_model: persona_model(persona),
          session_label: session_label,
          document_title: document_title(persona_label, session_label),
          page: page,
          older_url: older_url(sid, page[:before]),
          live_turn: live,
          usage: usage_locals(sid),
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
        res["Set-Cookie"] = "rubot_token=#{@token}; Path=/; HttpOnly; SameSite=Lax"
      end

      # Static assets are cached for an hour, so the URL carries the mtime of
      # the newest of them. One stamp for both files: a JS-only change has to
      # reach the browser just as a CSS change does, and the stylesheet alone
      # as its version was a promise the stylesheet could not keep.
      def asset_version
        %w[app.css app.js].map { |name| File.mtime(File.join(ASSETS, name)).to_i }.max
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

        messages = Session.transcript(
          @app_config.workspace,
          sid,
          dir: @app_config.sessions_dir
        )
        results = tool_results(messages)

        turns = []
        current = nil

        messages.each do |msg|
          case msg["role"]
          when "user"
            text = Session.text_content(msg["content"]).to_s.strip
            next if text.empty?

            turns << { kind: :prompt, text: text }
            current = nil
          when "assistant"
            items = []
            text = Session.text_content(msg["content"]).to_s.strip
            items << { kind: :text, text: text, live: false } unless text.empty?
            Array(msg["tool_calls"]).each { |call| items.concat(history_tool_items(call, results, sid)) }
            next if items.empty?

            # Rounds of one prompt belong to one turn: the model answering,
            # calling out, and answering again is a single exchange.
            if current
              current[:items].concat(items)
            else
              current = { kind: :turn, items: items }
              turns << current
            end
          end
        end

        turns
      end

      # Tool output is stored after the call that asked for it, so the id is
      # what pairs a row with how it ended.
      def tool_results(messages)
        messages.each_with_object({}) do |msg, acc|
          next unless msg["role"] == "tool"

          acc[msg["tool_call_id"].to_s] = msg["content"].to_s
        end
      end

      # The row for a call, plus the picture below it when send_file handed one
      # back. Two items rather than one, because the picture is drawn as a
      # picture and the row as a row.
      def history_tool_items(call, results, sid)
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

        pictures = sent_pictures(name, result, sid)
        items << { kind: :images, list: pictures } unless pictures.empty?
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
        metrics = usage_metrics(sid)
        {
          cost: metrics&.dig(:cost) || "—",
          cache: metrics&.dig(:cache) || "—",
          ctx: metrics&.dig(:context) || "—"
        }
      end

      # Asking a session that is mid-turn is safe: the actor runs the turn on
      # its own thread, so the report is answered rather than queued behind it.
      def usage_metrics(sid)
        Rubot::UsageReport.metrics(session_for(sid).usage_report)
      rescue StandardError
        nil
      end

      # --- personas (create) ---------------------------------------------

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

      # The pictures a call handed back, read out of the result the call left in
      # the transcript. The markers are the only record of which stored files it
      # produced — that is how a conversation drawn from disk a week later can
      # still show them. One result can name several: `send_files` sends a batch
      # in a single call and writes a marker per picture.
      def sent_pictures(name, result, sid)
        return [] unless %w[send_file send_files].include?(name.to_s)

        result.to_s.scan(Rubot::Tools::SendFile::WEB_MARKER_RE).flatten.filter_map do |stored|
          next unless MEDIA_NAME.match?(stored)

          # The stored file's own id is the picture's stable identity on the
          # page: the timeline is redrawn on every token, and a picture that
          # kept its node is not fetched or decoded again while the answer grows
          # under it.
          { url: media_url(sid, stored), name: download_name(stored), id: stored[/\A[0-9a-f]{32}/] }
        end.uniq { |picture| picture[:id] }
      end

      # Point the agent's file tools at this conversation, so a picture they
      # hand back lands where the page can serve it. Telegram sets the same
      # field with a chat id; here it is a folder. Plain strings only, because
      # the value crosses into the session's Ractor.
      def prepare_delivery(sid)
        dir = attachments_dir(sid)
        return unless dir

        %w[send_file send_files].each do |name|
          tool = session_for(sid).tools.get(name)
          tool.delivery_context = { channel: "web", dir: dir } if tool
        end
      end

      # What a picture is called when it is downloaded: the stored name minus
      # the id in front of it.
      def download_name(name)
        extension = File.extname(name)
        base = File.basename(name, extension).sub(/\A[0-9a-f]{32}-?/, "")
        base.empty? ? "gambar#{extension}" : "#{base}#{extension}"
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
        res.body = View.render("_turn", turn: turn, text: text, token_query: token_query)
      end

      # The turn the browser is following, in one place: the agent reads the
      # prompt, and everything it hands back lands in the timeline. `send_file`
      # is aimed at this conversation first — a picture the agent sends is the
      # whole point of this channel's attachment folder.
      def run_turn(turn, text)
        Thread.current[:rubot_web_turn] = turn
        prepare_delivery(turn.session_id)

        response = process_message(
          text,
          session_id: turn.session_id,
          on_tool_call: ->(name, args, _snapshot) { turn.tool_started(name, summarize_arguments(args)) },
          on_tool_result: ->(name, result, _diff) { tool_finished(turn, name, result) },
          on_reasoning: ->(delta) { turn.thinking(delta) },
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
      rescue StandardError => e
        turn.fail_with(handle_error(e, text))
      ensure
        Thread.current[:rubot_web_turn] = nil
        @turns_mutex.synchronize do
          @active.delete(turn.session_id) if @active[turn.session_id] == turn.id
        end
      end

      # A fragment meant for the status row rather than for the turn: the swap
      # is out-of-band, so it lands on #usage wherever that element sits.
      def usage_markup(sid)
        usage_markup_with(usage_locals(sid))
      end

      # Split out so the marker can be tested without a live session behind it.
      def usage_markup_with(locals)
        body = View.render("_usage", **locals)
        body.sub(%(<span class="metrics" id="usage">),
                 %(<span class="metrics" id="usage" hx-swap-oob="true">))
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

        nav = View.render("_sessions", sessions: session_rows(slug, sid), token_query: token_query)
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

      # A tool row, and — when the tool handed pictures back — the pictures
      # themselves, drawn under the row that produced them. `send_files` names
      # several in one result; they land in the same strip, in the order sent.
      def tool_finished(turn, name, result)
        turn.tool_finished(name, tool_ok?(result))
        sent_pictures(name, result, turn.session_id).each { |picture| turn.add_image(**picture) }
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
        when :working
          # The band above the composer, sent again every time the turn reaches
          # for a tool: the payload carries its own out-of-band marker, so the
          # swap lands there and the timeline is untouched.
          sse(out, "working", View.render("_working", since: turn.epoch))
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

      def log_cron(result)
        warn "[web] cron fired (#{result[:mode]}) but the browser channel has no target yet"
      end
    end
  end
end
