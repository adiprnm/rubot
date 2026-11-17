-- One token per Instagram account, kept once for the whole install. What a
-- persona owns is a mapping of which accounts it may use and which one is its
-- default. Connecting through Meta is then needed only once: another persona
-- links the existing account from its own card, no second OAuth round trip.
ALTER TABLE instagram_accounts RENAME TO instagram_accounts_old;

CREATE TABLE instagram_accounts (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  access_token   TEXT NOT NULL,
  ig_user_id     TEXT NOT NULL UNIQUE,
  username       TEXT,
  account_type   TEXT,
  token_type     TEXT,
  expires_at     TEXT,
  connected_at   TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

-- Several personas may have linked the same IG account, each with its own
-- copy of the token. Keep one row per ig_user_id; the lowest id survives so
-- scheduled posts pointing at it can be remapped below.
INSERT INTO instagram_accounts
  (id, access_token, ig_user_id, username, account_type, token_type, expires_at, connected_at, updated_at)
SELECT MIN(id), access_token, ig_user_id, username, account_type, token_type, expires_at,
       MIN(connected_at), MAX(updated_at)
FROM instagram_accounts_old
GROUP BY ig_user_id;

-- A post was scheduled through one persona's copy of the account. Point it at
-- the surviving global row instead, or the ticker would publish as a row that
-- no longer exists. Rows whose account is gone are left untouched.
UPDATE instagram_posts
SET account_id = (
  SELECT MIN(o2.id) FROM instagram_accounts_old o2
  WHERE o2.ig_user_id = (
    SELECT o.ig_user_id FROM instagram_accounts_old o WHERE o.id = instagram_posts.account_id
  )
)
WHERE account_id IN (SELECT id FROM instagram_accounts_old);

-- The per-persona mapping. The lowest-id account a persona had becomes its
-- default, matching the old is_default flag.
CREATE TABLE instagram_persona_accounts (
  persona    TEXT NOT NULL,
  account_id INTEGER NOT NULL REFERENCES instagram_accounts(id),
  is_default INTEGER NOT NULL DEFAULT 0,
  linked_at  TEXT NOT NULL,
  PRIMARY KEY (persona, account_id)
);

INSERT INTO instagram_persona_accounts (persona, account_id, is_default, linked_at)
SELECT o.persona, g.id,
       CASE WHEN o.id = (SELECT MIN(o2.id) FROM instagram_accounts_old o2 WHERE o2.persona = o.persona)
            THEN 1 ELSE 0 END,
       o.connected_at
FROM (SELECT persona, ig_user_id, MIN(id) AS id, MIN(connected_at) AS connected_at
      FROM instagram_accounts_old GROUP BY persona, ig_user_id) o
JOIN instagram_accounts g ON g.ig_user_id = o.ig_user_id;

DROP TABLE instagram_accounts_old;

CREATE INDEX IF NOT EXISTS idx_instagram_persona_accounts
  ON instagram_persona_accounts(persona, is_default, account_id);
