# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  class TestChannel < Minitest::Test
    # Concrete test subclass
    class DummyChannel < Channel
      attr_reader :started

      def start
        @started = true
        @running = true
      end
    end

    def setup
      @tmpdir = Dir.mktmpdir
      @config = isolated_config(@tmpdir, name: "test_channel")
      @tools = Rubot::Tools::Registry.new
      @agent = Rubot::Agent.new(
        config: @config,
        session_id: "test_channel",
        tools: @tools
      )
    end

    def teardown
      FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
    end

    def test_channel_requires_name
      channel = DummyChannel.new(agent: @agent)
      refute_nil channel.name
    end

    def test_channel_not_running_by_default
      channel = DummyChannel.new(agent: @agent)
      refute channel.running?
    end

    def test_channel_start_sets_running
      channel = DummyChannel.new(agent: @agent)
      channel.start
      assert channel.started
      assert channel.running?
    end

    def test_channel_stop_sets_not_running
      channel = DummyChannel.new(agent: @agent)
      channel.start
      channel.stop
      refute channel.running?
    end

    def test_channel_process_message
      channel = DummyChannel.new(agent: @agent)
      response = channel.process_message("Hello")
      assert_kind_of String, response
    end

    def test_before_process_returns_message_by_default
      channel = DummyChannel.new(agent: @agent)
      assert_equal "hello", channel.before_process("hello")
    end

    def test_before_process_can_transform_message
      channel = DummyChannel.new(agent: @agent)
      def channel.before_process(message)
        "[prefix] #{message}"
      end
      assert_equal "[prefix] hello", channel.before_process("hello")
    end

    def test_before_process_can_skip_with_nil
      channel = DummyChannel.new(agent: @agent)
      def channel.before_process(message)
        nil
      end
      assert_nil channel.process_message("skip me")
    end

    def test_after_process_returns_response_by_default
      channel = DummyChannel.new(agent: @agent)
      result = channel.after_process("msg", "response")
      assert_equal "response", result
    end

    def test_after_process_can_transform_response
      channel = DummyChannel.new(agent: @agent)
      def channel.after_process(message, response)
        response.upcase
      end
      assert_equal "HELLO", channel.after_process("msg", "hello")
    end

    def test_before_process_skip_with_custom_response
      channel = DummyChannel.new(agent: @agent)
      def channel.before_process(message)
        return [ :skip, "Handled!" ] if message == "/cmd"
        message
      end
      assert_equal "Handled!", channel.process_message("/cmd")
    end

    def test_before_process_skip_with_nil_returns_nil
      channel = DummyChannel.new(agent: @agent)
      def channel.before_process(message)
        nil
      end
      assert_nil channel.process_message("skip")
    end

    def test_channel_handle_error_returns_string
      channel = DummyChannel.new(agent: @agent)
      result = channel.handle_error(StandardError.new("test error"))
      assert_kind_of String, result
      assert_includes result, "error"
    end

    def test_channel_handle_error_mentions_timeout
      channel = DummyChannel.new(agent: @agent)

      direct = channel.handle_error(Net::ReadTimeout.new("stalled"))
      assert_includes direct, "did not respond in time"
      refute_includes direct, "Sorry"

      wrapped = channel.handle_error(StandardError.new("Net::ReadTimeout: stalled\nbacktrace"))
      assert_includes wrapped, "did not respond in time"
    end

    def test_abstract_channel_raises
      channel = Channel.new(agent: @agent)
      assert_raises(NotImplementedError) { channel.start }
    end

    def test_session_for_returns_per_session_agent_in_legacy_mode
      channel = DummyChannel.new(agent: @agent)
      session_agent = channel.session_for("s1")
      refute_same @agent, session_agent
      assert_equal "s1", session_agent.session.id
    end

    def test_reap_threads_removes_finished_threads
      channel = DummyChannel.new(agent: @agent)
      finished = Thread.new { sleep 0.01 }
      alive = Thread.new { sleep 10 }
      threads = [ finished, alive ]
      finished.join(1)  # Ensure finished thread has actually completed
      channel.reap_threads(threads)
      refute_includes threads, finished
      assert_includes threads, alive
      alive.kill
      alive.join
    end

    def test_process_message_is_thread_safe_for_same_session
      channel = DummyChannel.new(agent: @agent)
      results = []
      mutex = Mutex.new
      threads = 5.times.map do |i|
        Thread.new do
          resp = channel.process_message("msg-#{i}", session_id: "shared_session")
          mutex.synchronize { results << resp }
        end
      end
      threads.each(&:join)
      # All messages should be processed without errors
      assert_equal 5, results.size
    end

    def test_steer_session_forwards_to_the_running_handle
      channel = DummyChannel.new(agent: @agent)
      steered = []
      handle = Object.new
      handle.define_singleton_method(:steer) do |text|
        steered << text
        true
      end
      channel.send(:track_running_session, "steer-session", handle)

      assert channel.steer_session("steer-session", "pakai folder lain")
      assert_equal [ "pakai folder lain" ], steered
    end

    def test_steer_session_is_false_when_nothing_runs
      channel = DummyChannel.new(agent: @agent)

      refute channel.steer_session("steer-session", "pakai folder lain")
    end

    def test_request_agent_returns_per_session_clone
      channel = DummyChannel.new(agent: @agent)
      captured = nil

      # Override before_process to capture the request_agent
      def channel.before_process(message)
        captured_agent = request_agent
        # Verify it's different from the shared agent (has its own session)
        [ :skip, captured_agent.session.id ]
      end

      response = channel.process_message("test", session_id: "test_req_agent")
      assert_equal "test_req_agent", response
    end

    def test_request_agent_returns_shared_agent_outside_process_message
      channel = DummyChannel.new(agent: @agent)
      assert_same @agent, channel.request_agent
    end

    # Ruby 4.0.9 takes SIGSEGV in ractor_port_close when a session Ractor is torn
    # down while a caller is still blocked receiving on its event port — what a
    # quit during a running turn looks like. #shutdown_pool therefore stops the
    # turns and waits for their callers to return before shutting the pool down.
    def test_shutdown_pool_stops_running_turns_before_tearing_the_pool_down
    order = []
    pool = Object.new
    pool.define_singleton_method(:shutdown) { order << :pool_shutdown }

    channel = DummyChannel.new(channel_config: {})
    channel.instance_variable_set(:@pool, pool)
    channel.instance_variable_set(:@owned_pool, true)

    handle = Object.new
    handle.define_singleton_method(:cancel!) do
      order << :cancelled
      channel.send(:untrack_running_session, "s1", handle)
    end
    channel.send(:track_running_session, "s1", handle)

    channel.shutdown_pool

    assert_equal [ :cancelled, :pool_shutdown ], order
    end

    def test_shutdown_pool_does_nothing_when_the_channel_owns_no_pool
    channel = DummyChannel.new(channel_config: {})

    channel.shutdown_pool # must not raise

    assert_nil channel.pool
    end
  end

  class TestChannelRegistry < Minitest::Test
    def test_build_channel_list_from_hash_config
      data = {
        "channels" => {
          "repl" => { "stream" => true },
          "telegram" => { "token" => "test" }
        }
      }
      result = Channels::Registry.build_channel_list(data, {})
      assert_equal 2, result.size
      assert_equal "repl", result[0][0]
      assert_equal "telegram", result[1][0]
    end

    def test_build_channel_list_from_array_config
      data = { "channels" => [ "telegram", "repl" ] }
      result = Channels::Registry.build_channel_list(data, {})
      assert_equal 2, result.size
      assert_equal [ [ "telegram", {} ], [ "repl", {} ] ], result
    end

    def test_build_channel_list_empty_if_no_channels_key
      result = Channels::Registry.build_channel_list({}, {})
      assert_empty result
    end

    def test_build_channel_list_cli_override
      data = { "channels" => { "repl" => {} } }
      options = { channel: "telegram" }
      result = Channels::Registry.build_channel_list(data, options)
      assert_equal [ [ "telegram", {} ] ], result
    end

    def test_channel_map_known_channels
      assert_includes Channels::Registry::CHANNEL_MAP.keys, "telegram"
      assert_includes Channels::Registry::CHANNEL_MAP.keys, "repl"
    end

    def test_build_channel_list_filters_disabled
      data = {
        "channels" => {
          "repl" => { "enabled" => true },
          "telegram" => { "enabled" => false }
        }
      }
      result = Channels::Registry.build_channel_list(data, {})
      assert_equal 2, result.size
      # The registry.start_channels will filter disabled, but
      # build_channel_list returns all — filtering is done in start_channels
    end

    def test_start_channels_skips_disabled
      data = {
        "channels" => {
          "repl" => { "enabled" => false },
          "telegram" => { "enabled" => false }
        }
      }
      Dir.mktmpdir do |dir|
        config = isolated_config(dir, name: "test_disabled")
        tools = Rubot::Tools::Registry.new
        agent = Rubot::Agent.new(
          config: config,
          session_id: "test_disabled",
          tools: tools
        )
        assert_raises(RuntimeError) do
          Channels::Registry.start_channels(data: data, agent: agent)
        end
      end
    end
  end

  class TestTelegramChannel < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
      @config = isolated_config(@tmpdir, name: "test_telegram")
      @tools = Rubot::Tools::Registry.new
      @agent = Rubot::Agent.new(
        config: @config,
        session_id: "test_telegram",
        tools: @tools
      )
      @tg = Rubot::Channels::Telegram.new(
        agent: @agent,
        channel_config: { "token" => "fake-token-for-testing" }
      )
    end

    def teardown
      FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
    end

    def test_start_returns_skip_response
      result = @tg.before_process("/start")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1], "Welcome"
    end

    def test_help_returns_skip_response
      result = @tg.before_process("/help")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1], "Help"
    end

    def test_help_returns_skip_response_case_insensitive
      result = @tg.before_process("/HELP")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
    end

    def test_normal_message_passes_through
      assert_equal "hello", @tg.before_process("hello")
    end

    def test_unknown_command_passes_through
      assert_equal "/unknown arg1", @tg.before_process("/unknown arg1")
    end

    def test_process_message_handles_skip_response
      response = @tg.process_message("/start")
      assert_kind_of String, response
      assert_includes response, "Welcome"
    end

    def test_new_command_returns_skip_response
      result = @tg.before_process("/new")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1], "new session"
    end

    def test_compact_command_handles_an_empty_session
      result = @tg.before_process("/compact")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1], "Tidak ada"
    end

    # Telegram gets the same door as the TUI and the page: the prompt is pinned
    # so the cache survives a memory write, and this is how a reader asks for the
    # files as they are now. The reply carries the price, because it lands on the
    # next request rather than this one.
    def test_repin_command_rebuilds_the_pinned_prompt
      handle = @tg.request_agent
      handle.define_singleton_method(:repin_system_prompt) { @repinned = true }

      result = @tg.before_process("/repin")

      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert handle.instance_variable_get(:@repinned), "the pin has to actually be dropped"
      assert_includes result[1], "dibangun ulang"
      assert_includes result[1], "membayar penuh"
    end

    def test_repin_command_says_when_there_was_nothing_pinned
      handle = @tg.request_agent
      handle.define_singleton_method(:repin_system_prompt) { false }

      result = @tg.before_process("/repin")

      assert_equal :skip, result[0]
      assert_includes result[1], "belum di-pin"
    end

    def test_new_command_is_case_insensitive
      result = @tg.before_process("/NEW")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
    end

    def test_new_command_clears_session
      # Add a message to the session first
      @agent.session.add("user", "hello")
      refute_empty @agent.session.messages

      @tg.before_process("/new")
      assert_empty @agent.session.messages
    end

    def test_help_mentions_new_command
      result = @tg.before_process("/help")
      assert_kind_of Array, result
      assert_includes result[1], "/new"
    end

    def test_help_mentions_stop_command
      result = @tg.before_process("/help")
      assert_kind_of Array, result
      assert_includes result[1], "/stop"
    end

    def test_bot_commands_are_registered_for_group_chats
      scopes = []
      commands = []
      @tg.define_singleton_method(:http_post) do |_url, req|
        body = JSON.parse(req.body)
        scopes << body["scope"]["type"]
        commands << body["commands"].map { |c| c["command"] }
        { "ok" => true }
      end

      @tg.send(:register_bot_commands)

      assert_includes scopes, "default"
      assert_includes scopes, "all_private_chats"
      assert_includes scopes, "all_group_chats", "groups need their own scope in some clients"
      assert_includes commands.first, "stop"
    end

    def test_stop_without_a_running_task_reports_nothing_to_stop
      sent = []
      @tg.define_singleton_method(:send_message) { |_chat, text, _thread| sent << text }

      @tg.send(:handle_stop_command, 42, nil)

      assert_includes sent.last, "Tidak ada tugas"
    end

    def test_stop_cancels_the_running_turn
      sent = []
      @tg.define_singleton_method(:send_message) { |_chat, text, _thread| sent << text }

      handle = Class.new do
        attr_reader :cancelled
        def cancel!
          @cancelled = true
        end
      end.new
      @tg.send(:track_running_session, "tg_42", handle)

      @tg.send(:handle_stop_command, 42, nil)

      assert handle.cancelled
      assert_includes sent.last, "Menghentikan"
    end

    def test_stop_releases_a_waiting_confirmation
      pending = @tg.instance_variable_get(:@pending_confirmations)
      mutex = @tg.instance_variable_get(:@confirm_mutex)
      cv = ConditionVariable.new
      pending["abc"] = { cv: cv, result: nil, msg_id: 1, chat_id: 42, thread_id: nil }

      woken = false
      waiter = Thread.new do
        mutex.synchronize do
          cv.wait(mutex, 5)
          woken = true
        end
      end
      sleep 0.1

      @tg.send(:cancel_pending_confirmations, 42, nil)

      assert waiter.join(2), "the confirmation wait must be woken"
      assert woken
      assert_equal false, pending["abc"][:result]
    ensure
      pending&.delete("abc")
    end

    def test_info_command_returns_skip
      result = @tg.before_process("/info")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1], "Agent Info"
    end

    def test_models_command_returns_skip
      result = @tg.before_process("/models")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1].downcase, "model"
    end

    def test_skills_command_returns_skip
      result = @tg.before_process("/skills")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1], "Skills"
    end

    def test_memory_command_returns_skip
      result = @tg.before_process("/memory")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
    end

    def test_soul_command_returns_skip
      result = @tg.before_process("/soul")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
    end

    def test_agents_command_returns_skip
      result = @tg.before_process("/agents")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
    end

    def test_help_lists_all_commands
      result = @tg.before_process("/help")
      assert_kind_of Array, result
      %w[/new /info /models /skills /memory /soul /agents /cron /help /start /use /unuse].each do |cmd|
        assert_includes result[1], cmd, "help text should mention #{cmd}"
      end
    end

    def test_use_without_skill_name_shows_usage
      result = @tg.before_process("/use")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1], "Usage"
      assert_includes result[1], "/use"
    end

    def test_use_with_nonexistent_skill_shows_error
      result = @tg.before_process("/use nonexistent-skill")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1], "not found"
    end

    def test_use_with_valid_skill_sets_forced_skill
      # Install a test skill
      @agent.skill_registry.install("test-skill", "# Test Skill\n\nInstructions.")

      result = @tg.before_process("/use test-skill")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1], "will be used"
      assert_equal "test-skill", @agent.session.forced_skill
    end

    def test_unuse_clears_forced_skill
      @agent.session.forced_skill = "some-skill"

      result = @tg.before_process("/unuse")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1], "cleared"
      assert_nil @agent.session.forced_skill
    end

    def test_unuse_when_no_skill_set_shows_info
      @agent.session.forced_skill = nil

      result = @tg.before_process("/unuse")
      assert_kind_of Array, result
      assert_equal :skip, result[0]
      assert_includes result[1], "No forced skill"
    end

    def test_default_max_concurrent_requests
      assert_equal 10, @tg.instance_variable_get(:@request_slots)
    end

    def test_custom_max_concurrent_requests
      tg = Rubot::Channels::Telegram.new(
        agent: @agent,
        channel_config: { "token" => "fake", "max_concurrent_requests" => 5 }
      )
      assert_equal 5, tg.instance_variable_get(:@request_slots)
    end

    def test_active_threads_starts_empty
      assert_empty @tg.instance_variable_get(:@active_threads)
    end

    def test_acquire_and_release_request_slot
      @tg.acquire_request_slot
      @tg.release_request_slot
      assert_equal 10, @tg.instance_variable_get(:@request_slots)
    end

    def test_send_narration_sends_the_model_text_as_a_chat_message
      sent = []
      @tg.define_singleton_method(:send_message) do |chat_id, text, thread_id = nil|
        sent << [ chat_id, text, thread_id ]
        true
      end

      @tg.send(:send_narration, 42, 7, "  Let me check the structure first.  ")

      assert_equal [ [ 42, "Let me check the structure first.", 7 ] ], sent
    end

    def test_send_narration_ignores_blank_text
      sent = []
      @tg.define_singleton_method(:send_message) { |*_args| sent << :sent }

      @tg.send(:send_narration, 42, nil, "   ")

      assert_empty sent
    end

    def test_send_narration_can_be_disabled
      tg = Rubot::Channels::Telegram.new(
        agent: @agent,
        channel_config: { "token" => "fake", "narration" => false }
      )
      sent = []
      tg.define_singleton_method(:send_message) { |*_args| sent << :sent }

      tg.send(:send_narration, 42, nil, "hello")

      assert_empty sent
    end

    # The status card is a live "running tool" line. A narration must land below
    # it, so the card is deleted before the words are sent — never left sitting
    # above the assistant text that describes what happened after it.
    def test_send_narration_deletes_the_stale_tool_status_first
      events = []
      seed_status_message(42, 7, "sent-1")

      @tg.define_singleton_method(:delete_message) do |chat_id, message_id|
        events << [ :delete, chat_id, message_id ]
        true
      end
      @tg.define_singleton_method(:send_message) do |chat_id, text, thread_id = nil|
        events << [ :send, chat_id, text, thread_id ]
        true
      end

      @tg.send(:send_narration, 42, 7, "Perintah tadi kena guard, gue pecah jadi yang aman.")

      assert_equal [
        [ :delete, 42, "sent-1" ],
        [ :send, 42, "Perintah tadi kena guard, gue pecah jadi yang aman.", 7 ]
      ], events
    end

    def test_narration_keeps_the_tool_step_count_so_the_next_card_continues
      seed_status_message(42, 7, "sent-1")
      status_key = @tg.send(:status_key, 42, 7)
      @tg.instance_variable_get(:@tool_counts)[status_key] = 3
      @tg.define_singleton_method(:delete_message) { |*_args| true }
      @tg.define_singleton_method(:send_message) { |*_args| true }

      @tg.send(:send_narration, 42, 7, "Checking the next file.")

      assert_equal 3, @tg.instance_variable_get(:@tool_counts)[status_key]
    end

    def test_clear_status_message_resets_the_step_count_for_the_next_request
      seed_status_message(42, 7, "sent-1")
      status_key = @tg.send(:status_key, 42, 7)
      @tg.instance_variable_get(:@tool_counts)[status_key] = 3
      @tg.define_singleton_method(:delete_message) { |*_args| true }

      @tg.send(:clear_status_message, 42, 7)

      assert_nil @tg.instance_variable_get(:@tool_counts)[status_key]
    end

    # --- Live status card ---------------------------------------------------

    # The card says only what is true: which tool, which step, how long. No
    # "Still working" prose, because at that moment nothing is running.
    def test_status_card_shows_literal_state_without_prose
      texts = capture_status_texts

      @tg.send(:notify_tool_started, 42, 7, "shell_exec", { "command" => "bundle exec rspec" })

      assert_equal 1, texts.size
      assert_includes texts[0], "💻 `shell_exec` · step 1 · 0s"
      assert_includes texts[0], "bundle exec rspec"
      refute_includes texts[0], "Running tool"
      refute_includes texts[0], "Still working"
    end

    # A finished round means no tool is running, so the card marks the step done
    # and offers the one escape hatch the user has while waiting.
    def test_finished_round_marks_the_step_done_and_hints_stop_once
      texts = capture_status_texts

      @tg.send(:notify_tool_started, 42, 7, "file_ops", { "operation" => "read", "path" => "lib/rubot/agent.rb" })
      @tg.send(:notify_progress, 42, 7, 2)
      refute_includes texts.last, "/stop", "two rounds is not yet worth a stop hint"

      @tg.send(:notify_progress, 42, 7, 3)
      assert_includes texts.last, "✓"
      assert_equal 1, texts.last.scan("/stop").size

      @tg.send(:notify_progress, 42, 7, 9)
      assert_equal 1, texts.last.scan("/stop").size, "the hint must not repeat"
      refute_includes texts.last, "round", "the round counter stays internal"
    end

    def test_status_card_shows_running_subagents
      texts = capture_status_texts

      @tg.send(:notify_tool_started, 42, 7, "shell_exec", { "command" => "ls" })
      @tg.send(:notify_subagent, 42, 7, { run_id: "r1", agent: "writer", phase: "started", detail: "write a poem" })
      @tg.send(:notify_subagent, 42, 7, { run_id: "r2", agent: "researcher", phase: "tool", detail: "search docs" })

      card = texts.last
      assert_includes card, "2 subagent aktif"
      assert_includes card, "writer"
      assert_includes card, "researcher"
      assert_includes card, "search docs"

      @tg.send(:notify_subagent, 42, 7, { run_id: "r1", agent: "writer", phase: "done", detail: "3s" })
      assert_includes texts.last, "1 subagent aktif"
      assert_includes texts.last, "✓ writer"
    end

    def test_progress_without_a_tool_card_does_nothing
      texts = capture_status_texts

      @tg.send(:notify_progress, 42, 7, 5)

      assert_empty texts
    end

    # Telegram allows ~1 message per second per chat, and an edit counts as one.
    # Tools inside a single batch arrive faster than that.
    def test_status_edits_are_throttled_to_one_per_second
      clock = 0.0
      @tg.define_singleton_method(:monotonic_now) { clock }
      events = []
      @tg.define_singleton_method(:send_message_with_id) do |*_args|
        events << :sent
        "sent-1"
      end
      @tg.define_singleton_method(:edit_message) { |*_args| events << :edited }

      @tg.send(:update_or_send_status, 42, 7, "step 1")
      @tg.send(:update_or_send_status, 42, 7, "step 2")
      assert_equal [ :sent ], events, "an edit inside the interval is dropped"

      clock = 1.5
      @tg.send(:update_or_send_status, 42, 7, "step 2")
      assert_equal [ :sent, :edited ], events
    end

    def test_identical_status_text_is_never_resent
      clock = 0.0
      @tg.define_singleton_method(:monotonic_now) { clock }
      events = []
      @tg.define_singleton_method(:send_message_with_id) do |*_args|
        events << :sent
        "sent-1"
      end

      @tg.send(:update_or_send_status, 42, 7, "step 1")
      clock = 10.0
      @tg.send(:update_or_send_status, 42, 7, "step 1")

      assert_equal [ :sent ], events
    end

    # A 429 is not retried in place: the wait Telegram asks for can be 15-30s,
    # which would stall the agent loop. The gate closes for that chat instead,
    # so no further send or edit goes out until the window expires.
    def test_a_429_closes_the_flood_gate_and_drops_the_edit
      calls = 0
      @tg.define_singleton_method(:http_post) do |_url, _req|
        calls += 1
        { "ok" => false, "error_code" => 429, "description" => "Too Many Requests",
          "parameters" => { "retry_after" => 17 } }
      end

      assert_equal :error, @tg.send(:post_edit, 42, "sent-1", "hi", "HTML")
      assert_equal 1, calls
      assert_operator @tg.send(:flood_remaining, 42), :>, 0
    end

    def test_a_flood_window_silences_sends_and_edits_for_that_chat
      sends = 0
      @tg.define_singleton_method(:http_post) do |_url, _req|
        sends += 1
        { "ok" => false, "error_code" => 429, "description" => "Too Many Requests",
          "parameters" => { "retry_after" => 17 } }
      end

      @tg.send(:post_edit, 42, "sent-1", "hi", "HTML")
      assert_equal :error, @tg.send(:deliver, 42, "hello", nil, parse_mode: nil)
      assert_equal :error, @tg.send(:post_edit, 42, "sent-1", "again", "HTML")
      assert_equal 1, sends, "nothing reaches the API while the gate is closed"

      # A different chat is unaffected: the limit is per chat.
      refute_operator @tg.send(:flood_remaining, 99), :>, 0
    end

    def test_format_elapsed
      assert_equal "0s", @tg.send(:format_elapsed, 0)
      assert_equal "59s", @tg.send(:format_elapsed, 59.9)
      assert_equal "1m 05s", @tg.send(:format_elapsed, 65)
      assert_equal "1h 02m", @tg.send(:format_elapsed, 3720)
    end

    # Register a status message the way update_or_send_status would, without
    # touching the Telegram API.
    def seed_status_message(chat_id, thread_id, message_id)
      key = @tg.send(:status_key, chat_id, thread_id)
      @tg.instance_variable_get(:@status_messages)[key] = {
        chat_id: chat_id, thread_id: thread_id, message_id: message_id
      }
    end

    # Capture what the status card would have rendered, bypassing the throttle
    # and the Telegram API.
    def capture_status_texts
      texts = []
      @tg.define_singleton_method(:update_or_send_status) do |_chat_id, _thread_id, text, **_options|
        texts << text
        true
      end
      texts
    end
  end

  # Stubs every piece that would touch the network, and records what the
  # agent would have been asked. Shared by the inbound media and reply tests.
  class StubbedTelegram < Channels::Telegram
    attr_reader :sent, :prompts, :downloads

    def initialize(downloads: [], **kwargs)
      super(**kwargs)
      @sent = []
      @prompts = []
      @downloads = downloads
    end

    private

    def send_message(chat_id, text, thread_id = nil)
      @sent << [ chat_id, text, thread_id ]
      true
    end

    def send_message_plain(chat_id, text, thread_id = nil)
      @sent << [ chat_id, text, thread_id ]
      true
    end

    def process_message(message, session_id: nil, **_callbacks)
      @prompts << [ message, session_id ]
      "agent reply"
    end

    def send_action(*_args)
      nil
    end

    def download_attachment(_attachment, session_id)
      @downloads.shift || File.join(attachments_root, sanitize_component(session_id), "shot.png")
    end
  end

  # Stands in for a running session handle in steering tests: records the text
  # the channel hands to the turn already in flight.
  class SteeringHandle
    attr_reader :steered

    def initialize
      @steered = []
    end

    def steer(text)
      @steered << text
      true
    end
  end

  # A second message while a turn is running steers that turn (delivered
  # between rounds) instead of queueing behind it.
  class TestTelegramSteering < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
      @config = isolated_config(@tmpdir, name: "test_steering")
      @agent = Rubot::Agent.new(config: @config, session_id: "test_steering",
                                tools: Rubot::Tools::Registry.new)
      @tg = StubbedTelegram.new(
        agent: @agent,
        channel_config: { "token" => "fake", "typing_indicator" => false }
      )
    end

    def teardown
      FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
    end

    def text_update(text, thread_id: nil)
      message = {
        "chat" => { "id" => 42, "type" => "private" },
        "from" => { "id" => 42, "username" => "tester" },
        "text" => text
      }
      message["message_thread_id"] = thread_id if thread_id
      { "update_id" => 1, "message" => message }
    end

    def test_a_message_while_the_session_runs_steers_the_turn
      handle = SteeringHandle.new
      @tg.send(:track_running_session, "tg_42", handle)

      @tg.send(:process_update, text_update("pakai folder lain"))

      assert_equal [ "pakai folder lain" ], handle.steered
      assert_empty @tg.prompts, "a steered message does not start its own turn"
      assert_includes @tg.sent.last[1], "Diteruskan ke tugas yang sedang berjalan."
    end

    def test_a_steered_message_in_a_topic_uses_the_topic_session
      handle = SteeringHandle.new
      @tg.send(:track_running_session, "tg_42_7", handle)

      @tg.send(:process_update, text_update("pakai folder lain", thread_id: 7))

      assert_equal [ "pakai folder lain" ], handle.steered
      assert_empty @tg.prompts
    end

    def test_a_command_while_the_session_runs_is_not_steered
      handle = SteeringHandle.new
      @tg.send(:track_running_session, "tg_42", handle)

      @tg.send(:process_update, text_update("/help"))

      assert_empty handle.steered
      assert_equal [ [ "/help", "tg_42" ] ], @tg.prompts
    end

    def test_a_reply_quote_rides_along_with_the_steer
      handle = SteeringHandle.new
      @tg.send(:track_running_session, "tg_42", handle)

      update = text_update("yang ini maksudnya?")
      update["message"]["reply_to_message"] = {
        "message_id" => 9,
        "from" => { "id" => 7, "username" => "alice" },
        "text" => "harga naik 12% bulan ini"
      }
      @tg.send(:process_update, update)

      steer = handle.steered.first
      assert steer.start_with?("yang ini maksudnya?"), steer
      assert_includes steer, "harga naik 12% bulan ini"
    end

    def test_a_media_message_while_the_session_runs_queues_its_own_turn
      handle = SteeringHandle.new
      @tg.send(:track_running_session, "tg_42", handle)
      image = File.join(@config.workspace, "attachments", "tg_42", "shot.png")
      FileUtils.mkdir_p(File.dirname(image))
      File.binwrite(image, png_bytes(1200, 800))
      @tg.downloads << image

      update = text_update("")
      update["message"].delete("text")
      update["message"]["caption"] = "lihat ini"
      update["message"]["photo"] = [
        { "file_id" => "small", "file_unique_id" => "u1", "file_size" => 1_000 },
        { "file_id" => "large", "file_unique_id" => "u2", "file_size" => 90_000 }
      ]
      @tg.send(:process_update, update)

      assert_empty handle.steered, "media is not steered"
      assert_equal 1, @tg.prompts.size, "it queues as its own turn instead"
    end

    def png_bytes(width, height)
      ihdr = [ width, height, 8, 2, 0, 0, 0 ].pack("N2C5")
      "\x89PNG\r\n\x1A\n".b + [ 13 ].pack("N") + "IHDR" + ihdr + [ 0 ].pack("N")
    end
  end

  # Inbound media: Telegram sends photos as `photo` + `caption`, never as
  # `text`. These tests lock in that a captioned screenshot reaches the agent.
  class TestTelegramInboundAttachments < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
      @config = isolated_config(@tmpdir, name: "test_inbound")
      @agent = Rubot::Agent.new(config: @config, session_id: "test_inbound", tools: Rubot::Tools::Registry.new)
      @image = File.join(@config.workspace, "attachments", "tg_42", "shot.png")
      FileUtils.mkdir_p(File.dirname(@image))
      File.binwrite(@image, png_bytes(1864, 1200))
    end

    def teardown
      FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
    end

    def png_bytes(width, height)
      ihdr = [ width, height, 8, 2, 0, 0, 0 ].pack("N2C5")
      "\x89PNG\r\n\x1A\n".b + [ 13 ].pack("N") + "IHDR" + ihdr + [ 0 ].pack("N")
    end

    def build_telegram(downloads: [])
      StubbedTelegram.new(
        agent: @agent,
        channel_config: { "token" => "fake", "typing_indicator" => false },
        downloads: downloads
      )
    end

    def photo_update(caption: nil)
      message = {
        "chat" => { "id" => 42, "type" => "private" },
        "from" => { "id" => 42, "username" => "tester" },
        "photo" => [
          { "file_id" => "small", "file_unique_id" => "u1", "file_size" => 1_000 },
          { "file_id" => "large", "file_unique_id" => "u2", "file_size" => 90_000 }
        ]
      }
      message["caption"] = caption if caption
      { "update_id" => 1, "message" => message }
    end

    def test_photo_with_caption_reaches_the_agent
      tg = build_telegram
      tg.send(:process_update, photo_update(caption: "ini bagian amplop"))

      assert_equal 1, tg.prompts.size
      prompt, session_id = tg.prompts.first
      assert_includes prompt, "ini bagian amplop"
      assert_includes prompt, "#{@image}"
      assert_includes prompt, "1864×1200"
      assert_equal "tg_42", session_id
    end

    def test_photo_without_caption_is_no_longer_dropped
      tg = build_telegram
      tg.send(:process_update, photo_update)

      assert_equal 1, tg.prompts.size
      assert_includes tg.prompts.first[0], @image
      refute_empty tg.sent
    end

    def test_plain_text_still_passes_through_unchanged
      tg = build_telegram
      update = { "update_id" => 2, "message" => {
        "chat" => { "id" => 42 }, "from" => { "id" => 42 }, "text" => "halo"
      } }
      tg.send(:process_update, update)

      assert_equal [ [ "halo", "tg_42" ] ], tg.prompts
    end

    def test_unsupported_media_gets_an_explicit_reply_instead_of_silence
      tg = build_telegram
      update = { "update_id" => 3, "message" => {
        "chat" => { "id" => 42 }, "from" => { "id" => 42 },
        "sticker" => { "file_id" => "s1", "emoji" => "🙂" }
      } }
      tg.send(:process_update, update)

      assert_empty tg.prompts
      assert_equal 1, tg.sent.size
      assert_includes tg.sent.first[1], "sticker"
    end

    def test_failed_download_still_passes_the_caption_to_the_agent
      tg = build_telegram
      tg.define_singleton_method(:download_attachment) { |*_args| nil }

      tg.send(:process_update, photo_update(caption: "lihat ini"))

      assert_equal 1, tg.prompts.size
      assert_includes tg.prompts.first[0], "lihat ini"
      assert_includes tg.prompts.first[0], "could not be downloaded"
    end

    def test_unauthorized_user_never_triggers_a_download
      tg = Channels::Telegram.new(
        agent: @agent,
        channel_config: { "token" => "fake", "allowed_user_ids" => [ 999 ] }
      )
      called = false
      tg.define_singleton_method(:download_attachment) { |*_args| called = true and nil }

      tg.send(:process_update, photo_update(caption: "hi"))

      refute called
    end

    def test_attachments_live_inside_the_workspace
      tg = build_telegram
      root = tg.send(:attachments_root)
      assert root.start_with?(@config.workspace), "#{root} must stay inside #{@config.workspace}"
    end

    def test_extract_attachments_picks_the_largest_photo
      tg = build_telegram
      attachments, unsupported = tg.send(:extract_attachments, photo_update["message"])

      assert_nil unsupported
      assert_equal 1, attachments.size
      assert_equal "large", attachments.first[:file_id]
      assert_equal :image, attachments.first[:kind]
    end

    def test_extract_attachments_marks_documents_by_mime_type
      tg = build_telegram
      attachments, = tg.send(:extract_attachments, {
        "document" => { "file_id" => "d1", "file_unique_id" => "u", "file_name" => "a.pdf",
                        "mime_type" => "application/pdf" }
      })

      assert_equal :file, attachments.first[:kind]
    end

    def test_attachment_filename_cannot_escape_the_directory
      tg = build_telegram
      name = tg.send(:attachment_filename, { name: "../../etc/passwd", unique_id: "u1" }, "photos/file_1.jpg")

      refute_includes name, "/"
      refute name.start_with?(".")
    end

    def test_attachment_filename_keeps_the_original_extension
      tg = build_telegram
      name = tg.send(:attachment_filename, { name: "capture.png", unique_id: "u1" }, "documents/file_1")

      assert name.end_with?(".png"), name
      assert_includes name, "capture-"
    end

    def test_attachments_can_be_disabled
      tg = Channels::Telegram.new(
        agent: @agent,
        channel_config: { "token" => "fake", "attachments" => false, "typing_indicator" => false }
      )
      attachments, = tg.send(:extract_attachments, photo_update["message"])

      assert_empty attachments
    end
  end

  # A reply carries the quoted message in `reply_to_message` (or the highlighted
  # excerpt in `quote`), never in `text`. Without this the agent only sees the
  # new message and loses what the user was pointing at.
  class TestTelegramReplyContext < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
      @config = isolated_config(@tmpdir, name: "test_reply")
      @agent = Rubot::Agent.new(config: @config, session_id: "test_reply", tools: Rubot::Tools::Registry.new)
    end

    def teardown
      FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
    end

    def build_telegram(downloads: [])
      StubbedTelegram.new(
        agent: @agent,
        channel_config: { "token" => "fake", "typing_indicator" => false },
        downloads: downloads
      )
    end

    def reply_update(quoted: "harga naik 12% bulan ini", body: "ini artinya apa?",
                     author: { "id" => 7, "username" => "alice" }, thread_id: nil, extra: {})
      reply = { "message_id" => 99, "from" => author }
      reply["text"] = quoted if quoted
      message = {
        "chat" => { "id" => 42 },
        "from" => { "id" => 42, "username" => "tester" },
        "reply_to_message" => reply
      }
      message["text"] = body if body
      message["message_thread_id"] = thread_id if thread_id
      message.merge!(extra)
      { "update_id" => 10, "message" => message }
    end

    def test_the_quoted_message_reaches_the_agent
      tg = build_telegram
      tg.send(:process_update, reply_update)

      assert_equal 1, tg.prompts.size
      prompt = tg.prompts.first[0]
      assert_includes prompt, "harga naik 12% bulan ini"
      assert_includes prompt, "ini artinya apa?"
      assert_includes prompt, "@alice"
    end

    def test_the_users_own_text_stays_first
      tg = build_telegram
      tg.send(:process_update, reply_update)

      prompt = tg.prompts.first[0]
      assert prompt.start_with?("ini artinya apa?"), prompt
    end

    def test_the_highlighted_excerpt_wins_over_the_whole_message
      tg = build_telegram
      update = reply_update(extra: { "quote" => { "text" => "harga naik 12%" } })
      update["message"]["reply_to_message"]["text"] = "harga naik 12% bulan ini, sisanya stabil"

      tg.send(:process_update, update)

      prompt = tg.prompts.first[0]
      assert_includes prompt, "harga naik 12%"
      refute_includes prompt, "sisanya stabil"
    end

    def test_a_reply_to_the_bot_is_labelled_as_the_assistant
      tg = build_telegram
      tg.instance_variable_set(:@bot_username, "mybot")
      update = reply_update(quoted: "Berikut ringkasannya.",
                            author: { "id" => 1, "username" => "MyBot", "is_bot" => true })

      tg.send(:process_update, update)

      assert_includes tg.prompts.first[0], "your earlier message"
    end

    def test_a_reply_to_a_member_without_a_username_uses_their_name
      tg = build_telegram
      update = reply_update(author: { "id" => 7, "first_name" => "Budi" })

      tg.send(:process_update, update)

      assert_includes tg.prompts.first[0], "Budi"
    end

    def test_the_quote_survives_a_reply_that_crosses_topics
      tg = build_telegram
      tg.send(:process_update, reply_update(thread_id: 7))

      prompt, session_id = tg.prompts.first
      assert_equal "tg_42_7", session_id
      assert_includes prompt, "harga naik 12% bulan ini"
    end

    def test_a_media_reply_target_is_downloaded_and_described
      shot = File.join(@config.workspace, "attachments", "tg_42", "target.png")
      FileUtils.mkdir_p(File.dirname(shot))
      File.binwrite(shot, "\x89PNG\r\n\x1A\n".b)

      tg = build_telegram(downloads: [ shot ])
      update = reply_update(quoted: nil, extra: {})
      update["message"]["reply_to_message"]["photo"] = [
        { "file_id" => "p1", "file_unique_id" => "u9", "file_size" => 90_000 }
      ]

      tg.send(:process_update, update)

      prompt = tg.prompts.first[0]
      assert_includes prompt, shot
      assert_includes prompt, "ini artinya apa?"
    end

    def test_a_reply_to_an_unreadable_service_message_adds_nothing
      tg = build_telegram
      update = reply_update(quoted: nil, body: "halo")
      update["message"]["reply_to_message"] = { "message_id" => 99, "forum_topic_created" => { "name" => "x" } }

      tg.send(:process_update, update)

      assert_equal [ [ "halo", "tg_42" ] ], tg.prompts
    end

    def test_a_long_quote_is_truncated
      tg = build_telegram
      tg.send(:process_update, reply_update(quoted: "x" * 10_000))

      prompt = tg.prompts.first[0]
      assert_includes prompt, "(truncated)"
      assert_operator prompt.length, :<, 10_000
    end

    def test_reply_context_can_be_skipped_when_the_update_has_no_reply
      tg = build_telegram
      tg.send(:reply_context, { "text" => "halo" }, "tg_42", 42)

      assert_nil tg.send(:reply_context, { "text" => "halo" }, "tg_42", 42)
    end
  end

  # The per-topic persona wizard: forum_topic_created opens it, inline buttons
  # move between steps, and the system prompt arrives as ordinary chat text.
  class TestTelegramPersona < Minitest::Test
    class FakeCatalog
      attr_reader :entries

      def initialize(entries)
        @entries = entries
      end
    end

    class PersonaTelegram < Channels::Telegram
      class FakeSession
        attr_reader :personas

        def initialize
          @personas = []
        end

        def set_persona(persona)
          @personas << persona
          persona
        end
      end

      # Stands in for the SessionPool when a test needs the actor-mode cron
      # paths without booting Ractors.
      class FakeCronPool
        attr_reader :removals

        def initialize(dropped: 0, rooted: {})
          @dropped = dropped
          @rooted = rooted
          @removals = []
        end

        def remove_cron_jobs_for(chat_id:, thread_id: nil)
          @removals << [ chat_id, thread_id ]
          @dropped
        end

        def workspace_for_session(session_id)
          @rooted[session_id]
        end
      end

      attr_reader :sent, :keyboards, :deleted, :sessions, :answers

      def initialize(**kwargs)
        super
        @sent = []
        @keyboards = []
        @deleted = []
        @sessions = {}
        @answers = []
      end

      def session_for(session_id)
        @sessions[session_id] ||= FakeSession.new
      end

      def answer_callback_query(callback_id, text = nil)
        @answers << [ callback_id, text ]
        { "ok" => true }
      end

      private

      def send_message(chat_id, text, thread_id = nil)
        @sent << [ chat_id, text, thread_id ]
        true
      end

      def send_message_plain(chat_id, text, thread_id = nil)
        @sent << [ chat_id, text, thread_id ]
        true
      end

      def send_keyboard_message(chat_id, text, thread_id, keyboard)
        @keyboards << [ chat_id, text, thread_id, keyboard ]
        1_000 + @keyboards.size
      end

      def delete_message(chat_id, message_id, thread_id = nil)
        @deleted << [ chat_id, message_id, thread_id ]
      end
    end

    def setup
      @tmpdir = Dir.mktmpdir
      @config = isolated_config(@tmpdir, name: "persona-model")
      @config.data["model_presets"] = {
        "fast" => { "model" => "test-model", "temperature" => 0.2, "max_tokens" => 8192 },
        "deep" => { "model" => "deepseek-v4-pro", "temperature" => 0.1 }
      }
      @config.data["agents"]["defaults"]["model_preset"] = "fast"
      @config.save
      @agent = Rubot::Agent.new(
        config: @config,
        session_id: "persona",
        tools: Rubot::Tools::Registry.new
      )
      @tg = PersonaTelegram.new(
        agent: @agent,
        channel_config: { "token" => "fake", "typing_indicator" => false }
      )
    end

    def teardown
      FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
    end

    def topic_message(text: nil, thread_id: 7, chat_id: 42, created: false)
      message = {
        "chat" => { "id" => chat_id, "is_forum" => true },
        "from" => { "id" => chat_id, "username" => "tester" }
      }
      message["message_thread_id"] = thread_id unless thread_id.nil?
      message["text"] = text if text
      message["forum_topic_created"] = { "name" => "trading" } if created
      { "update_id" => 1, "message" => message }
    end

    def callback_update(data)
      {
        "update_id" => 2,
        "callback_query" => {
          "id" => "cb-1",
          "data" => data,
          "message" => { "message_id" => 500 }
        }
      }
    end

    def keyboard_data(keyboard)
      keyboard.flatten.map { |button| button["callback_data"] }
    end

    def last_keyboard
      @tg.keyboards.last[3]
    end

    def click(action)
      data = keyboard_data(last_keyboard).find { |value| value.end_with?(":#{action}") }
      refute_nil data, "expected a #{action} button in #{keyboard_data(last_keyboard).inspect}"
      @tg.send(:process_update, callback_update(data))
      data
    end

    def test_forum_topic_created_opens_the_preset_step
      @tg.send(:process_update, topic_message(created: true))

      assert_equal 1, @tg.keyboards.size
      _chat_id, text, thread_id, = @tg.keyboards.last
      assert_equal 7, thread_id
      assert_includes text, "Langkah 1/3"
      assert_includes text, "Pilih model preset"
      assert_includes text, "fast (primary)"

      data = keyboard_data(last_keyboard)
      assert data.any? { |value| value.end_with?(":preset:0") }, data.inspect
      assert data.any? { |value| value.end_with?(":preset:default") }, data.inspect
    end

    def test_forum_topic_created_is_ignored_when_a_persona_exists
      @tg.send(:persona_store).set(
        "42:7",
        Rubot::Persona.new(name: "trading", preset: "fast", system_prompt: "Halo")
      )

      @tg.send(:process_update, topic_message(created: true))

      assert_empty @tg.keyboards
    end

    def test_persona_wizard_happy_path_saves_and_applies_the_persona
      @tg.send(:process_update, topic_message(created: true))
      click("preset:0")

      assert_includes @tg.keyboards.last[1], "Langkah 2/3"

      @tg.send(:process_update, topic_message(text: "Kamu adalah asisten trading. Jawab singkat."))

      assert_includes @tg.keyboards.last[1], "Langkah 3/3"
      assert_includes @tg.keyboards.last[1], "Kamu adalah asisten trading."

      click("save")

      stored = @tg.send(:persona_store).get(42, 7)
      assert_equal "fast", stored.preset
      assert_nil stored.model
      assert_equal "Kamu adalah asisten trading. Jawab singkat.", stored.system_prompt
      assert_equal "topic-7", stored.name

      session = @tg.sessions["tg_42_7"]
      assert_equal "Kamu adalah asisten trading. Jawab singkat.", session.personas.last["system_prompt"]
      assert @tg.sent.any? { |_chat, text, _thread| text.include?("Persona disimpan") }
      assert_nil @tg.send(:wizard_for_topic, 42, 7)
    end

    # The usual setup once a specialist exists: point the topic at it instead
    # of retyping a prompt. The topic keeps its own session; the persona — and
    # so its memory — is shared.
    def test_a_topic_can_be_pointed_at_an_existing_persona
      @tg.send(:persona_store).set("trainer", Rubot::Persona.new(
        slug: "trainer", name: "Trainer", emoji: "🧪", system_prompt: "Kamu personal trainer."
      ))

      @tg.send(:process_update, topic_message(created: true))

      assert_includes @tg.keyboards.last[1], "Pakai persona yang sudah ada"
      assert keyboard_data(last_keyboard).any? { |value| value.end_with?(":use:0") }
      assert keyboard_data(last_keyboard).any? { |value| value.end_with?(":new") }

      click("use:0")

      stored = @tg.send(:persona_store).all["42:7"]
      assert_equal "trainer", stored.ref
      assert_equal "Trainer", @tg.send(:persona_store).get(42, 7).name

      session = @tg.sessions["tg_42_7"]
      assert_equal "Kamu personal trainer.", session.personas.last["system_prompt"]
      assert @tg.sent.any? { |_chat, text, _thread| text.include?("memakai persona") }
    end

    def test_a_topic_can_still_build_its_own_persona
      @tg.send(:persona_store).set("trainer", Rubot::Persona.new(slug: "trainer", name: "Trainer"))

      @tg.send(:process_update, topic_message(created: true))
      click("new")

      assert_includes @tg.keyboards.last[1], "Langkah 1/3"
      assert keyboard_data(last_keyboard).any? { |value| value.end_with?(":preset:0") }
    end

    def test_persona_show_names_the_borrowed_persona
      @tg.send(:persona_store).set("trainer", Rubot::Persona.new(
        slug: "trainer", name: "Trainer", emoji: "🧪"
      ))
      @tg.send(:persona_store).set("42:7", Rubot::Persona.new(ref: "trainer"))

      @tg.send(:process_update, topic_message(text: "/persona show"))

      text = @tg.sent.last[1]
      assert_includes text, "Memakai : Trainer (trainer)"
      assert_includes text, "dipakai bersama"
    end

    # A reminder written with a trainer's memory must not outlive the persona:
    # after a reset it would fire into a session that can no longer answer in
    # the same voice.
    def test_reset_drops_the_topics_reminders
      pool = PersonaTelegram::FakeCronPool.new(dropped: 2)
      @tg.instance_variable_set(:@pool, pool)
      @tg.send(:persona_store).set("42:7", Rubot::Persona.new(name: "trading"))

      @tg.send(:process_update, topic_message(text: "/persona reset"))

      assert_equal [ [ 42, 7 ] ], pool.removals
      assert_includes @tg.sent.last[1], "2 reminder"
    end

    def test_reset_without_reminders_says_nothing_extra
      @tg.send(:persona_store).set("42:7", Rubot::Persona.new(name: "trading"))

      @tg.send(:process_update, topic_message(text: "/persona reset"))

      refute_includes @tg.sent.last[1], "reminder"
    end

    # The cron tool must be told which directory the turn is running in, or a
    # reminder written here would be filed in the install's own store.
    def test_a_message_tells_the_cron_tool_its_workspace
      persona_dir = File.join(@tmpdir, "personas", "trainer")
      pool = PersonaTelegram::FakeCronPool.new(rooted: { "tg_42_7" => persona_dir })
      @tg.instance_variable_set(:@pool, pool)
      # The real session hands out its own tool registry; the fake session the
      # wizard tests use has none.
      @tg.define_singleton_method(:session_for) { |_session_id| @agent }

      cron_tool = @agent.tools.get("cron")
      refute_nil cron_tool, "the agent needs a cron tool for this test"

      @tg.send(:bind_delivery_context, "tg_42_7", 42, 7)

      assert_equal persona_dir, cron_tool.delivery_context[:workspace]
      assert_equal 42, cron_tool.delivery_context[:chat_id]
      assert_equal 7, cron_tool.delivery_context[:thread_id]
    end

    def test_a_topic_without_a_persona_files_reminders_in_the_main_workspace
      pool = PersonaTelegram::FakeCronPool.new(rooted: {})
      @tg.instance_variable_set(:@pool, pool)
      @tg.define_singleton_method(:session_for) { |_session_id| @agent }

      cron_tool = @agent.tools.get("cron")
      @tg.send(:bind_delivery_context, "tg_42_7", 42, 7)

      assert_equal @config.workspace, cron_tool.delivery_context[:workspace]
    end

    def test_prompt_can_be_skipped_to_use_the_default
      @tg.send(:process_update, topic_message(created: true))
      click("preset:0")
      click("prompt_default")

      assert_includes @tg.keyboards.last[1], "Prompt: (default)"
      click("save")

      stored = @tg.send(:persona_store).get(42, 7)
      assert_equal "fast", stored.preset
      assert_nil stored.system_prompt
    end

    def test_persona_show_lists_the_active_persona
      @tg.send(:persona_store).set(
        "42:7",
        Rubot::Persona.new(name: "trading", preset: "fast", system_prompt: "Jawab singkat.")
      )

      @tg.send(:process_update, topic_message(text: "/persona show"))

      text = @tg.sent.last[1]
      assert_includes text, "Persona topic ini"
      assert_includes text, "fast"
      assert_includes text, "test-model"
      assert_includes text, "Jawab singkat."
    end

    def test_persona_reset_removes_it_and_clears_the_session
      @tg.send(:persona_store).set(
        "42:7",
        Rubot::Persona.new(name: "trading", preset: "fast", system_prompt: "Jawab singkat.")
      )

      @tg.send(:process_update, topic_message(text: "/persona reset"))

      assert_nil @tg.send(:persona_store).get(42, 7)
      assert_equal [ nil ], @tg.sessions["tg_42_7"].personas
      assert_includes @tg.sent.last[1], "dihapus"
    end

    def test_cancel_stops_an_active_wizard
      @tg.send(:process_update, topic_message(created: true))
      refute_nil @tg.send(:wizard_for_topic, 42, 7)

      @tg.send(:process_update, topic_message(text: "/cancel"))

      assert_nil @tg.send(:wizard_for_topic, 42, 7)
      assert_includes @tg.sent.last[1], "dibatalkan"
      refute_empty @tg.deleted
    end

    def test_cancel_without_a_wizard_is_harmless
      @tg.send(:process_update, topic_message(text: "/cancel"))

      assert_includes @tg.sent.last[1], "Tidak ada setup"
    end

    def test_persona_in_the_general_topic_uses_the_default
      @tg.send(:process_update, topic_message(text: "/persona", thread_id: nil))

      assert_empty @tg.keyboards
      assert_includes @tg.sent.last[1], "General"
    end

    def test_persona_command_with_bot_suffix_is_recognized
      @tg.send(:process_update, topic_message(text: "/persona@MyBot"))

      assert_equal 1, @tg.keyboards.size
    end

    def test_first_message_in_a_new_topic_opens_the_wizard_as_fallback
      @tg.send(:maybe_start_persona_wizard_for_new_topic, 42, 7)

      assert_equal 1, @tg.keyboards.size
      assert_includes @tg.keyboards.last[1], "Langkah 1/3"
    end

    def test_fallback_skips_topics_that_already_have_a_session
      # Sessions live next to config.yml, not in the workspace: the guard has
      # to look where they actually are, or every used topic looks new.
      path = File.join(@config.sessions_dir, "tg_42_7.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{}")

      @tg.send(:maybe_start_persona_wizard_for_new_topic, 42, 7)

      assert_empty @tg.keyboards
    end

    def test_help_mentions_persona_commands
      result = @tg.before_process("/help")

      assert_includes result[1], "/persona"
      assert_includes result[1], "/cancel"
    end

    def catalog_entries
      [
        { "id" => "test-model", "name" => "Test Model" },
        { "id" => "deepseek-v4-pro", "name" => "DeepSeek V4 Pro" },
        { "id" => "glm-5.3", "name" => "GLM-5.3" }
      ]
    end

    def use_fake_catalog!
      @tg.instance_variable_set(:@model_catalog, FakeCatalog.new(catalog_entries))
    end

    def test_preset_picker_lists_the_configured_presets
      @tg.send(:process_update, topic_message(created: true))

      labels = @tg.keyboards.last[3].flatten.map { |button| button["text"] }
      assert_includes labels, "fast ★"
      assert_includes labels, "deep"
      assert_includes @tg.keyboards.last[1], "fast (primary)"
      assert_includes @tg.keyboards.last[1], "deepseek-v4-pro"
    end

    def test_selecting_a_preset_stores_the_preset_name
      @tg.send(:process_update, topic_message(created: true))
      click("preset:1")
      @tg.send(:process_update, topic_message(text: "Kamu adalah asisten trading."))

      assert_includes @tg.keyboards.last[1], "deep (`deepseek-v4-pro`)"

      click("save")

      stored = @tg.send(:persona_store).get(42, 7)
      assert_equal "deep", stored.preset
      assert_equal "deep", @tg.sessions["tg_42_7"].personas.last["preset"]
    end

    def test_models_command_lists_presets
      result = @tg.before_process("/models")

      assert_includes result[1], "Model Presets"
      assert_includes result[1], "fast ★"
      assert_includes result[1], "deep"
    end

    def test_model_command_switches_the_session_preset
      result = @tg.before_process("/model deep")

      assert_includes result[1], "preset **deep**"
      assert_equal "deep", @agent.session.model_preset
      assert_equal "deepseek-v4-pro", @agent.active_model_name
    end

    def test_model_command_rejects_unknown_preset
      result = @tg.before_process("/model nope")

      assert_includes result[1], "tidak ada"
      assert_equal "fast", @agent.active_preset_name
    end

    def test_preset_set_creates_a_preset_and_persists_it
      use_fake_catalog!

      result = @tg.before_process("/preset set coding glm-5.3 temperature=0.15 max_tokens=4096")

      assert_includes result[1], "Preset **coding** disimpan"
      preset = @config.model_preset("coding")
      assert_equal "glm-5.3", preset["model"]
      assert_equal 0.15, preset["temperature"]
      assert_equal 4096, preset["max_tokens"]

      raw = YAML.safe_load(File.read(@config.config_path))
      assert_equal "glm-5.3", raw.dig("model_presets", "coding", "model")
    end

    def test_preset_default_changes_the_default_for_new_sessions
      result = @tg.before_process("/preset default deep")

      assert_includes result[1], "sesi baru"
      assert_equal "deep", @config.primary_model_preset_name

      new_agent = Rubot::Agent.new(
        config: @config,
        session_id: "new-session",
        tools: Rubot::Tools::Registry.new
      )
      assert_equal "deepseek-v4-pro", new_agent.active_model_name
    end

    def test_preset_delete_removes_it
      result = @tg.before_process("/preset delete deep")

      assert_includes result[1], "dihapus"
      assert_nil @config.model_preset("deep")
    end

    def test_preset_models_lists_the_provider_catalog
      use_fake_catalog!

      result = @tg.before_process("/preset models")

      assert_includes result[1], "Model tersedia"
      assert_includes result[1], "deepseek-v4-pro"
      assert_includes result[1], "glm-5.3"
    end
  end
