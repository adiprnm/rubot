# frozen_string_literal: true

require "test_helper"

# The language switch, tested where a reader meets it: the config key that
# chooses it, the dictionary both languages are written in, and the rows the
# channels draw through the one translation function.
class TestI18n < Minitest::Test
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

  private

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
end
