# frozen_string_literal: true

require_relative "../tool"
require_relative "../instagram"
require_relative "../store_service"

module Rubot
  module Tools
    # Instagram, from the conversation's point of view.
    #
    # `connect` does not open a browser itself — the web channel turns its
    # result into a card with a button. The other operations are plain answers:
    # scheduling is a row in the archive, and the web channel's minute ticker
    # publishes what came due.
    class Instagram < Tool
      def name
        "instagram"
      end

      def description
        <<~DESC.strip
          Connect an Instagram Business/Creator account and publish scheduled feed posts.

          Operations:
          - connect: when the user says "connect ke instagram", "hubungkan IG",
            or asks to link their Instagram. Returns a card with a Connect button
            on the web channel. Do NOT claim the account is connected yet. The
            card is the whole answer — call this tool with no preamble and add
            no text of your own before or after it.
          - status: list every connected account and which one is the default.
          - schedule: queue an image post. Needs `image_url` (a public HTTPS URL
            Meta can fetch) and `scheduled_at` (ISO 8601, e.g. "2026-11-20T09:00:00+07:00").
            `caption` is optional. Use this for "posting nanti", "jadwalkan",
            "post jam 9 besok".
          - posts: list scheduled and published posts.
          - cancel: cancel a pending post by id.
          - publish: publish immediately instead of scheduling (same image_url).
          - link: link an account already connected under another persona,
            without another OAuth round trip. Takes `account` (username or id).
          - disconnect: forget an account from this persona only.

          Several accounts can be connected. Every operation that acts on an
          account takes an optional `account` (username or id). If the user
          names one, pass it. If they do not and more than one account is
          connected, DO NOT guess: ask the user which account to use first.

          Instagram feed posts REQUIRE an image. Text-only posts are not
          supported by the API. The account must be Business or Creator and
          linked to a Facebook Page.
        DESC
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "operation" => {
              "type" => "string",
              "enum" => %w[connect status schedule posts cancel publish link disconnect],
              "description" => "Instagram operation"
            },
            "caption" => { "type" => "string", "description" => "Post caption" },
            "image_url" => { "type" => "string", "description" => "Public HTTPS image URL" },
            "scheduled_at" => { "type" => "string", "description" => "ISO 8601 time, with timezone" },
            "post_id" => { "type" => "integer", "description" => "Post id for cancel" },
            "account" => { "type" => "string", "description" => "Username or id of the Instagram account to use. Omit only when there is one account or the user named none and you already asked." }
          },
          "required" => [ "operation" ]
        }
      end

      # The web channel reads this to draw the connect card. Kept on the tool
      # rather than guessed from the result text so a translated answer cannot
      # break the button.
      CONNECT_MARKER = "[[instagram_connect_card]]"

      # The card is the whole answer. The agent skips narration for this call
      # and ends the turn on the marker, so the model never gets to add a
      # "sure, let me connect you" on top of a button that is already there.
      def silent_operation?(arguments)
        arguments["operation"].to_s == "connect"
      end

      def silent_result?(result)
        result.to_s.include?(CONNECT_MARKER)
      end

      # Injected by the Agent with the session's store port. Inside a session
      # Ractor SQLite cannot be opened, so the tool must reach the archive
      # through StoreService instead of Session.store. When no port is set
      # (tests, REPL, channels on the main Ractor) it falls back to the store.
      attr_accessor :store_port

      # Injected by the Agent with the session's persona slug, so accounts are
      # scoped to the persona whose conversation is running. Empty means the
      # legacy unscoped set.
      attr_accessor :persona

      def execute(arguments)
        op = arguments["operation"].to_s
        ig = build_client
        return "ERROR: Arsip sesi belum terbuka, Instagram tidak bisa dipakai." unless ig_ready?(ig)

        ref = arguments["account"].to_s

        case op
        when "connect"
          if !ig.configured?
            "ERROR: Instagram belum dikonfigurasi. Buka halaman Pengaturan dan isi " \
              "App ID, App Secret, dan Redirect URI Instagram."
          else
            CONNECT_MARKER
          end
        when "status"
          list = ig.accounts
          return "Belum terhubung. Ketik 'connect ke instagram' untuk mulai." if list.empty?

          list.map do |a|
            "##{a["id"]} @#{a["username"]}#{a["is_default"] ? " (default)" : ""} — " \
              "terhubung sejak #{a["connected_at"]}"
          end.join("\n")
        when "schedule"
          id = ig.schedule(caption: arguments["caption"], image_url: arguments["image_url"],
                           scheduled_at: arguments["scheduled_at"], account: ref)
          "Postingan ##{id} dijadwalkan pada #{arguments["scheduled_at"]}."
        when "posts"
          list = ig.posts(account: ref)
          return "Belum ada postingan Instagram." if list.empty?

          list.map { |p| "##{p[:id]} [#{p[:status]}] #{p[:scheduled_at]} — #{p[:caption].to_s[0, 60]}" }.join("\n")
        when "cancel"
          ig.cancel_post(arguments["post_id"]) ? "Postingan dibatalkan." : "Tidak ada postingan pending dengan id itu."
        when "publish"
          id = ig.publish(caption: arguments["caption"], image_url: arguments["image_url"], account: ref)
          "Terbit di Instagram dengan media id #{id}."
        when "link"
          acc = ig.link_account(id: ref, username: ref)
          "Akun Instagram @#{acc["username"]} di-link ke persona ini."
        when "disconnect"
          acc = ig.disconnect(id: ref, username: ref)
          "Instagram @#{acc["username"]} diputus dari persona ini."
        else
          "ERROR: Operasi Instagram tidak dikenal: #{op}"
        end
      rescue Rubot::Instagram::Error => e
        "ERROR: #{e.message}"
      rescue ArgumentError => e
        "ERROR: #{e.message}"
      end

      private

      def build_client
        if @store_port
          Rubot::Instagram.new(store_port: @store_port, persona: @persona)
        else
          Rubot::Instagram.new(store: Session.store, persona: @persona)
        end
      end

      def ig_ready?(ig)
        !ig.nil? && ig.archive?
      end
    end
  end
end
