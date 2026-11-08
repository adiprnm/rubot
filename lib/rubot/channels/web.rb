# frozen_string_literal: true

require "webrick"
require "securerandom"

require_relative "../channel"
require_relative "../persona_store"
require_relative "../session"
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
    # Each persona is its own agent: session `web_<slug>`, rooted at the
    # persona's workspace by SessionPool, so SOUL.md, skills and memory are not
    # shared between specialists.
    class Web < Channel
      DEFAULT_HOST = "127.0.0.1"
      DEFAULT_PORT = 4567
      MAX_TURNS = 30
      DEFAULT_SLUG = "rubot"

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

      # Session ids are per persona: "web_<slug>".
      def session_id(slug = default_slug)
        "web_#{slug}"
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
        elsif method == "GET" && (match = %r{\A/p/([a-z0-9][a-z0-9_-]{0,31})\z}.match(path))
          render_index(res, match[1])
        elsif method == "POST" && path == "/personas"
          create_persona(req, res)
        elsif method == "POST" && (match = %r{\A/p/([a-z0-9][a-z0-9_-]{0,31})/turn\z}.match(path))
          create_turn(req, res, match[1])
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

        value = raw.to_s
        value = value.dup.force_encoding(Encoding::UTF_8) if value.encoding == Encoding::ASCII_8BIT
        value.valid_encoding? ? value : value.scrub
      end

      def authorized?(req)
        return true if @token.nil?

        given = form(req, "token")
        given = cookie_token(req) if given.empty?
        !given.empty? && given == @token
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

      def render_index(res, slug)
        return not_found(res) unless known_slug?(slug)

        persona = persona_store&.[](slug)
        body = View.render(
          "index",
          personas: persona_rows(slug),
          slug: slug,
          persona_label: persona ? persona.label : slug.capitalize,
          persona_emoji: persona ? persona.emoji_or : "🤖",
          persona_model: persona_model(persona),
          session_id: session_id(slug),
          messages: history(slug),
          usage: usage_locals(slug),
          token_query: token_query
        )
        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        res.body = View.render("layout", content: body, title: persona ? persona.label : slug,
                                         asset_version: asset_version)

        return unless @token

        # WEBrick::Cookie has no httponly accessor in 1.9.x, so the header is
        # written by hand to keep the token out of reach of page scripts.
        res["Set-Cookie"] = "rubot_token=#{@token}; Path=/; HttpOnly; SameSite=Lax"
      end

      # Static assets are cached for an hour, so the URL carries the file's
      # mtime. Editing the stylesheet then reaches the browser immediately.
      def asset_version
        File.mtime(File.join(ASSETS, "app.css")).to_i
      rescue SystemCallError
        0
      end

      # The emoji the person picked for this persona, or a neutral default.
      def persona_emoji(slug)
        persona = persona_store&.[](slug)
        persona ? persona.emoji_or : "🤖"
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
      def history(slug)
        return [] unless @app_config

        messages = Session.transcript(
          @app_config.workspace,
          session_id(slug),
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
            Array(msg["tool_calls"]).each { |call| items << history_tool_item(call, results) }
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

      def history_tool_item(call, results)
        function = call["function"] || {}
        result = results[call["id"].to_s]

        {
          kind: :tool,
          name: function["name"].to_s,
          detail: summarize_arguments(parse_arguments(function["arguments"])),
          state: result.nil? ? :unknown : (tool_ok?(result) ? :ok : :failed),
          elapsed: nil
        }
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
      def usage_locals(slug)
        metrics = usage_metrics(slug)
        {
          cost: metrics&.dig(:cost) || "—",
          cache: metrics&.dig(:cache) || "—",
          ctx: metrics&.dig(:context) || "—"
        }
      end

      # Asking a session that is mid-turn is safe: the actor runs the turn on
      # its own thread, so the report is answered rather than queued behind it.
      def usage_metrics(slug)
        Rubot::UsageReport.metrics(session_for(session_id(slug)).usage_report)
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

      # --- turn lifecycle ------------------------------------------------

      def create_turn(req, res, slug)
        return not_found(res) unless known_slug?(slug)

        text = form(req, "message").strip
        if text.empty?
          res.status = 400
          res.body = %(<div class="notice"><div class="error">Pesan kosong.</div></div>)
          return
        end

        sid = session_id(slug)
        turn = Turn.new(id: "t#{SecureRandom.hex(6)}", session_id: sid)

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

        Thread.new { run_turn(turn, text, slug) }

        res["Content-Type"] = "text/html; charset=utf-8"
        res.body = View.render("_turn", turn: turn, text: text, token_query: token_query)
      end

      def run_turn(turn, text, slug)
        Thread.current[:rubot_web_turn] = turn

        response = process_message(
          text,
          session_id: turn.session_id,
          on_tool_call: ->(name, args, _snapshot) { turn.tool_started(name, summarize_arguments(args)) },
          on_tool_result: ->(name, result, _diff) { turn.tool_finished(name, tool_ok?(result)) },
          on_reasoning: ->(delta) { turn.thinking(delta) },
          on_confirm: ->(name, _args, reason) { turn.ask_confirm(name, reason) }
        )

        # The footer figures move with every request, so the row is re-rendered
        # once the turn has nothing left to spend — before :done, which ends
        # the stream.
        turn.emit(:usage, usage_markup(slug))
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
      def usage_markup(slug)
        usage_markup_with(usage_locals(slug))
      end

      # Split out so the marker can be tested without a live session behind it.
      def usage_markup_with(locals)
        body = View.render("_usage", **locals)
        body.sub(%(<span class="metrics" id="usage">),
                 %(<span class="metrics" id="usage" hx-swap-oob="true">))
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
          turn.each_event do |type, payload|
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
        when :heartbeat
          out.write(": keepalive\n\n")
          out.flush if out.respond_to?(:flush)
        when :done
          sse(out, "turn", render_timeline(turn))
          sse(out, "done", " ")
        end
      end

      def render_timeline(turn)
        View.render("_timeline", items: turn.items)
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

          res.status = steer_session(turn.session_id, text) ? 204 : 409
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
