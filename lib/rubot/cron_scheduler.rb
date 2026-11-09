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

    # FIX (VULN-1, VULN-7, PEN-05): Safety guard for command validation.
    # Supports both direct assignment and lazy source (proc) to prevent
    # TOCTOU where the scheduler is created before the guard is set.
    attr_accessor :safety_guard
    attr_accessor :safety_guard_source

    # FIX (VULN-7, PEN-05): safety_guard can be passed via constructor so
    # that load! validates jobs with the guard already in place. Or
    # safety_guard_source can be passed as a proc/lambda that returns
    # the current guard value — this prevents TOCTOU where the guard
    # is set after the scheduler is created.
    def initialize(workspace:, safety_guard: nil, safety_guard_source: nil, &on_fire)
      @workspace = workspace
      @safety_guard = safety_guard
      @safety_guard_source = safety_guard_source
      @jobs = {}
      @extra_workspaces = {}
      @mutex = Mutex.new
      @on_fire = on_fire || proc { |_result| }
      @running = false
      @thread = nil
      load!
    end

    # Add a new scheduled job. Returns job ID.
    # FIX (VULN-13): Validates command through safety guard before storing.
    def add(message:, cron_expr: nil, every_seconds: nil, at_seconds: nil, command: nil, mode: nil, description: "", target_chat_id: nil, target_thread_id: nil, workspace: nil)
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

        job = {
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
          "target_thread_id" => target_thread_id,
          # The directory whose agent should run an `agent_turn` job. A job
          # added from a persona's topic names that persona's directory, so
          # the reminder answers in the same voice it was written in.
          "workspace" => workspace || @workspace
        }

        # File it where it was written: a persona's reminder belongs to the
        # persona's directory, not to the install's own store.
        owner = normalize_workspace(workspace)
        if owner && owner != @workspace
          store = (@extra_workspaces[owner] ||= load_store(owner))
          store[id] = job
          save_store(owner, store)
        else
          @jobs[id] = job
          save!
        end
        id
      end
    end

    # Which job store(s) this scheduler owns.
    #
    # The default workspace is the install's own (next to config.yml); a
    # persona opens a second store inside its own directory, so a reminder
    # written by a specialist is filed there, and closed when the persona goes
    # away. All stores share one scheduler and one firing thread — a scheduler
    # per directory would mean a thread per directory for no benefit.
    attr_reader :workspace

    def register_workspace(path)
      full = normalize_workspace(path)
      return @workspace if full.nil? || full == @workspace

      @mutex.synchronize do
        @extra_workspaces[full] ||= load_store(full)
      end
      full
    end

    def unregister_workspace(path)
      full = normalize_workspace(path)
      return 0 if full.nil? || full == @workspace

      @mutex.synchronize do
        jobs = @extra_workspaces.delete(full)
        next 0 unless jobs

        count = jobs.size
        jobs.clear
        save_store(full, jobs)
        count
      end
    end

    def registered_workspaces
      @mutex.synchronize { [ @workspace, *@extra_workspaces.keys ].compact }
    end

    # Move every job out of a store and rewrite the files.
    #
    # `to` names the store to receive them; nil drops them. A caller that wants
    # them kept passes a path — the pool passes the install's own workspace —
    # so nil stays an unambiguous "throw them away".
    def merge_workspace(from, to: nil)
      source = normalize_workspace(from)
      return 0 if source.nil? || source == @workspace

      @mutex.synchronize do
        jobs = @extra_workspaces[source] || load_store(source)
        @extra_workspaces.delete(source)
        next 0 if jobs.empty?

        target = normalize_workspace(to)
        if target.nil?
          # Dropped on purpose: a persona that is going away leaves reminders
          # written in a voice that no longer exists.
        elsif target == @workspace
          @jobs.merge!(jobs)
          save!
        else
          store = (@extra_workspaces[target] ||= load_store(target))
          store.merge!(jobs)
          save_store(target, store)
        end

        save_store(source, {})
        jobs.size
      end
    end

    def remove(id)
      @mutex.synchronize do
        if @jobs.delete(id)
          save!
          return true
        end

        @extra_workspaces.each do |path, jobs|
          next unless jobs.delete(id)

          save_store(path, jobs)
          return true
        end

        false
      end
    end

    def toggle(id)
      @mutex.synchronize do
        job = job_location(id)&.last
        return :not_found unless job

        job["enabled"] = !job["enabled"]
        save_store_for(id, job)
        [ :ok, job["enabled"] ]
      end
    end

    def list
      @mutex.synchronize { all_jobs.map(&:dup) }
    end

    # Every job the scheduler can fire, whatever store it is filed in.
    def all_jobs
      [ @jobs, *@extra_workspaces.values ].flat_map { |store| store.values }
    end

    # Drop every job aimed at one chat/topic. Used when a topic loses the
    # persona it was set up for: a job written with a trainer's memory must not
    # keep firing into a session that no longer has it.
    # Returns how many were removed.
    def remove_by_target(chat_id:, thread_id: nil)
      chat = chat_id&.to_s
      return 0 if chat.nil? || chat.empty?

      thread = thread_id&.to_s
      @mutex.synchronize do
        removed = 0
        stores = [ [ @workspace, @jobs ], *@extra_workspaces.map { |path, jobs| [ path, jobs ] } ]

        stores.each do |path, jobs|
          ids = jobs.values.select do |job|
            job["target_chat_id"].to_s == chat &&
              (thread.nil? || thread.empty? || job["target_thread_id"].to_s == thread)
          end.map { |job| job["id"] }

          next if ids.empty?

          ids.each { |id| jobs.delete(id) }
          path == @workspace ? save! : save_store(path, jobs)
          removed += ids.size
        end

        removed
      end
    end

    def get(id)
      @mutex.synchronize { job_location(id)&.last&.dup }
    end

    # [store_path, job] for an id, in whichever store holds it.
    def job_location(id)
      return [ @workspace, @jobs[id] ] if @jobs[id]

      @extra_workspaces.each do |path, jobs|
        return [ path, jobs[id] ] if jobs[id]
      end

      nil
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
        fire_result = {
          job_id: job["id"],
          mode: job["mode"],
          result: result,
          description: job["description"],
          target_chat_id: job["target_chat_id"],
          target_thread_id: job["target_thread_id"],
          # Which agent should run an agent_turn job: the directory the job was
          # written in, so a persona's reminder answers with that persona.
          workspace: job["workspace"]
        }
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
      begin
        @thread&.wakeup
      rescue ThreadError
        nil
      end
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
      all_jobs.select { |j| j["enabled"] }
    end

    def validate_cron_command(command)
      cmd = command.strip
      guard = resolve_guard

      # Always check dangerous patterns
      if guard&.dangerous_command?(cmd)
        raise SafetyGuard::SecurityError,
              "Cron command blocked by safety guard (dangerous pattern detected)"
      end

      # In workspace-restricted mode, verify command path
      return unless guard&.restrict_to_workspace
      guard.check_command(cmd)
    end

    # Resolve the active safety guard from either direct value or lazy source.
    # Public method for testing and external validation.
    # This prevents TOCTOU where the guard is set after the scheduler is created.
    #
    # @return [SafetyGuard, nil]
    public
    def resolve_guard
      @safety_guard || (@safety_guard_source&.call)
    end

    private

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
        location = job_location(job_id)
        return unless location

        store_path, job = location
        store = store_path == @workspace ? @jobs : (@extra_workspaces[store_path] ||= load_store(store_path))

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
          store.delete(job_id)
        else
          now = Time.now
          job["next_run"] = if job["schedule_type"] == "every"
            (now + job["every_seconds"]).iso8601
          else
            CronExpression.new(job["cron_expr"]).next_after(now)&.iso8601
          end
        end

        store_path == @workspace ? save! : save_store(store_path, store)
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

    # A workspace path as an absolute string, or nil for "nowhere".
    # An empty string must not expand to the current directory — that would
    # silently file a persona's reminders in whatever directory the process
    # happens to run from.
    def normalize_workspace(path)
      return nil if path.nil?

      text = path.to_s.strip
      return nil if text.empty?

      File.expand_path(text)
    rescue ArgumentError
      nil
    end

    def store_file(path)
      return nil if path.nil?
      File.join(path, "cron", "jobs.json")
    end

    def load_store(path)
      file = store_file(path)
      return {} unless file && File.exist?(file)

      data = JSON.parse(File.read(file))
      jobs = data["jobs"] || {}
      validate_loaded!(jobs, path)
      jobs
    rescue JSON::ParserError
      warn "[cron] Invalid JSON in #{file}; ignoring its jobs"
      {}
    end

    def save_store(path, jobs)
      file = store_file(path)
      return unless file

      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, JSON.pretty_generate({ "jobs" => jobs }))
    end

    # Re-save whichever store holds `id`.
    def save_store_for(id, job)
      location = job_location(id)
      return save! unless location

      path, = location
      path == @workspace ? save! : save_store(path, @extra_workspaces[path] || {})
    end

    def load!
      return unless data_file && File.exist?(data_file)
      data = JSON.parse(File.read(data_file))
      @jobs = data["jobs"] || {}

      validate_loaded!(@jobs, @workspace)
    rescue JSON::ParserError
      @jobs = {}
    end

    # FIX (VULN-13): Validate loaded command-mode jobs through safety guard.
    # Invalid jobs are disabled rather than deleted (preserves audit trail).
    def validate_loaded!(jobs, path)
      return unless resolve_guard

      jobs.each_value do |job|
        next unless job["mode"] == "command" && job["command"]
        validate_cron_command(job["command"])
      end
    rescue SafetyGuard::SecurityError => e
      warn "[cron] Disabling unsafe loaded job: #{e.message}"
      jobs.each_value do |job|
        next unless job["mode"] == "command" && job["command"]
        begin
          validate_cron_command(job["command"])
        rescue SafetyGuard::SecurityError
          job["enabled"] = false
          job["last_error"] = "Disabled by safety guard: #{e.message}"
        end
      end
      save_store(path, jobs)
    end

    def save!
      return unless data_file
      FileUtils.mkdir_p(File.dirname(data_file))
      File.write(data_file, JSON.pretty_generate({ "jobs" => @jobs }))
    rescue SystemCallError => e
      warn "[cron] Could not save #{data_file}: #{e.class}: #{e.message}"
    end
  end
end
