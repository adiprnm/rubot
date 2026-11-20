# AGENTS.md — Rubot codebase guide

A guide for agents and humans working on this repository. This is not the
runtime AGENTS.md config file (the YAML-frontmatter persona format is
documented in README); it covers development conventions for the codebase.

## Stack & setup

- Ruby 4.0.x (see `.ruby-version` and `mise.toml`), almost entirely standard
  library. The only runtime gems: `webrick` (Telegram webhook), `ruby-tui`
  (from `vendor/ruby-tui`, not rubygems), `base64`, and `sqlite3`.
- Run `bundle install` before anything else.
- Entry point: `bin/rubot`. Run it with `bundle exec bin/rubot`.
- Example config lives at `config/rubot.example.yml`; the real config is at
  `~/.rubot/config.yml` — never read or write that from tests.

## Test & lint commands

```bash
bundle exec rake test              # parallel, one worker per CPU by default
JOBS=4 bundle exec rake test       # limit workers
TESTS_PER_SHARD=4 bundle exec rake test
SHARD_TIMEOUT=120 bundle exec rake test   # per-shard timeout (seconds)
bundle exec rake test_serial       # single process, for debugging
bundle exec ruby -Ilib -Itest test/test_agent.rb                    # one file
bundle exec ruby -Ilib -Itest test/test_agent.rb -n /test_name/     # one test
bundle exec rubocop                # lint (RuboCop Rails Omakase, Rails cops off)
```

- `rake test` splits tests by method into shards and runs them in parallel;
  each shard has a 120-second default timeout. If a shard TIMEOUTs, run that
  file with `test_serial` or `-n` to isolate it.
- `test/test_helper.rb` points `HOME` at a throwaway directory before
  `lib/rubot` is loaded, so tests never touch the real `~/.rubot`. Use
  `isolated_config(dir)` to build a Config in tests, never plain `Config.new`.
- Every test file is independent and builds its own temp workspace — safe to
  run alone or in parallel.

## Code conventions

- Pure Ruby, standard library first. Avoid new gems unless truly needed; if
  one is needed, add it to the Gemfile and explain why.
- One-off scripts and helpers are written in Ruby (`ruby -e '...'` or a `.rb`
  file), not Python. Node is only for existing JS pipelines in skills.
- `# frozen_string_literal: true` at the top of every Ruby file.
- Style: RuboCop Rails Omakase, but the `Rails` cop and Rails assertion cops
  are disabled (see `.rubocop.yml`) — use plain minitest `assert`/`refute`.
- File names follow the class/function they define (`agent.rb`,
  `session_actor.rb`, `test_agent.rb`). New tests: `test/test_<topic>.rb`.
- Edit files with `file_ops edit` (targeted); use `write` only for new files or
  full rewrites. Never edit in place with `sed -i` or shell redirection.
- Do not commit unless the user explicitly asks. Commit only after changes
  are confirmed good.

## Architecture (overview)

- I/O and execution are separated: **Channels** (TUI, Telegram, Web) live in
  the main Ractor and own all I/O. A **SessionActor**
  (`actors/session_actor.rb`) owns one `Agent`, one `Session`, and its tools
  per session; one session id maps to one actor, so requests to the same
  conversation are serialized by the actor's mailbox.
- **CronActor** (`actors/cron_actor.rb`) owns the scheduler and job stores;
  a single actor serves every workspace, with a store per directory.
- Cross-Ractor communication uses message passing over `Ractor::Port`
  (chunks, tool events, progress, confirm, done, subagent). Procs and mutexes
  never cross a boundary.
- **Delegation** (`tools/delegate.rb`) runs a sub agent inside the parent's
  SessionActor, on the same thread — never through `SessionPool#for`, which
  lives in the main Ractor. The sub agent gets the target persona's config and
  a `~sub-` session id. Its progress reaches channels through the `on_subagent`
  callback (Agent → SessionActor → SessionHandle → Channel). Sub agents have a
  restricted tool set (no `delegate`, `notify`, `cron`, `instagram`) and write
  an audit row to `subagent_runs` via `StoreClient`.
- File-backed state (`MEMORY.md`, session JSON) is written with `flock`.
- The SQLite connection is not Ractor-safe: `SQLite3::Database` must live in
  the main Ractor (see `Rubot::Store`) and is reached through a port /
  `StoreClient`, never opened inside a SessionActor.
- The agent can be used in-process (passing `agent:` to a channel) — this is
  what the unit tests use.

## Directory map

```
bin/                  executable + cache/benchmark scripts
lib/rubot.rb          entry point
lib/rubot/
  agent.rb            agent loop, system prompt, trimming/compaction
  session.rb          history & session state
  config.rb           YAML config loader
  provider.rb, providers/   OpenAI/Anthropic/Ollama/OpenCode
  tool.rb, tools/     tool base + implementations (shell, file_ops, web, ...)
  channel.rb, channels/     TUI, Telegram, Web (HTMX + SSE)
  actors/             SessionActor, SessionPool, CronActor
  store.rb, store/migrations/   SQLite session store + FTS + migrations
  memory*.rb          MEMORY.md, extractor, persona memory
  soul.rb, agents_file.rb, skill*.rb   identity, rules, skills
  tui/, web/          UI components (TUI widgets, ERB views, assets)
  safety_guard.rb     dangerous-command filter
test/                 minitest, one file per topic
config/               rubot.example.yml
vendor/ruby-tui       local TUI gem
```

## Workflow

- Verify changes with the relevant tests (or `rake test`) before finishing.
- When adding a SQLite migration, place it in `lib/rubot/store/migrations/`
  with the next sequence number; never edit a migration already in use. Update
  the version list and expected columns in `test/test_store_migrations.rb`.
- Adding a tool means registering it in `tools/registry.rb`, requiring it from
  `lib/rubot.rb`, and updating the tool-count assertions in `test/test_tools.rb`
  and `test/test_providers.rb`. If the tool changes the system prompt, add its
  rule to `shipped_rules` so the cache epoch moves.
- Changes to the prompt/system prompt can affect caching — see
  `test/test_payload_stability.rb`.
- Feature documentation lives in `README.md`; the active task list is in
  `TODO.md`.
