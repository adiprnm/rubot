# frozen_string_literal: true

require "openssl"
require "json"
require "net/http"
require "uri"
require "securerandom"
require "fileutils"

module Rubot
  module Web
    # Web Push, written out rather than pulled in.
    #
    # The whole of it is two messages. Outward, a short ES256 JWT that says who
    # is allowed to wake this browser (VAPID). Inward, one encrypted record that
    # carries the notification (RFC 8291, `aes128gcm`). Neither needs a service
    # of our own: the browser hands over an endpoint when it subscribes, and the
    # payload is sealed to a key only that browser holds.
    #
    # The pieces are here because they are small enough to read. The alternative
    # was a gem whose only job is these two hundred lines, for a feature used a
    # few times a day.
    module Push
      # The one curve Web Push uses. Both key pairs — ours for VAPID, the
      # browser's for the payload — are P-256.
      CURVE = "prime256v1"
      # An uncompressed P-256 point: 0x04, then x and y. Every key in the
      # protocol travels in this shape, which is why it is one constant.
      POINT_BYTES = 65
      # Record size for a single-record message. A notification never fills it;
      # the header still has to state one, and 4096 is what every push service
      # expects.
      RECORD_SIZE = 4096
      # How long the push service should keep trying if the device is asleep.
      DEFAULT_TTL = 24 * 60 * 60
      # Twelve hours is shorter than any push service wants (24h) and longer
      # than any retry needs: a VAPID token older than this is refused, and one
      # minted per delivery is a signature we cannot cache anyway.
      JWT_LIFETIME = 12 * 60 * 60

      module_function

      # base64url without padding — the encoding the protocol speaks. Standard
      # base64 in a query string or a header is a different string to the
      # server, and a `+` may even become a space on the way.
      def base64url(bytes)
        [ bytes ].pack("m0").tr("+/", "-_").delete("=")
      end

      def unbase64url(text)
        padded = text.to_s.tr("-_", "+/")
        padded += "=" * ((4 - padded.length % 4) % 4)
        padded.unpack1("m0")
      end

      # A brand-new P-256 key pair. The private half is kept as PEM because it
      # is the shape OpenSSL reads back without any ASN.1 assembly on our side;
      # the public half is base64url because that is what the browser API wants.
      def generate_keypair
        key = OpenSSL::PKey::EC.generate(CURVE)
        {
          "private_key" => key.private_to_pem,
          "public_key" => base64url(point_bytes(key))
        }
      end

      # The uncompressed point of a key, which is what `applicationServerKey`
      # and `p256dh` both are. Takes a key or an already-extracted point, since
      # the payload step has the browser's public half as a bare point.
      def point_bytes(key)
        point = key.is_a?(OpenSSL::PKey::EC::Point) ? key : key.public_key
        point.to_octet_string(:uncompressed)
      end

      # --- VAPID ---------------------------------------------------------

      # `Authorization: vapid t=<jwt>, k=<public key>` for one endpoint.
      #
      # The audience is the endpoint's origin, not ours: the push service
      # checks that the token was minted for it, so a stolen token cannot be
      # replayed at another service. The claims are the whole of the proof —
      # there is no account anywhere to look us up in.
      def authorization(key:, endpoint:, subject:)
        uri = URI.parse(endpoint.to_s)
        audience = "#{uri.scheme}://#{uri.host}#{uri.port && !default_port?(uri) ? ":#{uri.port}" : ""}"
        token = jwt(key: key, audience: audience, subject: subject)
        "vapid t=#{token}, k=#{base64url(point_bytes(key))}"
      rescue URI::InvalidURIError
        nil
      end

      def default_port?(uri)
        (uri.scheme == "https" && uri.port == 443) || (uri.scheme == "http" && uri.port == 80)
      end

      def jwt(key:, audience:, subject:, now: Time.now)
        header = base64url(JSON.generate({ "typ" => "JWT", "alg" => "ES256" }))
        claims = base64url(JSON.generate({
          "aud" => audience,
          "exp" => (now.to_i + JWT_LIFETIME),
          "sub" => subject.to_s
        }))
        signing_input = "#{header}.#{claims}"
        # ECDSA comes back as DER; JWS wants the bare 32-byte r and 32-byte s,
        # so the two halves are cut out of the SEQUENCE and padded on the left.
        der = key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
        sequence = OpenSSL::ASN1.decode(der)
        r = sequence.value[0].value.to_s(2).rjust(32, "\x00")
        s = sequence.value[1].value.to_s(2).rjust(32, "\x00")
        "#{signing_input}.#{base64url(r + s)}"
      end

      # --- payload -------------------------------------------------------

      # One `aes128gcm` record, sealed to the browser's `p256dh` key.
      #
      # The shape on the wire is the RFC 8188 header followed by the ciphertext:
      #
      #   salt(16) | rs(4, big-endian) | idlen(1) | keyid(idlen) | ciphertext
      #
      # `keyid` is our ephemeral public key: the browser needs it to derive the
      # same shared secret we did, and it is the only way to open the record.
      def encrypt(payload, p256dh:, auth:)
        user_key = decode_point(p256dh)
        auth_secret = unbase64url(auth)

        ephemeral = OpenSSL::PKey::EC.generate(CURVE)
        shared = ecdh(ephemeral, user_key)

        # Two steps of HKDF, in the order the RFC states them: first mix the two
        # public keys into a secret (so the record cannot be opened by anyone
        # else's key), then split that into the content key and nonce with a
        # fresh random salt per message.
        salt = SecureRandom.random_bytes(16)
        info = "WebPush: info\x00".b + point_bytes(user_key) + point_bytes(ephemeral)
        ikm = OpenSSL::KDF.hkdf(shared, salt: auth_secret, info: info.b, length: 32, hash: "SHA256")
        cek = OpenSSL::KDF.hkdf(ikm, salt: salt, info: "Content-Encoding: aes128gcm\x00".b, length: 16, hash: "SHA256")
        nonce = OpenSSL::KDF.hkdf(ikm, salt: salt, info: "Content-Encoding: nonce\x00".b, length: 12, hash: "SHA256")

        cipher = OpenSSL::Cipher.new("aes-128-gcm")
        cipher.encrypt
        cipher.key = cek
        cipher.iv = nonce
        cipher.auth_data = ""
        # 0x02 is the padding delimiter of the last record: "the message stops
        # here". Without it the browser appends the remaining bytes of the
        # record to the payload.
        sealed = cipher.update(payload.to_s.b + "\x02".b) + cipher.final
        tag = cipher.auth_tag(16)

        header = salt + [ RECORD_SIZE ].pack("N") + [ POINT_BYTES ].pack("C") + point_bytes(ephemeral)
        (header + sealed + tag).b
      end

      def decode_point(text)
        bytes = unbase64url(text)
        raise ArgumentError, "p256dh is not a P-256 point" unless bytes.bytesize == POINT_BYTES

        group = OpenSSL::PKey::EC::Group.new(CURVE)
        OpenSSL::PKey::EC::Point.new(group, OpenSSL::BN.new(bytes, 2))
      end

      def ecdh(private_key, public_point)
        shared = private_key.dh_compute_key(public_point)
        # `dh_compute_key` hands back the x coordinate without its leading
        # zeros, so a secret that happens to start low would be 31 bytes — and
        # HKDF would derive different keys on each side.
        shared.rjust(32, "\x00").b
      end

      # --- delivery ------------------------------------------------------

      # POST one notification to one subscription.
      #
      # The return value is the only thing the caller needs to act on: `:gone`
      # means the browser forgot this subscription (uninstalled, permission
      # revoked, replaced), and the row should stop being asked. Anything else
      # is either fine or a problem that repeats on its own.
      def deliver(subscription:, payload:, key:, subject:, ttl: DEFAULT_TTL, timeout: 8)
        deliver_with_status(subscription: subscription, payload: payload, key: key,
                            subject: subject, ttl: ttl, timeout: timeout).first
      end

      # The same delivery, keeping the push service's own answer.
      #
      # `:ok` only ever means the service *accepted* the message — whether a
      # device then shows it is a question only the device can answer (it may be
      # offline, or its worker may decide the app is already on screen). Keeping
      # the status makes that difference visible when something looks delivered
      # but nothing appears.
      def deliver_with_status(subscription:, payload:, key:, subject:, ttl: DEFAULT_TTL, timeout: 8)
        endpoint = subscription["endpoint"].to_s
        authorization_header = authorization(key: key, endpoint: endpoint, subject: subject)
        return [ :invalid, nil ] if authorization_header.nil?

        body = encrypt(payload, p256dh: subscription["p256dh"], auth: subscription["auth"])
        uri = URI.parse(endpoint)

        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = authorization_header
        request["Content-Encoding"] = "aes128gcm"
        request["Content-Type"] = "application/octet-stream"
        request["TTL"] = ttl.to_i.to_s
        # `normal` keeps a phone quiet at night: a push service may hold it
        # until the device next wakes instead of waking it.
        request["Urgency"] = "normal"
        request.body = body
        request["Content-Length"] = body.bytesize.to_s

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: timeout, read_timeout: timeout) do |http|
          http.request(request)
        end

        code = response.code.to_i
        status = case code
        when 200, 201, 202, 204 then :ok
        when 404, 410 then :gone
        when 401, 403 then :unauthorized
        when 413 then :too_large
        when 429 then :throttled
        else :error
        end
        [ status, code ]
      rescue StandardError => e
        warn "[push] #{e.class}: #{e.message}"
        [ :error, e.class.name ]
      end
    end

    # The key pair this install signs with.
    #
    # It is generated on first use and kept beside config.yml, readable only by
    # its owner. It is not in the repository and not in the database: losing it
    # costs every subscription (the browser has the old public key baked in),
    # so it is a file worth backing up, and a file worth not committing.
    class Vapid
      SUBJECT = "mailto:rubot@localhost"

      attr_reader :path, :subject

      def initialize(path, subject: SUBJECT)
        @path = path
        @subject = subject
        @mutex = Mutex.new
        @key = nil
      end

      def key
        @mutex.synchronize { @key ||= load_or_create }
      end

      # What the page passes as `applicationServerKey` — the public half only.
      def public_key
        Push.base64url(Push.point_bytes(key))
      end

      private

      def load_or_create
        if File.file?(@path)
          data = JSON.parse(File.read(@path))
          return OpenSSL::PKey.read(data["private_key"].to_s)
        end

        generated = Push.generate_keypair
        FileUtils.mkdir_p(File.dirname(@path))
        # Written to a private temporary name and renamed into place: the
        # private scalar is the whole secret, and a group-readable file would
        # hand the ability to notify this device to every account on the
        # machine. The rename also means a reader never sees a half-written
        # JSON, and the key that ends up in the file is the one every later
        # reader adopts — including two processes that started at the same time.
        temporary = "#{@path}.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.write(temporary, JSON.pretty_generate(generated), perm: 0o600)
        File.rename(temporary, @path)
        OpenSSL::PKey.read(JSON.parse(File.read(@path))["private_key"].to_s)
      rescue JSON::ParserError, TypeError, OpenSSL::PKey::PKeyError => e
        warn "[push] vapid key unreadable (#{e.class}); subscriptions must be renewed"
        raise
      end
    end
  end
end
