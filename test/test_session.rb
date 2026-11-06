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
    @session.add("assistant", "Let me check", tool_calls: [{ "id" => "t1" }])
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

  def test_hard_message_trim_invalidates_the_context_anchor
    session = Rubot::Session.new("context-trim", workspace: @workspace)
    100.times { session.add("user", "Message") }
    session.record_usage({ "prompt_tokens" => 5_000, "completion_tokens" => 100 })

    session.add("user", "one more message past the cap")

    refute session.context_anchored?
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

  def test_safe_history_respects_the_token_budget
    @session.add("user", "a" * 400)
    @session.add("assistant", "b" * 400)
    @session.add("assistant", "c" * 400)

    history = @session.safe_history(max_tokens: 150)

    assert_equal 1, history.size
    assert_equal "c" * 400, history.first["content"]
  end

  def test_token_budget_does_not_leave_an_orphaned_tool_result
    @session.add("assistant", "working", tool_calls: [
      { "id" => "call-1", "type" => "function", "function" => { "name" => "test" } }
    ])

    @session.add("tool", "x" * 400, tool_call_id: "call-1")
    @session.add("assistant", "done")

    history = @session.safe_history(max_tokens: 10)

    assert_equal [ "assistant" ], history.map { |m| m["role"] }.uniq
  end

  # ------------------------------------------------------------------
  # Saved-session index (/resume)
  # ------------------------------------------------------------------

  def write_session(id, updated_at:, messages:)
    dir = File.join(@workspace, "sessions")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{id}.json"), JSON.pretty_generate(
      "id" => id,
      "updated_at" => updated_at,
      "messages" => messages
    ))
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
