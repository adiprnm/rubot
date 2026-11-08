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
      # Errors the actor reports by name keep their class on this side of the
      # Ractor boundary, so callers can tell "the provider throttled us" from
      # an unexpected failure instead of matching on a message string.
      PASSTHROUGH_ERRORS = {
        "Rubot::RateLimitError" => Rubot::RateLimitError,
        "Rubot::Cancelled" => Rubot::Cancelled
      }.freeze

      attr_reader :session_id

      def initialize(ractor, session_id, stop_port = nil)
        @ractor = ractor
        @session_id = session_id.to_s
        @stop_port = stop_port
        @views = {}
      end

      def actor?
        true
      end

      # Stop the turn running in this session. This must not be a normal
      # request: the actor is busy running the turn, so the request would only
      # be read after it finished. The signal goes straight to the watcher
      # thread that lives inside the session Ractor.
      def cancel!
        return false unless @stop_port

        @stop_port << :stop
        true
      rescue Ractor::ClosedError
        false
      end

      # Queue a message for the turn already running in the session actor,
      # without blocking. Like #cancel!, this bypasses the request queue:
      # the actor only reads requests once the turn has finished. The message
      # is delivered between rounds by the agent itself.
      def steer(text)
        return false unless @stop_port
        return false if text.to_s.strip.empty?

        @stop_port << [ :steer, text.to_s ]
        true
      rescue Ractor::ClosedError
        false
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
                  on_assistant_text: nil, on_steer: nil, on_stopped: nil, on_usage: nil,
                  stream: true, &on_chunk)
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
            on_tool_call&.call(event[1], event[2], event[3])
          when :tool_finished
            on_tool_result&.call(event[1], event[2], event[3])
          when :progress
            on_progress&.call(event[1], event[2])
          when :usage
            on_usage&.call(event[1])
          when :steered
            on_steer&.call(event[1])
          when :stopped
            on_stopped&.call
          when :confirm
            answered = begin
              on_confirm ? on_confirm.call(event[2], event[3], event[4]) : false
            rescue StandardError
              false # fail closed; never leave the actor blocked on a reply
            end
            raise ActorError, "confirmation channel not established" unless control

            control << [ :confirm_result, event[1], answered ]
          when :done
            response = event[1].to_s
            break
          when :error
            raise translate_error(event[1], event[2], event[3])
          end
        end

        response
      ensure
        events&.close
      end

      # Rebuild the error the session actor caught. The actor can only send
      # strings, so known classes are mapped back explicitly; everything else
      # becomes an ActorError. Backtraces from inside the Ractor are kept for
      # RUBOT_DEBUG=1 only: a rate limit is not a bug, and a stack trace in
      # the chat is noise.
      def translate_error(name, message, trace)
        klass = PASSTHROUGH_ERRORS[name.to_s]
        text = message.to_s
        if klass == Rubot::RateLimitError
          return Rubot::RateLimitError.new(nil, message: text)
        end
        return klass.new(text) if klass

        frames = Array(trace)
        text = "#{name}: #{text}" unless name.to_s.empty?
        text = "#{text}\n#{frames.join("\n")}" if Rubot.debug? && !frames.empty?
        ActorError.new(text)
      end

      def process_cron(text)
        call(:process_cron, text: text)
      end

      # Run post-answer learning (memory extraction, feedback) in the actor
      # that owns the session.
      def flush_learning
        call(:flush_learning)
      end

      def startup_info
        call(:info)
      end

      def usage_report
        call(:usage_report)
      end

      def opencode_usage
        call(:opencode_usage)
      end

      def active_model_name
        call(:active_model_name)
      end

      def active_model_preset
        call(:active_model_preset)
      end

      def model_presets
        call(:model_presets)
      end

      # The models the provider supports, from its /models catalog.
      def provider_models
        call(:provider_models)
      end

      def use_model(name)
        call(:use_model, name: name)
      end

      def use_model_preset(name, preset: nil)
        call(:use_model_preset, name: name, preset: preset)
      end

      def persona
        call(:persona)
      end

      # Auto mode: the flag lives in the session Ractor (the agent that acts on
      # it) and is persisted to config.yml by the agent itself.
      def auto_approve?
        call(:auto_approve)
      end

      def set_auto_approve(value)
        call(:set_auto_approve, value: value)
      end

      # The session handle exposes plain data, matching Agent#persona_info.
      def persona_info
        persona
      end

      def set_persona(persona)
        call(:set_persona, persona: persona)
      end

      def clear_session
        call(:clear_session)
      end

      def compact_session
        call(:compact_session)
      end

      def context_window_tokens
        call(:context_window)
      end

      def estimated_context_tokens
        call(:estimated_context)
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

        def external_editor
          @handle.call(:external_editor)
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

        def model_preset
          @handle.call(:model_preset)
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
