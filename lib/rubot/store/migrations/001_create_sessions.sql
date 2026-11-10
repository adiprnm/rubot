-- The archive itself.
--
-- Messages are append-only: nothing in Rubot::Store deletes a row, so a session
-- trimmed to fit the model's context window keeps its history here. idx is the
-- position in the transcript and UNIQUE(session_id, idx) is what makes a
-- re-saved turn a no-op.
CREATE TABLE IF NOT EXISTS sessions(
  id         TEXT PRIMARY KEY,
  title      TEXT NOT NULL DEFAULT '',
  created_at TEXT,
  updated_at TEXT,
  cwd        TEXT,
  msg_count  INTEGER NOT NULL DEFAULT 0,
  bytes      INTEGER NOT NULL DEFAULT 0
);

-- No `content` column: it is recoverable from `payload`, and keeping both cost
-- 4 MB over 7k messages. `text` is the one derived copy worth paying for —
-- search and snippets read it without parsing JSON.
CREATE TABLE IF NOT EXISTS messages(
  id         INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL,
  idx        INTEGER NOT NULL,
  role       TEXT NOT NULL,
  text       TEXT NOT NULL DEFAULT '',
  created_at TEXT,
  payload    TEXT NOT NULL DEFAULT '',
  UNIQUE(session_id, idx)
);

-- The UNIQUE constraint already indexes (session_id, idx); a second index on
-- the same columns would only cost disk and write time.
CREATE INDEX IF NOT EXISTS idx_sessions_updated ON sessions(updated_at);
