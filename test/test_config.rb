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

  def test_model_entry_by_name_finds_model
    File.write(@config_path, {
      "models" => [
        { "name" => "gpt-4o-mini", "model" => "openai/gpt-4o-mini" },
        { "name" => "llama3", "model" => "ollama/llama3" }
      ]
    }.to_yaml)
    config = Rubot::Config.new(@config_path)
    entry = config.model_entry_by_name("llama3")
    assert_equal "llama3", entry["name"]
    assert_equal "ollama/llama3", entry["model"]
  end

  def test_model_entry_by_name_returns_nil_for_unknown
    File.write(@config_path, {
      "models" => [
        { "name" => "gpt-4o-mini", "model" => "openai/gpt-4o-mini" }
      ]
    }.to_yaml)
    config = Rubot::Config.new(@config_path)
    assert_nil config.model_entry_by_name("nonexistent")
  end

  def test_model_entry_by_name_with_no_models
    config = Rubot::Config.new("/nonexistent/config.yml")
    assert_nil config.model_entry_by_name("anything")
  end
end

class TestConfigDynamicModels < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yml")
    File.write(@config_path, {
      "agents" => { "defaults" => { "name" => "opencode-go" } },
      "models" => [
        {
          "name" => "opencode-go",
          "model" => "openai/deepseek-v4.1-flash",
          "api_key" => "sk-opencode",
          "api_base" => "https://opencode.ai/zen/go/v1",
          "extra_headers" => { "x-custom" => "yes" }
        }
      ]
    }.to_yaml)
    @config = Rubot::Config.new(@config_path)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_catalog_model_id_uses_the_active_entry_credentials
    settings = @config.provider_settings("deepseek-v4-pro")

    assert_equal "openai", settings.provider
    assert_equal "deepseek-v4-pro", settings.model
    assert_equal "sk-opencode", settings.api_key
    assert_equal "https://opencode.ai/zen/go/v1", settings.api_base
    assert_equal({ "x-custom" => "yes" }, settings.extra_headers)
  end

  def test_unknown_config_model_still_uses_the_raw_model_id
    settings = @config.provider_settings("some-catalog-model")

    assert_equal "some-catalog-model", settings.model
    assert_equal "https://opencode.ai/zen/go/v1", settings.api_base
  end
end

