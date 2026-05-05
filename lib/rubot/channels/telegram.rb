# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "thread"

module Rubot
  module Channels
    # Telegram channel using the Telegram Bot API (long polling).
    #
    # Configuration (in config.yml):
    #
    #   channels:
    #     telegram:
    #       token: "123456:ABC-DEF..."
    #       allowed_user_ids: [123456789]   # optional: restrict to specific users
    #       allowed_chat_ids: [123456789]   # optional: restrict to specific chats
    #       webhook: false                   # default: long polling; set true for webhook
    #       webhook_url: "https://..."       # required if webhook: true
    #       webhook_port: 8443               # port for webhook server
    #       stream: true                     # enable streaming responses
    #       typing_indicator: true           # show typing indicator while processing
    #       max_message_length: 4096         # Telegram's max message length
    #
    class Telegram < Channel
      API_BASE = "https://api.telegram.org/bot"
      DEFAULT_MAX_LENGTH = 4096
      DEFAULT_POLL_TIMEOUT = 60

      def initialize(agent:, channel_config: {})
        super
        @token = @config["token"] || ENV["TELEGRAM_BOT_TOKEN"]
        @offset = 0
        @mutex = Mutex.new
        @active_typing = {}  # chat_id => thread
        @last_chat_id = nil
        @last_thread_id = nil
        @process_mutex = Mutex.new
      end

      def start
        raise ArgumentError, "Telegram bot token is required. Set 'token' in config or TELEGRAM_BOT_TOKEN env var." unless @token

        @running = true
        register_signal_handlers

        url = URI("#{API_BASE}#{@token}/getMe")
        resp = http_get(url)
        raise "Telegram API error: #{resp["description"] || resp}" unless resp["ok"]

        bot_info = resp["result"]
        warn "[telegram] Connected as @#{bot_info['username']} (id: #{bot_info['id']})"

        # Start cron scheduler with callback for automatic cron execution
        start_cron_scheduler

        @webhook = @config["webhook"] == true
        if @webhook
          start_webhook
        else
          start_polling_thread
        end
      end

      def stop
        @running = false
        @poll_thread&.raise(Interrupt)
        @poll_thread&.join(5)
        @active_typing.each_value(&:kill)
        @active_typing.clear
        stop_cron_scheduler
      end

      # Override signal handlers to interrupt the polling thread.
      def register_signal_handlers
        %w[INT TERM].each do |signal|
          Signal.trap(signal) do
            warn "\n[telegram] Received #{signal}, stopping..."
            @running = false
            @poll_thread&.raise(Interrupt)
          end
        end
      end

      # Run polling in a background thread so the main thread
      # stays responsive to signals (Ctrl+C).
      def start_polling_thread
        warn "[telegram] Starting long polling (timeout: #{DEFAULT_POLL_TIMEOUT}s)"

        @poll_thread = Thread.new do
          poll_loop
        end

        # Block main thread on the polling thread — signals are handled
        # by Ruby on the main thread, which then interrupts @poll_thread.
        @poll_thread.join
        warn "[telegram] Polling stopped."
      end

      def poll_loop
        while @running
          begin
            updates = get_updates
            updates.each { |update| process_update(update) }
          rescue Interrupt
            warn "[telegram] Interrupted, stopping..."
            break
          rescue StandardError => e
            warn "[telegram] Polling error: #{e.message}"
            sleep 5 if @running
          end
        end
      end

      # --------------- Placeholder Hooks ---------------

      # Intercept built-in slash commands before they reach the agent.
      def before_process(message)
        case message.strip.downcase
        when "/start"
          [:skip, "👋 Welcome to Rubot!\n\nI'm your AI assistant. Send me any message and I'll help you out.\n\nUse /help to see available commands."]
        when "/help"
          bot_name = @config.fetch("bot_name", "Rubot")
          [:skip, "📖 Help | #{bot_name}\n\nJust send me a message and I'll do my best to help.\n\nBuilt-in commands:\n/start - Start the bot\n/help - Show this help message\n/cron - List scheduled cron jobs\n/cron delete <id> - Delete a cron job"]
        when /^\/cron(\s+(.*))?$/
          handle_cron_command($2&.strip)
        else
          message
        end
      end

      private

      # --------------- Cron Scheduler ---------------

      def start_cron_scheduler
        cron_tool = @agent.tools.get("cron")
        return unless cron_tool

        cron_tool.on_fire do |result|
          cron_fire_callback(result)
        end

        scheduler = cron_tool.scheduler
        scheduler.start
      end

      def stop_cron_scheduler
        cron_tool = @agent.tools.get("cron")
        return unless cron_tool
        scheduler = cron_tool.scheduler
        scheduler&.stop
      end

      def cron_fire_callback(result)
        return unless @last_chat_id

        case result[:mode]
        when "command"
          output = result[:result][:output] || "(no output)"
          text = "⏰ **Cron: #{result[:description] || result[:job_id]}**\n\n```\n#{output}\n```"
          send_message(@last_chat_id, text, @last_thread_id)
        when "deliver"
          send_message(@last_chat_id, result[:result][:deliver_message], @last_thread_id)
        when "agent_turn"
          # Process through the LLM with mutex protection
          response = @process_mutex.synchronize do
            @agent.process_cron(result[:result][:agent_message])
          end
          send_message(@last_chat_id, response, @last_thread_id) if response && !response.empty?
        end
      rescue StandardError => e
        warn "[cron] Callback error: #{e.class}: #{e.message}"
      end

      # Handle /cron slash command
      def handle_cron_command(args)
        cron_tool = @agent.tools.get("cron")
        return [:skip, "❌ Cron tool not available."] unless cron_tool

        if args.nil? || args.empty?
          # List all cron jobs
          result = cron_tool.execute({ "operation" => "list" })
          [:skip, result]
        elsif args.start_with?("delete ")
          job_id = args[7..].strip
          result = cron_tool.execute({ "operation" => "remove", "job_id" => job_id })
          [:skip, result]
        elsif args.start_with?("enable ")
          job_id = args[7..].strip
          result = cron_tool.execute({ "operation" => "enable", "job_id" => job_id })
          [:skip, result]
        elsif args.start_with?("disable ")
          job_id = args[8..].strip
          result = cron_tool.execute({ "operation" => "disable", "job_id" => job_id })
          [:skip, result]
        else
          [:skip, "❌ Unknown /cron subcommand. Use:\n/cron — list jobs\n/cron delete <id>\n/cron enable <id>\n/cron disable <id>"]
        end
      rescue StandardError => e
        [:skip, "❌ Error: #{e.message}"]
      end

      # --------------- Long Polling ---------------

      def get_updates
        params = {
          "offset" => @offset,
          "limit" => 10,
          "timeout" => DEFAULT_POLL_TIMEOUT,
        }
        url = URI("#{API_BASE}#{@token}/getUpdates?#{URI.encode_www_form(params)}")
        resp = http_get(url)
        return [] unless resp["ok"]

        updates = resp["result"]
        @offset = updates.map { |u| u["update_id"] }.max.to_i + 1 if updates.any?
        updates
      end

      # --------------- Webhook ---------------

      def start_webhook
        webhook_url = @config["webhook_url"]
        raise ArgumentError, "webhook_url is required when webhook is enabled" unless webhook_url

        warn "[telegram] Setting webhook to #{webhook_url}"

        # Set webhook via API
        body = { "url" => webhook_url }.to_json
        url = URI("#{API_BASE}#{@token}/setWebhook")
        req = Net::HTTP::Post.new(url)
        req["Content-Type"] = "application/json"
        req.body = body
        resp = Net::HTTP.start(url.hostname, url.port, use_ssl: true) { |http| http.request(req) }
        result = JSON.parse(resp.body)
        raise "Failed to set webhook: #{result}" unless result["ok"]

        # Start a simple HTTP server to receive webhook updates
        require "webrick"
        server = WEBrick::HTTPServer.new(
          Port: @config["webhook_port"] || 8443,
          AccessLog: [],
          Logger: WEBrick::Log.new("/dev/null")
        )

        server.mount_proc "/" do |req, res|
          if req.request_method == "POST"
            update = JSON.parse(req.body)
            process_update(update)
            res.status = 200
          else
            res.status = 200
            res.body = "ok"
          end
        end

        trap("INT") { server.shutdown }
        trap("TERM") { server.shutdown }

        warn "[telegram] Webhook server listening on port #{@config['webhook_port'] || 8443}"
        server.start
      end

      # --------------- Update Processing ---------------

      def process_update(update)
        # Handle different update types
        message = update["message"] || update["edited_message"] || update["channel_post"]
        return unless message

        chat_id = message["chat"]["id"]
        text = message["text"]
        thread_id = message["message_thread_id"]

        # Skip if no text (e.g., photo, sticker, etc.)
        return unless text && !text.strip.empty?

        # Check allowed users/chats
        return unless authorized?(chat_id, message)

        user_id = message["from"]["id"]
        username = message.dig("from", "username") || "User##{user_id}"

        # Per-topic (or per-DM) session isolation
        session_id = thread_id ? "tg_#{chat_id}_#{thread_id}" : "tg_#{chat_id}"

        # Track last active chat for cron message delivery
        @last_chat_id = chat_id
        @last_thread_id = thread_id

        warn "[telegram] #{username} (#{user_id})#{thread_id ? " [topic:#{thread_id}]" : ""}: #{text[0..80]}"

        # Show typing indicator
        # Note: Telegram API has a known bug where typing indicators don't display
        # in the General topic of forum-enabled groups. See:
        # https://github.com/NousResearch/hermes-agent/issues/7877
        is_forum = message.dig("chat", "is_forum") == true
        is_general_topic = is_forum && thread_id.nil?
        if is_general_topic
          warn "[telegram] Skipping typing indicator for General topic (Telegram API limitation)"
        else
          start_typing(chat_id, thread_id) if @config.fetch("typing_indicator", true)
        end

        response = process_message(text, session_id: session_id)

        stop_typing(chat_id, thread_id) unless is_general_topic

        if response && !response.empty?
          warn "[telegram] Sending response (#{response.length} chars)"
          send_message(chat_id, response, thread_id)
        else
          warn "[telegram] No response to send"
        end
      end

      # --------------- Authorization ---------------

      def authorized?(chat_id, message)
        user_id = message["from"]["id"]

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

      # --------------- Sending Messages ---------------

      def send_message(chat_id, text, thread_id = nil)
        max_length = @config.fetch("max_message_length", DEFAULT_MAX_LENGTH)

        # Split long messages
        chunks = split_message(text, max_length)
        chunks.each do |chunk|
          body = {
            "chat_id" => chat_id,
            "text" => chunk,
          }
          body["message_thread_id"] = thread_id if thread_id && thread_id != 1
          url = URI("#{API_BASE}#{@token}/sendMessage")
          req = Net::HTTP::Post.new(url)
          req["Content-Type"] = "application/json"
          req.body = body.to_json

          begin
            result = http_post(url, req)
            unless result["ok"]
              warn "[telegram] API error: #{result["description"]}"
            end
          rescue StandardError => e
            warn "[telegram] Failed to send message: #{e.message}"
          end
        end
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

      # --------------- Typing Indicator ---------------

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
        body["message_thread_id"] = thread_id if thread_id && thread_id != 1
        body_json = body.to_json
        url = URI("#{API_BASE}#{@token}/sendChatAction")
        req = Net::HTTP::Post.new(url)
        req["Content-Type"] = "application/json"
        req.body = body_json
        http_post(url, req)
      rescue StandardError
        # Ignore typing indicator errors
      end

      # --------------- Streaming ---------------

      # Override from base Channel to support Telegram streaming
      def on_stream_chunk(chunk)
        return unless @config.fetch("stream", false)
        # For Telegram, streaming is tricky because we can't edit messages
        # in real-time without hitting rate limits. We accumulate and
        # send periodically in a real implementation, but for now we
        # just let the full response be sent at the end.
        # The typing indicator gives the user feedback that something is happening.
      end

      # --------------- HTTP Helpers ---------------

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
    end
  end
end
