-- Instagram accounts belong to a persona, not to the install. Two personas on
-- the same install can each connect their own set of accounts without seeing
-- or publishing as each other's.
--
-- SQLite cannot ALTER a CHECK or add a column to a UNIQUE constraint, so the
-- table is rebuilt: the old rows are carried over with an empty persona (they
-- predate scoping and stay reachable as the "unscoped" set), and the unique key
-- becomes (persona, ig_user_id) so the same IG account can be linked under two
-- personas without one overwriting the other.
ALTER TABLE instagram_accounts RENAME TO instagram_accounts_old;

CREATE TABLE instagram_accounts (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  persona        TEXT NOT NULL DEFAULT '',
  access_token   TEXT NOT NULL,
  ig_user_id     TEXT NOT NULL,
  username       TEXT,
  account_type   TEXT,
  token_type     TEXT,
  expires_at     TEXT,
  is_default     INTEGER NOT NULL DEFAULT 0,
  connected_at   TEXT NOT NULL,
  updated_at     TEXT NOT NULL,
  UNIQUE (persona, ig_user_id)
);

-- Existing accounts were connected from the default persona's conversations,
-- so they are carried over under that slug rather than left in an unscoped set
-- the UI would never show. The install's default is "rubot" (Web::DEFAULT_SLUG).
INSERT INTO instagram_accounts
  (persona, access_token, ig_user_id, username, account_type, token_type, expires_at, is_default, connected_at, updated_at)
SELECT 'rubot', access_token, ig_user_id, username, account_type, token_type, expires_at, is_default, connected_at, updated_at
FROM instagram_accounts_old;

DROP TABLE instagram_accounts_old;

CREATE INDEX IF NOT EXISTS idx_instagram_accounts_persona
  ON instagram_accounts(persona, is_default, id);

-- Posts belong to an account, which now carries its persona implicitly. No
-- column change is needed here: account_id still points at the same row.

-- The OAuth callback arrives from Meta's domain with no session cookie, so the
-- persona that started the handshake has to travel in the state row. Without
-- it the callback would save the token into the wrong persona's set.
ALTER TABLE instagram_oauth_states ADD COLUMN persona TEXT NOT NULL DEFAULT '';
UPDATE instagram_oauth_states SET persona = 'rubot' WHERE persona = '';