end

class TestChannelLearningHook < Minitest::Test
  # Minimal handle that records the order of delivery and learning.
  class RecordingHandle
    attr_reader :events

    def initialize(events)
      @events = events
    end

    def process(_message, **_callbacks)
      @events << :answered
      "answer"
    end

    def flush_learning
      @events << :learned
    end
  end

  class HookChannel < Rubot::Channel
    def initialize(handle, events)
      @handle = handle
      @events = events
      super()
    end

    def name
      "hook"
    end

    def after_process(_message, response)
      @events << :delivered
      response
    end

    def session_for(_session_id)
      @handle
    end

    def start; end
    def stop; end
  end

  def test_learning_runs_after_the_answer_is_delivered
    events = []
    handle = RecordingHandle.new(events)
    channel = HookChannel.new(handle, events)

    response = channel.process_message("hello there")

    assert_equal "answer", response
    assert_equal [ :answered, :delivered, :learned ], events
  end

  # A channel that can announce a later change itself does not make the reader
  # wait for the naming request: the turn ends with the answer, and the queue
  # reports back when it is done.
  class DeferringChannel < HookChannel
    def defer_learning?
      true
    end

    def after_learning(session_id)
      @events << [ :learned_later, session_id ]
    end
  end

  def test_a_deferring_channel_ends_the_turn_before_learning_runs
    events = []
    handle = RecordingHandle.new(events)
    handle.define_singleton_method(:flush_learning) do
      sleep 0.05
      events << :learned
    end
    channel = DeferringChannel.new(handle, events)

    assert_equal "answer", channel.process_message("hello there")
    assert_equal [ :answered, :delivered ], events,
                 "the turn must be finished before the naming request runs"

    channel.drain_learning
    assert_equal [ :answered, :delivered, :learned, [ :learned_later, "default" ] ], events
  ensure
    channel&.stop_learning_worker
  end

  def test_learning_that_fails_still_tells_the_channel_it_is_done
    events = []
    handle = RecordingHandle.new(events)
    handle.define_singleton_method(:flush_learning) { raise "provider said no" }
    channel = DeferringChannel.new(handle, events)

    channel.process_message("hello there")
    channel.drain_learning

    assert_equal [ :answered, :delivered, [ :learned_later, "default" ] ], events
  ensure
    channel&.stop_learning_worker
  end
