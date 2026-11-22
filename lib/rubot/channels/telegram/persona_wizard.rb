# frozen_string_literal: true

module Rubot
  module Channels
    class Telegram < Channel
      # The per-topic persona wizard: /persona and the three steps behind it
      # (which model preset, which system prompt, then a preview to confirm).
      #
      # The state is one Hash per topic in @persona_wizards, keyed by
      # "chat:thread" and guarded by @persona_mutex, because a wizard is not
      # one turn: a button press arrives first, then the reply that carries
      # the prompt, then another button press, and each update is handled on
      # its own.
      module PersonaWizard
        private

        def handle_persona_command(chat_id, thread_id, args)
          case args.to_s.strip.downcase
          when ""
            start_persona_wizard(chat_id, thread_id)
          when "show"
            show_persona(chat_id, thread_id)
          when "reset"
            reset_persona(chat_id, thread_id)
          else
            send_message(
              chat_id,
              "🧬 Penggunaan:\n/persona — buka setup persona\n/persona show — lihat persona topic ini\n/persona reset — hapus persona topic ini",
              thread_id
            )
          end
        end

        def show_persona(chat_id, thread_id)
          if thread_id.nil?
            send_message(chat_id, "🧬 Topic General memakai persona default (config global).", thread_id)
            return
          end

          persona = persona_store.get(chat_id, thread_id)
          unless persona
            send_message(chat_id, "🧬 Belum ada persona untuk topic ini. Ketik /persona untuk membuatnya.", thread_id)
            return
          end

          # The resolved persona is the one that runs; the stored entry says
          # whether it is borrowed or this topic's own.
          stored = persona_store.all[persona_topic_key(chat_id, thread_id)]
          send_message(chat_id, persona_summary(persona, ref: stored&.ref), thread_id)
        end

        def reset_persona(chat_id, thread_id)
          if thread_id.nil?
            send_message(chat_id, "🧬 Topic General memakai persona default (config global).", thread_id)
            return
          end

          removed = persona_store.delete(persona_topic_key(chat_id, thread_id))
          apply_persona_to_session(topic_session_id(chat_id, thread_id), nil)
          dropped = drop_topic_reminders(chat_id, thread_id)

          text = removed ? "✅ Persona topic ini dihapus. Model kembali ke default." : "ℹ️ Topic ini memang belum punya persona."
          text += "\n⏰ #{dropped} reminder topic ini ikut dihapus — reminder itu ditulis dengan memory persona yang sekarang sudah tidak dipakai." if dropped.positive?
          send_message(chat_id, text, thread_id)
        rescue StandardError => e
          warn "[persona] reset failed: #{e.class}: #{e.message}"
          send_message(chat_id, "❌ Gagal menghapus persona: #{e.message}", thread_id)
        end

        # A reminder written from a persona's topic was written with that
        # persona's memory. Once the persona is gone it would fire into a session
        # that can no longer answer in the same voice, so it goes too.
        def drop_topic_reminders(chat_id, thread_id)
          return 0 unless actor_mode? && @pool.respond_to?(:remove_cron_jobs_for)

          @pool.remove_cron_jobs_for(chat_id: chat_id, thread_id: thread_id)
        rescue StandardError => e
          warn "[persona] could not clear reminders: #{e.class}: #{e.message}"
          0
        end

        # A topic that has no persona and no session file has never been used, so
        # this is the first message in it. Used when forum_topic_created is not
        # delivered to the bot.
        def maybe_start_persona_wizard_for_new_topic(chat_id, thread_id)
          return unless thread_id
          return if persona_store.get(chat_id, thread_id)
          return if wizard_for_topic(chat_id, thread_id)
          return if topic_session_exists?(chat_id, thread_id)

          start_persona_wizard(chat_id, thread_id, only_if_new: true)
        end

        def topic_session_exists?(chat_id, thread_id)
          sid = topic_session_id(chat_id, thread_id)
          return true if (store = Session.store) && store.session?(sid)

          path = File.join(sessions_dir, "#{sid}.json")
          File.exist?(path)
        end

        # Open the wizard. `only_if_new` keeps repeated forum_topic_created
        # service messages (or a topic that already has a persona) from
        # reopening it.
        def start_persona_wizard(chat_id, thread_id, only_if_new: false)
          if thread_id.nil?
            unless only_if_new
              send_message(chat_id, "🧬 Persona hanya tersedia di forum topic. Topic General memakai persona default.", thread_id)
            end
            return nil
          end

          return nil if only_if_new && persona_store.get(chat_id, thread_id)

          prune_persona_wizards!

          wizard = {
            id: SecureRandom.hex(4),
            chat_id: chat_id,
            thread_id: thread_id,
            session_id: topic_session_id(chat_id, thread_id),
            step: :preset,
            preset: nil,
            prompt: nil,
            presets: nil,
            message_id: nil,
            updated_at: Time.now
          }

          key = persona_topic_key(chat_id, thread_id)
          previous = @persona_mutex.synchronize do
            old = @persona_wizards.delete(key)
            @persona_wizards[key] = wizard
            old
          end
          delete_wizard_message(previous)

          # A topic may borrow a persona that already exists — the usual case
          # once a specialist is set up — so the first question is which one,
          # not which model. With nothing to borrow, go straight to building one.
          if persona_choices.any?
            send_persona_source_step(wizard)
          else
            send_persona_model_step(wizard)
          end
          wizard
        end

        # The specialists a topic can be pointed at: every persona that owns a
        # workspace. Taken from the store, so a persona created in the web UI is
        # offered here without a restart.
        def persona_choices
          persona_store.specialists.map do |slug, persona|
            { "slug" => slug, "label" => "#{persona.emoji_or} #{persona.label}".strip }
          end
        rescue StandardError => e
          warn "[persona] could not list personas: #{e.class}: #{e.message}"
          []
        end

        def send_persona_source_step(wizard)
          choices = persona_choices
          @persona_mutex.synchronize do
            wizard[:choices] = choices
            wizard[:step] = :source
          end

          text = "🧬 Persona untuk topic ini\n\n" \
                 "Pakai persona yang sudah ada (memory-nya ikut, sesi tidak), " \
                 "atau buat persona baru khusus topic ini:"

          keyboard = choices.each_with_index.each_slice(2).map do |slice|
            slice.map do |choice, index|
              { "text" => truncate(choice["label"].to_s, 28),
                "callback_data" => "persona:#{wizard[:id]}:use:#{index}" }
            end
          end
          keyboard << [ { "text" => "➕ Buat persona baru", "callback_data" => "persona:#{wizard[:id]}:new" } ]
          keyboard << [ { "text" => "❌ Batal", "callback_data" => "persona:#{wizard[:id]}:cancel" } ]

          store_wizard_message(wizard, send_keyboard_message(wizard[:chat_id], text, wizard[:thread_id], keyboard))
        end

        # Consume the reply to step 2 (the system prompt). Returns true when the
        # text was handled by the wizard and must not reach the agent.
        def intercept_persona_prompt(chat_id, thread_id, text)
          wizard = wizard_for_topic(chat_id, thread_id)
          return false unless wizard
          return false unless wizard[:step] == :prompt
          return false if text.strip.start_with?("/")

          @persona_mutex.synchronize do
            wizard[:prompt] = text.strip
            wizard[:step] = :preview
            wizard[:updated_at] = Time.now
          end

          delete_wizard_message(wizard)
          send_persona_preview_step(wizard)
          true
        end

        def send_persona_model_step(wizard)
          presets = preset_choices
          @persona_mutex.synchronize { wizard[:presets] = presets }

          text = "🧬 Setup persona untuk topic ini\n\nLangkah 1/3 — Pilih model preset:"
          if presets.any?
            text += "\n\n" + presets.map do |choice|
              label = choice["name"]
              label += " (primary)" if choice["primary"] && !choice["name"].casecmp?("primary")
              label += " ★" if choice["primary"] && choice["name"].casecmp?("primary")
              "• #{label} — #{choice['preset']['model']}"
            end.join("\n")
          else
            text += "\n\nBelum ada preset. Pakai default dulu, atau buat preset dengan /preset set <nama> <model>."
          end

          keyboard = presets.each_with_index.each_slice(2).map do |slice|
            slice.map do |choice, index|
              label = choice["name"]
              label += " ★" if choice["primary"]
              {
                "text" => truncate(label.to_s, 28),
                "callback_data" => "persona:#{wizard[:id]}:preset:#{index}"
              }
            end
          end
          keyboard << [ { "text" => "Pakai default", "callback_data" => "persona:#{wizard[:id]}:preset:default" } ]
          keyboard << [ { "text" => "❌ Batal", "callback_data" => "persona:#{wizard[:id]}:cancel" } ]

          store_wizard_message(wizard, send_keyboard_message(wizard[:chat_id], text, wizard[:thread_id], keyboard))
        end

        def send_persona_prompt_step(wizard)
          text = "🧬 Setup persona untuk topic ini\n\n" \
                 "Langkah 2/3 — Kirim system prompt (balas dengan teks):\n\n" \
                 "Ketik system prompt untuk persona ini, atau tekan tombol di bawah untuk memakai prompt default."
          keyboard = [
            [ { "text" => "Lewati / pakai default", "callback_data" => "persona:#{wizard[:id]}:prompt_default" } ],
            [ { "text" => "❌ Batal", "callback_data" => "persona:#{wizard[:id]}:cancel" } ]
          ]

          store_wizard_message(wizard, send_keyboard_message(wizard[:chat_id], text, wizard[:thread_id], keyboard))
        end

        def send_persona_preview_step(wizard)
          model = persona_preset_label(wizard[:preset])
          prompt = wizard[:prompt].to_s.strip
          prompt = "(default)" if prompt.empty?
          prompt = "#{prompt[0, 700]}…" if prompt.length > 700

          text = "🧬 Setup persona untuk topic ini\n\nLangkah 3/3 — Preview:\n\n" \
                 "Model : #{model}\n" \
                 "Prompt: #{prompt}"
          keyboard = [
            [
              { "text" => "✅ Simpan", "callback_data" => "persona:#{wizard[:id]}:save" },
              { "text" => "✏️ Ulangi", "callback_data" => "persona:#{wizard[:id]}:back" }
            ],
            [ { "text" => "❌ Batal", "callback_data" => "persona:#{wizard[:id]}:cancel" } ]
          ]

          store_wizard_message(wizard, send_keyboard_message(wizard[:chat_id], text, wizard[:thread_id], keyboard))
        end

        def store_wizard_message(wizard, message_id)
          @persona_mutex.synchronize do
            wizard[:message_id] = message_id
            wizard[:updated_at] = Time.now
          end
        end

        def delete_wizard_message(wizard)
          return unless wizard

          message_id = @persona_mutex.synchronize do
            id = wizard[:message_id]
            wizard[:message_id] = nil
            id
          end
          delete_message(wizard[:chat_id], message_id, wizard[:thread_id]) if message_id
        end

        def wizard_for_topic(chat_id, thread_id)
          return nil if thread_id.nil?

          key = persona_topic_key(chat_id, thread_id)
          prune_persona_wizards!

          @persona_mutex.synchronize { @persona_wizards[key] }
        end

        def wizard_for_id(id)
          prune_persona_wizards!

          @persona_mutex.synchronize do
            @persona_wizards.values.find { |wizard| wizard[:id] == id }
          end
        end

        def prune_persona_wizards!
          now = Time.now

          @persona_mutex.synchronize do
            @persona_wizards.delete_if do |_key, wizard|
              now - wizard[:updated_at] > PERSONA_WIZARD_TTL
            end
          end
        end

        def remove_persona_wizard(wizard)
          key = persona_topic_key(wizard[:chat_id], wizard[:thread_id])

          @persona_mutex.synchronize do
            @persona_wizards.delete(key) if @persona_wizards[key].equal?(wizard)
          end
        end

        def cancel_persona_wizard(chat_id, thread_id)
          return false if thread_id.nil?

          key = persona_topic_key(chat_id, thread_id)
          wizard = @persona_mutex.synchronize { @persona_wizards.delete(key) }
          return false unless wizard

          delete_wizard_message(wizard)
          true
        end

        def handle_persona_callback(callback_query)
          data = callback_query["data"].to_s
          parts = data.split(":")
          unless parts.size >= 3
            answer_callback_query(callback_query["id"])
            return
          end

          wizard = wizard_for_id(parts[1])
          action = parts[2]
          argument = parts[3]

          unless wizard
            answer_callback_query(callback_query["id"], "Wizard sudah kedaluwarsa. Ketik /persona untuk memulai lagi.")
            return
          end

          @persona_mutex.synchronize { wizard[:updated_at] = Time.now }

          case action
          when "use"
            apply_existing_persona(callback_query, wizard, argument)
          when "new"
            @persona_mutex.synchronize { wizard[:step] = :preset }
            delete_wizard_message(wizard)
            send_persona_model_step(wizard)
            answer_callback_query(callback_query["id"])
          when "preset", "model"
            apply_persona_preset_choice(callback_query, wizard, argument)
          when "prompt_default"
            @persona_mutex.synchronize do
              wizard[:prompt] = nil
              wizard[:step] = :preview
            end
            delete_wizard_message(wizard)
            send_persona_preview_step(wizard)
            answer_callback_query(callback_query["id"])
          when "back"
            @persona_mutex.synchronize do
              wizard[:step] = :preset
              wizard[:prompt] = nil
            end
            delete_wizard_message(wizard)
            send_persona_model_step(wizard)
            answer_callback_query(callback_query["id"])
          when "save"
            save_persona_wizard(wizard)
            answer_callback_query(callback_query["id"], "Persona disimpan.")
          when "cancel"
            cancel_persona_wizard(wizard[:chat_id], wizard[:thread_id])
            answer_callback_query(callback_query["id"], "Setup dibatalkan.")
          else
            answer_callback_query(callback_query["id"])
          end
        end

        # Point this topic at a persona that already exists. The topic keeps its
        # own session (its own conversation and history); what it borrows is the
        # persona — model, prompt, skills and, because the workspace root is what
        # decides it, the same MEMORY.md.
        def apply_existing_persona(callback_query, wizard, argument)
          choices = @persona_mutex.synchronize { Array(wizard[:choices]) }
          choice = choices[argument.to_i]

          unless choice
            answer_callback_query(callback_query["id"],
                                  "Daftar persona berubah. Ketik /persona untuk mengulang.")
            return
          end

          key = persona_topic_key(wizard[:chat_id], wizard[:thread_id])
          stored = persona_store.set(key, Persona.new(ref: choice["slug"]))
          apply_persona_to_session(wizard[:session_id], stored)

          delete_wizard_message(wizard)
          remove_persona_wizard(wizard)
          answer_callback_query(callback_query["id"], "Persona dipasang.")
          send_message(
            wizard[:chat_id],
            "✅ Topic ini kini memakai persona #{choice['label'].to_s.strip} (#{choice['slug']}).\n\n" \
            "Memory-nya dipakai bersama dengan persona itu; sesinya tetap milik topic ini.",
            wizard[:thread_id]
          )
        end

        # Set (or clear) the persona of a live session. The actor is dropped
        # first: its config is fixed when it spawns, so a session that moves to
        # another persona's workspace has to be built again to read that
        # persona's SOUL.md and MEMORY.md.
        def apply_persona_to_session(session_id, persona)
          invalidate_session(session_id)
          session_for(session_id).set_persona(persona&.to_h)
        rescue StandardError => e
          warn "[persona] failed to apply persona to #{session_id}: #{e.class}: #{e.message}"
        end

        def invalidate_session(session_id)
          return unless actor_mode? && @pool.respond_to?(:invalidate)

          @pool.invalidate(session_id)
        rescue StandardError => e
          warn "[persona] failed to reset #{session_id}: #{e.class}: #{e.message}"
        end

        def apply_persona_preset_choice(callback_query, wizard, argument)        preset_name = "default"
          unless argument == "default"
            index = argument.to_i
            presets = wizard[:presets] || preset_choices
            choice = presets[index]
            unless choice
              answer_callback_query(callback_query["id"], "Preset tidak dikenal. Ketik /persona untuk mengulang.")
              return
            end
            preset_name = choice["name"].to_s
          end

          @persona_mutex.synchronize do
            wizard[:preset] = preset_name
            wizard[:step] = :prompt
          end
          delete_wizard_message(wizard)
          send_persona_prompt_step(wizard)
          answer_callback_query(callback_query["id"], "Model preset dipilih.")
        end

        def save_persona_wizard(wizard)
          persona = Persona.new(
            name: "topic-#{wizard[:thread_id]}",
            preset: wizard[:preset],
            system_prompt: wizard[:prompt]
          )
          key = persona_topic_key(wizard[:chat_id], wizard[:thread_id])
          stored = persona_store.set(key, persona)
          apply_persona_to_session(wizard[:session_id], stored)

          delete_wizard_message(wizard)
          remove_persona_wizard(wizard)
          send_message(wizard[:chat_id], persona_saved_text(stored), wizard[:thread_id])
        end

        def persona_saved_text(persona)
          model = persona_preset_label(persona.preset || persona.model)
          prompt = persona.system_prompt.to_s.strip
          prompt = "(default)" if prompt.empty?
          prompt = "#{prompt[0, 500]}…" if prompt.length > 500

          "✅ Persona disimpan untuk topic ini.\n\n" \
            "Model  : #{model}\n" \
            "Prompt : #{prompt}\n\n" \
            "Persona hanya berlaku di topic ini. Ketik /persona show untuk melihatnya."
        end

        def persona_summary(persona, ref: nil)
          model = persona_preset_label(persona.preset || persona.model)
          prompt = persona.system_prompt.to_s.strip
          prompt = "(default)" if prompt.empty?
          prompt = "#{prompt[0, 700]}…" if prompt.length > 700
          skills = Array(persona.skills)

          lines = [ "🧬 Persona topic ini", "" ]
          if ref
            lines << "Memakai : #{persona.label} (#{ref})"
            lines << "Memory  : dipakai bersama persona itu"
          else
            lines << "Nama    : #{persona.name || '-'}"
          end
          lines << "Model   : #{model}"
          lines << "Skills  : #{skills.join(', ')}" unless skills.empty?
          lines << "Prompt  : #{prompt}"
          lines << "Dibuat  : #{persona.created_at || '-'}"
          lines.join("\n")
        end
      end
    end
  end
end
