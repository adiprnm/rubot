# frozen_string_literal: true

require "test_helper"
require_relative "support/tui_support"

# The language switch, tested where a reader meets it: the config key that
# chooses it, the dictionary both languages are written in, and the rows the
# channels draw through the one translation function.
class TestI18n < Minitest::Test
  include Rubot::TuiSupport

  # What a compaction answers with, in the shape every channel reads: the same
  # numbers appear in the TUI rows, the Telegram card and the web note.
  COMPACT_RESULT = { summarized_messages: 12, kept_messages: 4,
                     context_before: 48_000, context_after: 9_000 }.freeze

  # A usage report shaped like the one /context reads: a window, a hit rate and
  # a price, so every line of the card is drawn.
  CONTEXT_REPORT = {
    model: "test-model", provider: "openai",
    context_used: 10_500, context_window: 128_000, context_percent: 8.2,
    messages: 12, requests: 3,
    prompt_tokens: 5_000, completion_tokens: 400, cached_tokens: 2_000,
    last_prompt_tokens: 1_000, cache_hit_rate: 0.5, last_re_read_tokens: 0,
    price_source: nil,
    cost: { "total" => 0.0123, "input" => 0.01, "cached_input" => 0.0002,
            "cache_creation" => 0.0, "output" => 0.0021, "saved" => 0.0 }
  }.freeze

  # The id /session reads off the agent's session, in the shape it reads it.
  OpenSession = Struct.new(:id)

  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yml")
  end

  def teardown
    Rubot::I18n.locale = Rubot::I18n::DEFAULT_LOCALE
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  # --- the config key ---------------------------------------------------

  # An install that never mentions the language speaks English: the default is
  # what every existing config file already means.
  def test_a_config_that_names_no_language_speaks_english
    assert_equal "en", config_with({}).bahasa
    assert_equal "en", Rubot::I18n.locale
    assert_equal "Thinking…", Rubot::I18n.t("thinking.live")
  end

  def test_bahasa_accepts_id_and_forgives_case_and_spaces
    assert_equal "id", config_with({ "bahasa" => "id" }).bahasa
    assert_equal "id", config_with({ "bahasa" => " ID " }).bahasa
  end

  # A persona-level default is where the rest of the agent settings live, so a
  # config that puts the language there is read the same way.
  def test_bahasa_is_read_from_agent_defaults_too
    config = config_with({ "agents" => { "defaults" => { "bahasa" => "id" } } })

    assert_equal "id", config.bahasa
  end

  # The error names the key, the value and what is accepted: a typo in the
  # config file must not turn into a half-English screen nobody can explain.
  def test_an_unknown_language_is_refused_with_the_choices
    config = config_with({ "bahasa" => "fr" })

    error = assert_raises(Rubot::I18n::UnknownLocale) { config.bahasa }

    assert_includes error.message, "bahasa"
    assert_includes error.message, "fr"
    assert_includes error.message, "en, id"
  end

  # --- the dictionary ---------------------------------------------------

  # Both halves of the dictionary are one translation set: a key added to one
  # language and not the other would leave a row blank in whichever language
  # the reader picked.
  def test_both_languages_define_the_same_keys
    assert_empty Rubot::I18n.missing_keys,
                 "keys only one language has: #{Rubot::I18n.missing_keys.inspect}"
    assert_equal Rubot::I18n.keys(locale: "en"), Rubot::I18n.keys(locale: "id")
  end

  def test_every_entry_is_a_non_empty_string
    %w[en id].each do |locale|
      Rubot::I18n.keys(locale: locale).each do |key|
        value = Rubot::I18n.t(key, locale: locale)

        assert_instance_of String, value, "#{locale}.#{key} is not a string"
        refute_empty value.strip, "#{locale}.#{key} is empty"
      end
    end
  end

  # A key nobody renders is a label nobody can read, and a sentence written in
  # place is a row that never switches. The two directions are checked against
  # the channel's own source: every `web.*` and `telegram.*` key has to be named
  # by the code that belongs to it, and the parity check above keeps the other
  # half honest. Telegram keeps its replies in the channel class and in the
  # modules beside it, so both are read.
  def test_every_channel_key_is_named_by_the_channel_that_renders_it
    {
      "web" => [ File.expand_path("../lib/rubot/web", __dir__) ],
      "telegram" => [ File.expand_path("../lib/rubot/channels/telegram.rb", __dir__),
                      File.expand_path("../lib/rubot/channels/telegram", __dir__) ]
    }.each do |namespace, roots|
      keys = Rubot::I18n.keys.select { |key| key.start_with?("#{namespace}.") }
      refute_empty keys, "#{namespace}.* is a namespace this build speaks"

      source = roots
        .flat_map { |root| File.directory?(root) ? Dir.glob(File.join(root, "**/*.{rb,erb}")) : [ root ] }
        .sort.map { |path| File.read(path) }.join("\n")
      unused = keys.reject { |key| source.include?(key) }

      assert_empty unused, "keys in #{namespace}.* that nothing renders: #{unused.inspect}"
    end
  end

  def test_an_unknown_key_raises_instead_of_drawing_the_key
    error = assert_raises(Rubot::I18n::MissingTranslation) { Rubot::I18n.t("tool.nope.nope") }

    assert_includes error.message, "tool.nope.nope"
  end

  def test_placeholders_are_filled_from_the_keyword_arguments
    assert_equal "Sending 3 files", Rubot::I18n.t("tool.send.many", count: 3)
    assert_equal "Mengirim 3 berkas", Rubot::I18n.t("tool.send.many", locale: "id", count: 3)
  end

  # --- switching --------------------------------------------------------

  # One assignment moves every row a person reads: the tool label, the thinking
  # block and the compaction line are the three the reader meets most.
  def test_switching_the_language_changes_the_tool_label_the_thinking_block_and_the_compaction_line
    english = spoken_in("en")
    indonesian = spoken_in("id")

    refute_equal english[:tool], indonesian[:tool], "the tool row follows the language"
    refute_equal english[:thinking], indonesian[:thinking], "the thinking block follows the language"
    refute_equal english[:compaction], indonesian[:compaction], "the compaction line follows the language"

    assert_equal "Ran a command in the terminal", english[:tool]
    assert_equal "Menjalankan perintah di terminal", indonesian[:tool]
    assert_equal "Thought for 5s", english[:thinking]
    assert_equal "Berpikir 5s", indonesian[:thinking]
    assert_equal "Summarized 12 messages · ~48000 → ~9000 tokens", english[:compaction]
    assert_equal "Meringkas 12 pesan · ~48000 → ~9000 token", indonesian[:compaction]
  end

  # A block runs in the other language and the old one comes back, so a page
  # that drew one language cannot leave the process speaking it.
  def test_with_locale_puts_the_previous_language_back
    assert_equal "Menjalankan perintah di terminal",
                 Rubot::I18n.with_locale("id") { Rubot::ToolCaption.caption("shell_exec", { "command" => "" }) }
    assert_equal "en", Rubot::I18n.locale
    assert_equal "Ran a command in the terminal",
                 Rubot::ToolCaption.caption("shell_exec", { "command" => "" })
  end

  # --- the rows a channel draws -----------------------------------------

  # A turn in the TUI, read the way a reader reads it: the live thinking label
  # while the model waits, the block that label collapses to once the answer
  # starts, and the footer that closes the turn. Drawn twice, once per
  # language, so the switch is checked at the row and not at the dictionary.
  def test_a_tui_turn_writes_its_thinking_block_and_footer_in_the_chosen_language
    english = tui_turn_in("en")
    indonesian = tui_turn_in("id")

    assert_includes english[:live], "Thinking…"
    assert_includes english[:rows], "Thought for 12s"
    assert_includes english[:rows], "Turn took 2m 25s (Total time 2m 25s · 1 turn)"

    assert_includes indonesian[:live], "Berpikir…"
    assert_includes indonesian[:rows], "Berpikir 12s"
    assert_includes indonesian[:rows], "2m 25s giliran (total waktu 2m 25s · 1 giliran)"

    refute_includes indonesian[:rows], "Turn took", "the footer is not half English"
    refute_includes english[:rows], "giliran", "the footer is not half Indonesian"
  end

  # The same two rows in the web timeline, plus the seam a compaction leaves:
  # the label a reader watches, the block it leaves behind, and its detail.
  def test_the_web_timeline_writes_its_thinking_label_and_compaction_seam_in_the_chosen_language
    live = { kind: :thinking, epoch: 1.0, started_at: 0.0, closed_at: nil, elapsed: nil }
    done = { kind: :thinking, epoch: 1.0, started_at: 0.0, closed_at: 2.0, elapsed: 12.0 }
    seam = { kind: :compaction, epoch: 1.0, before: 48_000, after: 9_000 }

    english = Rubot::Web::View.render("_timeline", items: [ live, done, seam ])
    indonesian = Rubot::I18n.with_locale("id") do
      Rubot::Web::View.render("_timeline", items: [ live, done, seam ])
    end

    assert_includes english, 'aria-label="Thinking…"'
    assert_includes english, "Thought for 12s"
    assert_includes english, "Context summarized."
    assert_includes english, ">48000 → 9000 tokens<"

    assert_includes indonesian, 'aria-label="Berpikir…"'
    assert_includes indonesian, "Berpikir 12s"
    assert_includes indonesian, "Konteks diringkas."
    assert_includes indonesian, ">48000 → 9000 token<"
  end

  # --- the commands a reader types ---------------------------------------

  # What five different slash commands answer with, in both languages. Each is
  # typed into the same REPL a reader types into and the screen is read back
  # row by row, so a command that writes its own wording fails here instead of
  # passing on the dictionary alone.
  TUI_COMMAND_ANSWERS = {
    "/help" => [ "Available commands:", "Perintah yang tersedia:" ],
    "/clear" => [ "Session cleared.", "Sesi dibersihkan." ],
    "/stop" => [ "Stop requested.", "Permintaan berhenti dikirim." ],
    "/session" => [ "Current session: s-1", "Sesi saat ini: s-1" ],
    "/compact" => [ "Compaction complete.", "Compact selesai." ]
  }.freeze

  def test_five_tui_commands_answer_in_the_chosen_language
    # Five commands, not one: a switch that reaches only the newest sentence
    # is the failure this guards against.
    assert_equal 5, TUI_COMMAND_ANSWERS.size

    TUI_COMMAND_ANSWERS.each do |command, (english_answer, indonesian_answer)|
      english = tui_command_output("en", command)
      indonesian = tui_command_output("id", command)

      assert_includes english, english_answer, "#{command} has to answer in English"
      assert_includes indonesian, indonesian_answer, "#{command} has to answer in Indonesian"
      refute_equal english, indonesian, "#{command} has to change language"
      refute_includes english, indonesian_answer, "#{command} leaves no Indonesian behind"
      refute_includes indonesian, english_answer, "#{command} leaves no English behind"
    end
  end

  # /help reads both of its tables from the dictionary row by row, not only
  # their two headers: a switch that stopped at the title would pass the test
  # above and still leave an English table on an Indonesian screen.
  def test_every_help_row_speaks_the_chosen_language
    english = tui_command_output("en", "/help")
    indonesian = tui_command_output("id", "/help")

    assert_includes english, "Clear conversation history"
    assert_includes indonesian, "Bersihkan riwayat percakapan"
    assert_includes english, "Complete a /command"
    assert_includes indonesian, "Lengkapi sebuah /command"
    refute_includes indonesian, "Clear conversation history"
    refute_includes english, "Bersihkan riwayat percakapan"
  end

  # A key nothing reads is a row that can rot. Every tui.* entry is either
  # spelled out in the command module or one row of the two /help tables,
  # which are looked up by the row a reader sees; a row with no entry fails
  # here instead of as an empty line on the screen.
  def test_every_tui_key_is_read_at_least_once
    source = File.read(File.expand_path("../lib/rubot/tui/commands.rb", __dir__))
    repl = build_repl

    help_rows = Rubot::TUI::COMMANDS.keys.map { |row| "help.cmd.#{repl.help_slug(row)}" } +
                Rubot::TUI::KEYS.keys.map { |row| "help.key.#{repl.help_slug(row)}" }
    keys = tui_keys.map { |path| path.join(".") }

    orphaned = (keys - help_rows).reject { |key| source.include?("tui.#{key}") }

    assert_empty orphaned, "every tui key is read at least once"
    assert_empty help_rows - keys, "every /help row has an entry"
  end

  # --- the compaction answer, drawn by each channel ---------------------

  # /compact typed into a real TUI: the lines come back through the same
  # say/say_text the reader sees, so a channel that writes its own wording
  # fails here instead of passing on the dictionary alone.
  def test_the_tui_compaction_answer_follows_the_language
    english = tui_compact_output("en")
    indonesian = tui_compact_output("id")

    assert_includes english, "Compaction complete."
    assert_includes english, "Summarized: 12 messages"
    assert_includes english, "Kept: 4 messages"
    assert_includes english, "Context: ~48000 → ~9000 tokens (estimated)"

    assert_includes indonesian, "Compact selesai."
    assert_includes indonesian, "Pesan diringkas: 12"
    assert_includes indonesian, "Pesan dipertahankan: 4"
    assert_includes indonesian, "Perkiraan konteks: ~48000 → ~9000 token"

    refute_equal english, indonesian
  end

  def test_the_tui_says_there_is_nothing_to_compact_in_both_languages
    assert_includes tui_compact_output("en", result: nil), "Nothing to compact yet"
    assert_includes tui_compact_output("id", result: nil), "Belum ada yang perlu diringkas"
  end

  # The Telegram card is assembled from the same keys, header included, so the
  # two languages differ there as well.
  def test_the_telegram_compaction_card_follows_the_language
    english = telegram_compact_reply("en")
    indonesian = telegram_compact_reply("id")

    assert_includes english, "Compaction complete"
    assert_includes english, "Summarized: 12"
    assert_includes english, "Context: ~48000 → ~9000 tokens (estimated)"

    assert_includes indonesian, "Compact selesai"
    assert_includes indonesian, "Pesan diringkas: 12"
    assert_includes indonesian, "Perkiraan konteks: ~48000 → ~9000 token"

    refute_equal english, indonesian
  end

  def test_the_telegram_empty_compaction_follows_the_language
    assert_includes telegram_compact_reply("en", result: nil), "Nothing to compact yet"
    assert_includes telegram_compact_reply("id", result: nil), "Belum ada yang perlu diringkas"
  end

  # The note under the compact button is a template, so this renders the
  # template: every state it can land in has to speak the chosen language.
  def test_the_web_compaction_note_follows_the_language
    %i[busy done error empty].each do |state|
      english = web_compact_note("en", state)
      indonesian = web_compact_note("id", state)

      refute_empty english.strip, "#{state} must say something"
      refute_equal english, indonesian, "the #{state} note must differ between en and id"
    end

    assert_includes web_compact_note("en", :done), "Conversation summarized"
    assert_includes web_compact_note("id", :done), "Percakapan berhasil diringkas"
    assert_includes web_compact_note("en", :error), "Summarizing failed"
    assert_includes web_compact_note("id", :error), "Ringkasan gagal"
    assert_includes web_compact_note("en", :busy), "A turn is still running"
    assert_includes web_compact_note("id", :busy), "Turn masih berjalan"
  end

  # --- the Telegram replies, drawn by the channel ----------------------

  # Six commands typed into a real Telegram handler, each read back the way the
  # chat shows it. Only the agent is a double; the wording is the channel's own,
  # so a reply written in place fails here instead of passing on the dictionary.
  def test_the_telegram_command_replies_follow_the_language
    english = telegram_surfaces("en")
    indonesian = telegram_surfaces("id")

    assert_includes english[:start], "Welcome to Rubot!"
    assert_includes indonesian[:start], "Selamat datang di Rubot!"

    assert_includes english[:new], "Started a new session"
    assert_includes indonesian[:new], "Sesi baru dimulai"

    assert_includes english[:stop], "Nothing is running."
    assert_includes indonesian[:stop], "Tidak ada yang sedang berjalan"

    assert_includes english[:help], "Built-in commands:"
    assert_includes indonesian[:help], "Perintah bawaan:"

    assert_includes english[:skills], "No skills installed."
    assert_includes indonesian[:skills], "Belum ada skill yang terpasang"

    assert_includes english[:auto], "Usage: /auto on|off (no argument flips it)."
    assert_includes indonesian[:auto], "Penggunaan: /auto on|off"

    english.each_key do |surface|
      refute_equal english[surface], indonesian[surface], "/#{surface} has to switch"
    end
  end

  # /context is the one reply that lands as a whole card: header, labels and the
  # price line all have to speak the chosen language.
  def test_the_telegram_context_card_follows_the_language
    english = telegram_context("en")
    indonesian = telegram_context("id")

    assert_includes english, "📊 **Context**"
    assert_includes english, "Messages: 12 | Requests: 3"
    assert_includes english, "Estimated cost: `$0.0123`"

    assert_includes indonesian, "📊 **Konteks Sesi**"
    assert_includes indonesian, "Pesan: 12 | Request: 3"
    assert_includes indonesian, "Estimasi biaya: `$0.0123`"

    refute_equal english, indonesian
  end

  # The live card while a request works, and the one-time /stop hint under it:
  # the step count and the hint are both reader-facing, so both switch.
  def test_the_telegram_status_card_follows_the_language
    english = telegram_status_card("en")
    indonesian = telegram_status_card("id")

    assert_includes english, "💻 `shell_exec`"
    assert_includes english, " · step 1 · 0s"
    assert_includes english, "⟡ 2 subagents running"
    assert_includes english, "/stop to stop it"

    assert_includes indonesian, " · langkah 1 · 0s"
    assert_includes indonesian, "⟡ 2 subagent aktif"
    assert_includes indonesian, "/stop untuk menghentikan"

    refute_includes english, "langkah", "the card is not half Indonesian"
    refute_includes indonesian, "step", "the card is not half English"
  end

  # A caption is not the command and not the argument: the sentence is built
  # from the intent table, the verbs and the durations too, so the switch has to
  # reach all of them. Six calls are drawn here, each by the branch that owns
  # it, through the same function the channels call.
  def test_a_caption_follows_the_language_through_the_whole_intent_table
    assert_equal [
      "Showing what is inside this directory",
      "Searching for \"Turn\" in the files",
      "Looking for files in lib",
      "Asking planner for help",
      "Reading lib/rubot/agent.rb",
      "Waiting 1m 30s"
    ], spoken_captions("en")
    assert_equal [
      "Menampilkan isi direktori ini",
      "Mencari \"Turn\" di dalam berkas",
      "Mencari berkas di lib",
      "Meminta bantuan planner",
      "Membaca isi lib/rubot/agent.rb",
      "Menunggu 1 menit 30 detik"
    ], spoken_captions("id")
  end

  private

  # One command typed into a real TUI, with only the agent's answers stubbed:
  # the rows are what say/say_text drew, read back row by row from the log
  # rather than the viewport, so a long answer is compared whole instead of
  # being cut at the height of the screen.
  def tui_command_output(locale, command, compact_result: COMPACT_RESULT)
    Rubot::I18n.with_locale(locale) do
      repl = build_repl
      stub_command_agent(repl.agent, compact_result: compact_result)

      repl.handle_command(command)
      repl.pump

      drawn_rows(repl).join("\n")
    end
  end

  # The text of every row the log holds, in the order it was drawn.
  def drawn_rows(repl)
    log = repl.instance_variable_get(:@log)
    log.instance_variable_get(:@entries).map { |segments| segments.map(&:first).join }
  end

  # The smallest agent these commands need: /clear, /stop and /compact answer
  # with a sentence of their own, and /session reads an id and a model name.
  def stub_command_agent(agent, compact_result: COMPACT_RESULT)
    agent.define_singleton_method(:clear_session) { nil }
    agent.define_singleton_method(:cancel!) { nil }
    agent.define_singleton_method(:compact_session) { compact_result }
    agent.define_singleton_method(:session) { OpenSession.new("s-1") }
    agent.define_singleton_method(:active_model_name) { "gpt-test" }
  end

  # Every leaf key under the tui namespace, as dotted paths.
  def tui_keys(prefix = [], hash = Rubot::I18n::DICTIONARY["en"]["tui"], out = [])
    hash.each do |key, value|
      value.is_a?(Hash) ? tui_keys(prefix + [ key ], value, out) : out << (prefix + [ key ])
    end
    out
  end

  # One /compact in a real TUI, with only the agent's answer stubbed: the rows
  # are what say/say_text drew, read back the way a terminal would show them.
  def tui_compact_output(locale, result: COMPACT_RESULT)
    tui_command_output(locale, "/compact", compact_result: result)
  end

  # The Telegram handler, reached the way an update reaches it. Only the agent
  # is a double; the card itself is the channel's own code.
  def telegram_compact_reply(locale, result: COMPACT_RESULT)
    Rubot::I18n.with_locale(locale) do
      handle = Object.new
      handle.define_singleton_method(:compact_session) { result }
      channel = Rubot::Channels::Telegram.new(agent: nil, channel_config: {})

      channel.define_singleton_method(:request_agent) { handle }
      channel.before_process("/compact")[1]
    end
  end

  def web_compact_note(locale, state)
    Rubot::I18n.with_locale(locale) { Rubot::Web::View.render("_compact_note", state: state) }
  end

  # Six slash commands in one language, each answered by the channel's own
  # `before_process`. The agent is a double with only what these replies read,
  # so nothing here can pass on a template the chat never draws.
  def telegram_surfaces(locale)
    Rubot::I18n.with_locale(locale) do
      agent = telegram_stub_agent
      channel = Rubot::Channels::Telegram.new(agent: nil, channel_config: {})
      channel.define_singleton_method(:request_agent) { agent }
      channel.define_singleton_method(:cancel_session) { |_id| false }

      {
        start: channel.before_process("/start")[1],
        new: channel.before_process("/new")[1],
        stop: channel.before_process("/stop")[1],
        help: channel.before_process("/help")[1],
        skills: channel.before_process("/skills")[1],
        auto: channel.before_process("/auto sideways")[1]
      }
    end
  end

  # The agent as the command replies see it: a registry with no skills installed
  # (the empty state), a session that clears, and nothing else.
  def telegram_stub_agent
    registry = Object.new
    registry.define_singleton_method(:reload!) { nil }
    registry.define_singleton_method(:any?) { false }

    handle = Object.new
    handle.define_singleton_method(:clear_session) { true }
    handle.define_singleton_method(:skill_registry) { registry }
    handle
  end

  # /context, with a report shaped like the agent's: a window, a hit rate, and a
  # price, so every label on the card is drawn.
  def telegram_context(locale)
    Rubot::I18n.with_locale(locale) do
      handle = Object.new
      handle.define_singleton_method(:usage_report) { CONTEXT_REPORT }
      channel = Rubot::Channels::Telegram.new(agent: nil, channel_config: {})
      channel.define_singleton_method(:request_agent) { handle }
      channel.before_process("/context")[1]
    end
  end

  # The live card, drawn by the channel's own notify_* path: one tool, two sub
  # agents running, and the round that fires the one-time /stop hint.
  def telegram_status_card(locale)
    Rubot::I18n.with_locale(locale) do
      texts = []
      channel = Rubot::Channels::Telegram.new(agent: nil, channel_config: {})
      channel.define_singleton_method(:update_or_send_status) do |_chat_id, _thread_id, text, **_options|
        texts << text
        true
      end

      channel.notify_tool_started(42, 7, "shell_exec", { "command" => "bundle exec rspec" })
      channel.notify_subagent(42, 7, { run_id: "r1", agent: "writer", phase: "started", detail: "write a poem" })
      channel.notify_subagent(42, 7, { run_id: "r2", agent: "researcher", phase: "tool", detail: "search the docs" })
      channel.notify_progress(42, 7, 3)

      texts.last
    end
  end

  def spoken_captions(locale)
    Rubot::I18n.with_locale(locale) do
      [
        Rubot::ToolCaption.caption("shell_exec", { "command" => "ls" }),
        Rubot::ToolCaption.caption("shell_exec", { "command" => "grep -rn Turn lib" }),
        Rubot::ToolCaption.caption("shell_exec", { "command" => "find lib" }),
        Rubot::ToolCaption.caption("delegate", { "agent" => "planner" }),
        Rubot::ToolCaption.caption("file_ops", { "operation" => "read", "path" => "lib/rubot/agent.rb" }),
        Rubot::ToolCaption.caption("shell_exec", { "command" => "sleep 90" })
      ]
    end
  end

  def config_with(data)
    File.write(@config_path, data.to_yaml)
    Rubot::Config.new(@config_path)
  end

  # The three rows the reader meets most, drawn exactly as a channel draws
  # them: a tool caption goes through ToolCaption, the other two through the
  # dictionary entry the TUI and the web timeline share.
  def spoken_in(locale)
    Rubot::I18n.with_locale(locale) do
      {
        tool: Rubot::ToolCaption.caption("shell_exec", { "command" => "" }),
        thinking: Rubot::I18n.t("thinking.done", duration: "5s"),
        compaction: Rubot::I18n.t("compaction.done", count: 12, before: 48_000, after: 9_000)
      }
    end
  end

  # One whole turn of the TUI in one language: the label while the model is
  # still thinking, then the collapsed block and the footer once the answer
  # lands. The rows come off the app's own renderer, so a string that never
  # reaches the screen is not counted as translated.
  def tui_turn_in(locale)
    Rubot::I18n.with_locale(locale) do
      repl = build_repl
      app = repl.instance_variable_get(:@app)
      events = repl.instance_variable_get(:@events)

      events << [ :stream_start ]
      events << [ :thinking, "let me look" ]
      repl.pump
      live = plain(app.render_lines).join("\n")

      # A pause long enough to keep a row: 12s of thinking, then an answer.
      age_thinking(repl, 12)
      repl.instance_variable_set(:@turn_started_at, repl.monotonic_now - 145)
      events << [ :chunk, "the answer" ]
      events << [ :stream_end ]
      repl.pump

      { live: live, rows: plain(app.render_lines).join("\n") }
    end
  end
end
