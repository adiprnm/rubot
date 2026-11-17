-- Instagram lives beside the install's other settings, not in config.yml:
-- the app credentials are typed into the settings form, and the token is
-- minted by the OAuth callback. One account per install is enough — the web
-- channel is a single reader, and a second account would only make "who am I
-- posting as?" a question nobody asked for.
CREATE TABLE IF NOT EXISTS instagram_accounts (
  id             INTEGER PRIMARY KEY CHECK (id = 1),
  access_token   TEXT NOT NULL,
  ig_user_id     TEXT NOT NULL,
  username       TEXT,
  account_type   TEXT,
  token_type     TEXT,
  expires_at     TEXT,
  connected_at   TEXT NOT NULL,
  updated_at     TEXT NOT NULL
);

-- A scheduled post is a row, not a cron agent-turn: publishing is a fixed
-- Graph API call, and asking a model to remember the caption at 07:00 would
-- put a prompt between the reader and their own post.
CREATE TABLE IF NOT EXISTS instagram_posts (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  caption      TEXT NOT NULL DEFAULT '',
  image_url    TEXT NOT NULL,
  scheduled_at TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending',
  ig_media_id  TEXT,
  error        TEXT,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_instagram_posts_due
  ON instagram_posts(status, scheduled_at);
