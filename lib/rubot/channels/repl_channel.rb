# frozen_string_literal: true

require_relative "../repl"

module Rubot
  module Channels
    # Wraps the existing REPL as a channel.
    # This allows the terminal REPL to be treated as just another channel,
    # making the architecture consistent and extensible.
    class REPLChannel < Channel
      def initialize(agent:, channel_config: {})
        super
        @stream = channel_config.fetch("stream", true)
      end

      def start
        @running = true
        register_signal_handlers

        repl = REPL.new(@agent, stream: @stream)
        repl.run
      end

      def stop
        @running = false
      end

      # Override to NOT trap SIGINT — let Reline handle Ctrl+C natively.
      # The REPL already rescues Interrupt and exits gracefully.
      def register_signal_handlers
        Signal.trap("TERM") do
          warn "\n[repl] Received TERM, stopping..."
          stop
        end
      end
    end
  end
end
