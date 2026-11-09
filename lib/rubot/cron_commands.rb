# frozen_string_literal: true

module Rubot
  # Shared implementation of the cron tool's operations.
  #
  # This module is intentionally stateless: it works on any object that
  # responds to the CronScheduler API. That lets the same code run either
  # in-process (legacy tool mode) or inside a dedicated CronActor.
  module CronCommands
    module_function

    def execute(scheduler, arguments, delivery_context: nil)
      operation = arguments["operation"]

      case operation
      when "add"      then add_job(scheduler, arguments, delivery_context)
      when "list"     then list_jobs(scheduler)
      when "detail"   then detail_job(scheduler, arguments)
      when "remove"   then remove_job(scheduler, arguments)
      when "enable", "disable" then toggle_job(scheduler, arguments, enable: operation == "enable")
      when "register", "unregister" then toggle_workspace(scheduler, arguments, register: operation == "register")
      else
        "ERROR: Unknown operation '#{operation}'. Use: add, list, remove, enable, disable"
      end
    rescue StandardError => e
      "ERROR: #{e.class}: #{e.message}"
    end

    # Open or close a workspace's job store.
    #
    # The CronActor owning this scheduler keeps every registered workspace's
    # jobs in one Ractor, so a persona's directory holds its own cron/jobs.json
    # without needing a scheduler object (and a firing thread) of its own.
    def toggle_workspace(scheduler, arguments, register:)
      return "ERROR: this scheduler does not manage multiple workspaces" unless scheduler.respond_to?(:register_workspace)

      path = arguments["workspace"].to_s
      return "ERROR: 'workspace' is required" if path.empty?

      if register
        scheduler.register_workspace(path)
        "OK: workspace registered (#{path})"
      else
        count = scheduler.unregister_workspace(path)
        "OK: workspace unregistered (#{path}, #{count} reminder#{count == 1 ? '' : 's'} removed)"
      end
    end

    def add_job(scheduler, arguments, delivery_context)
      message = arguments["message"]
      return "ERROR: 'message' is required for add operation" unless message && !message.strip.empty?

      id = scheduler.add(
        message: message,
        cron_expr: arguments["cron_expr"],
        every_seconds: arguments["every_seconds"],
        at_seconds: arguments["at_seconds"],
        command: arguments["command"],
        description: arguments["description"] || "",
        target_chat_id: arguments["target_chat_id"] || context_value(delivery_context, :chat_id),
        target_thread_id: arguments["target_thread_id"] || context_value(delivery_context, :thread_id),
        workspace: arguments["workspace"] || context_value(delivery_context, :workspace)
      )

      job = scheduler.get(id)
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

    def detail_job(scheduler, arguments)
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

    def remove_job(scheduler, arguments)
      job_id = arguments["job_id"]
      return "ERROR: 'job_id' is required for remove operation" unless job_id

      scheduler.remove(job_id) ? "Job '#{job_id}' removed." : "ERROR: Job '#{job_id}' not found."
    end

    def toggle_job(scheduler, arguments, enable:)
      job_id = arguments["job_id"]
      return "ERROR: 'job_id' is required" unless job_id

      result = scheduler.toggle(job_id)
      if result.is_a?(Array)
        "Job '#{job_id}' #{enable ? 'enabled' : 'disabled'}."
      else
        "ERROR: Job '#{job_id}' not found."
      end
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

    def context_value(context, key)
      return nil unless context
      context[key] || context[key.to_s]
    end
  end
end
