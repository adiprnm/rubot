# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  # Per-topic personas in Telegram: the wizard, borrowing one, and what a topic keeps.
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
      @tg.process_update(callback_update(data))
      data
    end

    def test_forum_topic_created_opens_the_preset_step
      @tg.process_update(topic_message(created: true))

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
      @tg.persona_store.set(
        "42:7",
        Rubot::Persona.new(name: "trading", preset: "fast", system_prompt: "Halo")
      )

      @tg.process_update(topic_message(created: true))

      assert_empty @tg.keyboards
    end

    def test_persona_wizard_happy_path_saves_and_applies_the_persona
      @tg.process_update(topic_message(created: true))
      click("preset:0")

      assert_includes @tg.keyboards.last[1], "Langkah 2/3"

      @tg.process_update(topic_message(text: "Kamu adalah asisten trading. Jawab singkat."))

      assert_includes @tg.keyboards.last[1], "Langkah 3/3"
      assert_includes @tg.keyboards.last[1], "Kamu adalah asisten trading."

      click("save")

      stored = @tg.persona_store.get(42, 7)
      assert_equal "fast", stored.preset
      assert_nil stored.model
      assert_equal "Kamu adalah asisten trading. Jawab singkat.", stored.system_prompt
      assert_equal "topic-7", stored.name

      session = @tg.sessions["tg_42_7"]
      assert_equal "Kamu adalah asisten trading. Jawab singkat.", session.personas.last["system_prompt"]
      assert @tg.sent.any? { |_chat, text, _thread| text.include?("Persona disimpan") }
      assert_nil @tg.wizard_for_topic(42, 7)
    end

    # The usual setup once a specialist exists: point the topic at it instead
    # of retyping a prompt. The topic keeps its own session; the persona — and
    # so its memory — is shared.
    def test_a_topic_can_be_pointed_at_an_existing_persona
      @tg.persona_store.set("trainer", Rubot::Persona.new(
        slug: "trainer", name: "Trainer", emoji: "🧪", system_prompt: "Kamu personal trainer."
      ))

      @tg.process_update(topic_message(created: true))

      assert_includes @tg.keyboards.last[1], "Pakai persona yang sudah ada"
      assert keyboard_data(last_keyboard).any? { |value| value.end_with?(":use:0") }
      assert keyboard_data(last_keyboard).any? { |value| value.end_with?(":new") }

      click("use:0")

      stored = @tg.persona_store.all["42:7"]
      assert_equal "trainer", stored.ref
      assert_equal "Trainer", @tg.persona_store.get(42, 7).name

      session = @tg.sessions["tg_42_7"]
      assert_equal "Kamu personal trainer.", session.personas.last["system_prompt"]
      assert @tg.sent.any? { |_chat, text, _thread| text.include?("memakai persona") }
    end

    def test_a_topic_can_still_build_its_own_persona
      @tg.persona_store.set("trainer", Rubot::Persona.new(slug: "trainer", name: "Trainer"))

      @tg.process_update(topic_message(created: true))
      click("new")

      assert_includes @tg.keyboards.last[1], "Langkah 1/3"
      assert keyboard_data(last_keyboard).any? { |value| value.end_with?(":preset:0") }
    end

    def test_persona_show_names_the_borrowed_persona
      @tg.persona_store.set("trainer", Rubot::Persona.new(
        slug: "trainer", name: "Trainer", emoji: "🧪"
      ))
      @tg.persona_store.set("42:7", Rubot::Persona.new(ref: "trainer"))

      @tg.process_update(topic_message(text: "/persona show"))

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
      @tg.persona_store.set("42:7", Rubot::Persona.new(name: "trading"))

      @tg.process_update(topic_message(text: "/persona reset"))

      assert_equal [ [ 42, 7 ] ], pool.removals
      assert_includes @tg.sent.last[1], "2 reminder"
    end

    def test_reset_without_reminders_says_nothing_extra
      @tg.persona_store.set("42:7", Rubot::Persona.new(name: "trading"))

      @tg.process_update(topic_message(text: "/persona reset"))

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

      @tg.bind_delivery_context("tg_42_7", 42, 7)

      assert_equal persona_dir, cron_tool.delivery_context[:workspace]
      assert_equal 42, cron_tool.delivery_context[:chat_id]
      assert_equal 7, cron_tool.delivery_context[:thread_id]
    end

    def test_a_topic_without_a_persona_files_reminders_in_the_main_workspace
      pool = PersonaTelegram::FakeCronPool.new(rooted: {})
      @tg.instance_variable_set(:@pool, pool)
      @tg.define_singleton_method(:session_for) { |_session_id| @agent }

      cron_tool = @agent.tools.get("cron")
      @tg.bind_delivery_context("tg_42_7", 42, 7)

      assert_equal @config.workspace, cron_tool.delivery_context[:workspace]
    end

    def test_prompt_can_be_skipped_to_use_the_default
      @tg.process_update(topic_message(created: true))
      click("preset:0")
      click("prompt_default")

      assert_includes @tg.keyboards.last[1], "Prompt: (default)"
      click("save")

      stored = @tg.persona_store.get(42, 7)
      assert_equal "fast", stored.preset
      assert_nil stored.system_prompt
    end

    def test_persona_show_lists_the_active_persona
      @tg.persona_store.set(
        "42:7",
        Rubot::Persona.new(name: "trading", preset: "fast", system_prompt: "Jawab singkat.")
      )

      @tg.process_update(topic_message(text: "/persona show"))

      text = @tg.sent.last[1]
      assert_includes text, "Persona topic ini"
      assert_includes text, "fast"
      assert_includes text, "test-model"
      assert_includes text, "Jawab singkat."
    end

    def test_persona_reset_removes_it_and_clears_the_session
      @tg.persona_store.set(
        "42:7",
        Rubot::Persona.new(name: "trading", preset: "fast", system_prompt: "Jawab singkat.")
      )

      @tg.process_update(topic_message(text: "/persona reset"))

      assert_nil @tg.persona_store.get(42, 7)
      assert_equal [ nil ], @tg.sessions["tg_42_7"].personas
      assert_includes @tg.sent.last[1], "dihapus"
    end

    def test_cancel_stops_an_active_wizard
      @tg.process_update(topic_message(created: true))
      refute_nil @tg.wizard_for_topic(42, 7)

      @tg.process_update(topic_message(text: "/cancel"))

      assert_nil @tg.wizard_for_topic(42, 7)
      assert_includes @tg.sent.last[1], "dibatalkan"
      refute_empty @tg.deleted
    end

    def test_cancel_without_a_wizard_is_harmless
      @tg.process_update(topic_message(text: "/cancel"))

      assert_includes @tg.sent.last[1], "Tidak ada setup"
    end

    def test_persona_in_the_general_topic_uses_the_default
      @tg.process_update(topic_message(text: "/persona", thread_id: nil))

      assert_empty @tg.keyboards
      assert_includes @tg.sent.last[1], "General"
    end

    def test_persona_command_with_bot_suffix_is_recognized
      @tg.process_update(topic_message(text: "/persona@MyBot"))

      assert_equal 1, @tg.keyboards.size
    end

    def test_first_message_in_a_new_topic_opens_the_wizard_as_fallback
      @tg.maybe_start_persona_wizard_for_new_topic(42, 7)

      assert_equal 1, @tg.keyboards.size
      assert_includes @tg.keyboards.last[1], "Langkah 1/3"
    end

    def test_fallback_skips_topics_that_already_have_a_session
      # Sessions live next to config.yml, not in the workspace: the guard has
      # to look where they actually are, or every used topic looks new.
      path = File.join(@config.sessions_dir, "tg_42_7.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{}")

      @tg.maybe_start_persona_wizard_for_new_topic(42, 7)

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
      @tg.process_update(topic_message(created: true))

      labels = @tg.keyboards.last[3].flatten.map { |button| button["text"] }
      assert_includes labels, "fast ★"
      assert_includes labels, "deep"
      assert_includes @tg.keyboards.last[1], "fast (primary)"
      assert_includes @tg.keyboards.last[1], "deepseek-v4-pro"
    end

    def test_selecting_a_preset_stores_the_preset_name
      @tg.process_update(topic_message(created: true))
      click("preset:1")
      @tg.process_update(topic_message(text: "Kamu adalah asisten trading."))

      assert_includes @tg.keyboards.last[1], "deep (`deepseek-v4-pro`)"

      click("save")

      stored = @tg.persona_store.get(42, 7)
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

      assert_includes result[1], "does not exist"
      assert_equal "fast", @agent.active_preset_name
    end

    def test_preset_set_creates_a_preset_and_persists_it
      use_fake_catalog!

      result = @tg.before_process("/preset set coding glm-5.3 temperature=0.15 max_tokens=4096")

      assert_includes result[1], "Preset **coding** saved"
      preset = @config.model_preset("coding")
      assert_equal "glm-5.3", preset["model"]
      assert_equal 0.15, preset["temperature"]
      assert_equal 4096, preset["max_tokens"]

      raw = YAML.safe_load(File.read(@config.config_path))
      assert_equal "glm-5.3", raw.dig("model_presets", "coding", "model")
    end

    def test_preset_default_changes_the_default_for_new_sessions
      result = @tg.before_process("/preset default deep")

      assert_includes result[1], "new sessions"
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

      assert_includes result[1], "deleted"
      assert_nil @config.model_preset("deep")
    end

    def test_preset_models_lists_the_provider_catalog
      use_fake_catalog!

      result = @tg.before_process("/preset models")

      assert_includes result[1], "Models available"
      assert_includes result[1], "deepseek-v4-pro"
      assert_includes result[1], "glm-5.3"
    end

    # The preset card is drawn by the channel, so the switch has to reach it:
    # the same command in the other language answers in that language.
    def test_the_preset_card_follows_the_language
      Rubot::I18n.with_locale("id") do
        assert_includes @tg.before_process("/models")[1], "Preset Model"
        assert_includes @tg.before_process("/model nope")[1], "tidak ada"
        assert_includes @tg.before_process("/preset delete deep")[1], "dihapus"
      end
    end
  end
end
