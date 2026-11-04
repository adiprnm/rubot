# frozen_string_literal: true

require_relative "cron_actor"
require_relative "session_actor"
require_relative "../session_handle"

module Rubot
  module Actors
    # Main-Ractor-side registry of session actors (one actor per session id).
    #
    # The pool is intentionally not Ractor-shareable: it is owned by the
    # main Ractor (where channels run). Use #for to obtain a SessionHandle.
    class SessionPool
      attr_reader :cron, :cron_events

      def initialize(config:, delivery: nil)
        @config_data = config.snapshot
        @config_path = config.config_path
        @mutex = Mutex.new
        @actors = {}
        @cron_events = delivery

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
            cron_actor: @cron
          )
        end

        SessionHandle.new(ractor.ractor, sid)
      end

      def session_ids
        @mutex.synchronize { @actors.keys.dup }
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
    end
  end
end
