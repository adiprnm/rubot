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
    now = Time.utc(2025, 5, 4, 8, 0, 0)
    next_time = expr.next_after(now)
    assert_equal Time.utc(2025, 5, 4, 9, 30, 0), next_time
    assert next_time.utc?, "a schedule is computed on the UTC clock"
  end

  def test_next_after_past_time
    expr = Rubot::CronExpression.new("0 9 * * *")
    now = Time.utc(2025, 5, 4, 10, 0, 0)
    next_time = expr.next_after(now)
    assert_equal Time.utc(2025, 5, 5, 9, 0, 0), next_time
  end

  # The hour in the expression is the hour in UTC, whatever zone the caller
  # happens to be in: the same expression must not move when the process does.
  def test_next_after_reads_the_expression_in_utc
    expr = Rubot::CronExpression.new("0 9 * * *")
    local = Time.at(Time.utc(2025, 5, 4, 8, 0, 0).to_i).getlocal("+07:00")

    assert_equal Time.utc(2025, 5, 4, 9, 0, 0), expr.next_after(local)
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

  # --- Per-persona job stores ---

  # A reminder written from a persona's topic is filed in that persona's
  # directory, not in the install's own store, so deleting the persona can take
  # its reminders with it.
  def test_a_job_can_be_filed_in_another_workspace
    persona_dir = File.join(@tmpdir, "personas", "trainer")
    id = @scheduler.add(message: "Latihan 16.30", every_seconds: 3600, workspace: persona_dir)

    assert_equal "Latihan 16.30", @scheduler.get(id)["message"]
    assert_equal persona_dir, @scheduler.get(id)["workspace"]

    persona_store = JSON.parse(File.read(File.join(persona_dir, "cron", "jobs.json")))
    assert persona_store["jobs"].key?(id), "the job belongs to the persona's store"
    refute File.exist?(File.join(@tmpdir, "cron", "jobs.json")),
           "the install's store must not gain a persona's reminder"
  end

  def test_list_and_remove_span_every_store
    persona_dir = File.join(@tmpdir, "personas", "trainer")
    own = @scheduler.add(message: "own", every_seconds: 60)
    theirs = @scheduler.add(message: "theirs", every_seconds: 60, workspace: persona_dir)

    assert_equal %w[own theirs], @scheduler.list.map { |job| job["message"] }.sort

    assert @scheduler.remove(theirs)
    assert_nil @scheduler.get(theirs)
    assert_equal [ "own" ], @scheduler.list.map { |job| job["message"] }
    assert_equal own, @scheduler.list.first["id"]
  end

  def test_a_registered_workspace_loads_jobs_it_did_not_write
    persona_dir = File.join(@tmpdir, "personas", "trainer")
    FileUtils.mkdir_p(File.join(persona_dir, "cron"))
    File.write(File.join(persona_dir, "cron", "jobs.json"), JSON.generate(
      "jobs" => { "abc123" => { "id" => "abc123", "message" => "dari disk", "enabled" => true } }
    ))

    @scheduler.register_workspace(persona_dir)

    assert_equal "dari disk", @scheduler.get("abc123")["message"]
    assert_includes @scheduler.registered_workspaces, File.expand_path(persona_dir)
  end

  def test_merging_a_workspace_moves_its_reminders_to_the_default_store
    persona_dir = File.join(@tmpdir, "personas", "trainer")
    id = @scheduler.add(message: "pindah", every_seconds: 60, workspace: persona_dir)

    moved = @scheduler.merge_workspace(persona_dir, to: @tmpdir)

    assert_equal 1, moved
    assert_equal "pindah", @scheduler.get(id)["message"]
    assert JSON.parse(File.read(File.join(@tmpdir, "cron", "jobs.json")))["jobs"].key?(id)
    assert_empty JSON.parse(File.read(File.join(persona_dir, "cron", "jobs.json")))["jobs"]
  end

  def test_merging_without_a_target_drops_the_reminders
    persona_dir = File.join(@tmpdir, "personas", "trainer")
    id = @scheduler.add(message: "hilang", every_seconds: 60, workspace: persona_dir)

    assert_equal 1, @scheduler.merge_workspace(persona_dir)

    assert_nil @scheduler.get(id)
    assert_empty @scheduler.list
  end

  def test_remove_by_target_clears_one_topic_only
    keep = @scheduler.add(message: "general", every_seconds: 60, target_chat_id: 42)
    drop = @scheduler.add(message: "topic", every_seconds: 60, target_chat_id: 42, target_thread_id: 7)
    other = @scheduler.add(message: "lain", every_seconds: 60, target_chat_id: 99)

    assert_equal 1, @scheduler.remove_by_target(chat_id: 42, thread_id: 7)

    assert @scheduler.get(keep)
    assert_nil @scheduler.get(drop)
    assert @scheduler.get(other)
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
    assert_equal "chat 100, topic 200", Rubot::CronCommands.delivery_desc(job)
  end

  def test_delivery_desc_with_chat_only
    job = { "target_chat_id" => 100 }
    assert_equal "chat 100", Rubot::CronCommands.delivery_desc(job)
  end

  def test_delivery_desc_without_target
    job = {}
    assert_equal "channel default", Rubot::CronCommands.delivery_desc(job)
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

