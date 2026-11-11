-- One row per provider request, for answering "why did the cache miss?".
--
-- The session meta already keeps `cache_history`: the last twelve hit rates as
-- bare numbers. A number says a request missed; it cannot say why. These rows
-- keep what the request was made of — a digest of the pinned system prompt, a
-- digest of the tool catalog, how many blocks the provider hashed, and how many
-- turns the live window carried. Two requests with the same digests share a
-- prefix; the first request whose digest differs is where the prefix moved.
--
-- `cached_tokens` and `cache_creation_tokens` are the provider's own answer for
-- that request (Anthropic reports both; OpenAI-compatible endpoints usually
-- only the read side), which is what a hit rate has to be computed from.
--
-- Bounded per session by the writer (Store::CACHE_RECORDS_KEPT): a diagnosis
-- window, not an archive, so it must not grow with the conversation.
CREATE TABLE IF NOT EXISTS request_cache(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  provider TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT '',
  prompt_tokens INTEGER NOT NULL DEFAULT 0,
  cached_tokens INTEGER NOT NULL DEFAULT 0,
  cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
  epoch TEXT NOT NULL DEFAULT '',
  tools TEXT NOT NULL DEFAULT '',
  blocks INTEGER NOT NULL DEFAULT 0,
  turns INTEGER NOT NULL DEFAULT 0,
  auxiliary INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS request_cache_session ON request_cache(session_id, id);
