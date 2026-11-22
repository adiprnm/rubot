# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  # The channel base: who may talk, what one message does, and the registry of channels.
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
end
