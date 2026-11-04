# 🤖 Rubot - AI Assistant in Ruby

> Personal AI assistant written in pure Ruby — powered by Ractors.

Rubot is a lightweight, terminal-based AI assistant inspired by [NanoBot](https://github.com/HKUDS/nanobot) and [PicoClaw](https://github.com/sipeed/picoclaw). It connects to LLM providers (OpenAI, Anthropic, Ollama, or any OpenAI-compatible API) and executes tool calls — all using only Ruby's standard library.

## Features

- 🪶 **Almost zero dependencies** — Ruby 4 standard library; WEBrick only for Telegram webhook mode
- ⚡ **Ractor-powered sessions** — one actor per conversation, no shared mutable agent state
- 🔌 **Multiple providers** — OpenAI, Anthropic, Ollama, or any OpenAI-compatible API
- 🛠️ **Built-in tools** — shell execution, file operations, web fetching, persistent memory, cron scheduling
- 💬 **Interactive REPL** — with streaming, command history, and tab completion
- 📝 **Session management** — persistent conversation history
- 🧬 **SOUL.md** — personality and identity file for persistent character
- 📋 **AGENTS.md** — YAML frontmatter config + markdown behavior rules
- 🧠 **MEMORY.md** — persistent memory the bot can read and update across sessions
- ⏰ **Cron scheduling** — schedule reminders, recurring tasks, and timed alerts
- 🔒 **Safety guard** — dangerous command filtering (PicoClaw-style sandboxing)
- 🎯 **Skills system** — pluggable skill definitions via SKILL.md files in the workspace
- 📡 **Multi-channel** — REPL and Telegram, with a pluggable channel architecture
- 📄 **`.env` support** — automatic environment variable loading from `.env` files
- 🎛️ **CLI options** — single-message mode or interactive chat

## Requirements

- Ruby 4.0+
- `bundle install` (only for `webrick` in webhook mode, plus test gems)

The repository pins Ruby with `.ruby-version` and `mise.toml`. With [mise](https://mise.jdx.dev/):

```bash
mise install
mise exec -- ruby -v   # 4.0.9
```

## Installation

Clone the repository and add `bin/` to your PATH:

```bash
git clone https://github.com/adipurnm/rubot.git
cd rubot
export PATH="$PWD/bin:$PATH"  # or add to ~/.bashrc
```

Or just run directly:

```bash
ruby bin/rubot --help
```

## Quick Start

### 1. Initialize

```bash
rubot init
```

This creates `~/.rubot/` with a default config, workspace, SOUL.md, MEMORY.md, AGENTS.md, and the skill-creator skill.

### 2. Configure

Edit the generated config:

```bash
vim ~/.rubot/config.yml
```

Or use environment variables:

```bash
export RUBOT_API_KEY="sk-your-key-here"
```

### 3. Validate

```bash
rubot check
```

Checks your config, API key, workspace, and channel connections before you start.

### 4. Run

```bash
# Interactive mode
rubot

# Single message
rubot -m "What is Ruby?"

# Use Ollama (no API key needed)
rubot -p ollama -M llama3 -m "Hello!"

# With Anthropic/Claude
export ANTHROPIC_API_KEY="sk-ant-..."
rubot -p anthropic -M claude-sonnet-4-20250514 -m "Hello!"

# Debug mode
rubot -d -m "Test"

# Disable tools
rubot -n -m "Just chat"

# Telegram channel
export TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
rubot -C telegram
```

## Usage

### Interactive Mode

```
$ rubot
╔══════════════════════════════════════════════╗
║         🤖  Rubot AI Assistant  🤖          ║
╠══════════════════════════════════════════════╣
║  Provider: openai                            ║
║  Model:    gpt-4o-mini                       ║
║  Tools:    3 loaded                          ║
╠══════════════════════════════════════════════╣
║  Type /help for commands, /quit to exit     ║
╚══════════════════════════════════════════════╝

🤖 You: List files in the current directory
🤖 Assistant: [streamed response...]
```

### REPL Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/clear` | Clear conversation history |
| `/new` | Clear chat and start a new session |
| `/session [name]` | Show or switch session |
| `/info` | Show agent info (includes soul/memory status) |
| `/tools` | List available tools |
| `/soul` | Show the bot's soul (SOUL.md) |
| `/memory` | Show persistent memory (MEMORY.md) |
| `/agents` | Show agent rules (AGENTS.md) |
| `/cron` | List scheduled cron jobs |
| `/cron delete <id>` | Delete a cron job |
| `/stream on\|off` | Toggle streaming |
| `/quit` | Exit |

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
| `-v, --version` | Show version |
| `-C, --channel CHANNEL` | Channel to use: repl, telegram (default: repl) |
| `-h, --help` | Show help |

### Subcommands

| Subcommand | Description |
|------------|-------------|
| `rubot init` | Initialize config, workspace, and default files |
| `rubot check` | Validate config and test channel connections |

## Configuration

Config file location: `~/.rubot/config.yml` (or set `RUBOT_CONFIG`)

```yaml
agents:
  defaults:
    workspace: ~/.rubot/workspace
    name: gpt-4o-mini
    max_tokens: 4096
    temperature: 0.7
    system_prompt: "You are Rubot, a helpful AI assistant."
    max_tool_iterations: 50

models:
  - name: gpt-4o-mini
    model: openai/gpt-4o-mini
    api_key: sk-your-key-here
    api_base: https://api.openai.com/v1
  - name: llama3
    model: ollama/llama3
    api_base: http://localhost:11434

tools:
  exec:
    enabled: true
  read_file:
    enabled: true
  write_file:
    enabled: true
  list_dir:
    enabled: true
  web_fetch:
    enabled: true
```

### Model List

Each entry in `model_list` defines a model with its provider and credentials:

| Field | Description |
|-------|-------------|
| `name` | Friendly name for the model |
| `model` | `<provider>/<model-id>` (e.g. `openai/gpt-4o-mini`, `ollama/llama3`) |
| `api_key` | API key (optional for Ollama) |
| `api_base` | API base URL |

### Providers

| Provider | Model Prefix | API Key Env Var | Notes |
|----------|-------------|-----------------|-------|
| OpenAI | `openai/` | `RUBOT_API_KEY`, `OPENAI_API_KEY` | Default |
| Anthropic | `anthropic/` | `ANTHROPIC_API_KEY` | |
| Ollama | `ollama/` | (none) | Local, no key needed |
| Any OpenAI-compatible | `openai/` | Set `api_base` | Groq, DeepSeek, LM Studio, etc. |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `RUBOT_API_KEY` | API key (overrides config) |
| `RUBOT_API_BASE` | API base URL (overrides config) |
| `RUBOT_CONFIG` | Path to config file |
| `RUBOT_DEBUG` | Set to `1` for debug mode |
| `OPENAI_API_KEY` | Fallback for OpenAI key |
| `OPENAI_API_BASE` | Fallback for OpenAI base URL |
| `ANTHROPIC_API_KEY` | Anthropic API key |
| `OLLAMA_HOST` | Ollama host (default: http://localhost:11434) |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |

### `.env` File Loading

Rubot automatically loads environment variables from `.env` files on startup. It searches:

1. `.env` in the current working directory
2. `.env` files in `~/.rubot/` (e.g., `.env`, `.env.local`, `.env.production`)

Or specify a file explicitly:

```bash
rubot -e /path/to/.env -m "Hello!"
```

Variables are loaded in order — later files override earlier ones. Use `KEY=VALUE` syntax with support for double-quoted, single-quoted, and unquoted values.

## Channels

Rubot supports multiple communication channels — the terminal REPL is just the default.
Channels are configured in `~/.rubot/config.yml` under the `channels:` key, and multiple
can run simultaneously.

### Available Channels

| Channel | Description |
|---------|-------------|
| `repl` | Terminal REPL (default if no channels configured) |
| `telegram` | Telegram Bot via long polling or webhook |

### Telegram Setup

1. **Create a bot** via [@BotFather](https://t.me/BotFather) on Telegram and get your bot token.
2. **Configure** your `~/.rubot/config.yml`:

```yaml
channels:
  telegram:
    token: "123456:ABC-DEF..."  # or set TELEGRAM_BOT_TOKEN env var
    # Optional security: restrict who can talk to your bot
    allowed_user_ids: [123456789]   # your Telegram user ID
    typing_indicator: true          # show "typing..." while processing
    max_message_length: 4096        # Telegram's max message length
```

3. **Run** with the Telegram channel:

```bash
# Check configuration before starting
rubot check

# Via CLI flag
rubot -C telegram

# Or via config (add to config.yml and just run `rubot`)
rubot
```

Telegram uses long polling by default. For production use with webhooks:

```yaml
channels:
  telegram:
    token: "123456:ABC-DEF..."
    webhook: true
    webhook_url: "https://your-domain.com/webhook"
    webhook_port: 8443
```

### Running Multiple Channels

You can run both REPL and Telegram simultaneously:

```yaml
channels:
  repl:
    stream: true
  telegram:
    token: "123456:ABC-DEF..."
```

### Adding New Channels

Channels are pluggable. To add a new channel (e.g., Discord, Slack, WhatsApp):

1. Create `lib/rubot/channels/your_channel.rb`
2. Subclass `Rubot::Channel`:

```ruby
module Rubot
  module Channels
    class Discord < Channel
      def start
        @running = true
        register_signal_handlers
        # Connect to Discord API, listen for messages
        # On message: response = process_message(text)
        # Then: send_response(channel_id, response)
      end

      def stop
        @running = false
        # Disconnect from Discord API
      end
    end
  end
end
```

3. Register it in `lib/rubot/channels/registry.rb`:

```ruby
CHANNEL_MAP = {
  "telegram" => Telegram,
  "repl" => REPLChannel,
  "discord" => Discord,    # add your channel
}.freeze
```

4. Configure in `config.yml`:

```yaml
channels:
  discord:
    bot_token: "your-discord-bot-token"
```

## Workspace: Soul, Agents & Memory

Run `rubot init` to create `~/.rubot/workspace/` with default files.

### SOUL.md — Personality & Identity

A freeform Markdown file describing the bot's personality, values, and
communication style. Loaded into the system prompt on every session.

```markdown
# Soul

You are Rubot, a concise and pragmatic terminal assistant.
You are written in Ruby and value simplicity.
You prefer small, composable solutions over complex architectures.
```

### AGENTS.md — Agent Configuration & Rules

A Markdown file with **YAML frontmatter** for machine-readable settings
and a body of behavior rules. Frontmatter can override:
`name`, `model`, `max_tokens`, `temperature`, `max_tool_iterations`, and
individual tool enable/disable settings.

```yaml
---
name: Rubot
model: gpt-4o-mini
max_tokens: 4096
temperature: 0.7
max_tool_iterations: 50
tools:
  exec: true
  file_ops: true
  web_fetch: true
---
```

```markdown
# Agent Rules

- Be concise and direct in responses.
- Explain before executing commands.
- Use tools when they can help.
- Remember important details using the memory tool.
```

### MEMORY.md — Persistent Memory

A Markdown file that the bot reads on every session and can update via
the built-in `memory` tool. Organized into sections:

- **Facts** — Things the bot should remember about you
- **Preferences** — Your communication style and preferences
- **Context** — Current project/task context

The bot uses the memory tool to `read`, `write`, `append`, and
`update_section`. This lets it remember information across sessions.

```markdown
# Memory

## Facts
- User prefers Ruby over JavaScript
- Works on a personal AI assistant project

## Preferences
- Concise responses, no fluff

## Context
- Currently working on tool registry
```

## Tools

Rubot comes with 5 built-in tools:

### `shell_exec`
Execute shell commands. The LLM can run commands and see their output.
Dangerous commands like `rm -rf /` are blocked.

### `file_ops`
File operations: read, write, append, list directories, get file info.

### `web_fetch`
Fetch content from URLs via HTTP GET.

### `memory`
Read and update the bot's persistent MEMORY.md file.

| Operation | Description |
|-----------|-------------|
| `read` | Read the entire memory file |
| `write` | Replace all memory with new content |
| `append` | Add a fact to a section (Facts, Preferences, or Context) |
| `update_section` | Replace all items in a section |

### `cron`
Schedule reminders, recurring tasks, and timed alerts. The LLM can:

- Set one-time reminders (e.g., "remind me in 5 minutes")
- Create recurring tasks (e.g., "every hour", "daily at 9am")
- Schedule shell commands to run on a schedule
- Deliver messages through the active channel

Jobs are stored in the workspace and checked each time the agent processes a message.

### Adding Custom Tools

Create a new file in `lib/rubot/tools/` and subclass `Rubot::Tool`:

```ruby
require_relative "../tool"

module Rubot
  module Tools
    class MyTool < Tool
      def name
        "my_tool"
      end

      def description
        "Description for the LLM"
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "input" => { "type" => "string", "description" => "The input" }
          },
          "required" => ["input"]
        }
      end

      def execute(arguments)
        input = arguments["input"]
        # Do something
        "Result: #{input}"
      end
    end
  end
end
```

Then register it in `lib/rubot/tools/registry.rb`.

## Skills

Skills are pluggable domain-specific instructions stored as `SKILL.md` files in the workspace. They let you teach Rubot specialized procedures without changing the core code.

### Skill Structure

Each skill lives in its own directory:

```
~/.rubot/workspace/skills/{skill-name}/SKILL.md
```

The `SKILL.md` file contains:

1. **YAML frontmatter**:
   ```yaml
   ---
   name: my-skill
   description: A brief description of what this skill does and when to use it.
   ---
   ```

2. **Markdown body** — instructions for when and how to use the skill.

### Creating Skills

Use the built-in `skill-creator` skill (installed by `rubot init`) or manually create a directory and `SKILL.md`. Skills are automatically loaded from the workspace `skills/` directory on startup.

## Safety Guard

Rubot includes a PicoClaw-style safety guard that blocks dangerous commands before execution. It operates in two modes:

- **strict** — blocks commands matching known dangerous patterns (e.g., `rm -rf /`, `mkfs`, `dd if=`, `fsck -y /dev/`)
- **permissive** — allows all commands

The mode is configured in `AGENTS.md` frontmatter or the workspace settings.

## Architecture: Ractor Sessions

Rubot separates I/O from agent execution:

- **Channels** (REPL, Telegram) live in the main Ractor and own all I/O,
  signal handling, and channel-local state.
- **Session actors** (`lib/rubot/actors/session_actor.rb`) each own one
  `Agent`, one `Session`, and its tools. A session id maps to exactly one
  actor, so requests to the same conversation are serialized by the
  actor's mailbox instead of by mutexes.
- **Cron actor** (`lib/rubot/actors/cron_actor.rb`) owns the scheduler and
  the persisted job store, and delivers fired jobs as messages.
- **Message passing** replaces callbacks across Ractor boundaries: tool
  events, streaming chunks, progress, and confirmation requests are
  sent as messages on `Ractor::Port` objects. Procs and mutexes never
  cross a boundary.
- **File-backed state** (`MEMORY.md`, session JSON) is written with
  `flock` so concurrent session actors cannot corrupt it.

```
Channel (main Ractor)
   │  { type: :message, text:, events:, control: }
   ▼
SessionActor(session id) ── tools ──► CronActor
   │  [:chunk] [:tool_started] [:progress] [:confirm] [:done]
   ▼
Channel
```

Legacy in-process agents are still supported by passing `agent:` to a
channel, which is what the unit tests use.

## Project Structure

```
rubot/
├── bin/
│   └── rubot              # Main executable
├── lib/
│   ├── rubot.rb           # Entry point
│   └── rubot/
│       ├── agent.rb       # Agent loop (process messages, call tools)
│       ├── session_handle.rb # Main-Ractor proxy for a session actor
│       ├── actors/
│       │   ├── session_actor.rb # One Agent/Session per Ractor
│       │   ├── session_pool.rb  # Lazy per-session actor registry
│       │   └── cron_actor.rb    # Ractor-owned cron scheduler
│       ├── cron_commands.rb # Shared cron operation implementation
│       ├── config.rb      # Configuration management
│       ├── session.rb     # Session/history management
│       ├── soul.rb        # SOUL.md personality loader
│       ├── memory.rb      # MEMORY.md persistent memory
│       ├── agents_file.rb # AGENTS.md config & rules parser
│       ├── provider.rb    # Base provider interface
│       ├── providers/
│       │   ├── openai.rb  # OpenAI-compatible provider
│       │   ├── anthropic.rb # Anthropic provider
│       │   └── ollama.rb  # Ollama provider
│       ├── tool.rb        # Base tool class
│       ├── tools/
│       │   ├── shell.rb   # Shell execution tool
│       │   ├── file_tool.rb # File operations tool
│       │   ├── web.rb     # Web fetch tool
│       │   ├── memory_tool.rb # Memory management tool
│       │   ├── cron.rb    # Cron scheduling tool
│       │   └── registry.rb # Tool registry
│       ├── channel.rb     # Base channel class
│       ├── channels/
│       │   ├── repl_channel.rb # Terminal REPL
│       │   ├── telegram.rb  # Telegram bot channel
│       │   └── registry.rb  # Channel registry
│       ├── safety_guard.rb # Dangerous command filter
│       ├── skill.rb       # Skill loader
│       ├── skill_registry.rb # Skill registry
│       ├── cron_scheduler.rb # Cron job scheduler
│       └── env_loader.rb  # .env file loader
├── config/
│   └── rubot.example.yml # Example config
├── test/                  # Minitest tests
├── Gemfile                # webrick + test gems
├── Dockerfile             # Ruby 4.0.9 runtime image
├── docker-compose.yml     # base compose service
├── docker-compose.override.yml.example # local laptop template
├── mise.toml              # Ruby version pin (4.0.9)
├── .ruby-version          # Ruby version pin
├── Rakefile               # Test runner
└── README.md
```

## Docker

Build the image and initialize `~/.rubot` once:

```bash
mkdir -p ~/.rubot/workspace/kanyaah.com ~/.rubot/workspace/adipurnm.com
mkdir -p ~/.rubot/workspace/skills/{adipurnm-brand,kanyaah-brand,marketing-strategist,writing}
docker compose build
docker compose run --rm rubot init
vim ~/.rubot/config.yml   # set your API key / Telegram token
```

With the local override, host data lives in `~/.rubot` and is mounted onto
`/home/rubot/.rubot` in the container. The brand projects are mounted
inside the agent workspace so the safety guard allows read/write access:

| Host | Container |
|---|---|
| `~/.rubot` | `/home/rubot/.rubot` |
| `~/Documents/work/freelance/website/kanyaah.com` | `/home/rubot/.rubot/workspace/kanyaah.com` |
| `~/Documents/work/freelance/website/by.adipurnm.com` | `/home/rubot/.rubot/workspace/adipurnm.com` |
| `~/Projects/squadron/skills/adipurnm-brand` | `/home/rubot/.rubot/workspace/skills/adipurnm-brand` |
| `~/Projects/squadron/skills/kanyaah-brand` | `/home/rubot/.rubot/workspace/skills/kanyaah-brand` |
| `~/Projects/squadron/skills/marketing-strategist` | `/home/rubot/.rubot/workspace/skills/marketing-strategist` |
| `~/Projects/squadron/skills/writing` | `/home/rubot/.rubot/workspace/skills/writing` |

Because the brand directories live under the workspace, the agent can use
its normal `file_ops` / `shell_exec` tools on them without disabling the
safety guard. Squadron skills are mounted one directory at a time, so any
other skills already in `~/.rubot/workspace/skills` remain visible.

Run modes:

```bash
# Interactive REPL
docker compose run --rm rubot -C repl

# One-shot message
docker compose run --rm rubot -m "hello"

# Telegram bot (background)
docker compose up -d
docker compose logs -f
docker compose down
```

`docker-compose.override.yml` is git-ignored and is the local laptop
configuration. It bind-mounts `~/.rubot`, the two brand directories, and
the four Squadron skills, and runs as your UID/GID so sessions, `MEMORY.md`,
cron jobs, and edited brand/skill files stay owned by you. It defaults to
`-C telegram`; remove its
`command:` block (or run `docker compose run --rm rubot -C repl`) for the
REPL.

A tracked template is available as `docker-compose.override.yml.example`:

```bash
mkdir -p ~/.rubot/workspace/kanyaah.com ~/.rubot/workspace/adipurnm.com
mkdir -p ~/.rubot/workspace/skills/{adipurnm-brand,kanyaah-brand,marketing-strategist,writing}
cp docker-compose.override.yml.example docker-compose.override.yml
HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d
```

The mount-point directories must exist and be owned by you before the
first `docker compose up`. Otherwise Docker creates them as root.

Notes:

- From the laptop, edit `~/.rubot/config.yml`. Inside the container the
  data directory is `/home/rubot/.rubot`, so workspace paths resolve to
  `~/.rubot/workspace` (the generated default) or `/home/rubot/...`.
- To add another brand or skill, append another bind mount under
  `/home/rubot/.rubot/workspace/<name>` (or `/home/rubot/.rubot/workspace/skills/<name>`)
  and create the matching host mount point first.
- Skills are regular files on the host: edit them in
  `~/Projects/squadron/skills` and the container sees the changes immediately.
- For Ollama running on the host, set
  `api_base: http://host.docker.internal:11434` (already allowed by the
  Compose `extra_hosts` entry).
- Telegram webhook mode additionally needs a port mapping in the override,
  e.g. `ports: ["8443:8443"]`.
- The image contains only `webrick` plus the standard library. Test gems
  are excluded via `BUNDLE_WITHOUT=development:test`.

## Testing

```bash
bundle install
bundle exec rake test
```

## License

MIT
