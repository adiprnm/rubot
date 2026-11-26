# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

require "rubot/loop_store"

class TestLoopStore < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rubot-loops")
    @store = Rubot::LoopStore.new(dir: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.exist?(@dir)
  end

  def create_loop(**overrides)
    defaults = { goal: "Fix the flaky test", done_criteria: "rake test is green", repo: "/tmp/repo" }
    @store.create(**defaults.merge(overrides))
  end

  # The budget is a fact about the loop, not about the process that happens to
  # run it, so it lives in the file: a resumed run constructed without an
  # argument must still know what the loop may spend.
  def test_max_tokens_round_trips
    state = create_loop(max_tokens: 12_345)

    assert_equal 12_345, @store.load(state.id).max_tokens
    assert_includes File.read(@store.path(state.id)), "max_tokens: 12345"
  end

  # The base is what the loop's work is measured against, so it has to survive a
  # round trip like every other fact. It also proves the key is in FACT_KEYS:
  # #update goes through #save, whose rebase writes only the facts it was read
  # with plus the caller's own edits, so a key left out of that list is dropped.
  def test_base_round_trips
    state = create_loop
    sha = "0d1e2f30a4b5c6d7e8f901a2b3c4d5e6f7080912"

    @store.update(state.id) { |loop| loop.base = sha }

    assert_equal sha, @store.load(state.id).base
    assert_includes File.read(@store.path(state.id)), %(base: "#{sha}")
  end

  # A file written before the base was a fact must load as "no base" rather than
  # raise, and saving it must not invent one: a base written today would move the
  # line the loop's own changes are measured from.
  def test_a_file_written_before_base_loads_with_nil_and_a_save_keeps_it_nil
    state = create_loop
    file = @store.path(state.id)
    File.write(file, File.read(file).sub(/^base:.*\n/, ""))
    refute_includes File.read(file), "base:"

    loaded = @store.load(state.id)
    assert_nil loaded.base

    @store.save(loaded)

    assert_nil @store.load(state.id).base
    refute_includes File.read(file), "base:"
  end

  # A loop file written before the cap was recorded must not read back as
  # "may spend nothing", which would stop it on its first iteration.
  def test_a_file_without_max_tokens_falls_back_to_the_default
    state = create_loop
    file = @store.path(state.id)
    File.write(file, File.read(file).sub(/^max_tokens:.*\n/, ""))

    assert_equal Rubot::LoopStore::State::DEFAULT_MAX_TOKENS, @store.load(state.id).max_tokens
  end

  # The defaults are facts about the file, so a loop created without them
  # records them and reads them back: three iterations and twelve million
  # tokens, because one measured iteration is two full turns of about 2.8M to
  # 5.8M tokens -- every request inside a turn re-sends the conversation -- and
  # not the 85k a toy loop spends. The numbers are asserted, not described:
  # three cheap iterations (3 * 2.8M = 8.4M) fit under the budget, so the cap
  # can fire first, while three expensive ones (3 * 5.8M = 17.4M) do not, so
  # the budget still brakes a loop that costs too much to reach its cap.
  def test_a_loop_created_without_a_cap_gets_three_iterations_inside_twelve_million_tokens
    state = create_loop

    assert_equal 3, Rubot::LoopStore::State::DEFAULT_MAX_ITERATIONS
    assert_equal 3, @store.load(state.id).max_iterations
    assert_includes File.read(@store.path(state.id)), "max_iterations: 3"

    assert_equal 12_000_000, Rubot::LoopStore::State::DEFAULT_MAX_TOKENS
    assert_includes File.read(@store.path(state.id)), "max_tokens: 12000000"

    assert_operator 2_800_000 * 3, :<=, Rubot::LoopStore::State::DEFAULT_MAX_TOKENS,
                    "three cheap iterations of 2.8M tokens fit under the budget, so the cap can fire first"
    refute_operator 5_800_000 * 3, :<=, Rubot::LoopStore::State::DEFAULT_MAX_TOKENS,
                    "three expensive iterations of 5.8M must not fit, or the budget brakes nothing"
    refute_operator 2_800_000, :>, Rubot::LoopStore::State::DEFAULT_MAX_TOKENS,
                    "the budget has to be above one iteration: 500,000 was below it and stopped every loop on its first one"
  end

  # A file written before the cap was a fact falls back to the same default as a
  # fresh loop, rather than to an eight nobody meant to keep.
  def test_a_file_without_max_iterations_falls_back_to_the_default
    state = create_loop
    file = @store.path(state.id)
    File.write(file, File.read(file).sub(/^max_iterations:.*\n/, ""))

    assert_equal Rubot::LoopStore::State::DEFAULT_MAX_ITERATIONS, @store.load(state.id).max_iterations
  end

  def test_create_then_load_round_trips_the_frontmatter
    state = create_loop(max_iterations: 3)

    loaded = @store.load(state.id)
    assert_equal state.id, loaded.id
    assert_equal "Fix the flaky test", loaded.goal
    assert_equal "rake test is green", loaded.done_criteria
    assert_equal "/tmp/repo", loaded.repo
    assert_equal 3, loaded.max_iterations
    assert_equal "active", loaded.status
    assert_equal 0, loaded.iterations
    assert_equal 0, loaded.tokens
    assert_nil loaded.branch
    assert_instance_of Time, loaded.created_at
  end

  def test_the_file_on_disk_has_frontmatter_and_a_log_section
    state = create_loop

    content = File.read(@store.path(state.id))
    assert content.start_with?("---\n"), "the file opens with YAML frontmatter"
    assert_includes content, "\n---\n\n## Log\n\n"
    assert_includes content, "- "
    assert_includes content, "id: #{state.id}"
    assert_includes content, "goal: \"Fix the flaky test\""
    assert_includes content, "loop started"
  end

  def test_append_log_puts_the_newest_entry_first_and_bumps_updated_at
    state = create_loop
    # Plant an older stamp: create and append can land in the same second, and the
    # bump has to be visible regardless.
    stale = @store.load(state.id)
    stale.updated_at = Time.utc(2020, 1, 1)
    @store.save(stale)
    assert_equal Time.utc(2020, 1, 1), @store.load(state.id).updated_at

    @store.append_log(state.id, "narrowed it to the idle stream")

    loop = @store.load(state.id)
    assert_equal "narrowed it to the idle stream", loop.log.first.text
    assert_equal "loop started", loop.log.last.text
    assert_operator loop.updated_at, :>, Time.utc(2020, 1, 2)
  end

  def test_append_log_collapses_a_multi_line_text_into_one_entry
    state = create_loop

    @store.append_log(state.id, "first line\n  second line\n\nthird")

    loop = @store.load(state.id)
    assert_equal 2, loop.log.size
    assert_equal "first line second line third", loop.log.first.text
    assert_equal 2, File.read(@store.path(state.id)).lines.count { |line| line.start_with?("- ") }
  end

  def test_load_returns_nil_for_a_missing_loop_and_path_rejects_bad_ids
    assert_nil @store.load("20260101-000000-aaaa")

    [ "../escape", "Bad Id" ].each do |bad|
      error = assert_raises(ArgumentError) { @store.path(bad) }
      assert_includes error.message, bad
    end
    assert_raises(ArgumentError) { @store.load("Bad Id") }
  end

  def test_save_rejects_an_unknown_status
    state = create_loop
    state.status = "zombie"

    assert_raises(ArgumentError) { @store.save(state) }
    assert_equal "active", @store.load(state.id).status
  end

  def test_update_persists_what_the_block_changes
    state = create_loop

    returned = @store.update(state.id) do |loop|
      loop.iterations = 4
      loop.tokens = 12_345
    end

    assert_equal 4, returned.iterations
    reloaded = @store.load(state.id)
    assert_equal 4, reloaded.iterations
    assert_equal 12_345, reloaded.tokens
    assert_nil @store.update("20260101-000000-aaaa") { |loop| loop.iterations = 1 }
  end

  def test_ids_lists_every_loop_sorted
    ids = 3.times.map { create_loop.id }
    File.write(File.join(@dir, "notes.txt"), "not a loop")
    File.write(File.join(@dir, "UPPER.md"), "not a loop id")

    assert_equal ids.sort, @store.ids
  end

  def test_two_stores_on_the_same_dir_see_each_others_writes
    other = Rubot::LoopStore.new(dir: @dir)
    state = other.create(goal: "shared goal", done_criteria: "both see it", repo: "/tmp/repo")

    assert_equal "shared goal", @store.load(state.id).goal
    assert_equal [ state.id ], @store.ids
  end

  def test_create_generates_distinct_ids_in_the_same_second
    ids = 5.times.map { create_loop.id }

    assert_equal 5, ids.uniq.size
    assert_equal ids.sort, @store.ids
  end

  # A goal is free text a person typed into a chat, so it holds whatever they
  # typed. String#dump used to escape "#{" as "\#{", which YAML cannot read
  # back: the loop came back with an empty goal and the next save made it so.
  def test_a_goal_containing_an_interpolation_round_trips
    goal = %q(fix the task that builds #{app_name} and prints #1)
    state = create_loop(goal: goal)

    assert_equal goal, @store.load(state.id).goal

    @store.append_log(state.id, %q(still #{here}))
    @store.update(state.id) { |s| s.iterations = 2 }

    assert_equal goal, @store.load(state.id).goal
  end

  def test_values_with_backslash_quote_newline_and_emoji_round_trip
    goal = %(a \\ b "quoted" and\n a second line 🚀)
    criteria = %(run "rake test" \n and read the output)
    state = create_loop(goal: goal, done_criteria: criteria)

    loaded = @store.load(state.id)

    assert_equal goal, loaded.goal
    assert_equal criteria, loaded.done_criteria
  end

  def test_a_broken_frontmatter_raises_instead_of_resetting_the_loop
    state = create_loop
    @store.update(state.id) do |s|
      s.tokens = 41_000
      s.iterations = 3
      s.status = "done"
    end
    broken = File.read(@store.path(state.id)).sub(/^tokens: .*$/, "tokens: [oops")
    File.write(@store.path(state.id), broken)

    assert_raises(Rubot::LoopStore::Corrupt) { @store.load(state.id) }
    assert_equal broken, File.read(@store.path(state.id)),
                 "a file the store cannot read must not be rewritten"
  end

  def test_a_frontmatter_id_that_disagrees_with_the_file_name_is_rewritten
    state = create_loop
    @store.append_log(state.id, "note")
    File.write(@store.path(state.id), File.read(@store.path(state.id)).sub(/^id: .*$/, "id: 20260101-000000-ffff"))

    assert_equal state.id, @store.load(state.id).id

    @store.update(state.id) { |s| s.iterations = 1 }

    assert_includes File.read(@store.path(state.id)), "id: #{state.id}"
    assert_equal [ state.id ], @store.ids
  end

  def test_a_file_without_an_id_loads_under_its_file_name
    state = create_loop
    File.write(@store.path(state.id), File.read(@store.path(state.id)).sub(/^id: .*\n/, ""))

    assert_equal state.id, @store.load(state.id).id
  end

  # One loop, one file: an update after a rename must follow the name it was
  # asked for, not resurrect the old id beside it.
  def test_updating_a_renamed_file_leaves_exactly_one_file
    state = create_loop
    renamed = "20260101-000000-bbbb"
    File.rename(@store.path(state.id), @store.path(renamed))

    @store.update(renamed) { |s| s.iterations = 3 }

    assert_equal [ renamed ], @store.ids
    assert_equal 3, @store.load(renamed).iterations
  end

  def test_loading_from_a_missing_dir_returns_nil_without_creating_it
    store = Rubot::LoopStore.new(dir: File.join(@dir, "nope", "loops"))

    assert_nil store.load("20260101-000000-aaaa")
    refute Dir.exist?(File.join(@dir, "nope")), "a read must not create the store"
  end

  # Two writers, two store instances, one loop directory: the temp file a save
  # writes and renames must not survive it, or the next writer steps over it and a
  # stray `*.md.tmp` sits in the directory for a human to explain. The temp name
  # carries pid, thread and random bytes, so two saves in one process cannot pick
  # the same path either.
  def test_two_stores_saving_the_same_loop_leave_one_file_and_no_temp_files
    state = create_loop
    other = Rubot::LoopStore.new(dir: @dir)

    @store.save(@store.load(state.id))
    other.save(other.load(state.id))

    files = Dir.children(@dir)
    assert_equal [ "#{state.id}.md" ], files.grep(/\.md\z/)
    assert_empty files.grep(/\.tmp\z/)
    assert_equal [ state.id ], @store.ids
  end

  # Semantics chosen for a stale save: it does not overwrite the file wholesale.
  # #save takes the lock #update takes, and under it the file is the base while the
  # object it was handed is a delta against what it read, so a field it never
  # touched keeps what the concurrent #update wrote and only its own edit lands.
  # Last-writer-wins would hand a spent budget back and re-arm a finished loop.
  def test_a_stale_save_keeps_the_field_an_update_wrote_in_between
    stale = @store.load(create_loop.id)
    @store.update(stale.id) do |loop|
      loop.iterations = 2
      loop.tokens = 9_000
    end

    stale.branch = "harden-write-path"
    @store.save(stale)

    reloaded = @store.load(stale.id)
    assert_equal "harden-write-path", reloaded.branch, "the caller's own edit is written"
    assert_equal 2, reloaded.iterations, "an untouched field keeps what #update wrote"
    assert_equal 9_000, reloaded.tokens
  end

  # A save that dies between creating the temp file and the rename must clean up
  # after itself, and the file that was already there must stay readable.
  def test_a_failed_rename_leaves_no_temp_file_behind
    state = create_loop
    before = File.read(@store.path(state.id))

    File.stub(:rename, ->(*_args) { raise Errno::EIO }) do
      assert_raises(Errno::EIO) { @store.save(@store.load(state.id)) }
    end

    assert_empty Dir.children(@dir).grep(/\.tmp\z/)
    assert_equal before, File.read(@store.path(state.id)), "the old file is untouched"
  end

  # The same guarantee when the filesystem steps in first: a read-only loop
  # directory refuses the write, and nothing is left lying around.
  def test_a_save_into_a_read_only_directory_leaves_no_temp_file
    skip "root ignores directory permissions" if Process.uid.zero?

    state = create_loop
    stale = @store.load(state.id)
    before = File.read(@store.path(state.id))
    File.chmod(0o500, @dir)
    begin
      assert_raises(SystemCallError) { @store.save(stale) }
    ensure
      File.chmod(0o700, @dir)
    end

    assert_empty Dir.children(@dir).grep(/\.tmp\z/)
    assert_equal before, File.read(@store.path(state.id))
  end

  # "unknown status: \"zombie\"" said what, not where: a store holds many loops,
  # and the path is what tells a reader which file to open.
  def test_the_status_error_names_the_file
    state = create_loop
    state.status = "zombie"

    error = assert_raises(ArgumentError) { @store.save(state) }

    assert_includes error.message, @store.path(state.id)
    assert_includes error.message, "zombie"
  end

  # One store is shared by every loop thread of a conversation, so the
  # re-entrancy guard has to be per thread. An instance-wide guard let the
  # second thread believe it already held the lock, so it skipped flock and the
  # two writers overwrote each other: 40 updates landed as 10. Tokens and
  # iterations travel in the same write, so a lost update is a loop that thinks
  # it has budget it already spent.
  def test_updates_from_many_threads_on_one_store_lose_nothing
    state = create_loop
    threads = Array.new(4) do
      Thread.new do
        10.times { @store.update(state.id) { |loop| loop.iterations = loop.iterations + 1 } }
      end
    end
    threads.each(&:join)

    assert_equal 40, @store.load(state.id).iterations
  end

  # How many times a loop has been picked up from a process that died. A file
  # written before the fact is a loop that has never been taken over, so the key
  # must read as zero rather than raise, and a save must write the number back.
  def test_takeovers_round_trip_and_a_file_without_the_key_reads_zero
    state = create_loop
    assert_includes File.read(@store.path(state.id)), "takeovers: 0"

    @store.update(state.id) { |loop| loop.takeovers = 2 }
    assert_equal 2, @store.load(state.id).takeovers
    assert_includes File.read(@store.path(state.id)), "takeovers: 2"

    file = @store.path(state.id)
    File.write(file, File.read(file).sub(/^takeovers:.*\n/, ""))

    assert_equal 0, @store.load(state.id).takeovers, "an older file means \"never taken over\", not an error"
  end

  # One completed iteration is proof the run is alive and getting somewhere, so
  # the count of takeovers goes back to zero -- but that is the run's fact, not
  # the store's: an iteration is charged as it starts spending, so `iterations`
  # moves for the runs that die too. The store must therefore leave the number
  # alone, and LoopRun clears it where the verdict is.
  def test_a_write_that_completes_no_iteration_keeps_the_takeovers
    state = create_loop
    @store.update(state.id) { |loop| loop.takeovers = 2 }

    @store.update(state.id) { |loop| loop.iterations = loop.iterations.to_i + 1 }
    @store.append_log(state.id, "still dying")

    assert_equal 1, @store.load(state.id).iterations
    assert_equal 2, @store.load(state.id).takeovers,
                 "a charged iteration is not a finished one, and a log line is not progress"
  end
end
