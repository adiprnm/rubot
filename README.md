# 🤖 Rubot - AI Assistant in Ruby

> Personal AI assistant written in pure Ruby — no dependencies required.

Rubot is a lightweight, terminal-based AI assistant inspired by [NanoBot](https://github.com/HKUDS/nanobot) and [PicoClaw](https://github.com/sipeed/picoclaw). It connects to LLM providers (OpenAI, Anthropic, Ollama, or any OpenAI-compatible API) and executes tool calls — all using only Ruby's standard library.

## Features

- 🪶 **Zero dependencies** — only Ruby standard library
- 🔌 **Multiple providers** — OpenAI, Anthropic, Ollama, or any OpenAI-compatible API
- 🛠️ **Built-in tools** — shell execution, file operations, web fetching
- 💬 **Interactive REPL** — with streaming, command history, and tab completion
- 📝 **Session management** — persistent conversation history
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
| `/info` | Show agent info |
| `/tools` | List available tools |
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

## Tools

Rubot comes with 3 built-in tools:

### `shell_exec`
Execute shell commands. The LLM can run commands and see their output.
Dangerous commands like `rm -rf /` are blocked.

### `file_ops`
File operations: read, write, append, list directories, get file info.

### `web_fetch`
Fetch content from URLs via HTTP GET.

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
