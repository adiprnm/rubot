# frozen_string_literal: true

require_relative "../tool"
require_relative "../cron_scheduler"

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

          Use this when the user asks to:
          - Remind them about something later (e.g. "remind me in 5 minutes")
          - Run something on a schedule (e.g. "every hour", "daily at 9am")
          - Run a shell command on a schedule

          Schedule types:
          - at_seconds: One-time reminder, seconds from now. Examples:
            * "in 2 minutes" → 120
            * "in 5 minutes" → 300
            * "in 1 hour" → 3600
            * "in 10 minutes" → 600
          - every_seconds: Recurring interval in seconds. Examples:
            * "every hour" → 3600
            * "every 30 minutes" → 1800
          - cron_expr: Standard 5-field cron expression. Examples:
            * "daily at 9am" → "0 9 * * *"
            * "every weekday at 6pm" → "0 18 * * 1-5"

          Operations: add, list, detail, remove, enable, disable
          Tip: To view a job's details, use `/cron show <job-id>` (e.g. `/cron show abc123def456`).
        DESC
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "operation" => {
              "type" => "string",
              "enum" => [ "add", "list", "detail", "remove", "enable", "disable" ],
              "description" => "The cron operation to perform"
            },
            "message" => {
              "type" => "string",
              "description" => "The message/task to execute when the job fires (required for add)"
            },
            "command" => {
              "type" => "string",
              "description" => "Shell command to execute directly (uses command mode)"
            },
            "cron_expr" => {
              "type" => "string",
              "description" => "Cron expression for recurring schedule, e.g. '0 9 * * *'"
            },
            "every_seconds" => {
              "type" => "integer",
              "description" => "Recurring interval in seconds, e.g. 3600 for every hour"
            },
            "at_seconds" => {
              "type" => "integer",
              "description" => "One-time delay in seconds from now, e.g. 600 for 10 minutes"
            },
            "description" => {
              "type" => "string",
              "description" => "Human-readable description of the job"
            },
            "job_id" => {
              "type" => "string",
              "description" => "Job ID (for remove, enable, disable)"
            },
            "target_chat_id" => {
              "type" => "integer",
              "description" => "Telegram chat ID to deliver results to (set automatically by the channel)"
            },
            "target_thread_id" => {
              "type" => "integer",
              "description" => "Telegram topic/thread ID to deliver results to (set automatically by the channel)"
            }
          },
          "required" => [ "operation" ]
        }
      end

      def execute(arguments)
        operation = arguments["operation"]
        scheduler = ensure_scheduler

        case operation
        when "add"      then add_job(arguments)
        when "list"     then list_jobs(scheduler)
        when "detail"   then detail_job(arguments, scheduler)
        when "remove"   then remove_job(arguments, scheduler)
        when "enable", "disable" then toggle_job(arguments, scheduler, enable: operation == "enable")
        else
          "ERROR: Unknown operation '#{operation}'. Use: add, list, remove, enable, disable"
        end
      rescue => e
        "ERROR: #{e.class}: #{e.message}"
      end

      def scheduler
        ensure_scheduler
      end

      attr_writer :workspace

      # Delivery context set by the channel (e.g. Telegram chat/thread IDs).
      # Used as defaults for target_chat_id/target_thread_id when creating jobs.
      attr_accessor :delivery_context

      # Register a callback to be called when cron jobs fire.
      # The callback receives { job_id:, mode:, result:, description: }.
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

      def add_job(arguments)
        message = arguments["message"]
        return "ERROR: 'message' is required for add operation" unless message && !message.strip.empty?

        id = @scheduler.add(
          message: message,
          cron_expr: arguments["cron_expr"],
          every_seconds: arguments["every_seconds"],
          at_seconds: arguments["at_seconds"],
          command: arguments["command"],
          description: arguments["description"] || "",
          target_chat_id: arguments["target_chat_id"] || @delivery_context&.fetch(:chat_id),
          target_thread_id: arguments["target_thread_id"] || @delivery_context&.fetch(:thread_id)
        )

        job = @scheduler.get(id)
        schedule_desc = if job["one_time"]
          "One-time, fires in #{job['at_seconds']}s"
        elsif job["schedule_type"] == "every"
          "Every #{job['every_seconds']}s"
        else
          "Cron: #{job['cron_expr']}"
        end

        <<~RESULT.strip
          ✅ `#{id}` | #{schedule_desc} | #{job['mode']} | #{job['command'] ? "cmd: #{job['command']}" : message}
          Use `/cron show #{id}` to see details, or `operation=remove job_id=#{id}` to delete.
        RESULT
      end

      def list_jobs(scheduler)
        jobs = scheduler.list
        return "No scheduled jobs." if jobs.empty?

        lines = [ "Scheduled jobs (#{jobs.size}):" ]
        jobs.each do |job|
          icon = job["enabled"] ? "✅" : "⏸️"
          schedule = if job["one_time"]
            "at #{job['at_seconds']}s"
          elsif job["schedule_type"] == "every"
            "every #{job['every_seconds']}s"
          else
            job["cron_expr"]
          end
          msg = job["command"] || job["message"]
          lines << "#{icon} `#{job['id']}` | #{schedule} | #{job['mode']} | #{msg}"
        end
        lines.join("\n")
      end

      def detail_job(arguments, scheduler)
        job_id = arguments["job_id"]
        return "ERROR: 'job_id' is required for detail operation" unless job_id
        job = scheduler.get(job_id)
        return "ERROR: Job '#{job_id}' not found." unless job

        schedule_desc = if job["one_time"]
          "One-time, fires in #{job['at_seconds']}s"
        elsif job["schedule_type"] == "every"
          "Every #{job['every_seconds']}s"
        else
          "Cron: #{job['cron_expr']}"
        end

        status = job["enabled"] ? "enabled" : "disabled"
        last_info = []
        last_info << "Last run: #{job['last_run']}" if job["last_run"]
        last_info << "Status: #{job['last_status']}" if job["last_status"]
        last_info << "Error: #{job['last_error']}" if job["last_error"]

        <<~RESULT.strip
          Job `#{job['id']}` (#{status})
          Mode: #{job['mode']}
          Schedule: #{schedule_desc}
          Next run: #{job['next_run'] || 'N/A'}
          #{job['command'] ? "Command: #{job['command']}" : "Message: #{job['message']}"}
          Description: #{job['description']}
          Runs: #{job['run_count']}
          Deliver to: #{delivery_desc(job)}
          Created: #{job['created_at']}
          #{last_info.join(" | ")}
        RESULT
      end

      # Describe where cron job results will be delivered.
      def delivery_desc(job)
        chat_id = job["target_chat_id"]
        thread_id = job["target_thread_id"]
        if chat_id && thread_id
          "chat #{chat_id}, topic #{thread_id}"
        elsif chat_id
          "chat #{chat_id}"
        else
          "channel default"
        end
      end

      def remove_job(arguments, scheduler)
        job_id = arguments["job_id"]
        return "ERROR: 'job_id' is required for remove operation" unless job_id
        scheduler.remove(job_id) ? "Job '#{job_id}' removed." : "ERROR: Job '#{job_id}' not found."
      end

      def toggle_job(arguments, scheduler, enable:)
        job_id = arguments["job_id"]
        return "ERROR: 'job_id' is required" unless job_id
        result = scheduler.toggle(job_id)
        if result.is_a?(Array)
          "Job '#{job_id}' #{enable ? 'enabled' : 'disabled'}."
        else
          "ERROR: Job '#{job_id}' not found."
        end
      end
    end
  end
end
