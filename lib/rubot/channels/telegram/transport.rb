# frozen_string_literal: true

module Rubot
  module Channels
    class Telegram < Channel
      # Talking to the Bot API: the HTTP calls, the retry gate that keeps a 429
      # from turning into a log full of them, and the chunking that keeps a long
      # answer inside one message.
      #
      # Nothing here knows what a session or a persona is. Everything above the
      # channel uses these methods, and they use only @token, @config and the
      # flood table, which is what makes this layer testable by stubbing http_post.
      module Transport
        private

        # Monotonic seconds: the clock the flood gate and the status card both
        # read, and the only one that cannot jump when the host clock does.
        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def http_get(uri)
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.read_timeout = 120
            http.open_timeout = 10
            resp = http.get(uri)
            JSON.parse(resp.body)
          end
        end

        def http_post(uri, request)
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.read_timeout = 120
            http.open_timeout = 10
            resp = http.request(request)
            JSON.parse(resp.body)
          end
        end

        # Send a message to Telegram. Markdown becomes Telegram HTML and is split
        # into chunks that never break an entity. A chunk Telegram refuses to
        # parse is re-sent as plain text — only that chunk, so earlier ones are
        # never duplicated. Returns true if every chunk reached the chat.
        def send_message(chat_id, text, thread_id = nil)
          max_length = @config.fetch("max_message_length", DEFAULT_MAX_LENGTH)

          all_ok = true
          Rubot::TelegramFormat.chunks(text, max_length).each do |chunk|
            status = deliver(chat_id, chunk, thread_id, parse_mode: "HTML")
            if status == :entity_error
              # Only an unparsable entity is worth a plain-text retry. Retrying a
              # timed-out request could post the same chunk twice.
              plain = Rubot::TelegramFormat.to_plain(chunk)
              all_ok = false unless delivered?(deliver(chat_id, plain, thread_id, parse_mode: nil))
            elsif !delivered?(status)
              all_ok = false
            end
          end
          all_ok
        end

        # Send text with no parse mode at all (already plain, or last resort).
        def send_message_plain(chat_id, text, thread_id = nil)
          max_length = @config.fetch("max_message_length", DEFAULT_MAX_LENGTH)
          split_message(text, max_length).all? do |chunk|
            delivered?(deliver(chat_id, chunk, thread_id, parse_mode: nil))
          end
        end

        # True when deliver returned a Telegram Message object.
        def delivered?(status)
          status.is_a?(Hash)
        end

        # One sendMessage call. Returns the Telegram result hash on success,
        # :entity_error when the markup could not be parsed, :error otherwise.
        def deliver(chat_id, text, thread_id, parse_mode:)
          # Telegram asked this chat to wait. Sending anyway only earns another
          # 429 and fills the log; the caller treats :error as "not delivered".
          if (left = flood_remaining(chat_id)).positive?
            warn "[telegram] Send skipped, flood window #{left.round}s left"
            return :error
          end

          body = { "chat_id" => chat_id, "text" => text }
          body["parse_mode"] = parse_mode if parse_mode
          body["message_thread_id"] = thread_id if thread_id
          url = URI("#{API_BASE}#{@token}/sendMessage")
          req = Net::HTTP::Post.new(url)
          req["Content-Type"] = "application/json"
          req.body = body.to_json

          result = http_post(url, req)
          return result if result["ok"]

          if result["error_code"].to_i == 429
            wait = close_flood_gate(chat_id, result.dig("parameters", "retry_after"))
            warn "[telegram] Send rate limited, pausing #{wait}s for chat #{chat_id}"
            return :error
          end

          warn "[telegram] API error: #{result["description"]}"
          entity_error?(result["description"].to_s) ? :entity_error : :error
        rescue StandardError => e
          warn "[telegram] Failed to send message: #{e.message}"
          :error
        end

        def split_message(text, max_length)
          return [ text ] if text.length <= max_length

          lines = text.split("\n")
          chunks = []
          current = ""

          lines.each do |line|
            if (current + line + "\n").length > max_length
              chunks << current.strip unless current.empty?
              current = line + "\n"
            else
              current += line + "\n"
            end
          end
          chunks << current.strip unless current.empty?
          chunks
        end

        # Send a message and return the message_id (for later editing/deletion).
        def send_message_with_id(chat_id, text, thread_id = nil)
          max_length = @config.fetch("max_message_length", DEFAULT_MAX_LENGTH)
          last_id = nil

          Rubot::TelegramFormat.chunks(text, max_length).each do |chunk|
            status = deliver(chat_id, chunk, thread_id, parse_mode: "HTML")
            if status == :entity_error
              plain = Rubot::TelegramFormat.to_plain(chunk)
              status = deliver(chat_id, plain, thread_id, parse_mode: nil)
            end
            last_id = status.dig("result", "message_id") if delivered?(status)
          end
          last_id
        end

        # Edit an existing message by ID (used for status updates). Takes Markdown:
        # conversion happens here so callers never ship half-formatted text.
        def edit_message(chat_id, message_id, text, thread_id = nil)
          html = Rubot::TelegramFormat.convert(text)
          return if post_edit(chat_id, message_id, html, "HTML") != :entity_error

          post_edit(chat_id, message_id, Rubot::TelegramFormat.to_plain(html), nil)
        end

        # Returns :ok, :entity_error or :error.
        def post_edit(chat_id, message_id, text, parse_mode)
          result = post_edit_once(chat_id, message_id, text, parse_mode)
          return result unless result == :rate_limited

          # Telegram said how long to wait, and that wait is often longer than a
          # status repaint is worth. Sleeping through it stalls the agent loop, so
          # the edit is dropped: the flood gate already keeps every other call to
          # this chat quiet, and the next repaint draws the card once it expires.
          warn "[telegram] Edit dropped, flood window #{flood_remaining(chat_id).round}s"
          :error
        end

        def post_edit_once(chat_id, message_id, text, parse_mode)
          if (left = flood_remaining(chat_id)).positive?
            warn "[telegram] Edit skipped, flood window #{left.round}s left"
            return :rate_limited
          end

          body = { "chat_id" => chat_id, "message_id" => message_id, "text" => text }
          body["parse_mode"] = parse_mode if parse_mode
          url = URI("#{API_BASE}#{@token}/editMessageText")
          req = Net::HTTP::Post.new(url)
          req["Content-Type"] = "application/json"
          req.body = body.to_json

          result = http_post(url, req)
          return :ok if result["ok"]

          if result["error_code"].to_i == 429
            @last_retry_after = result.dig("parameters", "retry_after").to_i
            close_flood_gate(chat_id, @last_retry_after)
            return :rate_limited
          end

          warn "[telegram] Edit message error: #{result["description"]}"
          entity_error?(result["description"].to_s) ? :entity_error : :error
        rescue StandardError => e
          warn "[telegram] Failed to edit message: #{e.message}"
          :error
        end

        # Telegram's wording when the HTML/Markdown in a message cannot be parsed.
        def entity_error?(description)
          description.to_s.match?(/parse|entit|tag|unsupported start|can't find end/i)
        end

        # Delete a message by ID.
        def delete_message(chat_id, message_id, thread_id = nil)
          body = { "chat_id" => chat_id, "message_id" => message_id }
          body["message_thread_id"] = thread_id if thread_id
          url = URI("#{API_BASE}#{@token}/deleteMessage")
          req = Net::HTTP::Post.new(url)
          req["Content-Type"] = "application/json"
          req.body = body.to_json

          begin
            result = http_post(url, req)
            warn "[telegram] Delete message error: #{result["description"]}" if result["ok"] == false && Rubot.debug?
          rescue StandardError => e
            warn "[telegram] Failed to delete message: #{e.message}" if Rubot.debug?
          end
        end

        # Seconds a chat still has to stay quiet. Zero means the gate is open.
        def flood_remaining(chat_id)
          key = chat_id.to_s
          @flood_mutex.synchronize do
            remaining = @flood_until[key].to_f - monotonic_now
            if remaining.positive?
              remaining
            else
              @flood_until.delete(key)
              0.0
            end
          end
        end

        # Telegram answered 429 with `retry_after`. Close the gate for that chat:
        # continuing to send through the window is what turned one 429 into a log
        # full of them, and every call that still went out was rejected anyway.
        def close_flood_gate(chat_id, retry_after)
          wait = retry_after.to_i
          wait = 1 if wait <= 0
          key = chat_id.to_s
          deadline = monotonic_now + wait
          @flood_mutex.synchronize do
            @flood_until[key] = deadline if deadline > @flood_until[key].to_f
          end
          wait
        end

        # Answer a callback query to remove the loading spinner on the button.
        def answer_callback_query(callback_id, text = nil)
          url = URI("#{API_BASE}#{@token}/answerCallbackQuery")
          req = Net::HTTP::Post.new(url)
          req["Content-Type"] = "application/json"
          body = { "callback_query_id" => callback_id }
          body["text"] = text if text
          body["show_alert"] = false
          req.body = body.to_json

          result = http_post(url, req)
          warn "[telegram] answerCallbackQuery error: #{result["description"]}" unless result["ok"]
          result
        end
      end
    end
  end
end
