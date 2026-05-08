# frozen_string_literal: true

require "json"
require_relative "config"
require_relative "session"
require_relative "provider"
require_relative "tools/registry"
require_relative "safety_guard"
require_relative "soul"
require_relative "memory"
require_relative "agents_file"
require_relative "tools/memory_tool"

module Rubot
  class Agent
    MAX_TOOL_ITERATIONS = 10

    attr_reader :config, :provider, :session, :tools, :soul, :memory, :agents_file, :skill_registry, :safety_guard

    def initialize(config:, provider: nil, session_id: "default", tools: nil)
      @config = config
      @provider = provider || build_provider
      @session = Session.new(session_id, workspace: config.workspace)

      # Build safety guard from config
      @safety_guard = SafetyGuard.new(
        workspace: config.workspace,
        restrict_to_workspace: config.restrict_to_workspace,
        allow_read_outside: config.allow_read_outside_workspace
      )

      @tools = tools || Tools::Registry.new
      # Always inject safety guard into tools, even when passed from outside
      inject_safety_guard

      # Warn if safety guard is disabled
      unless @safety_guard.restrict_to_workspace
        warn "[safety] WARNING: restrict_to_workspace is DISABLED — agent has full system access"
        warn "[safety] Set restrict_to_workspace: true in config.yml to enable sandboxing"
      else
        mode = @safety_guard.allow_read_outside ? "restrict-write" : "strict"
        warn "[safety] Safety guard ENABLED (mode: #{mode}, workspace: #{@safety_guard.workspace})"
      end

      @soul = Soul.new(workspace: config.workspace)
      @memory = Memory.new(workspace: config.workspace)
      @agents_file = AgentsFile.new(workspace: config.workspace)
      @skill_registry = SkillRegistry.new(workspace: config.workspace)
      config.ensure_workspace

      # Register the memory tool so the bot can manage its own memory
      @tools.register(Tools::MemoryTool.new(@memory)) if @memory.enabled?

      # Apply AGENTS.md overrides to config
      apply_agents_overrides if @agents_file.enabled?

      # Set workspace on cron tool so jobs persist to disk
      configure_cron_tool
    end

    # Process a user message and return the final assistant response.
    # Due cron jobs are fired first, their output prepended to the response.
    #
    # Callbacks (optional):
    #   on_tool_call:     Called before each tool executes. Yields (tool_name, arguments).
    #   on_tool_result:   Called after each tool executes. Yields (tool_name, result).
    #   on_progress:      Called after each full tool-call iteration. Yields (iteration_count, tool_count).
    def process(message, on_tool_call: nil, on_tool_result: nil, on_progress: nil, &on_chunk)
      # Fire any due cron jobs and collect their results
      cron_results = fire_due_cron_jobs
      warn "[cron] fire_due_cron_jobs returned #{cron_results.size} result(s)" if Rubot.debug?

      # Add user message to session
      @session.add("user", message)

      response = ""
      tool_calls = nil
      iterations = 0

      loop do
        break if iterations >= MAX_TOOL_ITERATIONS

        messages = build_messages
        log_debug("Sending #{messages.size} messages to provider")

        result = if block_given?
          @provider.chat_stream(messages, tools: tool_definitions) do |chunk, tool_data|
            response += chunk if chunk
            yield chunk if chunk && block_given?
          end
        else
          @provider.chat(messages, tools: tool_definitions)
        end

        # Parse result
        if result.is_a?(Array)
          # Streaming result: [content, tool_calls]
          response, tool_calls = result
        elsif result.is_a?(Hash) && result["tool_calls"]
          response = result["content"] || ""
          tool_calls = result["tool_calls"]
        else
          response = result.to_s
          tool_calls = nil
        end

        # Handle tool calls
        if tool_calls && !tool_calls.empty?
          log_debug("Got #{tool_calls.size} tool call(s)")

          # Add assistant message with tool calls to session
          @session.add("assistant", response, tool_calls: tool_calls)

          # Execute each tool call
          tool_calls.each do |tc|
            tool_name, arguments = parse_tool_call(tc)
            log_debug("Executing tool: #{tool_name}")

            # Fire pre-execution callback
            on_tool_call&.call(tool_name, arguments)

            begin
              tool_result = @tools.execute(tool_name, arguments)
            rescue StandardError => e
              tool_result = "ERROR: #{e.class}: #{e.message}"
            end

            # Fire post-execution callback
            on_tool_result&.call(tool_name, tool_result)

            log_debug("Tool result: #{tool_result[0..200]}")

            # Add tool result to session
            # Use the tool call ID for tracking
            tool_call_id = tc.is_a?(Hash) ? (tc["id"] || tool_name) : tool_name
            @session.add("tool", tool_result, tool_call_id: tool_call_id)
          end

          # Continue the loop to get the next response
          response = ""
          tool_calls = nil
          iterations += 1

          # Fire progress callback after each iteration
          on_progress&.call(iterations, tool_calls ? tool_calls.size : 0)
        else
          # No tool calls, we're done
          break
        end
      end

      # Add final assistant response to session
      @session.add("assistant", response) unless response.empty?

      # Prepend cron results to the user's response
      # Skip inline processing if a callback is registered (Telegram handles it)
      parts = []
      cron_tool = @tools.get("cron")
      has_callback = cron_tool && cron_tool.respond_to?(:has_fire_callback?) && cron_tool.has_fire_callback?

      unless has_callback
        cron_results.each do |cr|
          warn "[cron] Processing job #{cr[:job_id]} mode=#{cr[:mode]}" if Rubot.debug?
          case cr[:mode]
          when "agent_turn"
            cron_response = process_cron(cr[:result][:agent_message])
            warn "[cron] agent_turn response: #{(cron_response || '(nil)')[0..100]}" if Rubot.debug?
            parts << cron_response if cron_response && !cron_response.empty?
          when "deliver"
            warn "[cron] deliver message: #{(cr[:result][:deliver_message] || '(nil)')[0..100]}" if Rubot.debug?
            parts << cr[:result][:deliver_message]
          when "command"
            output = cr[:result][:output] || "(no output)"
            warn "[cron] command output: #{output[0..100]}" if Rubot.debug?
            parts << "⏰ Cron job fired: #{cr[:result][:output]}"
          end
        end
      end
      parts << response if response && !response.empty?

      combined = parts.join("\n\n---\n\n")
      warn "[cron] Combined response (#{parts.size} parts): #{combined[0..200]}" if Rubot.debug?
      combined
    end

    def clear_session
      @session.clear!
    end

    # Switch to a different session (e.g. per-topic in Telegram)
    def switch_session(session_id)
      return @session if @session.id == session_id
      @session = Session.new(session_id, workspace: @config.workspace)
      @session
    end

    def startup_info
      info = {
        provider: @provider.name,
        model: @config.model,
        tools: @tools.count,
        messages: @session.message_count
      }
      info[:soul] = "yes" if @soul.enabled?
      info[:memory] = "yes" if @memory.enabled?
      info[:agents] = "yes" if @agents_file.enabled?
      info[:safety] = @safety_guard.restrict_to_workspace ? "restricted" : "permissive"
      info[:skills] = @skill_registry.count if @skill_registry.any?
      info
    end

    # Build the full system prompt from all sources
    def build_system_prompt
      @skill_registry.reload!
      parts = []

      # 1. AGENTS.md rules (behavior guidelines)
      if @agents_file.enabled? && !@agents_file.rules.empty?
        parts << "# Agent Rules\n\n#{@agents_file.rules}"
      end

      # 2. SOUL.md (personality and identity)
      if @soul.enabled?
        parts << "# Soul\n\n#{@soul}"
      end

      # 3. MEMORY.md (persistent context)
      if @memory.enabled?
        parts << "# Memory\n\n#{@memory}"
      end

      # 4. Skills (specialized instruction sets)
      skill_prompt = @skill_registry.to_system_prompt
      parts << skill_prompt unless skill_prompt.empty?

      # 5. Default/config system prompt
      config_prompt = @config.system_prompt
      parts << config_prompt unless config_prompt.empty?

      parts.join("\n\n---\n\n")
    end

    private

    def apply_agents_overrides
      ag = @agents_file

      # Override config values if set in AGENTS.md frontmatter
      if ag.name
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["name"] = ag.name
      end

      if ag.model
        @config.data["model"] = ag.model
      end

      if ag.max_tokens
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["max_tokens"] = ag.max_tokens
      end

      if ag.temperature
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["temperature"] = ag.temperature
      end

      if ag.max_tool_iterations
        @config.data.dig("agents", "defaults") || @config.data["agents"] = { "defaults" => {} }
        @config.data.dig("agents", "defaults")["max_tool_iterations"] = ag.max_tool_iterations
      end

      # Apply tool overrides from AGENTS.md
      return if ag.tools_config.empty?
      tools = @config.data["tools"] || {}
      ag.tools_config.each do |tool_name, enabled|
        tools[tool_name.to_s] = { "enabled" => enabled }
      end
      @config.data["tools"] = tools unless ag.tools_config.empty?
    end

    # Set the workspace on the cron tool so jobs persist to disk
    def configure_cron_tool
      cron_tool = @tools.get("cron")
      return unless cron_tool && cron_tool.respond_to?(:workspace=)
      cron_tool.workspace = @config.workspace
    end

    # Inject the safety guard into all tools that support it.
    # Called after @tools is assigned, ensuring the guard is applied
    # regardless of whether tools came from the Agent's constructor
    # or were passed in externally (e.g. from bin/rubot or REPL).
    def inject_safety_guard
      return unless @tools.respond_to?(:all)
      @tools.all.each do |tool|
        next unless tool.respond_to?(:safety_guard=)
        tool.safety_guard = @safety_guard
      end
    end

    # Fire any due cron jobs and return their results.
    def fire_due_cron_jobs
      cron_tool = @tools.get("cron")
      return [] unless cron_tool && cron_tool.respond_to?(:scheduler)
      scheduler = cron_tool.scheduler
      scheduler.fire_due_jobs
    rescue StandardError => e
      warn "[cron] Error firing due jobs: #{e.class}: #{e.message}"
      []
    end

    def build_messages
      messages = []

      # Add system prompt (composed from all sources)
      messages << { "role" => "system", "content" => build_system_prompt }

      # Add conversation history (limited)
      history_limit = @config.history_limit
      recent_messages = @session.safe_history(limit: history_limit)

      recent_messages.each do |msg|
        formatted = { "role" => msg["role"], "content" => msg["content"] }

        # Handle tool calls for assistant messages
        if msg["role"] == "assistant" && msg["tool_calls"]
          formatted["tool_calls"] = msg["tool_calls"]
        end

        # Handle tool_call_id for tool results
        if msg["role"] == "tool"
          formatted["tool_call_id"] = msg["tool_call_id"]
        end

        messages << formatted
      end

      messages
    end

    def build_provider
      provider_name = @config.provider.downcase

      case provider_name
      when "openai", "openai_compatible", "azure", "deepseek", "groq", "gemini", "mistral", "perplexity"
        Providers::OpenAI.new(@config)
      when "anthropic", "claude"
        Providers::Anthropic.new(@config)
      when "ollama"
        Providers::Ollama.new(@config)
      else
        # Default to OpenAI-compatible
        warn "Unknown provider '#{provider_name}', falling back to OpenAI-compatible"
        Providers::OpenAI.new(@config)
      end
    end

    def tool_definitions
      return nil unless @config.tools_enabled
      enabled_list = @config.enabled_tools

      # If no explicit tool configuration, use all registered tools
      tools = if enabled_list.nil? || enabled_list.empty?
        @tools.all
      else
        @tools.all.select { |t| enabled_list.include?(t.name) }
      end

      # Always include memory tool if memory is enabled, regardless of config
      if @memory.enabled?
        memory_tool = @tools.get("memory")
        tools << memory_tool if memory_tool && !tools.include?(memory_tool)
      end

      tools
    end

    def parse_tool_call(tc)
      if tc.is_a?(Hash)
        fn = tc["function"]
        name = fn["name"]
        args_str = fn["arguments"]
      else
        fn = tc.function
        name = fn.name
        args_str = fn.arguments
      end

      arguments = args_str.is_a?(String) ? JSON.parse(args_str) : args_str
      [ name, arguments ]
    rescue JSON::ParserError
      [ name, {} ]
    end

    def log_debug(msg)
      warn "[debug] #{msg}" if @config.debug?
    end

    # -- Public methods accessible from background threads and channels --
    public

    # Process a cron message through the LLM. Called by the cron scheduler's
    # background thread.
    def process_cron(message)
      # Build local messages from session history ONLY (up to the last assistant response)
      # Do NOT include the current user message — this is a separate conversation turn
      local_messages = build_cron_messages
      local_messages << { "role" => "user", "content" => "⏰ Scheduled task fired:\n#{message}" }

      response = ""
      tool_calls = nil
      iterations = 0

      loop do
        break if iterations >= MAX_TOOL_ITERATIONS

        result = @provider.chat(local_messages, tools: tool_definitions)

        if result.is_a?(Array)
          response, tool_calls = result
        elsif result.is_a?(Hash) && result["tool_calls"]
          response = result["content"] || ""
          tool_calls = result["tool_calls"]
        else
          response = result.to_s
          tool_calls = nil
        end

        if tool_calls && !tool_calls.empty?
          local_messages << { "role" => "assistant", "content" => response, "tool_calls" => tool_calls }

          tool_calls.each do |tc|
            tool_name, arguments = parse_tool_call(tc)
            begin
              tool_result = @tools.execute(tool_name, arguments)
            rescue StandardError => e
              tool_result = "ERROR: #{e.class}: #{e.message}"
            end

            tool_call_id = tc.is_a?(Hash) ? (tc["id"] || tool_name) : tool_name
            local_messages << { "role" => "tool", "content" => tool_result, "tool_call_id" => tool_call_id }
          end

          response = ""
          tool_calls = nil
          iterations += 1
        else
          break
        end
      end

      # If the LLM returned empty, use the cron message itself as the response
      response = message if response.nil? || response.strip.empty?

      @session.add("assistant", response) unless response.empty?
      response
    end

    # Build messages for cron processing — uses conversation history
    # but excludes the current user message being processed.
    def build_cron_messages
      messages = []
      messages << { "role" => "system", "content" => build_system_prompt }

      history_limit = @config.history_limit
      all_history = @session.safe_history(limit: history_limit)

      # If the last message is a user message (the current one being processed),
      # exclude it so cron processing has clean context
      history = all_history.dup
      history.pop if history.last && history.last["role"] == "user"

      recent = history
      recent.each do |msg|
        formatted = { "role" => msg["role"], "content" => msg["content"] }
        formatted["tool_calls"] = msg["tool_calls"] if msg["role"] == "assistant" && msg["tool_calls"]
        formatted["tool_call_id"] = msg["tool_call_id"] if msg["role"] == "tool"
        messages << formatted
      end

      messages
    end
  end
end
