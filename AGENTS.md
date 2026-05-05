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

# Agent Rules

- Be concise and direct in responses. No fluff.
- Explain what you're doing before executing commands.
- Use tools when they can help accomplish the task.
- Remember important details by using the memory tool.

## Code Conventions

- Ruby 3.0+ compatible; use modern syntax where appropriate.
- Always use `# frozen_string_literal: true` at the top of every `.rb` file.
- Follow RuboCop rules defined in `.rubocop.yml`.
- Prefer small, composable methods over large monolithic ones.
- Use keyword arguments for methods with more than 2 parameters.
- Keep classes and modules in the `Rubot` namespace.

## Architecture

- **Providers** (`lib/rubot/providers/`) — LLM API adapters (OpenAI, Anthropic, Ollama).
- **Channels** (`lib/rubot/channels/`) — Communication interfaces (REPL, Telegram). Add new channels by subclassing `Rubot::Channel`.
- **Tools** (`lib/rubot/tools/`) — Capabilities the agent can use (shell, file, web, memory). Add new tools by subclassing `Rubot::Tool`.
- **Core** (`lib/rubot/agent.rb`, `lib/rubot/session.rb`) — Agent loop and conversation state.
- **Zero runtime dependencies** — only Ruby standard library. Tests use minitest.

## Testing

- Run `bundle exec rake test` — all tests must pass before committing.
- New features should include tests in `test/`.
- Minitest with descriptive method names: `def test_feature_does_something`.
