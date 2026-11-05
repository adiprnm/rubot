# frozen_string_literal: true

require "json"
require "net/http"

module Rubot
  # Immutable view of the settings needed to construct a provider.
  # Providers only need these methods, so they can be built without
  # mutating (and without sharing) the live Config object.
  class ProviderSettings
    attr_reader :provider, :model, :api_key, :api_base, :max_tokens, :temperature, :extra_headers

    def initialize(provider:, model:, api_key:, api_base:, max_tokens:, temperature:, debug: false, extra_headers: {})
      @provider = provider
      @model = model
      @api_key = api_key
      @api_base = api_base
      @max_tokens = max_tokens
      @temperature = temperature
      @debug = debug
      @extra_headers = (extra_headers || {}).dup.freeze
      freeze
    end

    def debug?
      @debug
    end
  end

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
    # Network failures that usually clear up on a retry. A read timeout often
    # just means the provider stalled while generating, and a fresh request
    # normally succeeds.
    TRANSIENT_ERRORS = [
      Net::ReadTimeout,
      Net::OpenTimeout,
      Net::WriteTimeout,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::EPIPE,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
      SocketError,
      EOFError
    ].freeze

    attr_reader :config, :last_usage

    # Build the provider implementation for an immutable ProviderSettings.
    # Kept here so callers (Agent, ModelCatalog) share one mapping.
    def self.build(settings)
      case settings.provider.to_s.downcase
      when "openai", "openai_compatible", "azure", "deepseek", "groq", "gemini", "mistral", "perplexity"
        Providers::OpenAI.new(settings)
      when "anthropic", "claude"
        Providers::Anthropic.new(settings)
      when "ollama"
        Providers::Ollama.new(settings)
      else
        warn "Unknown provider '#{settings.provider}', falling back to OpenAI-compatible"
        Providers::OpenAI.new(settings)
      end
    end

    def initialize(config)
      @config = config
      @last_usage = nil
    end

    # The provider's usage hash for the most recent request, or nil.
    # Providers reset this at the start of every chat/chat_stream call.
    def reset_last_usage!
      @last_usage = nil
    end

    # Return the provider's supported models as an array of hashes with at
    # least an "id" key. Providers that cannot list models return [] and the
    # caller falls back to config.yml entries.
    def list_models
      []
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

    # Remember the raw usage hash returned by the provider. The Agent
    # normalizes it into a Rubot::Usage.
    def track_usage(raw)
      @last_usage = raw if raw.is_a?(Hash) && !raw.empty?
      @last_usage
    end

    # Wrap a block that performs an HTTP request. Retries on 429 with
    # exponential backoff (respects Retry-After header if present), and on
    # transient network errors (timeouts, connection resets, ...).
    #
    # retryable - optional callable; when it returns false the error is
    #             re-raised instead of retried. Streaming providers use this
    #             to avoid replaying a response that was already delivered.
    def with_retry(max_retries: 3, max_network_retries: 2, retryable: nil)
      attempts = 0
      network_attempts = 0
      begin
        yield
      rescue RateLimitError => e
        attempts += 1
        raise if attempts > max_retries
        raise if retryable && !retryable.call

        wait_time = e.retry_after || exponential_backoff(attempts)
        log_debug("Rate limited (429). Retrying in #{wait_time}s (attempt #{attempts}/#{max_retries})")
        sleep wait_time
        retry
      rescue *TRANSIENT_ERRORS => e
        network_attempts += 1
        raise if network_attempts > max_network_retries
        raise if retryable && !retryable.call

        wait_time = exponential_backoff(network_attempts)
        log_debug("#{e.class}: #{e.message}. Retrying in #{wait_time}s " \
                  "(attempt #{network_attempts}/#{max_network_retries})")
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
