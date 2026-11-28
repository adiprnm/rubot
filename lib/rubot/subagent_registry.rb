# frozen_string_literal: true

module Rubot
  # Built-in sub agents. These are not user personas: they live in code, are
  # never written to personas.json, and never appear in a sidebar, a /delegates
  # list or a Telegram topic picker. They exist only as targets for `delegate`.
  #
  # Each entry is a plain Hash in the same shape as a persona record, so the
  # existing Persona value object and sub-agent builder can consume it as-is.
  # `allowed_tools` is the one extra key: it narrows the tool set the sub agent
  # may call, on top of the global SUBAGENT_FORBIDDEN_TOOLS.
  module SubagentRegistry
    # A role's tools are its capability: a role that must not write simply has
    # no `file_write` in its list, and there is nothing else to keep correct.
    # The reading tools (file_read, search, web_fetch) answer `writes?` with
    # false, so a list made only of them is read-only; a writing role adds
    # `file_write` and, because it has to produce and verify its work, shell.
    #
    # Shell is never part of a read-only list: a shell command can write any
    # file, so there is no read-only shell. A reviewer that needs a diff is given
    # it in the task, not a shell to produce it.
    READ_TOOLS = %w[file_read search web_fetch].freeze
    CODE_TOOLS = %w[file_read file_write search shell_exec].freeze
    LOOKUP_TOOLS = %w[file_read search].freeze

    DEFINITIONS = [
      {
        "slug" => "code_reviewer",
        "internal" => true,
        "name" => "Code Reviewer",
        "emoji" => "🔍",
        "preset" => "flash",
        "thinking" => "low",
        "allowed_tools" => LOOKUP_TOOLS,
        "system_prompt" => <<~PROMPT.strip
          You are a code reviewer. Read the diff or files you are given and report
          findings only: bugs, security issues, and style inconsistencies. Order
          findings by severity, each with file, line, and a one-line fix. You have
          no write access: report what should change, never change it yourself.
          Keep the answer short and scannable.
        PROMPT
      },
      {
        "slug" => "debugger",
        "internal" => true,
        "name" => "Debugger",
        "emoji" => "🐛",
        "preset" => "flash",
        "thinking" => "low",
        "allowed_tools" => LOOKUP_TOOLS,
        "system_prompt" => <<~PROMPT.strip
          You are a debugger. Given an error, log, or failing behaviour, find the
          most likely cause and propose the smallest fix. Show the evidence you
          relied on. If you cannot reproduce it, say what you would check next.
          Keep the answer short and concrete.
        PROMPT
      },
      {
        "slug" => "implementer",
        "internal" => true,
        "name" => "Implementer",
        "emoji" => "🛠️",
        "preset" => "primary",
        "thinking" => "medium",
        "allowed_tools" => CODE_TOOLS,
        "system_prompt" => <<~PROMPT.strip
          You are an implementer. Make the change you were asked for and stop
          there. Read AGENTS.md and the files involved before editing anything.
          Keep the diff small: change what the task needs, and leave unrelated
          code, comments and formatting alone. Follow the conventions the
          repository already uses, including any stated RuboCop baseline. Do not
          commit, do not push, and do not rename commands, payload keys or
          callback data unless the task says to. Run the relevant tests and
          report the command and its exit code. If a test fails and the fix is
          not obvious, say what fails and stop rather than widening the change.
          Finish with a short list of the files you touched and why.
        PROMPT
      },
      {
        "slug" => "researcher",
        "internal" => true,
        "name" => "Researcher",
        "emoji" => "📚",
        "preset" => "flash",
        "thinking" => "low",
        "allowed_tools" => %w[web_fetch],
        "system_prompt" => <<~PROMPT.strip
          You are a researcher. Use web_fetch to find documentation or references
          for the given question. Summarise the answer and include the source URL
          for each claim. Do not modify files. If you cannot verify something,
          say so plainly. Keep the answer short.
        PROMPT
      },
      {
        "slug" => "test_writer",
        "internal" => true,
        "name" => "Test Writer",
        "emoji" => "🧪",
        "preset" => "flash",
        "thinking" => "low",
        "allowed_tools" => CODE_TOOLS,
        "system_prompt" => <<~PROMPT.strip
          You are a test writer. Write Ruby minitest cases for the given code,
          run them, and report the result. Cover the happy path and the obvious
          edge cases. Do not change production code. Keep the answer short and
          include the test command you ran.
        PROMPT
      },
      {
        "slug" => "docs_writer",
        "internal" => true,
        "name" => "Docs Writer",
        "emoji" => "📝",
        "preset" => "flash",
        "thinking" => "low",
        "allowed_tools" => CODE_TOOLS,
        "system_prompt" => <<~PROMPT.strip
          You are a documentation writer. Write clear English README and AGENTS.md
          sections. Prefer short sentences and simple structure. Do not use em
          dashes, en dashes, or hyphens in prose; use commas, periods, or words
          instead. Keep the answer short and ready to paste.
        PROMPT
      },
      {
        "slug" => "planner",
        "internal" => true,
        "name" => "Planner",
        "emoji" => "🧭",
        "preset" => "flash",
        "thinking" => "low",
        "allowed_tools" => READ_TOOLS,
        "system_prompt" => <<~PROMPT.strip
          You are a planner. Break the given task into concrete, ordered steps
          that another agent can execute. Do not modify files. Note the risk or
          dependency for each step. Keep the answer short and actionable.
        PROMPT
      }
    ].freeze

    # Session actors run in non-main Ractors, which may only read shareable
    # constants. Freeze the whole tree recursively so a sub agent lookup from
    # inside an actor does not raise Ractor::IsolationError.
    Ractor.make_shareable(DEFINITIONS) if defined?(Ractor)

    # The slugs a lead agent may name, for the delegation prompt.
    def self.slugs
      DEFINITIONS.map { |d| d["slug"] }.freeze
    end

    def self.[](slug)
      definition = find(slug)
      return nil unless definition

      definition.reject { |key, _| key == "allowed_tools" }
    end

    # The tools a role may call. A role definition that names none is an error
    # rather than "everything": the list is the whole declaration of what the
    # role can do, so a forgotten one has to fail loudly.
    def self.allowed_tools(slug)
      definition = find(slug)
      raise ArgumentError, "sub agent role #{slug.inspect} is not defined" if definition.nil?

      allowed = definition["allowed_tools"]
      if !allowed.is_a?(Array) || allowed.empty?
        raise ArgumentError, "sub agent role #{slug.inspect} names no tools; add an allowed_tools list"
      end

      allowed
    end

    def self.find(slug)
      DEFINITIONS.find { |d| d["slug"] == slug.to_s.strip.downcase }
    end
  end
end
