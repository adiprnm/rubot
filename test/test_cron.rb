# frozen_string_literal: true

require_relative "test_helper"

class TestCronExpression < Minitest::Test
  def test_every_minute
    expr = Rubot::CronExpression.new("* * * * *")
    time = Time.new(2025, 5, 4, 12, 30, 45)
    assert expr.match?(time)
  end

  def test_specific_minute
    expr = Rubot::CronExpression.new("30 * * * *")
    assert expr.match?(Time.new(2025, 5, 4, 12, 30, 0))
    refute expr.match?(Time.new(2025, 5, 4, 12, 31, 0))
  end

  def test_specific_hour_and_minute
    expr = Rubot::CronExpression.new("0 9 * * *")
    assert expr.match?(Time.new(2025, 5, 4, 9, 0, 0))
    refute expr.match?(Time.new(2025, 5, 4, 9, 5, 0))
    refute expr.match?(Time.new(2025, 5, 4, 10, 0, 0))
  end

  def test_every_n_minutes
    expr = Rubot::CronExpression.new("*/5 * * * *")
    assert expr.match?(Time.new(2025, 5, 4, 12, 0, 0))
    assert expr.match?(Time.new(2025, 5, 4, 12, 5, 0))
    assert expr.match?(Time.new(2025, 5, 4, 12, 30, 0))
    refute expr.match?(Time.new(2025, 5, 4, 12, 3, 0))
    refute expr.match?(Time.new(2025, 5, 4, 12, 17, 0))
  end

  def test_range
    expr = Rubot::CronExpression.new("0 9-17 * * *")
    assert expr.match?(Time.new(2025, 5, 4, 9, 0, 0))
    assert expr.match?(Time.new(2025, 5, 4, 12, 0, 0))
    assert expr.match?(Time.new(2025, 5, 4, 17, 0, 0))
    refute expr.match?(Time.new(2025, 5, 4, 8, 0, 0))
    refute expr.match?(Time.new(2025, 5, 4, 18, 0, 0))
  end

  def test_list
    expr = Rubot::CronExpression.new("0 9,12,18 * * *")
    assert expr.match?(Time.new(2025, 5, 4, 9, 0, 0))
    assert expr.match?(Time.new(2025, 5, 4, 12, 0, 0))
    assert expr.match?(Time.new(2025, 5, 4, 18, 0, 0))
    refute expr.match?(Time.new(2025, 5, 4, 10, 0, 0))
  end

  def test_day_of_week
    expr = Rubot::CronExpression.new("0 9 * * 1-5")
    monday = Time.new(2025, 5, 5, 9, 0, 0)
    sunday = Time.new(2025, 5, 4, 9, 0, 0)
    assert expr.match?(monday), "Should match Monday"
    refute expr.match?(sunday), "Should not match Sunday"
  end

  def test_specific_day_of_month
    expr = Rubot::CronExpression.new("0 0 1 * *")
    assert expr.match?(Time.new(2025, 5, 1, 0, 0, 0))
    refute expr.match?(Time.new(2025, 5, 2, 0, 0, 0))
  end

  def test_specific_month
    expr = Rubot::CronExpression.new("0 0 * 6 *")
    assert expr.match?(Time.new(2025, 6, 15, 0, 0, 0))
    refute expr.match?(Time.new(2025, 5, 15, 0, 0, 0))
  end

  def test_complex_expression
    expr = Rubot::CronExpression.new("*/15 9-17 * * 1-5")
    assert expr.match?(Time.new(2025, 5, 5, 9, 0, 0))
    assert expr.match?(Time.new(2025, 5, 5, 9, 15, 0))
    assert expr.match?(Time.new(2025, 5, 5, 12, 30, 0))
    refute expr.match?(Time.new(2025, 5, 5, 8, 0, 0))
    refute expr.match?(Time.new(2025, 5, 4, 10, 0, 0))
  end

  def test_invalid_expression
    assert_raises(RuntimeError) { Rubot::CronExpression.new("* * * *") }
    assert_raises(RuntimeError) { Rubot::CronExpression.new("* *") }
  end

  def test_to_s
    expr = Rubot::CronExpression.new("*/5 9-17 * * 1-5")
    assert_equal "*/5 9-17 * * 1-5", expr.to_s
  end

  def test_next_after
    expr = Rubot::CronExpression.new("30 9 * * *")
    now = Time.new(2025, 5, 4, 8, 0, 0)
    next_time = expr.next_after(now)
    assert_equal Time.new(2025, 5, 4, 9, 30, 0), next_time
  end

  def test_next_after_past_time
    expr = Rubot::CronExpression.new("0 9 * * *")
    now = Time.new(2025, 5, 4, 10, 0, 0)
    next_time = expr.next_after(now)
    assert_equal Time.new(2025, 5, 5, 9, 0, 0), next_time
  end
