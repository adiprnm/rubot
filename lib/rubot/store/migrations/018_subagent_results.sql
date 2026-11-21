-- The answer a delegated run came back with, and whether it has been read.
--
-- A background run finishes after the turn that asked for it is over, so its
-- answer cannot be handed to the model there and then. It is written here
-- instead: the row already exists (017), the model reads it through the
-- `subagent_results` tool when it wants it, and `reported_at` is what stops the
-- same answer being handed over twice.
--
-- Until now `error` was the only thing a finished run could carry, which made
-- a successful run an empty row.
ALTER TABLE subagent_runs ADD COLUMN result TEXT;
ALTER TABLE subagent_runs ADD COLUMN reported_at TEXT;

CREATE INDEX idx_subagent_runs_pending
  ON subagent_runs(parent_session, reported_at);
