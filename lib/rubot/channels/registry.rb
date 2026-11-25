# frozen_string_literal: true

require_relative "telegram"
require_relative "tui_channel"
require_relative "web"

module Rubot
  module Channels
    # Registry that loads and starts channels based on configuration.
    module Registry
      CHANNEL_MAP = {
        "telegram" => Telegram,
        "web" => Web,
        "tui" => TuiChannel,
        "repl" => TuiChannel,       # legacy alias
        "terminal" => TuiChannel,
        "console" => TuiChannel
      }.freeze

      # Load and start all channels configured in `data["channels"]`.
      # If no channels are configured, starts REPL as the default.
      #
      # @param data [Hash] The full config data hash
      # @param config [Rubot::Config, nil] live config used to build session actors
      # @param agent [Rubot::Agent, nil] legacy in-process agent
      # @param options [Hash] CLI options that may override channel selection
      # @return [Array<Rubot::Channel>] The started channel instances
      def self.start_channels(data:, config: nil, agent: nil, options: {})
        # The language is settled once, before a single channel is built: the
        # per-channel rescue below turns a failure into "Skipping channel", and
        # a language nobody speaks must not be skipped into a fallback. Here it
        # reaches the launch as the error it is.
        config&.apply_locale!

        channel_configs = build_channel_list(data, options)
        return channel_configs if channel_configs.empty?

        channels = channel_configs.filter_map do |name, channel_config|
          klass = CHANNEL_MAP[name]
          raise ArgumentError, "Unknown channel: #{name}. Available: #{CHANNEL_MAP.keys.join(', ')}" unless klass

          # Skip disabled channels
          if channel_config && channel_config["enabled"] == false
            warn "[registry] Channel '#{name}' is disabled"
            next
          end

          warn "[registry] Starting channel: #{name}"
          channel = klass.new(
            agent: agent,
            app_config: config,
            channel_config: channel_config || {}
          )
          channel.start
          channel
        rescue StandardError => e
          warn "[registry] Skipping channel '#{name}': #{e.message}"
          nil
        end

        raise "No channels could be started." if channels.empty?

        channels
      end

      # Build a list of channels to start from config and CLI options.
      #
      # Priority:
      #   1. CLI --channel flag (overrides channel selection, but uses config)
      #   2. Config "channels" section
      #   3. Default to REPL
      def self.build_channel_list(data, options)
        # CLI override — use config from the channels section if available
        if options[:channel]
          name = options[:channel].downcase
          channels = data["channels"]
          config = channels.is_a?(Hash) ? channels[name] : nil
          return [ [ name, config || {} ] ]
        end

        # Config-based channels
        channels = data["channels"]
        return [] unless channels

        # Channels can be a hash (name => config) or an array of names
        if channels.is_a?(Hash)
          channels.map { |name, cfg| [ name.to_s.downcase, cfg ] }
        elsif channels.is_a?(Array)
          channels.map { |name| [ name.to_s.downcase, {} ] }
        else
          []
        end
      end
    end
  end
end
