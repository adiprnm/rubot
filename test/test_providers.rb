# frozen_string_literal: true

require_relative "test_helper"

class TestProviders < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yml")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
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
    assert_equal 5, defs.size

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
    assert_equal 5, defs.size

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
    assert_equal 5, defs.size

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

    result = provider.send(:with_retry) { provider.chat([]) }
    assert_equal "success", result
    assert_equal 2, provider.call_count
  end

  def test_with_retry_raises_after_max_retries
    config = make_retry_config
    provider = RetryTestProvider.new(config, [:rate_limit, :rate_limit, :rate_limit, :rate_limit])

    assert_raises(Rubot::RateLimitError) do
      provider.send(:with_retry, max_retries: 3) { provider.chat([]) }
    end
    assert_equal 4, provider.call_count # initial + 3 retries
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
end
