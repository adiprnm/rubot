# frozen_string_literal: true

require "test_helper"
require "cgi"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # The install settings page and the Instagram tab it carries.
    class TestWebSettings < Minitest::Test
      include WebChannelSupport

      # --- install settings ------------------------------------------------

      # What the form shows, and what it must not: the key is a capability, so
      # the page says whether one is stored and never what it is.
      def test_the_settings_page_shows_the_install_values_and_never_the_key
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        channel.instance_variable_get(:@app_config).apply_settings(
          "provider" => "anthropic", "api_key" => "sk-rahasia", "default_model" => "claude-sonnet"
        )

        res = FakeResponse.new
        channel.render_settings(res, FakeRequest.new("/settings"))

        assert_includes res.body, %(value="claude-sonnet")
        assert_includes res.body, %(<option value="anthropic" selected>)
        assert_includes res.body, "sudah tersimpan"
        refute_includes res.body, "sk-rahasia", "a credential must not come back in the page"
      end

      # The page is one form with five subjects, one panel at a time: the strip
      # says which subject, and the panel opens with a line saying what it
      # currently holds. The panels that are not shown stay in the DOM —
      # `display: none`, not disabled — so the single Save button posts all of
      # them, and a reader who saves from the Instagram tab does not drop the
      # model they changed a minute earlier.
      def test_the_page_is_five_tab_panels_of_one_form
        html = settings_page_html

        labels = html.scan(%r{<button[^>]*role="tab"[^>]*>(.*?)</button>}m).flatten.map(&:strip)
        assert_equal ["Koneksi", "Tampilan", "Preset model", "Subagent", "Instagram"], labels

        assert_equal 5, html.scan(%r{<section class="settings-panel[^"]*" role="tabpanel"}).size
        assert_equal 1, html.scan(%r{class="settings-panel is-active"}).size,
                     "exactly one panel is on before anything is pressed"

        # Each tab names its panel and each panel names its tab, or a screen
        # reader announces a panel with no title.
        assert_equal 5, html.scan(%r{aria-controls="settings-panel-}).size
        assert_equal 5, html.scan(%r{aria-labelledby="settings-tab-}).size

        # A hidden panel still contributes its fields.
        assert_includes html, %(name="api_key" )
        assert_includes html, %(name="new_preset_name")
        assert_includes html, %(name="instagram_app_id")
        assert_includes html, %(name="subagent_slug")
      end

      # Without a script the strip is hidden and every panel shows: a page that
      # cannot switch tabs should read as the long page it used to be, not as
      # one fifth of the form. With a script, one panel at a time.
      def test_the_panels_hide_only_on_a_page_whose_script_ran
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes css, "html.js .settings-panel { display: none; }"
        assert_includes css, "html.js .settings-panel.is-active { display: block; }"
        assert_includes css, "html:not(.js) .settings-tabs { display: none; }"

        # The tab is remembered for the sitting, because the reload after Save
        # is exactly when it would otherwise snap back to the first one.
        assert_includes js, %(sessionStorage.setItem(SETTINGS_TAB_KEY, target.dataset.settingsTab))
        assert_includes js, %(ArrowRight), "the strip has to work from the keyboard"
        assert_includes js, "document.getElementById(tab.getAttribute(\"aria-controls\"))"
      end

      # Saving is the point of the page: the archive holds it, and the process
      # that is already running uses it from the next turn.
      def test_saving_settings_writes_the_archive_and_the_running_config
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })

        res = FakeResponse.new
        channel.save_settings(res, form_post(
          { "provider" => "ollama", "default_model" => "llama3", "api_key" => "sk-baru" }
        ))

        assert_equal 303, res.status
        assert_includes res.headers["Location"].to_s, "saved=1"

        store = Rubot::Session.store
        assert_equal "ollama", store.setting("provider")
        assert_equal "sk-baru", store.setting("api_key")

        config = channel.instance_variable_get(:@app_config)
        assert_equal "ollama", config.provider
        assert_equal "llama3", config.model
        assert_equal "sk-baru", config.api_key
      end

      # --- the language -----------------------------------------------------

      # The language is a setting like any other, so it is a field like any
      # other: two options, and the one in force is the one shown as chosen.
      def test_the_settings_page_offers_both_languages_and_shows_the_active_one
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })

        html = settings_page_of(channel)

        assert_includes html, %(<select id="setting-bahasa" name="bahasa">)
        assert_includes html, %(<option value="en" selected>English</option>)
        assert_includes html, %(<option value="id">Indonesian</option>)

        # A stored choice is the one the select opens on, not the first entry
        # of the list.
        channel.instance_variable_get(:@app_config).apply_settings("bahasa" => "id")

        html = settings_page_of(channel)

        assert_includes html, %(<option value="id" selected>)
        refute_includes html, %(<option value="en" selected>)
      end

      # Saving a language changes the process that is running and the archive a
      # restart reads. The two have to agree, or the page would speak a
      # language the next boot has forgotten.
      def test_saving_a_language_switches_the_process_and_survives_a_restart
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        config = channel.instance_variable_get(:@app_config)
        assert_equal "en", Rubot::I18n.locale

        res = FakeResponse.new
        channel.save_settings(res, form_post({ "bahasa" => "id", "provider" => "ollama" }))

        assert_equal 303, res.status
        assert_includes res.headers["Location"].to_s, "saved=1"
        assert_equal "id", Rubot::I18n.locale, "the running process speaks the new language at once"
        assert_equal "Menjalankan perintah di terminal",
                     Rubot::ToolCaption.caption("shell_exec", { "command" => "" })

        # A restart is a fresh Config with the archive laid over it, which is
        # exactly the two lines bin/rubot runs before any channel starts.
        reloaded = Rubot::Config.new(config.config_path)
        assert_equal "en", reloaded.bahasa, "the file itself never learned it"
        reloaded.apply_settings(Rubot::Store.saved_settings(config.sessions_dir))
        assert_equal "id", reloaded.bahasa
      ensure
        Rubot::I18n.locale = Rubot::I18n::DEFAULT_LOCALE
      end

      # A language nobody speaks is refused where it is typed: the message
      # names the value and the two that are accepted, nothing is stored, and
      # the process keeps the language it had. A half-switched interface is
      # worse than a rejected form.
      def test_a_language_this_build_does_not_speak_is_refused_with_the_choices
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })

        res = FakeResponse.new
        channel.save_settings(res, form_post({ "bahasa" => "fr", "provider" => "ollama" }))

        assert_equal 303, res.status
        location = res.headers["Location"].to_s
        message = CGI.unescape(location[/error=([^&]*)/, 1].to_s)

        assert_includes message, "fr", "the refused value is named"
        assert_includes message, "en, id", "the accepted ones are named"

        assert_equal "en", Rubot::I18n.locale, "the interface is not left half in one language"
        store = Rubot::Session.store
        assert_nil store.setting("bahasa")
        assert_nil store.setting("provider"), "a refused form stores nothing at all"

        # And the page the reader lands on carries the reason, in the same
        # words the redirect named.
        page = FakeResponse.new
        channel.render_settings(page, FakeRequest.new("/settings", query: { "error" => message }))

        assert_includes page.body, CGI.escapeHTML(message)
      ensure
        Rubot::I18n.locale = Rubot::I18n::DEFAULT_LOCALE
      end

      def test_settings_page_lists_editable_presets_and_the_default_picker
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        config = channel.instance_variable_get(:@app_config)
        config.set_model_preset("cepat", "model" => "mimo-v2.6-flash", "temperature" => 0.2)
        config.set_default_model_preset("cepat")

        res = FakeResponse.new
        channel.render_settings(res, FakeRequest.new("/settings"))

        assert_includes res.body, %(name="preset_name" value="cepat")
        assert_includes res.body, %(value="mimo-v2.6-flash" selected)
        assert_includes res.body, %(name="default_preset")
        assert_includes res.body, %(value="cepat" selected)
        assert_includes res.body, %(name="new_preset_name")
        assert_equal 3, res.body.scan(%(name="new_preset_name")).size, "three blank rows for bulk create"
        refute_includes res.body, "Preset disimpan di config.yml"
      end

      def test_settings_page_lists_each_subagent_with_model_and_thinking
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        config = channel.instance_variable_get(:@app_config)
        config.set_subagent_settings("planner", "model" => "mimo-v2.6-flash", "thinking" => "high")

        res = FakeResponse.new
        channel.render_settings(res, FakeRequest.new("/settings"))

        assert_includes res.body, %(name="subagent_slug" value="planner")
        assert_includes res.body, %(value="mimo-v2.6-flash" selected)
        assert_includes res.body, %(name="subagent_thinking")
        assert_includes res.body, %(value="high" selected)
      end

      def test_saving_settings_writes_per_subagent_model_and_thinking
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        config = channel.instance_variable_get(:@app_config)

        channel.save_settings(FakeResponse.new, form_post(
          { "provider" => "opencode",
            "subagent_slug" => [ "planner", "researcher" ],
            "subagent_model_choice" => [ "mimo-v2.6-flash", "deepseek-v4.1-flash" ],
            "subagent_thinking" => [ "high", "" ] }
        ))

        assert_equal "mimo-v2.6-flash", config.subagent_settings("planner")["model"]
        assert_equal "high", config.subagent_settings("planner")["thinking"]
        assert_equal "deepseek-v4.1-flash", config.subagent_settings("researcher")["model"]
        assert_nil config.subagent_settings("researcher")["thinking"]
        assert_equal "mimo-v2.6-flash", YAML.load_file(config.config_path).dig("subagents", "planner", "model")
      end

      def test_saving_settings_adds_multiple_new_presets_at_once
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        config = channel.instance_variable_get(:@app_config)

        channel.save_settings(FakeResponse.new, form_post(
          { "provider" => "opencode",
            "new_preset_name" => [ "cepat", "lama", "" ],
            "new_preset_model" => [ "mimo-v2.6-flash", "deepseek-v4.1-flash", "" ],
            "new_preset_temperature" => [ "0.2", "", "" ],
            "new_preset_max_tokens" => [ "4096", "", "" ],
            "new_preset_reasoning_effort" => [ "low", "", "" ] }
        ))

        preset = config.model_preset("cepat")
        assert_equal "mimo-v2.6-flash", preset["model"]
        assert_equal 0.2, preset["temperature"]
        assert_equal 4096, preset["max_tokens"]
        assert_equal "low", preset["reasoning_effort"]
        assert_equal "deepseek-v4.1-flash", config.model_preset("lama")["model"]
        assert_equal 2, config.model_presets.size
        assert_equal "mimo-v2.6-flash", YAML.load_file(config.config_path).dig("model_presets", "cepat", "model")
      end

      def test_saving_settings_writes_presets_to_config_and_can_delete_them
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        config = channel.instance_variable_get(:@app_config)

        channel.save_settings(FakeResponse.new, form_post(
          { "provider" => "opencode", "preset_name" => [ "cepat", "lama" ],
            "preset_model" => [ "mimo-v2.6-flash", "deepseek-v4.1-flash" ],
            "preset_temperature" => [ "0.2", "" ],
            "preset_max_tokens" => [ "4096", "" ],
            "preset_reasoning_effort" => [ "low", "" ],
            "default_preset" => "cepat" }
        ))

        assert_equal "mimo-v2.6-flash", config.model_preset("cepat")["model"]
        assert_includes config.model_preset_names, "lama"
        assert_equal "cepat", config.primary_model_preset_name
        assert_equal "mimo-v2.6-flash", YAML.load_file(config.config_path).dig("model_presets", "cepat", "model")

        channel.save_settings(FakeResponse.new, form_post(
          { "provider" => "opencode", "preset_name" => [ "lama" ], "preset_model" => [ "" ] }
        ))
        refute_includes config.model_preset_names, "lama"
      end

      # A password box that comes back empty means "I did not touch it", not
      # "delete the key" — deleting is its own checkbox, because the two are one
      # keystroke apart and only one of them can be undone from this page.
      def test_a_blank_key_field_keeps_the_stored_key_until_it_is_cleared
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        channel.save_settings(FakeResponse.new,
                     form_post({ "provider" => "openai", "api_key" => "sk-lama" }))

        channel.save_settings(FakeResponse.new,
                     form_post({ "provider" => "openai", "api_key" => "" }))
        assert_equal "sk-lama", Rubot::Session.store.setting("api_key")

        channel.save_settings(FakeResponse.new,
                     form_post({ "provider" => "openai", "api_key" => "", "clear_api_key" => "1" }))
        assert_nil Rubot::Session.store.setting("api_key"), "the checkbox hands the key back to config.yml"
      end

      # --- instagram -------------------------------------------------------

      def test_settings_form_saves_ig_credentials_without_touching_the_token
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        store = Rubot::Session.store
        store.set_setting("instagram_app_secret", "secret-lama")
        Rubot::Instagram.new(store: store, persona: "rubot").save_account(
          access_token: "token-rahasia", ig_user_id: "ig-1", username: "adipurnm"
        )

        channel.save_settings(FakeResponse.new,
                     form_post({ "provider" => "openai", "instagram_app_id" => "app-baru",
                                 "instagram_redirect_uri" => "https://rubot.ts.net/instagram/callback" }))

        assert_equal "app-baru", store.setting("instagram_app_id")
        assert_equal "secret-lama", store.setting("instagram_app_secret"), "a blank secret keeps the stored one"
        assert_equal "token-rahasia", store.db.get_first_value("SELECT access_token FROM instagram_accounts WHERE id = 1"),
                     "saving the form must never overwrite the OAuth token"
      end

      def test_settings_page_never_echoes_the_ig_secret
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        Rubot::Session.store.set_setting("instagram_app_secret", "secret-rahasia")

        res = FakeResponse.new
        channel.render_settings(res, FakeRequest.new("/settings"))
        refute_includes res.body, "secret-rahasia"
        assert_includes res.body, "sudah tersimpan"
      end

      def test_connect_route_redirects_to_meta_with_a_fresh_state
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        store = Rubot::Session.store
        store.update_settings("instagram_app_id" => "app", "instagram_app_secret" => "secret",
                              "instagram_redirect_uri" => "https://rubot.ts.net/instagram/callback")

        res = FakeResponse.new
        channel.send(:dispatch, FakeRequest.new("/instagram/connect"), res)
        assert_equal 303, res.status
        location = res.headers["Location"].to_s
        assert_includes location, "https://www.facebook.com/#{Rubot::Instagram::API_VERSION}/dialog/oauth"
        query = URI.decode_www_form(URI(location).query).to_h
        assert_equal "app", query["client_id"]
        assert_equal 48, query["state"].length
      end

      def test_callback_exchanges_code_and_shows_only_the_username
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        store = Rubot::Session.store
        store.update_settings("instagram_app_id" => "app", "instagram_app_secret" => "secret",
                              "instagram_redirect_uri" => "https://rubot.ts.net/instagram/callback")
        ig = Rubot::Instagram.new(store: store)
        state = URI.decode_www_form(URI(ig.authorize_url).query).to_h["state"]
        ig.define_singleton_method(:api_get) do |path, params|
          case path
          when "/oauth/access_token"
            params["grant_type"] == "authorization_code" ? { "access_token" => "user" } :
              { "access_token" => "page-token", "expires_in" => 5_175_360 }
          when "/me/accounts"
            { "data" => [ { "instagram_business_account" => { "id" => "ig-1" } } ] }
          else
            { "username" => "adipurnm", "account_type" => "BUSINESS" }
          end
        end
        # The channel builds its own client, so stub the class for this request.
        Rubot::Instagram.stub(:new, ig) do
          res = FakeResponse.new
          channel.send(:dispatch, FakeRequest.new("/instagram/callback", query: { "code" => "code", "state" => state }), res)
          assert_equal 200, res.status
          assert_includes res.body, "@adipurnm"
          refute_includes res.body, "page-token"
          assert_includes res.body, "window.close()", "a successful callback closes its tab"
        end
      end

      def test_subagent_phases_become_timeline_rows
        turn = Rubot::Web::Turn.new(id: "t1", session_id: "web_rubot")
        turn.subagent_item(run_id: "r1", agent: "writer", phase: "started", detail: "write a poem", depth: 0)
        turn.subagent_item(run_id: "r1", agent: "writer", phase: "done", detail: "3s", depth: 0)
        html = Rubot::Web::View.turn_body(turn, token_query: "")

        assert_includes html, "subagent-row"
        assert_includes html, %(<span class="subagent-name">writer</span>)
        refute_includes html, "subagent ·"
        assert_includes html, "write a poem"
      end

      # The channel calls both callbacks for every phase: one keeps the count of
      # calls a run made, the other decides what the transcript keeps.

      # Delegated runs have one place on the page: the footer. The band above
      # the composer says the turn is still working and nothing else, so a run
      # is not reported twice in two registers.
      def test_the_working_band_does_not_carry_subagents
        html = Rubot::Web::View.render("_working", since: 12.5)

        assert_includes html, "Working…"
        refute_includes html, "subagent"
      end

      # The footer is where a delegated run is read: it outlives the turn that
      # asked for it, so it cannot live in the turn's own view — and it is not
      # there at all when there is nothing to say.
      def test_the_footer_sheet_names_itself_and_lists_the_runs
        running = [
          { agent: "writer", phase: "tool", detail: "tulis puisi", line: "1 langkah · tulis puisi" },
          { agent: "researcher", phase: "started", detail: "find docs", line: "find docs" }
        ]
        html = Rubot::Web::View.render("_subagent_sheet", subagents: running)
        assert_includes html, %(<span class="subagent-label">subagent</span>)
        assert_includes html, "researcher"
        assert_includes html, "1 langkah · tulis puisi"
        refute_includes html, "read notes.md"
        refute_includes html, %(id="subagent-sheet" hidden)

        finished = [
          { agent: "writer", phase: "done", detail: "9s", line: "1 langkah · 9s", finished_at: Time.now }
        ]
        html = Rubot::Web::View.render("_subagent_sheet", subagents: finished)
        assert_includes html, "subagent-done"

        # Nothing running and the last run long gone: the row keeps nothing.
        stale = [
          { agent: "writer", phase: "done", detail: "9s", line: "1 langkah · 9s",
            finished_at: Time.now - (Rubot::Web::SubagentJobs::DONE_MARK_SECONDS + 60) }
        ]
        html = Rubot::Web::View.render("_subagent_sheet", subagents: stale)
        assert_includes html, %(id="subagent-sheet" hidden)

        html = Rubot::Web::View.render("_subagent_sheet", subagents: [])
        assert_includes html, %(id="subagent-sheet" hidden)
      end

      # A page that was away has missed the events that moved the footer, and
      # the sheet otherwise only ever arrives as a diff (the slots inside it).
      # One lost event left a run that had come back still wearing the mark it
      # wore while it worked — the reader saw two runs apparently stuck and one
      # ticked. The stream hands the whole sheet over on every (re)connect, so
      # a page with a stale footer repairs itself without a reload.
      def test_a_reopened_stream_hands_the_page_the_whole_footer_again
        channel = channel_with_sessions(personas: { "rubot" => { "name" => "Rubot" } },
                                        sessions: { "web_rubot" => "Halo" })
        jobs = channel.instance_variable_get(:@subagent_jobs)
        jobs.start(session_id: "web_rubot", run_id: "r1", agent: "writer", task: "tulis puisi")
        jobs.start(session_id: "web_rubot", run_id: "r2", agent: "researcher", task: "cari docs")
        jobs.finish(session_id: "web_rubot", run_id: "r1", status: "done", result: "puisi")
        jobs.finish(session_id: "web_rubot", run_id: "r2", status: "done", result: "docs")

        sheet = channel.event_stream_opening("web_rubot").to_h[:"subagent-sheet"]

        assert_includes sheet, %(id="subagent-sheet" hx-swap-oob="true")
        assert_equal 2, sheet.scan("subagent-done").size, "both runs read as finished"
        assert_includes sheet, "writer"
        assert_includes sheet, "researcher"
      end

      # The footer is a reply to "did it finish?", not a permanent decoration.
      # Three seconds after the last run lands the sheet goes — and nothing else
      # will ever mention it, so the channel schedules that hiding itself rather
      # than waiting for an event that never comes.
      def test_the_footer_hides_once_the_mark_has_had_its_three_seconds
        channel = channel_with_sessions(personas: { "rubot" => { "name" => "Rubot" } },
                                        sessions: { "web_rubot" => "Halo" })
        sent = []
        channel.define_singleton_method(:push_to_session) { |_sid, type, markup| sent << [ type, markup ] }

        jobs = channel.instance_variable_get(:@subagent_jobs)
        jobs.start(session_id: "web_rubot", run_id: "r1", agent: "writer", task: "tulis puisi")
        jobs.finish(session_id: "web_rubot", run_id: "r1", status: "done", result: "puisi")
        sent.clear

        channel.hide_finished_subagents("web_rubot")
        assert_empty sent, "the tick is still inside its three seconds"

        # The same call, three seconds later, is what takes the row away. Time is
        # moved on the run rather than waited out.
        jobs.instance_variable_get(:@runs)["web_rubot"]["r1"][:finished_at] =
          Time.now - (Rubot::Web::SubagentJobs::DONE_MARK_SECONDS + 1)
        channel.hide_finished_subagents("web_rubot")

        assert_match(/id="subagent-sheet"[^>]*\shidden/, sent.last[1])
      end

      # One element, one source: the sheet appears when the first run starts
      # and afterwards only its slots move, so an open panel stays open.
      def test_the_footer_appears_on_the_first_event_and_then_only_moves_its_slots
        channel = channel_with_sessions(personas: { "rubot" => { "name" => "Rubot" } },
                                        sessions: { "web_rubot" => "Halo" })
        sent = []
        channel.define_singleton_method(:push_to_session) { |_sid, type, markup| sent << [ type, markup ] }

        jobs = channel.instance_variable_get(:@subagent_jobs)
        jobs.start(session_id: "web_rubot", run_id: "r1", agent: "writer", task: "tulis puisi")

        assert_equal 1, sent.size
        assert_includes sent.first[1], %(id="subagent-sheet" hx-swap-oob="true")
        assert_includes sent.first[1], %(id="subagent-sheet-body")

        jobs.update(session_id: "web_rubot", run_id: "r1", phase: "tool")

        assert_equal 2, sent.size
        refute_includes sent.last[1], %(id="subagent-sheet" hx-swap-oob="true")
        assert_includes sent.last[1], %(id="subagent-sheet-body" hx-swap-oob="innerHTML")
        # The row counts the step and keeps naming the task, never the tool the
        # sub agent reached for.
        assert_includes sent.last[1], "1 langkah · tulis puisi"
        refute_includes sent.last[1], "grep rhyme"
      end

      # A compact turn does not narrate the calls a delegated agent made: the
      # strip above the composer already names the agent and the call it is on
      # while it works. What survives into the transcript is one row per run,
      # with the count of calls it took.
      def test_a_compact_turn_records_one_row_per_subagent_run
        turn = Rubot::Web::Turn.new(id: "t1", session_id: "web_rubot", tool_output: "compact")
        feed_subagent(turn, run_id: "r1", agent: "writer", phase: "started", detail: "write a poem", depth: 0)
        feed_subagent(turn, run_id: "r1", agent: "writer", phase: "tool", detail: "read notes.md", depth: 0)
        feed_subagent(turn, run_id: "r1", agent: "writer", phase: "tool", detail: "grep rhyme", depth: 0)
        feed_subagent(turn, run_id: "r1", agent: "writer", phase: "thinking", detail: "hmm", depth: 0)
        html = Rubot::Web::View.turn_body(turn, token_query: "")

        assert_equal 0, turn.items.count { |item| item[:kind] == :subagent }

        feed_subagent(turn, run_id: "r1", agent: "writer", phase: "done", detail: "12s", depth: 0)
        html = Rubot::Web::View.turn_body(turn, token_query: "")

        assert_equal 1, turn.items.count { |item| item[:kind] == :subagent }
        assert_equal 1, html.scan("subagent-row").size
        assert_includes html, "2 langkah · 12s"
        refute_includes html, "read notes.md"
        refute_includes html, "grep rhyme"
        # The task still rides on the row, just not as a line of its own.
        assert_includes html, %(title="write a poem")
      end

      def test_a_compact_turn_keeps_the_reason_a_run_failed
        turn = Rubot::Web::Turn.new(id: "t1", session_id: "web_rubot", tool_output: "compact")
        feed_subagent(turn, run_id: "r1", agent: "writer", phase: "started", detail: "write a poem", depth: 0)
        feed_subagent(turn, run_id: "r1", agent: "writer", phase: "tool", detail: "read notes.md", depth: 0)
        feed_subagent(turn, run_id: "r1", agent: "writer", phase: "failed", detail: "rate limited", depth: 0)
        html = Rubot::Web::View.turn_body(turn, token_query: "")

        assert_equal 1, html.scan("subagent-row").size
        assert_includes html, "subagent-failed"
        assert_includes html, "rate limited"
        refute_includes html, "1 langkah"
      end

      def test_a_compaction_callback_becomes_a_timeline_row
        turn = Rubot::Web::Turn.new(id: "t1", session_id: "web_rubot")
        turn.compaction(summarized_messages: 8, context_before: 2029, context_after: 1565)
        html = Rubot::Web::View.turn_body(turn, token_query: "")

        assert_includes html, "compaction-row"
        assert_includes html, "2029 → 1565 token"
        refute_includes html, "pesan diringkas"
      end

      def test_a_running_compaction_shows_a_progress_row_then_turns_into_the_result
        turn = Rubot::Web::Turn.new(id: "t1", session_id: "web_rubot")
        turn.compaction_start
        running = Rubot::Web::View.turn_body(turn, token_query: "")

        assert_includes running, "compaction-row is-running"
        assert_includes running, "Compaction sedang berlangsung"
        refute_includes running, "2029 → 1565 token"

        turn.compaction(summarized_messages: 8, context_before: 2029, context_after: 1565)
        done = Rubot::Web::View.turn_body(turn, token_query: "")

        refute_includes done, "is-running"
        assert_includes done, "Konteks diringkas."
        assert_includes done, "2029 → 1565 token"
        refute_includes done, "pesan diringkas"
        assert_equal 1, turn.items.count { |item| item[:kind] == :compaction }
      end

      def test_a_failed_compaction_retires_the_progress_row
        turn = Rubot::Web::Turn.new(id: "t1", session_id: "web_rubot")
        turn.compaction_start
        running = Rubot::Web::View.turn_body(turn, token_query: "")
        assert_includes running, "Compaction sedang berlangsung"

        turn.compaction_failed
        failed = Rubot::Web::View.turn_body(turn, token_query: "")

        refute_includes failed, "is-running"
        refute_includes failed, "Compaction sedang berlangsung"
        assert_includes failed, "Ringkasan tidak berhasil dibuat"
        assert_equal 1, turn.items.count { |item| item[:kind] == :compaction }
      end

      def test_connect_card_is_drawn_in_the_timeline
        turn = Rubot::Web::Turn.new(id: "t1", session_id: "web_rubot")
        turn.add_instagram_card
        html = Rubot::Web::View.turn_body(turn, token_query: "?token=abc")

        assert_includes html, "ig-connect-card"
        assert_includes html, "/instagram/connect?token=abc"
        assert_includes html, "Connect dengan Instagram"
      end

      def test_connect_button_disables_and_shows_a_spinner_while_connecting
        turn = Rubot::Web::Turn.new(id: "t1", session_id: "web_rubot")
        turn.add_instagram_card
        html = Rubot::Web::View.turn_body(turn, token_query: "?token=abc")

        assert_includes html, "@submit=\"busy = true\"", "pressing the button marks it busy"
        assert_includes html, ":disabled=\"busy\"", "the button goes disabled while connecting"
        assert_includes html, "ig-spinner", "a loading indicator is present"
        assert_includes html, "Menghubungkan…", "the label says it is connecting"
        assert_includes html, "target=\"_blank\"", "the OAuth dialog opens in a new tab"
      end

      def test_connect_card_keeps_the_connect_button_and_lists_linked_accounts
        turn = Rubot::Web::Turn.new(id: "t1", session_id: "web_rubot")
        turn.add_instagram_card
        accounts = [
          { "id" => 1, "username" => "adipurnm", "is_default" => true },
          { "id" => 2, "username" => "kanyaahweb", "is_default" => false }
        ]
        html = Rubot::Web::View.turn_body(turn, token_query: "?token=abc", ig_accounts: accounts,
                                          ig_linkable_accounts: [])

        # The button stays so a second (or third) account can still be added.
        assert_includes html, "/instagram/connect", "Connect stays available for another account"
        assert_includes html, "Connect dengan Instagram"
        assert_includes html, "@adipurnm"
        assert_includes html, "@kanyaahweb"
        assert_includes html, "(default)", "the default account is marked"
        assert_equal 2, html.scan('name="account"').length, "each account has its own Putuskan"
        assert_includes html, "name=\"account\" value=\"adipurnm\"", "the right account is named"
        # The buttons answer for the card they sit in, not for the first
        # #ig-status in the document: an older page drawn above the live one
        # carries a card of its own, and the id selector swapped the wrong one.
        assert_equal 2, html.scan('hx-target="closest .ig-connect-card"').length
      end

      def test_instagram_disconnect_route_removes_the_account
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        store = Rubot::Session.store
        ig = Rubot::Instagram.new(store: store, persona: "rubot")
        ig.save_account(access_token: "t", ig_user_id: "ig-1", username: "adipurnm")
        assert ig.connected?

        res = FakeResponse.new
        channel.send(:dispatch, FakeRequest.new("/instagram/disconnect", method: "POST",
                                                query: { "account" => "adipurnm", "persona" => "rubot" }), res)

        refute ig.connected?, "the account is gone from this persona"
        assert_equal 200, res.status
        assert_includes res.body, "ig-connect-card"
        assert_includes res.body, "Connect dengan Instagram", "the card is back in the connect state"
        refute_includes res.body, "ig-account-name\">\n          <span class=\"ig-check\"", "no linked account is listed"
        assert_includes res.body, "Link akun ini", "the token survives install-wide, so it can be re-linked without OAuth"
      end

      def test_connect_button_has_no_underline
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        rule = css[/\.ig-connect-btn\s*\{[^}]*\}/]
        assert rule, "the connect button has a style rule"
        assert_includes rule, "text-decoration: none"
      end

      def test_instagram_connect_tool_row_does_not_repeat_connect
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        call = { "function" => { "name" => "instagram",
                                 "arguments" => JSON.generate("operation" => "connect") } }
        items = channel.history_tool_items(call, {}, {}, "web_rubot")
        row = items.first

        assert_equal "instagram", row[:name]
        refute row.key?(:op), "the op is folded into the tool name, not repeated"
      end

      def test_instagram_card_offers_to_link_an_existing_account
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        store = Rubot::Session.store
        Rubot::Instagram.new(store: store, persona: "kanyaah").save_account(
          access_token: "t", ig_user_id: "ig-1", username: "kanyaahweb"
        )

        markup = channel.send(:instagram_card_markup, persona: "rubot")
        assert_includes markup, "/instagram/link", "another persona's account can be linked here"
        assert_includes markup, "@kanyaahweb"
        assert_includes markup, "Link akun ini"
      end

      def test_instagram_link_route_grants_access_without_oauth
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        store = Rubot::Session.store
        Rubot::Instagram.new(store: store, persona: "kanyaah").save_account(
          access_token: "t", ig_user_id: "ig-1", username: "kanyaahweb"
        )
        rubot = Rubot::Instagram.new(store: store, persona: "rubot")
        refute rubot.connected?

        res = FakeResponse.new
        channel.send(:dispatch, FakeRequest.new("/instagram/link", method: "POST",
                                                query: { "account" => "kanyaahweb", "persona" => "rubot" }), res)

        assert_equal 200, res.status
        assert rubot.connected?, "the account is now linked into this persona"
        assert_includes res.body, "@kanyaahweb"
        assert_equal 1, store.db.get_first_value("SELECT COUNT(*) FROM instagram_accounts"),
                     "no second token row was created"
      end

      def test_instagram_broadcast_swaps_the_whole_card
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })
        Rubot::Session.store.set_setting("instagram_app_id", "app")
        Rubot::Session.store.set_setting("instagram_app_secret", "secret")
        Rubot::Session.store.set_setting("instagram_redirect_uri", "https://rubot.ts.net/instagram/callback")
        ig = Rubot::Instagram.new(store: Rubot::Session.store)
        ig.save_account(access_token: "t", ig_user_id: "ig-1", username: "adipurnm")

        markup = channel.send(:instagram_card_markup, oob: true)
        assert_includes markup, "hx-swap-oob=\"true\""
        assert_includes markup, "@adipurnm"
        assert_includes markup, "/instagram/connect", "the card keeps the Connect button"
      end

      # --- install settings (end) ------------------------------------------

      private

      # The settings page as one channel draws it, so a test can read the form
      # the running install would send rather than a page built from fakes.
      def settings_page_of(channel)
        res = FakeResponse.new
        channel.render_settings(res, FakeRequest.new("/settings"))
        res.body
      end
    end
  end
end
