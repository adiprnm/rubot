# frozen_string_literal: true

require "securerandom"
require_relative "../agent"
require_relative "../cancellation"
require_relative "../config"

module Rubot
  module Actors
    class ActorError < StandardError; end

    # Owns a single Agent (and therefore a single Session) inside a Ractor.
    #
    # Requests arrive on the Ractor's default port:
    #   - { type: :message, text:, events:, stream: }   streaming turn
    #   - { type: :request, op:, port:, ... }           synchronous call
    #   - { type: :shutdown }
    #
    # Responses are messages on the port supplied by the caller. The agent's
    # callbacks are constructed *inside* this Ractor and only capture
    # shareable ports, so no Proc crosses a Ractor boundary.
    #
    # Confirmation replies use a port created *here* and handed to the caller
    # as an `[:control, port]` event: Ractor::Port#receive only works from the
    # Ractor that created the port.
    class SessionActor
      attr_reader :ractor, :session_id, :stop_port

      def initialize(config_data:, config_path:, session_id:, cron_actor: nil, persona: nil)
        @session_id = session_id.to_s

        # The stop port has to be created inside the Ractor (only the creating
        # Ractor may receive from it) and handed back before this constructor
        # returns, so a /stop can reach a busy actor without queueing behind
        # the turn it is meant to stop.
        bootstrap = Ractor::Port.new

        @ractor = Ractor.new(
          {
            config_data: config_data,
            config_path: config_path,
            session_id: @session_id,
            cron_actor: cron_actor,
            persona: persona
          },
          bootstrap,
          name: "rubot-session-#{@session_id}"
        ) do |args, boot|
          stop_port = Ractor::Port.new
          cancellation = Rubot::Cancellation.new
          # The watcher starts before the agent exists so a stop or a steer
          # can land during construction instead of queueing behind it.
          agent = nil

          watcher = Thread.new do
            loop do
              signal = stop_port.receive
              break if signal == :shutdown

              if signal.is_a?(Array) && signal[0] == :steer
                agent&.steer(signal[1])
              else
                cancellation.cancel!
              end
            end
          rescue Ractor::ClosedError
            nil
          end

          boot << stop_port

          config = Config.from_data(args[:config_data], config_path: args[:config_path])
          agent = Agent.new(config: config, session_id: args[:session_id], persona: args[:persona])
          agent.cancellation = cancellation
          agent.cron_ractor = args[:cron_actor] if args[:cron_actor]
          SessionActor.serve(agent, args[:session_id], stop_port: stop_port, watcher: watcher)
        end

        @stop_port = bootstrap.receive
        bootstrap.close
      end

      # Runs inside the Ractor.
      def self.serve(agent, session_id, stop_port: nil, watcher: nil)
        loop do
          msg = Ractor.receive
          case msg[:type]
          when :message
            handle_message(agent, msg)
          when :request
            handle_request(agent, session_id, msg)
          when :shutdown
            break
          end
        end
      ensure
        # Closing the port wakes the watcher (Ractor::ClosedError) on shutdown.
        stop_port&.close
        watcher&.join(1)
      end

      def self.handle_message(agent, msg)
        events = msg[:events]

        # Ractor::Port#receive is only allowed in the Ractor that created the
        # port, so the confirmation channel is created here and sent to the
        # caller (which may only send on it).
        control = Ractor::Port.new
        events << [ :control, control ]

        callbacks = {
          on_assistant_text: ->(text) { events << [ :assistant_text, text ] },
          on_tool_call: ->(name, args) { events << [ :tool_started, name, args ] },
          on_tool_result: ->(name, result) { events << [ :tool_finished, name, result ] },
          on_progress: ->(round, tool_count) { events << [ :progress, round, tool_count ] },
          on_steer: ->(text) { events << [ :steered, text ] },
          on_stopped: -> { events << [ :stopped ] },
          on_confirm: lambda do |name, args|
            id = SecureRandom.hex(6)
            events << [ :confirm, id, name, args ]
            loop do
              reply = control.receive
              next unless reply[0] == :confirm_result
              next unless reply[1] == id
              break reply[2]
            end
          end,
          stream: msg.fetch(:stream, true)
        }

        response = if msg.fetch(:stream, true)
          agent.process(msg[:text], **callbacks) { |chunk| events << [ :chunk, chunk ] }
        else
          agent.process(msg[:text], **callbacks)
        end

        events << [ :done, response ]
      rescue StandardError => e
        events << [ :error, e.class.name, e.message, Array(e.backtrace).first(5) ]
      ensure
        control&.close
      end

      def self.handle_request(agent, session_id, msg)
        value = case msg[:op]
        when :info                 then agent.startup_info
        when :usage_report         then agent.usage_report
        when :opencode_usage       then agent.opencode_usage
        when :models               then agent.config.models
        when :model_entry          then agent.config.model_entry_by_name(msg[:name])
        when :active_model_entry   then agent.config.active_model_entry
        when :workspace            then agent.config.workspace
        when :external_editor      then agent.config.external_editor
        when :active_model_name    then agent.active_model_name
        when :active_model_preset  then agent.active_model_preset
        when :model_presets        then agent.model_presets
        when :use_model_preset     then agent.use_model_preset(msg[:name], preset: msg[:preset])
        when :provider_name        then agent.provider.name
        when :session_id           then session_id
        when :message_count        then agent.session.message_count
        when :session_model_override then agent.session.model_override
        when :model_preset        then agent.session.model_preset
        when :forced_skill         then agent.session.forced_skill
        when :use_model            then agent.use_model(msg[:name])
        when :persona              then agent.persona_info
        when :set_persona          then agent.set_persona(msg[:persona])
        when :clear_session        then agent.clear_session
        when :compact_session      then agent.compact_session
        when :context_window       then agent.context_window_tokens
        when :estimated_context    then agent.estimated_context_tokens
        when :tool_list            then agent.tools.all.map(&:name)
        when :tool_count           then agent.tools.count
        when :tool_description     then agent.tools.get(msg[:name])&.description.to_s
        when :tool_execute         then agent.tools.execute(msg[:name], msg[:arguments])
        when :tool_context         then set_tool_context(agent, msg[:name], msg[:context])
        when :soul_enabled         then agent.soul.enabled?
        when :soul_content         then agent.soul.to_s
        when :memory_enabled       then agent.memory.enabled?
        when :memory_read          then agent.memory.read
        when :agents_enabled       then agent.agents_file.enabled?
        when :agents_raw           then agent.agents_file.raw
        when :skills               then skill_list(agent)
        when :skills_reload        then reload_skills(agent)
        when :set_forced_skill     then set_forced_skill(agent, msg[:name])
        when :clear_forced_skill   then clear_forced_skill(agent)
        when :process_cron         then agent.process_cron(msg[:text])
        when :flush_learning       then agent.flush_learning
        else
          raise ArgumentError, "Unknown session request: #{msg[:op].inspect}"
        end

        msg[:port] << [ :ok, value ]
      rescue StandardError => e
        msg[:port] << [ :error, "#{e.class}: #{e.message}" ]
      end

      def self.set_tool_context(agent, name, context)
        tool = agent.tools.get(name)
        tool.delivery_context = context if tool.respond_to?(:delivery_context=)
        nil
      end

      def self.skill_list(agent)
        agent.skill_registry.all.values.map do |skill|
          { name: skill.name, summary: skill.summary, enabled: skill.enabled? }
        end
      end

      def self.reload_skills(agent)
        agent.skill_registry.reload!
        nil
      end

      def self.set_forced_skill(agent, name)
        agent.skill_registry.reload!
        skill = agent.skill_registry.get(name)
        return false unless skill && skill.enabled?

        agent.session.forced_skill = name
        agent.session.save!
        true
      end

      def self.clear_forced_skill(agent)
        return false if agent.session.forced_skill.nil?

        agent.session.forced_skill = nil
        agent.session.save!
        true
      end

      def shutdown
        @ractor.send({ type: :shutdown })
        @ractor.join
      rescue Ractor::ClosedError, Ractor::RemoteError
        nil
      end
    end
  end
end
