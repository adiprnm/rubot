# frozen_string_literal: true

module Rubot
  module Channels
    class Telegram < Channel
      # The edge of the conversation: who is allowed to talk to the bot, what a
      # replied-to message turns into as context, and the two round trips that
      # need a keyboard — a message with buttons, and a tool call waiting for
      # the reader to say yes or no.
      #
      # The confirmation is the only place here that blocks: ask_confirmation
      # posts the card and waits on a condition variable until the button
      # arrives on another update thread, or the turn is cancelled.
      module Messaging
        private

        # Send a plain-text message with an inline keyboard and return its id.
        def send_keyboard_message(chat_id, text, thread_id, keyboard)
          body = {
            "chat_id" => chat_id,
            "text" => text,
            "reply_markup" => { "inline_keyboard" => keyboard }
          }
          body["message_thread_id"] = thread_id if thread_id

          url = URI("#{API_BASE}#{@token}/sendMessage")
          req = Net::HTTP::Post.new(url)
          req["Content-Type"] = "application/json"
          req.body = body.to_json

          result = http_post(url, req)
          unless result["ok"]
            warn "[persona] Failed to send wizard: #{result['description']}"
            return nil
          end

          result.dig("result", "message_id")
        rescue StandardError => e
          warn "[persona] Failed to send wizard: #{e.class}: #{e.message}"
          nil
        end

        def authorized?(chat_id, message)
          user_id = message.dig("from", "id")

          allowed_users = @config["allowed_user_ids"]
          if allowed_users && !allowed_users.map(&:to_i).include?(user_id)
            warn "[telegram] Blocked unauthorized user: #{user_id}"
            return false
          end

          allowed_chats = @config["allowed_chat_ids"]
          if allowed_chats && !allowed_chats.map(&:to_i).include?(chat_id)
            warn "[telegram] Blocked unauthorized chat: #{chat_id}"
            return false
          end

          true
        end

        # Telegram puts the quoted message in `reply_to_message` and the exact
        # passage the user highlighted in `quote`. Neither is part of the text, so
        # a reply has to be carried into the prompt explicitly: the transcript
        # only helps when the quoted message belongs to this same session, which
        # is not the case for replies that cross topics, follow /new, or point at
        # a message the bot never received.
        #
        # Returns nil when there is nothing readable to quote.
        def reply_context(message, session_id, chat_id)
          reply = message["reply_to_message"]
          quote = message["quote"]
          return nil unless reply.is_a?(Hash) || quote.is_a?(Hash)

          quoted = quoted_text(quote) || quoted_text(reply)
          attachments = reply.is_a?(Hash) ? extract_attachments(reply).first : []
          notes = attachments.map { |attachment| receive_attachment(attachment, session_id, chat_id) }
          return nil if quoted.nil? && notes.empty?

          lines = [ reply_author_label(reply) ]
          lines << quoted.lines.map { |line| "> #{line.chomp}" }.join("\n") if quoted
          lines.concat(notes)
          lines.join("\n")
        end

        # The message text, or the caption when the quoted message is media.
        # Truncated so one long quote cannot crowd out the actual question.
        def quoted_text(message)
          return nil unless message.is_a?(Hash)

          text = (message["text"] || message["caption"]).to_s.strip
          return nil if text.empty?
          return text if text.length <= MAX_REPLY_QUOTE_CHARS

          "#{text[0, MAX_REPLY_QUOTE_CHARS]}… (truncated)"
        end

        # Tells the model whose message it is looking at. Replies to the bot's own
        # messages are common ("lanjutkan", "yang tadi maksudnya apa") and read
        # differently from a reply to another member.
        def reply_author_label(reply)
          from = reply.is_a?(Hash) ? reply["from"] : nil
          return "↩️ The user replied to an earlier message:" unless from.is_a?(Hash)

          username = from["username"].to_s
          if from["is_bot"] && !@bot_username.nil? && username.downcase == @bot_username
            return "↩️ The user replied to your earlier message:"
          end

          name = username.empty? ? from["first_name"].to_s.strip : "@#{username}"
          name = "someone" if name.empty?
          "↩️ The user replied to this earlier message from #{name}:"
        end

        # Send a confirmation message with inline Yes/No buttons.
        # Blocks until the user responds or timeout expires.
        # Returns true if confirmed, false otherwise.
        def ask_confirmation(chat_id, thread_id, tool_name, args, reason = nil)
          confirm_id = SecureRandom.hex(8)
          description = describe_action(tool_name, args, reason)

          # Send confirmation message with inline keyboard
          url = URI("#{API_BASE}#{@token}/sendMessage")
          req = Net::HTTP::Post.new(url)
          req["Content-Type"] = "application/json"
          text = "⚠️ **#{confirmation_title(tool_name, args)}**\n\n#{description}\n\nProceed?"
          body = {
            "chat_id" => chat_id,
            "text" => Rubot::TelegramFormat.convert(text),
            "parse_mode" => "HTML",
            "reply_markup" => {
              "inline_keyboard" => [
                [
                  { "text" => "✅ Yes", "callback_data" => "confirm:#{confirm_id}:yes" },
                  { "text" => "❌ No", "callback_data" => "confirm:#{confirm_id}:no" }
                ]
              ]
            }
          }
          body["message_thread_id"] = thread_id if thread_id
          req.body = body.to_json

          result = http_post(url, req)
          unless result["ok"]
            warn "[telegram] Failed to send confirmation: #{result["description"]}"
            # If we can't ask, default to safe: deny
            return false
          end

          msg_id = result.dig("result", "message_id")

          # Create a condition variable and wait for the response
          cv = ConditionVariable.new
          @confirm_mutex.synchronize do
            @pending_confirmations[confirm_id] = {
              cv: cv, result: nil, msg_id: msg_id, chat_id: chat_id, thread_id: thread_id
            }
          end

          @confirm_mutex.synchronize do
            cv.wait(@confirm_mutex, CONFIRM_TIMEOUT_SECONDS)
          end

          # Retrieve the result
          confirmed = false
          msg_id = nil
          @confirm_mutex.synchronize do
            entry = @pending_confirmations.delete(confirm_id)
            confirmed = entry && entry[:result] == true
            msg_id = entry&.dig(:msg_id)
          end

          # Delete the confirmation message regardless of outcome
          delete_message(chat_id, msg_id, thread_id) if msg_id

          confirmed
        end

        # Send a question from the ask_user tool and wait for the answer.
        #
        # The options are buttons; the custom answer is simply the next message
        # typed in this conversation — there is no room for a text box in a chat
        # that already has one, and asking the reader to press "Other" first
        # would be a step with nothing behind it.
        def ask_question(chat_id, thread_id, payload)
          payload = {} unless payload.is_a?(Hash)
          options = Array(payload[:options]).first(4)
          question_id = SecureRandom.hex(8)

          text = "❓ #{payload[:question]}\n"
          options.each_with_index do |option, index|
            description = option[:description].to_s.strip
            line = "#{index + 1}. #{option[:label]}"
            line += " — #{description}" unless description.empty?
            text << "\n#{line}"
          end
          text << "\n\nChoose above, or reply with your own answer."

          url = URI("#{API_BASE}#{@token}/sendMessage")
          req = Net::HTTP::Post.new(url)
          req["Content-Type"] = "application/json"
          body = {
            "chat_id" => chat_id,
            "text" => Rubot::TelegramFormat.convert(text),
            "parse_mode" => "HTML"
          }
          unless options.empty?
            body["reply_markup"] = {
              "inline_keyboard" => options.each_with_index.map do |option, index|
                [ { "text" => option[:label].to_s, "callback_data" => "ask:#{question_id}:#{index}" } ]
              end
            }
          end
          body["message_thread_id"] = thread_id if thread_id
          req.body = body.to_json

          # Registered before the message goes out: the reader can answer in the
          # time the send takes, and an answer that arrives before there is a
          # slot for it would be dropped and the question would sit out its
          # deadline. The message id is filled in on the way back.
          cv = ConditionVariable.new
          @confirm_mutex.synchronize do
            @pending_questions[question_id] = {
              cv: cv, result: nil, msg_id: nil, chat_id: chat_id, thread_id: thread_id,
              options: options
            }
          end

          result = http_post(url, req)
          unless result["ok"]
            warn "[telegram] Failed to send question: #{result["description"]}"
            # Nowhere to ask is the same as nobody answering: the model is told
            # the question expired and decides for itself.
            @confirm_mutex.synchronize { @pending_questions.delete(question_id) }
            return { outcome: :expired }
          end

          msg_id = result.dig("result", "message_id")
          @confirm_mutex.synchronize do
            entry = @pending_questions[question_id]
            entry[:msg_id] = msg_id if entry
          end

          @confirm_mutex.synchronize do
            cv.wait(@confirm_mutex, CONFIRM_TIMEOUT_SECONDS)
          end

          answer = nil
          msg_id = nil
          @confirm_mutex.synchronize do
            entry = @pending_questions.delete(question_id)
            answer = entry && entry[:result]
            msg_id = entry&.dig(:msg_id)
          end

          # The buttons go with the question: a stale keyboard in a chat is a
          # button that answers something nobody is waiting on.
          delete_message(chat_id, msg_id, thread_id) if msg_id

          answer || { outcome: :expired }
        end

        # A message typed while a question is waiting is its answer. Returns
        # true when it was taken, so the update is not also run as a prompt.
        def deliver_question_answer(chat_id, thread_id, text)
          body = text.to_s.strip
          return false if body.empty?

          @confirm_mutex.synchronize do
            entry = @pending_questions.each_value.find do |candidate|
              candidate[:chat_id] == chat_id && candidate[:thread_id] == thread_id && candidate[:result].nil?
            end
            return false unless entry

            entry[:result] = { outcome: :custom, text: body }
            entry[:cv].signal
          end
          true
        end

        # Release a confirmation prompt waiting for a button press. Without this
        # a stopped turn would stay blocked until the 120 s timeout expires.
        def cancel_pending_confirmations(chat_id, thread_id)
          @confirm_mutex.synchronize do
            @pending_confirmations.each_value do |entry|
              next unless entry[:chat_id] == chat_id && entry[:thread_id] == thread_id
              next unless entry[:result].nil?

              entry[:result] = false
              entry[:cv].signal
            end
            # A question goes the same way, as a cancellation rather than an
            # expiry: the turn stopped, the reader did not walk away.
            @pending_questions.each_value do |entry|
              next unless entry[:chat_id] == chat_id && entry[:thread_id] == thread_id
              next unless entry[:result].nil?

              entry[:result] = { outcome: :cancelled }
              entry[:cv].signal
            end
          end
        end

        # Handle an incoming callback query (inline button click).
        def handle_callback_query(callback_query)
          data = callback_query["data"]
          callback_id = callback_query["id"]

          if data&.start_with?("persona:")
            handle_persona_callback(callback_query)
            return
          end

          if data&.start_with?("ask:")
            handle_question_callback(data, callback_id)
            return
          end

          return unless data&.start_with?("confirm:")

          parts = data.split(":")
          return unless parts.size == 3

          confirm_id = parts[1]
          response = parts[2]

          @confirm_mutex.synchronize do
            entry = @pending_confirmations[confirm_id]
            if entry
              entry[:result] = (response == "yes")
              entry[:cv].signal
            end
          end

          # Acknowledge the callback query to remove the loading spinner
          answer_callback_query(callback_id, response == "yes" ? "Proceeding..." : "Action cancelled.")
        end

        # An option button under a question. The index is the whole answer; the
        # label rides along so the model reads words, not a position.
        def handle_question_callback(data, callback_id)
          parts = data.split(":")
          return unless parts.size == 3

          question_id = parts[1]
          index = parts[2].to_i
          label = nil

          @confirm_mutex.synchronize do
            entry = @pending_questions[question_id]
            option = entry && Array(entry[:options])[index]
            if entry && entry[:result].nil? && option
              label = option[:label].to_s
              entry[:result] = { outcome: :option, index: index, label: label }
              entry[:cv].signal
            end
          end

          answer_callback_query(callback_id, label ? "Chose: #{label}" : "That question is closed.")
        end
      end
    end
  end
end
