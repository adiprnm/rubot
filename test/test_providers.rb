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
    assert_equal 4, defs.size

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
    assert_equal 4, defs.size

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
    assert_equal 4, defs.size

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
end
