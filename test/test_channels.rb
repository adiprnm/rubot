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
      @config = Rubot::Config.new
      @tools = Rubot::Tools::Registry.new
      @agent = Rubot::Agent.new(
        config: @config,
        session_id: "test_channel",
        tools: @tools
      )
    end

    def teardown
      FileUtils.rm_rf(File.join(@config.workspace, "sessions"))
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
        return [:skip, "Handled!"] if message == "/cmd"
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

    def test_abstract_channel_raises
      channel = Channel.new(agent: @agent)
      assert_raises(NotImplementedError) { channel.start }
    end
  end

  class TestChannelRegistry < Minitest::Test
    def test_build_channel_list_from_hash_config
      data = {
        "channels" => {
          "repl" => { "stream" => true },
          "telegram" => { "token" => "test" },
        },
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
          "telegram" => { "enabled" => false },
        },
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
          "telegram" => { "enabled" => false },
        },
      }
      config = Rubot::Config.new
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

  class TestTelegramChannel < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
      @config = Rubot::Config.new
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
      FileUtils.rm_rf(File.join(@config.workspace, "sessions"))
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
      assert_includes result[1], "Model"
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
      %w[/new /info /models /skills /memory /soul /agents /cron /help /start].each do |cmd|
        assert_includes result[1], cmd, "help text should mention #{cmd}"
      end
    end
  end
end
