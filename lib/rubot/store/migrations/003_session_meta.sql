-- Session metadata and where the live transcript begins.
--
-- `meta` is the session state that is not a message: summary, usage, the pinned
-- system prompt and its epoch, forced skill, model override, the memory backlog,
-- the cache-history ring. It has to survive a restart byte for byte — the epoch
-- is built from the summary and the task, so losing either one rebuilds the
-- whole system prompt and makes the next request a cold cache.
--
-- `messages_start` is the index where the live transcript begins. The archive
-- grows an row for every message and never deletes, but compaction and the hard
-- trim drop messages from the front of the *live* window. Recording where that
-- window starts lets a reload return exactly what the old JSON file held, while
-- the archive keeps the rest for search.
ALTER TABLE sessions ADD COLUMN meta TEXT NOT NULL DEFAULT '{}';
ALTER TABLE sessions ADD COLUMN messages_start INTEGER NOT NULL DEFAULT 0;
