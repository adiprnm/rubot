# frozen_string_literal: true

require_relative "test_helper"

# A Session backed by the SQLite archive instead of a JSON file.
class TestSessionArchive < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rubot-session-archive")
    @store = Rubot::Store.new(File.join(@dir, "sessions.db"))
    @service = Rubot::StoreService.new(@store)
    @client = Rubot::StoreClient.new(@service.port)
  end

  def teardown
    @service&.stop
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def session(id = "s1", max_messages: Rubot::Session::DEFAULT_MAX_MESSAGES)
    Rubot::Session.new(id, workspace: @dir, archive: @client, max_messages: max_messages)
  end

  def test_messages_round_trip_through_the_archive
    s = session
    s.add("user", "halo")
    s.add("assistant", "hai", reasoning_content: "pikir")

    reloaded = session

    assert_equal %w[halo hai], reloaded.messages.map { |m| m["content"] }
    assert_equal "pikir", reloaded.messages[1]["reasoning_content"]
  end

  def test_json_file_is_not_written
    s = session
    s.add("user", "halo")

    assert_empty Dir.glob(File.join(@dir, "sessions", "*.json")),
                 "the archive is the store; the JSON file is an export, not a write-through"
  end

  # The part that decides whether a restart costs one cold request or a run of
  # them: the pinned prompt, its epoch, and the inputs the epoch is built from.
  def test_cache_critical_state_survives_a_reload
    s = session
    s.add("user", "kerjakan todo")
    s.summary = "ringkasan yang dikutip prompt"
    s.forced_skill = "todotxt"
    epoch = { "model" => "openai/deepseek", "summary" => "d1", "skill" => "todotxt" }
    s.store_system_prompt("PROMPT TERPIN", epoch)

    reloaded = session

    assert_equal "ringkasan yang dikutip prompt", reloaded.summary
    assert_equal "todotxt", reloaded.forced_skill
    assert_equal "kerjakan todo", reloaded.task
    assert_equal "PROMPT TERPIN", reloaded.system_prompt_for(epoch),
                 "the same epoch must get the same pinned prompt back"
  end

  def test_a_changed_epoch_rebuilds_the_prompt
    s = session
    s.add("user", "halo")
    epoch = { "model" => "model-a" }
    s.store_system_prompt("PROMPT TERPIN", epoch)

    reloaded = session

    # A summary rewrite or a model switch must not keep a stale prompt.
    assert_nil reloaded.system_prompt_for({ "model" => "model-b" })
  end

  def test_usage_and_cache_history_survive
    s = session
    s.add("user", "halo")
    s.push_cache_history(Rubot::Usage.from({ "prompt_tokens" => 100, "completion_tokens" => 10,
                                             "prompt_tokens_details" => { "cached_tokens" => 90 } }))
    s.record_auxiliary_usage({ "prompt_tokens" => 100, "completion_tokens" => 10 })
    s.save!

    reloaded = session

    assert_equal 0.9, reloaded.cache_history.last
    assert_operator reloaded.usage.requests, :>, 0
  end

  def test_appends_are_incremental
    s = session
    s.add("user", "satu")
    s.add("assistant", "dua")
    before = @store.message_count("s1")
    s.save!
    s.save!
    after = @store.message_count("s1")

    assert_equal 2, before
    assert_equal 2, after, "saving again must not duplicate history"
  end

  def test_trim_keeps_the_archive_and_moves_the_window
    s = session(max_messages: 4)
    10.times { |i| s.add("user", "pesan #{i}") }

    reloaded = session(max_messages: 4)

    assert_equal 10, @store.message_count("s1"), "the archive keeps every message"
    assert_operator reloaded.messages.size, :<, 10, "the live window was trimmed"
    assert_equal "pesan 9", reloaded.messages.last["content"]
  end

  def test_clear_starts_a_new_window_without_reusing_indices
    s = session
    s.add("user", "sebelum clear")
    s.clear!
    s.add("user", "sesudah clear")

    reloaded = session

    assert_equal [ "sesudah clear" ], reloaded.messages.map { |m| m["content"] },
                 "a cleared session must not resurrect the old transcript"
    assert_equal 2, @store.message_count("s1"), "the archive still holds both"
  end

  def test_a_long_session_can_be_reloaded_after_many_saves
    s = session
    40.times { |i| s.add(i.even? ? "user" : "assistant", "giliran #{i}") }

    reloaded = session

    assert_equal 40, reloaded.messages.size
    assert_equal "giliran 39", reloaded.messages.last["content"]
  end

  # The point of the whole migration, stated as a test: if the payload built
  # from the reloaded transcript differs by a single byte, the provider's prompt
  # cache misses and the turn pays for the whole transcript again.
  def test_reload_produces_an_identical_request_payload
    s = session
    s.add("user", "kerjakan todo besok")
    s.add("assistant", "", tool_calls: [
            { "id" => "call_1", "type" => "function",
              "function" => { "name" => "shell", "arguments" => "{}" } }
          ], reasoning_content: "perlu cek dulu")
    s.add("tool", "[Exit code: 0] ok", tool_call_id: "call_1")
    s.add("assistant", "sudah, semua beres", reasoning_content: "selesai")
    6.times { |i| s.add(i.even? ? "user" : "assistant", "giliran #{i}") }

    before = JSON.generate(s.safe_history(limit: 400))
    reloaded = session
    after = JSON.generate(reloaded.safe_history(limit: 400))

    assert_equal before, after, "a reloaded session must build the same request payload"
  end

  # The records exist so a hit rate can be explained. A record that does not
  # survive the reload cannot explain the request that came before it, which is
  # exactly the request a diagnosis is asked about.
  def test_request_records_survive_a_reload_through_the_archive
    s = session
    s.add("user", "halo")
    s.record_usage(
      { "input_tokens" => 500, "cache_read_input_tokens" => 9_000,
        "cache_creation_input_tokens" => 1_500, "output_tokens" => 20 },
      provider: "anthropic",
      shape: { "provider" => "anthropic", "model" => "claude-sonnet-5",
               "epoch" => "epoch-1", "tools" => "tools-1", "blocks" => 12,
               "turns" => 1, "auxiliary" => false }
    )

    record = session.cache_records.last

    assert_equal "anthropic", record["provider"]
    assert_equal "claude-sonnet-5", record["model"]
    assert_equal 11_000, record["prompt_tokens"], "prompt is read + write + uncached"
    assert_equal 9_000, record["cached_tokens"]
    assert_equal 1_500, record["cache_creation_tokens"]
    assert_equal "epoch-1", record["epoch"]
    assert_equal "tools-1", record["tools"]
    assert_equal 12, record["blocks"]
    assert_equal false, record["auxiliary"]
  end

  def test_an_auxiliary_request_is_recorded_as_auxiliary
    s = session
    s.record_auxiliary_usage(
      { "prompt_tokens" => 800, "cached_tokens" => 0, "completion_tokens" => 5 },
      provider: "openai",
      shape: { "provider" => "openai", "model" => "gpt-4o-mini", "epoch" => "e",
               "tools" => "t", "blocks" => 4, "turns" => 2, "auxiliary" => true }
    )

    assert_equal true, session.cache_records.last["auxiliary"]
  end

  def test_a_request_without_a_shape_writes_no_record
    s = session

    s.record_usage({ "prompt_tokens" => 10, "completion_tokens" => 2 }, provider: "openai")

    assert_empty session.cache_records,
                 "a request whose shape is unknown would only add noise to the diagnosis"
  end

  def test_the_session_keeps_a_bounded_window_of_records
    s = session
    (Rubot::Session::CACHE_RECORDS_LIMIT + 5).times do |i|
      s.record_usage(
        { "prompt_tokens" => 10, "completion_tokens" => 2 },
        provider: "openai",
        shape: { "provider" => "openai", "model" => "m", "epoch" => "e#{i}",
                 "tools" => "t", "blocks" => i, "turns" => 1, "auxiliary" => false }
      )
    end

    records = session.cache_records

    assert_equal Rubot::Session::CACHE_RECORDS_LIMIT, records.size
    assert_equal Rubot::Session::CACHE_RECORDS_LIMIT + 4, records.last["blocks"],
                 "the newest request is the one still in the window"
  end

  def test_a_reload_keeps_the_same_pinned_prompt_for_the_same_epoch
    s = session
    s.add("user", "halo")
    epoch = { "model" => "m", "summary" => "s", "skill" => "", "task" => "t" }
    prompt = "SYSTEM PROMPT PANJANG " * 20
    s.store_system_prompt(prompt, epoch)

    reloaded = session

    assert_equal prompt, reloaded.system_prompt_for(epoch)
  end

  # The fingerprint is what the next request compares against, and the next
  # request can arrive after a restart — so it has to come back from the store,
  # not just from memory.
  def test_the_newest_fingerprint_and_divergence_survive_a_reload
    s = session
    s.add("user", "halo")
    shape = ->(fingerprint, diverged_at) do
      { "provider" => "anthropic", "model" => "m", "epoch" => "e", "tools" => "t",
        "blocks" => 2, "turns" => 1, "auxiliary" => false,
        "fingerprint" => fingerprint, "diverged_at" => diverged_at }
    end
    s.record_usage({ "prompt_tokens" => 10, "cached_tokens" => 0, "completion_tokens" => 1 },
                   provider: "anthropic", shape: shape.call("saaa,tbbb", nil))
    s.record_usage({ "prompt_tokens" => 12, "cached_tokens" => 10, "completion_tokens" => 1 },
                   provider: "anthropic", shape: shape.call("saaa,tbbb,mccc", -1))

    records = session.cache_records

    assert_nil records.first["fingerprint"],
               "the row behind gives up its fingerprint: one comparison is all it is for"
    assert_equal "saaa,tbbb,mccc", records.last["fingerprint"]
    assert_equal(-1, records.last["diverged_at"])
    assert_nil records.first["diverged_at"], "the first request had nothing to compare against"
  end
end
