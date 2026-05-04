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
    end
  end
end
