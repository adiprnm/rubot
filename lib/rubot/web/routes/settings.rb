# frozen_string_literal: true

module Rubot
  module Web
    module Routes
      # The settings page: the install's provider and key, the personas and what
      # each of them talks to, and the one door that applies a change to the
      # running actors.
      #
      # General settings are the install's; model and thinking level belong to a
      # persona here and are overridden per session on the conversation page
      # itself. Both read from the same rows, which is why the readers and the
      # form live together.
      #
      # Included into the channel and left public on purpose: the router calls
      # these directly, the views ask the readers, and the tests do both.
      module Settings
        # The level a persona starts from, and the one a session falls back to
        # when neither it nor its persona has chosen: the middle of what the
        # models understand, and the one effort a reasoning model accepts.
        DEFAULT_THINKING = "medium"

      # --- settings -------------------------------------------------------

      # The provider that is not in the offered list, if any, is added by
      # `settings_provider_choices`; this is only what a fresh install sees.
      PROVIDER_CHOICES = %w[opencode openai anthropic ollama gemini deepseek groq mistral].freeze

      # The three keys that are not scoped to a persona or a conversation: one
      # provider, one key, one default model for the whole install.
      def render_settings(res, req)
        saved = req.query["saved"].to_s == "1"
        if req.query["refresh"].to_s == "1" || req.query["refresh_models"].to_s == "1"
          begin
            Rubot::ModelCatalog.new(config: @app_config).entries if @app_config
          rescue StandardError
            nil
          end
        end
        store = Rubot::Archive.current

        # The back button returns the reader to wherever they came from, not to
        # a fixed page: the settings page is reachable from any conversation,
        # so a hard-coded destination would drop them somewhere unexpected.
        referer = settings_referer(req)
        back_url = referer.empty? ? "/#{token_query}" : referer

        res["Content-Type"] = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-store"
        # The persona the device-wide controls speak for: the notification test
        # button sends one message to one persona, and the page may have been
        # opened from any conversation. Same resolution the Instagram card uses
        # — named in the query, else the owner of `sid`, else the default.
        persona = ig_persona_for(req)
        res.body = View.render(
          "settings",
          provider: @app_config&.provider.to_s,
          default_model: @app_config&.model.to_s,
          auxiliary_model: @app_config&.auxiliary_model.to_s,
          subagent_model: @app_config&.subagent_model.to_s,
          subagent_rows: settings_subagent_rows,
          preset_rows: settings_preset_rows,
          default_preset: @app_config&.primary_model_preset_name.to_s,
          key_set: !@app_config&.api_key.to_s.empty?,
          key_from_archive: !store&.setting("api_key").to_s.strip.empty?,
          ig_app_id: store&.setting("instagram_app_id").to_s,
          ig_redirect_uri: store&.setting("instagram_redirect_uri").to_s,
          ig_secret_set: !store&.setting("instagram_app_secret").to_s.strip.empty?,
          ig_persona: persona,
          **ig_account_locals(persona),
          push_persona: persona,
          provider_choices: settings_provider_choices,
          model_choices: model_choices,
          saved: saved,
          archived: !store.nil?,
          token_query: token_query,
          back_url: back_url,
          asset_version: asset_version
        )
      end

      def settings_referer(req)
        return "" unless req
        value = nil
        if req.respond_to?(:[])
          value = req["Referer"]
          value = req["HTTP_REFERER"] if value.nil? || value.to_s.strip.empty?
        end
        if (value.nil? || value.to_s.strip.empty?) && req.respond_to?(:header) && req.header.is_a?(Hash)
          value = req.header["Referer"] || req.header["referer"] || req.header["HTTP_REFERER"]
        end
        if (value.nil? || value.to_s.strip.empty?) && req.respond_to?(:referer)
          value = req.referer
        end
        value.to_s.strip
      end

      # The current provider is in the list even when it is not one of the ones
      # offered: an install on an OpenAI-compatible endpoint it spelled itself
      # must not be silently moved to "openai" by opening the page and pressing
      # save.
      def settings_provider_choices
        current = @app_config&.provider.to_s
        list = PROVIDER_CHOICES.dup
        list.unshift(current) unless current.empty? || list.include?(current)
        list
      end

      def save_settings(res, req)
        store = Rubot::Archive.current
        return redirect_to(res, settings_url) unless store

        values = {
          "provider" => form(req, "provider"),
          "default_model" => form(req, "default_model"),
          "auxiliary_model" => form(req, "auxiliary_model"),
          "subagent_model" => form(req, "subagent_model")
        }
        # An empty key field means "leave the key alone": it is a password box,
        # it never carries the current value back, and a form that blanked the
        # key because nobody retyped it would take the install down. Clearing is
        # its own checkbox, and it is what deletes the row.
        if form(req, "clear_api_key") == "1"
          values["api_key"] = nil
        else
          typed = form(req, "api_key").strip
          values["api_key"] = typed unless typed.empty?
        end

        # Instagram credentials are typed here, but the token is not: it is
        # minted by the callback and lives in its own table. Only the three
        # credential keys go through the form, so saving cannot erase a token.
        %w[instagram_app_id instagram_redirect_uri].each do |key|
          values[key] = form(req, key).strip
        end
        if form(req, "clear_ig_secret") == "1"
          values["instagram_app_secret"] = nil
        else
          typed_secret = form(req, "instagram_app_secret").strip
          values["instagram_app_secret"] = typed_secret unless typed_secret.empty?
        end

        store.update_settings(values)
        if form(req, "ig_disconnect") == "1"
          persona = ig_persona_for(req)
          ig = instagram_client(persona: persona)
          ig.accounts.each { |acc| ig.disconnect(username: acc["username"]) }
          instagram_broadcast(persona: persona)
        end
        raw_link = req.query["ig_link"]
        links = raw_link.is_a?(Array) ? raw_link : (raw_link.to_s.empty? ? [] : [ raw_link ])
        links.flat_map { |v| v.to_s.split(",") }.map(&:strip).reject(&:empty?).each do |username|
          persona = ig_persona_for(req)
          begin
            instagram_client(persona: persona).link_account(username: username)
            instagram_broadcast(persona: persona)
          rescue Rubot::Instagram::Error => e
            warn "[web] instagram link: #{e.message}"
          end
        end
        save_settings_presets(req)
        apply_saved_settings
        redirect_to(res, settings_url(saved: true))
      end

      # Presets live in config.yml, not in the settings archive: they are the
      # install's model definitions, edited here with the same form as the
      # provider and key. Each row posts its name and fields; a blank model
      # deletes the preset, and the default picker writes agents.defaults.
      def save_settings_presets(req)
        config = @app_config
        return unless config

        names = form_values(req, "preset_name")

        names.each_with_index do |name, index|
          name = name.to_s.strip
          next if name.empty?

          model = form_values(req, "preset_model")[index].to_s.strip
          if model.empty?
            begin
              config.delete_model_preset(name)
            rescue StandardError => e
              warn "[web] delete preset #{name}: #{e.class}: #{e.message}"
            end
            next
          end

          attrs = { "model" => model }
          %w[preset_max_tokens preset_temperature preset_reasoning_effort].each do |field|
            value = form_values(req, field)[index].to_s.strip
            attrs[field.delete_prefix("preset_")] = value unless value.empty?
          end
          begin
            config.set_model_preset(name, attrs)
          rescue ArgumentError => e
            warn "[web] preset #{name}: #{e.message}"
          end
        end

        new_names = form_values(req, "new_preset_name")
        new_models = form_values(req, "new_preset_model")
        new_temps = form_values(req, "new_preset_temperature")
        new_tokens = form_values(req, "new_preset_max_tokens")
        new_reasoning = form_values(req, "new_preset_reasoning_effort")
        new_names.each_with_index do |raw_name, index|
          name = raw_name.to_s.strip
          model = new_models[index].to_s.strip
          next if name.empty? || model.empty?

          attrs = { "model" => model }
          { "temperature" => new_temps[index], "max_tokens" => new_tokens[index],
            "reasoning_effort" => new_reasoning[index] }.each do |key, value|
            text = value.to_s.strip
            attrs[key] = text unless text.empty?
          end
          begin
            config.set_model_preset(name, attrs)
          rescue ArgumentError => e
            warn "[web] new preset #{name}: #{e.message}"
          end
        end

        default = form(req, "default_preset").to_s.strip
        unless default.empty?
          begin
            config.set_default_model_preset(default)
          rescue ArgumentError => e
            warn "[web] default preset: #{e.message}"
          end
        end

        slugs = form_values(req, "subagent_slug")
        models = form_values(req, "subagent_model_choice")
        thinkings = form_values(req, "subagent_thinking")
        slugs.each_with_index do |slug, index|
          slug = slug.to_s.strip
          next if slug.empty?

          config.set_subagent_settings(slug, {
            "model" => models[index].to_s.strip,
            "thinking" => thinkings[index].to_s.strip
          })
        end
        config.save
      rescue StandardError => e
        warn "[web] save presets: #{e.class}: #{e.message}"
      end

      # Re-fetch the provider's model list and rewrite the on-disk cache, so
      # the pickers on this page (and everywhere else that reads the cache)
      # see the current set instead of a stale snapshot. Nothing is saved to
      # the archive: the catalog is a cache, not a setting.
      def refresh_models(res, req)
        if @app_config
          begin
            Rubot::ModelCatalog.new(config: @app_config).entries
          rescue StandardError => e
            warn "[web] refresh models failed: #{e.class}: #{e.message}"
          end
        end
        redirect_to(res, settings_url)
      end
      alias refresh_model_list refresh_models
      alias refresh_model_catalog refresh_models
      alias refresh_models_list refresh_models
      alias refresh_catalog refresh_models
      alias refresh_models! refresh_models
      alias refresh_model_list! refresh_models
      alias refresh refresh_models

      # Put the saved settings in front of the running process, without a
      # restart: the config is laid over, the pool's copy is refreshed for the
      # actors it spawns next, and the idle actors are dropped so their next turn
      # builds a provider from the new values.
      #
      # A session with a turn in flight is left alone — tearing its actor down
      # mid-answer would lose the answer to save a form — and it picks the
      # setting up on the turn after that.
      def apply_saved_settings
        store = Rubot::Archive.current
        return unless store && @app_config

        @app_config.apply_settings(store.settings)
        return unless @pool

        @pool.refresh_config(@app_config)
        @pool.session_ids.each do |sid|
          next if session_running?(sid)

          @pool.invalidate(sid)
        end
      rescue StandardError => e
        warn "[web] settings applied to this process only: #{e.class}: #{e.message}"
      end

      # The connect card as it should look now. Two callers need it: the SSE
      # broadcast (which needs hx-swap-oob so htmx replaces #ig-status instead
      # of dropping the markup into the notice slot) and the disconnect button's
      # own response (which already has hx-target + outerHTML, so the extra
      # attribute would make htmx swap the same element twice).
      def settings_url(saved: false)
        query = []
        query << "saved=1" if saved
        query << "token=#{CGI.escape(@token)}" if @token
        query.empty? ? "/settings" : "/settings?#{query.join("&")}"
      end

      # The model this persona actually talks to. A preset it inherited from
      # the Telegram wizard still resolves, so the header never shows "default"
      # for a persona that is plainly using something else.
      def persona_model(persona)
        return @app_config&.model.to_s if persona.nil?

        if persona.preset
          preset = @app_config&.model_preset(persona.preset)
          return preset["model"] if preset && preset["model"]
        end

        persona.model || @app_config&.model || "default"
      end

      # What the model picker shows as selected. A persona that only carries a
      # preset is offered the preset's model, because saving the form replaces
      # the preset with an explicit model.
      def persona_model_value(persona)
        return "" unless persona
        return persona.model if persona.model

        preset = persona.preset && @app_config&.model_preset(persona.preset)
        preset ? preset["model"].to_s : ""
      end

      # Every model a persona can be pinned to, by id. The provider's cached
      # catalog comes first because that is where the real choices are;
      # config.yml entries follow as named aliases that still resolve through
      # Config. Nothing here reaches the network.
      # One editable row per built-in sub agent, with its current model and
      # thinking override (blank means it follows the built-in definition).
      def settings_subagent_rows
        config = @app_config
        return [] unless config

        Rubot::SubagentRegistry.slugs.map do |slug|
          settings = config.respond_to?(:subagent_settings) ? config.subagent_settings(slug) : {}
          {
            slug: slug,
            name: Rubot::SubagentRegistry[slug]["name"].to_s,
            model: settings["model"].to_s,
            thinking: settings["thinking"].to_s
          }
        end
      end

      # The model presets as editable rows for the settings page. The implicit
      # `default` preset is built from the direct model fields, so it has no
      # stored attributes to edit here and is left out.
      def settings_preset_rows
        config = @app_config
        return [] unless config

        config.model_preset_names.filter_map do |name|
          next if name.casecmp?("default")

          raw = config.model_presets.find { |key, _| key.to_s.casecmp?(name) }&.last
          next unless raw.is_a?(Hash)

          {
            name: name,
            model: raw["model"].to_s,
            max_tokens: raw["max_tokens"].to_s,
            temperature: raw["temperature"].to_s,
            reasoning_effort: raw["reasoning_effort"].to_s
          }
        end
      end

      def model_choices
        config = @app_config
        return [] unless config

        choices = []
        seen = {}

        ModelCatalog.cached_entries(config.catalog_dir).each do |entry|
          id = entry["id"].to_s
          next if id.empty? || seen[id]

          seen[id] = true
          label = entry["name"].to_s
          choices << { value: id, label: label.empty? || label == id ? id : "#{label} (#{id})" }
        end

        Array(config.models).each do |entry|
          next unless entry.is_a?(Hash)

          name = entry["name"].to_s
          next if name.empty? || seen[name]

          seen[name] = true
          choices << { value: name, label: "#{name} (#{entry['model']})" }
        end

        choices.sort_by { |choice| [ choice[:label].downcase, choice[:value] ] }
      end

      # A model from a form, checked against what the provider and config
      # actually offer so a stale form cannot pin a persona to a model that
      # does not exist. Empty means "follow the default model"; an unknown
      # non-empty name falls back to `fallback` so editing a persona does not
      # quietly wipe the choice it already had.
      def persona_model_from(req, fallback: nil)
        name = form(req, "model").strip
        return nil if name.empty?
        return name if known_model?(name)

        fallback
      end

      # The face a persona form submits, or `fallback` when it names none.
      # The picker offers a fixed roster plus a free field ("Emoji lain…"); the
      # free field wins when it is filled, since that is the only way to say
      # "none of those". Either answer is clipped to a single grapheme — the
      # rail draws a face in a twenty-pixel circle, and a pasted string would
      # overflow it.
      def emoji_from(req, fallback: nil, current: nil)
        custom = form(req, "emoji_custom").strip
        choice = form(req, "emoji").strip
        # The field is filled only when the face in use is not on the roster, so
        # a field that still holds exactly that face was not typed — it is the
        # panel's own echo, and a cell clicked afterwards must win over it.
        typed = custom.empty? || custom == current.to_s ? nil : custom
        clipped = (typed || choice).scan(/\X/).first.to_s
        clipped.empty? ? fallback : clipped
      end

      def known_model?(name)
        config = @app_config
        return false unless config
        return true if config.model_entry_by_name(name)

        ModelCatalog.cached_model_ids(config.catalog_dir).include?(name)
      end

      # The model and thinking level this session runs on, read from the
      # store's meta block rather than from the actor: a turn may be running
      # in it, and the page has to render without waiting for that turn.
      # A persona's default effort, as its edit form shows it: what it stores,
      # or the floor every persona starts from.
      def persona_thinking(persona)
        persona&.thinking || DEFAULT_THINKING
      end

      # A level from the persona form, checked against the ones a model
      # understands. An unknown word falls back to what the persona already
      # had, so a stale form cannot erase the default.
      def persona_thinking_from(req, fallback: nil)
        level = form(req, "thinking").to_s.strip.downcase
        return fallback if level.empty?
        return level if Persona::THINKING_LEVELS.include?(level)

        fallback
      end

      # The tool-row view a posted form asks for. A value the picker cannot
      # produce is not a third mode nothing draws, it is a fallback.
      def persona_tool_output_from(req, fallback: nil)
        mode = form(req, "tool_output").to_s.strip.downcase
        return fallback if mode.empty?
        return mode if Persona::TOOL_OUTPUT_MODES.include?(mode)

        fallback
      end

      # How this conversation draws the tool calls of its turns: its persona's
      # choice, since a call log is noisy in the same way for every turn.
      def session_tool_output(sid)
        persona = persona_store&.[](owner_slug(sid))
        persona ? persona.tool_output : Persona::DEFAULT_TOOL_OUTPUT
      end

      # The model this session runs on. The picker lists real models only, so
      # it has to start on the one the session would actually use: its own
      # override, the persona's, or the config's default.
      def session_model(sid)
        meta = session_meta(sid)
        return meta["model_override"].to_s unless meta["model_override"].to_s.empty?

        persona = persona_store&.[](owner_slug(sid))
        return persona.model if persona && persona.model

        config = @app_config
        return "" unless config

        entry = config.active_model_entry
        name = entry["name"].to_s
        name.empty? ? config.name : name
      end

      # Its own choice, then the persona's default, then the effort the
      # persona's preset carries. There is no "default" entry in the picker, so
      # this always answers a concrete level.
      def session_thinking(sid)
        meta = session_meta(sid)
        return meta["thinking_level"].to_s unless meta["thinking_level"].to_s.empty?

        persona = persona_store&.[](owner_slug(sid))
        return persona.thinking if persona && persona.thinking

        preset = @app_config&.model_preset(persona&.preset)
        level = preset.is_a?(Hash) ? preset["reasoning_effort"].to_s : ""
        return level unless level.empty?

        DEFAULT_THINKING
      end

      def session_meta(sid)
        store = Rubot::Archive.current
        return {} unless store

        store.session_meta(sid)
      end

      # --- personas (create, edit) ---------------------------------------

      # The skills directory as the agent sees it: one tree for the whole
      # install, so what the form lists and what a session may load are the
      # same set of names. The same legacy fallbacks the agent reads are
      # included, or the form would hide skills the prompt still advertises.
      # Scanned per render rather than kept, because a skill installed by hand
      # should show up on the next page load and not on the next restart.
      def skills_for_form
        config = @app_config
        SkillRegistry.new(workspace: config&.skills_workspace,
                          extra_workspaces: config ? config.legacy_skills_workspaces : [])
      end

      # Where a skill has to be dropped to show up in the picker, shortened to
      # ~ so the hint stays one line. The picker is a list of switches, so it
      # says where skills live instead of offering to install one.
      def skills_dir_label
        dir = skills_for_form.skills_dir
        return "" if dir.nil? || dir.to_s.empty?

        home = Dir.home.to_s
        home != "/" && dir.start_with?("#{home}/") ? "~#{dir.delete_prefix(home)}" : dir
      end

      # One row per installed skill, carrying the state both persona forms need:
      # whether this persona has it switched on, and whether the persona
      # requires it (a required skill cannot be switched off from here).
      def persona_skill_choices(persona = nil)
        skills_for_form.all.values.map do |skill|
          {
            name: skill.name,
            description: skill.description.to_s,
            enabled: persona.nil? || persona.skill_enabled?(skill.name),
            required: persona ? Array(persona.skills).include?(skill.name) : false
          }
        end
      end

      # The skills a submitted persona form left unticked, or nil when the form
      # carried no list at all — another editor of the same record, which must
      # not be read as "switched everything off". The list is stored as the
      # exceptions, so a skill installed later is on for every persona until
      # someone decides otherwise.
      def persona_disabled_from(req, required: [])
        return nil unless form_field?(req, "skills_present")

        chosen = form_values(req, "skill")
        skills_for_form.names - chosen - Array(required).map(&:to_s)
      end

      def create_persona(req, res)
        store = persona_store
        return bad_request(res) unless store

        slug = form(req, "slug").strip.downcase.tr(" ", "-")
        unless PersonaStore.valid_slug?(slug) && !known_slug?(slug)
          res.status = 422
          res.body = %(<p class="form-error">Slug tidak valid atau sudah dipakai. Pakai huruf kecil, angka, tanda hubung.</p>)
          return
        end

        prompt = form(req, "system_prompt").strip
        store.set(slug, Persona.new(
          slug: slug,
          name: form(req, "name").strip.empty? ? nil : form(req, "name").strip,
          emoji: emoji_from(req, fallback: Persona::EMOJI_CHOICES.first),
          model: persona_model_from(req),
          thinking: persona_thinking_from(req, fallback: DEFAULT_THINKING),
          tool_output: persona_tool_output_from(req, fallback: Persona::DEFAULT_TOOL_OUTPUT),
          system_prompt: prompt.empty? ? nil : prompt,
          disabled_skills: persona_disabled_from(req)
        ))
        store.prepare_workspace(slug, seed_from: @app_config&.workspace)

        redirect(res, "/p/#{slug}", req)
      end

      # Changing a persona that already exists: its face, its name and the
      # prompt it speaks with. The slug is not one of the fields — it is the
      # key in personas.json and the name of the workspace directory, so
      # renaming it would strand the SOUL.md, skills and memory the persona
      # already owns.
      def edit_persona(req, res, slug)
        store = persona_store
        return bad_request(res) unless store
        return not_found(res) unless known_slug?(slug)

        current = store[slug]
        return not_found(res) unless current

        name = form(req, "name").strip
        emoji = form(req, "emoji").strip
        prompt = form(req, "system_prompt").strip

        # A form without a model field is not asking about the model. `form`
        # cannot tell "absent" from "empty" — both answer "" — so the field's
        # presence is read from the query itself: an editor that only knows
        # name, face and prompt leaves the model and a preset inherited from
        # the Telegram wizard alone, instead of silently dropping both and
        # pinning the persona to the global default.
        keeps_model = !form_field?(req, "model")
        model = keeps_model ? current.model : persona_model_from(req, fallback: current.model)
        keeps_thinking = !form_field?(req, "thinking")
        thinking = keeps_thinking ? current.thinking : persona_thinking_from(req, fallback: current.thinking)
        keeps_tool_output = !form_field?(req, "tool_output")
        tool_output = keeps_tool_output ? current.tool_output : persona_tool_output_from(req, fallback: current.tool_output)

        # The same rule for the skills: a form that posts no list is not
        # saying anything about them, and the personas created by the Telegram
        # wizard never post one.
        disabled_skills = persona_disabled_from(req, required: current.skills)
        disabled_skills = current.disabled_skills if disabled_skills.nil?

        store.set(slug, Persona.new(
          slug: slug,
          name: name.empty? ? nil : name,
          emoji: emoji_from(req, fallback: current.emoji, current: current.emoji),
          accent: current.accent,
          # The picker edits the model itself, so a preset inherited from the
          # Telegram wizard is replaced rather than left to win the tie — but
          # only by a form that actually carries the picker.
          preset: keeps_model ? current.preset : nil,
          model: model,
          thinking: thinking,
          tool_output: tool_output,
          system_prompt: prompt.empty? ? nil : prompt,
          skills: current.skills,
          disabled_skills: disabled_skills,
          ref: current.ref,
          created_at: current.created_at
        ))
        reload_persona_actors(slug)

        redirect(res, return_to(slug, form(req, "session_id").strip), req)
      end

      # Back to the conversation the form was opened from, as long as it is
      # still this persona's; otherwise to the persona's newest one.
      def return_to(slug, sid)
        return "/s/#{sid}" if sid.match?(/\A[a-z0-9][a-z0-9_~-]{0,90}\z/) && owner_slug(sid) == slug

        "/p/#{slug}"
      end

      # An actor that is already spawned holds the old prompt in its agent, so
      # the next turn would still answer in the old voice. Idle sessions are
      # dropped and rebuilt from the store on their next message; a session
      # with a turn in flight is left alone, because invalidating it would kill
      # the answer being written — its next turn picks the edit up instead.
      def reload_persona_actors(slug)
        pool = @pool
        return unless pool

        pool.session_ids.each do |sid|
          next unless owner_slug(sid) == slug
          next if @active[sid]

          begin
            pool.invalidate(sid)
          rescue StandardError => e
            warn "[persona] could not reload #{sid}: #{e.class}: #{e.message}"
          end
        end
      end
      end
    end
  end
end