end

class TestCronScheduler < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @scheduler = Rubot::CronScheduler.new(workspace: @tmpdir)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  # --- Schedule types ---

  def test_add_with_cron_expr
    id = @scheduler.add(message: "Daily summary", cron_expr: "0 9 * * *")
    assert id && !id.empty? && id.length == 12
    job = @scheduler.get(id)
    assert_equal "cron", job["schedule_type"]
    assert_equal "0 9 * * *", job["cron_expr"]
    refute job["one_time"]
    assert_equal "agent_turn", job["mode"]
    assert job["next_run"]
  end

  def test_add_with_every_seconds
    id = @scheduler.add(message: "Ping", every_seconds: 300)
    job = @scheduler.get(id)
    assert_equal "every", job["schedule_type"]
    assert_equal 300, job["every_seconds"]
    refute job["one_time"]
  end

  def test_add_with_at_seconds
    id = @scheduler.add(message: "One-time reminder", at_seconds: 60)
    job = @scheduler.get(id)
    assert_equal "at", job["schedule_type"]
    assert_equal 60, job["at_seconds"]
    assert job["one_time"]
  end

  def test_add_requires_schedule
    assert_raises(RuntimeError) do
      @scheduler.add(message: "No schedule")
    end
  end

  def test_add_command_mode
    id = @scheduler.add(message: "Run backup", command: "echo backup", cron_expr: "0 2 * * *")
    job = @scheduler.get(id)
    assert_equal "command", job["mode"]
    assert_equal "echo backup", job["command"]
  end

  def test_add_invalid_cron_expr
    assert_raises(RuntimeError) do
      @scheduler.add(message: "Bad", cron_expr: "invalid")
    end
  end

  # --- Job management ---

  def test_list_jobs
    @scheduler.add(message: "Job 1", cron_expr: "0 9 * * *")
    @scheduler.add(message: "Job 2", every_seconds: 300)
    assert_equal 2, @scheduler.list.size
  end

  def test_remove_job
    id = @scheduler.add(message: "Remove me", every_seconds: 60)
    assert @scheduler.remove(id)
    assert_equal 0, @scheduler.list.size
    refute @scheduler.remove("nonexistent")
  end

  def test_toggle_job
    id = @scheduler.add(message: "Toggle me", every_seconds: 60)
    assert @scheduler.get(id)["enabled"]

    result = @scheduler.toggle(id)
    assert_equal [ :ok, false ], result
    refute @scheduler.get(id)["enabled"]

    result = @scheduler.toggle(id)
    assert_equal [ :ok, true ], result
    assert @scheduler.get(id)["enabled"]
  end

  def test_toggle_nonexistent
    assert_equal :not_found, @scheduler.toggle("nonexistent")
  end

  # --- Persistence ---

  def test_persistence
    @scheduler.add(message: "Persistent job", cron_expr: "0 9 * * *", description: "Daily")

    new_scheduler = Rubot::CronScheduler.new(workspace: @tmpdir)
    jobs = new_scheduler.list
    assert_equal 1, jobs.size
    assert_equal "Persistent job", jobs[0]["message"]
    assert_equal "Daily", jobs[0]["description"]
  end

  # --- Firing jobs ---

  def test_fire_due_jobs_empty
    results = @scheduler.fire_due_jobs
    assert_empty results
  end

  def test_fire_due_jobs_command_mode
    id = @scheduler.add(message: "echo hello", command: "echo hello", at_seconds: 1)
    # Wait until the job is due
    sleep 2

    results = @scheduler.fire_due_jobs
    assert_equal 1, results.size
    assert_equal id, results[0][:job_id]
    assert_equal "command", results[0][:mode]
    assert results[0][:result][:success]
    assert_includes results[0][:result][:output], "hello"

    # One-time job should be deleted
    refute @scheduler.get(id)
  end

  def test_fire_due_jobs_agent_turn_mode
    id = @scheduler.add(message: "Say hello", at_seconds: 1)
    sleep 2

    results = @scheduler.fire_due_jobs
    assert_equal 1, results.size
    assert_equal "agent_turn", results[0][:mode]
    assert_equal "Say hello", results[0][:result][:agent_message]

    # One-time job should be deleted
    refute @scheduler.get(id)
  end

  def test_fire_due_jobs_deliver_mode
    id = @scheduler.add(message: "Reminder!", at_seconds: 1, mode: :deliver)
    sleep 2

    results = @scheduler.fire_due_jobs
    assert_equal 1, results.size
    assert_equal "deliver", results[0][:mode]
    assert_equal "Reminder!", results[0][:result][:deliver_message]

    # One-time job should be deleted
    refute @scheduler.get(id)
  end

  def test_fire_due_jobs_not_yet_due
    @scheduler.add(message: "Future job", every_seconds: 3600)
    results = @scheduler.fire_due_jobs
    assert_empty results
  end

  def test_next_run_recomputed_for_every
    id = @scheduler.add(message: "Ping", every_seconds: 2)
    job = @scheduler.get(id)
    original_next = job["next_run"]

    sleep_until = Time.parse(original_next) + 1
    sleep_time = [ sleep_until - Time.now, 0.1 ].max
    sleep(sleep_time) if sleep_time > 0

    @scheduler.fire_due_jobs
    updated = @scheduler.get(id)
    assert updated["next_run"] > original_next, "next_run should advance"
  end

  def test_next_run_recomputed_for_cron
    id = @scheduler.add(message: "Daily", cron_expr: "0 9 * * *")

    result = { success: true, output: "done", exit_code: 0 }
    @scheduler.send(:update_after_run, id, result)

    updated = @scheduler.get(id)
    assert updated, "Job should still exist after run"
    assert_equal "ok", updated["last_status"]
    assert_equal 1, updated["run_count"]
  end

  # --- Delivery targets ---

  def test_add_stores_target_chat_and_thread
    id = @scheduler.add(message: "Topic reminder", cron_expr: "0 9 * * *", target_chat_id: 123, target_thread_id: 456)
    job = @scheduler.get(id)
    assert_equal 123, job["target_chat_id"]
    assert_equal 456, job["target_thread_id"]
  end

  def test_add_target_defaults_to_nil
    id = @scheduler.add(message: "No target", cron_expr: "0 9 * * *")
    job = @scheduler.get(id)
    assert_nil job["target_chat_id"]
    assert_nil job["target_thread_id"]
  end

  def test_fire_result_includes_target
    @scheduler.add(message: "echo hi", command: "echo hi", at_seconds: 1, target_chat_id: 789, target_thread_id: 10)
    sleep 2

    results = @scheduler.fire_due_jobs
    assert_equal 1, results.size
    assert_equal 789, results[0][:target_chat_id]
    assert_equal 10, results[0][:target_thread_id]
  end

  def test_target_persists_across_reload
    @scheduler.add(message: "Persistent target", cron_expr: "0 9 * * *", target_chat_id: 999, target_thread_id: 42)

    new_scheduler = Rubot::CronScheduler.new(workspace: @tmpdir)
    jobs = new_scheduler.list
    assert_equal 1, jobs.size
    assert_equal 999, jobs[0]["target_chat_id"]
    assert_equal 42, jobs[0]["target_thread_id"]
  end
