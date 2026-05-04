# frozen_string_literal: true

require "json"
require_relative "config"
require_relative "session"
require_relative "provider"
require_relative "tools/registry"

module Rubot
  class Agent
    MAX_TOOL_ITERATIONS = 10

    attr_reader :config, :provider, :session, :tools

    def initialize(config:, provider: nil, session_id: "default", tools: nil)
      @config = config
      @provider = provider || build_provider
      @session = Session.new(session_id, workspace: config.workspace)
      @tools = tools || Tools::Registry.new
      config.ensure_workspace
    end

    # Process a user message and return the final assistant response
    def process(message, &on_chunk)
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

            begin
              tool_result = @tools.execute(tool_name, arguments)
            rescue StandardError => e
              tool_result = "ERROR: #{e.class}: #{e.message}"
            end

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
        else
          # No tool calls, we're done
          break
        end
      end

      # Add final assistant response to session
      @session.add("assistant", response) unless response.empty?
      response
    end

    def clear_session
      @session.clear!
    end

    def startup_info
      {
        provider: @provider.name,
        model: @config.model,
        tools: @tools.count,
        messages: @session.message_count
      }
    end

    private

    def build_messages
      messages = []

      # Add system prompt
      messages << { "role" => "system", "content" => @config.system_prompt }

      # Add conversation history (limited)
      history_limit = @config.history_limit
      recent_messages = history_limit ? @session.conversation_history.last(history_limit) : @session.conversation_history

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
      return nil if enabled_list.nil? || enabled_list.empty?
      @tools.all.select { |t| enabled_list.include?(t.name) }
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
  end
end
