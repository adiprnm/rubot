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
        # Per-chat status tracking — keyed by "#{chat_id}:#{thread_id}"
        # so concurrent requests to different chats don't interfere.
        @status_messages = {}   # chat_thread_key => { chat_id:, thread_id:, message_id: }
        @tool_counts = {}       # chat_thread_key => Integer
        @status_mutex = Mutex.new
        @active_threads = []   # Track spawned threads for cleanup
        @threads_mutex = Mutex.new
        # Limit concurrent request processing (prevents overwhelming the LLM API)
        max_concurrent = @config.fetch("max_concurrent_requests", 10)
        @request_semaphore = Mutex.new
        @request_slots = max_concurrent
        @request_cv = ConditionVariable.new
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
        # Wait for active request threads to finish
        wait_for_threads
      end

      # Wait for all spawned request threads to complete.
      def wait_for_threads
        loop do
          threads = @threads_mutex.synchronize { @active_threads.dup }
          break if threads.empty?
          threads.each { |t| t.join(1) }
          @threads_mutex.synchronize { @active_threads.reject! { |t| !t.alive? } }
        end
      end

      # Acquire a slot from the request semaphore (blocks if at capacity).
      def acquire_request_slot
        @request_semaphore.synchronize do
          while @request_slots <= 0
            @request_cv.wait(@request_semaphore)
          end
          @request_slots -= 1
        end
      end

      # Release a slot back to the request semaphore.
      def release_request_slot
        @request_semaphore.synchronize do
          @request_slots += 1
          @request_cv.signal
        end
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
            updates.each do |update|
              # Spawn each update in its own thread for concurrent processing.
              # The per-session mutex (in Channel#process_message) ensures that
              # messages to the same session are serialized.
              t = Thread.new(update) do |u|
                acquire_request_slot
                begin
                  process_update(u)
                ensure
                  release_request_slot
                end
              end
              @threads_mutex.synchronize { @active_threads << t }
            end

            # Reap finished threads periodically to avoid memory growth
            @threads_mutex.synchronize { @active_threads.reject! { |t| !t.alive? } }
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
        ra = request_agent
        info = ra.startup_info
        lines = info.map { |k, v| "#{k}: #{v}" }
        [ :skip, "ℹ️ Agent Info\n\n" + lines.join("\n") ]
      end

      def handle_models_command
        ra = request_agent
        models = ra.config.models
        active = ra.active_model_name

        if models.empty?
          [ :skip, "🧠 No models configured in config.yml." ]
        else
          lines = models.map do |m|
            marker = m["name"] == active ? "→ " : "  "
            "#{marker}**#{m["name"]}** (`#{m["model"]}`)"
          end
          [ :skip, "🧠 **Available Models**\n\n" + lines.join("\n") ]
        end
      end

      def handle_model_command
        ra = request_agent
        active = ra.active_model_name
        entry = ra.config.model_entry_by_name(active) || ra.config.active_model_entry
        text = "🧠 **Current Model**\n\n**#{active}** (`#{entry['model']}`)\nProvider: `#{ra.provider.name}`"
        text += "\n_Session override — cleared on /new_" if ra.session.model_override
        [ :skip, text ]
      end

      def handle_use_model_command(model_name)
        ra = request_agent
        if model_name.nil? || model_name.empty?
          models = ra.config.models
          if models.empty?
            [ :skip, "⚠️ Usage: `/use_model <model_name>`\n\nNo models configured." ]
          else
            list = models.map { |m| "• **#{m['name']}**" }.join("\n")
            [ :skip, "⚠️ Usage: `/use_model <model_name>`\n\nAvailable models:\n#{list}" ]
          end
        else
          result = ra.use_model(model_name)
          if result
            entry = ra.config.model_entry_by_name(result)
            [ :skip, "✅ Switched to model: **#{result}** (`#{entry['model']}`)\nProvider: `#{ra.provider.name}`\n_Persists for this session (cleared on /new)_" ]
          else
            models = ra.config.models
            list = models.map { |m| "• **#{m['name']}**" }.join("\n")
            [ :skip, "❌ Model `#{model_name}` not found in config.yml.\n\n*Available models:*\n#{list}" ]
          end
        end
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
          request_agent.clear_session
          [ :skip, "✨ Started a new session. Previous conversation has been cleared." ]
        when "/help"
          bot_name = @config.fetch("bot_name", "Rubot")
          [ :skip, "📖 Help | #{bot_name}\n\nJust send me a message and I'll do my best to help.\n\nBuilt-in commands:\n/start - Start the bot\n/new - Clear chat and start a new session\n/help - Show this help message\n/info - Show agent info\n/models - List available models\n/model - Show current model\n/use_model <name> - Switch model for this session\n/skills - List available skills\n/memory - Show persistent memory\n/soul - Show bot personality\n/agents - Show agent rules\n/cron - List scheduled cron jobs\n/cron delete <id> - Delete a cron job\n/use <skill> - Force a skill for the next message\n/unuse - Clear the forced skill" ]
        when "/info"
          handle_info_command
        when "/models"
          handle_models_command
        when "/model"
          handle_model_command
        when /^\/use_model(\s+(.*))?$/
          handle_use_model_command($2&.strip)
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
        when /^\/use(\s+(.*))?$/
          handle_use_command($2&.strip)
        when "/unuse"
          handle_unuse_command
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
          { "command" => "models", "description" => "List available models" },
          { "command" => "model", "description" => "Show current model" },
          { "command" => "use_model", "description" => "Switch model for this session" },
          { "command" => "skills", "description" => "List available skills" },
          { "command" => "memory", "description" => "Show persistent memory" },
          { "command" => "soul", "description" => "Show bot personality" },
          { "command" => "agents", "description" => "Show agent rules" },
          { "command" => "cron", "description" => "List scheduled cron jobs" },
          { "command" => "use", "description" => "Force a skill for the next message" },
          { "command" => "unuse", "description" => "Clear the forced skill" }
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
          # Process through the LLM with a per-request agent clone to avoid
          # cross-session interference when cron fires concurrently with user requests.
          session_id = thread_id ? "tg_#{chat_id}_#{thread_id}" : "tg_#{chat_id}"
          response = session_lock(session_id).synchronize do
            request_agent = @agent.for_session(session_id)
            request_agent.process_cron(result[:result][:agent_message])
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

      # Handle /use <skill-name> command
      def handle_use_command(skill_name)
        ra = request_agent
        return [ :skip, "⚠️ Usage: /use <skill-name>\n\nAvailable skills:\n#{list_skills_text}" ] if skill_name.nil? || skill_name.empty?

        registry = ra.skill_registry
        registry.reload!
        skill = registry.get(skill_name)

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

      def list_skills_text
        ra = request_agent
        registry = ra.skill_registry
        registry.reload!
        return "No skills installed." unless registry.any?

        registry.all.values.map { |s| "• **#{s.name}** — #{s.summary}" }.join("\n")
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
            # Process in a thread so webhook handler doesn't block other requests
            t = Thread.new(update) do |u|
              acquire_request_slot
              begin
                process_update(u)
              ensure
                release_request_slot
              end
            end
            @threads_mutex.synchronize { @active_threads << t }
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
        clear_status_message(chat_id, thread_id)

        if response && !response.empty?
          warn "[telegram] Sending response (#{response.length} chars)" if Rubot.debug?
          ok = send_message(chat_id, response, thread_id)
          unless ok
            warn "[telegram] Retrying with plain text (markdown may be invalid)"
            send_message_plain(chat_id, response, thread_id)
          end
        else
          warn "[telegram] ⚠️ Empty response — agent produced no text output"
          send_message(chat_id, "⚠️ I completed processing but have no text result to share.", thread_id)
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

      # Send a message to Telegram. Returns true if all chunks sent successfully.
      def send_message(chat_id, text, thread_id = nil)
        max_length = @config.fetch("max_message_length", DEFAULT_MAX_LENGTH)

        # Convert standard Markdown to Telegram MarkdownV2
        converted_text = Rubot::TelegramMarkdown.convert(text)

        # Split long messages
        chunks = split_message(converted_text, max_length)
        all_ok = true
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
              all_ok = false
            end
          rescue StandardError => e
            warn "[telegram] Failed to send message: #{e.message}"
            all_ok = false
          end
        end
        all_ok
      end

      # Send a message without MarkdownV2 (plain text fallback for retries).
      def send_message_plain(chat_id, text, thread_id = nil)
        max_length = @config.fetch("max_message_length", DEFAULT_MAX_LENGTH)
        chunks = split_message(text, max_length)
        all_ok = true
        chunks.each do |chunk|
          body = { "chat_id" => chat_id, "text" => chunk }
          body["message_thread_id"] = thread_id if thread_id
          url = URI("#{API_BASE}#{@token}/sendMessage")
          req = Net::HTTP::Post.new(url)
          req["Content-Type"] = "application/json"
          req.body = body.to_json

          begin
            result = http_post(url, req)
            unless result["ok"]
              warn "[telegram] Plain text send error: #{result["description"]}"
              all_ok = false
            end
          rescue StandardError => e
            warn "[telegram] Failed to send plain text: #{e.message}"
            all_ok = false
          end
        end
        all_ok
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
        key = status_key(chat_id, thread_id)
        @status_mutex.synchronize do
          @tool_counts[key] ||= 0
          @tool_counts[key] += 1
        end
        emoji = TOOL_EMOJIS[tool_name] || "⚙️"

        preview = case tool_name
                  when "shell_exec"
                    "```\n#{truncate(args["command"] || "...", 80)}\n```"
                  when "file_ops"
                    "#{args["operation"] || "read"}: #{truncate(args["path"] || "...", 60)}"
                  when "web_fetch"
                    "query: #{truncate(args["query"] || args["url"] || "...", 60)}"
                  when "memory"
                    "operation: #{args["operation"] || "..."}"
                  when "cron"
                    "operation: #{args["operation"] || "..."}"
                  else
                    "#{args.keys.first}: #{truncate(args.values.first.to_s, 60)}"
                  end

        count = @status_mutex.synchronize { @tool_counts[key] }
        text = "#{emoji} **Running tool:** `#{tool_name}`\n"
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
        text = "#{emoji} **Still working** (iteration #{iteration})\n"
        text += "_Running tool calls to complete your request_"

        update_or_send_status(chat_id, thread_id, text)
      end

      # Send a new status message or edit the existing one (avoids message spam).
      def update_or_send_status(chat_id, thread_id, text)
        return unless @config.fetch("tool_notifications", true)

        # Convert standard Markdown to Telegram MarkdownV2 to ensure
        # all reserved characters are properly escaped.
        converted_text = Rubot::TelegramMarkdown.convert(text)

        key = status_key(chat_id, thread_id)
        existing = @status_mutex.synchronize { @status_messages[key] }
        warn "[telegram] update_or_send_status: existing=#{!!existing}, key=#{key}" if Rubot.debug?

        if existing
          # Edit the existing status message
          edit_message(chat_id, existing[:message_id], converted_text, thread_id)
        else
          # Send a new status message
          msg_id = send_message_with_id(chat_id, converted_text, thread_id)
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

      # Delete the status message for a specific chat/thread (called before sending the final response).
      def clear_status_message(chat_id, thread_id)
        key = status_key(chat_id, thread_id)
        @status_mutex.synchronize do
          info = @status_messages.delete(key)
          @tool_counts.delete(key)
          return unless info
          delete_message(info[:chat_id], info[:message_id]) if info[:chat_id] && info[:message_id]
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

    end
  end
end
