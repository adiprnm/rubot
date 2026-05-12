# frozen_string_literal: true

require "json"

module Rubot
  # Raised when a provider returns HTTP 429 Too Many Requests.
  class RateLimitError < StandardError
    attr_reader :retry_after

    def initialize(retry_after = nil)
      @retry_after = retry_after
      super("Rate limited (429 Too Many Requests)")
    end
  end

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

    # Wrap a block that performs an HTTP request. Retries on 429 with
    # exponential backoff (respects Retry-After header if present).
    def with_retry(max_retries: 3)
      attempts = 0
      begin
        yield
      rescue RateLimitError => e
        attempts += 1
        raise if attempts > max_retries
        wait_time = e.retry_after || exponential_backoff(attempts)
        log_debug("Rate limited (429). Retrying in #{wait_time}s (attempt #{attempts}/#{max_retries})")
        sleep wait_time
        retry
      end
    end

    # Parse the Retry-After header from a response. Returns seconds as
    # Integer, or nil if not present / not parseable.
    def parse_retry_after(response)
      header = response["Retry-After"]
      return nil unless header
      val = header.to_i
      val > 0 ? val : nil
    end

    # Exponential backoff with small jitter: 1s, 2s, 4s, ...
    def exponential_backoff(attempt)
      base = 2**(attempt - 1)
      jitter = rand * 0.5
      (base + jitter).round(2)
    end

    def log_debug(msg)
      warn "[debug][#{name}] #{msg}" if @config.debug?
    end
  end
end
