# frozen_string_literal: true

require_relative "../tool"
require_relative "../cron_scheduler"
require_relative "../cron_commands"

module Rubot
  module Tools
    # Cron tool — schedules are checked and executed synchronously
    # each time the agent processes a message. No background thread.
    class Cron < Tool
      # FIX (VULN-1): Safety guard for cron command validation
      attr_accessor :safety_guard

      def initialize(workspace: nil)
        @workspace = workspace
        @scheduler = nil
        @on_fire = nil
      end

      def name
        "cron"
      end

      def description
        <<~DESC.strip
          Schedule reminders, recurring tasks, and one-time alerts.

          Operations: add, list, detail, remove, enable, disable
          Schedule, one per job:
          - at_seconds: one-time, seconds from now (600 = 10 minutes)
          - every_seconds: recurring interval (1800 = every 30 minutes)
          - cron_expr: standard 5-field cron ("0 9 * * *" = daily 09:00)
        DESC
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "operation" => {
              "type" => "string",
              "enum" => [ "add", "list", "detail", "remove", "enable", "disable" ],
              "description" => "Cron operation"
            },
            "message" => {
              "type" => "string",
              "description" => "Task to run when the job fires (required for add)"
            },
            "command" => {
              "type" => "string",
              "description" => "Shell command to run instead of a message"
            },
            "cron_expr" => {
              "type" => "string",
              "description" => "5-field cron expression, e.g. '0 9 * * *'"
            },
            "every_seconds" => {
              "type" => "integer",
              "description" => "Recurring interval in seconds, e.g. 3600"
            },
            "at_seconds" => {
              "type" => "integer",
              "description" => "One-time delay in seconds from now, e.g. 600"
            },
            "description" => {
              "type" => "string",
              "description" => "Human-readable label"
            },
            "job_id" => {
              "type" => "string",
              "description" => "Job id (remove, enable, disable)"
            },
            "target_chat_id" => {
              "type" => "integer",
              "description" => "Telegram chat id (set by the channel)"
            },
            "target_thread_id" => {
              "type" => "integer",
              "description" => "Telegram topic id (set by the channel)"
            }
          },
          "required" => [ "operation" ]
        }
      end

      # Optional CronActor handle. When present, all operations are delegated
      # to the actor, which owns the scheduler and the job store.
      attr_accessor :cron_actor

      def execute(arguments)
        if @cron_actor
          @cron_actor.call(
            operation: arguments["operation"],
            arguments: arguments,
            delivery_context: @delivery_context
          )
        else
          CronCommands.execute(ensure_scheduler, arguments, delivery_context: @delivery_context)
        end
      end

      # The in-process scheduler, or nil when running in actor mode.
      def scheduler
        return nil if @cron_actor
        ensure_scheduler
      end

      attr_writer :workspace

      # Delivery context set by the channel (e.g. Telegram chat/thread IDs).
      # Used as defaults for target_chat_id/target_thread_id when creating jobs.
      attr_accessor :delivery_context

      # Register a callback to be called when cron jobs fire (legacy mode).
      def on_fire(&block)
        @on_fire = block
      end

      def has_fire_callback?
        !!@on_fire
      end

      private

      def ensure_scheduler
        return @scheduler if @scheduler
        # FIX (VULN-7, PEN-05): Pass safety guard via lazy reference (proc)
        # to prevent TOCTOU where the scheduler is created before safety_guard=
        # is set. The proc always reads the current value of @safety_guard.
        @scheduler = CronScheduler.new(
          workspace: @workspace,
          safety_guard_source: -> { @safety_guard },
          &@on_fire
        )
        @scheduler
      end
    end
  end
end
