# frozen_string_literal: true

module Rubot
  module Web
    module Routes
      # The notification endpoints, and the notifier they hand the work to.
      #
      # A route module: it is included into the channel, so the gate it relies
      # on (`same_origin?`, `cross_site`), the form helpers and the page helpers
      # are the channel's own methods. `Push` in this namespace is this module,
      # not the protocol, which is why the protocol classes are named by their
      # own names below.
      module Push
        private

        # The key pair that signs a notification request. Beside config.yml,
        # because it is this install's identity to the push services and
        # outlives every conversation; never in the repository, because anyone
        # holding it could notify the devices that subscribed here.
        def vapid
          @vapid_mutex.synchronize { @vapid ||= Vapid.new(vapid_path, subject: @vapid_subject) }
        end

        def vapid_path
          dir = @app_config ? @app_config.catalog_dir : File.expand_path("~/.rubot")
          File.join(dir, "vapid.json")
        end

        # What the page needs before it may subscribe: the public half only.
        def push_public_key(res)
          json(res, 200, { "key" => vapid.public_key, "subject" => @vapid_subject })
        rescue StandardError => e
          warn "[web] push key: #{e.class}: #{e.message}"
          json(res, 500, { "error" => "key unavailable" })
        end

        # `pushManager.subscribe` hands over three strings and no identity: the
        # endpoint is what identifies the device, so subscribing again is an
        # update of the keys, not a second device.
        #
        # The subscription belongs to the device, not to the conversation it was
        # made in — the browser keeps exactly one per registration, so a row
        # tagged with a persona would make the drawer say "aktif" in every other
        # persona while their notifications silently went nowhere. Hence a null
        # persona, which means "all of them".
        def push_subscribe(req, res)
          return cross_site(res) unless same_origin?(req)

          endpoint = form(req, "endpoint")
          p256dh = form(req, "p256dh")
          auth = form(req, "auth")
          return bad_request(res) if endpoint.empty? || p256dh.empty? || auth.empty?

          unless store = Session.store
            json(res, 503, { "error" => "archive unavailable" })
            return
          end

          store.add_push_subscription(endpoint: endpoint, p256dh: p256dh, auth: auth, persona: nil)
          json(res, 200, { "ok" => true })
        end

        def push_unsubscribe(req, res)
          return cross_site(res) unless same_origin?(req)

          endpoint = form(req, "endpoint")
          return bad_request(res) if endpoint.empty?

          Session.store&.drop_push_subscription(endpoint)
          json(res, 200, { "ok" => true })
        end

        # A notification now, to the device that asked. The drawer's button is
        # how a reader finds out whether the permission, the keys and the push
        # service all work — better than waiting for a reminder hours later.
        def push_test(req, res)
          return cross_site(res) unless same_origin?(req)

          slug = form(req, "persona")
          slug = default_slug unless !slug.empty? && known_slug?(slug)

          result = notify_push(slug,
                               title: persona_title(slug),
                               body: "Notifikasi percobaan. Kalau ini muncul, semuanya sudah tersambung.",
                               url: session_url(session_id(slug)),
                               sync: true,
                               # The page that presses this button is on screen,
                               # and the worker's "the reader is already looking"
                               # rule would swallow the very notification that is
                               # meant to prove the path works.
                               force: true)
          json(res, 200, result)
        end

        # Tell a persona's devices that something arrived.
        #
        # Delivering means one HTTPS round trip per device to a push service, so
        # it never happens on the caller's thread: a turn or a cron fire must not
        # wait on Apple's or Google's edge. The exception is the test button,
        # which exists precisely to report the result. The sending itself lives
        # in `Notifier`, because the same job has to be possible from the command
        # line — this method is the channel's doorway to it.
        def notify_push(slug, title:, body:, url:, sync: false, force: false)
          notifier = push_notifier
          return { "sent" => 0, "reason" => "no archive" } unless notifier

          if sync
            notifier.deliver(slug, title: title, body: body, url: url, force: force)
          else
            notifier.notify(slug, title: title, body: body, url: url, force: force)
          end
        end

        # Built per call rather than memoised: the archive behind `Session.store`
        # is a setting tests swap between one call and the next, and a notifier
        # holding the old one would answer from a stale list of devices.
        def push_notifier
          store = Session.store
          store && Notifier.new(store: store, vapid: vapid, subject: @vapid_subject,
                                urgency: @push_urgency)
        end
      end
    end
  end
end
