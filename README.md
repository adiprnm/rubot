# 🤖 Rubot - AI Assistant in Ruby

> Personal AI assistant written in pure Ruby — powered by Ractors.

Rubot is a lightweight, terminal-based AI assistant inspired by [NanoBot](https://github.com/HKUDS/nanobot) and [PicoClaw](https://github.com/sipeed/picoclaw). It connects to LLM providers (OpenAI, Anthropic, Ollama, or any OpenAI-compatible API) and executes tool calls — all using only Ruby's standard library.

## Features

- 🪶 **Almost zero dependencies** — Ruby 4 standard library; WEBrick only for Telegram webhook mode
- ⚡ **Ractor-powered sessions** — one actor per conversation, no shared mutable agent state
- 🔌 **Multiple providers** — OpenAI, Anthropic, Ollama, or any OpenAI-compatible API
- 🛠️ **Built-in tools** — shell execution, file operations, web fetching, persistent memory, cron scheduling
- 💬 **Interactive REPL** — with streaming, command history, tab completion, and a slash-command palette
- ⌨️ **Multiline prompt** — Shift+Enter inserts a newline and the input box grows with the text, word-wrapping long lines
- 📝 **External editor** — Ctrl+G opens the half-typed prompt in `$EDITOR` and takes the edited text straight back into the input box
- 📝 **Session management** — persistent conversation history, a new session per TUI launch, and `/resume` to browse and reopen any saved session
- 🧬 **SOUL.md** — personality and identity file for persistent character
- 🎛️ **Model presets** — named model configurations with a primary default, switchable per session and manageable from Telegram
- 🎚️ **Model picker** — `/models` lists every model the provider supports and switches the active session to the one you pick
- 🎭 **Per-topic personas** — each Telegram forum topic can have its own model preset and system prompt, set up with an inline-button wizard
- 📋 **AGENTS.md** — YAML frontmatter config + markdown behavior rules
- 🧠 **MEMORY.md** — persistent memory the bot can read and update across sessions
- ⏰ **Cron scheduling** — schedule reminders, recurring tasks, and timed alerts
- 🔒 **Safety guard** — dangerous command filtering (PicoClaw-style sandboxing)
- 🎯 **Skills system** — pluggable skill definitions via SKILL.md files in the workspace; loading one shows up in the TUI transcript as its own `✦ skill <name>` row, and flips to `✓` once read
- 📡 **Multi-channel** — REPL and Telegram, with a pluggable channel architecture
- 📎 **Inbound attachments** — screenshots and files sent to Telegram are saved to the workspace, with dimensions and size added to the prompt
- 🔈 **Progress narration** — the model explains what it is doing between tool calls ("Let me check the structure first."), sent as normal chat messages
- 🧭 **Steering** — type while a turn is running (TUI, or a plain message in Telegram) and it reaches the model between rounds, without stopping the turn
- ⏹️ **`/stop`** — stops the running turn instantly, mid-answer or mid-command: an open provider stream is closed, not drained, and the shell command it started is killed
- 🗜️ **Context compaction** — `/compact` summarizes older turns, and auto-compaction kicks in at a configurable share of the context window
- 🪶 **Lean requests** — past reasoning is never re-sent, old tool output is shortened, and an optional token budget bounds the history block
- 🎨 **Telegram HTML rendering** — model Markdown becomes Telegram HTML: nested bold/italic, `<blockquote expandable>`, spoilers, syntax-highlighted code, aligned monospace tables, and long replies split without breaking entities
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

# Terminal UI only, even when other channels (e.g. Telegram) are enabled
rubot tui

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

Every command's output is set apart in the transcript: one blank line above
and below it, and two cells of left padding. A command that prints nothing
still leaves one blank line below it, so whatever comes next is set apart from
it — and so does a list that is cancelled (`/models`, `/resume`): the rows go
back out, and the blank line stays.

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/clear` | Clear conversation history |
| `/new` | Clear chat and start a new session |
| `/stop` | Stop the task that is running (Ctrl+C during a turn does the same) |
| `/compact` | Summarize older messages to free context |
| `/session [name]` | Show or switch session |
| `/resume` | Show saved sessions under the command; `↑`/`↓` + `Enter` resumes one (plain REPL: numbered list) |
| `/resume <n\|id>` | Reopen a saved session by number or id |
| `/info` | Show agent info (includes soul/memory status) |
| `/models` | List the models the provider supports; type to search, `↑`/`↓` + `Enter` switches the active session to one (plain REPL: printed list) |
| `/models <text>` | Show only the models whose id or name contains `<text>` |
| `/use-model <name\|id>` | Switch the active session to a configured model or a provider model id |
| `/context` | Show context usage, cache hit rate, and estimated cost |
| `/usage` | Show OpenCode Go subscription usage |
| `/tools` | List available tools |
| `/soul` | Show the bot's soul (SOUL.md) |
| `/memory` | Show persistent memory (MEMORY.md) |
| `/agents` | Show agent rules (AGENTS.md) |
| `/cron` | List scheduled cron jobs |
| `/cron delete <id>` | Delete a cron job |
| `/stream on\|off` | Toggle streaming |
| `/quit` | Exit |

Sessions live as JSON files under `<workspace>/sessions/`. Every TUI launch
starts a new conversation under a timestamped id — the previous one keeps its
own id and stays resumable, so nothing is lost. A session file is only written
once it has at least one message: closing a launch before saying anything
leaves nothing behind and adds nothing to `/resume`. The list of saved sessions
is written into the transcript, right under the echoed command (not a floating
window), newest first, each row showing the last prompt with the message count
and age pinned to the right edge. `Up`/`Down` (or `PageUp`/`PageDown`) move the
highlight, `Enter` resumes the selected session and restores its whole
transcript — every user prompt, tool call, and assistant answer, rendered
exactly as it looked while the session was live — and `Esc` takes the list back
out without switching. `/resume 2` and `/resume <id>` reopen a session without
the list (a piped, non-tty REPL replays the transcript as plain text), and
`/resume` alone prints the numbered list there. `/session <name>` still switches
directly.

`/models` asks the provider which models it serves (`GET /models` for
OpenAI-compatible APIs, `GET /v1/models` for Anthropic, `GET /api/tags` for
Ollama) and writes the list into the transcript, right under the echoed
command. Models configured in `config.yml` that the provider does not
advertise are listed as well, so a configured model stays selectable. The
model the session is running is marked with `✓`. Typing searches the list:
every keystroke narrows it to the models whose id or name contains what has
been typed, `Backspace` undoes a character, and the header counts the matches
(`(2/30)`). `Up`/`Down` (or
`PageUp`/`PageDown`) move the highlight, `Enter` switches the active session
to the highlighted model — it stays switched until `/new` — and `Esc` clears
the search, and closes the list once the search is empty. `/models <text>`
narrows the list to the models whose id or name contains that text. The
catalog is cached
in `<workspace>/model_catalog.json`, so a provider that is temporarily
unreachable still shows the last known list.

### TUI Keys

| Key | Action |
|-----|--------|
| `Enter` | Send the prompt, take the highlighted `/command`, or steer the turn that is running |
| `Shift+Enter`, `Alt+Enter` | Insert a newline |
| `Up` / `Down` | Move between lines once the input has more than one, otherwise recall history; while the command list is open, pick an entry |
| `Tab` | Complete a `/command` |
| `Ctrl+G` | Edit the prompt in `$EDITOR`, then take it back into the input |
| `Esc` | Cancel the running turn, clear a selection |
| `Ctrl+C` | Quit |
| `PageUp` / `PageDown`, mouse wheel | Scroll the transcript |
| Drag with the mouse | Select text; released selection is copied via OSC 52 |

Typing `/` at the start of the prompt opens the command list above the input
box, with each command's description on the right. Keep typing to filter it,
use `Up`/`Down` to move the highlight, and press `Enter` to put the highlighted
command in the prompt (a fully typed command runs on `Enter` instead). `Esc`
dismisses the list, and a space closes it once you start typing an argument.

While a turn is running, `Enter` steers it instead of queueing behind it: the
line is echoed on its own row, set apart by a blank row above and below, and
handed to the model after the tool calls of the round in flight, before its
next request. That is how a direction is corrected
mid-turn — "use the other directory", "skip the tests" — without cancelling
the work already done. Each steer becomes its own user turn, so it stays in
the session and is replayed on `/resume`. Commands typed while a turn is
running still queue and run once it finishes; `Esc` (or `/stop`) stops the
turn as before.

The prompt grows with its content: hard newlines and long lines that wrap both
add rows, up to six. `Shift+Enter` needs a terminal that reports the key
separately, which means the kitty keyboard protocol (kitty, Ghostty, WezTerm,
foot, iTerm2) or xterm's modifyOtherKeys — rubot turns both on for the duration
of the session. Terminals that cannot distinguish it (Alacritty) send a plain
`Enter`.

Under the prompt, the status row tracks the running turn's estimated cost,
cache hit rate, and how much of the model's context window is in use (for
example `$0.004 · cache 87.3% · ctx 11.6%`), with the session and model on
the right. Figures refresh after every turn; `/context` has the full report.

`Ctrl+G` hands the prompt to an external editor for a long or multi-paragraph
message, then reads it back into the input box. The editor is `external_editor`
from `config.yml` when set, otherwise `$VISUAL`, `$EDITOR`, or `vi`. The TUI
steps aside while the editor runs (alternate screen, raw mode, mouse tracking
and the keyboard protocol are restored afterwards), so a normal full-screen
editor works in place. The command has to block until the file is saved — use
`code --wait`, not `code`:

```yaml
external_editor: nvim
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
| `-v, --version` | Show version |
| `-C, --channel CHANNEL` | Channel to use: tui, telegram (default: configured channels) |
| `-h, --help` | Show help |

### Subcommands

| Subcommand | Description |
|------------|-------------|
| `rubot init` | Initialize config, workspace, and default files |
| `rubot check` | Validate config and test channel connections |
| `rubot tui` | Run the terminal UI only and skip every configured channel |

## Configuration

Config file location: `~/.rubot/config.yml` (or set `RUBOT_CONFIG`)

```yaml
agents:
  defaults:
    workspace: ~/.rubot/workspace
    name: gpt-4o-mini
    model_preset: primary        # preset used by new sessions
    max_tokens: 4096
    temperature: 0.7
    system_prompt: "You are Rubot, a helpful AI assistant."
    max_rounds: 50
    compaction:
      auto: true
      threshold_percent: 80
      keep_recent_messages: 6
    memory:
      extract_every: 3       # batch memory extraction (0 disables it)
      consolidate: true      # dedupe and cap MEMORY.md sections

model_presets:
  primary:
    model: opencode-go          # config model entry, or a provider model id
    max_tokens: 4096
    temperature: 0.7
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

### Agent rounds

`agents.defaults.max_rounds` caps how many loop rounds one user message may
use (default 50). A round is one trip through the agent loop: running the tools
the model asked for, re-asking after an empty reply, or asking for the rest of a
cut-off answer. One round can run several tools, so this is not a tool-call
limit. When the limit is reached the turn stops with a notice and the user can
reply "continue".

`max_tool_iterations` is the old name for this setting and is still accepted;
new configs should use `max_rounds`.

### Model List

Each entry in `model_list` defines a model with its provider and credentials:

| Field | Description |
|-------|-------------|
| `name` | Friendly name for the model |
| `model` | `<provider>/<model-id>` (e.g. `openai/gpt-4o-mini`, `ollama/llama3`) |
| `api_key` | API key (optional for Ollama) |
| `api_base` | API base URL |

When the provider exposes a `GET /models` endpoint (OpenAI-compatible APIs,
including OpenCode Go), `/preset models` lists the provider's own catalog
instead of only the entries in `config.yml`. The catalog is cached at
`<workspace>/model_catalog.json`; a preset that references a catalog model id
reuses the active config entry's `api_base` and `api_key`.

The TUI's `/models` reads the same catalog — Anthropic (`GET /v1/models`) and
Ollama (`GET /api/tags`) included — and switches the active session to the
model you pick.

### Model Presets

A model preset names a complete model configuration. Sessions start with the
primary preset and switch per session with `/model <preset>`.

```yaml
agents:
  defaults:
    model_preset: primary
    # reasoning_effort: low   # global default; a preset overrides it

model_presets:
  primary:
    model: opencode-go            # a `models` entry name...
    max_tokens: 4096
    temperature: 0.7
  deep:
    model: deepseek-v4-pro        # ...or a provider catalog model id
    max_tokens: 8192
    temperature: 0.1
    reasoning_effort: high
  local:
    model: llama3
    provider: ollama
    api_base: http://localhost:11434
    temperature: 0.2
```

| Field | Description |
|-------|-------------|
| `model` | Config `models` entry name or provider model id |
| `provider`, `api_base`, `api_key` | Optional overrides; inherited from the model entry / active entry |
| `max_tokens`, `temperature` | Generation settings for this preset |
| `reasoning_effort` | Sent as OpenAI `reasoning_effort` (`minimal`/`low`/`medium`/`high`). Models without support ignore it |
| `context_window_tokens` | Context window size for `/context` (falls back to a built-in table) |
| `pricing` | Token prices for the cost estimate (see below) |

- `default` is always available as the implicit preset built from the direct
  `models` / `agents.defaults` fields. `/model default` follows it.
- The primary preset is `agents.defaults.model_preset`; if it is unset or
  invalid, the implicit `default` becomes primary. A preset named `primary` may
  be defined explicitly and selected as the default.
- New sessions use the primary preset. `/new` clears the conversation and any
  per-session switch, returning to the primary preset.
- `/model <preset>` switches the current session only and persists across
  restarts. It does not change `config.yml`.

#### Usage and cost estimates

`/context` reports, for the current session:

- context used vs. the model's context window,
- cumulative input/output tokens, plus the cache hit rate of the most recent
  request,
- an estimated cost in USD.

The three figures follow the same rules as Pi:

- **Context** is anchored on the last provider request (its prompt plus the
  reply it produced) and adds an estimate for anything appended since, so
  tool output and a new user message are counted before they are sent. When
  there is no usable request yet — a fresh session, or right after
  `/compact` — it falls back to an estimate of the whole transcript plus the
  system prompt. The same number drives the footer and the automatic
  compaction threshold.
- **Cache hit rate** describes the latest request only
  (`cached / (uncached + cached + cache write)`), not the session average.
  That is what shows whether the prompt cache is working now; a long session
  with one early miss would otherwise hide it.
- **Cost** is priced per request, with the rates of the model that served it,
  and accumulated. Switching model with `/model` therefore does not re-price
  earlier turns. Long-context tiers (`cost.tiers` on models.dev), cache reads,
  and Anthropic 1-hour cache writes (charged at 2x the input rate) are taken
  into account.

#### OpenCode Go usage

`/usage` shows the OpenCode Go subscription allowance for the active model:
the rolling, weekly, and monthly limits, how much of each is used, and when
they reset. It is fetched from `<api_base origin>/zen/go/v1/usage` with the
configured API key, so it only works while the active provider points at
OpenCode (`https://opencode.ai/zen/go/v1`). Accounts without a Go allowance
show that no usage is available.

Pricing and context windows are fetched automatically from
[models.dev](https://models.dev/api.json) and cached in
`<workspace>/model_pricing.json` for 24 hours. The file is a plain JSON cache:
delete it to force a refresh. Lookup precedence is:

1. `pricing` / `context_window_tokens` in `config.yml`,
2. the models.dev cache (or a fresh API response),
3. the bundled defaults in `lib/rubot/model_info.rb`.

You normally don't need to set prices manually. To override a specific model
(USD per 1M tokens):

```yaml
model_presets:
  primary:
    model: gpt-4o-mini
    context_window_tokens: 128000
    pricing:
      input_per_mtok: 0.15
      cached_input_per_mtok: 0.075
      output_per_mtok: 0.60
```

`pricing` may also be set on a `models` entry. Ollama models are treated as
free. Usage is stored in the session file, so it survives restarts and resets
with `/new` or `/clear`.

#### Context compaction

Long sessions eventually fill the model's context window. Rubot summarizes the
older turns into the running summary (included in the system prompt as
"Previous Conversation Summary") and keeps the most recent messages verbatim.

- `/compact` — compact now, at any time. Reports how many messages were
  summarized, how many were kept, and the estimated context before/after.
- Automatic compaction — when the estimated context reaches
  `threshold_percent` of the model's context window:

```yaml
agents:
  defaults:
    compaction:
      auto: true               # default: true
      threshold_percent: 80    # default: 80 (0.8 is also accepted)
      keep_recent_messages: 6  # default: 6
```

A value of `100` disables auto-compaction by making the threshold unreachable
(there is no room left to summarize); set `auto: false` to disable it
outright. The context size is estimated from the transcript with a
bytes-per-token heuristic (reasoning excluded, since it is never sent or
summarized), and very long transcripts are summarized in chunks so the
summarizer request itself stays within the window.

Each compaction **merges** the previous running summary into the new one
instead of appending a paragraph, and only the newest 6,000 characters of the
summary are injected into the system prompt. Without that, every compaction
added another paragraph to a block that was paid for on every request.

On a model with a very large window the percentage threshold can be
unreachable in practice (50% of 1M tokens is 500k). `threshold_tokens` adds an
absolute ceiling; the lower of the two triggers compaction:

```yaml
agents:
  defaults:
    compaction:
      threshold_tokens: 60000  # 0 = disabled (default)
```

#### Request size

Besides compaction, every provider request is trimmed so a tool-heavy turn
does not re-send its entire transcript on each round:

- **Past reasoning is dropped.** Only the reasoning produced inside the turn
  currently running is sent (a tool loop continues from it). Reasoning from
  earlier turns is never needed again and can be the largest part of a
  tool-heavy prompt.
- **Old tool output is shortened.** The newest `tool_result_keep` results are
  sent verbatim; older ones are cut to `tool_result_max_chars`. The session
  file keeps the full output, so `/compact` and later turns still have it.
- **Optional history budget.** `history.max_tokens` drops the oldest messages
  until the block fits the budget.

```yaml
agents:
  defaults:
    history:
      limit: 50                    # default: max_rounds
      max_tokens: 24000            # 0 = only the message limit applies
      tool_result_keep: 3          # newest tool outputs kept in full
      tool_result_max_chars: 2000  # older ones are cut to this
```

Telegram commands:

| Command | Description |
|---------|-------------|
| `/model` | Show the current preset and available presets |
| `/model <preset>` | Switch the current session preset |
| `/models` | List presets |
| `/preset` | List presets |
| `/preset show <name>` | Show one preset |
| `/preset set <name> <model> [temperature=0.2] [max_tokens=4096]` | Create or update a preset in `config.yml` |
| `/preset default <name>` | Choose the preset for new sessions (`default` clears it) |
| `/preset delete <name>` | Remove a preset |
| `/preset models [filter]` | List the provider's supported models |
| `/context` | Show context usage, cache hit rate, and estimated cost |
| `/usage` | Show OpenCode Go subscription usage |
| `/stop` | Stop the running task instantly, mid-answer or mid-command, and any command it started |
| `/compact` | Summarize older messages to free context |

While a turn is still running, a plain message steers it instead of waiting in
the queue: the bot acknowledges with `↳ Diteruskan ke tugas yang sedang
berjalan.` and the text reaches the model after the current round's tool calls,
before its next request. Commands still work mid-turn (`/stop` stops it), and a
message carrying an attachment starts its own turn instead of steering.

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
    narration: true                 # send progress narration as chat messages
    tool_notifications: true        # show/edit a status line while tools run
    max_message_length: 4096        # Telegram's max message length
    attachments: true               # download inbound photos and files
```

While it works, the bot sends the model's own narration as normal chat messages
("Let me check the structure first.", "Now I'll generate the image.") and keeps
the technical detail in a separate status card that is edited in place and
deleted once the final answer arrives. Set `narration: false` to silence the
narration or `tool_notifications: false` to hide the status card.

The card states only what is true — no "still working" filler:

```
✓ 💻 `shell_exec` · step 3 · 1m 05s
$ bundle exec rspec test/agent_test.rb

/stop untuk menghentikan
```

- The `✓` appears once the round has finished, i.e. while the model is being
  asked again; without it, that tool call is the one currently running.
- Edits are throttled to one per second per chat (Telegram's own limit) and an
  identical card is never re-sent, so a batch of tools cannot flood the chat or
  trip a 429. A 429 is retried once using the `retry_after` Telegram sends.
- The `/stop` line appears once per request, and only after the third round or
  after a minute — whichever comes first.

#### Sending images and files to the bot

A photo sent to the bot arrives as `message.photo` plus an optional
`message.caption` — Telegram never fills `message.text` for it. The channel
handles that case: the image (or `document`) is downloaded via `getFile` into
`<workspace>/attachments/<session>/`, and its local path, pixel dimensions, and
size are appended to the caption before the agent sees it:

```
crop ini buat slide 2

📎 User attached an image: /home/rubot/.rubot/workspace/attachments/tg_42/20261104-1006-a1b2c3.jpg (1864×1200, 412 KB)
```

The agent can then use its normal tools (`file_ops`, `shell_exec`) on that path.
Dimensions are read from the file header, so no ImageMagick is required. Files
are kept inside the workspace so the safety guard allows the agent to read them.
Media the channel cannot read (stickers, voice notes, video) now gets an explicit
reply instead of being dropped silently. Set `attachments: false` to disable the
download path entirely.

#### Replying to a message

Telegram puts a quoted message in `message.reply_to_message` and the exact
excerpt the user highlighted in `message.quote` — never in `message.text`. The
channel now carries both into the prompt, so the model knows what the user is
pointing at even when the quoted message is not in the session transcript
(a reply that crosses forum topics, one that follows `/new`, or one aimed at
someone else's message):

```
ini artinya apa?

↩️ The user replied to this earlier message from @alice:
> harga naik 12% bulan ini
```

When the user quotes a passage, only that excerpt is included. Replies to the
bot's own messages are labelled as such (“your earlier message”), which keeps
follow-ups like “lanjutkan” or “yang tadi maksudnya apa” unambiguous. If the
quoted message is a photo or file, it is downloaded and described exactly like
an attachment in the current message; a quoted message with nothing readable
(service messages, stickers) adds nothing. Quotes longer than Telegram's 4096
character message limit are truncated with a visible `(truncated)` marker.

#### Per-topic personas (forum topics)

Every Telegram forum topic gets its own session, and now it can also get its
own **persona**: a model plus a system prompt that applies only to that topic.
The bot must be an admin in the group (or have privacy mode disabled) to see
the `forum_topic_created` service message that starts the wizard.

When a new topic is created the bot sends a three-step wizard:

```
🧬 Setup persona untuk topic ini

Langkah 1/3 — Pilih model preset:
  • primary ★ (default) — deepseek-v4.1-flash
  • fast — deepseek-v4-pro
[ primary ★ ] [ fast ]
[ Pakai default ]

Langkah 2/3 — Kirim system prompt (balas dengan teks):
[ Lewati / pakai default ]

Langkah 3/3 — Preview:
  Model : primary (`deepseek-v4.1-flash`)
  Prompt: Kamu adalah asisten trading. Jawab singkat, fokus data.
[ ✅ Simpan ] [ ✏️ Ulangi ] [ ❌ Batal ]
```

The system prompt is typed as a normal chat message while the wizard is on
step 2. It is intercepted and never reaches the agent. The wizard expires after
15 minutes, and the topic falls back to the default persona if you leave it.

Commands:

| Command | Description |
|---------|-------------|
| `/persona` | Open the setup wizard (or replace the current persona) |
| `/persona show` | Show the active persona for this topic |
| `/persona reset` | Remove the persona and return to the default model/prompt |
| `/cancel` | Leave the wizard without saving |

Personas are stored in `<workspace>/personas.json`, keyed by
`"<chat_id>:<thread_id>"`, so they survive restarts and can be edited by hand:

```json
{
  "-1001234567890:42": {
    "name": "trading",
    "preset": "primary",
    "system_prompt": "Kamu adalah asisten trading. Jawab singkat, fokus data.",
    "created_at": "2026-02-11T10:00:00Z"
  }
}
```

Notes:

- The persona picker lists the configured model presets and always includes the
  primary preset. It no longer asks for a raw model id.
- The General topic (`thread_id == nil`) always uses the global/default persona.
- A persona preset that no longer exists falls back to the primary preset with
  a warning instead of breaking the topic.
- Memory (`MEMORY.md`) and skills are still shared by all topics. Only the
  preset and system prompt are per-topic.
- `/new` clears the conversation and any per-session preset switch, but keeps the
  topic persona.

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
`name`, `model`, `max_tokens`, `temperature`, `max_rounds`, and
individual tool enable/disable settings.

```yaml
---
name: Rubot
model: gpt-4o-mini
max_tokens: 4096
temperature: 0.7
max_rounds: 50
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

The bot uses the memory tool to `read`, `append`, and `update_section`. This
lets it remember information across sessions. (A full `write` replaces the
whole file and is deliberately not exposed, so the bot can never erase its
memory.)

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

Every line of `MEMORY.md` is sent with every request, so Rubot keeps it
bounded instead of letting it grow forever:

- **Batched extraction** — the bot extracts facts from user messages in
  batches (`memory.extract_every`, default 3) instead of spending one extra
  provider request per message, and it does so after the answer has been sent.
- **Consolidation** — after each extraction the file is deduplicated
  ("User communicates in casual Indonesian" and its paraphrases collapse into
  one line) and each section is capped: Facts 25, Preferences 15, Context 10,
  Learned Corrections 10 entries.
- **Archive** — entries that fall past a cap are appended to
  `MEMORY_ARCHIVE.md` next to the memory file. That file is never injected into
  a prompt, so nothing is lost but nothing is paid for either.

```yaml
agents:
  defaults:
    memory:
      extract_every: 3    # user messages per extraction request; 0 disables it
      consolidate: true   # merge duplicates and enforce the section caps
```

### `personas.json` — Per-topic Personas

Telegram forum topics can override the model and system prompt via
`<workspace>/personas.json`. The file is managed by the `/persona` wizard but is
plain JSON, so it can also be edited by hand. See the Telegram section above for
the format and the fallback rules.

### `model_catalog.json` — Provider Model Cache

The provider's `/models` response (for example every model available through
OpenCode Go) is cached here so the picker works even when the provider is
temporarily unreachable. It is safe to delete; the next `/models` or `/persona`
command refreshes it.

## Tools

Rubot comes with 5 built-in tools:

### `shell_exec`
Execute shell commands. The LLM can run commands and see their output.
Dangerous commands like `rm -rf /` are blocked.

New scripts and one-off snippets are written in Ruby (`ruby -e '...'` or a
`.rb` file). A built-in `Scripting Language` rule in the system prompt says so,
and it sits outside the configurable prompt so a per-topic persona cannot drop
it. Python that already exists in a repo or skill (`tools/*.py`) is still run
as-is; only *new* code has to be Ruby.

### `file_ops`
File operations: read, write, append, list directories, get file info.

### `web_fetch`
Fetch content from URLs via HTTP GET.

HTML pages are converted to plain text before they enter the conversation:
scripts, styles, comments, and tags are stripped, the document title is kept,
and entities are decoded. JSON and other non-HTML bodies are passed through
unmodified. Everything is truncated to 5,000 characters after stripping, so the
budget is spent on content instead of markup.

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
│       ├── persona.rb     # Per-topic persona value object
│       ├── persona_store.rb # personas.json load/save/lookup
│       ├── model_catalog.rb # Provider /models catalog + cache
│       ├── memory.rb      # MEMORY.md persistent memory
│       ├── agents_file.rb # AGENTS.md config & rules parser
│       ├── image_info.rb  # Image dimensions from file headers (no deps)
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
mkdir -p ~/.rubot/workspace/kanyaah ~/.rubot/workspace/by.adipurnm
mkdir -p ~/.rubot/workspace/kanyaah.com ~/.rubot/workspace/by.adipurnm.com
mkdir -p ~/.rubot/workspace/skills/{adipurnm-brand,kanyaah-brand,marketing-strategist,writing}
docker compose build
docker compose run --rm rubot init
vim ~/.rubot/config.yml   # set your API key / Telegram token
```

With the local override, host data lives in `~/.rubot` and is mounted onto
`/home/rubot/.rubot` in the container. The brand content directories and the
website repos are mounted inside the agent workspace so the safety guard
allows read/write access:

| Host | Container |
|---|---|
| `~/.rubot` | `/home/rubot/.rubot` |
| `~/Documents/work/freelance/brand/kanyaah` | `/home/rubot/.rubot/workspace/kanyaah` |
| `~/Documents/work/freelance/brand/by.adipurnm` | `/home/rubot/.rubot/workspace/by.adipurnm` |
| `~/Documents/work/freelance/website/kanyaah.com` | `/home/rubot/.rubot/workspace/kanyaah.com` |
| `~/Documents/work/freelance/website/by.adipurnm.com` | `/home/rubot/.rubot/workspace/by.adipurnm.com` |
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
configuration. It bind-mounts `~/.rubot`, the two brand directories, the two
website repos (so the bot reads facts like templates and prices locally
instead of guessing), and the four Squadron skills, and runs as your UID/GID
so sessions, `MEMORY.md`, cron jobs, and edited files stay owned by you. It defaults to
`-C telegram`; remove its
`command:` block (or run `docker compose run --rm rubot -C repl`) for the
REPL.

A tracked template is available as `docker-compose.override.yml.example`:

```bash
mkdir -p ~/.rubot/workspace/kanyaah ~/.rubot/workspace/by.adipurnm
mkdir -p ~/.rubot/workspace/kanyaah.com ~/.rubot/workspace/by.adipurnm.com
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
- The image ships `node`, `chromium` (headless shell), `magick` (ImageMagick 7)
  and a static `ffmpeg` on top of Ruby. The brand/carousel skills need them:
  Chromium screenshots the HTML at 2×, `magick -resize` downsamples to the
  final size (e.g. `magick cover@2x.png -resize 1080x1920 -strip cover.png`),
  and `ffmpeg` encodes reels. They are installed at build time because the
  agent cannot install packages on the fly and the safety guard blocks `PATH`
  exports.
- Four size decisions worth knowing before you change the image:
  - `chromium-headless-shell` (not `chromium`) provides a `chromium` and
    `chromium-browser` symlink. Every render path here is headless — carousel
    `render.sh` drives the binary CLI and the `instagram-feed`/`featured`
    scripts drive it through `puppeteer-core` with `headless: "new"`. That
    drops the GTK/Adwaita/X11 toolkit, ~290 MB off the image.
  - `ffmpeg` is the static build (pinned by version and sha256 in the
    Dockerfile). It replaces the Debian `ffmpeg` package and its ~450 MiB of
    libav*/x265/aom dependencies while behaving the same (`libx264`, `aac`,
    `ffprobe`).
  - `curl`, `jq` and `ripgrep` are installed (~19 MiB total): repo tooling
    shells out to `curl` (Kanyaah's `featured-image/generate.sh` polls a local
    preview server with it) and the agent reaches for `jq`/`rg` constantly.
    Not included: `python3`, `rsvg-convert` and `git` — see the workspace notes
    below if a pipeline needs them.
  - The GPU stack is purged after `apt-get install`: `mesa-libgallium` (41 MiB),
    `libllvm19` (124 MiB) and `libz3-4` (27 MiB), plus the Vulkan validation
    layer (23 MiB). Every render passes `--disable-gpu`, so none of it is ever
    loaded; renders were compared byte for byte before and after (`sha256sum`
    identical, CLI and puppeteer). Side effect: `libgbm1` has an unmet
    dependency, so **do not run `apt-get -f install` or `apt-get autoremove`**
    in this image — it would remove `libgbm1` and then chromium. Add packages by
    rebuilding.
  - Anything deleted must be deleted **in the same `RUN`** as the install that
    created it. A `dpkg --purge` in its own `RUN` only hides the files from the
    final filesystem view; the bytes stay in the earlier layer and the image
    does not shrink.
- No `npm`/`npx` in the image. `node_modules` comes from the mounted repos
  (`kanyaah.com/tools/featured-image/node_modules`), installed on the host. The
  packages there are pure JS, so a host-installed tree works with the
  container's Node. If a dependency changes, run `npm install` on the host.
  The Kanyaah `instagram-feed` scripts borrow `puppeteer-core` from that folder
  and hardcode four `..` levels, which only holds in the host layout — inside
  the container set `KANYAAH_SITE=/home/rubot/.rubot/workspace/kanyaah.com`.
  The official Node tarball was measured as an alternative to the Debian
  `nodejs` package and is *not* smaller (single 100 MB binary vs 53 MiB
  `libnode` + 36 MiB `libicu`), so the distro package stays.
- Gems in the image are `webrick` plus the standard library. Test gems
  are excluded via `BUNDLE_WITHOUT=development:test`.

## Testing

```bash
bundle install
bundle exec rake test
```

The suite runs with `HOME` pointed at a throwaway directory (see
`test/test_helper.rb`) and every test workspace is a temp dir, so running tests
never reads or writes your real `~/.rubot` — use `isolated_config(dir)` instead
of plain `Config.new` in new tests.

## License

MIT
