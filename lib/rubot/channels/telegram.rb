# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "thread"

require_relative "../telegram_markdown"

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
    #       tool_notifications: true         # send status messages for tool execution (default: true)
    #       max_message_length: 4096         # Telegram's max message length
    #
    class Telegram < Channel
      API_BASE = "https://api.telegram.org/bot"
      DEFAULT_MAX_LENGTH = 4096
      DEFAULT_POLL_TIMEOUT = 60

      def initialize(agent:, channel_config: {})
        super
        @token = @config["token"] || ENV["TELEGRAM_BOT_TOKEN"]
        @bot_username = nil
        @offset = 0
        @mutex = Mutex.new
        @active_typing = {}  # chat_id => thread
        @last_chat_id = nil
        @last_thread_id = nil
        @process_mutex = Mutex.new
        @status_message = nil  # { chat_id:, thread_id:, message_id: } for current status msg
        @tool_count = 0        # tool calls in current processing cycle
        @status_mutex = Mutex.new
      end

      def start
        raise ArgumentError, "Telegram bot token is required. Set 'token' in config or TELEGRAM_BOT_TOKEN env var." unless @token

        @running = true
        register_signal_handlers

        url = URI("#{API_BASE}#{@token}/getMe")
        resp = http_get(url)
        raise "Telegram API error: #{resp["description"] || resp}" unless resp["ok"]

        bot_info = resp["result"]
        @bot_username = bot_info["username"].downcase
        warn "[telegram] Connected as @#{bot_info['username']} (id: #{bot_info['id']})" if Rubot.debug?

        # Register bot commands with Telegram
        register_bot_commands

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
        warn "[telegram] Starting long polling (timeout: #{DEFAULT_POLL_TIMEOUT}s)" if Rubot.debug?

        @poll_thread = Thread.new do
          poll_loop
        end

        # Block main thread on the polling thread — signals are handled
        # by Ruby on the main thread, which then interrupts @poll_thread.
        @poll_thread.join
        warn "[telegram] Polling stopped." if Rubot.debug?
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

      # --------------- Command Handlers ---------------

      def handle_info_command
        info = @agent.startup_info
        lines = info.map { |k, v| "#{k}: #{v}" }
        [ :skip, "ℹ️ Agent Info\n\n" + lines.join("\n") ]
      end

      def handle_models_command
        model = @agent.config.model
        provider = @agent.provider.name
        [ :skip, "🧠 Current Model\n\nProvider: #{provider}\nModel: #{model}" ]
      end

      def handle_skills_command
        registry = @agent.skill_registry
        return [ :skip, "📚 Skills\n\nNo skills installed.\n\nPlace skills in the workspace `skills/` directory." ] unless registry.any?

        lines = registry.all.values.map do |skill|
          "• **#{skill.name}** — #{skill.summary}"
        end
        [ :skip, "📚 Available Skills (#{registry.count})\n\n" + lines.join("\n") ]
      end

      def handle_memory_command
        return [ :skip, "🧠 Memory is not enabled (no workspace configured)." ] unless @agent.memory.enabled?

        content = @agent.memory.read
        max_len = DEFAULT_MAX_LENGTH - 200
        content = content[0, max_len] + "\n\n… (truncated)" if content.length > max_len
        [ :skip, "🧠 Memory\n\n```
#{content}
```" ]
      end

      def handle_soul_command
        return [ :skip, "🧬 No soul file (SOUL.md) found in workspace." ] unless @agent.soul.enabled?

        content = @agent.soul.to_s
        max_len = DEFAULT_MAX_LENGTH - 200
        content = content[0, max_len] + "\n\n… (truncated)" if content.length > max_len
        [ :skip, "🧬 Soul\n\n#{content}" ]
      end

      def handle_agents_command
        return [ :skip, "📋 No AGENTS.md found in workspace." ] unless @agent.agents_file.enabled?

        content = @agent.agents_file.raw
        max_len = DEFAULT_MAX_LENGTH - 200
        content = content[0, max_len] + "\n\n… (truncated)" if content.length > max_len
        [ :skip, "📋 Agent Rules\n\n```
#{content}
```" ]
      end

      # --------------- Placeholder Hooks ---------------

      # Intercept built-in slash commands before they reach the agent.
      def before_process(message)
        text = message.strip
        # Strip bot username from commands in groups (e.g. /new@MyBot -> /new)
        text = text.sub(/\A\/(\w+)@\S+/, '/\1') if text.start_with?("/")

        case text.downcase
        when "/start"
          [ :skip, "👋 Welcome to Rubot!\n\nI'm your AI assistant. Send me any message and I'll help you out.\n\nUse /help to see available commands." ]
        when "/new"
          @agent.clear_session
          [ :skip, "✨ Started a new session. Previous conversation has been cleared." ]
        when "/help"
          bot_name = @config.fetch("bot_name", "Rubot")
          [ :skip, "📖 Help | #{bot_name}\n\nJust send me a message and I'll do my best to help.\n\nBuilt-in commands:\n/start - Start the bot\n/new - Clear chat and start a new session\n/help - Show this help message\n/info - Show agent info\n/models - Show current model\n/skills - List available skills\n/memory - Show persistent memory\n/soul - Show bot personality\n/agents - Show agent rules\n/cron - List scheduled cron jobs\n/cron delete <id> - Delete a cron job" ]
        when "/info"
          handle_info_command
        when "/models"
          handle_models_command
        when "/skills"
          handle_skills_command
        when "/memory"
          handle_memory_command
        when "/soul"
          handle_soul_command
        when "/agents"
          handle_agents_command
        when /^\/cron(\s+(.*))?$/
          handle_cron_command($2&.strip)
        else
          message
        end
      end

      private

      # --------------- Bot Commands Registration ---------------

      # Register all slash commands with Telegram so they appear
      # in the command menu (available via the / button in the chat).
      def register_bot_commands
        commands = [
          { "command" => "start", "description" => "Start the bot" },
          { "command" => "new", "description" => "Clear chat and start a new session" },
          { "command" => "help", "description" => "Show help message" },
          { "command" => "info", "description" => "Show agent info" },
          { "command" => "models", "description" => "Show current model" },
          { "command" => "skills", "description" => "List available skills" },
          { "command" => "memory", "description" => "Show persistent memory" },
          { "command" => "soul", "description" => "Show bot personality" },
          { "command" => "agents", "description" => "Show agent rules" },
          { "command" => "cron", "description" => "List scheduled cron jobs" }
        ]

        url = URI("#{API_BASE}#{@token}/setMyCommands")
        body = { "commands" => commands }.to_json
        req = Net::HTTP::Post.new(url)
        req["Content-Type"] = "application/json"
        req.body = body

        begin
          result = http_post(url, req)
          if result["ok"]
            warn "[telegram] Registered #{commands.size} bot commands." if Rubot.debug?
          else
            warn "[telegram] Failed to register commands: #{result["description"]}"
          end
        rescue StandardError => e
          warn "[telegram] Error registering commands: #{e.message}"
        end
      end

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
        # Use stored target from the job; fall back to last-seen for older jobs
        chat_id = result[:target_chat_id] || @last_chat_id
        thread_id = result[:target_thread_id] || @last_thread_id
        return unless chat_id

        case result[:mode]
        when "command"
          output = result[:result][:output] || "(no output)"
          text = "⏰ **Cron: #{result[:description] || result[:job_id]}**\n\n```\n#{output}\n```"
          send_message(chat_id, text, thread_id)
        when "deliver"
          send_message(chat_id, result[:result][:deliver_message], thread_id)
        when "agent_turn"
          # Process through the LLM with mutex protection
          response = @process_mutex.synchronize do
            @agent.process_cron(result[:result][:agent_message])
          end
          send_message(chat_id, response, thread_id) if response && !response.empty?
        end
      rescue StandardError => e
        warn "[cron] Callback error: #{e.class}: #{e.message}"
      end

      # Handle /cron slash command
      def handle_cron_command(args)
        cron_tool = @agent.tools.get("cron")
        return [ :skip, "❌ Cron tool not available." ] unless cron_tool

        if args.nil? || args.empty?
          # List all cron jobs
          result = cron_tool.execute({ "operation" => "list" })
          [ :skip, result ]
        elsif args.start_with?("delete ")
          job_id = args[7..].strip
          result = cron_tool.execute({ "operation" => "remove", "job_id" => job_id })
          [ :skip, result ]
        elsif args.start_with?("enable ")
          job_id = args[7..].strip
          result = cron_tool.execute({ "operation" => "enable", "job_id" => job_id })
          [ :skip, result ]
        elsif args.start_with?("disable ")
          job_id = args[8..].strip
          result = cron_tool.execute({ "operation" => "disable", "job_id" => job_id })
          [ :skip, result ]
        else
          [ :skip, "❌ Unknown /cron subcommand. Use:\n/cron — list jobs\n/cron delete <id>\n/cron enable <id>\n/cron disable <id>" ]
        end
      rescue StandardError => e
        [ :skip, "❌ Error: #{e.message}" ]
      end

      # --------------- Long Polling ---------------

      def get_updates
        params = {
          "offset" => @offset,
          "limit" => 10,
          "timeout" => DEFAULT_POLL_TIMEOUT
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

        # Set delivery context on cron tool so new jobs are tied to this chat/topic
        cron_tool = @agent.tools.get("cron")
        cron_tool.delivery_context = { chat_id: chat_id, thread_id: thread_id } if cron_tool

        warn "[telegram] #{username} (#{user_id})#{thread_id ? " [topic:#{thread_id}]" : ""}: #{text[0..80]}" if Rubot.debug?

        # Show typing indicator
        # Note: Telegram API has a known bug where typing indicators don't display
        # in the General topic of forum-enabled groups. See:
        # https://github.com/NousResearch/hermes-agent/issues/7877
        is_forum = message.dig("chat", "is_forum") == true
        is_general_topic = is_forum && thread_id.nil?
        if is_general_topic
          warn "[telegram] Skipping typing indicator for General topic (Telegram API limitation)" if Rubot.debug?
        else
          start_typing(chat_id, thread_id) if @config.fetch("typing_indicator", true)
        end

        response = process_message(text, session_id: session_id, on_tool_call: ->(tool_name, args) {
          notify_tool_started(chat_id, thread_id, tool_name, args)
        }, on_tool_result: ->(tool_name, result) {
          notify_tool_finished(chat_id, thread_id, tool_name, result)
        }, on_progress: ->(iteration, tool_count) {
          notify_progress(chat_id, thread_id, iteration)
        })

        stop_typing(chat_id, thread_id) unless is_general_topic

        # Clear any lingering status message before sending the real response
        clear_status_message

        if response && !response.empty?
          warn "[telegram] Sending response (#{response.length} chars)" if Rubot.debug?
          send_message(chat_id, response, thread_id)
        else
          warn "[telegram] No response to send" if Rubot.debug?
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

        # Convert standard Markdown to Telegram MarkdownV2
        converted_text = Rubot::TelegramMarkdown.convert(text)

        # Split long messages
        chunks = split_message(converted_text, max_length)
        chunks.each do |chunk|
          body = {
            "chat_id" => chat_id,
            "text" => chunk,
            "parse_mode" => "MarkdownV2"
          }
          body["message_thread_id"] = thread_id if thread_id
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

      # --------------- Streaming ---------------

      # Override from base Channel to support Telegram streaming
      def on_stream_chunk(chunk)
        nil unless @config.fetch("stream", false)
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

      # --------------- Tool Progress Notifications ---------------

      TOOL_EMOJIS = {
        "shell_exec"  => "💻",
        "file_ops"    => "📄",
        "web_fetch"   => "🌐",
        "memory"      => "🧠",
        "cron"        => "⏰",
      }.freeze

      # Called before a tool executes. Updates the status message to show what's running.
      def notify_tool_started(chat_id, thread_id, tool_name, args)
        warn "[telegram] notify_tool_started: #{tool_name}" if Rubot.debug?
        @status_mutex.synchronize do
          @tool_count += 1
        end
        emoji = TOOL_EMOJIS[tool_name] || "⚙️"

        preview = case tool_name
                  when "shell"
                    # Pre block content is literal in MarkdownV2, no escaping needed
                    "```\n#{truncate(args["command"] || "...", 80)}\n```"
                  when "file"
                    "#{md_escape(args["operation"] || "read")}: #{md_escape(truncate(args["path"] || "...", 60))}"
                  when "web", "search"
                    "query: #{md_escape(truncate(args["query"] || args["url"] || "...", 60))}"
                  when "fetch"
                    "url: #{md_escape(truncate(args["url"] || "...", 60))}"
                  when "memory"
                    "operation: #{md_escape(args["operation"] || "...")}"
                  when "cron"
                    "operation: #{md_escape(args["operation"] || "...")}"
                  else
                    "#{md_escape(args.keys.first)}: #{md_escape(truncate(args.values.first.to_s, 60))}"
                  end

        count = @status_mutex.synchronize { @tool_count }
        # Inline code content is also literal in MarkdownV2, no escaping needed for tool_name
        text = "#{emoji} *Running tool:* `#{tool_name}`\n"
        text += "Step #{count}\n\n"
        text += preview

        warn "[telegram] Sending status message: #{text[0..100]}" if Rubot.debug?

        # Edit existing status message or send a new one
        update_or_send_status(chat_id, thread_id, text)
      end

      # Called after a tool finishes. Briefly shows completion before next tool starts.
      def notify_tool_finished(chat_id, thread_id, tool_name, result)
        # We don't send a separate "done" message — the next tool_call or final
        # response will overwrite the status. But we log it for debugging.
        warn "[telegram] Tool #{tool_name} finished" if Rubot.debug?
      end

      # Called after each tool-call iteration loop. Shows progress for multi-step operations.
      def notify_progress(chat_id, thread_id, iteration)
        return unless iteration >= 2  # Only notify after 2+ iterations

        emoji = "🔄"
        text = "#{emoji} *Still working* \(iteration #{iteration}\)\n"
        text += "_Running tool calls to complete your request_"

        update_or_send_status(chat_id, thread_id, text)
      end

      # Send a new status message or edit the existing one (avoids message spam).
      def update_or_send_status(chat_id, thread_id, text)
        return unless @config.fetch("tool_notifications", true)

        warn "[telegram] update_or_send_status: existing=#{!!@status_message}, chat_id=#{chat_id}" if Rubot.debug?

        if @status_message && @status_message[:chat_id] == chat_id && @status_message[:thread_id] == thread_id
          # Edit the existing status message
          edit_message(chat_id, @status_message[:message_id], text, thread_id)
        else
          # Send a new status message
          msg_id = send_message_with_id(chat_id, text, thread_id)
          warn "[telegram] Status message sent, id=#{msg_id}" if Rubot.debug?
          @status_mutex.synchronize do
            @status_message = { chat_id: chat_id, thread_id: thread_id, message_id: msg_id }
          end
        end
      end

      # Delete the current status message (called before sending the final response).
      def clear_status_message
        @status_mutex.synchronize do
          @tool_count = 0
          return unless @status_message
          chat_id = @status_message[:chat_id]
          message_id = @status_message[:message_id]
          @status_message = nil
          chat_id && message_id ? delete_message(chat_id, message_id) : nil
        end
      end

      # Send a message and return the message_id (for later editing/deletion).
      def send_message_with_id(chat_id, text, thread_id = nil)
        max_length = @config.fetch("max_message_length", DEFAULT_MAX_LENGTH)
        chunks = split_message(text, max_length)
        last_id = nil

        chunks.each do |chunk|
          body = {
            "chat_id" => chat_id,
            "text" => chunk,
            "parse_mode" => "MarkdownV2"
          }
          body["message_thread_id"] = thread_id if thread_id
          url = URI("#{API_BASE}#{@token}/sendMessage")
          req = Net::HTTP::Post.new(url)
          req["Content-Type"] = "application/json"
          req.body = body.to_json

          begin
            result = http_post(url, req)
            if result["ok"]
              last_id = result["result"]["message_id"]
            else
              warn "[telegram] API error: #{result["description"]}"
            end
          rescue StandardError => e
            warn "[telegram] Failed to send message: #{e.message}"
          end
        end
        last_id
      end

      # Edit an existing message by ID (used for status updates).
      def edit_message(chat_id, message_id, text, thread_id = nil)
        body = {
          "chat_id" => chat_id,
          "message_id" => message_id,
          "text" => text,
          "parse_mode" => "MarkdownV2"
        }
        url = URI("#{API_BASE}#{@token}/editMessageText")
        req = Net::HTTP::Post.new(url)
        req["Content-Type"] = "application/json"
        req.body = body.to_json

        begin
          result = http_post(url, req)
          unless result["ok"]
            warn "[telegram] Edit message error: #{result["description"]}"
          end
        rescue StandardError => e
          warn "[telegram] Failed to edit message: #{e.message}"
        end
      end

      # Delete a message by ID.
      def delete_message(chat_id, message_id)
        body = { "chat_id" => chat_id, "message_id" => message_id }
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

      def truncate(str, max_len)
        return str unless str && str.length > max_len
        str[0, max_len] + "…"
      end

      # Escape a string for Telegram MarkdownV2 parse mode.
      # All special chars must be prefixed with a backslash:
      #   _ * [ ] ( ) ~ ` > # + - = | { } . ! \ 
      def md_escape(str)
        return "" unless str
        str.gsub(/([_*\[\]()~`>#+\-=|{}.!\\])/) { "\\" + $1 }
      end
    end
  end
end
