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
require_relative "memory_extractor"
require_relative "tools/feedback_learner"

module Rubot
  class Agent
    MAX_TOOL_ITERATIONS = 10

    attr_reader :config, :provider, :session, :tools, :soul, :memory, :agents_file, :skill_registry, :safety_guard, :session_model

    def initialize(config:, provider: nil, session_id: "default", tools: nil)
      @config = config
      @session = Session.new(session_id, workspace: config.workspace)
      @session_model = @session.model_override
      @provider = provider || build_provider(@session_model)

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

      # Adaptive features (always on)
      @memory_extractor = MemoryExtractor.new(provider: @provider, memory: @memory)
      @feedback_learner = Tools::FeedbackLearner.new(memory: @memory)

      # Apply AGENTS.md overrides to config
      apply_agents_overrides if @agents_file.enabled?

      # Set workspace on cron tool so jobs persist to disk
      configure_cron_tool
      @cron_ractor = nil
    end

    # Attach a CronActor handle. When present, cron jobs are owned by the
    # actor and this agent no longer fires them inline.
    def cron_ractor=(ractor)
      @cron_ractor = ractor
      cron_tool = @tools.get("cron")
      cron_tool.cron_actor = ractor if cron_tool.respond_to?(:cron_actor=)
    end

    # Create a new Agent instance with a different session but sharing
    # the same config, tools, and all shared resources.
    # This enables concurrent request processing without cross-session
    # interference — each request gets an isolated session on its
    # own agent instance.
    def for_session(session_id)
      # Let Agent.new handle session loading and provider building correctly.
      # Do NOT override @provider — it was already set up for this session.
      copy = Agent.new(
        config: @config,
        session_id: session_id,
        tools: @tools
      )
      # Share stateless/shared resources only (skip @provider, which
      # Agent#new already built correctly for the target session)
      copy.instance_variable_set(:@safety_guard, @safety_guard)
      copy.instance_variable_set(:@soul, @soul)
      copy.instance_variable_set(:@memory, @memory)
      copy.instance_variable_set(:@agents_file, @agents_file)
      copy.instance_variable_set(:@skill_registry, @skill_registry)
      copy.instance_variable_set(:@memory_extractor, @memory_extractor)
      copy.instance_variable_set(:@feedback_learner, @feedback_learner)
      copy
    end

    # Process a user message and return the final assistant response.
    # Due cron jobs are fired first, their output prepended to the response.
    #
    # Callbacks (optional):
    #   on_tool_call:     Called before each tool executes. Yields (tool_name, arguments).
    #   on_tool_result:   Called after each tool executes. Yields (tool_name, result).
    #   on_progress:      Called after each full tool-call iteration. Yields (iteration_count, tool_count).
    #   on_confirm:       Called before dangerous actions that could cause data loss.
    #                     Yields (tool_name, arguments). Return truthy to proceed, falsy to skip.
    def process(message, on_tool_call: nil, on_tool_result: nil, on_progress: nil, on_confirm: nil, stream: true, &on_chunk)
      # Fire any due cron jobs and collect their results
      cron_results = fire_due_cron_jobs
      warn "[cron] fire_due_cron_jobs returned #{cron_results.size} result(s)" if Rubot.debug?

      # Add user message to session
      @session.add("user", message)

      # Adaptive: extract memory from user message (auto-remember facts)
      run_memory_extraction(message)

      # Adaptive: learn from feedback (detect corrections)
      run_feedback_learning(message)

      response = ""
      tool_calls = nil
      reasoning_content = nil
      iterations = 0

      loop do
        break if iterations >= MAX_TOOL_ITERATIONS

        # Adaptive: summarize old messages if approaching limit
        run_summarization

        messages = build_messages
        log_debug("Sending #{messages.size} messages to provider")

        result = if block_given? && stream
          @provider.chat_stream(messages, tools: tool_definitions) do |chunk, tool_data|
            response += chunk if chunk
            yield chunk if chunk && block_given?
          end
        else
          @provider.chat(messages, tools: tool_definitions)
        end

        # Parse result — both streaming and non-streaming now return Hash
        if result.is_a?(Hash)
          response = result["content"] || ""
          tool_calls = result["tool_calls"]
          reasoning_content = result["reasoning_content"]
        elsif result.is_a?(Array)
          # Legacy streaming format: [content, tool_calls]
          response, tool_calls = result
          reasoning_content = nil
        else
          response = result.to_s
          tool_calls = nil
          reasoning_content = nil
        end

        # Handle tool calls
        if tool_calls && !tool_calls.empty?
          log_debug("Got #{tool_calls.size} tool call(s)")

          # Add assistant message with tool calls to session
          @session.add("assistant", response, tool_calls: tool_calls, reasoning_content: reasoning_content)

          # Execute each tool call
          tool_calls.each do |tc|
            tool_name, arguments = parse_tool_call(tc)
            log_debug("Executing tool: #{tool_name}")

            # Use the tool call ID for tracking
            tool_call_id = tc.is_a?(Hash) ? (tc["id"] || tool_name) : tool_name

            # Check for dangerous action that could cause data loss
            tool = @tools.get(tool_name)
            if tool && tool.respond_to?(:dangerous_action?) && tool.dangerous_action?(arguments)
              log_debug("Dangerous action detected: #{tool_name} with args: #{arguments.inspect}")
              if on_confirm && !on_confirm.call(tool_name, arguments)
                log_debug("Action cancelled by user: #{tool_name}")
                @session.add("tool", "Action cancelled by user.", tool_call_id: tool_call_id)
                next
              end
            end

            # Fire pre-execution callback
            on_tool_call&.call(tool_name, arguments)

            begin
              tool_result = @tools.execute(tool_name, arguments)
            rescue StandardError => e
              tool_result = "ERROR: #{e.class}: #{e.message}"
            end

            # Tool output can be binary (e.g. reading a PNG); keep the transcript
            # and the chat message valid UTF-8.
            tool_result = Session.normalize_utf8(tool_result.to_s)

            # Fire post-execution callback
            on_tool_result&.call(tool_name, tool_result)

            log_debug("Tool result: #{tool_result[0..200]}")

            # Add tool result to session
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

      # Add final assistant response to session (only if not already added via tool-call branch)
      @session.add("assistant", response, reasoning_content: reasoning_content) unless response.empty?

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

      # Guard: if the LLM produced only tool calls with no text content
      # (e.g. read_file → grep → etc.), return the cron/tool summary or
      # a fallback so the user never gets a silent drop.
      if combined.empty? && iterations > 0
        fallback = build_fallback_response(iterations)
        combined = fallback if fallback && !fallback.empty?
      end

      warn "[cron] Combined response (#{parts.size} parts): #{combined[0..200]}" if Rubot.debug?
      combined
    end

    def clear_session
      @session.clear!
      @session_model = nil
      @provider = build_provider
    end

    # Switch to a different model for the current session.
    # The selected model persists within the active session but
    # is cleared when the user starts a new session.
    def use_model(model_name)
      model_name = model_name.to_s.strip
      entry = @config.model_entry_by_name(model_name)
      return nil if entry.nil?

      @session_model = model_name
      @session.model_override = model_name
      @session.save!
      rebuild_provider
      @session_model
    end

    # Returns the active model name (session override or config default)
    def active_model_name
      @session_model || @config.name
    end

    # Switch to a different session (e.g. per-topic in Telegram).
    # Applies the new session's model override if one was previously saved.
    def switch_session(session_id)
      return @session if @session.id == session_id
      @session = Session.new(session_id, workspace: @config.workspace)
      @session_model = @session.model_override
      rebuild_provider if @session_model
      @session
    end

    def startup_info
      model = active_model_name
      info = {
        provider: @provider.name,
        model: model,
        tools: @tools.count,
        messages: @session.message_count
      }
      info[:model_override] = true if model != @config.name
      info[:soul] = "yes" if @soul.enabled?
      info[:memory] = "yes" if @memory.enabled?
      info[:agents] = "yes" if @agents_file.enabled?
      info[:safety] = @safety_guard.restrict_to_workspace ? "restricted" : "permissive"
      info[:skills] = @skill_registry.count if @skill_registry.any?
      info[:adaptive] = "memory+summary+feedback"
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

      # 3b. Learned Corrections (from feedback learner)
      correction_prompt = @feedback_learner.to_system_prompt
      parts << correction_prompt unless correction_prompt.empty?

      # 3c. Conversation Summary (from session summarization)
      if @session&.summary_text
        parts << "# Previous Conversation Summary\n\n#{@session.summary_text}"
      end

      # 3d. Forced skill — injected directly to skip LLM tool-call overhead
      forced = resolve_forced_skill
      if forced
        parts << "# Active Skill: #{forced[:name]}\n\nYou MUST follow the instructions below for this response:\n\n#{forced[:content]}"
      end

      # 4. Skills (specialized instruction sets)
      skill_prompt = @skill_registry.to_system_prompt
      parts << skill_prompt unless skill_prompt.empty?

      # 4b. Current model identity (so the bot knows which model it's using)
      model_name = active_model_name
      model_entry = @config.model_entry_by_name(model_name) || @config.active_model_entry
      model_provider = model_entry["model"] || @config.model
      parts << "# Current Model\n\nYou are currently running as model: **#{model_name}** (#{model_provider}).\nWhen asked about which model you are, respond with: #{model_name}."

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
      return [] if @cron_ractor
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

        # Include reasoning_content for DeepSeek and other reasoning models
        if msg["role"] == "assistant" && msg["reasoning_content"]
          formatted["reasoning_content"] = msg["reasoning_content"]
        end

        # Handle tool_call_id for tool results
        if msg["role"] == "tool"
          formatted["tool_call_id"] = msg["tool_call_id"]
        end

        messages << formatted
      end

      messages
    end

    # Build a provider from an immutable settings snapshot. No config
    # mutation is performed, so this is safe to call from any Ractor.
    def build_provider(model_name = nil)
      settings = @config.provider_settings(model_name)
      provider_name = settings.provider.downcase

      case provider_name
      when "openai", "openai_compatible", "azure", "deepseek", "groq", "gemini", "mistral", "perplexity"
        Providers::OpenAI.new(settings)
      when "anthropic", "claude"
        Providers::Anthropic.new(settings)
      when "ollama"
        Providers::Ollama.new(settings)
      else
        # Default to OpenAI-compatible
        warn "Unknown provider '#{provider_name}', falling back to OpenAI-compatible"
        Providers::OpenAI.new(settings)
      end
    end

    # Rebuild the provider using the session-level model override.
    def rebuild_provider
      return if @session_model.nil?
      return if @config.model_entry_by_name(@session_model).nil?

      @provider = build_provider(@session_model)
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

    # Build a fallback response when the LLM produced only tool calls
    # with no text content, so the user never gets a silent drop.
    def build_fallback_response(iterations)
      return nil if iterations == 0

      # Summarize what the agent did
      tool_names = []
      @session.safe_history(limit: @config.history_limit).each do |msg|
        next unless msg["role"] == "tool"
        result = msg["content"].to_s.strip
        tool_names << (result.empty? ? "(empty)" : result[0..120])
      end

      if tool_names.any?
        "I completed #{iterations} step(s) of tool calls. Results:\n\n" +
          tool_names.map.with_index(1) { |r, i| "#{i}. #{r}" }.join("\n")
      else
        "I completed #{iterations} step(s) of processing but have no text result to share."
      end
    end

    # Resolve the forced skill for the current session, return {name, content} or nil.
    # Clears the forced_skill flag after use so it only applies once.
    def resolve_forced_skill
      skill_name = @session&.forced_skill
      return nil if skill_name.nil? || skill_name.empty?

      # Clear the flag so it only applies to the next message
      @session.forced_skill = nil
      @session.save! if @session.respond_to?(:save!)

      skill = @skill_registry.get(skill_name)
      return nil unless skill && skill.enabled?

      { name: skill.name, content: skill.content }
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
      reasoning_content = nil
      iterations = 0

      loop do
        break if iterations >= MAX_TOOL_ITERATIONS

        result = @provider.chat(local_messages, tools: tool_definitions)

        if result.is_a?(Hash)
          response = result["content"] || ""
          tool_calls = result["tool_calls"]
          reasoning_content = result["reasoning_content"]
        elsif result.is_a?(Array)
          response, tool_calls = result
          reasoning_content = nil
        else
          response = result.to_s
          tool_calls = nil
          reasoning_content = nil
        end

        if tool_calls && !tool_calls.empty?
          assistant_msg = { "role" => "assistant", "content" => response, "tool_calls" => tool_calls }
          assistant_msg["reasoning_content"] = reasoning_content if reasoning_content
          local_messages << assistant_msg

          tool_calls.each do |tc|
            tool_name, arguments = parse_tool_call(tc)
            begin
              tool_result = @tools.execute(tool_name, arguments)
            rescue StandardError => e
              tool_result = "ERROR: #{e.class}: #{e.message}"
            end

            # Tool output can be binary (e.g. reading a PNG); keep the transcript
            # and the chat message valid UTF-8.
            tool_result = Session.normalize_utf8(tool_result.to_s)

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

      @session.add("assistant", response, reasoning_content: reasoning_content) unless response.empty?
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
        formatted["reasoning_content"] = msg["reasoning_content"] if msg["role"] == "assistant" && msg["reasoning_content"]
        messages << formatted
      end

      messages
    end

    # --- Adaptive feature helpers ---

    # Run memory extraction on the user message (always on)
    def run_memory_extraction(message)
      return unless @memory_extractor
      return unless @memory.enabled?

      extracted = @memory_extractor.extract(message)
      return if extracted.empty?

      if Rubot.debug?
        extracted.each do |item|
          warn "[memory_extractor] Stored [#{item[:section]}]: #{item[:fact]}"
        end
      end
    end

    # Run feedback learning — detect if user is correcting the bot (always on)
    def run_feedback_learning(message)
      return unless @feedback_learner
      return unless @memory.enabled?

      # Get previous turns (excluding the current user message)
      previous_turns = @session.conversation_history

      @feedback_learner.process(message, previous_turns)
    end

    # Run conversation summarization if approaching the limit (always on)
    def run_summarization
      return unless @session.respond_to?(:summarize_and_trim!)

      summary = @session.summarize_and_trim!(
        provider: @provider,
        system_prompt: build_system_prompt
      )
      warn "[summarization] Generated summary fragment" if summary && Rubot.debug?
    end
  end
end
