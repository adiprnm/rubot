# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  # The Telegram surface above the base: the live status card, steering, inbound media and quoting.
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
      assert_includes result[1], "Nothing to compact yet"

      indonesian = Rubot::I18n.with_locale("id") { @tg.before_process("/compact") }
      assert_includes indonesian[1], "Belum ada yang perlu diringkas"
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

      @tg.register_bot_commands

      assert_includes scopes, "default"
      assert_includes scopes, "all_private_chats"
      assert_includes scopes, "all_group_chats", "groups need their own scope in some clients"
      assert_includes commands.first, "stop"
    end

    def test_stop_without_a_running_task_reports_nothing_to_stop
      sent = []
      @tg.define_singleton_method(:send_message) { |_chat, text, _thread| sent << text }

      @tg.handle_stop_command(42, nil)

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
      @tg.track_running_session("tg_42", handle)

      @tg.handle_stop_command(42, nil)

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

      @tg.cancel_pending_confirmations(42, nil)

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

      @tg.send_narration(42, 7, "  Let me check the structure first.  ")

      assert_equal [ [ 42, "Let me check the structure first.", 7 ] ], sent
    end

    def test_send_narration_ignores_blank_text
      sent = []
      @tg.define_singleton_method(:send_message) { |*_args| sent << :sent }

      @tg.send_narration(42, nil, "   ")

      assert_empty sent
    end

    def test_send_narration_can_be_disabled
      tg = Rubot::Channels::Telegram.new(
        agent: @agent,
        channel_config: { "token" => "fake", "narration" => false }
      )
      sent = []
      tg.define_singleton_method(:send_message) { |*_args| sent << :sent }

      tg.send_narration(42, nil, "hello")

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

      @tg.send_narration(42, 7, "Perintah tadi kena guard, gue pecah jadi yang aman.")

      assert_equal [
        [ :delete, 42, "sent-1" ],
        [ :send, 42, "Perintah tadi kena guard, gue pecah jadi yang aman.", 7 ]
      ], events
    end

    def test_narration_keeps_the_tool_step_count_so_the_next_card_continues
      seed_status_message(42, 7, "sent-1")
      status_key = @tg.status_key(42, 7)
      @tg.instance_variable_get(:@tool_counts)[status_key] = 3
      @tg.define_singleton_method(:delete_message) { |*_args| true }
      @tg.define_singleton_method(:send_message) { |*_args| true }

      @tg.send_narration(42, 7, "Checking the next file.")

      assert_equal 3, @tg.instance_variable_get(:@tool_counts)[status_key]
    end

    def test_clear_status_message_resets_the_step_count_for_the_next_request
      seed_status_message(42, 7, "sent-1")
      status_key = @tg.status_key(42, 7)
      @tg.instance_variable_get(:@tool_counts)[status_key] = 3
      @tg.define_singleton_method(:delete_message) { |*_args| true }

      @tg.clear_status_message(42, 7)

      assert_nil @tg.instance_variable_get(:@tool_counts)[status_key]
    end

    # --- Live status card ---------------------------------------------------

    # The card says only what is true: which tool, which step, how long. No
    # "Still working" prose, because at that moment nothing is running.
    def test_status_card_shows_literal_state_without_prose
      texts = capture_status_texts

      @tg.notify_tool_started(42, 7, "shell_exec", { "command" => "bundle exec rspec" })

      assert_equal 1, texts.size
      assert_includes texts[0], "💻 `shell_exec` · step 1 · 0s"
      assert_includes texts[0], "Running the tests"
      refute_includes texts[0], "Running tool"
      refute_includes texts[0], "Still working"
    end

    # A finished round means no tool is running, so the card marks the step done
    # and offers the one escape hatch the user has while waiting.
    def test_finished_round_marks_the_step_done_and_hints_stop_once
      texts = capture_status_texts

      @tg.notify_tool_started(42, 7, "file_ops", { "operation" => "read", "path" => "lib/rubot/agent.rb" })
      @tg.notify_progress(42, 7, 2)
      refute_includes texts.last, "/stop", "two rounds is not yet worth a stop hint"

      @tg.notify_progress(42, 7, 3)
      assert_includes texts.last, "✓"
      assert_equal 1, texts.last.scan("/stop").size

      @tg.notify_progress(42, 7, 9)
      assert_equal 1, texts.last.scan("/stop").size, "the hint must not repeat"
      refute_includes texts.last, "round", "the round counter stays internal"
    end

    def test_status_card_shows_running_subagents
      texts = capture_status_texts

      @tg.notify_tool_started(42, 7, "shell_exec", { "command" => "ls" })
      @tg.notify_subagent(42, 7, { run_id: "r1", agent: "writer", phase: "started", detail: "write a poem" })
      @tg.notify_subagent(42, 7, { run_id: "r2", agent: "researcher", phase: "tool", detail: "search docs" })

      card = texts.last
      assert_includes card, "2 subagent aktif"
      assert_includes card, "writer"
      assert_includes card, "researcher"
      assert_includes card, "search docs"

      @tg.notify_subagent(42, 7, { run_id: "r1", agent: "writer", phase: "done", detail: "3s" })
      assert_includes texts.last, "1 subagent aktif"
      assert_includes texts.last, "✓ writer"
    end

    def test_progress_without_a_tool_card_does_nothing
      texts = capture_status_texts

      @tg.notify_progress(42, 7, 5)

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

      @tg.update_or_send_status(42, 7, "step 1")
      @tg.update_or_send_status(42, 7, "step 2")
      assert_equal [ :sent ], events, "an edit inside the interval is dropped"

      clock = 1.5
      @tg.update_or_send_status(42, 7, "step 2")
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

      @tg.update_or_send_status(42, 7, "step 1")
      clock = 10.0
      @tg.update_or_send_status(42, 7, "step 1")

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

      assert_equal :error, @tg.post_edit(42, "sent-1", "hi", "HTML")
      assert_equal 1, calls
      assert_operator @tg.flood_remaining(42), :>, 0
    end

    def test_a_flood_window_silences_sends_and_edits_for_that_chat
      sends = 0
      @tg.define_singleton_method(:http_post) do |_url, _req|
        sends += 1
        { "ok" => false, "error_code" => 429, "description" => "Too Many Requests",
          "parameters" => { "retry_after" => 17 } }
      end

      @tg.post_edit(42, "sent-1", "hi", "HTML")
      assert_equal :error, @tg.deliver(42, "hello", nil, parse_mode: nil)
      assert_equal :error, @tg.post_edit(42, "sent-1", "again", "HTML")
      assert_equal 1, sends, "nothing reaches the API while the gate is closed"

      # A different chat is unaffected: the limit is per chat.
      refute_operator @tg.flood_remaining(99), :>, 0
    end

    def test_format_elapsed
      assert_equal "0s", @tg.format_elapsed(0)
      assert_equal "59s", @tg.format_elapsed(59.9)
      assert_equal "1m 05s", @tg.format_elapsed(65)
      assert_equal "1h 02m", @tg.format_elapsed(3720)
    end

    # Register a status message the way update_or_send_status would, without
    # touching the Telegram API.
    def seed_status_message(chat_id, thread_id, message_id)
      key = @tg.status_key(chat_id, thread_id)
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

  # A fired job lands on whichever channel wrote it, and a loop_tick job can
  # only be honoured where a loop can iterate. Telegram has no session pool and
  # no worktree, so it says so in one line instead of crashing the delivery.
  class TestTelegramCronFire < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
      @config = isolated_config(@tmpdir, name: "test_cron_fire")
      @agent = Rubot::Agent.new(config: @config, session_id: "test_cron_fire",
                                tools: Rubot::Tools::Registry.new)
      @tg = StubbedTelegram.new(
        agent: @agent,
        channel_config: { "token" => "fake", "typing_indicator" => false }
      )
    end

    def teardown
      FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
    end

    def test_a_loop_tick_job_says_where_the_loop_can_be_resumed
      @tg.send(:cron_fire_callback,
               mode: "loop_tick", job_id: "job1", loop_id: "impl-1", target_chat_id: 42,
               result: { success: true, loop_id: "impl-1" })

      assert_equal 1, @tg.sent.size, "one short message, not a silent drop"
      chat_id, text, = @tg.sent.first
      assert_equal 42, chat_id, "it answers in the chat that asked for the job"
      assert_includes text, "impl-1", "the reader has to know which loop it was"
      assert_includes text, "web channel"
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
      @tg.track_running_session("tg_42", handle)

      @tg.process_update(text_update("pakai folder lain"))

      assert_equal [ "pakai folder lain" ], handle.steered
      assert_empty @tg.prompts, "a steered message does not start its own turn"
      assert_includes @tg.sent.last[1], "Diteruskan ke tugas yang sedang berjalan."
    end

    def test_a_steered_message_in_a_topic_uses_the_topic_session
      handle = SteeringHandle.new
      @tg.track_running_session("tg_42_7", handle)

      @tg.process_update(text_update("pakai folder lain", thread_id: 7))

      assert_equal [ "pakai folder lain" ], handle.steered
      assert_empty @tg.prompts
    end

    def test_a_command_while_the_session_runs_is_not_steered
      handle = SteeringHandle.new
      @tg.track_running_session("tg_42", handle)

      @tg.process_update(text_update("/help"))

      assert_empty handle.steered
      assert_equal [ [ "/help", "tg_42" ] ], @tg.prompts
    end

    def test_a_reply_quote_rides_along_with_the_steer
      handle = SteeringHandle.new
      @tg.track_running_session("tg_42", handle)

      update = text_update("yang ini maksudnya?")
      update["message"]["reply_to_message"] = {
        "message_id" => 9,
        "from" => { "id" => 7, "username" => "alice" },
        "text" => "harga naik 12% bulan ini"
      }
      @tg.process_update(update)

      steer = handle.steered.first
      assert steer.start_with?("yang ini maksudnya?"), steer
      assert_includes steer, "harga naik 12% bulan ini"
    end

    def test_a_media_message_while_the_session_runs_queues_its_own_turn
      handle = SteeringHandle.new
      @tg.track_running_session("tg_42", handle)
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
      @tg.process_update(update)

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
      tg.process_update(photo_update(caption: "ini bagian amplop"))

      assert_equal 1, tg.prompts.size
      prompt, session_id = tg.prompts.first
      assert_includes prompt, "ini bagian amplop"
      assert_includes prompt, "#{@image}"
      assert_includes prompt, "1864×1200"
      assert_equal "tg_42", session_id
    end

    def test_photo_without_caption_is_no_longer_dropped
      tg = build_telegram
      tg.process_update(photo_update)

      assert_equal 1, tg.prompts.size
      assert_includes tg.prompts.first[0], @image
      refute_empty tg.sent
    end

    def test_plain_text_still_passes_through_unchanged
      tg = build_telegram
      update = { "update_id" => 2, "message" => {
        "chat" => { "id" => 42 }, "from" => { "id" => 42 }, "text" => "halo"
      } }
      tg.process_update(update)

      assert_equal [ [ "halo", "tg_42" ] ], tg.prompts
    end

    def test_unsupported_media_gets_an_explicit_reply_instead_of_silence
      tg = build_telegram
      update = { "update_id" => 3, "message" => {
        "chat" => { "id" => 42 }, "from" => { "id" => 42 },
        "sticker" => { "file_id" => "s1", "emoji" => "🙂" }
      } }
      tg.process_update(update)

      assert_empty tg.prompts
      assert_equal 1, tg.sent.size
      assert_includes tg.sent.first[1], "sticker"
    end

    def test_failed_download_still_passes_the_caption_to_the_agent
      tg = build_telegram
      tg.define_singleton_method(:download_attachment) { |*_args| nil }

      tg.process_update(photo_update(caption: "lihat ini"))

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

      tg.process_update(photo_update(caption: "hi"))

      refute called
    end

    def test_attachments_live_inside_the_workspace
      tg = build_telegram
      root = tg.attachments_root
      assert root.start_with?(@config.workspace), "#{root} must stay inside #{@config.workspace}"
    end

    def test_extract_attachments_picks_the_largest_photo
      tg = build_telegram
      attachments, unsupported = tg.extract_attachments(photo_update["message"])

      assert_nil unsupported
      assert_equal 1, attachments.size
      assert_equal "large", attachments.first[:file_id]
      assert_equal :image, attachments.first[:kind]
    end

    def test_extract_attachments_marks_documents_by_mime_type
      tg = build_telegram
      attachments, = tg.extract_attachments({
        "document" => { "file_id" => "d1", "file_unique_id" => "u", "file_name" => "a.pdf",
                        "mime_type" => "application/pdf" }
      })

      assert_equal :file, attachments.first[:kind]
    end

    def test_attachment_filename_cannot_escape_the_directory
      tg = build_telegram
      name = tg.attachment_filename({ name: "../../etc/passwd", unique_id: "u1" }, "photos/file_1.jpg")

      refute_includes name, "/"
      refute name.start_with?(".")
    end

    def test_attachment_filename_keeps_the_original_extension
      tg = build_telegram
      name = tg.attachment_filename({ name: "capture.png", unique_id: "u1" }, "documents/file_1")

      assert name.end_with?(".png"), name
      assert_includes name, "capture-"
    end

    def test_attachments_can_be_disabled
      tg = Channels::Telegram.new(
        agent: @agent,
        channel_config: { "token" => "fake", "attachments" => false, "typing_indicator" => false }
      )
      attachments, = tg.extract_attachments(photo_update["message"])

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
      tg.process_update(reply_update)

      assert_equal 1, tg.prompts.size
      prompt = tg.prompts.first[0]
      assert_includes prompt, "harga naik 12% bulan ini"
      assert_includes prompt, "ini artinya apa?"
      assert_includes prompt, "@alice"
    end

    def test_the_users_own_text_stays_first
      tg = build_telegram
      tg.process_update(reply_update)

      prompt = tg.prompts.first[0]
      assert prompt.start_with?("ini artinya apa?"), prompt
    end

    def test_the_highlighted_excerpt_wins_over_the_whole_message
      tg = build_telegram
      update = reply_update(extra: { "quote" => { "text" => "harga naik 12%" } })
      update["message"]["reply_to_message"]["text"] = "harga naik 12% bulan ini, sisanya stabil"

      tg.process_update(update)

      prompt = tg.prompts.first[0]
      assert_includes prompt, "harga naik 12%"
      refute_includes prompt, "sisanya stabil"
    end

    def test_a_reply_to_the_bot_is_labelled_as_the_assistant
      tg = build_telegram
      tg.instance_variable_set(:@bot_username, "mybot")
      update = reply_update(quoted: "Berikut ringkasannya.",
                            author: { "id" => 1, "username" => "MyBot", "is_bot" => true })

      tg.process_update(update)

      assert_includes tg.prompts.first[0], "your earlier message"
    end

    def test_a_reply_to_a_member_without_a_username_uses_their_name
      tg = build_telegram
      update = reply_update(author: { "id" => 7, "first_name" => "Budi" })

      tg.process_update(update)

      assert_includes tg.prompts.first[0], "Budi"
    end

    def test_the_quote_survives_a_reply_that_crosses_topics
      tg = build_telegram
      tg.process_update(reply_update(thread_id: 7))

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

      tg.process_update(update)

      prompt = tg.prompts.first[0]
      assert_includes prompt, shot
      assert_includes prompt, "ini artinya apa?"
    end

    def test_a_reply_to_an_unreadable_service_message_adds_nothing
      tg = build_telegram
      update = reply_update(quoted: nil, body: "halo")
      update["message"]["reply_to_message"] = { "message_id" => 99, "forum_topic_created" => { "name" => "x" } }

      tg.process_update(update)

      assert_equal [ [ "halo", "tg_42" ] ], tg.prompts
    end

    def test_a_long_quote_is_truncated
      tg = build_telegram
      tg.process_update(reply_update(quoted: "x" * 10_000))

      prompt = tg.prompts.first[0]
      assert_includes prompt, "(truncated)"
      assert_operator prompt.length, :<, 10_000
    end

    def test_reply_context_can_be_skipped_when_the_update_has_no_reply
      tg = build_telegram
      tg.reply_context({ "text" => "halo" }, "tg_42", 42)

      assert_nil tg.reply_context({ "text" => "halo" }, "tg_42", 42)
    end
  end

  # The per-topic persona wizard: forum_topic_created opens it, inline buttons
  # move between steps, and the system prompt arrives as ordinary chat text.
end
