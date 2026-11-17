-- Multiple Instagram accounts per install. The old table was pinned to a
-- single row (CHECK (id = 1)); an install can now manage more than one page,
-- so accounts get real ids and posts remember which account owns them.
--
-- SQLite cannot ALTER a CHECK constraint, so the old table is set aside, the
-- real `instagram_accounts` is created with its final shape, the one existing
-- account (if any) is carried over as the default, then the old copy is dropped.
ALTER TABLE instagram_accounts RENAME TO instagram_accounts_old;

CREATE TABLE instagram_accounts (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  access_token   TEXT NOT NULL,
  ig_user_id     TEXT NOT NULL UNIQUE,
  username       TEXT,
  account_type   TEXT,
  token_type     TEXT,
  expires_at     TEXT,
  is_default     INTEGER NOT NULL DEFAULT 0,
  connected_at   TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

INSERT INTO instagram_accounts
  (access_token, ig_user_id, username, account_type, token_type, expires_at, is_default, connected_at, updated_at)
SELECT access_token, ig_user_id, username, account_type, token_type, expires_at, 1, connected_at, updated_at
FROM instagram_accounts_old;

DROP TABLE instagram_accounts_old;

-- Posts belong to an account. Existing posts are assigned to the one account
-- that was carried over (id 1); a fresh install has none to migrate.
ALTER TABLE instagram_posts ADD COLUMN account_id INTEGER NOT NULL DEFAULT 1;
CREATE INDEX IF NOT EXISTS idx_instagram_posts_account
  ON instagram_posts(account_id, status, scheduled_at);

-- OAuth state used to be a single setting, so connecting a second account
-- burned the first one's handshake. Each state now carries the account it is
-- linking (label is filled in from the settings form before the redirect).
CREATE TABLE IF NOT EXISTS instagram_oauth_states (
  state       TEXT PRIMARY KEY,
  issued_at   INTEGER NOT NULL,
  label       TEXT NOT NULL DEFAULT ''
);
