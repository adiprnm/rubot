# frozen_string_literal: true

module Rubot
  module Channels
    class Telegram < Channel
      # The slash commands a reader can type in a topic: what this agent is,
      # how full the context is, what it has spent, and the two commands that
      # change the next request rather than the conversation (/compact, /repin).
      #
      # Each handler returns [ :skip, text ]: the text is the whole answer, so
      # the turn is not forwarded to the model. The dispatch that picks one is
      # in telegram.rb, next to the update loop that calls it.
      module Commands
        def handle_info_command
          ra = request_agent
          info = ra.startup_info
          lines = info.map { |k, v| "#{k}: #{v}" }
          [ :skip, "#{I18n.t("telegram.info.header")}\n\n" + lines.join("\n") ]
        end

        def handle_context_command
          report = request_agent.usage_report

          context = if report[:context_window]
            I18n.t("telegram.context.window",
                   used: UsageReport.tokens(report[:context_used]),
                   window: UsageReport.tokens(report[:context_window]),
                   percent: format("%.1f", report[:context_percent]))
          else
            I18n.t("telegram.context.no_window", used: UsageReport.tokens(report[:context_used]))
          end

          hit = if report[:last_prompt_tokens].to_i.zero?
            "n/a"
          else
            format("%.1f%%", report[:cache_hit_rate].to_f * 100)
          end

          lines = [ I18n.t("telegram.context.header") ]
          lines << I18n.t("telegram.context.model", model: report[:model], provider: report[:provider])
          lines << I18n.t("telegram.context.used", context: context)
          lines << I18n.t("telegram.context.messages", messages: report[:messages], requests: report[:requests])
          lines << I18n.t("telegram.context.tokens",
                          prompt: UsageReport.tokens(report[:prompt_tokens]),
                          completion: UsageReport.tokens(report[:completion_tokens]))
          lines << I18n.t("telegram.context.cache",
                          cached: UsageReport.tokens(report[:cached_tokens]), hit: hit)
          lines << I18n.t("telegram.context.re_read",
                          tokens: UsageReport.tokens(report[:last_re_read_tokens]))

          cost = report[:cost]
          if cost
            source = report[:price_source] ? " [#{report[:price_source]}]" : ""
            bound = cost["cache_price_unknown"] ? I18n.t("telegram.context.bound") : ""
            lines << I18n.t("telegram.context.cost",
                            total: UsageReport.money(cost["total"]), bound: bound, source: source,
                            input: UsageReport.money(cost["input"]),
                            cached_input: UsageReport.money(cost["cached_input"]),
                            cache_creation: UsageReport.money(cost["cache_creation"]),
                            output: UsageReport.money(cost["output"]))
            if cost["saved"].to_f.positive?
              lines << I18n.t("telegram.context.saved", saved: UsageReport.money(cost["saved"]),
                                                       tokens: UsageReport.tokens(report[:cached_tokens]))
            end
          else
            lines << I18n.t("telegram.context.cost_missing")
          end

          [ :skip, lines.join("\n") ]
        end

        def handle_usage_command
          [ :skip, OpencodeUsageReport.render(request_agent.opencode_usage) ]
        end

        def handle_models_command
          handle_preset_list_command
        end

        def handle_compact_command
          result = request_agent.compact_session
          unless result
            return [ :skip, "ℹ️ #{I18n.t("compaction.empty")}" ]
          end

          lines = [ "🗜️ **#{I18n.t("compaction.title")}**" ]
          lines << I18n.t("compaction.summarized", count: result[:summarized_messages])
          lines << I18n.t("compaction.kept", count: result[:kept_messages])
          lines << I18n.t("compaction.context", before: result[:context_before], after: result[:context_after])
          [ :skip, lines.join("\n") ]
        end

        def handle_repin_command
          # The prompt is pinned so the cached prefix survives a memory write;
          # this is the door, and the price is stated with the answer because it
          # arrives on the next request, not this one.
          changed = request_agent.respond_to?(:repin_system_prompt) &&
                    request_agent.repin_system_prompt
          unless changed
            return [ :skip, I18n.t("telegram.repin.missing") ]
          end

          [ :skip, I18n.t("telegram.repin.rebuilt") ]
        end

        def handle_model_command(args = nil)
          args = args.to_s.strip
          return handle_preset_list_command if args.empty?

          switch_session_preset(args)
        end

        def handle_use_model_command(model_name)
          # Backwards-compatible alias for /model <preset>.
          handle_model_command(model_name)
        end

        def refresh_configuration!
          @persona_store = nil
          config = persona_config
          return unless config

          @pool.refresh_config(config) if @pool.respond_to?(:refresh_config)
        end

        def handle_preset_command(args)
          args = args.to_s.strip
          return handle_preset_list_command if args.empty? || args.casecmp?("list")

          command, rest = args.split(/\s+/, 2)
          case command.to_s.downcase
          when "list"
            handle_preset_list_command
          when "show"
            handle_preset_show(rest)
          when "set"
            handle_preset_set(rest)
          when "default", "primary"
            handle_preset_default(rest)
          when "delete", "remove"
            handle_preset_delete(rest)
          when "models"
            handle_preset_models(rest)
          else
            [ :skip, preset_usage_text ]
          end
        end

        def handle_preset_list_command
          ra = request_agent
          active = ra.active_model_preset
          active_name = active && active["name"]
          choices = preset_choices

          if choices.empty?
            return [ :skip, I18n.t("telegram.preset.empty") ]
          end

          lines = choices.map do |choice|
            preset = choice["preset"]
            marker = choice["name"].to_s.casecmp?(active_name.to_s) ? "→ " : "  "
            label = choice["name"]
            label += " ★" if choice["primary"]
            "#{marker}**#{label}** (`#{preset['model']}`)"
          end

          text = "#{I18n.t("telegram.preset.header")}\n\n" + lines.join("\n")
          [ :skip, text + I18n.t("telegram.preset.list_footer") ]
        end

        def switch_session_preset(name)
          config = persona_config
          preset = config && config.model_preset(name)
          unless preset
            list = preset_choices.map { |choice| "• **#{choice['name']}**" }.join("\n")
            return [ :skip, I18n.t("telegram.preset.missing", name: name, list: list) ]
          end

          applied = request_agent.use_model_preset(name, preset: preset)
          unless applied
            return [ :skip, I18n.t("telegram.preset.switch_failed", name: name) ]
          end

          [ :skip, I18n.t("telegram.preset.switched", name: name, model: applied["model"]) ]
        rescue StandardError => e
          [ :skip, I18n.t("telegram.error", message: e.message) ]
        end

        def handle_preset_show(name)
          name = name.to_s.strip
          return [ :skip, preset_usage_text ] if name.empty?

          config = persona_config
          preset = config && config.model_preset(name)
          return [ :skip, I18n.t("telegram.preset.show_missing", name: name) ] unless preset

          [ :skip, preset_detail_text(name, preset) ]
        end

        def handle_preset_set(rest)
          parts = rest.to_s.split(/\s+/)
          name = parts.shift
          if name.to_s.empty?
            return [ :skip, I18n.t("telegram.preset.set_usage") ]
          end

          config = persona_config
          return [ :skip, I18n.t("telegram.preset.no_config") ] unless config

          model = nil
          attributes = {}
          parts.each do |token|
            key, value = token.split("=", 2)
            if value.nil?
              model ||= token
            else
              attributes[key.to_s.downcase] = value
            end
          end
          model ||= attributes.delete("model")
          provided_model = model

          if model.nil?
            existing = config.model_preset(name)
            unless existing
              return [ :skip, I18n.t("telegram.preset.set_needs_model", name: name) ]
            end

            model = existing["model"]
          end

          known = persona_models.any? do |choice|
            choice["name"] == model || choice["model"] == model || model_id_from_entry(choice) == model
          end
          known ||= !config.model_entry_by_name(model).nil?
          if !known && !persona_models.empty?
            return [ :skip, I18n.t("telegram.preset.unknown_model", model: model) ]
          end

          attributes["model"] = provided_model if provided_model

          preset = config.set_model_preset(name, attributes)
          config.save
          refresh_configuration!

          # If this preset is active in the current session, apply the new
          # settings immediately instead of waiting for a restart.
          ra = request_agent
          active = ra.active_model_preset
          applied_now = active && active["name"].to_s.casecmp?(preset["name"]).to_s
          ra.use_model_preset(preset["name"], preset: preset) if applied_now

          text = I18n.t("telegram.preset.saved", name: preset["name"],
                                                detail: preset_detail_text(preset["name"], preset))
          text += I18n.t("telegram.preset.saved_active") if applied_now
          [ :skip, text ]
        rescue ArgumentError => e
          [ :skip, "❌ #{e.message}" ]
        rescue StandardError => e
          [ :skip, I18n.t("telegram.preset.save_failed", message: e.message) ]
        end

        def handle_preset_default(name)
          name = name.to_s.strip
          config = persona_config
          return [ :skip, I18n.t("telegram.preset.no_config") ] unless config

          if name.empty?
            primary = config.primary_model_preset_name
            preset = config.model_preset(primary)
            return [ :skip, I18n.t("telegram.preset.default_none", name: primary, model: preset["model"]) ]
          end

          applied = config.set_default_model_preset(name)
          config.save
          refresh_configuration!

          if applied
            preset = config.model_preset(applied)
            [ :skip, I18n.t("telegram.preset.default_set", name: applied, model: preset["model"]) ]
          else
            preset = config.model_preset("default")
            [ :skip, I18n.t("telegram.preset.default_config", model: preset["model"]) ]
          end
        rescue ArgumentError => e
          [ :skip, "❌ #{e.message}" ]
        rescue StandardError => e
          [ :skip, I18n.t("telegram.preset.default_failed", message: e.message) ]
        end

        def handle_preset_delete(name)
          name = name.to_s.strip
          return [ :skip, preset_usage_text ] if name.empty?

          config = persona_config
          return [ :skip, I18n.t("telegram.preset.no_config") ] unless config

          removed = config.delete_model_preset(name)
          unless removed
            return [ :skip, I18n.t("telegram.preset.show_missing", name: name) ]
          end

          config.save
          refresh_configuration!

          ra = request_agent
          active = ra.active_model_preset
          if active && active["name"].to_s.casecmp?(name).to_s
            fallback = config.default_model_preset
            ra.use_model_preset(fallback["name"], preset: fallback)
          end

          [ :skip, I18n.t("telegram.preset.deleted", name: name,
                                                     primary: config.primary_model_preset_name) ]
        rescue StandardError => e
          [ :skip, I18n.t("telegram.preset.delete_failed", message: e.message) ]
        end

        def handle_preset_models(filter)
          models = persona_models
          filter = filter.to_s.strip.downcase
          unless filter.empty?
            models = models.select do |model|
              [ model["name"], model["model"], model["label"] ].compact.any? { |value| value.to_s.downcase.include?(filter) }
            end
          end

          if models.empty?
            return [ :skip, I18n.t("telegram.preset.models_empty") ]
          end

          max = 60
          lines = models.first(max).map do |model|
            label = model["label"] || model["name"]
            "• `#{model['name']}` — #{label}"
          end
          text = "#{I18n.t("telegram.preset.models_header", count: models.size)}\n\n" + lines.join("\n")
          text += I18n.t("telegram.preset.models_hint")
          text += I18n.t("telegram.preset.models_more", count: models.size - max) if models.size > max
          [ :skip, text ]
        end

        def preset_detail_text(name, preset)
          public_preset = persona_config&.public_model_preset(preset) || preset
          lines = [ I18n.t("telegram.preset.detail.header", name: name) ]
          lines << I18n.t("telegram.preset.detail.model", model: public_preset["model"])
          lines << I18n.t("telegram.preset.detail.provider", provider: public_preset["provider"])
          if public_preset["max_tokens"]
            lines << I18n.t("telegram.preset.detail.max_tokens", value: public_preset["max_tokens"])
          end
          if public_preset["temperature"]
            lines << I18n.t("telegram.preset.detail.temperature", value: public_preset["temperature"])
          end
          if public_preset["reasoning_effort"]
            lines << I18n.t("telegram.preset.detail.reasoning", value: public_preset["reasoning_effort"])
          end
          if name.to_s.casecmp?(persona_config&.primary_model_preset_name.to_s)
            lines << I18n.t("telegram.preset.detail.primary")
          end
          lines.join("\n")
        end

        def preset_usage_text
          I18n.t("telegram.preset.usage")
        end

        def handle_skills_command
          ra = request_agent
          registry = ra.skill_registry
          registry.reload!
          return [ :skip, I18n.t("telegram.skills.none") ] unless registry.any?

          lines = registry.all.values.map do |skill|
            "• **#{skill.name}** — #{skill.summary}"
          end
          [ :skip, "#{I18n.t("telegram.skills.header", count: registry.count)}\n\n" + lines.join("\n") ]
        end

        def handle_memory_command
          ra = request_agent
          return [ :skip, I18n.t("telegram.memory.disabled") ] unless ra.memory.enabled?

          content = ra.memory.read
          max_len = DEFAULT_MAX_LENGTH - 200
          content = content[0, max_len] + "\n\n" + I18n.t("telegram.truncated") if content.length > max_len
          [ :skip, "#{I18n.t("telegram.memory.header")}\n\n```\n  #{content}\n  ```" ]
        end

        def handle_soul_command
          ra = request_agent
          return [ :skip, I18n.t("telegram.soul.disabled") ] unless ra.soul.enabled?

          content = ra.soul.to_s
          max_len = DEFAULT_MAX_LENGTH - 200
          content = content[0, max_len] + "\n\n" + I18n.t("telegram.truncated") if content.length > max_len
          [ :skip, "#{I18n.t("telegram.soul.header")}\n\n#{content}" ]
        end

        def handle_agents_command
          ra = request_agent
          return [ :skip, I18n.t("telegram.agents.disabled") ] unless ra.agents_file.enabled?

          content = ra.agents_file.raw
          max_len = DEFAULT_MAX_LENGTH - 200
          content = content[0, max_len] + "\n\n" + I18n.t("telegram.truncated") if content.length > max_len
          [ :skip, "#{I18n.t("telegram.agents.header")}\n\n```\n  #{content}\n  ```" ]
        end


        private

        # Handle /use <skill-name> command
        def handle_use_command(skill_name)
          ra = request_agent
          if skill_name.nil? || skill_name.empty?
            return [ :skip, I18n.t("telegram.use.usage", skills: list_skills_text) ]
          end

          registry = ra.skill_registry
          registry.reload!
          skill = registry.get(skill_name)

          # /use can name anything installed; a skill this persona switched off
          # is refused here so the refusal is visible, not silent.
          if skill && ra.persona && !ra.persona.skill_enabled?(skill_name)
            return [ :skip, I18n.t("telegram.use.refused", name: skill_name) ]
          end

          if skill && skill.enabled?
            ra.session.forced_skill = skill_name
            ra.session.save! if ra.session.respond_to?(:save!)
            [ :skip, I18n.t("telegram.use.applied", name: skill_name) ]
          else
            [ :skip, I18n.t("telegram.use.missing", name: skill_name, skills: list_skills_text) ]
          end
        rescue StandardError => e
          [ :skip, I18n.t("telegram.error", message: e.message) ]
        end

        # Handle /unuse command
        def handle_unuse_command
          ra = request_agent
          if ra.session.forced_skill
            ra.session.forced_skill = nil
            ra.session.save! if ra.session.respond_to?(:save!)
            [ :skip, I18n.t("telegram.use.cleared") ]
          else
            [ :skip, I18n.t("telegram.use.none") ]
          end
        rescue StandardError => e
          [ :skip, I18n.t("telegram.error", message: e.message) ]
        end

        # Auto mode: run anything the safety guard allows without asking. The
        # destructive patterns inside the guard still refuse, so this skips the
        # question, not the check. The choice is written to config.yml and shared
        # with the TUI.
        def handle_auto_command(argument)
          ra = request_agent
          current = ra.respond_to?(:auto_approve?) ? !!ra.auto_approve? : false
          word = argument.to_s.strip.downcase
          wanted = if word.empty?
            !current
          elsif AUTO_TOGGLE.key?(word)
            AUTO_TOGGLE[word]
          end

          return [ :skip, I18n.t("telegram.auto.usage") ] if wanted.nil?

          ra.set_auto_approve(wanted)
          if wanted
            [ :skip, I18n.t("telegram.auto.on") ]
          else
            [ :skip, I18n.t("telegram.auto.off") ]
          end
        rescue StandardError => e
          [ :skip, I18n.t("telegram.error", message: e.message) ]
        end

        def list_skills_text
          ra = request_agent
          registry = ra.skill_registry
          registry.reload!
          return I18n.t("telegram.skills.list_empty") unless registry.any?

          skills = registry.all.values
          persona = ra.persona
          skills = skills.select { |s| persona.skill_enabled?(s.name) } if persona
          return I18n.t("telegram.skills.list_none_enabled") if skills.empty?

          skills.map { |s| "• **#{s.name}** — #{s.summary}" }.join("\n")
        end
      end
    end
  end
end
