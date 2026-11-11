-- Where a request stopped matching the one before it.
--
-- `fingerprint` is the per-block digest list of one request (see
-- Rubot::CacheProbe): the system prompt, every tool definition, every message,
-- in the order a provider hashes them. `diverged_at` is the index of the first
-- block that differs from the previous request's fingerprint, or -1 when this
-- request only appended to it.
--
-- Both columns are nullable on purpose. A record written before this migration,
-- or the first request of a session, has nothing to compare against and must
-- not read as "identical". And the fingerprint is kept for the newest request
-- only — the writer clears it from the row behind (Store#append_cache_record) —
-- because one request is all the next comparison needs, and a fingerprint is
-- ~1.5 KB.
ALTER TABLE request_cache ADD COLUMN fingerprint TEXT;
ALTER TABLE request_cache ADD COLUMN diverged_at INTEGER;
