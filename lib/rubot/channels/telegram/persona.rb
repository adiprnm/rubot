# frozen_string_literal: true

module Rubot
  module Channels
    class Telegram < Channel
      # Where a topic's persona comes from and what it resolves to: the store
      # that remembers which persona a topic borrows or built, the workspaces
      # behind each persona, the model catalog and the presets the wizard
      # offers, and the session ids and command shapes that are derived from
      # a chat/thread pair.
      #
      # Nothing here talks to Telegram. These are lookups over config, the
      # persona store and the model catalog, which is what lets the wizard,
      # /persona and the message path all ask the same questions.
      module PersonaDirectory
        private

        def persona_store
          @persona_store ||= begin
            config = persona_config
            PersonaStore.new(
              dir: persona_dir,
              legacy_workspace: persona_workspace,
              available_models: persona_models.map { |model| model["name"] },
              available_presets: config ? config.model_preset_names : [ "default" ]
            )
          end
        end

        # Personas live next to config.yml so the web channel and this one read
        # the same file. Telegram topics keep model + prompt only and never get a
        # workspace of their own.
        def persona_dir
          config = persona_config
          return File.dirname(config.config_path) if config

          File.join(Dir.home, ".rubot")
        end

        def persona_workspace
          return @app_config.workspace if @app_config
          return @pool.workspace if @pool.respond_to?(:workspace) && @pool.workspace
          return @agent.config.workspace if @agent.respond_to?(:config) && @agent.config

          File.join(Dir.home, ".rubot", "workspace")
        end

        # The directory a session's agent actually runs in: the persona's own
        # when it has one, the default workspace otherwise. The cron tool needs
        # it to file a reminder where it was written.
        def session_workspace(session_id)
          rooted = @pool.workspace_for_session(session_id) if actor_mode? && @pool.respond_to?(:workspace_for_session)
          rooted || persona_workspace
        end

        def persona_config
          @app_config || (@agent.respond_to?(:config) ? @agent.config : nil)
        end

        def model_catalog
          return @model_catalog if @model_catalog

          config = persona_config
          return nil unless config

          @model_catalog = ModelCatalog.new(config: config)
        end

        # Config model entries (the fallback when the provider cannot list models).
        def config_model_entries
          config = persona_config
          models = if config
            config.models
          elsif @pool.respond_to?(:models)
            @pool.models
          else
            []
          end
          models.is_a?(Array) ? models.select { |model| model.is_a?(Hash) && model["name"] } : []
        end

        # The provider's /models catalog plus any config entries that are not
        # represented there. Each choice:
        #   "name"  => value stored on the persona (config name or provider id)
        #   "model" => provider model id (or "openai/..." for config entries)
        #   "label" => human-friendly name for the button
        def persona_models
          config_entries = config_model_entries
          catalog = model_catalog&.entries || []

          if catalog.empty?
            return config_entries.map do |entry|
              { "name" => entry["name"], "model" => entry["model"], "label" => entry["name"] }
            end
          end

          catalog_ids = catalog.to_h { |model| [ model["id"], true ] }
          choices = catalog.map do |model|
            { "name" => model["id"], "model" => model["id"], "label" => model["name"] }
          end

          config_entries.each do |entry|
            next if catalog_ids[model_id_from_entry(entry)]

            choices << { "name" => entry["name"], "model" => entry["model"], "label" => entry["name"] }
          end

          choices
        end

        def model_id_from_entry(entry)
          model = entry["model"].to_s
          model.include?("/") ? model.split("/").last : model
        end

        # Model presets, with the configured primary/default marked.
        def preset_choices
          config = persona_config
          return [] unless config

          primary = config.primary_model_preset_name
          names = config.model_preset_names
          # Do not list a separate implicit `default` when a named preset is
          # already the primary; they would resolve to the same model.
          names = names.reject { |name| name.casecmp?("default") } unless primary.casecmp?("default")

          names.filter_map do |name|
            preset = config.model_preset(name)
            next unless preset

            { "name" => name, "preset" => preset, "primary" => name.casecmp?(primary) }
          end
        end

        def preset_choice(name)
          wanted = name.to_s
          preset_choices.find { |choice| choice["name"].casecmp?(wanted) }
        end

        def persona_preset_label(name)
          return "(default)" if name.nil? || name.to_s.empty?

          config = persona_config
          preset = config&.model_preset(name)
          return name.to_s unless preset

          label = name.to_s
          label += " (primary)" if name.casecmp?(config.primary_model_preset_name)
          "#{label} (`#{preset['model']}`)"
        end

        def topic_session_id(chat_id, thread_id)
          thread_id ? "tg_#{chat_id}_#{thread_id}" : "tg_#{chat_id}"
        end

        def persona_topic_key(chat_id, thread_id)
          "#{chat_id}:#{thread_id}"
        end

        # Parse /persona and /cancel, tolerating the @BotName suffix groups add.
        def persona_command(text)
          normalized = text.strip.sub(/\A(\/[A-Za-z0-9_]+)@\S+/, '\\1')

          case normalized
          when %r{\A/persona(?:\s+(.*))?\z}i
            { name: "/persona", args: Regexp.last_match(1)&.strip }
          when %r{\A/cancel(?:\s+.*)?\z}i
            { name: "/cancel", args: nil }
          when %r{\A/stop(?:\s+.*)?\z}i
            { name: "/stop", args: nil }
          end
        end

        # Sessions are central (next to config.yml), not in the workspace, so
        # this must not look in `persona_workspace/sessions` — that path stopped
        # being where sessions live and every topic then looked brand new.
        def sessions_dir
          config = persona_config
          return config.sessions_dir if config.respond_to?(:sessions_dir)

          File.join(persona_dir, "sessions")
        end
      end
    end
  end
end
