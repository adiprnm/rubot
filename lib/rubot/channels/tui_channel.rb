# frozen_string_literal: true

require_relative "../tui"

module Rubot
  module Channels
    # Wraps Rubot::TUI (the terminal chat UI) as a channel. This lets the
    # terminal be treated like any other channel, keeping the architecture
    # consistent and extensible.
    class TuiChannel < Channel
      def initialize(agent: nil, pool: nil, app_config: nil, channel_config: {})
        # The terminal channel writes files to the configured workspace
        # (~/.rubot/workspace by default), not to the directory rubot was
        # launched from. The launch directory is still recorded as the
        # sessions' origin so /resume can filter to the current project.
        if app_config && pool.nil? && agent.nil?
          app_config = app_config.with_workspace(app_config.workspace, sessions_cwd: Dir.pwd)
        end
        super(agent: agent, pool: pool, app_config: app_config, channel_config: channel_config)
        @stream = channel_config.fetch("stream", true)
      end

      def start
        @running = true
        register_signal_handlers

        start_cron_listener { |result| handle_cron_fire(result) } if actor_mode?

        @tui_instance = Rubot::TUI.new(@agent, stream: @stream, pool: @pool)
        @tui_instance.run
      ensure
        stop_cron_listener
        shutdown_pool
      end

      def stop
        @running = false
        @tui_instance&.stop
        stop_cron_listener
        shutdown_pool
      end

      # Override to NOT trap SIGINT — raw mode means ctrl-c arrives as a key,
      # and the TUI handles it itself (quit while idle, blocked by dialogs).
      def register_signal_handlers
        Signal.trap("TERM") do
          warn "\n[tui] Received TERM, stopping..."
          stop
        end
      end

      private

      # Deliver background cron results into the terminal.
      def handle_cron_fire(result)
        case result[:mode]
        when "command"
          output = result[:result][:output] || "(no output)"
          @tui_instance&.deliver_cron("Cron: #{result[:description] || result[:job_id]}\n#{output}")
        when "deliver"
          @tui_instance&.deliver_cron(result[:result][:deliver_message].to_s)
        when "agent_turn"
          # The job names the persona it was written in; running it in that
          # persona's conversation keeps the answer in the same voice. Without
          # one, the terminal's own agent is the right one.
          sid = result[:slug].to_s.strip
          session_id = sid.empty? ? "default" : "tui_#{sid}"
          response = @pool.for(session_id).process_cron(
            result[:result][:agent_message],
            fresh: result[:new_session] ? true : false
          )
          @tui_instance&.deliver_cron(response) if response && !response.empty?
        end
      rescue StandardError => e
        warn "[cron] TUI callback error: #{e.class}: #{e.message}"
      end
    end
  end
end
