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
            return [ :skip, "ℹ️ Tidak ada yang perlu di-compact (percakapan masih pendek atau ringkasan gagal dibuat)." ]
          end

          lines = [ "🗜️ **Compact selesai**" ]
          lines << "Pesan diringkas: #{result[:summarized_messages]}"
          lines << "Pesan dipertahankan: #{result[:kept_messages]}"
          lines << "Perkiraan konteks: #{result[:context_before]} → #{result[:context_after]} token"
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
      end
    end
  end
end
