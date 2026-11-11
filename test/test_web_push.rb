# frozen_string_literal: true

require_relative "test_helper"
require "rubot/web/push"

# Web Push without a gem: the two messages the protocol is made of, and the
# table that remembers who asked to be woken.
class TestWebPush < Minitest::Test
  include Rubot::Web

  def setup
    @dir = Dir.mktmpdir("rubot-push")
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  # A stand-in for what `pushManager.subscribe` hands the server.
  def subscription
    key = OpenSSL::PKey::EC.generate(Push::CURVE)
    auth = SecureRandom.random_bytes(16)
    {
      "endpoint" => "https://web.push.apple.com/QGVsbG8",
      "p256dh" => Push.base64url(Push.point_bytes(key)),
      "auth" => Push.base64url(auth),
      "key" => key,
      "auth_secret" => auth
    }
  end

  # Open a record the way the browser does, with nothing from the encoder
  # except the bytes on the wire. If this agrees with the payload, the header,
  # the two HKDF steps and the GCM tag are all where the RFC says they are.
  def decrypt(body, sub)
    salt = body[0, 16]
    assert_equal 4096, body[16, 4].unpack1("N")
    idlen = body[20].unpack1("C")
    assert_equal 65, idlen
    keyid = body[21, idlen]
    ciphertext = body[(21 + idlen)..]

    point = OpenSSL::PKey::EC::Point.new(OpenSSL::PKey::EC::Group.new(Push::CURVE), OpenSSL::BN.new(keyid, 2))
    shared = sub["key"].dh_compute_key(point).rjust(32, "\x00")
    info = "WebPush: info\x00".b + Push.point_bytes(sub["key"]) + keyid
    ikm = OpenSSL::KDF.hkdf(shared, salt: sub["auth_secret"], info: info, length: 32, hash: "SHA256")
    cek = OpenSSL::KDF.hkdf(ikm, salt: salt, info: "Content-Encoding: aes128gcm\x00".b, length: 16, hash: "SHA256")
    nonce = OpenSSL::KDF.hkdf(ikm, salt: salt, info: "Content-Encoding: nonce\x00".b, length: 12, hash: "SHA256")

    cipher = OpenSSL::Cipher.new("aes-128-gcm")
    cipher.decrypt
    cipher.key = cek
    cipher.iv = nonce
    cipher.auth_data = ""
    cipher.auth_tag = ciphertext[-16, 16]
    (cipher.update(ciphertext[0...-16]) + cipher.final).sub(/\x02+\z/n, "").force_encoding(Encoding::UTF_8)
  end

  def test_payload_opens_on_the_browser_side
    sub = subscription
    payload = JSON.generate({ title: "rubot", body: "balasan baru", url: "/s/web_default" })

    body = Push.encrypt(payload, p256dh: sub["p256dh"], auth: sub["auth"])

    assert_equal payload, decrypt(body, sub)
  end

  def test_each_message_uses_a_fresh_salt_and_key
    sub = subscription
    first = Push.encrypt("sama", p256dh: sub["p256dh"], auth: sub["auth"])
    second = Push.encrypt("sama", p256dh: sub["p256dh"], auth: sub["auth"])

    refute_equal first[0, 16], second[0, 16], "salt must not repeat"
    refute_equal first[21, 65], second[21, 65], "ephemeral key must not repeat"
    refute_equal first[(21 + 65)..], second[(21 + 65)..], "ciphertext must not repeat"
  end

  def test_a_different_subscription_cannot_open_the_record
    sub = subscription
    other = subscription
    body = Push.encrypt("rahasia", p256dh: sub["p256dh"], auth: sub["auth"])

    assert_raises(OpenSSL::Cipher::CipherError) { decrypt(body, other) }
  end

  def test_vapid_jwt_is_a_verifiable_es256_signature_for_the_endpoint_origin
    key = OpenSSL::PKey::EC.generate(Push::CURVE)
    header = Push.authorization(key: key, endpoint: "https://fcm.googleapis.com/send/abc", subject: "mailto:a@b.c")

    assert_match(/\Avapid t=/, header)
    token = header[/t=([^,]+)/, 1]
    head, body, signature = token.split(".")
    signing_input = "#{head}.#{body}"
    claims = JSON.parse(Push.unbase64url(body))

    assert_equal "https://fcm.googleapis.com", claims["aud"]
    assert_equal "mailto:a@b.c", claims["sub"]
    assert_operator claims["exp"], :>, Time.now.to_i

    raw = Push.unbase64url(signature)
    der = OpenSSL::ASN1::Sequence([
      OpenSSL::ASN1::Integer(OpenSSL::BN.new(raw[0, 32], 2)),
      OpenSSL::ASN1::Integer(OpenSSL::BN.new(raw[32, 32], 2))
    ]).to_der

    assert key.verify(OpenSSL::Digest.new("SHA256"), der, signing_input), "JWT signature must verify"
    # The key the browser subscribed with must be the one in the header.
    assert_equal Push.base64url(Push.point_bytes(key)), header[/k=(\S+)/, 1]
  end

  def test_a_non_default_port_stays_in_the_audience
    key = OpenSSL::PKey::EC.generate(Push::CURVE)
    header = Push.authorization(key: key, endpoint: "https://example.test:8443/x", subject: "mailto:a@b.c")
    token = header[/t=([^,]+)/, 1]
    claims = JSON.parse(Push.unbase64url(token.split(".")[1]))

    assert_equal "https://example.test:8443", claims["aud"]
  end

  def test_vapid_key_is_created_once_and_kept_private
    path = File.join(@dir, "vapid.json")

    first = Vapid.new(path)
    second = Vapid.new(path)

    assert_equal first.public_key, second.public_key
    assert_equal 65, Push.unbase64url(first.public_key).bytesize
    assert_equal 0o600, File.stat(path).mode & 0o777
  end

  def test_subscriptions_upsert_on_the_endpoint_and_are_read_per_persona
    store = Rubot::Store.new(File.join(@dir, "sessions.db"))
    endpoint = "https://fcm.googleapis.com/send/one"

    store.add_push_subscription(endpoint: endpoint, p256dh: "old-key", auth: "old-auth", persona: "rubot")
    store.add_push_subscription(endpoint: endpoint, p256dh: "new-key", auth: "new-auth", persona: "rubot")
    store.add_push_subscription(endpoint: "https://fcm.googleapis.com/send/two", p256dh: "k", auth: "a")

    all = store.push_subscriptions
    assert_equal 2, all.length, "the same endpoint must not be stored twice"

    mine = store.push_subscriptions("rubot").find { |row| row["endpoint"] == endpoint }
    assert_equal "new-key", mine["p256dh"]
    assert_equal "new-auth", mine["auth"]

    # A subscription that never records when it was last seen cannot be told
    # apart from one that has gone quiet for months.
    seen = store.instance_variable_get(:@db)
                .get_first_value("SELECT last_seen_at FROM push_subscriptions WHERE endpoint = ?", [ endpoint ])
    refute_nil seen

    # A subscription with no persona belongs to every persona; one that chose a
    # persona is only read for that persona.
    assert_equal 2, store.push_subscriptions("rubot").length
    assert_equal 1, store.push_subscriptions("lain").length
    assert_equal "https://fcm.googleapis.com/send/two", store.push_subscriptions("lain").first["endpoint"]

    assert store.drop_push_subscription(endpoint)
    assert_equal 1, store.push_subscriptions.length
    refute store.drop_push_subscription(endpoint)
  ensure
    store&.close
  end

  # The one write that later sends data to a third party: a subscription is an
  # endpoint someone else picked, and every notification is delivered to it.
  def test_a_cross_origin_page_cannot_register_its_own_subscription
    channel = Rubot::Channels::Web.new(channel_config: {})
    fake = Struct.new(:headers) do
      def [](key)
        headers[key]
      end
    end

    assert channel.send(:same_origin?, fake.new({ "Sec-Fetch-Site" => "same-origin" }))
    assert channel.send(:same_origin?, fake.new({ "Sec-Fetch-Site" => "none" }))
    refute channel.send(:same_origin?, fake.new({ "Sec-Fetch-Site" => "cross-site" }))
    refute channel.send(:same_origin?, fake.new({ "Sec-Fetch-Site" => "same-site" }))

    # The older proof, for browsers that send no fetch metadata.
    assert channel.send(:same_origin?, fake.new({ "Origin" => "http://127.0.0.1:4567", "Host" => "127.0.0.1:4567" }))
    refute channel.send(:same_origin?, fake.new({ "Origin" => "https://evil.test", "Host" => "127.0.0.1:4567" }))

    # A client that is not a browser sends neither, and could not be tricked
    # into this in the first place.
    assert channel.send(:same_origin?, fake.new({}))
  end

  # A test notification is pressed from a page that is on screen, and the worker
  # skips pushes while the app is visible — so the test has to say that it wants
  # to be shown anyway, and the answer has to carry the service's status code so
  # "accepted" is not confused with "displayed".
  def test_the_test_notification_asks_to_be_shown_beside_an_open_app
    ua_key = OpenSSL::PKey::EC.generate(Push::CURVE)
    auth = SecureRandom.random_bytes(16)
    requests = Queue.new
    server, port, thread = start_push_service(requests, status: 201)

    store = Rubot::Store.new(File.join(@dir, "sessions.db"))
    store.add_push_subscription(endpoint: "http://127.0.0.1:#{port}/push",
                                p256dh: Push.base64url(Push.point_bytes(ua_key)),
                                auth: Push.base64url(auth))
    Rubot::Session.store = store

    config = Rubot::Config.from_data(
      { "agents" => { "defaults" => { "workspace" => @dir } } },
      config_path: File.join(@dir, "config.yml")
    )
    channel = Rubot::Channels::Web.new(channel_config: {})
    channel.instance_variable_set(:@app_config, config)

    counts = channel.send(:notify_push, "rubot",
                          title: "rubot", body: "halo", url: "/s/web_rubot",
                          sync: true, force: true)

    assert_equal 1, counts["sent"]
    assert_equal [ 201 ], counts["status"]

    payload = JSON.parse(decrypt(requests.pop["body"], { "key" => ua_key, "auth_secret" => auth }))
    assert_equal true, payload["force"], "the test must not be swallowed by a visible window"
  ensure
    Rubot::Session.store = nil
    store&.close
    server&.shutdown
    thread&.join(2)
  end

  # The notification names two images, and the one for the status bar has to be
  # an alpha mask: Android paints that slot white, so a coloured icon with its
  # own background arrives as a solid block — the white square this test exists
  # to keep from coming back.
  def test_the_notification_assets_exist_and_the_badge_is_a_mask
    assets = File.expand_path("../lib/rubot/web/assets", __dir__)
    worker = File.read(File.join(assets, "sw.js"))

    assert_includes worker, %(icon: "/assets/icon-192.png")
    assert_includes worker, %(badge: "/assets/badge.png")
    assert_includes worker, %("/assets/badge.png"),
                    "the badge is needed before a notification arrives"
    assert File.file?(File.join(assets, "icon-192.png")), "the large icon must exist"
    assert File.file?(File.join(assets, "badge.png")), "the badge the worker names must exist"

    header = File.binread(File.join(assets, "badge.png"), 26)
    assert_equal "PNG", header[1, 3]
    width, height, depth, colour = header[16, 10].unpack("NNCC")
    assert_equal 8, depth
    assert_equal 6, colour, "the badge must carry an alpha channel — that mask is the whole point"
    assert_operator width, :>=, 72, "a badge smaller than 72px is upscaled into a blur"
    assert_equal width, height
  end

  # A turn that ran long enough is answered into a conversation nobody was
  # necessarily watching, so its ending travels to the device. The threshold is
  # the only rule: a quick reply is not news.
  def test_a_long_turn_notifies_and_a_short_one_does_not
    ua_key = OpenSSL::PKey::EC.generate(Push::CURVE)
    auth = SecureRandom.random_bytes(16)
    requests = Queue.new
    server, port, thread = start_push_service(requests, status: 201)

    store = Rubot::Store.new(File.join(@dir, "sessions.db"))
    store.add_push_subscription(endpoint: "http://127.0.0.1:#{port}/push",
                                p256dh: Push.base64url(Push.point_bytes(ua_key)),
                                auth: Push.base64url(auth))
    Rubot::Session.store = store

    config = Rubot::Config.from_data(
      { "agents" => { "defaults" => { "workspace" => @dir } } },
      config_path: File.join(@dir, "config.yml")
    )
    channel = Rubot::Channels::Web.new(channel_config: { "turn_notify_after" => 20 })
    channel.instance_variable_set(:@app_config, config)

    session = "web_rubot~20261110-230000"
    turn = Struct.new(:session_id, :response).new(session, "Ringkasan selesai: tiga berkas diubah.")

    # Under the threshold: the reader was probably still at the desk.
    channel.send(:notify_turn_end, turn, 4.0)
    sleep 0.05
    assert requests.empty?, "a four-second turn is not worth a notification"

    channel.send(:notify_turn_end, turn, 61.5)
    payload = JSON.parse(decrypt(requests.pop["body"], { "key" => ua_key, "auth_secret" => auth }))

    assert_equal "Ringkasan selesai: tiga berkas diubah.", payload["body"]
    assert_equal "/s/#{session}", payload["url"], "the tap has to land on the conversation that finished"
    assert_equal "rubot-rubot", payload["tag"]
    refute_equal true, payload["force"], "a real turn is not a test: a visible page should stay quiet"
  ensure
    Rubot::Session.store = nil
    store&.close
    server&.shutdown
    thread&.join(2)
  end

  # A tap is not a request the app made. It can open a window that never saw
  # the gate, or a phone that dropped the session cookie when the app closed —
  # and a bare URL then earns a token prompt instead of the answer the
  # notification just promised. So the conversation URL carries the token.
  def test_a_notification_opens_the_conversation_that_earned_it
    turn = Struct.new(:session_id, :response).new("web_rubot~20261111-011100", "Migrasi selesai, 5 test lulus.")
    channel = Rubot::Channels::Web.new(channel_config: { "token" => "s3cret" })
    sent = []
    channel.define_singleton_method(:notify_push) { |slug, **opts| sent << [slug, opts]; nil }
    channel.define_singleton_method(:persona_title) { |_slug| "rubot · Rubot" }
    channel.define_singleton_method(:owner_slug) { |_sid| "rubot" }

    channel.send(:notify_turn_end, turn, 0.2, requested: "Migrasi selesai")

    slug, push = sent.first
    assert_equal "rubot", slug
    assert_equal "Migrasi selesai", push[:body]
    assert_equal "/s/web_rubot~20261111-011100?token=s3cret", push[:url],
                 "the tap has to land on the conversation, not on the gate"
    assert_equal true, push[:force]

    # The same URL rule for the tick-box that says "there is news": an install
    # without a token gets a plain path, and nothing is appended for it.
    open_channel = Rubot::Channels::Web.new(channel_config: {})
    assert_equal "/s/web_rubot", open_channel.send(:session_url, "web_rubot")
  end

  def test_turn_notifications_can_be_switched_off_and_the_body_is_folded
    turn = Struct.new(:session_id, :response).new("web_rubot", "halo")

    # Zero is off, and off means the archive is never even asked — a channel
    # that was told to stay quiet should not do the work of deciding.
    exploding = Object.new
    def exploding.push_subscriptions(*)
      raise "a silenced channel should not look for devices"
    end
    Rubot::Session.store = exploding

    off = Rubot::Channels::Web.new(channel_config: { "turn_notify_after" => 0 })
    off.send(:notify_turn_end, turn, 999)

    assert_equal "halo", off.send(:turn_note, turn)

    long = "x" * 400
    note = off.send(:turn_note, Struct.new(:response).new(long))
    assert_equal 140, note.length, "a lock screen shows a gist, not the answer"
    assert note.end_with?("…")

    blank = off.send(:turn_note, Struct.new(:response).new("   \n  "))
    assert_equal "Balasan sudah siap.", blank
  ensure
    Rubot::Session.store = nil
  end

  # A push service, as far as this server can tell one: something that accepts
  # a signed POST and answers with a status. The real ones are Apple's and
  # Google's, but the request that reaches them is exactly this.
  def start_push_service(requests, status: 201)
    server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1", Port: 0, AccessLog: [],
      Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL)
    )
    server.mount_proc("/push") do |req, res|
      requests << {
        "authorization" => req["Authorization"].to_s,
        "encoding" => req["Content-Encoding"].to_s,
        "content_type" => req["Content-Type"].to_s,
        "ttl" => req["TTL"].to_s,
        "body" => req.body.to_s.b
      }
      res.status = status
      res.body = ""
    end

    thread = Thread.new { server.start }
    # `Port: 0` lets the kernel pick; the listener knows which one it got.
    50.times do
      break if server.listeners.any? && server.status == :Run

      sleep 0.02
    end
    port = server.listeners.first.addr[1]

    [ server, port, thread ]
  end

  # The request the encoder builds, checked end to end: signed for the endpoint
  # it is going to, sealed so only the subscriber can read it, and carrying the
  # payload it was given.
  def test_delivery_signs_and_seals_a_request_a_push_service_can_read
    ua_key = OpenSSL::PKey::EC.generate(Push::CURVE)
    auth = SecureRandom.random_bytes(16)
    requests = Queue.new
    server, port, thread = start_push_service(requests)

    subscription = {
      "endpoint" => "http://127.0.0.1:#{port}/push",
      "p256dh" => Push.base64url(Push.point_bytes(ua_key)),
      "auth" => Push.base64url(auth)
    }
    payload = JSON.generate({ "title" => "rubot · Rubot", "body" => "pengingat", "url" => "/s/web_rubot" })

    result = Push.deliver(subscription: subscription, payload: payload,
                          key: OpenSSL::PKey::EC.generate(Push::CURVE), subject: "mailto:rubot@localhost")

    assert_equal :ok, result

    request = requests.pop
    assert_match(/\Avapid t=[^.]+\.[^.]+\.[^,]+, k=[A-Za-z0-9_-]+\z/, request["authorization"])
    assert_equal "aes128gcm", request["encoding"]
    assert_equal "application/octet-stream", request["content_type"]
    assert_equal "86400", request["ttl"]
    assert_equal payload, decrypt(request["body"], { "key" => ua_key, "auth_secret" => auth })
  ensure
    server&.shutdown
    thread&.join(2)
  end

  # A browser that uninstalled the app answers 410 forever. The row has to go,
  # or every notification retries a device that is not there.
  def test_a_gone_endpoint_is_forgotten_after_the_next_notification
    ua_key = OpenSSL::PKey::EC.generate(Push::CURVE)
    auth = SecureRandom.random_bytes(16)
    requests = Queue.new
    server, port, thread = start_push_service(requests, status: 410)

    store = Rubot::Store.new(File.join(@dir, "sessions.db"))
    endpoint = "http://127.0.0.1:#{port}/push"
    store.add_push_subscription(endpoint: endpoint, p256dh: Push.base64url(Push.point_bytes(ua_key)),
                                auth: Push.base64url(auth))
    Rubot::Session.store = store

    config = Rubot::Config.from_data(
      { "agents" => { "defaults" => { "workspace" => @dir } } },
      config_path: File.join(@dir, "config.yml")
    )
    channel = Rubot::Channels::Web.new(channel_config: {})
    channel.instance_variable_set(:@app_config, config)

    counts = channel.send(:notify_push, "rubot", title: "rubot", body: "halo", url: "/s/web_rubot", sync: true)

    assert_equal 1, counts["gone"]
    assert_empty store.push_subscriptions, "a dead endpoint must not be retried"
  ensure
    Rubot::Session.store = nil
    store&.close
    server&.shutdown
    thread&.join(2)
  end

  # "Nothing arrived" is the hardest report to act on, because the sender cannot
  # see the device. What it can see is the push service's answer, so a refusal
  # is written down with its code — and the endpoint itself is not, since it is
  # the capability that lets any caller wake that device.
  def test_a_refused_delivery_is_logged_without_leaking_the_endpoint
    ua_key = OpenSSL::PKey::EC.generate(Push::CURVE)
    auth = SecureRandom.random_bytes(16)
    requests = Queue.new
    server, port, thread = start_push_service(requests, status: 500)

    store = Rubot::Store.new(File.join(@dir, "sessions.db"))
    endpoint = "http://127.0.0.1:#{port}/push?cap=secret-capability"
    store.add_push_subscription(endpoint: endpoint, p256dh: Push.base64url(Push.point_bytes(ua_key)),
                                auth: Push.base64url(auth))
    Rubot::Session.store = store

    config = Rubot::Config.from_data(
      { "agents" => { "defaults" => { "workspace" => @dir } } },
      config_path: File.join(@dir, "config.yml")
    )
    channel = Rubot::Channels::Web.new(channel_config: {})
    channel.instance_variable_set(:@app_config, config)

    _out, err = capture_io do
      counts = channel.send(:notify_push, "rubot", title: "rubot", body: "halo",
                            url: "/s/web_rubot", sync: true)
      assert_equal 1, counts["failed"]
    end

    assert_includes err, "500", "the push service's own code is the evidence"
    assert_includes err, "127.0.0.1", "the host says which service answered"
    refute_includes err, "secret-capability", "the endpoint is a capability, not a log field"
  ensure
    Rubot::Session.store = nil
    store&.close
    server&.shutdown
    thread&.join(2)
  end
end
