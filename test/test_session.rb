# frozen_string_literal: true

require_relative "test_helper"

class TestSession < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_add_scrubs_invalid_utf8
    session = Rubot::Session.new("utf8", workspace: @workspace)
    binary = "\x89PNG\r\n\x1a\n\x00\xff".b

    session.add("tool", binary)

    stored = session.messages.last["content"]
    assert stored.valid_encoding?, "content must be valid UTF-8"
    assert_equal Encoding::UTF_8, stored.encoding

    raw = File.read(File.join(@workspace, "sessions", "utf8.json"))
    assert raw.valid_encoding?, "session file must be valid UTF-8"
    parsed = JSON.parse(raw)
    assert_equal 1, parsed["messages"].size
  end

  def test_add_scrubs_invalid_utf8_in_tool_calls
    session = Rubot::Session.new("utf8-tools", workspace: @workspace)
    bad = "arg\xff".b
    tool_calls = [ { "id" => "call_1", "type" => "function",
                     "function" => { "name" => "shell_exec", "arguments" => bad } } ]

    session.add("assistant", "running", tool_calls: tool_calls)

    raw = File.read(File.join(@workspace, "sessions", "utf8-tools.json"))
    assert raw.valid_encoding?
    JSON.parse(raw) # must not raise
  end

  # A file-backed session (no archive) carries its records in the JSON export,
  # so a diagnosis is available there too — bounded, because the file is
  # rewritten on every save and this is not the transcript.
  def test_request_records_round_trip_through_the_json_file
    session = Rubot::Session.new("cache-json", workspace: @workspace)
    session.record_usage(
      { "prompt_tokens" => 2_000, "cached_tokens" => 1_500, "completion_tokens" => 40 },
      provider: "openai",
      shape: { "provider" => "openai", "model" => "gpt-4o-mini", "epoch" => "epoch-9",
               "tools" => "tools-9", "blocks" => 20, "turns" => 12, "auxiliary" => false }
    )

    reloaded = Rubot::Session.new("cache-json", workspace: @workspace)

    record = reloaded.cache_records.last
    assert_equal "epoch-9", record["epoch"]
    assert_equal 1_500, record["cached_tokens"]
    assert_equal 20, record["blocks"]
  end

  def test_load_ignores_empty_session_file
    dir = File.join(@workspace, "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "empty.json"), "")

    session = Rubot::Session.new("empty", workspace: @workspace)
    assert_equal 0, session.message_count
  end

  def test_load_ignores_corrupt_session_file
    dir = File.join(@workspace, "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "corrupt.json"), "{\"messages\": [")

    session = Rubot::Session.new("corrupt", workspace: @workspace)
    assert_equal 0, session.message_count
  end

  def test_creates_session_without_workspace
    session = Rubot::Session.new("test-1", workspace: nil)
    assert_equal "test-1", session.id
    assert_equal 0, session.message_count
  end

  def test_add_message
    session = Rubot::Session.new("test-2", workspace: nil)
    session.add("user", "Hello!")
    assert_equal 1, session.message_count

    session.add("assistant", "Hi there!")
    assert_equal 2, session.message_count
  end

  def test_message_content
    session = Rubot::Session.new("test-3", workspace: nil)
    session.add("user", "What is Ruby?")
    msg = session.conversation_history.first
    assert_equal "user", msg["role"]
    assert_equal "What is Ruby?", msg["content"]
  end

  def test_conversation_history
    session = Rubot::Session.new("test-4", workspace: nil)
    session.add("user", "Q1")
    session.add("assistant", "A1")
    session.add("user", "Q2")
    session.add("assistant", "A2")

    history = session.conversation_history
    assert_equal 4, history.size
    assert_equal "user", history[0]["role"]
    assert_equal "A1", history[1]["content"]
  end

  def test_clear_session
    session = Rubot::Session.new("test-5", workspace: nil)
    session.add("user", "Hello")
    session.add("assistant", "Hi")
    assert_equal 2, session.message_count

    session.clear!
    assert_equal 0, session.message_count
  end

  def test_persistence_with_workspace
    session = Rubot::Session.new("persist-1", workspace: @workspace)
    session.add("user", "Persistent message")

    # Create a new session instance with the same ID
    session2 = Rubot::Session.new("persist-1", workspace: @workspace)
    assert_equal 1, session2.message_count
    assert_equal "Persistent message", session2.conversation_history.first["content"]
  end

  def test_tool_call_tracking
    session = Rubot::Session.new("tool-session", workspace: nil)
    session.add("assistant", "Let me check", tool_calls: [
      { "id" => "call-1", "type" => "function", "function" => { "name" => "test" } }
    ])
    session.add("tool", "Result", tool_call_id: "call-1")

    history = session.conversation_history
    assistant_msg = history.find { |m| m["role"] == "assistant" }
    assert_instance_of Array, assistant_msg["tool_calls"]

    tool_msg = history.find { |m| m["role"] == "tool" }
    assert_equal "call-1", tool_msg["tool_call_id"]
  end

  def test_forced_skill_is_nil_by_default
    session = Rubot::Session.new("forced-skill-test", workspace: nil)
    assert_nil session.forced_skill
  end

  def test_forced_skill_can_be_set
    session = Rubot::Session.new("forced-skill-test", workspace: nil)
    session.forced_skill = "librarian"
    assert_equal "librarian", session.forced_skill
  end

  def test_forced_skill_can_be_cleared
    session = Rubot::Session.new("forced-skill-test", workspace: nil)
    session.forced_skill = "librarian"
    session.forced_skill = nil
    assert_nil session.forced_skill
  end

  def test_forced_skill_persists_with_workspace
    session = Rubot::Session.new("forced-skill-persist", workspace: @workspace)
    session.add("user", "ping")  # trigger save
    session.forced_skill = "test-skill"
    session.send(:save!)

    session2 = Rubot::Session.new("forced-skill-persist", workspace: @workspace)
    assert_equal "test-skill", session2.forced_skill
  end

  def test_forced_skill_persists_to_disk
    session = Rubot::Session.new("forced-skill-disk", workspace: @workspace)
    session.add("user", "ping")  # trigger save
    session.forced_skill = "my-skill"
    session.send(:save!)
    file_path = session.file_path
    assert File.exist?(file_path)

    data = JSON.parse(File.read(file_path))
    assert_equal "my-skill", data["forced_skill"]
  end

  def test_forced_skill_cleared_alongside_session
    session = Rubot::Session.new("forced-skill-clear", workspace: @workspace)
    session.add("user", "hello")
    session.forced_skill = "some-skill"
    refute_nil session.forced_skill

    session.clear!
    assert_nil session.forced_skill
  end

  def test_model_override_is_nil_by_default
    session = Rubot::Session.new("model-override-test", workspace: nil)
    assert_nil session.model_override
  end

  def test_model_override_can_be_set
    session = Rubot::Session.new("model-override-test", workspace: nil)
    session.model_override = "other-model"
    assert_equal "other-model", session.model_override
  end

  def test_model_override_persists_with_workspace
    session = Rubot::Session.new("model-override-persist", workspace: @workspace)
    session.add("user", "ping")
    session.model_override = "test-model"
    session.send(:save!)

    session2 = Rubot::Session.new("model-override-persist", workspace: @workspace)
    assert_equal "test-model", session2.model_override
  end

  def test_model_override_persists_to_disk
    session = Rubot::Session.new("model-override-disk", workspace: @workspace)
    session.add("user", "ping")
    session.model_override = "my-model"
    session.send(:save!)

    data = JSON.parse(File.read(session.file_path))
    assert_equal "my-model", data["model_override"]
  end

  def test_model_override_cleared_on_session_clear
    session = Rubot::Session.new("model-override-clear", workspace: @workspace)
    session.add("user", "hello")
    session.model_override = "some-model"
    refute_nil session.model_override

    session.clear!
    assert_nil session.model_override
  end
end

class TestSessionSummarization < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @session = Rubot::Session.new("summarize-test", workspace: @workspace)
    @provider = FakeSummarizeProvider.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_summary_is_nil_by_default
    session = Rubot::Session.new("new-session", workspace: @workspace)
    refute session.summarized?
    assert_nil session.summary_text
  end

  def test_append_summary_creates_new_summary
    @session.append_summary("First summary")
    assert_equal "First summary", @session.summary_text
    assert @session.summarized?
  end

  def test_append_summary_appends_to_existing
    @session.append_summary("First part")
    @session.append_summary("Second part")
    assert_includes @session.summary_text, "First part"
    assert_includes @session.summary_text, "Second part"
  end

  def test_summary_text_caps_a_long_running_summary
    session = Rubot::Session.new("long-summary", workspace: nil)
    session.append_summary("a" * 20_000)

    text = session.summary_text

    assert_operator text.length, :<=, Rubot::Session::MAX_SUMMARY_CHARS + 40
    assert text.end_with?("a" * 100)
    assert_includes text, "earlier summary omitted"
  end

  def test_persistence_of_summary
    @session.append_summary("Persistent summary")
    session2 = Rubot::Session.new("summarize-test", workspace: @workspace)
    assert_includes session2.summary_text, "Persistent summary"
  end

  def test_summarize_and_trim_does_nothing_without_workspace
    session = Rubot::Session.new("no-ws", workspace: nil)
    result = session.summarize_and_trim!(provider: @provider, system_prompt: "")
    assert_nil result
  end

  def test_summarize_and_trim_does_nothing_when_under_threshold
    # Default threshold is 60% of 100 = 60 messages
    # With only 10 messages, nothing should happen
    10.times { @session.add("user", "msg") }
    result = @session.summarize_and_trim!(provider: @provider, system_prompt: "")
    assert_nil result
  end

  def test_summarize_and_trim_works_when_over_threshold
    # Need more than 60 messages to trigger (60% of 100)
    70.times { |i| @session.add("user", "Message #{i}") }

    @provider.response = "Summary of old messages"
    result = @session.summarize_and_trim!(provider: @provider, system_prompt: "")

    assert_equal "Summary of old messages", result
    assert @session.summarized?
    assert @session.message_count < 70
  end

  def test_summarize_and_trim_removes_orphaned_tool_messages
    70.times { |i| @session.add("user", "Message #{i}") }
    # Add a tool message at the trimming boundary
    @session.add("assistant", "Let me check", tool_calls: [ { "id" => "t1" } ])
    @session.add("tool", "Result", tool_call_id: "t1")

    @provider.response = "Summary"
    @session.summarize_and_trim!(provider: @provider, system_prompt: "")

    # First message should not be a tool message
    first = @session.messages.first
    refute_equal "tool", first["role"] if first
  end

  def test_summarize_and_trim_handles_provider_error
    70.times { |i| @session.add("user", "Message #{i}") }
    @provider.raise_error = true

    result = @session.summarize_and_trim!(provider: @provider, system_prompt: "")
    assert_nil result
    # Messages should be unchanged
    assert_equal 70, @session.message_count
  end

  # The summary has to be the size of the material it replaces. A fixed 200
  # words was a caption, not a summary: 278 messages of tool work became one
  # paragraph, and the turn that followed spent its rounds re-reading the repo
  # to find out what it had already done.
  def test_the_summary_budget_follows_the_amount_of_conversation
    provider = CapturingSummarizeProvider.new
    @session.add("user", "refactor the importer\n" + ("a line of context\n" * 1_300))
    @session.add("assistant", "working")
    @session.add("assistant", "done")

    @session.compact!(provider: provider, keep_recent: 2, system_prompt: "")

    budget = summary_budget_in(provider.requests.last)
    assert_operator budget, :>, 200, "a 20k-character batch is more than a caption"
    assert_operator budget, :<=, Rubot::Session::MAX_SUMMARY_WORDS
  end

  def test_a_short_conversation_keeps_the_summary_floor
    provider = CapturingSummarizeProvider.new
    @session.add("user", "rename the helper")
    @session.add("assistant", "done")
    @session.add("assistant", "done too")

    @session.compact!(provider: provider, keep_recent: 2, system_prompt: "")

    assert_equal 200, summary_budget_in(provider.requests.last)
  end

  def summary_budget_in(request)
    prompt = request.last["content"]
    match = prompt.match(/Keep it under (\d+) words/)
    refute_nil match, "the summarizer has to be told how long it may be"
    match[1].to_i
  end

  def test_estimated_tokens_grows_with_the_transcript
    session = Rubot::Session.new("estimate", workspace: @workspace)
    empty = session.estimated_tokens

    session.add("user", "a" * 400)
    session.add("assistant", "b" * 400)

    assert_operator session.estimated_tokens, :>, empty + 150
  end

  def test_compact_keeps_recent_messages_and_returns_stats
    20.times { |i| @session.add(i.even? ? "user" : "assistant", "Message #{i}") }

    @provider.response = "Short summary"
    result = @session.compact!(provider: @provider, keep_recent: 4)

    refute_nil result
    assert_equal "Short summary", result[:summary]
    assert_equal 16, result[:summarized_messages]
    assert_equal 4, result[:kept_messages]
    assert_equal "Message 16", @session.messages.first["content"]
    assert @session.summarized?
    assert_operator result[:context_after], :<=, result[:context_before]
  end

  def test_compact_returns_nil_when_there_is_nothing_to_summarize
    3.times { @session.add("user", "hi") }

    assert_nil @session.compact!(provider: @provider, keep_recent: 6)
  end

  def test_compact_splits_large_transcripts_into_batches
    6.times { |i| @session.add("user", "#{i}:" + ("x" * 20_000)) }

    result = @session.compact!(provider: @provider, keep_recent: 1)

    refute_nil result
    # One request per batch plus one merge request.
    assert_operator @provider.calls, :>, 2
    assert_equal 1, @session.message_count
  end

  def test_session_persists_summary_to_disk
    @session.append_summary("Disk test")
    file_path = @session.file_path
    assert File.exist?(file_path)

    data = JSON.parse(File.read(file_path))
    assert_equal "Disk test", data["summary"]
  end

  def test_session_loads_summary_from_disk
    @session.append_summary("Saved summary")

    session2 = Rubot::Session.new("summarize-test", workspace: @workspace)
    assert_equal "Saved summary", session2.summary_text
  end

  def test_context_estimate_anchors_on_the_last_usage
    session = Rubot::Session.new("context-anchor", workspace: @workspace)
    session.add("user", "hello")
    session.record_usage({ "prompt_tokens" => 1_000, "completion_tokens" => 100 })
    session.add("assistant", "hi")

    assert session.context_anchored?
    # The assistant reply is the usage's own output, not extra context.
    assert_equal 1_100, session.context_tokens[:tokens]

    session.add("user", "x" * 350)
    # ~100 tokens estimated for the new message on top of the anchor.
    assert_in_delta 1_200, session.context_tokens[:tokens], 1
  end

  def test_context_estimate_falls_back_to_the_transcript_without_a_usage
    session = Rubot::Session.new("context-estimate", workspace: @workspace)
    session.add("user", "x" * 350)

    refute session.context_anchored?
    assert_in_delta 100, session.context_tokens[:tokens], 1
    assert_in_delta 200, session.context_tokens(extra_chars: 350)[:tokens], 1
  end

  def test_compaction_invalidates_the_context_anchor
    20.times { |i| @session.add(i.even? ? "user" : "assistant", "Message #{i}") }
    @session.record_usage({ "prompt_tokens" => 5_000, "completion_tokens" => 100 })

    assert @session.context_anchored?
    @session.compact!(provider: FakeSummarizeProvider.new, keep_recent: 4)

    refute @session.context_anchored?
    assert_operator @session.context_tokens[:tokens], :<, 5_000
  end

  # --- Task statement ---------------------------------------------------

  def test_the_first_user_message_is_kept_as_the_task
    session = Rubot::Session.new("task-1", workspace: nil)
    session.add("user", "Refactor the auth flow")
    session.add("user", "also rename the helper")

    assert_equal "Refactor the auth flow", session.task_statement
    assert_equal "Refactor the auth flow", session.messages.first["content"]
    refute session.task_anchor_needed?, "the transcript still states the goal itself"
  end

  def test_the_task_survives_compaction
    session = Rubot::Session.new("task-2", workspace: @workspace)
    session.add("user", "Refactor the auth flow")
    10.times { |i| session.add("assistant", "step #{i}") }
    session.compact!(provider: @provider, keep_recent: 2, system_prompt: "")

    refute_includes session.messages.map { |m| m["content"] }, "Refactor the auth flow"
    assert_equal "Refactor the auth flow", session.task_statement
    assert session.task_anchor_needed?, "the compacted transcript no longer states the goal"
  end

  def test_the_task_is_persisted_and_loaded
    session = Rubot::Session.new("task-3", workspace: @workspace)
    session.add("user", "Ship the search tool")
    6.times { |i| session.add("assistant", "step #{i}") }

    reloaded = Rubot::Session.new("task-3", workspace: @workspace)
    assert_equal "Ship the search tool", reloaded.task_statement
  end

  def test_the_title_is_persisted_and_loaded
    session = Rubot::Session.new("title-1", workspace: @workspace)
    session.add("user", "rapikan layout sidebar met")
    session.add("assistant", "Sudah.")
    session.title = "Perbaikan layout"
    session.save!

    reloaded = Rubot::Session.new("title-1", workspace: @workspace)
    assert_equal "Perbaikan layout", reloaded.title
  end

  def test_a_session_file_without_a_title_falls_back_to_the_first_prompt
    dir = File.join(@workspace, "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "untitled.json"), {
      "messages" => [ { "role" => "user", "content" => "Rapikan  layout\nsidebar" },
                      { "role" => "assistant", "content" => "ok" } ]
    }.to_json)

    entry = Rubot::Session.describe(File.join(dir, "untitled.json"))

    assert_equal "Rapikan layout sidebar", entry[:title]
  end

  def test_a_stored_title_wins_over_the_first_prompt
    dir = File.join(@workspace, "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "named.json"), {
      "title" => "Perbaikan layout",
      "messages" => [ { "role" => "user", "content" => "rapikan layout sidebar met" },
                      { "role" => "assistant", "content" => "ok" } ]
    }.to_json)

    assert_equal "Perbaikan layout", Rubot::Session.describe(File.join(dir, "named.json"))[:title]
  end

  def test_a_session_file_without_a_task_field_recovers_it_from_the_transcript
    dir = File.join(@workspace, "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "legacy-task.json"), {
      "messages" => [ { "role" => "user", "content" => "Old prompt" },
                      { "role" => "assistant", "content" => "ok" } ]
    }.to_json)

    session = Rubot::Session.new("legacy-task", workspace: @workspace)
    assert_equal "Old prompt", session.task_statement
  end

  def test_clear_drops_the_task
    session = Rubot::Session.new("task-4", workspace: nil)
    session.add("user", "Do the thing")
    session.clear!

    assert_nil session.task_statement
  end

  def test_cost_is_priced_per_request_with_the_rates_in_effect
    session = Rubot::Session.new("cost-per-request", workspace: @workspace)

    session.record_usage(
      { "prompt_tokens" => 1_000_000, "completion_tokens" => 0 },
      rates: { "input" => 1.0, "output" => 2.0, "cached_input" => 0.5 }
    )
    session.record_usage(
      { "prompt_tokens" => 1_000_000, "completion_tokens" => 0 },
      rates: { "input" => 10.0, "output" => 20.0, "cached_input" => 5.0 }
    )

    # A later model switch must not re-price the first request.
    assert_in_delta 11.0, session.cost["total"], 0.000001
    assert_in_delta 11.0, session.cost["input"], 0.000001
  end

  def test_cost_round_trips_through_the_session_file
    session = Rubot::Session.new("cost-persist", workspace: @workspace)
    session.add("user", "hi")
    session.record_usage(
      { "prompt_tokens" => 1_000, "completion_tokens" => 100, "prompt_tokens_details" => { "cached_tokens" => 500 } },
      rates: { "input" => 3.0, "output" => 15.0, "cached_input" => 0.3 }
    )

    reloaded = Rubot::Session.new("cost-persist", workspace: @workspace)

    assert_in_delta session.cost["total"], reloaded.cost["total"], 0.0000001
    assert reloaded.context_anchored?
  end

  def test_auxiliary_usage_is_counted_in_the_cost_but_keeps_the_anchor
    session = Rubot::Session.new("aux-cost", workspace: @workspace)
    session.add("user", "hi")
    session.record_usage({ "prompt_tokens" => 100, "completion_tokens" => 10 },
                         rates: { "input" => 1.0, "output" => 1.0 })
    anchor = session.last_usage.prompt_tokens

    session.record_auxiliary_usage({ "prompt_tokens" => 50, "completion_tokens" => 5 },
                                   rates: { "input" => 1.0, "output" => 1.0 })

    assert_equal anchor, session.last_usage.prompt_tokens
    assert_in_delta 0.000165, session.cost["total"], 0.0000001
  end

  # A single number for the latest request cannot tell a broken cache from one
  # cold request. The history can: a run of zeros means the prefix moves every
  # time, while one zero after a compaction is expected.
  def test_the_cache_history_keeps_the_shape_of_the_last_requests
    session = Rubot::Session.new("cache-history", workspace: @workspace)
    session.add("user", "hi")

    session.record_usage({ "prompt_tokens" => 1_000, "completion_tokens" => 10,
                           "prompt_tokens_details" => { "cached_tokens" => 990 } })
    session.record_usage({ "prompt_tokens" => 1_000, "completion_tokens" => 10,
                           "prompt_tokens_details" => { "cached_tokens" => 0 } })

    assert_equal [ 0.99, 0.0 ], session.cache_history

    (Rubot::Session::CACHE_HISTORY_LIMIT + 3).times do
      session.record_usage({ "prompt_tokens" => 100, "completion_tokens" => 1,
                             "prompt_tokens_details" => { "cached_tokens" => 50 } })
    end

    assert_equal Rubot::Session::CACHE_HISTORY_LIMIT, session.cache_history.size
    assert_equal 0.5, session.cache_history.last
  end

  def test_the_cache_history_round_trips_through_the_session_file
    session = Rubot::Session.new("cache-history-persist", workspace: @workspace)
    session.add("user", "hi")
    session.record_usage({ "prompt_tokens" => 1_000, "completion_tokens" => 10,
                           "prompt_tokens_details" => { "cached_tokens" => 250 } })

    reloaded = Rubot::Session.new("cache-history-persist", workspace: @workspace)

    assert_equal [ 0.25 ], reloaded.cache_history
  end

  # The prompt is pinned on the session, so it has to survive a restart: a new
  # process rebuilding it would change the bytes and undo the whole point.
  def test_the_pinned_system_prompt_round_trips_and_expires_on_epoch_change
    session = Rubot::Session.new("prompt-pin", workspace: @workspace)
    session.add("user", "hi")

    session.store_system_prompt("pinned prompt", { "model" => "m1" })

    reloaded = Rubot::Session.new("prompt-pin", workspace: @workspace)
    assert_equal "pinned prompt", reloaded.system_prompt_for({ "model" => "m1" })
    assert_nil reloaded.system_prompt_for({ "model" => "m2" }),
               "a different epoch must not reuse the old pin"
  end

  def test_clearing_the_pin_forces_a_rebuild
    session = Rubot::Session.new("prompt-clear", workspace: @workspace)
    session.add("user", "hi")
    session.store_system_prompt("pinned prompt", { "model" => "m1" })

    assert session.clear_system_prompt!
    assert_nil session.system_prompt_for({ "model" => "m1" })
    refute session.clear_system_prompt!, "clearing twice is a no-op"
  end

  class FakeSummarizeProvider
    attr_accessor :response, :raise_error
    attr_reader :calls

    def initialize
      @response = "Summary"
      @raise_error = false
      @calls = 0
    end

    def chat(messages, tools: nil)
      @calls += 1
      raise StandardError, "Provider error" if @raise_error
      @response
    end
  end

  # Keeps every request, so a test can read the prompt the summarizer was
  # actually handed instead of guessing at it.
  class CapturingSummarizeProvider < FakeSummarizeProvider
    attr_reader :requests

    def initialize
      super
      @requests = []
    end

    def chat(messages, tools: nil)
      @requests << messages
      super
    end
  end
