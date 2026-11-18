# 🤖 Rubot — AI Assistant in Ruby

> A lightweight, terminal-based AI assistant written in pure Ruby.

Rubot connects to LLM providers (OpenAI, Anthropic, Ollama, or any OpenAI-compatible API) and executes tool calls using only Ruby's standard library. It runs as a terminal REPL, a Telegram bot, or a browser UI.

## Features

- 🪶 **Almost zero dependencies** — Ruby 4 standard library; WEBrick only for Telegram webhook mode
- ⚡ **Ractor-powered sessions** — one actor per conversation, no shared mutable agent state
- 🔌 **Multiple providers** — OpenAI, Anthropic, Ollama, or any OpenAI-compatible API
- 🛠️ **Built-in tools** — shell, file operations, search, web fetch, memory, cron, file delivery, notifications, Instagram
- 💬 **Interactive TUI** — streaming, history, tab completion, multiline input, slash commands
- 📡 **Multi-channel** — terminal, Telegram, and a browser UI (HTMX + SSE, no build step)
- 🗃️ **SQLite session archive** — full-text search across past conversations, with backup/export tooling
- 🧬 **Personas** — per-topic or per-browser persona with its own model, prompt, soul, and memory
- 🗜️ **Context compaction** — automatic or `/compact`, with a lean request history
- 🧠 **Persistent memory** — global and per-project/persona, with batched extraction and post-answer learning
- ⏰ **Cron scheduling** — reminders, recurring tasks, and timed alerts
- 🔒 **Safety guard** — blocks dangerous commands before execution
- 🎭 **Skills** — pluggable `SKILL.md` instructions in the workspace

## Requirements

- Ruby 4.0+ (pinned via `.ruby-version` and `mise.toml`)
- `bundle install` only for WEBrick (webhook mode) and test gems

```bash
mise install
mise exec -- ruby -v   # 4.0.9
```

## Installation

```bash
git clone https://github.com/adipurnm/rubot.git
cd rubot
export PATH="$PWD/bin:$PATH"   # or add to ~/.bashrc
```

Or run directly: `ruby bin/rubot --help`

## Quick Start

```bash
rubot init                 # create ~/.rubot/ with config, workspace, and default files
vim ~/.rubot/config.yml    # or: export RUBOT_API_KEY="sk-..."
rubot check                # validate config and channel connections
rubot                      # interactive mode
```

Common run modes:

```bash
rubot tui                                          # terminal UI only
rubot -m "What is Ruby?"                           # single message
rubot -p ollama -M llama3 -m "Hello!"              # local model, no API key
rubot -p anthropic -M claude-sonnet-4-20250514 -m "Hello!"
rubot -d -m "Test"                                 # debug mode
rubot -n -m "Just chat"                            # disable tools
rubot -C telegram                                  # Telegram channel
```

### CLI Options

| Option | Description |
|--------|-------------|
| `-m, --message MESSAGE` | Send a single message (non-interactive) |
| `-s, --session SESSION` | Session ID (default: default) |
| `-p, --provider PROVIDER` | Provider: openai, anthropic, ollama |
| `-M, --model MODEL` | Model name to use |
| `-c, --config PATH` | Path to config file |
| `-d, --debug` | Enable debug output |
| `-n, --no-tools` | Disable tools |
| `--no-stream` | Disable streaming output |
| `-e, --env-file PATH` | Load environment variables from a file |
| `-C, --channel CHANNEL` | Channel: tui, telegram (default: configured channels) |
| `-v, --version` | Show version |
| `-h, --help` | Show help |

### Subcommands

| Subcommand | Description |
|------------|-------------|
| `rubot init` | Initialize config, workspace, and default files |
| `rubot check` | Validate config and test channel connections |
| `rubot tui` (`repl`, `chat`) | Run the terminal UI only, skipping configured channels |
| `rubot web` | Run the browser UI on `http://127.0.0.1:4567` |
| `rubot store <op>` | Maintain the SQLite session archive (see below) |

Sessions are archived in a SQLite database (`sessions.db` next to `config.yml`) with a full-text index over past conversations. The `rubot store` subcommand maintains it:

```bash
rubot store backup [path]     # back up the database (WAL-aware)
rubot store export [dir]      # export sessions as JSON
rubot store optimize          # run housekeeping (FTS merge, etc.)
rubot store counts            # show row counts
rubot store search <query>    # full-text search across messages
rubot store reindex           # rebuild the full-text index
```

## Configuration

Config lives at `~/.rubot/config.yml` (override with `RUBOT_CONFIG`).

