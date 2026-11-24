# frozen_string_literal: true

require "cgi"

module Rubot
  module Web
    module Routes
      # The Instagram connect flow: the button, the OAuth callback Meta sends the
      # browser back to, the card that shows what is linked, and the ticker that
      # publishes scheduled posts.
      #
      # Included into the channel. `Instagram` in this namespace is this module,
      # so the client is always spelled `Rubot::Instagram`.
      module Instagram
        private

        def instagram_client(persona: "")
          Rubot::Instagram.new(store: Rubot::Archive.current, persona: persona)
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
          unless Rubot::Archive.current
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

          # The button is an htmx request targeting the card it sits in, so answer
          # with the card itself: htmx swaps it straight back to the connect
          # state. A redirect would reload the whole page and lose the turn's live
          # stream.
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
          unless Rubot::Archive.current
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
          return unless Rubot::Archive.current

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
      end
    end
  end
end