end

class TestSessionMemoryBacklog < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @session = Rubot::Session.new("backlog", workspace: @tmpdir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_queues_and_takes_messages
    assert @session.push_memory_backlog("first message")
    assert @session.push_memory_backlog("second message")

    assert_equal [ "first message", "second message" ], @session.take_memory_backlog
    assert_empty @session.memory_backlog
  end

  def test_ignores_blank_messages
    refute @session.push_memory_backlog("   ")
    assert_empty @session.memory_backlog
  end

  def test_caps_the_queue
    (Rubot::Session::MAX_MEMORY_BACKLOG + 3).times { |i| @session.push_memory_backlog("message #{i}") }

    queue = @session.memory_backlog
    assert_equal Rubot::Session::MAX_MEMORY_BACKLOG, queue.size
    assert_includes queue.last, "message #{Rubot::Session::MAX_MEMORY_BACKLOG + 2}"
  end

  def test_survives_a_restart
    @session.push_memory_backlog("queued across restart")

    reloaded = Rubot::Session.new("backlog", workspace: @tmpdir)
    assert_equal [ "queued across restart" ], reloaded.memory_backlog
  end

  def test_clearing_the_session_clears_the_queue
    @session.push_memory_backlog("queued")
    @session.clear!

    assert_empty @session.memory_backlog
  end

  def test_auxiliary_usage_adds_to_totals_without_changing_last_usage
    @session.record_usage({ "prompt_tokens" => 100, "completion_tokens" => 10 })
    last = @session.last_usage

    @session.record_auxiliary_usage({ "prompt_tokens" => 50, "completion_tokens" => 5 })

    assert_equal 150, @session.usage.prompt_tokens
    assert_equal 2, @session.usage.requests
    assert_equal last.prompt_tokens, @session.last_usage.prompt_tokens
  end
end

class TestSessionHistoryWindowing < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @session = Rubot::Session.new("window", workspace: @workspace)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_reasoning_is_only_sent_for_the_requested_tail
    @session.add("assistant", "old answer", reasoning_content: "old thinking")
    @session.add("user", "question")
    @session.add("assistant", "new answer", reasoning_content: "fresh thinking")

    history = @session.conversation_history(reasoning_tail: 1)

    assert_nil history[0]["reasoning_content"]
    assert_equal "fresh thinking", history[2]["reasoning_content"]
  end

  def test_reasoning_tail_zero_drops_all_reasoning
    @session.add("assistant", "answer", reasoning_content: "thinking")

    history = @session.conversation_history(reasoning_tail: 0)

    assert_nil history[0]["reasoning_content"]
  end

  def test_conversation_history_keeps_reasoning_by_default
    @session.add("assistant", "answer", reasoning_content: "thinking")

    assert_equal "thinking", @session.conversation_history[0]["reasoning_content"]
  end

  def test_estimated_tokens_ignores_reasoning_content
    with_reasoning = Rubot::Session.new("with-reasoning", workspace: nil)
    with_reasoning.add("assistant", "answer", reasoning_content: "x" * 4_000)

    without = Rubot::Session.new("without-reasoning", workspace: nil)
    without.add("assistant", "answer")

    # Past reasoning is neither sent nor summarized, so it must not make the
    # transcript look larger to the compaction trigger.
    assert_equal without.estimated_tokens, with_reasoning.estimated_tokens
  end

  def test_message_tokens_counts_reasoning_for_the_request_budget
    msg = { "role" => "assistant", "content" => "answer", "reasoning_content" => "x" * 4_000 }

    assert_operator Rubot::Session.message_tokens(msg), :>=, 1_000
    assert_operator Rubot::Session.message_tokens(msg), :>, Rubot::Session.message_tokens(msg, reasoning: false)
  end

  # ------------------------------------------------------------------
  # Saved-session index (/resume)
  # ------------------------------------------------------------------

  def write_session(id, updated_at:, messages:, cwd: nil)
    dir = File.join(@workspace, "sessions")
    FileUtils.mkdir_p(dir)
    payload = {
      "id" => id,
      "updated_at" => updated_at,
      "messages" => messages
    }
    payload["cwd"] = cwd if cwd
    File.write(File.join(dir, "#{id}.json"), JSON.pretty_generate(payload))
  end

  def test_index_filters_on_an_exact_launch_directory
    messages = [ { "role" => "user", "content" => "hi" } ]
    write_session("here", updated_at: "2026-01-01T10:00:00+07:00", messages: messages, cwd: "/work/app")
    write_session("sub", updated_at: "2026-01-02T10:00:00+07:00", messages: messages, cwd: "/work/app/lib")
    write_session("elsewhere", updated_at: "2026-01-03T10:00:00+07:00", messages: messages, cwd: "/work/other")
    write_session("telegram", updated_at: "2026-01-04T10:00:00+07:00", messages: messages)

    here = Rubot::Session.index(@workspace, cwd: "/work/app")

    assert_equal %w[here], here.map { |entry| entry[:id] }, "prefix directories are not the same project"
    assert_equal 4, Rubot::Session.index(@workspace).size, "no filter lists everything"
    assert_equal %w[elsewhere sub here], Rubot::Session.index(@workspace, cwd: :all)
                                               .reject { |e| e[:cwd].nil? }
                                               .map { |e| e[:id] }
  end

  def test_a_session_records_and_reloads_its_launch_directory
    session = Rubot::Session.new("tagged", workspace: @workspace, cwd: "/work/app")
    session.add("user", "hello")
    session.save!

    assert_equal "/work/app", Rubot::Session.new("tagged", workspace: @workspace).cwd
    assert_equal "/work/app", Rubot::Session.describe(File.join(@workspace, "sessions", "tagged.json"))[:cwd]
    assert_nil Rubot::Session.new("untagged", workspace: @workspace).cwd
  end

  def test_sessions_dir_overrides_where_files_land
    central = File.join(@tmpdir, "central")
    session = Rubot::Session.new("central-1", workspace: @workspace, sessions_dir: central,
                                              cwd: "/work/app")
    session.add("user", "hello")
    session.save!

    assert File.exist?(File.join(central, "central-1.json"))
    refute File.exist?(File.join(@workspace, "sessions", "central-1.json"))
    assert_equal %w[central-1], Rubot::Session.index(nil, dir: central, cwd: "/work/app")
                               .map { |entry| entry[:id] }
    assert_equal "hello", Rubot::Session.transcript(nil, "central-1", dir: central).first["content"]
  end

  def test_fresh_id_avoids_collisions_in_the_given_directory
    central = File.join(@tmpdir, "central")
    FileUtils.mkdir_p(central)
    stamp = "20260101-120000"
    File.write(File.join(central, "default-#{stamp}.json"), "{}")

    assert_equal "default-#{stamp}-2", Rubot::Session.fresh_id(dir: central, stamp: stamp)
  end

  def test_index_lists_sessions_newest_first_and_skips_empty_ones
    write_session("older", updated_at: "2026-01-01T10:00:00+07:00", messages: [
      { "role" => "user", "content" => "  fix   the parser\nplease " },
      { "role" => "assistant", "content" => "done" }
    ])
    write_session("newer", updated_at: "2026-01-02T10:00:00+07:00", messages: [
      { "role" => "user", "content" => "new topic" }
    ])
    write_session("empty", updated_at: "2026-01-03T10:00:00+07:00", messages: [])

    entries = Rubot::Session.index(@workspace)

    assert_equal %w[newer older], entries.map { |entry| entry[:id] }
    assert_equal 2, entries.last[:messages]
    assert_equal "fix the parser please", entries.last[:last_prompt]
    refute entries.last.key?(:timestamp), "sort key stays internal"
  end

  def test_index_skips_unreadable_session_files
    dir = File.join(@workspace, "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "corrupt.json"), "{\"messages\": [")
    write_session("good", updated_at: "2026-01-01T10:00:00+07:00", messages: [
      { "role" => "user", "content" => "hello" }
    ])

    assert_equal %w[good], Rubot::Session.index(@workspace).map { |entry| entry[:id] }
  end

  def test_index_without_a_workspace_is_empty
    assert_empty Rubot::Session.index(nil)
    assert_nil Rubot::Session.find(nil, "default")
  end

  def test_find_returns_a_saved_session_summary
    write_session("work", updated_at: "2026-01-01T10:00:00+07:00", messages: [
      { "role" => "user", "content" => "question" },
      { "role" => "tool", "content" => "noise" },
      { "role" => "assistant", "content" => "answer" }
    ])

    entry = Rubot::Session.find(@workspace, "work")

    assert_equal "work", entry[:id]
    assert_equal "question", entry[:last_prompt]
    assert_nil Rubot::Session.find(@workspace, "missing")
  end

  def test_transcript_returns_every_message_of_a_saved_session
    write_session("work", updated_at: "2026-01-01T10:00:00+07:00", messages: [
      { "role" => "user", "content" => "question" },
      { "role" => "assistant", "content" => "" },
      { "role" => "tool", "content" => "result" }
    ])

    messages = Rubot::Session.transcript(@workspace, "work")

    assert_equal %w[user assistant tool], messages.map { |m| m["role"] }
    assert_equal "result", messages.last["content"]
    assert_empty Rubot::Session.transcript(@workspace, "missing")
  end

  def test_a_tool_message_keeps_its_ui_diff_across_a_reload
    session = Rubot::Session.new("with-diff", workspace: @workspace)
    session.add("tool", "Written 4 characters", tool_call_id: "call_1",
                ui_diff: { "path" => "notes.md", "before" => "old\n", "after" => "new\n" })

    message = Rubot::Session.transcript(@workspace, "with-diff").last

    assert_equal "call_1", message["tool_call_id"]
    assert_equal "old\n", message["ui_diff"]["before"]
    assert_equal "new\n", message["ui_diff"]["after"]
  end

  def test_last_prompt_is_the_newest_user_message
    write_session("work", updated_at: "2026-01-01T10:00:00+07:00", messages: [
      { "role" => "user", "content" => "first question" },
      { "role" => "assistant", "content" => "reply" },
      { "role" => "user", "content" => "latest ask" }
    ])

    assert_equal "latest ask", Rubot::Session.find(@workspace, "work")[:last_prompt]
  end

  def test_session_without_messages_is_not_written_to_disk
    session = Rubot::Session.new("untouched", workspace: @workspace)

    session.save!

    refute File.exist?(session.file_path), "an empty session leaves no file behind"
  end

  def test_clear_removes_the_session_file
    session = Rubot::Session.new("cleared", workspace: @workspace)
    session.add("user", "hello")
    assert File.exist?(session.file_path)

    session.clear!

    refute File.exist?(session.file_path), "a cleared session is gone from disk"
  end

  def test_fresh_id_avoids_ids_already_on_disk
    dir = File.join(@workspace, "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "default-stamp.json"), "{}")

    id = Rubot::Session.fresh_id(@workspace, stamp: "stamp")

    assert_equal "default-stamp-2", id
  end

  def test_fresh_id_without_a_workspace_is_just_the_stamp
    assert_equal "default-stamp", Rubot::Session.fresh_id(nil, stamp: "stamp")
  end
end

class TestSessionCacheStreakWarning < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @session = Rubot::Session.new("streak", workspace: @tmpdir)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def record(cached, epoch: "e1", diverged_at: -1)
    delta = Rubot::Usage.new(prompt_tokens: 50_000, completion_tokens: 10, cached_tokens: cached)
    shape = { "model" => "deepseek-v4.1-flash", "epoch" => epoch, "tools" => "t1",
              "blocks" => 40, "turns" => 20, "diverged_at" => diverged_at }
    _out, err = capture_io { @session.record_cache_record(delta, shape) }
    err
  end

  # Every record also logs the diagnosis of that request (see
  # Session#log_cache_cause); these tests are about the streak line, so they
  # look for that one instead of expecting a silent stderr.
  def test_three_zero_reads_in_a_row_are_warned_about_once
    refute_match(/berurutan/, record(0), "one miss is not a warning")
    refute_match(/berurutan/, record(0), "two misses are not a warning")
    assert_match(/3 request berurutan/, record(0))
    refute_match(/berurutan/, record(0), "a long streak warns at three and then every ten")
  end

  def test_a_read_resets_the_streak
    record(0)
    record(0)
    refute_match(/berurutan/, record(8_000))
    refute_match(/berurutan/, record(0))
  end

  # A trimmed window is an explained miss, not a provider problem.
  def test_a_trim_does_not_count_toward_the_streak
    record(0)
    refute_match(/berurutan/, record(0, diverged_at: 10))
    refute_match(/berurutan/, record(0))
  end

  # The cause itself is always logged: it is the only record of why a request
  # paid full price, and stderr is where the diagnosis belongs.
  def test_the_cause_of_every_request_is_logged
    assert_match(/\[cache\] streak: .*/, record(0))
    assert_match(/\[cache\] streak: hit/, record(40_000))
  end
end
