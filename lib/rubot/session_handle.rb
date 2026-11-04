# frozen_string_literal: true

require_relative "actors/session_actor"

module Rubot
  module Actors
    # Main-Ractor-side proxy for a SessionActor.
    #
    # It mirrors the subset of the Agent API used by channels and the REPL,
    # so command handlers can be written once for both legacy (in-process
    # Agent) and actor modes.
    class SessionHandle
      attr_reader :session_id

      def initialize(ractor, session_id)
        @ractor = ractor
        @session_id = session_id.to_s
        @views = {}
      end

      def actor?
        true
      end

      # Synchronous request/reply to the session Ractor.
      def call(op, **payload)
        port = Ractor::Port.new
        @ractor.send({ type: :request, op: op, port: port }.merge(payload))
        status, value = port.receive
        raise ActorError, value.to_s if status == :error
        value
      ensure
        port&.close
      end

      def process(message, on_tool_call: nil, on_tool_result: nil, on_progress: nil, on_confirm: nil,
                  on_assistant_text: nil, stream: true, &on_chunk)
        events = Ractor::Port.new
        control = nil

        @ractor.send({ type: :message, text: message, events: events, stream: stream })

        response = +""
        loop do
          event = events.receive
          case event[0]
          when :control
            # Port created by the session Ractor; we may only send on it.
            control = event[1]
          when :chunk
            on_chunk&.call(event[1])
          when :assistant_text
            on_assistant_text&.call(event[1])
          when :tool_started
            on_tool_call&.call(event[1], event[2])
          when :tool_finished
            on_tool_result&.call(event[1], event[2])
          when :progress
            on_progress&.call(event[1], event[2])
          when :confirm
            answered = begin
              on_confirm ? on_confirm.call(event[2], event[3]) : false
            rescue StandardError
              false # fail closed; never leave the actor blocked on a reply
            end
            raise ActorError, "confirmation channel not established" unless control

            control << [ :confirm_result, event[1], answered ]
          when :done
            response = event[1].to_s
            break
          when :error
            raise ActorError, "#{event[1]}: #{event[2]}\n#{Array(event[3]).join("\n")}"
          end
        end

        response
      ensure
        events&.close
      end

      def process_cron(text)
        call(:process_cron, text: text)
      end

      def startup_info
        call(:info)
      end

      def active_model_name
        call(:active_model_name)
      end

      def use_model(name)
        call(:use_model, name: name)
      end

      def clear_session
        call(:clear_session)
      end

      def config
        @views[:config] ||= ConfigView.new(self)
      end

      def provider
        @views[:provider] ||= ProviderView.new(self)
      end

      def session
        @views[:session] ||= SessionView.new(self)
      end

      def tools
        @views[:tools] ||= ToolsView.new(self)
      end

      def soul
        @views[:soul] ||= ContentView.new(self, :soul)
      end

      def memory
        @views[:memory] ||= ContentView.new(self, :memory)
      end

      def agents_file
        @views[:agents] ||= ContentView.new(self, :agents)
      end

      def skill_registry
        @views[:skills] ||= SkillRegistryView.new(self)
      end

      class ConfigView
        def initialize(handle)
          @handle = handle
        end

        def models
          @handle.call(:models)
        end

        def model_entry_by_name(name)
          @handle.call(:model_entry, name: name)
        end

        def active_model_entry
          @handle.call(:active_model_entry)
        end

        def workspace
          @handle.call(:workspace)
        end

        def name
          @handle.call(:active_model_name)
        end
      end

      class ProviderView
        def initialize(handle)
          @handle = handle
        end

        def name
          @handle.call(:provider_name)
        end
      end

      class SessionView
        def initialize(handle)
          @handle = handle
        end

        def id
          @handle.session_id
        end

        def message_count
          @handle.call(:message_count)
        end

        def model_override
          @handle.call(:session_model_override)
        end

        def forced_skill
          @handle.call(:forced_skill)
        end

        def forced_skill=(name)
          if name.nil? || name.to_s.empty?
            @handle.call(:clear_forced_skill)
          else
            @handle.call(:set_forced_skill, name: name)
          end
        end

        def save!
          nil
        end
      end

      class ContentView
        OPS = {
          soul:   { enabled: :soul_enabled,   content: :soul_content },
          memory: { enabled: :memory_enabled, content: :memory_read },
          agents: { enabled: :agents_enabled, content: :agents_raw }
        }.freeze

        def initialize(handle, kind)
          @handle = handle
          @ops = OPS.fetch(kind)
        end

        def enabled?
          @handle.call(@ops[:enabled])
        end

        def to_s
          @handle.call(@ops[:content]).to_s
        end

        def read
          to_s
        end

        def raw
          to_s
        end
      end

      class ToolView
        attr_reader :name

        def initialize(handle, name)
          @handle = handle
          @name = name
        end

        def description
          @handle.call(:tool_description, name: @name).to_s
        end
      end

      class ToolsView
        def initialize(handle)
          @handle = handle
          @proxies = {}
        end

        def get(name)
          @proxies[name] ||= ToolProxy.new(@handle, name)
        end

        def all
          @handle.call(:tool_list).map { |name| ToolView.new(@handle, name) }
        end

        def count
          @handle.call(:tool_count)
        end

        def names
          @handle.call(:tool_list)
        end
      end

      class ToolProxy
        attr_reader :name

        def initialize(handle, name)
          @handle = handle
          @name = name
          @delivery_context = nil
        end

        def execute(arguments)
          @handle.call(:tool_execute, name: @name, arguments: arguments)
        end

        # Persist the context on the actor-side tool immediately, because
        # a later SessionHandle for the same session is a different proxy.
        def delivery_context=(context)
          @delivery_context = context
          @handle.call(:tool_context, name: @name, context: context)
        end

        def delivery_context
          @delivery_context
        end

        # Cron jobs are fired by the CronActor; the agent must not fire
        # them inline in actor mode.
        def scheduler
          nil
        end

        def on_fire(&_block)
          nil
        end

        def has_fire_callback?
          true
        end
      end

      class SkillView
        attr_reader :name, :summary

        def initialize(data)
          @name = data[:name]
          @summary = data[:summary]
          @enabled = data[:enabled]
        end

        def enabled?
          @enabled
        end
      end

      class SkillRegistryView
        def initialize(handle)
          @handle = handle
        end

        def reload!
          @handle.call(:skills_reload)
        end

        def all
          @handle.call(:skills).to_h { |s| [ s[:name], SkillView.new(s) ] }
        end

        def get(name)
          all[name]
        end

        def any?
          !all.empty?
        end

        def count
          all.size
        end
      end
    end
  end
end