# Jobs are filed by the install, and a job can say who should run it and
# whether it wants a conversation of its own — the two things a daily practice
# session needs and a plain reminder does not.
class TestCronStoreAndDelivery < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @workspace = File.join(@root, "workspace")
    FileUtils.mkdir_p(@workspace)
    @scheduler = Rubot::CronScheduler.new(workspace: @workspace, store_root: @root)
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  # The install's own jobs live next to config.yml, not inside the folder the
  # agent works in.
  def test_the_default_store_sits_at_the_store_root
    @scheduler.add(message: "Pagi", cron_expr: "0 9 * * *")

    assert File.exist?(File.join(@root, "cron", "jobs.json"))
    refute File.exist?(File.join(@workspace, "cron", "jobs.json")), "the workspace should not hold the install's jobs"
  end

  # A persona's reminders still belong to the persona, so deleting it can take
  # them with it.
  def test_a_persona_store_still_lives_in_the_persona_directory
    persona = File.join(@root, "personas", "english-tutor")
    @scheduler.add(message: "Latihan", cron_expr: "0 21 * * *", workspace: persona)

    assert File.exist?(File.join(persona, "cron", "jobs.json"))
  end

  # A scheduler that names no store root keeps its jobs in the workspace, which
  # is what the standalone tests and the REPL rely on.
  def test_without_a_store_root_the_workspace_keeps_the_jobs
    scheduler = Rubot::CronScheduler.new(workspace: @workspace)
    scheduler.add(message: "Ping", every_seconds: 60)

    assert File.exist?(File.join(@workspace, "cron", "jobs.json"))
  end

  def test_a_job_remembers_its_channel_and_persona
    id = @scheduler.add(
      message: "Practice", cron_expr: "0 21 * * *",
      channel: "web", slug: "english-tutor", new_session: true
    )
    job = @scheduler.get(id)

    assert_equal "web", job["channel"]
    assert_equal "english-tutor", job["slug"]
    assert job["new_session"]
  end

  def test_a_job_wants_one_conversation_by_default
    id = @scheduler.add(message: "Minum air", every_seconds: 3600)

    refute @scheduler.get(id)["new_session"]
  end

  # The firing callback is the only thing a channel sees, so everything it
  # needs to deliver the result has to be in it.
  def test_firing_carries_the_channel_persona_and_fresh_session
    fired = nil
    scheduler = Rubot::CronScheduler.new(workspace: @workspace, store_root: @root) { |result| fired = result }
    scheduler.add(
      message: "Practice", at_seconds: 1,
      channel: "web", slug: "english-tutor", new_session: true
    )
    sleep 2

    scheduler.fire_due_jobs

    assert_equal "agent_turn", fired[:mode]
    assert_equal "web", fired[:channel]
    assert_equal "english-tutor", fired[:slug]
    assert fired[:new_session]
  end
end
