# frozen_string_literal: true

require_relative "cron_actor"
require_relative "session_actor"
require_relative "../persona_store"
require_relative "../session_handle"

module Rubot
  module Actors
    # Main-Ractor-side registry of session actors (one actor per session id).
    #
    # The pool is intentionally not Ractor-shareable: it is owned by the
    # main Ractor (where channels run). Use #for to obtain a SessionHandle.
    class SessionPool
      attr_reader :cron, :cron_events, :workspace, :models

      def initialize(config:, delivery: nil)
        @config_data = config.snapshot
        @config_path = config.config_path
        @workspace = config.workspace
        @models = Array(config.models)
        @mutex = Mutex.new
        @actors = {}
        @cron_events = delivery
        @persona_store = build_persona_store(config)

        @cron = if config.tools_enabled
          CronActor.new(
            workspace: config.workspace,
            restrict_to_workspace: config.restrict_to_workspace,
            allow_read_outside: config.allow_read_outside_workspace,
            delivery: delivery
          )
        end
      end

      # Returns a SessionHandle for the given session id, spawning the actor
      # lazily. Calls with the same id always return the same actor.
      def for(session_id)
        sid = (session_id || "default").to_s

        ractor = @mutex.synchronize do
          @actors[sid] ||= SessionActor.new(
            config_data: @config_data,
            config_path: @config_path,
            session_id: sid,
            cron_actor: @cron,
            persona: persona_for(sid)
          )
        end

        SessionHandle.new(ractor.ractor, sid)
      end

      def session_ids
        @mutex.synchronize { @actors.keys.dup }
      end

      # Pick up config.yml changes (model presets, defaults, credentials) for
      # actors spawned after this call. Live actors keep their in-memory config
      # until they are switched explicitly or recreated.
      def refresh_config(config)
        @mutex.synchronize do
          @config_data = config.snapshot
          @config_path = config.config_path
          @workspace = config.workspace
          @models = Array(config.models)
          @persona_store = build_persona_store(config)
        end
        self
      end

      # Drop a session actor so the next #for call recreates it from the
      # current persona store and session file.
      def invalidate(session_id)
        sid = (session_id || "default").to_s
        actor = @mutex.synchronize { @actors.delete(sid) }
        actor&.shutdown
        actor
      end

      def shutdown
        actors = @mutex.synchronize do
          list = @actors.values
          @actors = {}
          list
        end

        actors.each(&:shutdown)
        @cron&.shutdown
      end

      private

      def build_persona_store(config)
        PersonaStore.new(
          workspace: config.workspace,
          available_models: Array(config.models).filter_map { |model| model["name"] if model.is_a?(Hash) },
          available_presets: config.model_preset_names
        )
      end

      # Plain-data persona for a session, read fresh from disk so a topic
      # created (or reconfigured) after the pool started is picked up.
      def persona_for(session_id)
        persona = @persona_store.get_by_session(session_id)
        persona&.to_h
      rescue StandardError => e
        warn "[persona] failed to load persona for #{session_id}: #{e.class}: #{e.message}"
        nil
      end
    end
  end
end
