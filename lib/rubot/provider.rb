# frozen_string_literal: true

require "json"

module Rubot
  # Base class for all LLM providers.
  # Subclasses must implement #chat(messages, tools: nil)
  class Provider
    attr_reader :config

    def initialize(config)
      @config = config
    end

    # Main chat interface. Returns the assistant's response string.
    #
    # messages - Array of message hashes with role/content keys
    # tools    - Optional array of tool definitions (or nil)
    #
    # Returns the assistant's text response.
    def chat(messages, tools: nil)
      raise NotImplementedError, "#{self.class} must implement #chat"
    end

    # Convert Rubot tool definitions to the provider's native tool format.
    def format_tools(tools)
      tools.map { |t| t.to_provider_format(self.class.name.split("::").last.downcase) }
    end

    # Parse a streaming response line. Returns nil to continue, or the
    # accumulated text when the stream is complete.
    def parse_stream_chunk(line)
      raise NotImplementedError, "#{self.class} must implement #parse_stream_chunk"
    end

    def name
      self.class.name.split("::").last.downcase
    end

    protected

    def log_debug(msg)
      warn "[debug][#{name}] #{msg}" if @config.debug?
    end
  end
end
