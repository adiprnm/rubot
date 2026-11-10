-- A conversation the reader lifted out of the chronological list.
--
-- `pinned_at` is when it was pinned, not a boolean: the sidebar orders the
-- pinned section by it, so the newest pin is at the top and a cap of ten
-- always removes the one that has been pinned longest. NULL is "not pinned",
-- which is what every row written before this column existed is.
ALTER TABLE sessions ADD COLUMN pinned_at TEXT;

-- The pinned rows are read on every sidebar render and are a small minority of
-- the table, so a partial index keeps that lookup off a full scan without
-- paying for an entry per conversation.
CREATE INDEX IF NOT EXISTS idx_sessions_pinned ON sessions(pinned_at)
  WHERE pinned_at IS NOT NULL;
