# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "rubot/instagram"
require "rubot/tools/instagram"

class TestInstagram < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rubot-ig-")
    @store = Rubot::Store.new(File.join(@dir, "sessions.db"))
    @ig = Rubot::Instagram.new(store: @store)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def configure
    @store.update_settings(
      "instagram_app_id" => "app-id",
      "instagram_app_secret" => "app-secret",
      "instagram_redirect_uri" => "https://rubot.ts.net/instagram/callback"
    )
  end

  def test_not_configured_without_credentials
    refute @ig.configured?
    error = assert_raises(Rubot::Instagram::Error) { @ig.authorize_url }
    assert_match(/belum dikonfigurasi/, error.message)
  end

  def test_authorize_url_carries_state_and_scope
    configure
    url = @ig.authorize_url
    query = URI.decode_www_form(URI(url).query).to_h

    assert_equal "app-id", query["client_id"]
    assert_equal "https://rubot.ts.net/instagram/callback", query["redirect_uri"]
    assert_equal Rubot::Instagram::SCOPE, query["scope"]
    assert_equal "code", query["response_type"]
    assert_equal 48, query["state"].length
    assert @ig.valid_state?(query["state"])
  end

  def test_state_is_single_use_and_expires
    configure
    state = URI.decode_www_form(URI(@ig.authorize_url).query).to_h["state"]
    assert @ig.valid_state?(state)

    @store.db.execute("UPDATE instagram_oauth_states SET issued_at = 1000 WHERE state = ?", [ state ])
    refute @ig.valid_state?(state), "an hour-old state must not be accepted"

    @ig.burn_state(state)
    refute @ig.valid_state?(state), "a burned state must not be accepted"
  end

  def test_complete_authorization_exchanges_code_and_saves_page_token
    configure
    state = URI.decode_www_form(URI(@ig.authorize_url).query).to_h["state"]
    @ig.stub(:api_get, ->(path, params) {
      case path
      when "/oauth/access_token"
        case params["grant_type"]
        when "authorization_code" then { "access_token" => "user-token" }
        when "fb_exchange_token"
          assert_equal "short-page-token", params["fb_exchange_token"],
                       "must extend the Page token, not the user token"
          { "access_token" => "page-token", "expires_in" => 5_175_360, "token_type" => "bearer" }
        end
      when "/me/accounts"
        if params["fields"]
          assert_equal "id,name,instagram_business_account", params["fields"],
                       "the IG link is not a default field — asking without it always finds no Page"
          { "data" => [ { "id" => "page", "access_token" => "short-page-token",
                          "instagram_business_account" => { "id" => "ig-123" } } ] }
        else
          { "data" => [ { "id" => "page" } ] }
        end
      when "/ig-123"
        { "username" => "adipurnm" }
      else
        raise "unexpected path #{path}"
      end
    }) do
      acc = @ig.complete_authorization("the-code", state)
      assert_equal "adipurnm", acc["username"]
      assert_equal "ig-123", acc["ig_user_id"]
    end

    assert @ig.connected?
    assert_equal "adipurnm", @ig.account["username"]
    assert_equal "page-token", @store.db.get_first_value("SELECT access_token FROM instagram_accounts WHERE id = 1")
    refute @ig.valid_state?(state), "the state is burned after use"
  end

  def test_complete_authorization_refuses_bad_state
    configure
    error = assert_raises(Rubot::Instagram::Error) { @ig.complete_authorization("code", "bogus") }
    assert_match(/State OAuth/, error.message)
  end

  def test_complete_authorization_needs_a_business_page
    configure
    state = URI.decode_www_form(URI(@ig.authorize_url).query).to_h["state"]
    @ig.stub(:api_get, ->(path, _params) {
      path == "/oauth/access_token" ? { "access_token" => "user-token" } : { "data" => [] }
    }) do
      error = assert_raises(Rubot::Instagram::Error) { @ig.complete_authorization("code", state) }
      assert_match(/Business\/Creator/, error.message)
    end
  end

  def test_schedule_and_posts
    @ig.save_account(access_token: "t", ig_user_id: "ig-1", username: "adipurnm")
    id = @ig.schedule(caption: "halo", image_url: "https://example.com/a.jpg",
                      scheduled_at: (Time.now + 3600).iso8601)
    posts = @ig.posts
    assert_equal 1, posts.size
    assert_equal id, posts.first[:id]
    assert_equal "pending", posts.first[:status]

    assert @ig.cancel_post(id)
    refute @ig.cancel_post(id), "cancelling twice is a no-op"
    assert_equal "cancelled", @ig.posts.first[:status]
  end

  def test_schedule_rejects_past_time_and_missing_image
    assert_raises(Rubot::Instagram::Error) do
      @ig.schedule(caption: "", image_url: "https://example.com/a.jpg",
                   scheduled_at: (Time.now - 60).iso8601)
    end
    assert_raises(Rubot::Instagram::Error) do
      @ig.schedule(caption: "", image_url: "", scheduled_at: (Time.now + 60).iso8601)
    end
  end

  def test_publish_due_marks_success_and_failure_without_stopping
    @ig.save_account(access_token: "page-token", ig_user_id: "ig-1", username: "adipurnm")
    # Insert past-due rows directly: `schedule` deliberately refuses a past
    # time, but a row can become due while the ticker is asleep.
    [ [ "satu", "https://example.com/a.jpg", 60 ], [ "dua", "https://example.com/b.jpg", 30 ] ].each do |caption, url, ago|
      now = Time.now.utc.iso8601
      @store.db.execute(<<~SQL, [ caption, url, (Time.now - ago).utc.iso8601, 1, now, now ])
        INSERT INTO instagram_posts (caption, image_url, scheduled_at, account_id, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'pending', ?, ?)
      SQL
    end

    calls = []
    @ig.stub(:publish, ->(caption:, image_url:, account: nil, account_object: nil) {
      calls << caption
      raise Rubot::Instagram::Error, "upload gagal" if caption == "satu"

      "media-#{caption}"
    }) { @ig.publish_due }

    assert_equal %w[satu dua], calls
    statuses = @ig.posts.to_h { |p| [ p[:caption], p[:status] ] }
    assert_equal "failed", statuses["satu"]
    assert_equal "published", statuses["dua"]
    assert_equal "media-dua", @ig.posts.find { |p| p[:caption] == "dua" }[:ig_media_id]
  end

  def test_accounts_are_scoped_per_persona
    a = Rubot::Instagram.new(store: @store, persona: "kanyaah")
    b = Rubot::Instagram.new(store: @store, persona: "rubot")

    a.save_account(access_token: "t-a", ig_user_id: "ig-1", username: "kanyaahweb")
    assert a.connected?
    refute b.connected?, "another persona must not see this account"

    # The token is install-wide: linking the same IG account into a second
    # persona needs no OAuth and does not copy or overwrite the token.
    b.link_account(username: "kanyaahweb")
    assert_equal "t-a", a.account["access_token"]
    assert_equal "t-a", b.account["access_token"], "both personas use the one stored token"
    assert_equal 1, @store.db.get_first_value("SELECT COUNT(*) FROM instagram_accounts")

    # Each persona has its own default, and disconnecting one leaves the other.
    a.save_account(access_token: "t-a2", ig_user_id: "ig-2", username: "kanyaahdua")
    assert_equal "kanyaahweb", a.account["username"], "the first account stays default"
    b.disconnect(username: "kanyaahweb")
    refute b.connected?
    assert a.connected?, "disconnecting one persona leaves the other's accounts"
    assert_equal 2, @store.db.get_first_value("SELECT COUNT(*) FROM instagram_accounts"),
                 "the token rows survive a persona disconnect"
  end

  def test_linkable_accounts_lists_only_accounts_not_yet_linked
    a = Rubot::Instagram.new(store: @store, persona: "kanyaah")
    b = Rubot::Instagram.new(store: @store, persona: "rubot")
    a.save_account(access_token: "t-a", ig_user_id: "ig-1", username: "kanyaahweb")

    assert_equal [], a.linkable_accounts.map { |x| x["username"] }
    assert_equal [ "kanyaahweb" ], b.linkable_accounts.map { |x| x["username"] }

    b.link_account(username: "kanyaahweb")
    assert_equal [], b.linkable_accounts, "a linked account is no longer offered"
  end

  def test_oauth_state_carries_the_persona
    configure
    a = Rubot::Instagram.new(store: @store, persona: "kanyaah")
    state = URI.decode_www_form(URI(a.authorize_url).query).to_h["state"]
    assert_equal "kanyaah", a.state_persona(state)
    # The callback has no persona context of its own: it reads the persona back
    # from the state row through a fresh client before saving the token.
    assert_equal "kanyaah", @ig.state_persona(state)
  end

  def test_disconnect_removes_account
    @ig.save_account(access_token: "t", ig_user_id: "ig", username: "u")
    assert @ig.connected?
    @ig.disconnect
    refute @ig.connected?
  end

  def test_tool_connect_card_and_status
    tool = Rubot::Tools::Instagram.new
    Rubot::Session.stub(:store, @store) do
      configure
      result = tool.execute("operation" => "connect")
      assert_includes result, Rubot::Tools::Instagram::CONNECT_MARKER

      result = tool.execute("operation" => "status")
      assert_match(/Belum terhubung/, result)

      @ig.save_account(access_token: "t", ig_user_id: "ig", username: "adipurnm")
      result = tool.execute("operation" => "status")
      assert_match(/@adipurnm/, result)
      assert_match(/default/, result)
    end
  end

  def test_tool_schedule_uses_iso_time
    tool = Rubot::Tools::Instagram.new
    Rubot::Session.stub(:store, @store) do
      @ig.save_account(access_token: "t", ig_user_id: "ig-1", username: "adipurnm")
      result = tool.execute("operation" => "schedule", "caption" => "halo",
                            "image_url" => "https://example.com/a.jpg",
                            "scheduled_at" => (Time.now + 3600).iso8601)
      assert_match(/dijadwalkan/, result)
      assert_equal 1, @ig.posts.size
    end
  end
end