class TestConfigModelPresets < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @config_path = File.join(@tmpdir, "config.yml")
    write_config
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def write_config(extra = {})
    File.write(@config_path, {
      "agents" => { "defaults" => {
        "workspace" => @workspace,
        "name" => "opencode-go",
        "model_preset" => "fast"
      } },
      "models" => [
        {
          "name" => "opencode-go",
          "model" => "openai/deepseek-v4.1-flash",
          "api_key" => "sk-test",
          "api_base" => "https://opencode.ai/zen/go/v1"
        }
      ],
      "model_presets" => {
        "fast" => { "model" => "deepseek-v4.1-flash", "max_tokens" => 4096, "temperature" => 0.2 },
        "deep" => { "model" => "deepseek-v4-pro", "max_tokens" => 8192, "temperature" => 0.1 }
      }
    }.merge(extra).to_yaml)
    @config = Rubot::Config.new(@config_path)
  end

  def test_primary_is_first_and_named
    assert_equal %w[fast deep], @config.model_preset_names
    assert_equal "fast", @config.primary_model_preset_name
  end

  def test_default_preset_is_the_configured_primary
    preset = @config.default_model_preset

    assert_equal "fast", preset["name"]
    assert_equal "deepseek-v4.1-flash", preset["model"]
  end

  def test_preset_inherits_credentials_from_the_catalog_model
    preset = @config.model_preset("deep")

    assert_equal "deepseek-v4-pro", preset["model"]
    assert_equal "openai", preset["provider"]
    assert_equal "sk-test", preset["api_key"]
    assert_equal "https://opencode.ai/zen/go/v1", preset["api_base"]
    assert_equal 8192, preset["max_tokens"]
    assert_in_delta 0.1, preset["temperature"]
  end

  def test_preset_reasoning_effort_reaches_provider_settings
    write_config("model_presets" => {
      "fast" => { "model" => "deepseek-v4.1-flash", "reasoning_effort" => "low" }
    })

    settings = @config.provider_settings_for_preset("fast")

    assert_equal "low", settings.reasoning_effort
  end

  def test_agents_default_reasoning_effort_applies_without_a_preset
    write_config("agents" => { "defaults" => {
      "workspace" => @workspace,
      "name" => "opencode-go",
      "reasoning_effort" => "medium"
    } })

    assert_equal "medium", @config.provider_settings.reasoning_effort
  end

  def test_set_and_delete_preset
    preset = @config.set_model_preset("coding", {
      "model" => "glm-5.3",
      "temperature" => "0.15",
      "max_tokens" => "2048"
    })

    assert_equal "glm-5.3", preset["model"]
    assert_equal 2048, preset["max_tokens"]
    assert_in_delta 0.15, preset["temperature"]

    @config.save
    raw = YAML.safe_load(File.read(@config_path))
    assert_equal "glm-5.3", raw.dig("model_presets", "coding", "model")

    assert @config.delete_model_preset("coding")
    assert_nil @config.model_preset("coding")
  end

  def test_default_can_be_changed_and_cleared
    assert_equal "deep", @config.set_default_model_preset("deep")
    assert_equal "deep", @config.primary_model_preset_name
    assert_equal "deepseek-v4-pro", @config.default_model_preset["model"]

    assert_nil @config.set_default_model_preset("default")
    assert_equal "default", @config.primary_model_preset_name
    assert_equal "deepseek-v4.1-flash", @config.default_model_preset["model"]
  end

  def test_primary_alias_resolves_to_the_configured_default
    assert_equal "fast", @config.model_preset("primary")["name"]
  end

  def test_default_is_always_available_without_configured_presets
    write_config("model_presets" => {})

    assert_equal [ "default" ], @config.model_preset_names
    assert_equal "default", @config.primary_model_preset_name
    assert_equal "deepseek-v4.1-flash", @config.default_model_preset["model"]
  end

  def test_default_name_is_reserved
    assert_raises(ArgumentError) { @config.set_model_preset("default", { "model" => "glm-5.3" }) }
  end

  def test_primary_can_be_an_explicit_preset
    preset = @config.set_model_preset("primary", { "model" => "glm-5.3" })

    assert_equal "primary", preset["name"]
    assert_equal "glm-5.3", @config.model_preset("primary")["model"]

    assert_equal "primary", @config.set_default_model_preset("primary")
    assert_equal "primary", @config.primary_model_preset_name
    assert_equal "glm-5.3", @config.default_model_preset["model"]
  end

  def test_unknown_default_preset_falls_back_to_the_implicit_default
    @config.data["agents"]["defaults"]["model_preset"] = "missing"

    assert_equal "default", @config.primary_model_preset_name
    assert_equal "deepseek-v4.1-flash", @config.default_model_preset["model"]
  end
end

class TestConfigCompaction < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yml")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def write_config(defaults)
    File.write(@config_path, {
      "agents" => { "defaults" => defaults }
    }.to_yaml)
    Rubot::Config.new(@config_path)
  end

  def test_defaults
    config = Rubot::Config.new("/nonexistent/config.yml")

    assert config.auto_compact?
    assert_in_delta 80.0, config.compact_threshold_percent
    assert_equal 6, config.compact_keep_recent_messages
  end

  def test_nested_settings
    config = write_config(
      "compaction" => {
        "auto" => false,
        "threshold_percent" => 65,
        "keep_recent_messages" => 12
      }
    )

    refute config.auto_compact?
    assert_in_delta 65.0, config.compact_threshold_percent
    assert_equal 12, config.compact_keep_recent_messages
  end

  def test_fraction_threshold_is_converted_to_a_percentage
    config = write_config("compaction" => { "threshold" => 0.75 })

    assert_in_delta 75.0, config.compact_threshold_percent
  end

  def test_flat_aliases
    config = write_config(
      "auto_compact" => false,
      "compact_threshold_percent" => 55,
      "compact_keep_recent_messages" => 4
    )

    refute config.auto_compact?
    assert_in_delta 55.0, config.compact_threshold_percent
    assert_equal 4, config.compact_keep_recent_messages
  end

  def test_invalid_threshold_falls_back_to_the_default
    config = write_config("compaction" => { "threshold_percent" => 0 })

    assert_in_delta 80.0, config.compact_threshold_percent
  end

  def test_absolute_threshold_tokens
    config = write_config("compaction" => { "threshold_tokens" => 60_000 })

    assert_equal 60_000, config.compact_threshold_tokens
  end

  def test_missing_absolute_threshold_disables_the_cap
    config = write_config("compaction" => { "auto" => true })

    assert_equal 0, config.compact_threshold_tokens
  end