end

# /stop routing: the channel must be able to reach the turn that is running.
class TestChannelCancellation < Minitest::Test
  class StoppableHandle
    attr_reader :started, :cancelled

    def initialize
      @started = Queue.new
      @done = Queue.new
      @cancelled = false
    end

    def process(_message, **_callbacks)
      @started << true
      @done.pop
      "stopped"
    end

    def cancel!
      @cancelled = true
      @done << true
      true
    end

    def flush_learning
      nil
    end
  end

  class CancelChannel < Rubot::Channel
    def initialize(handle)
      @handle = handle
      super()
    end

    def session_for(_session_id)
      @handle
    end

    def start; end
    def stop; end
  end

  def test_cancel_session_reaches_the_running_turn
    handle = StoppableHandle.new
    channel = CancelChannel.new(handle)
    response = nil

    runner = Thread.new { response = channel.process_message("do something long") }
    handle.started.pop

    assert channel.session_running?("default")
    assert channel.cancel_session("default")
    assert runner.join(5)

    assert_equal "stopped", response
    assert handle.cancelled
    refute channel.session_running?("default")
  end

  def test_cancel_session_without_a_running_turn_returns_false
    channel = CancelChannel.new(StoppableHandle.new)

    refute channel.cancel_session("default")
  end
end
