# 🤖 Rubot - AI Assistant in Ruby

> Personal AI assistant written in pure Ruby — no dependencies required.

Rubot is a lightweight, terminal-based AI assistant inspired by [NanoBot](https://github.com/HKUDS/nanobot) and [PicoClaw](https://github.com/sipeed/picoclaw). It connects to LLM providers (OpenAI, Anthropic, Ollama, or any OpenAI-compatible API) and executes tool calls — all using only Ruby's standard library.

## Features

- 🪶 **Zero dependencies** — only Ruby standard library
- 🔌 **Multiple providers** — OpenAI, Anthropic, Ollama, or any OpenAI-compatible API
- 🛠️ **Built-in tools** — shell execution, file operations, web fetching, persistent memory
- 💬 **Interactive REPL** — with streaming, command history, and tab completion
- 📝 **Session management** — persistent conversation history
- 🧬 **SOUL.md** — personality and identity file for persistent character
- 📋 **AGENTS.md** — YAML frontmatter config + markdown behavior rules
- 🧠 **MEMORY.md** — persistent memory the bot can read and update across sessions
- 🎛️ **CLI options** — single-message mode or interactive chat
- 🔒 **Tool safety** — dangerous command filtering

## Requirements

- Ruby 3.0+

## Installation

Clone the repository and add `bin/` to your PATH:

```bash
git clone https://github.com/yourname/rubot.git
cd rubot
export PATH="$PWD/bin:$PATH"  # or add to ~/.bashrc
```

Or just run directly:

```bash
ruby bin/rubot --help
```

## Quick Start

### 1. Configure

Copy the example config and set your API key:

```bash
mkdir -p ~/.rubot
cp config/rubot.example.yml ~/.rubot/config.yml
# Edit the file and set your API key
vim ~/.rubot/config.yml
```

Or use environment variables:

```bash
export RUBOT_API_KEY="sk-your-key-here"
```

### 2. Run

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
| `/session [name]` | Show or switch session |
| `/info` | Show agent info (includes soul/memory status) |
| `/tools` | List available tools |
| `/soul` | Show the bot's soul (SOUL.md) |
| `/memory` | Show persistent memory (MEMORY.md) |
| `/agents` | Show agent rules (AGENTS.md) |
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
| `-v, --version` | Show version |
| `-C, --channel CHANNEL` | Channel to use: repl, telegram (default: repl) |
| `-h, --help` | Show help |

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

Rubot comes with 4 built-in tools:

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

## Project Structure

```
rubot/
├── bin/
│   └── rubot              # Main executable
├── lib/
│   ├── rubot.rb           # Entry point
│   └── rubot/
│       ├── agent.rb       # Agent loop (process messages, call tools)
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
│       │   └── registry.rb # Tool registry
│       └── repl.rb        # REPL interface
├── config/
│   └── rubot.example.yml # Example config
├── test/                  # Minitest tests
├── Gemfile                # Only for testing deps
├── Rakefile               # Test runner
└── README.md
```

## Testing

```bash
bundle install
bundle exec rake test
```

## License

MIT
