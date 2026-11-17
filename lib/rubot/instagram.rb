# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "time"
require "uri"
require_relative "store_service"

module Rubot
  # Instagram's Graph API for the accounts an install connects.
  #
  # The credentials live in the archive's `settings` table (typed into the web
  # settings form); the tokens minted by OAuth live in `instagram_accounts`.
  # Keeping them apart means saving the form can never overwrite a token the
  # callback just wrote.
  #
  # Everything here is plain HTTP + SQLite so it can be tested without a Meta
  # app: the network calls are methods a test can stub, and the store is passed
  # in rather than reached through a global.
  class Instagram
    API_VERSION = "v25.0".freeze
    GRAPH = "https://graph.facebook.com/#{API_VERSION}".freeze
    OAUTH = "https://www.facebook.com/#{API_VERSION}/dialog/oauth".freeze
    SCOPE = "instagram_basic,instagram_content_publish,pages_show_list,pages_read_engagement,business_management".freeze
    CREDENTIAL_KEYS = %w[instagram_app_id instagram_app_secret instagram_redirect_uri instagram_page_id].freeze

    class Error < StandardError; end

    # `store` is used directly in the main Ractor (channels, tests, REPL).
    # `store_port` is the Ractor-safe handle for a session actor's turn: SQLite
    # cannot be touched from a non-main Ractor, so every statement goes through
    # StoreService on the main Ractor instead. A client passes one or the other.
    def initialize(store: nil, store_port: nil, persona: nil)
      @store = store
      @store_port = store_port
      # Accounts are scoped per persona. An empty persona is the legacy set
      # that predates scoping; a client that does not name one sees that set,
      # so old installs and tests keep working unchanged.
      @persona = persona.to_s
    end

    # --- archive access --------------------------------------------------

    # Every read/write below funnels through these few methods so the same
    # Instagram logic works with a direct store or a port. The port path sends
    # only plain SQL strings and arrays across the Ractor boundary.
    def db_execute(sql, params = [])
      if @store_port
        StoreService.request(@store_port, operation: :ig_execute, arguments: { sql: sql, params: params })
      else
        @store.db.execute(sql, params)
      end
    end

    def db_first_row(sql, params = [])
      if @store_port
        StoreService.request(@store_port, operation: :ig_first_row, arguments: { sql: sql, params: params })
      else
        @store.db.get_first_row(sql, params)
      end
    end

    def db_first_value(sql, params = [])
      if @store_port
        StoreService.request(@store_port, operation: :ig_first_value, arguments: { sql: sql, params: params })
      else
        @store.db.get_first_value(sql, params)
      end
    end

    def db_last_insert_row_id
      @store_port ? StoreService.request(@store_port, operation: :ig_last_insert_row_id) : @store.db.last_insert_row_id
    end

    def db_changes
      @store_port ? StoreService.request(@store_port, operation: :ig_changes) : @store.db.changes
    end

    def db_transaction(statements)
      if @store_port
        StoreService.request(@store_port, operation: :ig_transaction, arguments: { statements: statements })
      else
        @store.db.transaction { statements.each { |spec| @store.db.execute(spec.fetch(:sql), spec.fetch(:params, [])) } }
      end
    end

    def archive?
      !@store.nil? || !@store_port.nil?
    end

    # --- credentials -----------------------------------------------------

    def credentials
      settings = if @store_port
        StoreService.request(@store_port, operation: :ig_settings) || {}
      elsif @store
        @store.settings
      else
        {}
      end
      CREDENTIAL_KEYS.to_h { |key| [ key, settings[key].to_s.strip ] }
    end

    def configured?
      creds = credentials
      !creds["instagram_app_id"].empty? && !creds["instagram_app_secret"].empty? &&
        !creds["instagram_redirect_uri"].empty?
    end

    def redirect_uri
      credentials["instagram_redirect_uri"]
    end

    # --- OAuth -----------------------------------------------------------

    # The state is a one-time nonce kept in the archive, not a cookie: the
    # callback arrives from Meta's domain, where a cookie set here would not
    # travel. Each handshake gets its own row so connecting a second account
    # cannot burn the first one's state. A state older than an hour is refused
    # so a stale tab cannot connect an account after the user changed their mind.
    STATE_TTL = 3600

    def authorize_url(label: "", persona: nil)
      raise Error, "Instagram belum dikonfigurasi — isi App ID, App Secret, dan Redirect URI di pengaturan" unless configured?

      # A client may be built without a persona (the ticker, the settings page)
      # and still start a handshake for one — pass it explicitly in that case.
      target = persona.nil? ? @persona : persona.to_s
      state = SecureRandom.hex(24)
      db_execute(
        "INSERT INTO instagram_oauth_states (state, issued_at, label, persona) VALUES (?, ?, ?, ?)",
        [ state, Time.now.to_i, label.to_s, target ]
      )
      params = {
        "client_id" => credentials["instagram_app_id"],
        "redirect_uri" => redirect_uri,
        "scope" => SCOPE,
        "response_type" => "code",
        "state" => state
      }
      "#{OAUTH}?#{URI.encode_www_form(params)}"
    end

    def valid_state?(state)
      return false if state.to_s.empty? || !archive?

      row = db_first_row(
        "SELECT issued_at FROM instagram_oauth_states WHERE state = ?", [ state.to_s ]
      )
      return false unless row

      Time.now.to_i - row[0].to_i <= STATE_TTL
    end

    def burn_state(state)
      db_execute("DELETE FROM instagram_oauth_states WHERE state = ?", [ state.to_s ]) if archive?
    end

    # The persona that opened the OAuth dialog, read back from the state row at
    # callback time. The callback has no session cookie, so this is the only way
    # to know which persona's account set the new token belongs to.
    def state_persona(state)
      return "" if state.to_s.empty? || !archive?

      row = db_first_row(
        "SELECT persona FROM instagram_oauth_states WHERE state = ?", [ state.to_s ]
      )
      row ? row[0].to_s : ""
    end

    # Exchange the code for a user token, find the Page linked to the IG
    # account, then exchange that for a long-lived Page token. The user token
    # is never stored: it is only a way to reach the Page.
    def complete_authorization(code, state)
      raise Error, "State OAuth tidak cocok atau sudah kedaluwarsa — coba lagi" unless valid_state?(state)
      raise Error, "Kode OAuth kosong" if code.to_s.strip.empty?
      raise Error, "Instagram belum dikonfigurasi" unless configured?

      user = api_get("/oauth/access_token", {
        "client_id" => credentials["instagram_app_id"],
        "client_secret" => credentials["instagram_app_secret"],
        "code" => code,
        "grant_type" => "authorization_code",
        "redirect_uri" => redirect_uri
      })
      user_token = user["access_token"].to_s
      raise Error, "Meta tidak mengembalikan access token" if user_token.empty?

      # `instagram_business_account` is NOT a default field of /me/accounts —
      # without an explicit `fields` Meta only returns id/name/access_token/
      # tasks, so every Page looks unlinked and the connect always fails.
      pages = api_get("/me/accounts", {
        "fields" => "id,name,instagram_business_account",
        "access_token" => user_token
      })
      page = Array(pages["data"]).find { |p| p["instagram_business_account"].is_a?(Hash) }

      # Some Pages live inside a Business Portfolio and never show up in
      # /me/accounts even for an admin. When the install knows the Page ID,
      # query it directly — that endpoint still returns the linked IG account.
      unless page
        page_id = credentials["instagram_page_id"].to_s
        unless page_id.empty?
          direct = api_get("/#{page_id}", {
            "fields" => "id,name,instagram_business_account",
            "access_token" => user_token
          })
          page = direct if direct["instagram_business_account"].is_a?(Hash)
        end
      end
      raise Error, "Tidak ada Facebook Page yang terhubung ke akun Instagram Business/Creator" unless page

      ig_id = page.dig("instagram_business_account", "id").to_s
      raise Error, "Page tidak punya akun Instagram Business" if ig_id.empty?

      # /me/accounts already hands us a Page-scoped token. Extending the
      # *user* token instead would give a long-lived user token, which cannot
      # publish to the IG account — always extend the Page token itself.
      # For the direct-Page fallback there is no token in the response, so
      # fall back to the user token (Meta accepts it for the linked Page).
      short_page_token = page["access_token"].to_s
      short_page_token = user_token if short_page_token.empty?
      raise Error, "Meta tidak mengembalikan token Page" if short_page_token.empty?

      long = api_get("/oauth/access_token", {
        "grant_type" => "fb_exchange_token",
        "client_id" => credentials["instagram_app_id"],
        "client_secret" => credentials["instagram_app_secret"],
        "fb_exchange_token" => short_page_token
      })
      page_token = long["access_token"].to_s
      raise Error, "Gagal memperpanjang token Page" if page_token.empty?

      # `account_type` is not a valid field on the Instagram Graph API user
      # node (v25 rejects it). The linked account is necessarily a Business or
      # Creator account anyway, so only the username is needed here.
      profile = api_get("/#{ig_id}", {
        "fields" => "username",
        "access_token" => page_token
      })
      expires = if long["expires_in"]
        (Time.now + long["expires_in"].to_i).utc.iso8601
      end

      acc = save_account(
        access_token: page_token,
        ig_user_id: ig_id,
        username: profile["username"].to_s,
        account_type: "BUSINESS",
        token_type: long["token_type"].to_s,
        expires_at: expires
      )
      burn_state(state)
      acc
    end

    # --- accounts --------------------------------------------------------

    # The token lives once in `instagram_accounts`; which accounts a persona
    # may use lives in `instagram_persona_accounts`. The join carries the
    # persona's default flag, so the same account can be linked under several
    # personas without copying its token.
    ACCOUNT_COLUMNS = "a.id, a.access_token, a.ig_user_id, a.username, a.account_type, a.token_type, a.expires_at, pa.is_default, a.connected_at, a.updated_at".freeze
    ACCOUNT_JOIN = <<~SQL.freeze
      FROM instagram_accounts a
      JOIN instagram_persona_accounts pa ON pa.account_id = a.id
    SQL

    def account_row(row)
      return nil unless row

      {
        "id" => row[0].to_i,
        "access_token" => row[1].to_s,
        "ig_user_id" => row[2].to_s,
        "username" => row[3].to_s,
        "account_type" => row[4].to_s,
        "token_type" => row[5].to_s,
        "expires_at" => row[6].to_s,
        "is_default" => row[7].to_i == 1,
        "connected_at" => row[8].to_s,
        "updated_at" => row[9].to_s
      }
    end

    # All accounts linked to this persona, default first. `account` is the one
    # used when a caller does not name one explicitly.
    def accounts
      return [] unless archive?

      db_execute(
        "SELECT #{ACCOUNT_COLUMNS} #{ACCOUNT_JOIN} WHERE pa.persona = ? ORDER BY pa.is_default DESC, a.id ASC",
        [ @persona ]
      ).map { |row| account_row(row) }
    end

    # Every account the install has ever connected, regardless of persona.
    # The card uses this to offer "link existing" for accounts another persona
    # already paid the OAuth cost for.
    def all_accounts
      return [] unless archive?

      db_execute(
        "SELECT id, access_token, ig_user_id, username, account_type, token_type, expires_at, 0, connected_at, updated_at FROM instagram_accounts ORDER BY id ASC"
      ).map { |row| account_row(row) }
    end

    # Link an existing install-wide account into this persona without another
    # OAuth round trip. Returns the persona's account row.
    def link_account(id: nil, username: nil)
      global = all_accounts.find do |a|
        (id && id.to_s.match?(/\A\d+\z/) && a["id"] == id.to_i) ||
          (username && a["username"].to_s.downcase == username.to_s.sub(/\A@/, "").downcase)
      end
      raise Error, "Akun Instagram tidak ditemukan" unless global

      existing = db_first_row(
        "SELECT account_id FROM instagram_persona_accounts WHERE persona = ? AND account_id = ?",
        [ @persona, global["id"] ]
      )
      unless existing
        now = Time.now.utc.iso8601
        db_execute(
          "INSERT INTO instagram_persona_accounts (persona, account_id, is_default, linked_at) VALUES (?, ?, ?, ?)",
          [ @persona, global["id"], accounts.empty? ? 1 : 0, now ]
        )
      end
      account(id: global["id"])
    end

    def account(id: nil, username: nil)
      list = accounts
      return nil if list.empty?
      return list.first if id.nil? && username.nil?

      # A username like "adipurnm" is not an id: `"adipurnm".to_i` is 0, which
      # matches no row and hides a perfectly good username match. Only treat
      # the ref as an id when it actually looks like one.
      if id && id.to_s.match?(/\A\d+\z/)
        list.find { |a| a["id"] == id.to_i } ||
          list.find { |a| a["ig_user_id"] == id.to_s }
      else
        needle = (id || username).to_s.sub(/\A@/, "").downcase
        list.find { |a| a["username"].to_s.downcase == needle }
      end
    end

    # Accounts connected somewhere on this install but not yet linked into
    # this persona. The card offers these as one-click links, no OAuth needed.
    def linkable_accounts
      mine = accounts.map { |a| a["id"] }
      all_accounts.reject { |a| mine.include?(a["id"]) }
    end

    def connected?
      !accounts.empty?
    end

    # Look up an account by its global id, across every persona. The minute
    # ticker schedules posts by account_id and has no persona context, so it
    # must be able to reach the exact account a post was queued for.
    def account_by_id(id)
      row = db_first_row(
        "SELECT id, access_token, ig_user_id, username, account_type, token_type, expires_at, 0, connected_at, updated_at FROM instagram_accounts WHERE id = ?",
        [ id.to_i ]
      )
      account_row(row)
    end

    # Resolve an account from a tool argument. Returns nil when there is no
    # account at all, or when a name was given but no account matched.
    def resolve_account(ref)
      return accounts.first if ref.to_s.strip.empty?
      account(username: ref) || account(id: ref)
    end

    def save_account(access_token:, ig_user_id:, username:, account_type: "", token_type: "", expires_at: nil)
      now = Time.now.utc.iso8601
      existing = db_first_row(
        "SELECT id FROM instagram_accounts WHERE ig_user_id = ?", [ ig_user_id ]
      )

      if existing
        db_execute(<<~SQL, [ access_token, username, account_type, token_type, expires_at, now, existing[0] ])
          UPDATE instagram_accounts SET
            access_token = ?, username = ?, account_type = ?, token_type = ?,
            expires_at = ?, updated_at = ?
          WHERE id = ?
        SQL
        id = existing[0].to_i
      else
        db_execute(<<~SQL, [ access_token, ig_user_id, username, account_type, token_type, expires_at, now, now ])
          INSERT INTO instagram_accounts
            (access_token, ig_user_id, username, account_type, token_type, expires_at, connected_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        id = db_last_insert_row_id
      end

      # The token row is install-wide; the persona link is what makes it show
      # up in this persona's card. Re-authorizing an already linked account is
      # a no-op here, and linking it into a new persona is one cheap insert.
      link_account(id: id)
      account(id: id)
    end

    def set_default(id)
      acc = account(id: id)
      raise Error, "Akun Instagram tidak ditemukan" unless acc

      db_transaction([
        { sql: "UPDATE instagram_persona_accounts SET is_default = 0 WHERE persona = ?", params: [ @persona ] },
        { sql: "UPDATE instagram_persona_accounts SET is_default = 1 WHERE persona = ? AND account_id = ?", params: [ @persona, acc["id"] ] }
      ])
      acc
    end

    # Unlink from this persona only. The token stays install-wide so another
    # persona can still use it, and a later reconnect here needs no OAuth.
    def disconnect(id: nil, username: nil)
      acc = account(id: id, username: username)
      raise Error, "Akun Instagram tidak ditemukan" unless acc

      db_execute(
        "DELETE FROM instagram_persona_accounts WHERE persona = ? AND account_id = ?",
        [ @persona, acc["id"] ]
      )
      set_default(accounts.first["id"]) if accounts.any?
      acc
    end

    # --- publishing ------------------------------------------------------

    # Feed posts need a publicly reachable image URL — Meta fetches it itself.
    # The caption is optional; the image is not. `account:` picks which of the
    # connected accounts publishes; without one the default account is used.
    def publish(caption:, image_url:, account: nil, account_object: nil)
      acc = account_object || resolve_account(account)
      raise Error, "Instagram belum terhubung — ketik 'connect ke instagram' dulu" unless acc

      token = acc["access_token"].to_s
      raise Error, "Token Instagram hilang — hubungkan kembali" if token.empty?
      raise Error, "Gambar wajib diisi (URL publik yang bisa diakses Meta)" if image_url.to_s.strip.empty?

      media = api_post("/#{acc["ig_user_id"]}/media", {
        "image_url" => image_url,
        "caption" => caption.to_s,
        "access_token" => token
      })
      media_id = media["id"].to_s
      raise Error, "Gagal membuat media Instagram" if media_id.empty?

      # Meta may need a moment to finish processing the upload. A short poll
      # keeps a scheduled post from failing on a race with their CDN.
      ready = wait_for_media(media_id, token)
      raise Error, "Gagal mengunggah gambar ke Instagram: #{ready["status"].to_s}" unless %w[FINISHED].include?(ready["status"].to_s)

      result = api_post("/#{acc["ig_user_id"]}/media_publish", {
        "creation_id" => media_id,
        "access_token" => token
      })
      result["id"].to_s
    end

    def wait_for_media(media_id, token, attempts: 10, sleep_seconds: 2)
      status = { "status" => "" }
      attempts.times do
        status = api_get("/#{media_id}", { "fields" => "status_code", "access_token" => token })
        code = status["status_code"].to_s
        return { "status" => "FINISHED" } if code == "FINISHED"
        return { "status" => code } if %w[ERROR EXPIRED].include?(code)

        sleep sleep_seconds
      end
      { "status" => status["status_code"].to_s }
    end

    # --- scheduling ------------------------------------------------------

    def schedule(caption:, image_url:, scheduled_at:, account: nil)
      raise Error, "scheduled_at wajib diisi" if scheduled_at.to_s.empty?
      raise Error, "Gambar wajib diisi" if image_url.to_s.strip.empty?

      acc = resolve_account(account)
      raise Error, "Instagram belum terhubung — ketik 'connect ke instagram' dulu" unless acc

      scheduled = Time.iso8601(scheduled_at.to_s)
      raise Error, "Jadwal harus di masa depan" if scheduled <= Time.now

      now = Time.now.utc.iso8601
      db_execute(<<~SQL, [ caption.to_s, image_url, scheduled.utc.iso8601, acc["id"], now, now ])
        INSERT INTO instagram_posts (caption, image_url, scheduled_at, account_id, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'pending', ?, ?)
      SQL
      db_last_insert_row_id
    end

    def posts(limit: 20, account: nil)
      acc = resolve_account(account) unless account.to_s.strip.empty?
      if acc
        db_execute(<<~SQL, [ acc["id"], limit ]).map do |row|
          SELECT id, caption, image_url, scheduled_at, status, ig_media_id, error, account_id
          FROM instagram_posts WHERE account_id = ? ORDER BY scheduled_at DESC LIMIT ?
        SQL
          post_row(row)
        end
      else
        db_execute(<<~SQL, [ limit ]).map do |row|
          SELECT id, caption, image_url, scheduled_at, status, ig_media_id, error, account_id
          FROM instagram_posts ORDER BY scheduled_at DESC LIMIT ?
        SQL
          post_row(row)
        end
      end
    end

    def post_row(row)
      { id: row[0], caption: row[1], image_url: row[2], scheduled_at: row[3],
        status: row[4], ig_media_id: row[5], error: row[6], account_id: row[7] }
    end

    def cancel_post(id)
      db_execute(
        "UPDATE instagram_posts SET status = 'cancelled', updated_at = ? WHERE id = ? AND status = 'pending'",
        [ Time.now.utc.iso8601, id.to_i ]
      )
      db_changes.positive?
    end

    # Publish everything that came due. Called by the web channel's minute
    # ticker; one failure never holds back the posts behind it. Each post is
    # published as the account it was scheduled for.
    def publish_due
      now = Time.now.utc.iso8601
      rows = db_execute(<<~SQL, [ now ])
        SELECT id, caption, image_url, account_id FROM instagram_posts
        WHERE status = 'pending' AND scheduled_at <= ? ORDER BY scheduled_at
      SQL
      rows.filter_map do |id, caption, image_url, account_id|
        begin
          acc = account_by_id(account_id)
          raise Error, "Akun Instagram untuk postingan ##{id} sudah diputus" unless acc

          media_id = publish(caption: caption, image_url: image_url, account_object: acc)
          db_execute(
            "UPDATE instagram_posts SET status = 'published', ig_media_id = ?, updated_at = ? WHERE id = ?",
            [ media_id, Time.now.utc.iso8601, id ]
          )
          { id: id, status: "published", media_id: media_id, account: acc["username"] }
        rescue StandardError => e
          db_execute(
            "UPDATE instagram_posts SET status = 'failed', error = ?, updated_at = ? WHERE id = ?",
            [ e.message, Time.now.utc.iso8601, id ]
          )
          { id: id, status: "failed", error: e.message }
        end
      end
    end

    # --- HTTP ------------------------------------------------------------

    def api_get(path, params)
      uri = URI("#{GRAPH}#{path}")
      uri.query = URI.encode_www_form(params)
      request(Net::HTTP::Get.new(uri))
    end

    def api_post(path, params)
      uri = URI("#{GRAPH}#{path}")
      req = Net::HTTP::Post.new(uri)
      req.set_form_data(params)
      request(req)
    end

    private

    def request(req)
      res = Net::HTTP.start(req.uri.hostname, req.uri.port, use_ssl: true,
                            open_timeout: 10, read_timeout: 30) { |http| http.request(req) }
      body = JSON.parse(res.body.to_s)
      raise Error, body.dig("error", "message").to_s unless res.is_a?(Net::HTTPSuccess) || body["error"].nil?

      body
    rescue JSON::ParserError
      raise Error, "Respons Meta bukan JSON (HTTP #{res&.code})"
    end

    def secure_compare(a, b)
      return false unless a.bytesize == b.bytesize

      a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
    end
  end
end
