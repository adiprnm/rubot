# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class TestProviders < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yml")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  # Read one request off the socket, body included. A stub that answers after
  # the headers and closes *without* reading the body leaves the POST payload
  # unread, and closing such a socket makes the kernel answer with RST: the
  # client then sees ECONNRESET mid-response instead of the data the stub just
  # wrote. That made the streaming tests fail about half the time when the
  # suite ran in parallel.
  def read_request(client)
    headers = {}
    while (line = client.gets)
      break if line == "\r\n"

      name, value = line.split(":", 2)
      headers[name.to_s.strip.downcase] = value.to_s.strip
    end
    length = headers["content-length"].to_i
    client.read(length) if length.positive?
    headers
  end

  # A throwaway HTTP server that answers every request with the same body.
  def with_stub_server(body)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      loop do
        client = server.accept
        read_request(client)

        client.write("HTTP/1.1 200 OK\r\n")
        client.write("Content-Type: application/json\r\n")
        client.write("Content-Length: #{body.bytesize}\r\n")
        client.write("Connection: close\r\n\r\n")
        client.write(body)
      ensure
        client&.close
      end
    rescue IOError, Errno::EBADF
      nil
    end

    yield "http://127.0.0.1:#{port}"
  ensure
    thread&.kill
    server&.close
  end

  def make_config(overrides = {})
    model_entry = {
      "name" => "gpt-4o-mini",
      "model" => "openai/gpt-4o-mini",
      "api_key" => "sk-test-key",
      "api_base" => "https://api.openai.com/v1"
    }

    if overrides["provider"] == "anthropic"
      model_entry["name"] = "claude-sonnet"
      model_entry["model"] = "anthropic/claude-sonnet"
      model_entry["api_key"] = overrides["anthropic_api_key"] || "sk-ant-test"
      model_entry["api_base"] = overrides["anthropic_api_base"] || "https://api.anthropic.com"
    elsif overrides["provider"] == "ollama"
      model_name = overrides["model"] || "llama3"
      model_entry["name"] = model_name
      model_entry["model"] = "ollama/#{model_name}"
      model_entry["api_base"] = overrides["ollama_host"] || "http://localhost:11434"
      model_entry.delete("api_key")
    end

    if overrides.key?("api_key") || overrides.key?("api_base")
      model_entry.merge!(overrides.slice("api_key", "api_base"))
    end

    models = [ model_entry ]
    agents = { "defaults" => { "name" => model_entry["name"] } }

    tools = {
      "exec" => { "enabled" => true },
      "read_file" => { "enabled" => true },
      "write_file" => { "enabled" => true },
      "list_dir" => { "enabled" => true },
      "web_fetch" => { "enabled" => true }
    }

    data = {
      "agents" => agents,
      "models" => models,
      "tools" => tools,
      "debug" => false
    }

    File.write(@config_path, data.to_yaml)
    Rubot::Config.new(@config_path)
  end

  # --- OpenAI Provider ---

  def test_opencode_go_adds_session_header
    config = make_config("api_base" => "https://opencode.ai/zen/go/v1")
    provider = Rubot::Providers::OpenAI.new(config.provider_settings)
    headers = provider.instance_variable_get(:@extra_headers)
    assert_match(/\A[0-9a-f]{32}\z/, headers["x-opencode-session"])
  end

  def test_openai_does_not_add_opencode_session_header
    config = make_config
    provider = Rubot::Providers::OpenAI.new(config.provider_settings)
    headers = provider.instance_variable_get(:@extra_headers)
    refute headers.key?("x-opencode-session")
  end

  def test_openai_provider_name
    config = make_config
    provider = Rubot::Providers::OpenAI.new(config)
    assert_equal "openai", provider.name
  end

  def test_openai_format_tools
    config = make_config
    provider = Rubot::Providers::OpenAI.new(config)
    registry = Rubot::Tools::Registry.new

    defs = provider.format_tools(registry.all)
    assert_equal 8, defs.size

    shell_def = defs.find { |d| d["function"]["name"] == "shell_exec" }
    assert shell_def
    assert_equal "function", shell_def["type"]
    assert_includes shell_def["function"]["description"], "shell"

    file_def = defs.find { |d| d["function"]["name"] == "file_ops" }
    assert file_def
    assert_equal "function", file_def["type"]

    web_def = defs.find { |d| d["function"]["name"] == "web_fetch" }
    assert web_def
    assert_equal "function", web_def["type"]
  end

  def test_openai_payload_includes_reasoning_effort
    settings = Rubot::ProviderSettings.new(
      provider: "openai", model: "deepseek-v4.1-flash", api_key: "sk-test",
      api_base: "https://example.invalid/v1", max_tokens: 256, temperature: 0.7,
      reasoning_effort: "low"
    )
    provider = Rubot::Providers::OpenAI.new(settings)

    payload = provider.send(:build_payload, [], nil)

    assert_equal "low", payload["reasoning_effort"]
  end

  def test_openai_payload_omits_reasoning_effort_when_unset
    settings = Rubot::ProviderSettings.new(
      provider: "openai", model: "deepseek-v4.1-flash", api_key: "sk-test",
      api_base: "https://example.invalid/v1", max_tokens: 256, temperature: 0.7
    )
    provider = Rubot::Providers::OpenAI.new(settings)

    payload = provider.send(:build_payload, [], nil)

    refute payload.key?("reasoning_effort")
  end

  def test_provider_settings_rejects_an_unknown_reasoning_effort
    settings = Rubot::ProviderSettings.new(
      provider: "openai", model: "m", api_key: "k", api_base: "http://127.0.0.1:1",
      max_tokens: 16, temperature: 0.7, reasoning_effort: "extreme"
    )

    assert_nil settings.reasoning_effort
  end

  def test_openai_requires_api_key
    config = make_config("api_key" => nil)
    provider = Rubot::Providers::OpenAI.new(config)
    assert provider
  end

  def test_openai_custom_api_base
    config = make_config("api_base" => "https://api.example.com/v1")
    provider = Rubot::Providers::OpenAI.new(config)
    assert provider
  end

  # --- Anthropic Provider ---

  def test_anthropic_provider_name
    config = make_config({
      "provider" => "anthropic",
      "anthropic_api_key" => "sk-ant-test"
    })
    provider = Rubot::Providers::Anthropic.new(config)
    assert_equal "anthropic", provider.name
  end

  def test_anthropic_format_tools
    config = make_config({
      "provider" => "anthropic",
      "anthropic_api_key" => "sk-ant-test"
    })
    provider = Rubot::Providers::Anthropic.new(config)
    registry = Rubot::Tools::Registry.new

    defs = provider.format_tools(registry.all)
    assert_equal 8, defs.size

    shell_def = defs.find { |d| d["name"] == "shell_exec" }
    assert shell_def
    assert shell_def["input_schema"]
    refute shell_def["type"]
  end

  def test_anthropic_custom_api_base
    config = make_config({
      "provider" => "anthropic",
      "anthropic_api_key" => "sk-ant-test",
      "anthropic_api_base" => "https://api.example.com"
    })
    provider = Rubot::Providers::Anthropic.new(config)
    assert provider
  end

  def test_anthropic_lists_its_models
    body = JSON.generate(
      "data" => [
        { "id" => "claude-sonnet-4-5", "display_name" => "Claude Sonnet 4.5" },
        { "id" => "claude-opus-4-1", "display_name" => "Claude Opus 4.1" }
      ]
    )

    with_stub_server(body) do |base|
      config = make_config({
        "provider" => "anthropic",
        "anthropic_api_key" => "sk-ant-test",
        "anthropic_api_base" => base
      })
      provider = Rubot::Providers::Anthropic.new(config.provider_settings)

      models = provider.list_models

      assert_equal %w[claude-sonnet-4-5 claude-opus-4-1], models.map { |model| model["id"] }
      assert_equal "Claude Sonnet 4.5", models.first["name"]
    end
  end

  # --- Ollama Provider ---

  def test_ollama_provider_name
    config = make_config({
      "provider" => "ollama",
      "model" => "llama3",
      "ollama_host" => "http://localhost:11434"
    })
    provider = Rubot::Providers::Ollama.new(config)
    assert_equal "ollama", provider.name
  end

  def test_ollama_format_tools
    config = make_config({
      "provider" => "ollama",
      "model" => "llama3"
    })
    provider = Rubot::Providers::Ollama.new(config)
    registry = Rubot::Tools::Registry.new

    defs = provider.format_tools(registry.all)
    assert_equal 8, defs.size

    shell_def = defs.find { |d| d["function"]["name"] == "shell_exec" }
    assert shell_def
    assert_equal "function", shell_def["type"]
  end

  def test_ollama_custom_host
    config = make_config({
      "provider" => "ollama",
      "model" => "llama3",
      "ollama_host" => "http://my-server:11434"
    })
    provider = Rubot::Providers::Ollama.new(config)
    assert provider
  end

  def test_ollama_lists_its_models
    body = JSON.generate(
      "models" => [
        { "name" => "llama3:latest" },
        { "name" => "qwen3:8b" }
      ]
    )

    with_stub_server(body) do |base|
      config = make_config({
        "provider" => "ollama",
        "model" => "llama3",
        "ollama_host" => base
      })
      provider = Rubot::Providers::Ollama.new(config.provider_settings)

      models = provider.list_models

      assert_equal %w[llama3:latest qwen3:8b], models.map { |model| model["id"] }
    end
  end

  # --- Provider base class ---

  def test_provider_chat_not_implemented
    config = make_config
    provider = Rubot::Provider.new(config)
    assert_raises(NotImplementedError) { provider.chat([]) }
  end

  def test_provider_parse_stream_chunk_not_implemented
    config = make_config
    provider = Rubot::Provider.new(config)
    assert_raises(NotImplementedError) { provider.parse_stream_chunk("") }
  end

  # --- Rate limit retry mechanism ---

  def test_rate_limit_error_message
    err = Rubot::RateLimitError.new
    assert_includes err.message, "429"
    assert_nil err.retry_after
  end

  def test_rate_limit_error_with_retry_after
    err = Rubot::RateLimitError.new(30)
    assert_equal 30, err.retry_after
  end

  class RetryTestProvider < Rubot::Provider
    attr_reader :call_count

    def initialize(config, responses = [])
      super(config)
      @responses = responses
      @call_count = 0
    end

    def chat(_messages, tools: nil)
      @call_count += 1
      resp = @responses.shift
      raise Rubot::RateLimitError.new if resp == :rate_limit
      raise Net::ReadTimeout, "stalled" if resp == :read_timeout

      resp
    end
  end

  def make_retry_config
    make_config("debug" => true)
  end

  def test_with_retry_succeeds_after_rate_limit
    config = make_retry_config
    provider = RetryTestProvider.new(config, [:rate_limit, "success"])

    result = provider.stub(:sleep, nil) do
      provider.send(:with_retry) { provider.chat([]) }
    end
    assert_equal "success", result
    assert_equal 2, provider.call_count
  end

  def test_with_retry_raises_after_max_retries
    config = make_retry_config
    provider = RetryTestProvider.new(config, [:rate_limit, :rate_limit, :rate_limit, :rate_limit])

    error = assert_raises(Rubot::RateLimitError) do
      provider.stub(:sleep, nil) do
        provider.send(:with_retry, max_retries: 3) { provider.chat([]) }
      end
    end
    assert_equal 4, provider.call_count # initial + 3 retries
    assert_equal 4, error.attempts
    assert_includes error.message, "4 attempts"
  end

  # The retry loop must wait between attempts, otherwise a throttled provider
  # is hammered with the same request and the turn still fails.
  def test_with_retry_waits_with_backoff_between_rate_limit_attempts
    config = make_retry_config
    provider = RetryTestProvider.new(
      config,
      [:rate_limit, :rate_limit, :rate_limit, :rate_limit, :rate_limit, "success"]
    )

    waits = []
    provider.stub(:sleep, ->(seconds) { waits << seconds }) do
      result = provider.send(:with_retry) { provider.chat([]) }
      assert_equal "success", result
    end

    assert_equal 5, waits.size
    waits.each_cons(2) { |prev, curr| assert curr > prev, "backoff should grow: #{waits.inspect}" }
    assert waits.all? { |wait| wait <= Rubot::Provider::MAX_BACKOFF }, waits.inspect
  end

  def test_with_retry_honours_retry_after_but_caps_it
    config = make_retry_config
    waits = []

    failing = Class.new(Rubot::Provider) do
      def initialize(config, retry_after, waits)
        super(config)
        @retry_after = retry_after
        @waits = waits
        @calls = 0
      end

      def chat(_messages, tools: nil)
        @calls += 1
        raise Rubot::RateLimitError.new(@retry_after) if @calls == 1

        "ok"
      end
    end.new(config, 7, waits)

    failing.stub(:sleep, ->(seconds) { waits << seconds }) do
      assert_equal "ok", failing.send(:with_retry) { failing.chat([]) }
    end
    assert_equal [ 7 ], waits

    waits.clear
    too_long = Class.new(Rubot::Provider) do
      attr_reader :calls

      def initialize(config, waits)
        super(config)
        @waits = waits
        @calls = 0
      end

      def chat(_messages, tools: nil)
        @calls += 1
        raise Rubot::RateLimitError.new(3600) if @calls == 1

        "ok"
      end
    end.new(config, waits)

    too_long.stub(:sleep, ->(seconds) { waits << seconds }) do
      assert_equal "ok", too_long.send(:with_retry) { too_long.chat([]) }
    end
    assert_equal [ Rubot::Provider::MAX_BACKOFF ], waits
  end

  def test_with_retry_passes_through_other_errors
    config = make_retry_config
    provider = RetryTestProvider.new(config, [])

    def provider.chat(_messages, tools: nil)
      raise StandardError, "boom"
    end

    assert_raises(StandardError) { provider.send(:with_retry) { provider.chat([]) } }
  end

  def test_with_retry_succeeds_after_read_timeout
    config = make_retry_config
    provider = RetryTestProvider.new(config, [:read_timeout, "success"])

    result = provider.stub(:sleep, nil) do
      provider.send(:with_retry) { provider.chat([]) }
    end
    assert_equal "success", result
    assert_equal 2, provider.call_count
  end

  def test_with_retry_raises_after_max_network_retries
    config = make_retry_config
    provider = RetryTestProvider.new(config, [:read_timeout, :read_timeout, :read_timeout])

    assert_raises(Net::ReadTimeout) do
      provider.stub(:sleep, nil) do
        provider.send(:with_retry, max_network_retries: 2) { provider.chat([]) }
      end
    end
    assert_equal 3, provider.call_count # initial + 2 retries
  end

  def test_with_retry_skips_retry_when_retryable_returns_false
    config = make_retry_config
    provider = RetryTestProvider.new(config, [:read_timeout, "success"])

    assert_raises(Net::ReadTimeout) do
      provider.stub(:sleep, nil) do
        provider.send(:with_retry, retryable: -> { false }) { provider.chat([]) }
      end
    end
    assert_equal 1, provider.call_count
  end

  def test_with_retry_passes_through_non_transient_errors
    config = make_retry_config
    provider = RetryTestProvider.new(config, [])

    def provider.chat(_messages, tools: nil)
      raise ArgumentError, "boom"
    end

    assert_raises(ArgumentError) { provider.send(:with_retry) { provider.chat([]) } }
  end

  def test_with_retry_succeeds_immediately_without_rate_limit
    config = make_retry_config
    provider = RetryTestProvider.new(config, ["ok"])

    result = provider.send(:with_retry) { provider.chat([]) }
    assert_equal "ok", result
    assert_equal 1, provider.call_count
  end

  def test_exponential_backoff_increases_with_attempt
    config = make_retry_config
    provider = RetryTestProvider.new(config, [])

    t1 = provider.send(:exponential_backoff, 1)
    t2 = provider.send(:exponential_backoff, 2)
    t3 = provider.send(:exponential_backoff, 3)

    assert t1 < t2, "backoff should increase: #{t1} < #{t2}"
    assert t2 < t3, "backoff should increase: #{t2} < #{t3}"
    # base values: 1, 2, 4 (plus small jitter)
    assert_in_delta 1.0, t1, 0.5
    assert_in_delta 2.0, t2, 0.5
    assert_in_delta 4.0, t3, 0.5
  end

  def test_exponential_backoff_is_capped
    config = make_retry_config
    provider = RetryTestProvider.new(config, [])

    assert_equal Rubot::Provider::MAX_BACKOFF, provider.send(:exponential_backoff, 20)
  end

  def test_rate_limit_error_message_is_user_facing
    err = Rubot::RateLimitError.new(12, attempts: 6)

    assert_includes err.message, "6 attempts"
    assert_includes err.message, "12s"
    assert_includes err.message, "switch to another model"
  end

  def test_parse_retry_after_accepts_http_date
    config = make_retry_config
    provider = RetryTestProvider.new(config, [])

    date = (Time.now + 12).httpdate
    mock_resp = Struct.new(:[]).new
    mock_resp.define_singleton_method(:[]) { |key| { "Retry-After" => date }[key] }

    seconds = provider.send(:parse_retry_after, mock_resp)
    assert_includes 11..12, seconds
  end

  def test_parse_retry_after_returns_integer
    config = make_retry_config
    provider = RetryTestProvider.new(config, [])

    mock_resp = Struct.new(:[]).new
    def mock_resp.[](key)
      { "Retry-After" => "30" }[key]
    end

    assert_equal 30, provider.send(:parse_retry_after, mock_resp)
  end

  def test_parse_retry_after_returns_nil_when_absent
    config = make_retry_config
    provider = RetryTestProvider.new(config, [])

    mock_resp = Struct.new(:[]).new
    def mock_resp.[](key)
      nil
    end

    assert_nil provider.send(:parse_retry_after, mock_resp)
  end

  def test_parse_retry_after_returns_nil_for_zero
    config = make_retry_config
    provider = RetryTestProvider.new(config, [])

    mock_resp = Struct.new(:[]).new
    def mock_resp.[](key)
      "0"
    end

    assert_nil provider.send(:parse_retry_after, mock_resp)
  end

  # Reasoning is streamed on its own channel: the answer must never be mixed
  # with the model's thinking, and the thinking must not be lost either.
  def test_a_streamed_answer_is_kept_apart_from_the_reasoning
    require "socket"

    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    config = make_config("api_base" => "http://127.0.0.1:#{port}/v1")
    provider = Rubot::Providers::OpenAI.new(config.provider_settings)

    server_thread = Thread.new do
      client = server.accept
      begin
        read_request(client)
        client.write("HTTP/1.1 200 OK\r\n")
        client.write("Content-Type: text/event-stream\r\n")
        client.write("\r\n")
        client.write("data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"let me think\"}}]}\n\n")
        client.write("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"}}]}\n\n")
        client.write("data: [DONE]\n\n")
        client.flush
      ensure
        client.close
      end
    end

    chunks = []
    thoughts = []
    result = provider.chat_stream([ { "role" => "user", "content" => "hi" } ]) do |chunk, _tool_data, reasoning|
      chunks << chunk if chunk
      thoughts << reasoning if reasoning
    end

    assert_equal [ "hello" ], chunks, "only the answer reaches the answer channel"
    assert_equal [ "let me think" ], thoughts, "the thinking reaches its own channel"
    assert_equal "hello", result["content"]
    assert_equal "let me think", result["reasoning_content"]
  ensure
    server_thread&.kill
    server&.close
  end

  # A blocked provider read must not be waited out: closing the session from
  # the cancellation token is what makes esc instant while the model is still
  # thinking (before the first token) or in the middle of an answer.
  def test_a_stop_closes_a_blocked_streaming_read
    require "socket"

    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    config = make_config("api_base" => "http://127.0.0.1:#{port}/v1")
    provider = Rubot::Providers::OpenAI.new(config.provider_settings)

    server_thread = Thread.new do
      client = server.accept
      begin
        read_request(client)
        client.write("HTTP/1.1 200 OK\r\n")
        client.write("Content-Type: text/event-stream\r\n")
        client.write("\r\n")
        client.write("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"}}]}\n\n")
        client.flush
        # The stream stays open without another chunk, exactly like a model
        # that is still generating. Only the stop can end the read.
        sleep 30
      ensure
        client.close
      end
    end

    token = Rubot::Cancellation.new.start!
    chunks = Queue.new
    canceller = Thread.new do
      chunks.pop
      token.cancel!
    end

    Thread.current[:rubot_cancellation] = token
    before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Rubot::Cancelled) do
      provider.chat_stream([ { "role" => "user", "content" => "hi" } ]) { |chunk| chunks << chunk }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before

    assert_instance_of Rubot::Cancelled, error
    assert_operator elapsed, :<, 5, "a blocked read must abort on stop, not wait for the provider"
    assert canceller.join(2)
  ensure
    Thread.current[:rubot_cancellation] = nil
    server_thread&.kill
    server&.close
  end
end
