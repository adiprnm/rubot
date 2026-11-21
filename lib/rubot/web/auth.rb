# frozen_string_literal: true

require "cgi"
require "uri"

module Rubot
  module Web
    # The way in: one token for the whole install, carried in a cookie once the
    # reader has typed it, in the query string of the links the pages write, and
    # inside a push payload for a tap that arrives with no cookie at all.
    #
    # Kept apart from the routes because a route that forgets the check is a
    # leak, and the check is easier to audit when it is not one branch among
    # thirty. Every method here is private to the channel that includes it.
    module Auth
      private

      # WEBrick delivers form/query values as ASCII-8BIT, so anything past
      # ASCII explodes later when a persona is serialised to JSON. Decode to
      # UTF-8 at the edge so the rest of the code can assume valid text.
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

      def token_query
        @token ? "?token=#{CGI.escape(@token)}" : ""
      end

      # Where a notification lands: the conversation it is about, carrying the
      # token the way every link the pages write does.
      #
      # A tap is not a request the app made. It may open a window that never
      # saw the gate, or a phone that dropped the session cookie when the app
      # was closed — and then the URL without the token earns a token prompt
      # instead of the answer the notification just promised. So the token
      # travels in the push payload, which is sealed to the device's own key:
      # the push service carrying it cannot read it.
      def session_url(sid)
        "/s/#{sid}#{token_query}"
      end
    end
  end
end