```yaml
agents:
  defaults:
    workspace: ~/.rubot/workspace
    name: gpt-4o-mini
    model_preset: primary
    max_tokens: 4096
    temperature: 0.3
    system_prompt: "You are Rubot, a helpful AI assistant."
    max_rounds: 120
    compaction:
      auto: true
      threshold_percent: 60
      threshold_tokens: 120000
      keep_recent_messages: 40
    memory:
      extract_every: 3
      consolidate: true

model_presets:
  primary:
    model: opencode-go
    max_tokens: 4096
    temperature: 0.3
  fast:
    model: deepseek-v4.1-flash
    temperature: 0.2

models:
  - name: gpt-4o-mini
    model: openai/gpt-4o-mini
    api_key: sk-your-key-here
    api_base: https://api.openai.com/v1
  - name: llama3
    model: ollama/llama3
    api_base: http://localhost:11434

tools:
  shell_exec: { enabled: true }
  file_ops:   { enabled: true }
  search:     { enabled: true }
  web_fetch:  { enabled: true }
```

Key points:

- **Model presets** name a complete model configuration. New sessions use the primary preset; `/model <preset>` switches the current session only.
- **`max_rounds`** caps the agent loop rounds per user message (default 120). `max_tool_iterations` is the old name, still accepted.
- **Compaction** summarizes older turns when the estimated context reaches `threshold_percent` (or `threshold_tokens`, whichever is lower). `auto: false` disables it; `/compact` runs it manually.
- **Memory** extraction is batched after the answer (`extract_every`, `0` disables) and consolidated to keep the file bounded. Overflow goes to `MEMORY_ARCHIVE.md`, which is never sent to the model.
- Pricing and context windows come from [models.dev](https://models.dev/api.json), cached in `model_pricing.json` for 24 hours. `/context` shows usage, cache hit rate, and estimated cost; `/usage` shows the OpenCode Go allowance.

### Providers

| Provider | Model Prefix | API Key Env Var | Notes |
|----------|-------------|-----------------|-------|
| OpenAI | `openai/` | `RUBOT_API_KEY`, `OPENAI_API_KEY` | Default |
| Anthropic | `anthropic/` | `ANTHROPIC_API_KEY` | |
| Ollama | `ollama/` | — | Local, no key needed |
| Any OpenAI-compatible | `openai/` | Set `api_base` | Groq, DeepSeek, LM Studio, etc. |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `RUBOT_API_KEY` | API key (overrides config) |
| `RUBOT_API_BASE` | API base URL (overrides config) |
| `RUBOT_CONFIG` | Path to config file |
| `RUBOT_DEBUG` | Set to `1` for debug mode |
| `OPENAI_API_KEY` / `OPENAI_API_BASE` | Fallback for OpenAI key/base URL |
| `ANTHROPIC_API_KEY` | Anthropic API key |
| `OLLAMA_HOST` | Ollama host (default: http://localhost:11434) |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |

Rubot also loads `.env` files from the current directory and `~/.rubot/` on startup, or an explicit file with `-e`. Later files override earlier ones.

## Channels

Configure channels under `channels:` in `config.yml`; several can run at once.

| Channel | Description |
|---------|-------------|
| `repl` | Terminal REPL (default when no channels are configured) |
| `telegram` | Telegram bot via long polling or webhook |
| `web` | Browser UI served over HTTP, streamed with Server-Sent Events |

### Telegram

Create a bot with [@BotFather](https://t.me/BotFather), then:

```yaml
channels:
  telegram:
    token: "123456:ABC-DEF..."   # or TELEGRAM_BOT_TOKEN
    allowed_user_ids: [123456789] # optional: restrict who can talk to the bot
    typing_indicator: true
    narration: true
    attachments: true
```

Run with `rubot -C telegram`. For production, set `webhook: true` with `webhook_url` and `webhook_port`.

Telegram commands: `/model`, `/models`, `/preset`, `/context`, `/usage`, `/stop`, `/compact`, `/persona`, `/cancel`. A plain message sent while a turn is running steers it instead of queueing.

Forum topics can each have their own persona (model + system prompt) via `/persona`. Personas are stored in `personas.json` next to `config.yml`, keyed by `"<chat_id>:<thread_id>"`.

### Web UI

```bash
rubot web            # http://127.0.0.1:4567
```

```yaml
channels:
  web:
    enabled: true
    host: 127.0.0.1
    port: 4567
    persona: rubot
```

The browser posts a message; Ruby streams the turn over SSE. No frontend build step — `htmx`, `htmx-ext-sse`, and `alpinejs` are vendored under `vendor/web/`, templates are ERB, and a small amount of JavaScript wires the composer. Files sent with `send_files` appear in the thread as a strip of pictures or document cards.

The web channel runs shell commands through the same agent as every other channel, so it binds to loopback by default. Reach it from another device over a private network (Tailscale, SSH tunnel) rather than exposing the port. Set `token` to require a shared secret on every request.

Scheduled jobs and explicitly requested announcements can wake the device through Web Push. It needs HTTPS and, on iOS, a PWA added to the home screen. The VAPID key pair is generated on first use in `vapid.json` next to `config.yml`; deleting it invalidates every subscription.

## Workspace Files

`rubot init` creates these under `~/.rubot/`:

- **SOUL.md** — freeform Markdown describing the bot's personality and style; loaded into the system prompt every session.
- **AGENTS.md** — Markdown with YAML frontmatter (`name`, `model`, `max_tokens`, `temperature`, `max_rounds`, tool toggles) plus behavior rules.
- **MEMORY.md** — persistent memory, split into global (`~/.rubot/MEMORY.md`) and local (`~/.rubot/memory/<slug>.md` or `<persona>/MEMORY.md`) layers. Sections: Facts, Preferences, Context, Learned Corrections. The `memory` tool reads, appends, and updates sections; a full write is deliberately not exposed.
- **personas.json** — specialists with their own model, prompt, soul, and memory.
- **model_catalog.json** / **model_pricing.json** — caches for the provider model list and models.dev pricing. Safe to delete; they rebuild on next use.

## Tools

Rubot ships with nine built-in tools:

| Tool | Purpose |
|------|---------|
| `shell_exec` | Run shell commands in the launch directory; dangerous commands are blocked |
| `file_ops` | Read, edit, write, append, delete, list, and inspect files |
| `search` | Find files by glob or matching lines by regex, skipping `.git`, `node_modules`, and build output |
| `web_fetch` | Fetch a URL and convert HTML to plain text (5,000 char cap) |
| `memory` | Read and update persistent memory (enabled when memory is on) |
| `cron` | Schedule one-time or recurring reminders and commands |
| `send_files` | Deliver local files (pictures, PDFs, notes) into the chat thread |
| `notify` | Ask for the end of the current turn to be announced on the user's devices |
| `instagram` | Connect an Instagram Business/Creator account and schedule feed posts |

New scripts and snippets are written in Ruby (`ruby -e '...'` or a `.rb` file). Existing Python in a repo or skill is run as-is. To add a tool, subclass `Rubot::Tool` in `lib/rubot/tools/` and register it in `registry.rb`.

## Skills

Skills are domain-specific instructions in `~/.rubot/workspace/skills/<name>/SKILL.md`: YAML frontmatter (`name`, `description`) plus a Markdown body. They load on startup. Use the built-in `skill-creator` skill or create the directory by hand.

## Safety Guard

A PicoClaw-style guard blocks dangerous commands before execution:

- **strict** — blocks known dangerous patterns (`rm -rf /`, `mkfs`, `dd if=`, …)
- **permissive** — allows all commands

Set the mode in `AGENTS.md` frontmatter or workspace settings.

## Architecture

I/O is separated from agent execution:

- **Channels** (REPL, Telegram, web) live in the main Ractor and own all I/O and signal handling.
- **Session actors** each own one `Agent`, one `Session`, and its tools. A session id maps to exactly one actor, so requests to the same conversation are serialized by its mailbox.
- **Cron actor** owns the scheduler and job stores, with one store per workspace.
- **Message passing** over `Ractor::Port` carries streaming chunks, tool events, progress, and confirmation requests across Ractor boundaries.
- **File-backed state** (`MEMORY.md`, session JSON) uses `flock` to prevent corruption.

```
Channel (main Ractor) ──► SessionActor(session id) ──► CronActor
        ▲                        │
        └──── chunks, tool events, confirmations ────┘
```

## Project Structure

```
rubot/
├── bin/rubot                  # Main executable
├── lib/rubot.rb               # Entry point
├── lib/rubot/
│   ├── agent.rb               # Agent loop
│   ├── session.rb             # Session/history management
│   ├── config.rb              # Configuration management
│   ├── actors/                # Session, session pool, and cron actors
│   ├── providers/             # OpenAI, Anthropic, Ollama
│   ├── tools/                 # Built-in tools and registry
│   ├── channels/              # REPL, Telegram, web, and registry
│   ├── memory.rb, soul.rb, persona.rb, skill.rb, ...
│   └── safety_guard.rb        # Dangerous command filter
├── config/rubot.example.yml   # Example config
├── test/                      # Minitest tests
├── Dockerfile, docker-compose*.yml
├── Gemfile, Rakefile, mise.toml, .ruby-version
└── README.md
```

## Docker

```bash
mkdir -p ~/.rubot/workspace/skills
docker compose build
docker compose run --rm rubot init
vim ~/.rubot/config.yml
```

`docker-compose.override.yml` is git-ignored and bind-mounts `~/.rubot` plus any brand/content directories you need into the agent workspace. Copy `docker-compose.override.yml.example` as a starting point; mount-point directories must exist and be owned by you before the first `up`.

```bash
docker compose run --rm rubot -C repl     # interactive REPL
docker compose run --rm rubot -m "hello"  # one-shot message
docker compose up -d                      # Telegram bot (background)
```

The image includes Node, headless Chromium, ImageMagick, and a static ffmpeg for the brand/carousel skills. For Ollama on the host, use `api_base: http://host.docker.internal:11434`.

## Testing

```bash
bundle install
bundle exec rake test
```

Tests use a throwaway `HOME` and temp workspaces, so they never touch your real `~/.rubot`.

## License

MIT
