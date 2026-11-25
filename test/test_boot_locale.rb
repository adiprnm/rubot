# frozen_string_literal: true

require "test_helper"

# The language a config file asks for, at the moment the process starts.
#
# `bahasa: id` used to be inert until someone opened the settings page and
# pressed save, because that handler was the only place that ever set
# Rubot::I18n.locale. These tests boot each channel the way the launcher does —
# a real config.yml, read by Config.new, handed to the channel — and check the
# language is in force before anything is drawn. No settings page, no storage.
class TestBootLocale < Minitest::Test
  # No turn runs in these tests, so the channel only needs something non-nil to
  # hold; agent mode also keeps the constructor from opening an archive.
  STUB_AGENT = Object.new

  def setup
    @tmpdir = Dir.mktmpdir("rubot-boot-locale")
  end

  def teardown
    Rubot::I18n.locale = Rubot::I18n::DEFAULT_LOCALE
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  # --- the config key, at boot ------------------------------------------

  # A config file that says `bahasa: id` speaks Indonesian on the terminal's
  # first row, with nobody having touched the settings page.
  def test_the_tui_speaks_the_language_its_config_names_before_anything_is_drawn
    config = config_with(bahasa: "id")
    assert_equal "en", Rubot::I18n.locale, "the process starts in the default"

    Rubot::Channels::TuiChannel.new(agent: STUB_AGENT, app_config: config)

    assert_equal "id", Rubot::I18n.locale
    assert_equal "Menjalankan perintah di terminal",
                 Rubot::ToolCaption.caption("shell_exec", { "command" => "" }),
                 "the first row drawn is already in the configured language"
  end

  # The same file, the same boot step, the browser channel: the language is a
  # setting of the install, not of one channel.
  def test_the_web_channel_speaks_the_language_its_config_names_before_anything_is_drawn
    config = config_with(bahasa: "id")

    Rubot::Channels::Web.new(agent: STUB_AGENT, app_config: config, channel_config: {})

    assert_equal "id", Rubot::I18n.locale
    assert_equal "Memori", Rubot::I18n.t("tool.name.memory")
  end

  # Telegram goes through the same funnel, so it gets the same answer.
  def test_the_telegram_channel_speaks_the_language_its_config_names
    config = config_with(bahasa: "id")

    Rubot::Channels::Telegram.new(agent: STUB_AGENT, app_config: config,
                                  channel_config: { "token" => "123:abc" })

    assert_equal "id", Rubot::I18n.locale
  end

  # A config that names no language means English, and booting must not invent
  # one: the default is what every existing config file already says.
  def test_a_config_that_names_no_language_boots_in_english
    config = config_with(bahasa: nil)
    Rubot::I18n.locale = "id" # a previous run, a saved setting, anything

    Rubot::Channels::TuiChannel.new(agent: STUB_AGENT, app_config: config)

    assert_equal "en", Rubot::I18n.locale
    assert_equal "Thinking…", Rubot::I18n.t("thinking.live")
  end

  # The step itself is public and answers with the locale it set, which is what
  # makes it the one thing a new channel has to remember to call.
  def test_apply_locale_is_the_one_boot_step_and_reports_what_it_set
    assert_equal "en", config_with(bahasa: nil).apply_locale!
    assert_equal "id", config_with(bahasa: "id", dir: File.join(@tmpdir, "kedua")).apply_locale!
  end

  # --- a language nobody speaks -----------------------------------------

  # The launch is refused where the config is read, and the message names the
  # value and the choices — the same words the settings form already uses.
  def test_an_unknown_language_stops_the_launch_and_names_the_value_and_the_choices
    config = config_with(bahasa: "fr")

    error = assert_raises(Rubot::I18n::UnknownLocale) { config.apply_locale! }

    assert_includes error.message, "fr"
    assert_includes error.message, "en, id"
    assert_equal "en", Rubot::I18n.locale, "nothing is half-switched"
  end

  # The registry's per-channel rescue turns a failure into "Skipping channel".
  # A refused language must not be swallowed into a fallback: it has to reach
  # the launch, before a channel exists to be skipped.
  def test_the_registry_refuses_a_bad_language_before_it_builds_any_channel
    config = config_with(bahasa: "fr")

    error = assert_raises(Rubot::I18n::UnknownLocale) do
      Rubot::Channels::Registry.start_channels(data: config.data, config: config,
                                               options: { channel: "tui" })
    end

    assert_includes error.message, "fr"
    assert_equal "en", Rubot::I18n.locale
  end

  # And a channel built directly refuses it too, so an embedder that never
  # passes through the registry is not the hole the hole came back through.
  def test_a_channel_built_directly_refuses_a_bad_language
    config = config_with(bahasa: "fr")

    assert_raises(Rubot::I18n::UnknownLocale) do
      Rubot::Channels::Web.new(agent: STUB_AGENT, app_config: config, channel_config: {})
    end

    assert_equal "en", Rubot::I18n.locale
  end

  private

  # A real config.yml on disk, read the way the launcher reads it: the file is
  # the only input, so this is the boot the reader actually gets.
  def config_with(bahasa:, dir: @tmpdir)
    workspace = File.join(dir, "workspace")
    FileUtils.mkdir_p(workspace)
    path = File.join(dir, "config.yml")
    data = {
      "agents" => { "defaults" => { "workspace" => workspace, "name" => "test" } },
      "models" => [
        { "name" => "test", "model" => "openai/test-model",
          "api_key" => "sk-test", "api_base" => "http://127.0.0.1:1/v1" }
      ],
      "provider" => "openai"
    }
    data["bahasa"] = bahasa if bahasa
    File.write(path, data.to_yaml)
    Rubot::Config.new(path)
  end
end
