# frozen_string_literal: true

module Rubot
  class Store
    # The push subscriptions a persona sends to, and nothing about sending.
    #
    # A subscription is per device, carries its own keys, and is dropped when
    # the service says it is gone; the store only keeps the rows.
    #
    # Moved as it was, comments included.
    module PushSubscriptions
      # --- push subscriptions -------------------------------------------
      #
      # A device that agreed to be woken. `persona` nil means every persona: the
      # toggle lives in the device's drawer, not in a conversation.
      #
      # Subscribing twice on the same browser is normal — the permission is
      # granted once, and the page asks again on every load to refresh keys a
      # browser may have rotated. The endpoint is the key, so that is an update
      # rather than a second row that would deliver the notification twice.
      def add_push_subscription(endpoint:, p256dh:, auth:, persona: nil)
        url = text_id(endpoint)
        return false if url.empty? || p256dh.to_s.empty? || auth.to_s.empty?

        now = Time.now.utc.iso8601
        @db.execute(<<~SQL, [ url, p256dh.to_s, auth.to_s, persona&.to_s, now, now ])
          INSERT INTO push_subscriptions(endpoint, p256dh, auth, persona, created_at, last_seen_at)
          VALUES(?, ?, ?, ?, ?, ?)
          ON CONFLICT(endpoint) DO UPDATE SET
            p256dh = excluded.p256dh,
            auth = excluded.auth,
            persona = excluded.persona,
            last_seen_at = excluded.last_seen_at
        SQL
        true
      end

      # Every device worth trying for this persona: its own subscriptions plus
      # the ones that never chose a persona.
      def push_subscriptions(persona = nil)
        rows = if persona.to_s.empty?
          @db.execute("SELECT endpoint, p256dh, auth, persona FROM push_subscriptions")
        else
          @db.execute(
            "SELECT endpoint, p256dh, auth, persona FROM push_subscriptions WHERE persona IS NULL OR persona = ?",
            [ persona.to_s ]
          )
        end

        rows.map do |(endpoint, p256dh, auth, who)|
          { "endpoint" => text_id(endpoint), "p256dh" => p256dh.to_s, "auth" => auth.to_s, "persona" => who }
        end
      end

      # A push service that answered 404/410 will never accept this endpoint
      # again: the browser uninstalled the app or dropped the permission. Keeping
      # the row would mean a dead request on every notification.
      def drop_push_subscription(endpoint)
        url = text_id(endpoint)
        return false if url.empty?

        @db.execute("DELETE FROM push_subscriptions WHERE endpoint = ?", [ url ])
        @db.changes.positive?
      end
    end
  end
end
