# frozen_string_literal: true

require "yaml"
require "fileutils"
require "pathname"
require_relative "provider"

module Rubot
  class Config
    DEFAULT_CONFIG_DIR  = File.expand_path("~/.rubot")
    DEFAULT_CONFIG_FILE = File.join(DEFAULT_CONFIG_DIR, "config.yml")
    DEFAULT_WORKSPACE   = File.join(DEFAULT_CONFIG_DIR, "workspace")

    attr_reader :config_path, :data

    def initialize(config_path = nil)
      @config_path = config_path || ENV["RUBOT_CONFIG"] || DEFAULT_CONFIG_FILE
      @data = load_config
    end

    # Build a Config around already-loaded data (used to hand a plain-data
    # snapshot to a Ractor). The data is not copied here: the Ractor message
    # boundary already deep-copies unshareable objects.
    def self.from_data(data, config_path: nil)
      config = allocate
      config.instance_variable_set(:@config_path, config_path || DEFAULT_CONFIG_FILE)
      config.instance_variable_set(:@data, data || {})
      config
    end

    # Plain, Ractor-sendable snapshot of the underlying configuration.
    def snapshot
      Marshal.load(Marshal.dump(@data))
    end

    def agent_defaults
      data.dig("agents", "defaults") || {}
    end

    def models
      data["models"] || []
    end

    alias model_list models

    def provider
      return data["provider"] if data["provider"]
      model_str = active_model_entry["model"] || "openai/#{name}"
      model_str.split("/").first
    end

    def name
      agent_defaults["name"] || "gpt-4o-mini"
    end

    def model
      return data["model"] if data["model"]
      entry = active_model_entry
      model_str = entry["model"] || "openai/#{name}"
      model_str.split("/").last
    end

    alias model_name model

    def active_model_entry
      return {} if models.empty?
      models.find { |m| m["name"] == name } || models.first
    end

    def model_entry_by_name(model_name)
      return nil if models.empty?
      models.find { |m| m["name"] == model_name }
    end

    def api_key
      active_model_entry["api_key"] || ENV["RUBOT_API_KEY"] || ENV["OPENAI_API_KEY"]
    end

    def api_base
      active_model_entry["api_base"] || ENV["RUBOT_API_BASE"] || ENV["OPENAI_API_BASE"]
    end

    # Build an immutable ProviderSettings snapshot for the given model
    # (or the active model when nil). This replaces the old approach of
    # temporarily mutating config.data during provider rebuilds.
    def provider_settings(model_name = nil)
      entry = model_name ? model_entry_by_name(model_name) : active_model_entry
      entry ||= {}

      model_str = entry["model"] || "openai/#{name}"

      ProviderSettings.new(
        provider: data["provider"] || model_str.split("/").first,
        model: data["model"] || model_str.split("/").last,
        api_key: entry["api_key"] || ENV["RUBOT_API_KEY"] || ENV["OPENAI_API_KEY"],
        api_base: entry["api_base"] || ENV["RUBOT_API_BASE"] || ENV["OPENAI_API_BASE"],
        max_tokens: max_tokens,
        temperature: temperature,
        debug: debug?,
        extra_headers: entry["extra_headers"].is_a?(Hash) ? entry["extra_headers"] : {}
      )
    end

    def max_tokens
      agent_defaults["max_tokens"] || 4096
    end

    def temperature
      agent_defaults["temperature"] || 0.7
    end

    def system_prompt
      agent_defaults["system_prompt"] || default_system_prompt
    end

    def workspace
      ws = agent_defaults["workspace"] || DEFAULT_WORKSPACE
      ws.start_with?("~") ? File.expand_path(ws) : ws
    end

    def restrict_to_workspace
      val = agent_defaults["restrict_to_workspace"]
      # Default to true for security (matches PicoClaw default)
      return true if val.nil?
      !!val
    end

    def allow_read_outside_workspace
      val = agent_defaults["allow_read_outside_workspace"]
      !!val
    end

    def max_tool_iterations
      agent_defaults["max_tool_iterations"] || 50
    end

    def history_limit
      max_tool_iterations
    end

    def tool_enabled?(name)
      return false unless tools_enabled
      tools = data["tools"] || {}
      tool = tools[name.to_s]
      return true if tool.nil?
      tool.is_a?(Hash) && tool["enabled"] != false
    end

    def tools_enabled
      tools = data["tools"]
      return true if tools.nil?
      return false if tools == false
      return true if tools.respond_to?(:empty?) && tools.empty?
      return false unless tools.is_a?(Hash)
      tools.values.any? { |t| t.is_a?(Hash) && t["enabled"] != false }
    end

    def enabled_tools
      tools = data["tools"]
      return [] unless tools.is_a?(Hash)
      tools.select { |_, t| t.is_a?(Hash) && t["enabled"] != false }.keys
    end

    def debug?
      data["debug"] == true || ENV["RUBOT_DEBUG"] == "1"
    end

    def ensure_workspace
      FileUtils.mkdir_p(workspace)
    end

    def save
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, data.to_yaml)
    end

    private

    def load_config
      return {} unless File.exist?(config_path)
      # FIX (VULN-14): Remove Symbol from permitted_classes to prevent
      # YAML-based symbol table exhaustion DoS attacks. All config access
      # in this codebase uses string keys, so symbols are unnecessary.
      YAML.safe_load(File.read(config_path), permitted_classes: []) || {}
    rescue Psych::SyntaxError => e
      warn "Warning: Failed to parse config file: #{e.message}"
      {}
    end

    def default_system_prompt
      <<~PROMPT.chomp
        You are Rubot, a helpful AI assistant running in the terminal.
        You are written in Ruby and powered by the Rubot framework.

        You can execute shell commands, read/write files, and search the web
        using the tools available to you. Be concise and helpful.

        When you execute commands, explain what you're doing briefly before
        executing them. After executing, summarize the results.
      PROMPT
    end
  end
end
