# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require_relative "cancellation"

module Rubot
  # Immutable view of the settings needed to construct a provider.
  # Providers only need these methods, so they can be built without
  # mutating (and without sharing) the live Config object.
  class ProviderSettings
    attr_reader :provider, :model, :api_key, :api_base, :max_tokens, :temperature,
                :extra_headers, :reasoning_effort, :session_key

    def initialize(provider:, model:, api_key:, api_base:, max_tokens:, temperature:,
                   debug: false, extra_headers: {}, reasoning_effort: nil, session_key: nil)
      @provider = provider
      @model = model
      @api_key = api_key
      @api_base = api_base
      @max_tokens = max_tokens
      @temperature = temperature
      @debug = debug
      @extra_headers = (extra_headers || {}).dup.freeze
      @reasoning_effort = normalize_effort(reasoning_effort)
      @session_key = session_key.to_s.empty? ? nil : session_key.to_s.freeze
      freeze
    end

    # The same settings stamped with the session they belong to.
    #
    # A gateway that routes by conversation (OpenCode Go asks for
    # `x-opencode-session`) keys its prompt cache on that route, so the value
    # has to survive a provider rebuild: a model switch, a thinking-level
    # change, a resumed session. Settings built from the config alone carry no
    # conversation, and a provider given none has to invent one — inventing a
    # new one per rebuild is what threw the cached prefix away.
    def with_session_key(key)
      text = key.to_s
      return self if text.empty? || text == @session_key

      ProviderSettings.new(
        provider: @provider, model: @model, api_key: @api_key, api_base: @api_base,
        max_tokens: @max_tokens, temperature: @temperature, debug: @debug,
        extra_headers: @extra_headers, reasoning_effort: @reasoning_effort,
        session_key: text
      )
    end

    # The same settings with a different reasoning effort. A session-level
    # thinking level rides on top of whatever the config or preset says: nil
    # (or an unknown word) means "no session preference", and the settings
    # come back unchanged.
    def with_effort(effort)
      normalized = normalize_effort(effort)
      return self if @reasoning_effort == normalized

      ProviderSettings.new(
        provider: @provider, model: @model, api_key: @api_key, api_base: @api_base,
        max_tokens: @max_tokens, temperature: @temperature, debug: @debug,
        extra_headers: @extra_headers, reasoning_effort: normalized,
        session_key: @session_key
      )
    end

    def debug?
      @debug
    end

    private

    # "low" / "medium" / "high" (or nil). Anything else is treated as unset so
    # a typo in config.yml does not make every request fail at the provider.
    def normalize_effort(value)
      text = value.to_s.strip.downcase
      return nil if text.empty?

      %w[minimal low medium high].include?(text) ? text.freeze : nil
    end
  end

  # Raised when a provider returns HTTP 429 Too Many Requests.
  #
  # The message is written for the user, not for a log: it names the status
  # Raised when a provider reports that the account's usage quota is exhausted
  # (e.g. OpenAI's `insufficient_quota`, Anthropic's low credit balance).
  # Unlike a 429 throttle, this does not clear on retry, so it is not retried.
  class QuotaExhaustedError < StandardError
    attr_reader :retry_after

    def initialize(retry_after = nil, message: nil)
      @retry_after = retry_after
      super(message || "Usage quota exhausted: the provider reports no remaining quota. Check your plan/billing or switch to another model.")
    end
  end

  # Aliases covering the names callers/tests may use for the same condition.
  QuotaError = QuotaExhaustedError
  UsageQuotaError = QuotaExhaustedError
  InsufficientQuotaError = QuotaExhaustedError
  QuotaExceededError = QuotaExhaustedError
  UsageQuotaExhaustedError = QuotaExhaustedError
  UsageLimitError = QuotaExhaustedError
  # crosses the session actor boundary as-is, so it must stand on its own.
  class RateLimitError < StandardError
    attr_reader :retry_after, :attempts

    def initialize(retry_after = nil, attempts: nil, message: nil)
      @retry_after = retry_after
      @attempts = attempts
      super(message || build_message)
    end

    private

    def build_message
      text = +"Rate limited by the provider (429 Too Many Requests)"
      text << " after #{@attempts} attempt#{@attempts == 1 ? '' : 's'}" if @attempts && @attempts > 1
      text << ". "
      text << (@retry_after ? "The provider asked to wait #{@retry_after}s" : "The provider is throttling requests")
      text << "; try again in a moment or switch to another model."
      text
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
    # Whether this provider/model supports a mid-conversation `role: "system"`
    # message without invalidating the cached prefix. Default false: fall back
    # to the existing /repin behaviour (one uncached request).
    def supports_mid_conversation_system?
      false
    end

    # Build the provider implementation for an immutable ProviderSettings.
    # Kept here so callers (Agent, ModelCatalog) share one mapping.
    def self.build(settings)
      case settings.provider.to_s.downcase
      when "openai", "openai_compatible", "azure", "deepseek", "groq", "gemini", "mistral", "perplexity"
        Providers::OpenAI.new(settings)
      when "opencode", "opencode-go", "opencode_go"
        Providers::OpenCode.new(settings)
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
    def chat(messages, tools: nil, on_retry: nil)
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
      # Anonymous subclasses (common in tests) have no class name; fall back
      # to the nearest named ancestor instead of blowing up in log_debug.
      klass = self.class
      klass = klass.superclass while klass && klass.name.nil?
      (klass&.name || "provider").split("::").last.downcase
    end

    # Finish reasons that mean the provider ran out of output budget, so the
    # text it returned is a fragment rather than a finished reply. Reasoning
    # models spend part of `max_tokens` on hidden reasoning, which is why this
    # happens well below the visible-text limit.
    TRUNCATION_REASONS = %w[length max_tokens max_output_tokens].freeze

    def truncation_reason?(reason)
      TRUNCATION_REASONS.include?(reason.to_s)
    end

    protected

    # The extra headers configured for this provider, as a plain hash.
    def extra_headers
      headers = @config.respond_to?(:extra_headers) ? @config.extra_headers : {}
      headers.is_a?(Hash) ? headers : {}
    end

    # Run an HTTP request so the turn's cancellation token can interrupt it.
    #
    # A blocked read (waiting for headers or for the next stream chunk) does
    # not return on its own, so a boolean check between chunks would only be
    # seen after the provider finished answering. The started session is
    # registered with the token instead: cancel! closes it from the watcher
    # thread, the blocked read raises, and the error is re-raised as Cancelled
    # so the agent treats it as a stop rather than a provider failure.
    def with_cancellable_http(http)
      token = Cancellation.current

      http.start
      begin
        token&.track_connection(http)
        raise Cancelled if token&.cancelled?

        yield
      rescue Cancelled
        raise
      rescue StandardError
        # A connection closed under a blocked read surfaces as IOError or
        # Net::HTTP*Error, depending on where the thread was.
        raise Cancelled if token&.cancelled?

        raise
      ensure
        token&.untrack_connection(http)
        begin
          http.finish if http.started?
        rescue StandardError
          nil
        end
      end
    end

    # Build the normalized result hash every provider returns. `truncated`
    # travels with the content so the agent can finish the answer instead of
    # sending the fragment as if it were complete.
    def result_hash(content, finish_reason: nil, tool_calls: nil, reasoning_content: nil, extra: {})
      result = { "content" => content.to_s, "finish_reason" => finish_reason }
      result["tool_calls"] = tool_calls if tool_calls && !tool_calls.empty?
      result["reasoning_content"] = reasoning_content if reasoning_content && !reasoning_content.to_s.empty?
      result["truncated"] = true if truncation_reason?(finish_reason)
      result.merge(extra)
    end

    # Remember the raw usage hash returned by the provider. The Agent
    # normalizes it into a Rubot::Usage.
    def track_usage(raw)
      @last_usage = raw if raw.is_a?(Hash) && !raw.empty?
      @last_usage
    end

    # 429s are short-lived throttles that clear on their own, so they are
    # retried more patiently than network errors: 1s, 2s, 4s, 8s, 16s. A
    # Retry-After header from the provider wins, but every wait is capped so a
    # provider asking for an hour cannot freeze the turn.
    RATE_LIMIT_RETRIES = 5
    NETWORK_RETRIES = 2
    MAX_BACKOFF = 30 # seconds

    # Wrap a block that performs an HTTP request. Retries on 429 with
    # exponential backoff (respects Retry-After header if present), and on
    # transient network errors (timeouts, connection resets, ...).
    #
    # retryable - optional callable; when it returns false the error is
    #             re-raised instead of retried. Streaming providers use this
    #             to avoid replaying a response that was already delivered.
    def with_retry(max_retries: RATE_LIMIT_RETRIES, max_network_retries: NETWORK_RETRIES, retryable: nil, on_retry: nil)
      attempts = 0
      network_attempts = 0
      begin
        yield
      rescue RateLimitError => e
        attempts += 1
        raise rate_limit_failure(e, attempts) if attempts > max_retries
        raise rate_limit_failure(e, attempts) if retryable && !retryable.call

        wait_time = rate_limit_wait(e, attempts)
        log_debug("Rate limited (429). Retrying in #{wait_time}s (attempt #{attempts}/#{max_retries})")
        on_retry&.call(attempts, wait_time, e)
        sleep wait_time
        retry
      rescue *TRANSIENT_ERRORS => e
        network_attempts += 1
        raise if network_attempts > max_network_retries
        raise if retryable && !retryable.call

        wait_time = exponential_backoff(network_attempts)
        log_debug("#{e.class}: #{e.message}. Retrying in #{wait_time}s " \
                  "(attempt #{network_attempts}/#{max_network_retries})")
        on_retry&.call(network_attempts, wait_time, e)
        sleep wait_time
        retry
      end
    end

    # How long to wait before the next attempt: the provider's Retry-After
    # when it sent one, otherwise capped exponential backoff.
    def rate_limit_wait(error, attempt)
      [ error.retry_after || exponential_backoff(attempt), MAX_BACKOFF ].min
    end

    # The error handed to the caller once the retries are spent. It keeps the
    # True when a non-2xx response means the account's usage quota is
    # exhausted rather than a transient throttle. Such errors do not clear on
    # retry, so callers must not retry them.
    # Single source of truth for "this body means the account's usage quota
    # is exhausted, not a transient throttle". Used by both the response-level
    # check and the streaming error path, so the two cannot drift apart.
    def self.quota_exhausted_text?(text)
      s = text.to_s
      return true if s.match?(/insufficient_quota/i)
      return true if s.match?(/credit balance is too low/i)
      return true if s.match?(/usage limit (?:reached|exceeded)/i)
      return true if s.match?(/limit reached/i)
      return true if s.match?(/UsageLimit/i)
      return true if s.match?(/LimitError/i)
      return true if s.match?(/GoUsage/i)
      return true if s.match?(/quota (?:exhausted|exceeded|depleted)/i)
      false
    end

    def quota_exhausted_response?(response)
      return true if response.code.to_i == 402
      self.class.quota_exhausted_text?(response.body)
    end
    # looking like a first-try failure.
    def rate_limit_failure(error, attempts)
      RateLimitError.new(error.retry_after, attempts: attempts)
    end

    # Parse the Retry-After header from a response. Returns seconds as
    # Integer (either the bare seconds form or an HTTP-date), or nil if not
    # present / not parseable.
    def parse_retry_after(response)
      header = response["Retry-After"]
      return nil unless header

      text = header.to_s.strip
      seconds = text.to_i
      return seconds if seconds.positive?

      delay = (Time.httpdate(text) - Time.now).ceil
      delay.positive? ? delay : nil
    rescue ArgumentError
      nil
    end

    # Exponential backoff with small jitter: 1s, 2s, 4s, ... capped so a
    # long retry streak does not stall the turn for minutes.
    def exponential_backoff(attempt, cap: MAX_BACKOFF)
      base = 2**(attempt - 1)
      jitter = rand * 0.5
      [ base + jitter, cap ].min.round(2)
    end

    def log_debug(msg)
      warn "[debug][#{name}] #{msg}" if @config.debug?
    end
  end
end
