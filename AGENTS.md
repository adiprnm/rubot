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
- A shard carries up to 20 tests (`TESTS_PER_SHARD`, default 20). Every shard
  is a process, so more shards means more startup: with 68 test files this is
  what keeps the suite near 22s. If the suite creeps past 25s, raise it.
- `test/test_helper.rb` points `HOME` at a throwaway directory before
  `lib/rubot` is loaded, so tests never touch the real `~/.rubot`. Use
  `isolated_config(dir)` to build a Config in tests, never plain `Config.new`.
- Every test file is independent and builds its own temp workspace — safe to
  run alone or in parallel. Helpers, stubs and fake views shared by a group of
  files live in `test/support/` (`web_channel_support.rb`, `tui_support.rb`)
  and are mixed in with `include`; `rake test` only picks up `test/test_*.rb`,
  so a support file is never run as a test.

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
- A test drives a public seam, never `send`. When a test needs a method that
  is private, make that method public in the class with one documented block
  naming it (`public :pump, :apply_event, ...` — see `Telegram` and `TUI`) and
  say in the comment why it is a seam; anything not named there stays private.
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
  (chunks, tool events, progress, confirm, done, subagent, delegate). Procs and
  mutexes never cross a boundary.
- **Delegation** (`tools/delegate.rb`) has two shapes. A channel that sets
  `on_delegate` gets the request handed over (`Agent#spawn_subagent` returns
  "started" at once) and runs it in a session actor of its own, so the
  conversation is never held by work it delegated. The web channel is the one
  that does this (`Web#start_delegate` → `SessionPool#delegate`), tracking the
  runs in `Rubot::Web::SubagentJobs` for the footer and writing the answer to
  the archive, where the `subagent_results` tool reads it once. The footer's
  sheet is the only live view of a run (the band above the composer says the
  turn is working and nothing more), and the idle stream redraws it whole on
  every (re)connect, so one missed event cannot leave a row stuck on the mark
  it wore while it worked. Three seconds after the last run lands the row goes,
  and the channel schedules that itself (`Web#hide_subagents_later`): nothing
  fires when a finished batch runs out of time, so waiting for the next event
  would leave the tick there until something unrelated moved. When the last run
  of a batch lands, the answers are
  handed back to the conversation as a turn of their own
  (`Web#report_subagents_when_done`), so nobody has to remember to call
  `subagent_results`. That turn is delivered as background context
  (`Agent#process_background`): the answers reach the model, and only its reply
  joins the transcript, so the reader never sees a message in their own voice
  that they did not write. The tool stays for pulling an answer early, and the
  store records what it has already given. A channel that
  does not set it keeps the original synchronous path: the sub agent runs in the
  parent's SessionActor and returns its answer as the tool result. Either way
  the sub agent gets the target persona's config, a `~sub-` session id, a
  restricted tool set (no `delegate`, `subagent_results`, `notify`, `cron`,
  `instagram`) and an audit row in `subagent_runs` written through
  `StoreClient`.
- Channels are split by domain, and a component is a module included into the
  channel, not an object the channel owns: `Telegram` mixes in transport,
  attachments, status, commands, messaging, scheduling, persona and the wizard,
  and `Web` mixes in the router, auth, the route modules, turns, media and the
  views (all under `channels/web/` and `web/`). A component reaches the
  channel's state through `self` and never names the channel class, which is
  what keeps each one small enough to read and to test.
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
  agent.rb            turn entry, cancellation/steering, session wiring
  agent/              SystemPrompt, TurnLoop, Turn, tool execution,
                      tool wiring, message building, prompt pinning,
                      model/preset precedence, usage accounting,
                      background tasks, delegation, callbacks
  session.rb          history & session state
  archive.rb          the one resolver for the open SQLite archive
  config.rb           YAML config loader
  config/             model presets, provider settings
  provider.rb, providers/   OpenAI/Anthropic/Ollama/OpenCode
  tool.rb, tools/     tool base + implementations (shell, file_ops, web, ...)
  channel.rb, channels/     TUI, Telegram, Web (HTMX + SSE)
    channels/telegram/      transport, attachments, status, commands,
                            messaging, scheduling, persona, persona_wizard
  actors/             SessionActor, SessionPool, CronActor
  store.rb            archive: sessions, messages, transcripts
  store/              row groups (search, settings, push subscriptions,
                      delegated runs) + migrations/
  memory*.rb          MEMORY.md, extractor, persona memory
  soul.rb, agents_file.rb, skill*.rb   identity, rules, skills
  formatting.rb       duration/text shaping shared by every channel
  persona_store.rb    persona registry; PersonaStore.from_config builds one
  tui/                TUI widgets + the class's own modules (commands, events,
                      bindings); web/  router, auth, routes, turns, views,
                      markdown (web/format.rb)
  safety_guard.rb     dangerous-command filter
test/                 minitest, one file per topic
test/support/         helpers and fakes shared by a group of test files
config/               rubot.example.yml
vendor/ruby-tui       local TUI gem
```

## Where the responsibilities sit

- A class that grew its own modules keeps one object: the modules are
  `include`d, so a caller and a test still see `Agent#build_messages`,
  `Store#search`, `Config#provider_settings`. When moving a method into one of
  them, move it verbatim (comments included) and keep its visibility; a stub
  seam used by tests (`Agent#system_prompt`, `Telegram#truncate`) is a real
  method, not a call site to inline.
- Personas are read through `PersonaStore.from_config(config, dir: ...)`; do not
  spell out the four constructor arguments in a new channel.
- The open archive is read through `Rubot::Archive.current`, never through
  `Session.store` directly. `Session.store` remains the variable behind it for
  the JSON fallback path.
- Duration labels, text truncation and SSE parsing each have one implementation
  (`Formatting`, `Formatting.truncate`, `Rubot::Sse`); a channel that needs a
  seam over one keeps a one-line wrapper rather than a second copy.

## Workflow

- Verify changes with the relevant tests (or `rake test`) before finishing.
- When adding a SQLite migration, place it in `lib/rubot/store/migrations/`
  with the next sequence number; never edit a migration already in use. Update
  the version list and expected columns in `test/test_store_migrations.rb`.
- Adding a tool means registering it in `tools/registry.rb`, requiring it from
  `lib/rubot.rb`, and updating the tool-count assertions in `test/test_tools.rb`
  and `test/test_providers.rb`. If the tool changes the system prompt, add its
  rule to `SystemPrompt#rules` so the cache epoch moves.
- Changes to the prompt/system prompt can affect caching — see
  `test/test_payload_stability.rb`.
- Feature documentation lives in `README.md`; the active task list is in
  `TODO.md`.