end

class TestCronTool < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @tool = Rubot::Tools::Cron.new(workspace: @tmpdir)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_tool_name
    assert_equal "cron", @tool.name
  end

  def test_tool_description
    desc = @tool.description
    assert_includes desc, "remind"
    assert_includes desc, "at_seconds"
    assert_includes desc, "cron_expr"
  end

  def test_tool_parameters
    params = @tool.parameters
    assert_equal "object", params["type"]
    assert_includes params["properties"].keys, "operation"
    assert_includes params["properties"].keys, "cron_expr"
    assert_includes params["properties"].keys, "every_seconds"
    assert_includes params["properties"].keys, "at_seconds"
    assert_includes params["required"], "operation"
  end

  def test_add_with_cron_expr
    result = @tool.execute({
      "operation" => "add",
      "message" => "Summarize transactions",
      "cron_expr" => "0 18 * * *",
      "description" => "Daily transaction summary"
    })
    assert_includes result, "✅"
    assert_includes result, "0 18 * * *"
    assert_includes result, "agent_turn"
  end

  def test_add_with_every_seconds
    result = @tool.execute({
      "operation" => "add",
      "message" => "Check server health",
      "every_seconds" => 3600,
      "description" => "Hourly health check"
    })
    assert_includes result, "✅"
    assert_includes result, "3600s"
  end

  def test_add_with_at_seconds
    result = @tool.execute({
      "operation" => "add",
      "message" => "Standup in 10 minutes",
      "at_seconds" => 600
    })
    assert_includes result, "✅"
    assert_includes result, "600s"
  end

  def test_add_command_mode
    result = @tool.execute({
      "operation" => "add",
      "message" => "Run backup script",
      "command" => "/usr/local/bin/backup.sh",
      "cron_expr" => "0 2 * * *"
    })
    assert_includes result, "✅"
    assert_includes result, "command"
  end

  def test_add_missing_message
    result = @tool.execute({
      "operation" => "add",
      "cron_expr" => "0 9 * * *"
    })
    assert_includes result, "ERROR"
    assert_includes result, "message"
  end

  def test_add_invalid_cron_expr
    result = @tool.execute({
      "operation" => "add",
      "message" => "Test",
      "cron_expr" => "bad"
    })
    assert_includes result, "ERROR"
  end

  def test_list_empty
    result = @tool.execute({ "operation" => "list" })
    assert_includes result, "No scheduled"
  end

  def test_list_with_jobs
    @tool.execute({ "operation" => "add", "message" => "Job 1", "every_seconds" => 60 })
    @tool.execute({ "operation" => "add", "message" => "Job 2", "cron_expr" => "0 9 * * *" })
    result = @tool.execute({ "operation" => "list" })
    assert_includes result, "2)"
    assert_includes result, "Job 1"
    assert_includes result, "Job 2"
    assert_includes result, "every 60s"
    assert_includes result, "0 9 * * *"
    # Compact: one line per job, no multi-line entries
    assert_equal 3, result.lines.size # header + 2 jobs
    # Job IDs are wrapped in backticks
    assert_match(/`\w{12}`/, result)
  end

  def test_detail_job
    create_result = @tool.execute({ "operation" => "add", "message" => "Detail test", "cron_expr" => "0 9 * * *", "description" => "Test detail" })
    job_id = create_result.match(/✅ `([^`]+)`/)[1]

    result = @tool.execute({ "operation" => "detail", "job_id" => job_id })
    assert_includes result, "`#{job_id}`"
    assert_includes result, "Detail test"
    assert_includes result, "0 9 * * *"
    assert_includes result, "Test detail"
    assert_includes result, "enabled"
  end

  def test_detail_nonexistent_job
    result = @tool.execute({ "operation" => "detail", "job_id" => "nonexistent" })
    assert_includes result, "ERROR"
    assert_includes result, "not found"
  end

  def test_detail_missing_job_id
    result = @tool.execute({ "operation" => "detail" })
    assert_includes result, "ERROR"
    assert_includes result, "job_id"
  end

  def test_remove_job
    create_result = @tool.execute({ "operation" => "add", "message" => "Remove me", "every_seconds" => 60 })
    job_id = create_result.match(/✅ `([^`]+)`/)[1]

    result = @tool.execute({ "operation" => "remove", "job_id" => job_id })
    assert_includes result, "removed"

    list_result = @tool.execute({ "operation" => "list" })
    assert_includes list_result, "No scheduled"
  end

  def test_disable_and_enable_job
    create_result = @tool.execute({ "operation" => "add", "message" => "Toggle me", "every_seconds" => 60 })
    job_id = create_result.match(/✅ `([^`]+)`/)[1]

    result = @tool.execute({ "operation" => "disable", "job_id" => job_id })
    assert_includes result, "disabled"

    result = @tool.execute({ "operation" => "enable", "job_id" => job_id })
    assert_includes result, "enabled"
  end

  def test_disable_nonexistent
    result = @tool.execute({ "operation" => "disable", "job_id" => "nonexistent" })
    assert_includes result, "ERROR"
  end

  def test_unknown_operation
    result = @tool.execute({ "operation" => "invalid" })
    assert_includes result, "ERROR"
    assert_includes result, "Unknown operation"
  end

  def test_registry_includes_cron
    registry = Rubot::Tools::Registry.new
    assert registry.enabled?("cron"), "Registry should include cron tool"
  end

  def test_delivery_context_is_stored_as_job_target
    @tool.delivery_context = { chat_id: 111, thread_id: 222 }
    result = @tool.execute({
      "operation" => "add",
      "message" => "Context test",
      "every_seconds" => 60
    })
    job_id = result.match(/✅ `([^`]+)`/)[1]
    job = @tool.scheduler.get(job_id)
    assert_equal 111, job["target_chat_id"]
    assert_equal 222, job["target_thread_id"]
  end

  def test_explicit_target_overrides_delivery_context
    @tool.delivery_context = { chat_id: 111, thread_id: 222 }
    result = @tool.execute({
      "operation" => "add",
      "message" => "Explicit target",
      "every_seconds" => 60,
      "target_chat_id" => 333
    })
    job_id = result.match(/✅ `([^`]+)`/)[1]
    job = @tool.scheduler.get(job_id)
    assert_equal 333, job["target_chat_id"]
    assert_equal 222, job["target_thread_id"]
  end

  def test_delivery_desc_with_chat_and_thread
    job = { "target_chat_id" => 100, "target_thread_id" => 200 }
    assert_equal "chat 100, topic 200", @tool.send(:delivery_desc, job)
  end

  def test_delivery_desc_with_chat_only
    job = { "target_chat_id" => 100 }
    assert_equal "chat 100", @tool.send(:delivery_desc, job)
  end

  def test_delivery_desc_without_target
    job = {}
    assert_equal "channel default", @tool.send(:delivery_desc, job)
  end

  def test_delivery_context_nil_when_not_set
    result = @tool.execute({
      "operation" => "add",
      "message" => "No context",
      "every_seconds" => 60
    })
    job_id = result.match(/✅ `([^`]+)`/)[1]
    job = @tool.scheduler.get(job_id)
    assert_nil job["target_chat_id"]
    assert_nil job["target_thread_id"]
  end

  def test_add_with_target_parameters
    result = @tool.execute({
      "operation" => "add",
      "message" => "Targeted job",
      "cron_expr" => "0 9 * * *",
      "target_chat_id" => 555,
      "target_thread_id" => 666
    })
    assert_includes result, "✅"
    assert_includes result, "0 9 * * *"
  end
end