end

class TestConfigHistory < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yml")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def write_config(defaults)
    File.write(@config_path, {
      "agents" => { "defaults" => defaults }
    }.to_yaml)
    Rubot::Config.new(@config_path)
  end

  def test_defaults
    config = write_config({})

    assert_equal Rubot::Config::DEFAULT_MAX_ROUNDS, config.history_limit
    assert_equal 0, config.history_max_tokens
    assert_equal 3, config.tool_result_keep
    assert_equal 2_000, config.tool_result_max_chars
  end

  def test_nested_settings
    config = write_config(
      "history" => {
        "limit" => 30,
        "max_tokens" => 24_000,
        "tool_result_keep" => 5,
        "tool_result_max_chars" => 4_000
      }
    )

    assert_equal 30, config.history_limit
    assert_equal 24_000, config.history_max_tokens
    assert_equal 5, config.tool_result_keep
    assert_equal 4_000, config.tool_result_max_chars
  end

  def test_flat_aliases
    config = write_config(
      "history_limit" => 12,
      "history_max_tokens" => 8_000,
      "tool_result_keep" => 1,
      "tool_result_max_chars" => 500
    )

    assert_equal 12, config.history_limit
    assert_equal 8_000, config.history_max_tokens
    assert_equal 1, config.tool_result_keep
    assert_equal 500, config.tool_result_max_chars
  end

  def test_zero_or_negative_values_fall_back_or_disable
    config = write_config(
      "history" => { "limit" => 0, "max_tokens" => -5,
                     "tool_result_keep" => -1, "tool_result_max_chars" => 0 }
    )

    assert_equal Rubot::Config::DEFAULT_MAX_ROUNDS, config.history_limit
    assert_equal 0, config.history_max_tokens
    assert_equal 0, config.tool_result_keep
    assert_equal 0, config.tool_result_max_chars
  end
end

class TestConfigMemory < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yml")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def write_config(defaults)
    File.write(@config_path, { "agents" => { "defaults" => defaults } }.to_yaml)
    Rubot::Config.new(@config_path)
  end

  def test_extraction_is_batched_by_default
    config = Rubot::Config.new("/nonexistent/config.yml")

    assert_equal Rubot::Config::DEFAULT_MEMORY_EXTRACT_EVERY, config.memory_extract_every
    assert config.memory_consolidate?
  end

  def test_nested_memory_settings
    config = write_config(
      "memory" => { "extract_every" => 5, "consolidate" => false }
    )

    assert_equal 5, config.memory_extract_every
    refute config.memory_consolidate?
  end

  def test_flat_aliases
    config = write_config("memory_extract_every" => 1, "memory_consolidate" => "off")

    assert_equal 1, config.memory_extract_every
    refute config.memory_consolidate?
  end

  def test_zero_disables_extraction
    config = write_config("memory" => { "extract_every" => 0 })

    assert_equal 0, config.memory_extract_every
  end

  def test_negative_values_are_treated_as_disabled
    config = write_config("memory" => { "extract_every" => -2 })

    assert_equal 0, config.memory_extract_every
  end
end
