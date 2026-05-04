# frozen_string_literal: true

require "yaml"

module Rubot
  # Manages AGENTS.md — machine-readable agent configuration in YAML frontmatter
  # plus human-readable behavior rules in the markdown body.
  #
  # Format:
  #   ---
  #   name: Rubot
  #   model: gpt-4o-mini
  #   max_tokens: 4096
  #   temperature: 0.7
  #   max_tool_iterations: 50
  #   tools:
  #     exec: true
  #     file_ops: true
  #     web_fetch: true
  #   ---
  #
  # # Agent Rules
  # - Always explain commands before executing
  # - Be concise in responses
  class AgentsFile
    attr_reader :frontmatter, :body, :file_path, :raw

    def initialize(workspace: nil)
      @workspace = workspace
      @file_path = workspace ? File.join(workspace, "AGENTS.md") : nil
      @frontmatter = {}
      @body = ""
      @raw = ""
      load!
    end

    def enabled?
      !@raw.empty?
    end

    # Agent name from frontmatter
    def name
      @frontmatter["name"]
    end

    # Model name from frontmatter
    def model
      @frontmatter["model"]
    end

    # Max tokens from frontmatter
    def max_tokens
      @frontmatter["max_tokens"]
    end

    # Temperature from frontmatter
    def temperature
      @frontmatter["temperature"]
    end

    # Max tool iterations from frontmatter
    def max_tool_iterations
      @frontmatter["max_tool_iterations"]
    end

    # Tools config from frontmatter (hash of tool_name => enabled)
    def tools_config
      @frontmatter["tools"] || {}
    end

    # The markdown body (behavior rules) — used as additional system prompt
    def rules
      @body.strip
    end

    private

    def load!
      return unless @file_path && File.exist?(@file_path)
      @raw = File.read(@file_path)
      parse!
    rescue Errno::ENOENT, Errno::EACCES
      @raw = ""
    end

    def parse!
      # Extract YAML frontmatter
      if @raw.start_with?("---\n") || @raw.start_with?("---\r\n")
        parts = @raw.lines
        first_end = parts[1..].index { |l| l.strip == "---" }

        if first_end
          yaml_content = parts[1..first_end].join
          @frontmatter = YAML.safe_load(yaml_content) || {}
          @body = parts[(first_end + 2)..].join
        else
          @body = @raw
        end
      else
        @body = @raw
      end
    end
  end
end
