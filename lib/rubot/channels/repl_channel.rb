# frozen_string_literal: true

require_relative "../repl"

module Rubot
  module Channels
    # Wraps the existing REPL as a channel.
    # This allows the terminal REPL to be treated as just another channel,
    # making the architecture consistent and extensible.
    class REPLChannel < Channel
      def initialize(agent: nil, pool: nil, app_config: nil, channel_config: {})
        super
        @stream = channel_config.fetch("stream", true)
      end

      def start
        @running = true
        register_signal_handlers

        start_cron_listener { |result| handle_cron_fire(result) } if actor_mode?

        repl = REPL.new(@agent, stream: @stream, pool: @pool)
        repl.run
      ensure
        stop_cron_listener
        shutdown_pool
      end

      def stop
        @running = false
        stop_cron_listener
        shutdown_pool
      end

      # Override to NOT trap SIGINT — let Reline handle Ctrl+C natively.
      # The REPL already rescues Interrupt and exits gracefully.
      def register_signal_handlers
        Signal.trap("TERM") do
          warn "\n[repl] Received TERM, stopping..."
          stop
        end
      end

      private

      # Deliver background cron results into the terminal.
      def handle_cron_fire(result)
        case result[:mode]
        when "command"
          output = result[:result][:output] || "(no output)"
          puts "\n⏰ Cron: #{result[:description] || result[:job_id]}\n#{output}\n"
        when "deliver"
          puts "\n⏰ #{result[:result][:deliver_message]}\n"
        when "agent_turn"
          response = @pool.for("default").process_cron(result[:result][:agent_message])
          puts "\n⏰ #{response}\n" if response && !response.empty?
        end
      rescue StandardError => e
        warn "[cron] REPL callback error: #{e.class}: #{e.message}"
      end
    end
  end
end
