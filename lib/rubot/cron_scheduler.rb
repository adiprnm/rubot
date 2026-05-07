# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "time"

module Rubot
  # Lightweight cron expression parser (5-field: min hour dom month dow)
  class CronExpression
    def initialize(expression)
      @fields = expression.strip.split(/\s+/)
      raise "Invalid cron expression: expected 5 fields, got #{@fields.size}" unless @fields.size == 5
    end

    def match?(time)
      match_field(@fields[0], time.min, 0, 59) &&
        match_field(@fields[1], time.hour, 0, 23) &&
        match_field(@fields[2], time.day, 1, 31) &&
        match_field(@fields[3], time.month, 1, 12) &&
        match_field(@fields[4], time.wday, 0, 6)
    end

    # Compute the next matching time after the given time
    def next_after(time, max_iterations: 525_600) # 1 year of minutes
      # Start at the beginning of the next minute (handles overflow correctly)
      t = Time.new(time.year, time.month, time.day, time.hour, time.min, 0) + 60
      max_iterations.times do
        return t if match?(t)
        t += 60
      end
      nil
    end

    def to_s
      @fields.join(" ")
    end

    private

    def match_field(field, value, min_val, max_val)
      return true if field == "*"

      field.split(",").any? do |part|
        if part.start_with?("*/")
          step = part[2..].to_i
          return false if step <= 0
          (value - min_val) % step == 0
        elsif part.include?("-")
          range_start, range_end = part.split("-").map(&:to_i)
          value >= range_start && value <= range_end
        else
          value == part.to_i
        end
      end
    end
  end

  # Cron job manager with background thread.
  # Fires due jobs automatically and calls a callback for each result.
  class CronScheduler
    attr_reader :jobs

    # FIX (VULN-1, VULN-7): Safety guard for command validation.
    # Must be passed via constructor to avoid TOCTOU where jobs are
    # loaded from disk before the guard is attached.
    attr_accessor :safety_guard

    # FIX (VULN-7): safety_guard can be passed via constructor so that
    # load! validates jobs with the guard already in place.
    def initialize(workspace:, safety_guard: nil, &on_fire)
      @workspace = workspace
      @safety_guard = safety_guard
      @jobs = {}
      @mutex = Mutex.new
      @on_fire = on_fire || proc { |_result| }
      @running = false
      @thread = nil
      load!
    end

    # Add a new scheduled job. Returns job ID.
    # FIX (VULN-13): Validates command through safety guard before storing.
    def add(message:, cron_expr: nil, every_seconds: nil, at_seconds: nil, command: nil, mode: nil, description: "", target_chat_id: nil, target_thread_id: nil)
      if at_seconds
        schedule_type = "at"
        at_seconds = at_seconds.to_i
        raise "at_seconds must be positive" if at_seconds <= 0
      elsif every_seconds
        schedule_type = "every"
        every_seconds = every_seconds.to_i
        raise "every_seconds must be positive" if every_seconds <= 0
      elsif cron_expr
        schedule_type = "cron"
        CronExpression.new(cron_expr)
      else
        raise "One of cron_expr, every_seconds, or at_seconds is required"
      end

      mode = command ? :command : (mode || :agent_turn).to_sym

      # FIX (VULN-1): Validate command through safety guard before storing
      if command && !command.strip.empty?
        validate_cron_command(command)
      end

      @mutex.synchronize do
        id = generate_id
        now = Time.now

        next_run = if schedule_type == "at"
          now + at_seconds
        elsif schedule_type == "every"
          now + every_seconds
        else
          CronExpression.new(cron_expr).next_after(now)
        end

        @jobs[id] = {
          "id" => id,
          "message" => message,
          "command" => command,
          "schedule_type" => schedule_type,
          "cron_expr" => cron_expr,
          "every_seconds" => every_seconds,
          "at_seconds" => at_seconds,
          "mode" => mode.to_s,
          "description" => description,
          "enabled" => true,
          "one_time" => schedule_type == "at",
          "created_at" => now.iso8601,
          "next_run" => next_run&.iso8601,
          "last_run" => nil,
          "last_status" => nil,
          "last_error" => nil,
          "run_count" => 0,
          "target_chat_id" => target_chat_id,
          "target_thread_id" => target_thread_id
        }
        save!
        id
      end
    end

    def remove(id)
      @mutex.synchronize do
        return false unless @jobs.key?(id)
        @jobs.delete(id)
        save!
        true
      end
    end

    def toggle(id)
      @mutex.synchronize do
        job = @jobs[id]
        return :not_found unless job
        job["enabled"] = !job["enabled"]
        save!
        [ :ok, job["enabled"] ]
      end
    end

    def list
      @mutex.synchronize { @jobs.values.map(&:dup) }
    end

    def get(id)
      @mutex.synchronize { @jobs[id]&.dup }
    end

    # Fire any due cron jobs and return their results.
    def fire_due_jobs
      due = @mutex.synchronize do
        enabled_jobs.select do |job|
          next_run = job["next_run"]
          next false unless next_run
          Time.parse(next_run) <= Time.now
        end.map(&:dup)
      end

      due.map do |job|
        result = execute_job(job)
        update_after_run(job["id"], result)
        fire_result = { job_id: job["id"], mode: job["mode"], result: result, description: job["description"], target_chat_id: job["target_chat_id"], target_thread_id: job["target_thread_id"] }
        @on_fire.call(fire_result)
        fire_result
      end
    end

    # Start background thread that checks for due jobs every 15 seconds
    def start
      return if @running
      @running = true
      @thread = Thread.new { run_loop }
      @thread.abort_on_exception = false
      warn "[cron] Scheduler started"
    end

    # Stop background thread
    def stop
      @running = false
      @thread&.join(2)
      @thread = nil
      warn "[cron] Scheduler stopped"
    end

    def running?
      @running && @thread&.alive?
    end

    def shutdown
      stop
    end

    private

    def run_loop
      while @running
        begin
          fire_due_jobs
        rescue StandardError => e
          warn "[cron] Scheduler error: #{e.class}: #{e.message}"
        end
        sleep 15
      end
    end

    private

    def enabled_jobs
      @jobs.values.select { |j| j["enabled"] }
    end

    def validate_cron_command(command)
      cmd = command.strip

      # Always check dangerous patterns
      if @safety_guard&.dangerous_command?(cmd)
        raise SafetyGuard::SecurityError,
              "Cron command blocked by safety guard (dangerous pattern detected)"
      end

      # In workspace-restricted mode, verify command path
      return unless @safety_guard&.restrict_to_workspace
      @safety_guard.check_command(cmd)
    end

    def execute_job(job)
      case job["mode"]
      when "command"
        execute_command(job)
      when "agent_turn"
        { success: true, agent_message: job["message"], mode: "agent_turn" }
      when "deliver"
        { success: true, deliver_message: job["message"], mode: "deliver" }
      else
        { success: false, error: "Unknown mode: #{job['mode']}" }
      end
    end

    def execute_command(job)
      require "open3"
      cmd = job["command"] || job["message"]

      # FIX (VULN-1): Validate command before execution (defense-in-depth)
      # Covers jobs loaded from disk that were created before safety guard existed
      validate_cron_command(cmd)

      stdout, stderr, status = Open3.capture3(cmd)
      output = ""
      output += stdout if stdout && !stdout.empty?
      output += "\nSTDERR: #{stderr}" if stderr && !stderr.empty?
      output = output.strip
      output = output[0..5000] + "\n... (truncated)" if output.length > 5000

      { success: status.exitstatus == 0, output: output, exit_code: status.exitstatus }
    rescue StandardError => e
      { success: false, error: e.message }
    end

    def update_after_run(job_id, result)
      @mutex.synchronize do
        job = @jobs[job_id]
        return unless job

        job["last_run"] = Time.now.iso8601
        job["run_count"] += 1

        if result[:success]
          job["last_status"] = "ok"
          job["last_error"] = nil
        else
          job["last_status"] = "error"
          job["last_error"] = result[:error]
        end

        if job["one_time"]
          @jobs.delete(job_id)
        else
          now = Time.now
          job["next_run"] = if job["schedule_type"] == "every"
            (now + job["every_seconds"]).iso8601
          else
            CronExpression.new(job["cron_expr"]).next_after(now)&.iso8601
          end
        end

        save!
      end
    end

    def generate_id
      loop do
        id = SecureRandom.hex(6)
        return id unless @jobs.key?(id)
      end
    end

    def data_file
      return nil unless @workspace
      File.join(@workspace, "cron", "jobs.json")
    end

    def load!
      return unless data_file && File.exist?(data_file)
      data = JSON.parse(File.read(data_file))
      @jobs = data["jobs"] || {}

      # FIX (VULN-13): Validate loaded command-mode jobs through safety guard
      # Invalid jobs are disabled rather than deleted (preserves audit trail)
      return unless @safety_guard
      @jobs.each_value do |job|
        next unless job["mode"] == "command" && job["command"]
        validate_cron_command(job["command"])
      end
    rescue SafetyGuard::SecurityError => e
      warn "[cron] Disabling unsafe loaded job: #{e.message}"
      # Disable the job that failed validation — don't delete, preserve audit trail
      @jobs.each_value do |job|
        next unless job["mode"] == "command" && job["command"]
        begin
          validate_cron_command(job["command"])
        rescue SafetyGuard::SecurityError
          job["enabled"] = false
          job["last_error"] = "Disabled by safety guard: #{e.message}"
        end
      end
      save!
    rescue JSON::ParserError
      @jobs = {}
    end

    def save!
      return unless data_file
      FileUtils.mkdir_p(File.dirname(data_file))
      File.write(data_file, JSON.pretty_generate({ "jobs" => @jobs }))
    end
  end
end
