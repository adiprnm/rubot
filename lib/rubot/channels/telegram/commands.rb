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
          [ :skip, "ℹ️ Agent Info\n\n" + lines.join("\n") ]
        end

        def handle_context_command
          report = request_agent.usage_report

          context = if report[:context_window]
            "#{UsageReport.tokens(report[:context_used])} / #{UsageReport.tokens(report[:context_window])} token " \
              "(#{format('%.1f', report[:context_percent])}%)"
          else
            "#{UsageReport.tokens(report[:context_used])} token (window tidak diketahui)"
          end

          hit = if report[:last_prompt_tokens].to_i.zero?
            "n/a"
          else
            format("%.1f%%", report[:cache_hit_rate].to_f * 100)
          end

          lines = [ "📊 **Konteks Sesi**" ]
          lines << "Model: `#{report[:model]}` (#{report[:provider]})"
          lines << "Konteks: #{context}"
          lines << "Pesan: #{report[:messages]} | Request: #{report[:requests]}"
          lines << "Token: #{UsageReport.tokens(report[:prompt_tokens])} in / " \
                   "#{UsageReport.tokens(report[:completion_tokens])} out"
          lines << "Cache: #{UsageReport.tokens(report[:cached_tokens])} cached total " \
                   "(hit rate #{hit} on request terakhir)"
          lines << "Re-read: #{UsageReport.tokens(report[:last_re_read_tokens])} token dibayar penuh"

          cost = report[:cost]
          if cost
            source = report[:price_source] ? " [#{report[:price_source]}]" : ""
            bound = cost["cache_price_unknown"] ? " (batas atas)" : ""
            lines << "Estimasi biaya: `$#{UsageReport.money(cost['total'])}`#{bound} " \
                     "(input $#{UsageReport.money(cost['input'])}, " \
                     "cache read $#{UsageReport.money(cost['cached_input'])}, " \
                     "cache write $#{UsageReport.money(cost['cache_creation'])}, " \
                     "output $#{UsageReport.money(cost['output'])})#{source}"
            if cost["saved"].to_f.positive?
              lines << "Dihemat: `$#{UsageReport.money(cost['saved'])}` dari " \
                       "#{UsageReport.tokens(report[:cached_tokens])} token cache"
            end
          else
            lines << "Estimasi biaya: belum tersedia — set `pricing` di preset config.yml"
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
            return [ :skip, "ℹ️ Prompt belum di-pin — pesan berikutnya memang sudah membangunnya dari memory dan skill terbaru." ]
          end

          [ :skip, "🧠 Prompt akan dibangun ulang pada pesan berikutnya — memory, skill, dan AGENTS.md yang berubah ikut masuk.\n\n" \
                    "Ongkosnya: request berikutnya membayar penuh (prefix berubah, jadi cache sekali hangus)." ]
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
            return [ :skip, "🧠 Belum ada model preset.\n\nBuat dengan:\n`/preset set fast deepseek-v4-pro temperature=0.2`" ]
          end

          lines = choices.map do |choice|
            preset = choice["preset"]
            marker = choice["name"].to_s.casecmp?(active_name.to_s) ? "→ " : "  "
            label = choice["name"]
            label += " ★" if choice["primary"]
            "#{marker}**#{label}** (`#{preset['model']}`)"
          end

          text = "🧠 **Model Presets**\n\n" + lines.join("\n")
          text += "\n\nGanti untuk sesi ini: `/model <preset>`"
          text += "\nKelola: `/preset set|default|delete|models`"
          [ :skip, text ]
        end

        def switch_session_preset(name)
          config = persona_config
          preset = config && config.model_preset(name)
          unless preset
            list = preset_choices.map { |choice| "• **#{choice['name']}**" }.join("\n")
            return [ :skip, "❌ Model preset `#{name}` tidak ada.\n\n*Preset tersedia:*\n#{list}" ]
          end

          applied = request_agent.use_model_preset(name, preset: preset)
          unless applied
            return [ :skip, "❌ Gagal mengganti preset ke `#{name}`." ]
          end

          [ :skip, "✅ Sesi ini sekarang memakai preset **#{name}** — model `#{applied['model']}`.\n_Persist sampai /new._" ]
        rescue StandardError => e
          [ :skip, "❌ Error: #{e.message}" ]
        end

        def handle_preset_show(name)
          name = name.to_s.strip
          return [ :skip, preset_usage_text ] if name.empty?

          config = persona_config
          preset = config && config.model_preset(name)
          return [ :skip, "❌ Preset `#{name}` tidak ada." ] unless preset

          [ :skip, preset_detail_text(name, preset) ]
        end

        def handle_preset_set(rest)
          parts = rest.to_s.split(/\s+/)
          name = parts.shift
          if name.to_s.empty?
            return [ :skip, "⚠️ Penggunaan: `/preset set <nama> [model] [temperature=0.2] [max_tokens=4096]`\n\nLihat model yang tersedia dengan `/preset models`." ]
          end

          config = persona_config
          return [ :skip, "❌ Config tidak tersedia." ] unless config

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
            return [ :skip, "⚠️ Preset `#{name}` belum punya model. Sertakan model id: `/preset set #{name} <model>`." ] unless existing

            model = existing["model"]
          end

          known = persona_models.any? do |choice|
            choice["name"] == model || choice["model"] == model || model_id_from_entry(choice) == model
          end
          known ||= !config.model_entry_by_name(model).nil?
          if !known && !persona_models.empty?
            return [ :skip, "❌ Model `#{model}` tidak ada di katalog provider atau config.yml.\n\nCek `/preset models`." ]
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

          text = "✅ Preset **#{preset['name']}** disimpan.\n\n" + preset_detail_text(preset["name"], preset)
          text += "\n\n_Sesi ini memakai preset tersebut; perubahannya langsung diterapkan._" if applied_now
          [ :skip, text ]
        rescue ArgumentError => e
          [ :skip, "❌ #{e.message}" ]
        rescue StandardError => e
          [ :skip, "❌ Gagal menyimpan preset: #{e.message}" ]
        end

        def handle_preset_default(name)
          name = name.to_s.strip
          config = persona_config
          return [ :skip, "❌ Config tidak tersedia." ] unless config

          if name.empty?
            primary = config.primary_model_preset_name
            preset = config.model_preset(primary)
            return [ :skip, "🧠 Belum ada preset default bernama. Sesi baru memakai preset **#{primary}** (`#{preset['model']}`).\n\nAtur dengan `/preset default <nama>` atau `/preset default default` untuk kembali ke model config." ]
          end

          applied = config.set_default_model_preset(name)
          config.save
          refresh_configuration!

          if applied
            preset = config.model_preset(applied)
            [ :skip, "✅ Preset default untuk **sesi baru**: **#{applied}** (`#{preset['model']}`).\n\nSesi yang sedang berjalan tidak diubah; gunakan `/model #{applied}`." ]
          else
            preset = config.model_preset("default")
            [ :skip, "✅ Default kembali ke model config: `#{preset['model']}`.\n\nSesi baru akan memakai preset ini." ]
          end
        rescue ArgumentError => e
          [ :skip, "❌ #{e.message}" ]
        rescue StandardError => e
          [ :skip, "❌ Gagal menyimpan default preset: #{e.message}" ]
        end

        def handle_preset_delete(name)
          name = name.to_s.strip
          return [ :skip, preset_usage_text ] if name.empty?

          config = persona_config
          return [ :skip, "❌ Config tidak tersedia." ] unless config

          removed = config.delete_model_preset(name)
          unless removed
            return [ :skip, "❌ Preset `#{name}` tidak ada." ]
          end

          config.save
          refresh_configuration!

          ra = request_agent
          active = ra.active_model_preset
          if active && active["name"].to_s.casecmp?(name).to_s
            fallback = config.default_model_preset
            ra.use_model_preset(fallback["name"], preset: fallback)
          end

          [ :skip, "🗑️ Preset **#{name}** dihapus.\n\nSesi baru memakai preset **#{config.primary_model_preset_name}**." ]
        rescue StandardError => e
          [ :skip, "❌ Gagal menghapus preset: #{e.message}" ]
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
            return [ :skip, "🧠 Tidak ada model yang cocok. Katalog provider mungkin belum tersedia; model dari config tetap bisa dipakai." ]
          end

          max = 60
          lines = models.first(max).map do |model|
            label = model["label"] || model["name"]
            "• `#{model['name']}` — #{label}"
          end
          text = "🧠 **Model tersedia (#{models.size})**\n\n" + lines.join("\n")
          text += "\n\nBuat preset: `/preset set <nama> <id>`" 
          text += "\n… dan #{models.size - max} lainnya" if models.size > max
          [ :skip, text ]
        end

        def preset_detail_text(name, preset)
          public_preset = persona_config&.public_model_preset(preset) || preset
          lines = [ "🧠 **Preset: #{name}**" ]
          lines << "Model: `#{public_preset['model']}`"
          lines << "Provider: `#{public_preset['provider']}`"
          lines << "Max tokens: `#{public_preset['max_tokens']}`" if public_preset["max_tokens"]
          lines << "Temperature: `#{public_preset['temperature']}`" if public_preset["temperature"]
          lines << "Reasoning effort: `#{public_preset['reasoning_effort']}`" if public_preset["reasoning_effort"]
          lines << "Primary/default: ya" if name.to_s.casecmp?(persona_config&.primary_model_preset_name.to_s)
          lines.join("\n")
        end

        def preset_usage_text
          "🧠 **Penggunaan /preset**\n\n" \
            "/preset — list preset\n" \
            "/preset show <nama> — detail\n" \
            "/preset set <nama> <model> [temperature=0.2] [max_tokens=4096] [provider=openai] [api_base=...] [reasoning_effort=high]\n" \
            "/preset default <nama|default> — preset untuk sesi baru\n" \
            "/preset delete <nama>\n" \
            "/preset models [filter] — model yang didukung provider\n\n" \
            "Ganti preset sesi ini: /model <nama>"
        end

        def handle_skills_command
          ra = request_agent
          registry = ra.skill_registry
          registry.reload!
          return [ :skip, "📚 Skills\n\nNo skills installed.\n\nPlace skills in the workspace `skills/` directory." ] unless registry.any?

          lines = registry.all.values.map do |skill|
            "• **#{skill.name}** — #{skill.summary}"
          end
          [ :skip, "📚 Available Skills (#{registry.count})\n\n" + lines.join("\n") ]
        end

        def handle_memory_command
          ra = request_agent
          return [ :skip, "🧠 Memory is not enabled (no workspace configured)." ] unless ra.memory.enabled?

          content = ra.memory.read
          max_len = DEFAULT_MAX_LENGTH - 200
          content = content[0, max_len] + "\n\n… (truncated)" if content.length > max_len
          [ :skip, "🧠 Memory\n\n```
  #{content}
  ```" ]
        end

        def handle_soul_command
          ra = request_agent
          return [ :skip, "🧬 No soul file (SOUL.md) found in workspace." ] unless ra.soul.enabled?

          content = ra.soul.to_s
          max_len = DEFAULT_MAX_LENGTH - 200
          content = content[0, max_len] + "\n\n… (truncated)" if content.length > max_len
          [ :skip, "🧬 Soul\n\n#{content}" ]
        end

        def handle_agents_command
          ra = request_agent
          return [ :skip, "📋 No AGENTS.md found in workspace." ] unless ra.agents_file.enabled?

          content = ra.agents_file.raw
          max_len = DEFAULT_MAX_LENGTH - 200
          content = content[0, max_len] + "\n\n… (truncated)" if content.length > max_len
          [ :skip, "📋 Agent Rules\n\n```
  #{content}
  ```" ]
        end


        private

        # Handle /use <skill-name> command
        def handle_use_command(skill_name)
          ra = request_agent
          return [ :skip, "⚠️ Usage: /use <skill-name>\n\nAvailable skills:\n#{list_skills_text}" ] if skill_name.nil? || skill_name.empty?

          registry = ra.skill_registry
          registry.reload!
          skill = registry.get(skill_name)

          # /use can name anything installed; a skill this persona switched off
          # is refused here so the refusal is visible, not silent.
          if skill && ra.persona && !ra.persona.skill_enabled?(skill_name)
            return [ :skip, "🚫 Skill '#{skill_name}' is switched off for this persona.\n\nTurn it back on from the persona's skills list." ]
          end

          if skill && skill.enabled?
            ra.session.forced_skill = skill_name
            ra.session.save! if ra.session.respond_to?(:save!)
            [ :skip, "✅ Skill '#{skill_name}' will be used for the next message." ]
          else
            [ :skip, "❌ Skill '#{skill_name}' not found or not enabled.\n\nAvailable skills:\n#{list_skills_text}" ]
          end
        rescue StandardError => e
          [ :skip, "❌ Error: #{e.message}" ]
        end

        # Handle /unuse command
        def handle_unuse_command
          ra = request_agent
          if ra.session.forced_skill
            ra.session.forced_skill = nil
            ra.session.save! if ra.session.respond_to?(:save!)
            [ :skip, "✅ Forced skill cleared." ]
          else
            [ :skip, "ℹ️ No forced skill is set." ]
          end
        rescue StandardError => e
          [ :skip, "❌ Error: #{e.message}" ]
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

          return [ :skip, "Usage: /auto on|off (no argument flips it)." ] if wanted.nil?

          ra.set_auto_approve(wanted)
          if wanted
            [ :skip, "⚡ Auto mode on — non-destructive actions run without asking.\n" \
                      "Destructive patterns (rm -rf /, mkfs, dd onto a device, …) are still refused." ]
          else
            [ :skip, "🛑 Auto mode off — every dangerous action asks first." ]
          end
        rescue StandardError => e
          [ :skip, "❌ Error: #{e.message}" ]
        end

        def list_skills_text
          ra = request_agent
          registry = ra.skill_registry
          registry.reload!
          return "No skills installed." unless registry.any?

          skills = registry.all.values
          persona = ra.persona
          skills = skills.select { |s| persona.skill_enabled?(s.name) } if persona
          return "No skills are switched on for this persona." if skills.empty?

          skills.map { |s| "• **#{s.name}** — #{s.summary}" }.join("\n")
        end
      end
    end
  end
end
