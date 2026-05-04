# frozen_string_literal: true

module Rubot
  # Base class for all communication channels.
  # Subclass this to implement channels for Telegram, Discord, Slack, web, etc.
  #
  # Each channel is responsible for:
  #   - Receiving messages from users
  #   - Forwarding them to the Agent for processing
  #   - Sending the response back to the user
  #
  # Channels run in a lifecycle: #start → loop { receive → process → send } → #stop
  class Channel
    attr_reader :agent, :config, :name

    # @param agent [Rubot::Agent] The AI agent to process messages
    # @param channel_config [Hash] Channel-specific configuration from rubot.yml
    def initialize(agent:, channel_config: {})
      @agent = agent
      @config = channel_config
      @name = self.class.name.split("::").last.downcase
      @running = false
    end

    # Start the channel. Should block until the channel is stopped.
    # Subclasses must override this.
    def start
      raise NotImplementedError, "#{self.class} must implement #start"
    end

    # Stop the channel gracefully.
    # Subclasses should override this if they need cleanup.
    def stop
      @running = false
    end

    # Hook called before the agent processes a user message.
    # Override in subclasses to intercept, transform, or block input.
    #
    # Return values:
    #   String         — process this message through the agent
    #   nil            — skip processing silently (returns nil)
    #   [:skip, text]  — skip the agent, return `text` as the response
    #
    # @param message [String] The raw user message
    # @return [String, nil, Array] See above
    def before_process(message)
      # No-op by default; override in subclasses
      message
    end

    # Hook called after the agent generates a response.
    # Override in subclasses to transform or filter the output.
    #
    # @param message [String] The original user message
    # @param response [String] The agent's response
    # @return [String] The final response to send back
    def after_process(message, response)
      # No-op by default; override in subclasses
      response
    end

    # Process a single message through the agent and return the response.
    # Shared implementation used by all channels.
    #
    # @param message [String] The user's message
    # @param session_id [String, nil] Optional session ID to switch to
    # @return [String, nil] The agent's response, or nil if processing was skipped
    def process_message(message, session_id: nil)
      @agent.switch_session(session_id) if session_id

      result = before_process(message)

      if result.is_a?(Array) && result[0] == :skip
        return after_process(message, result[1].to_s)
      end

      return nil if result.nil?

      response = @agent.process(result) do |chunk|
        on_stream_chunk(chunk) if respond_to?(:on_stream_chunk)
      end

      after_process(message, response)
    rescue StandardError => e
      handle_error(e, message)
    end

    # Called for each streaming chunk from the agent.
    # Override in subclasses to stream responses in real-time.
    #
    # @param chunk [String] A chunk of the streamed response
    def on_stream_chunk(chunk)
      # No-op by default; override in subclasses that support streaming
    end

    # Handle errors during message processing.
    # Override in subclasses for channel-specific error handling.
    #
    # @param error [StandardError] The error that occurred
    # @param message [String] The original message that caused the error
    # @return [String] A user-friendly error message
    def handle_error(error, message = nil)
      msg = "❌ Sorry, an error occurred: #{error.message}"
      warn "[#{@name}] Error processing message: #{error.class}: #{error.message}"
      warn error.backtrace.first(5).join("\n") if Rubot.debug?
      msg
    end

    # Whether the channel is currently running.
    def running?
      @running
    end

    # Signal handler registration helper.
    # Registers a handler to gracefully stop this channel on SIGINT/SIGTERM.
    def register_signal_handlers
      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          warn "\n[#{@name}] Received #{signal}, stopping..."
          stop
        end
      end
    end
  end
end
