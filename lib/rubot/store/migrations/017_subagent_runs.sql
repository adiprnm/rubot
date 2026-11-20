-- An audit trail of delegated work.
--
-- A sub agent runs inside its parent's session actor and writes into its own
-- conversation, so its turns are already in the archive. What was missing is
-- the link: which parent asked for it, which persona answered, and whether it
-- finished. Without that, a chain of delegations is a handful of unrelated
-- `~sub-` sessions nobody can piece back together.
--
-- One row per run, keyed by the run id the agent generates. `status` moves from
-- running to done or failed; the timestamps say when each happened. `task` is
-- kept so the audit reads as "asked this, got that" without opening the sub
-- session. The index serves the one query that matters: the runs of a parent,
-- newest first.
CREATE TABLE subagent_runs(
  run_id         TEXT PRIMARY KEY,
  parent_session TEXT NOT NULL,
  sub_session    TEXT,
  agent_slug     TEXT NOT NULL,
  task           TEXT,
  model          TEXT,
  status         TEXT NOT NULL,
  error          TEXT,
  started_at     TEXT NOT NULL,
  finished_at    TEXT
);

CREATE INDEX idx_subagent_runs_parent ON subagent_runs(parent_session, started_at);
