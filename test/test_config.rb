# frozen_string_literal: true

require_relative "test_helper"

class TestConfig < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yml")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_loads_empty_config_when_file_missing
    config = Rubot::Config.new("/nonexistent/config.yml")
    assert_equal "openai", config.provider
    assert_equal "gpt-4o-mini", config.model_name
    assert_equal "gpt-4o-mini", config.model
  end

  def test_loads_config_from_file
    File.write(@config_path, {
      "agents" => {
        "defaults" => {
          "name" => "llama3",
          "workspace" => "/tmp/ws"
        }
      },
      "models" => [
        {
          "name" => "llama3",
          "model" => "ollama/llama3",
          "api_base" => "http://localhost:11434"
        }
      ]
    }.to_yaml)

    config = Rubot::Config.new(@config_path)
    assert_equal "ollama", config.provider
    assert_equal "llama3", config.name
    assert_equal "http://localhost:11434", config.api_base
  end

  def test_default_system_prompt
    config = Rubot::Config.new("/nonexistent/config.yml")
    assert_includes config.system_prompt, "Rubot"
  end

  def test_custom_system_prompt
    File.write(@config_path, {
      "agents" => {
        "defaults" => {
          "system_prompt" => "Custom prompt here"
        }
      }
    }.to_yaml)

    config = Rubot::Config.new(@config_path)
    assert_equal "Custom prompt here", config.system_prompt
  end

  def test_api_key_from_env
    ENV["RUBOT_API_KEY"] = "test-key-123"
    config = Rubot::Config.new("/nonexistent/config.yml")
    assert_equal "test-key-123", config.api_key
  ensure
    ENV.delete("RUBOT_API_KEY")
  end

  def test_api_key_from_config
    File.write(@config_path, {
      "models" => [
        { "name" => "gpt-4o-mini", "api_key" => "sk-config-key" }
      ]
    }.to_yaml)

    config = Rubot::Config.new(@config_path)
    assert_equal "sk-config-key", config.api_key
  end

  def test_api_key_config_takes_precedence_over_env
    File.write(@config_path, {
      "models" => [
        { "name" => "gpt-4o-mini", "api_key" => "sk-config-key" }
      ]
    }.to_yaml)

    ENV["RUBOT_API_KEY"] = "sk-env-key"
    config = Rubot::Config.new(@config_path)
    assert_equal "sk-config-key", config.api_key
  ensure
    ENV.delete("RUBOT_API_KEY")
  end

  def test_debug_flag
    File.write(@config_path, { "debug" => true }.to_yaml)
    config = Rubot::Config.new(@config_path)
    assert config.debug?
  end

  def test_tools_enabled_by_default
    config = Rubot::Config.new("/nonexistent/config.yml")
    assert config.tools_enabled
  end

  def test_tools_disabled
    File.write(@config_path, {
      "tools" => {
        "exec" => { "enabled" => false },
        "read_file" => { "enabled" => false }
      }
    }.to_yaml)
    config = Rubot::Config.new(@config_path)
    refute config.tools_enabled
  end

  def test_enabled_tools
    File.write(@config_path, {
      "tools" => {
        "exec" => { "enabled" => true },
        "read_file" => { "enabled" => true },
        "write_file" => { "enabled" => false }
      }
    }.to_yaml)
    config = Rubot::Config.new(@config_path)
    assert_includes config.enabled_tools, "exec"
    assert_includes config.enabled_tools, "read_file"
    refute_includes config.enabled_tools, "write_file"
  end

  def test_tool_enabled
    File.write(@config_path, {
      "tools" => {
        "exec" => { "enabled" => true },
        "read_file" => { "enabled" => false }
      }
    }.to_yaml)
    config = Rubot::Config.new(@config_path)
    assert config.tool_enabled?("exec")
    refute config.tool_enabled?("read_file")
    assert config.tool_enabled?("web_fetch") # defaults to true when not specified
  end

  def test_model_list
    File.write(@config_path, {
      "models" => [
        { "name" => "gpt-4o-mini", "model" => "openai/gpt-4o-mini" },
        { "name" => "llama3", "model" => "ollama/llama3" }
      ]
    }.to_yaml)
    config = Rubot::Config.new(@config_path)
    assert_equal 2, config.model_list.size
    assert_equal "gpt-4o-mini", config.model_list.first["name"]
  end

  def test_save_config
    config = Rubot::Config.new(@config_path)
    config.data["agents"] = { "defaults" => { "name" => "claude" } }
    config.save

    loaded = YAML.safe_load(File.read(@config_path))
    assert_equal "claude", loaded.dig("agents", "defaults", "name")
  end

  def test_ensure_workspace
    config = Rubot::Config.new("/nonexistent/config.yml")
    config.data["agents"] = { "defaults" => { "workspace" => File.join(@tmpdir, "my_workspace") } }
    config.ensure_workspace
    assert File.directory?(File.join(@tmpdir, "my_workspace"))
  end
end
