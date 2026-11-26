# frozen_string_literal: true

module Rubot
  module Web
    # Which request goes where, as data.
    #
    # The order is the behaviour: a public path is answered before the token
    # check, and the check runs before any conversation is touched. Keeping the
    # routes in one list is what turns "what can a reader without a token
    # reach?" into a question this file answers by being read.
    module Router
      # What the page hands back: the pictures the agent sends through
      # send_files, and the two documents a browser already opens on its own —
      # a PDF and a markdown note. The name the server writes is a hex id this
      # channel generated, an optional slug of the file's own name, and a known
      # extension — the slug is what makes a download read like a file, the id
      # is what makes it impossible to guess.
      MEDIA_EXTENSIONS = %w[png jpg gif webp mp4 webm pdf md].freeze
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
      SESSION_RENAME_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/rename\z}
      SESSION_QUOTA_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/quota\z}
      # The footer's loop panel asking for its rows again. Read while a reader
      # has the panel open and nothing else: a loop's progress is a file on
      # disk, so the page has to ask rather than be told.
      SESSION_LOOPS_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/loops\z}
      SESSION_REPIN_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/repin\z}
      SESSION_COMPACT_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/compact\z}
      SESSION_SETTINGS_PATH = %r{\A/s/([a-z0-9][a-z0-9_~-]{0,90})/settings\z}
      PERSONA_SESSIONS_PATH = %r{\A/p/([a-z0-9][a-z0-9_-]{0,31})/sessions\z}
      PERSONA_EDIT_PATH = %r{\A/p/([a-z0-9][a-z0-9_-]{0,31})/edit\z}

      # Where the token form posts. Not under /s/ or /p/ because it belongs to
      # the way in rather than to any conversation behind it.
      UNLOCK_PATH = "/unlock"
      # Instagram's OAuth endpoints. The callback is where Meta sends the
      # browser back; it is not behind a session id because the account belongs
      # to the install, not to a conversation.
      IG_CONNECT_PATH = "/instagram/connect"
      IG_CALLBACK_PATH = "/instagram/callback"
      IG_DISCONNECT_PATH = "/instagram/disconnect"
      IG_LINK_PATH = "/instagram/link"

      # The spellings the settings page has posted to over time. One handler,
      # because they are one action: refreshing the model list.
      REFRESH_PATHS = %w[/settings/refresh-models /settings/refresh_models /settings/refresh].freeze

      private

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

        # The two ways in that cannot carry the token. The gate posts here, and
        # Meta sends the browser back with a one-time `state` instead. Both run
        # before the check below, obviously: one is asking for the token, the
        # other has no way to hold it.
        return unlock(req, res) if method == "POST" && path == UNLOCK_PATH
        return instagram_callback(req, res) if method == "GET" && path == IG_CALLBACK_PATH

        return refuse(res, req) unless authorized?(req)

        routes.each do |verb, matcher, handler|
          next unless verb == method

          captures = match_route(matcher, path)
          next if captures.nil?

          return handler.call(captures, req, res)
        end

        not_found(res)
      rescue StandardError => e
        warn "[web] #{e.class}: #{e.message}"
        warn e.backtrace.first(5).join("\n") if Rubot.debug?
        res.status = 500
        res.body = "internal error"
      end

      # Every route behind the token, in the order they are tried. An entry is
      # [method, matcher, handler]: a matcher is a path, a list of paths, or a
      # regexp whose captures are handed to the handler. The handlers are
      # lambdas closed over the channel, so a route reads as the call it makes
      # instead of a name resolved somewhere else.
      def routes
        @routes ||= [
          [ "GET", IG_CONNECT_PATH, ->(_c, req, res) { instagram_connect(req, res) } ],
          [ "POST", IG_DISCONNECT_PATH, ->(_c, req, res) { instagram_disconnect(req, res) } ],
          [ "POST", IG_LINK_PATH, ->(_c, req, res) { instagram_link(req, res) } ],
          [ "GET", "/", ->(_c, _req, res) { redirect(res, "/p/#{default_slug}") } ],
          [ "GET", SLUG_PATH, ->(c, req, res) { open_persona(res, c[0], req) } ],
          [ "POST", PERSONA_SESSIONS_PATH, ->(c, req, res) { create_session(res, c[0], req) } ],
          [ "GET", "/search", ->(_c, req, res) { render_search(res, req) } ],
          [ "GET", "/settings", ->(_c, req, res) { render_settings(res, req) } ],
          [ "POST", "/settings", ->(_c, req, res) { save_settings(res, req) } ],
          [ "GET", REFRESH_PATHS, ->(_c, req, res) { refresh_models(res, req) } ],
          [ "POST", REFRESH_PATHS, ->(_c, req, res) { refresh_models(res, req) } ],
          [ "GET", SESSION_PATH, ->(c, req, res) { render_session(res, c[0], req) } ],
          [ "GET", SESSION_HISTORY_PATH, ->(c, req, res) { render_history(res, c[0], req) } ],
          [ "GET", SESSION_RECENT_PATH, ->(c, req, res) { render_recent(res, c[0], req) } ],
          [ "POST", "/personas", ->(_c, req, res) { create_persona(req, res) } ],
          [ "POST", PERSONA_EDIT_PATH, ->(c, req, res) { edit_persona(req, res, c[0]) } ],
          [ "POST", SESSION_TURN_PATH, ->(c, req, res) { create_turn(req, res, c[0]) } ],
          [ "GET", SESSION_MEDIA_PATH, ->(c, _req, res) { serve_media(res, c[0], c[1]) } ],
          [ "GET", "/events", ->(_c, req, res) { stream_events(res, req) } ],
          [ "GET", SESSION_QUOTA_PATH, ->(c, _req, res) { render_quota(res, c[0]) } ],
          [ "GET", SESSION_LOOPS_PATH, ->(c, _req, res) { render_loops(res, c[0]) } ],
          [ "POST", SESSION_REPIN_PATH, ->(c, _req, res) { repin_prompt(res, c[0]) } ],
          [ "POST", SESSION_COMPACT_PATH, ->(c, req, res) { compact_session_now(res, c[0], req) } ],
          [ "POST", SESSION_DELETE_PATH, ->(c, req, res) { delete_session(res, c[0], req) } ],
          [ "POST", SESSION_PIN_PATH, ->(c, req, res) { toggle_pin(res, c[0], req) } ],
          [ "POST", SESSION_RENAME_PATH, ->(c, req, res) { rename_session(res, c[0], req) } ],
          [ "POST", SESSION_SETTINGS_PATH, ->(c, req, res) { update_session_settings(res, c[0], req) } ],
          [ "GET", "/push/key", ->(_c, _req, res) { push_public_key(res) } ],
          [ "POST", "/push/subscribe", ->(_c, req, res) { push_subscribe(req, res) } ],
          [ "POST", "/push/unsubscribe", ->(_c, req, res) { push_unsubscribe(req, res) } ],
          [ "POST", "/push/test", ->(_c, req, res) { push_test(req, res) } ],
          [ "GET", %r{\A/turns/([\w-]+)/stream\z}, ->(c, _req, res) { stream_turn(res, c[0]) } ],
          [ "POST", %r{\A/turns/([\w-]+)/(steer|stop|confirm|ask)\z},
            ->(c, req, res) { control_turn(req, res, c[0], c[1]) } ]
        ]
      end

      # A route answers with its captures, or nil when it does not match. An
      # empty array is a match with nothing to hand over, which is why this is
      # not simply `matcher.match(path)`.
      def match_route(matcher, path)
        case matcher
        when String then path == matcher ? [] : nil
        when Array then matcher.include?(path) ? [] : nil
        else matcher.match(path)&.captures
        end
      end
    end
  end
end
