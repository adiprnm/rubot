-- Two more things a request is made of, so two more causes can be named.
--
-- `summary` is a digest of the compaction summary. A summary being created
-- rewrites the system prompt *because of the transcript*, which is a different
-- fix from a prompt that was edited by hand — and only a separate digest can
-- tell them apart, since both move the prompt digest.
--
-- `effort` is the thinking level the request went out with. Providers do not
-- key the prompt cache on it, so it is recorded as a suspect rather than a
-- cause: when the prefix is intact, nothing was read from the cache, and the
-- effort changed between the two requests, that is the one difference left to
-- point at.
ALTER TABLE request_cache ADD COLUMN summary TEXT;
ALTER TABLE request_cache ADD COLUMN effort TEXT;
