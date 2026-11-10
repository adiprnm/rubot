-- A browser that agreed to be woken when there is something to say.
--
-- The three values are the whole of a subscription: where to send it, and the
-- two keys the payload is sealed to. They come from the browser, never from
-- us, and they are worthless without the VAPID key that signs the request
-- (kept in vapid.json, not here).
--
-- The endpoint is the identity: a browser that subscribes again on the same
-- device hands back the same long URL, so inserting on it updates the keys
-- instead of piling up a second row that would notify the phone twice.
CREATE TABLE IF NOT EXISTS push_subscriptions (
  endpoint      TEXT PRIMARY KEY,
  p256dh        TEXT NOT NULL,
  auth          TEXT NOT NULL,
  -- Which persona the reader subscribed for. NULL means "every persona": the
  -- toggle in the drawer is per device, not per conversation.
  persona       TEXT,
  created_at    TEXT NOT NULL,
  last_seen_at  TEXT
);

-- Notifications are looked up by persona on every fire, and the table stays
-- small enough that this index is mostly bookkeeping — but it is the only
-- column ever used in a WHERE clause besides the primary key.
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_persona ON push_subscriptions(persona);
