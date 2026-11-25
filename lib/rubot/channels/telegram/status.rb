# frozen_string_literal: true

module Rubot
  module Channels
    class Telegram < Channel
      # The live picture of a request: the typing indicator while the model
      # thinks, and the one status card that says which tool is running, how
      # many steps have gone by, and how long it has taken.
      #
      # Both are rate-limited on purpose. Telegram accepts roughly one message
      # per second per chat and an edit counts as one, so the card is repainted at
      # most once per interval, never with identical text, and never while a 429
      # is still open for that chat.
      module Status
        TOOL_EMOJIS = {
          "shell_exec"  => "💻",
          "file_ops"    => "📄",
          "web_fetch"   => "🌐",
          "memory"      => "🧠",
          "cron"        => "⏰"
        }.freeze

        # Telegram accepts roughly one message per second per chat and an edit
        # counts as a message. A tool batch used to fire one edit per tool, so a
        # five-tool round could trip 429 and leave the card frozen on an old step.
        # Override per deployment with `status_edit_interval` in channel config.
        MIN_STATUS_EDIT_INTERVAL = 1.0

        # Shown once per request, not on every edit. Named through the dictionary
        # at the moment the card is drawn, so the hint follows the language.
        SUBAGENT_RUNNING_PHASES = %w[started thinking tool].freeze

        private

        def start_typing(chat_id, thread_id = nil)
          key = typing_key(chat_id, thread_id)
          return if @active_typing[key]

          @active_typing[key] = Thread.new do
            loop do
              send_action(chat_id, "typing", thread_id)
              sleep 3
            end
          end
        end

        def stop_typing(chat_id, thread_id = nil)
          key = typing_key(chat_id, thread_id)
          thread = @active_typing.delete(key)
          thread&.kill
        end

        def typing_key(chat_id, thread_id)
          "#{chat_id}:#{thread_id}"
        end

        def send_action(chat_id, action, thread_id = nil)
          body = { "chat_id" => chat_id, "action" => action }
          body["message_thread_id"] = thread_id if thread_id
          body_json = body.to_json
          url = URI("#{API_BASE}#{@token}/sendChatAction")
          req = Net::HTTP::Post.new(url)
          req["Content-Type"] = "application/json"
          req.body = body_json
          http_post(url, req)
        rescue StandardError
          # Ignore typing indicator errors
        end

        # Called before a tool executes. Updates the status card with the literal
        # state: which tool, how many steps so far, and how long this request has
        # been running. No prose — the card says what is true, nothing more.
        def notify_tool_started(chat_id, thread_id, tool_name, args)
          warn "[telegram] notify_tool_started: #{tool_name}" if Rubot.debug?
          key = status_key(chat_id, thread_id)

          state = @status_mutex.synchronize do
            @tool_counts[key] = (@tool_counts[key] || 0) + 1
            st = (@status_state[key] ||= { started_at: monotonic_now, hint_sent: false })
            st[:tool_name] = tool_name
            st[:emoji] = TOOL_EMOJIS[tool_name] || "⚙️"
            st[:preview] = tool_preview(tool_name, args)
            st[:step] = @tool_counts[key]
            st[:finished] = false
            st.dup
          end

          update_or_send_status(chat_id, thread_id, render_tool_status(state))
        end

        # Called after a tool finishes. The card is not touched here: a batch of
        # five tools would mean five edits for no new information. The round
        # completing (below) is the moment worth showing.
        def notify_tool_finished(chat_id, thread_id, tool_name, result)
          warn "[telegram] Tool #{tool_name} finished" if Rubot.debug?
        end

        def notify_subagent(chat_id, thread_id, info)
          key = status_key(chat_id, thread_id)
          run_id = info[:run_id].to_s
          return if run_id.empty?

          state = @status_mutex.synchronize do
            runs = (@subagents[key] ||= {})
            runs[run_id] = {
              agent: info[:agent].to_s,
              phase: info[:phase].to_s,
              detail: info[:detail].to_s
            }
            st = (@status_state[key] ||= { started_at: monotonic_now })
            st[:subagents] = runs.dup
            st.dup
          end
          update_or_send_status(chat_id, thread_id, render_tool_status(state))
        end

        # Called after each agent round, i.e. once the model has been asked again.
        # No tool is running at this point, so the card marks the finished step
        # (✓) and refreshes the elapsed clock and the one-time /stop hint.
        def notify_progress(chat_id, thread_id, round)
          key = status_key(chat_id, thread_id)

          state = @status_mutex.synchronize do
            st = @status_state[key]
            next nil unless st

            st[:finished] = true
            st[:round] = round
            st[:hint_sent] = true if !st[:hint_sent] && stop_hint_due?(st, round)
            st.dup
          end
          return unless state

          # This edit carries the only news in the round, so wait out the throttle
          # instead of dropping it (the wait is bounded by MIN_STATUS_EDIT_INTERVAL).
          update_or_send_status(chat_id, thread_id, render_tool_status(state), wait: true)
        end

        # One line of literal state plus the tool's own arguments:
        #
        #   ✓ 💻 `shell_exec` · step 3 · 1m 05s
        #   $ bundle exec rspec test/agent_test.rb
        def render_tool_status(state)
          elapsed = format_elapsed(monotonic_now - state[:started_at].to_f)
          step = I18n.t("telegram.status.step", step: state[:step], elapsed: elapsed)
          head = (state[:finished] ? "✓ " : "") + "#{state[:emoji]} `#{state[:tool_name]}`" + step
          lines = [ head ]
          preview = state[:preview].to_s
          lines.push("", preview) unless preview.empty?
          subagents = state[:subagents]
          if subagents && !subagents.empty?
            running = subagents.values.count { |s| SUBAGENT_RUNNING_PHASES.include?(s[:phase]) }
            lines.push("", subagent_count_line(running))
            subagents.each_value do |s|
              mark = s[:phase] == "done" ? "✓" : (s[:phase] == "failed" ? "✗" : "·")
              detail = s[:detail].to_s.gsub(/\s+/, " ").strip
              line = "#{mark} #{s[:agent]}"
              line += " — #{truncate(detail, 40)}" unless detail.empty?
              lines.push(line)
            end
          end
          lines.push("", I18n.t("telegram.status.stop_hint")) if state[:hint_sent]
          lines.join("\n")
        end

        # The same phrase the timeline and the TUI draw (see
        # Rubot::ToolCaption), so the card does not describe one call in words
        # a reader cannot match to the row they see elsewhere.
        def tool_preview(tool_name, args)
          Rubot::ToolCaption.caption(tool_name, args)
        end

        # One sub agent is not "one subagents": the count line has its own
        # wording for the single case in both languages.
        def subagent_count_line(count)
          return I18n.t("telegram.status.subagent_one") if count == 1

          I18n.t("telegram.status.subagents", count: count)
        end

        # The stop hint appears once, and only when the request has gone on long
        # enough that a user might wonder whether it is stuck.
        def stop_hint_due?(state, round)
          return true if round.to_i >= 3
          monotonic_now - state[:started_at].to_f >= 60
        end

        def format_elapsed(seconds)
          total = seconds.to_i.clamp(0, 24 * 3600)
          return "#{total}s" if total < 60
          return format("%dm %02ds", total / 60, total % 60) if total < 3600
          format("%dh %02dm", total / 3600, (total % 3600) / 60)
        end

        # Edit interval for the live status card, in seconds.
        def status_edit_interval
          interval = @config.fetch("status_edit_interval", MIN_STATUS_EDIT_INTERVAL).to_f
          interval < MIN_STATUS_EDIT_INTERVAL ? MIN_STATUS_EDIT_INTERVAL : interval
        end

        # Send a new status message or edit the existing one (avoids message spam).
        #
        # Edits are throttled to one per MIN_STATUS_EDIT_INTERVAL per chat, and an
        # identical text is not sent at all. With `wait: true` the caller blocks
        # for the remainder of the interval instead of losing the update.
        def update_or_send_status(chat_id, thread_id, text, wait: false)
          return unless @config.fetch("tool_notifications", true)

          key = status_key(chat_id, thread_id)
          text = text.to_s
          interval = status_edit_interval

          if wait
            resume_at = @status_mutex.synchronize do
              last = @status_last_edit[key]
              last ? last + interval : 0.0
            end
            delay = resume_at - monotonic_now
            sleep(delay) if delay.positive?
          end

          # Telegram told this chat to wait: painting the card now would be
          # rejected, and the repaint would land on an already-deleted message.
          return if flood_remaining(chat_id).positive?

          proceed = @status_mutex.synchronize do
            last_at = @status_last_edit[key]
            if @status_last_text[key] == text
              false
            elsif !wait && last_at && monotonic_now - last_at < interval
              false
            else
              @status_last_edit[key] = monotonic_now
              @status_last_text[key] = text
              true
            end
          end
          return unless proceed

          existing = @status_mutex.synchronize { @status_messages[key] }
          warn "[telegram] update_or_send_status: existing=#{!!existing}, key=#{key}" if Rubot.debug?

          if existing
            # Edit the existing status message
            edit_message(chat_id, existing[:message_id], text, thread_id)
          else
            # Send a new status message
            msg_id = send_message_with_id(chat_id, text, thread_id)
            warn "[telegram] Status message sent, id=#{msg_id}" if Rubot.debug?
            @status_mutex.synchronize do
              @status_messages[key] = { chat_id: chat_id, thread_id: thread_id, message_id: msg_id }
            end
          end
        end

        # Build a unique key for per-chat status tracking.
        def status_key(chat_id, thread_id)
          "#{chat_id}:#{thread_id}"
        end

        # Delete the status message for a specific chat/thread. Called before the
        # final response, and before each narration so the assistant text always
        # ends up below the live tool status instead of above it.
        #
        # `reset_count: false` keeps the running tool step count for the request,
        # which is what a narration needs: the conversation restarts the status
        # message, not the numbering of the steps already taken.
        def clear_status_message(chat_id, thread_id, reset_count: true)
          key = status_key(chat_id, thread_id)
          @status_mutex.synchronize do
            info = @status_messages.delete(key)
            if reset_count
              @tool_counts.delete(key)
              @status_state.delete(key)
              @subagents.delete(key)
              @status_last_text.delete(key)
              @status_last_edit.delete(key)
            end
            return unless info
            delete_message(info[:chat_id], info[:message_id]) if info[:chat_id] && info[:message_id]
          end
        end
      end
    end
  end
end
