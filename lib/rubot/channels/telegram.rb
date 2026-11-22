# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "fileutils"
require "thread"
require "securerandom"

require_relative "../formatting"
require_relative "../image_info"
require_relative "../model_catalog"
require_relative "../persona"
require_relative "../persona_store"
require_relative "../session"
require_relative "../telegram_format"
require_relative "../usage"
require_relative "../opencode_usage"
require_relative "telegram/attachments"
require_relative "telegram/commands"
require_relative "telegram/status"
require_relative "telegram/transport"

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
    #       status_edit_interval: 1.0        # min seconds between edits of the live status card (floor 1.0)
    #       max_message_length: 4096         # Telegram's max message length
    #       attachments: true                # download inbound photos/documents
    #
    # Inbound media is saved under `<workspace>/attachments/<session>/` and its
    # local path is appended to the user's text, so the agent can read the file
    # with its normal tools. Telegram never puts media in "text" — photos and
    # captions arrive as `photo` + `caption` — which is why captions must be
    # read explicitly.
    class Telegram < Channel
      API_BASE = "https://api.telegram.org/bot"
      DEFAULT_MAX_LENGTH = 4096
      DEFAULT_POLL_TIMEOUT = 60
      # Words /auto accepts besides a bare flip.
      AUTO_TOGGLE = { "on" => true, "true" => true, "yes" => true, "1" => true,
                      "off" => false, "false" => false, "no" => false, "0" => false }.freeze
      PERSONA_WIZARD_TTL = 15 * 60
      # A quoted message is prepended to the prompt, so it competes with the
      # user's own text and the model's output budget. Telegram caps messages at
      # 4096 chars; anything longer is cut with a marker the model can see.
      MAX_REPLY_QUOTE_CHARS = 4096

      # Talking to the Bot API: see telegram/transport.rb.
      include Transport

      # Reading inbound media: see telegram/attachments.rb.
      include Attachments

      # The typing indicator and the live status card: see telegram/status.rb.
      include Status

      # The slash commands: see telegram/commands.rb.
      include Commands

      def initialize(agent: nil, pool: nil, app_config: nil, channel_config: {})
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
        # What the live status card is describing. Kept apart from
        # @status_messages because a narration deletes the message but the
        # step numbering and the elapsed clock must survive it.
        @status_state = {}      # chat_thread_key => { tool_name:, emoji:, preview:, step:,
                                #                     started_at:, finished:, round:, hint_sent: }
        # Delegated work in flight, keyed by run id, so the status card can say
        # how many sub agents are running and what each is doing.
        @subagents = {}         # chat_thread_key => { run_id => { agent:, phase:, detail: } }
        @status_last_text = {}  # chat_thread_key => String last rendered
        @status_last_edit = {}  # chat_thread_key => Float monotonic seconds
        @last_retry_after = 0   # seconds Telegram asked us to wait after a 429
        # chat_id => monotonic deadline. Set whenever Telegram answers 429, so
        # every send and edit for that chat stays quiet until it passes.
        @flood_until = {}
        @flood_mutex = Mutex.new
        @status_mutex = Mutex.new
        @active_threads = []   # Track spawned threads for cleanup
        @threads_mutex = Mutex.new
        # Limit concurrent request processing (prevents overwhelming the LLM API)
        max_concurrent = @config.fetch("max_concurrent_requests", 10)
        @request_semaphore = Mutex.new
        @request_slots = max_concurrent
        @request_cv = ConditionVariable.new
        # Confirmation tracking — keyed by confirmation_id
        @pending_confirmations = {}  # id => { cv:, result:, chat_id:, thread_id: }
        @confirm_mutex = Mutex.new
        # Per-topic persona wizard state, guarded by its own mutex.
        @persona_wizards = {} # "chat:thread" => wizard Hash
        @persona_mutex = Mutex.new
        @persona_store = nil
        @model_catalog = nil
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
        stop_learning_worker
        shutdown_pool
      end

      # A chat turn is over the moment the answer has been sent. Anything the
      # session does afterwards — naming the conversation, extracting memory,
      # learning from a correction — is a provider request the person on the
      # other end is not waiting for, so it runs on the learning queue.
      def defer_learning?
        true
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
        when "/stop"
          if cancel_session(request_session_id)
            [ :skip, "⏹️ Stopped the running task." ]
          else
            [ :skip, "ℹ️ Nothing is running." ]
          end
        when "/compact"
          handle_compact_command
        when "/repin"
          handle_repin_command
        when "/help"
          bot_name = @config.fetch("bot_name", "Rubot")
          [ :skip, "📖 Help | #{bot_name}\n\nJust send me a message and I'll do my best to help. While a task is still running, a plain message steers it instead of waiting behind it.\n\nBuilt-in commands:\n/start - Start the bot\n/new - Clear chat and start a new session\n/stop - Stop the task that is running\n/compact - Summarize older messages to free context\n/repin - Rebuild the system prompt on the next message (picks up memory and skills, costs one uncached request)\n/help - Show this help message\n/info - Show agent info\n/model - Show current model preset\n/model <preset> - Switch preset for this session\n/models - List model presets\n/preset - Manage model presets\n/preset set <name> <model> - Create/update a preset\n/preset default <name> - Preset for new sessions\n/preset models - List models supported by the provider\n/use_model <preset> - Alias for /model <preset>\n/persona - Setup persona for this forum topic\n/persona show - Show this topic's persona\n/persona reset - Remove this topic's persona\n/cancel - Cancel the persona setup\n/skills - List available skills\n/memory - Show persistent memory\n/soul - Show bot personality\n/agents - Show agent rules\n/cron - List scheduled cron jobs\n/context - Context usage, cache hit rate, and estimated cost\n/usage - OpenCode Go subscription usage\n/cron delete <id> - Delete a cron job\n/use <skill> - Force a skill for the next message\n/unuse - Clear the forced skill\n/auto on|off - Run non-destructive actions without asking (remembered)" ]
        when "/info"
          handle_info_command
        when "/context"
          handle_context_command
        when "/usage"
          handle_usage_command
        when "/models"
          handle_models_command
        when "/model"
          handle_model_command
        when /^\/model(\s+(.*))?$/
          handle_model_command($2&.strip)
        when /^\/use_model(\s+(.*))?$/
          handle_use_model_command($2&.strip)
        when /^\/preset(\s+(.*))?$/
          handle_preset_command($2&.strip)
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
        when /^\/auto(\s+(.*))?$/
          handle_auto_command($2&.strip)
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
          { "command" => "stop", "description" => "Stop the task that is running" },
          { "command" => "compact", "description" => "Summarize older messages to free context" },
          { "command" => "help", "description" => "Show help message" },
          { "command" => "info", "description" => "Show agent info" },
          { "command" => "usage", "description" => "Context usage, cache hit rate, and cost" },
          { "command" => "models", "description" => "List model presets" },
          { "command" => "model", "description" => "Show or switch the model preset" },
          { "command" => "preset", "description" => "Manage model presets" },
          { "command" => "use_model", "description" => "Alias for /model <preset>" },
          { "command" => "persona", "description" => "Setup persona for this forum topic" },
          { "command" => "cancel", "description" => "Cancel the persona setup" },
          { "command" => "skills", "description" => "List available skills" },
          { "command" => "memory", "description" => "Show persistent memory" },
          { "command" => "soul", "description" => "Show bot personality" },
          { "command" => "agents", "description" => "Show agent rules" },
          { "command" => "cron", "description" => "List scheduled cron jobs" },
          { "command" => "use", "description" => "Force a skill for the next message" },
          { "command" => "unuse", "description" => "Clear the forced skill" },
          { "command" => "auto", "description" => "Auto mode: skip confirmations for safe actions" }
        ]

        url = URI("#{API_BASE}#{@token}/setMyCommands")

        # BotCommandScopeDefault alone is not enough: some clients only show a
        # bot's slash menu in a group when the commands are registered for a
        # group scope, not inherited from the default.
        scopes = [
          { "type" => "default" },
          { "type" => "all_private_chats" },
          { "type" => "all_group_chats" }
        ]

        begin
          scopes.each do |scope|
            req = Net::HTTP::Post.new(url)
            req["Content-Type"] = "application/json"
            req.body = { "commands" => commands, "scope" => scope }.to_json

            result = http_post(url, req)
            unless result["ok"]
              warn "[telegram] Failed to register commands for #{scope['type']}: #{result['description']}"
            end
          end
          warn "[telegram] Registered #{commands.size} bot commands for #{scopes.size} scopes." if Rubot.debug?
        rescue StandardError => e
          warn "[telegram] Error registering commands: #{e.message}"
        end
      end

      # --------------- Cron Scheduler ---------------

      def start_cron_scheduler
        # In actor mode the CronActor owns the scheduler and delivers events
        # on the channel's cron port.
        if actor_mode?
          start_cron_listener { |result| cron_fire_callback(result) }
          return
        end

        cron_tool = @agent.tools.get("cron")
        return unless cron_tool

        cron_tool.on_fire do |result|
          cron_fire_callback(result)
        end

        scheduler = cron_tool.scheduler
        scheduler.start
      end

      def stop_cron_scheduler
        if actor_mode?
          stop_cron_listener
          return
        end

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
          # Each session is serialized by its own actor, so cron turns can
          # safely run concurrently with user requests.
          session_id = thread_id ? "tg_#{chat_id}_#{thread_id}" : "tg_#{chat_id}"
          response = session_for(session_id).process_cron(result[:result][:agent_message])
          send_message(chat_id, response, thread_id) if response && !response.empty?
        end
      rescue StandardError => e
        warn "[cron] Callback error: #{e.class}: #{e.message}"
      end

      # Handle /cron slash command
      def handle_cron_command(args)
        cron_tool = request_agent.tools.get("cron")
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
        elsif args.start_with?("show ")
          job_id = args[5..].strip
          result = cron_tool.execute({ "operation" => "detail", "job_id" => job_id })
          [ :skip, result ]
        else
          [ :skip, "❌ Unknown /cron subcommand. Use:\n/cron — list jobs\n/cron show <id>\n/cron delete <id>\n/cron enable <id>\n/cron disable <id>" ]
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
        # Handle callback queries (inline button clicks — e.g., action confirmations)
        callback_query = update["callback_query"]
        if callback_query
          handle_callback_query(callback_query)
          return
        end

        # Handle different update types
        message = update["message"] || update["edited_message"] || update["channel_post"]
        return unless message

        chat_id = message["chat"]["id"]
        text = message["text"]
        caption = message["caption"]
        thread_id = message["message_thread_id"]

        # Check allowed users/chats before touching the network or the disk.
        return unless authorized?(chat_id, message)

        # A newly created forum topic gets its own persona wizard. Telegram
        # sends this service message before any user text, so it has to be
        # handled before the "nothing to read" guard below.
        if message["forum_topic_created"]
          start_persona_wizard(chat_id, thread_id, only_if_new: true)
          return
        end

        # Persona commands need the chat/topic context, which is only known
        # here (before_process receives just the text).
        if text && !text.strip.empty?
          command = persona_command(text)
          case command&.fetch(:name)
          when "/cancel"
            handle_cancel_command(chat_id, thread_id)
            return
          when "/stop"
            handle_stop_command(chat_id, thread_id)
            return
          when "/persona"
            handle_persona_command(chat_id, thread_id, command[:args])
            return
          end

          # While the wizard waits for a system prompt, the next plain text
          # belongs to the wizard, not to the agent.
          if intercept_persona_prompt(chat_id, thread_id, text)
            return
          end
        end

        # Fallback for bots that cannot see forum_topic_created (privacy mode
        # on, or not an admin): the first message in a brand-new topic opens
        # the wizard. The message itself is still processed below.
        maybe_start_persona_wizard_for_new_topic(chat_id, thread_id)

        user_id = message["from"] ? message["from"]["id"] : chat_id
        username = message.dig("from", "username") || "User##{user_id}"

        # Per-topic (or per-DM) session isolation
        session_id = topic_session_id(chat_id, thread_id)

        attachments, unsupported_media = extract_attachments(message)
        body = text.to_s.strip.empty? ? caption : text
        body = body.to_s.strip

        # Nothing the agent can read. Answer explicitly instead of dropping the
        # update silently, which looks exactly like a broken bot to the user.
        if body.empty? && attachments.empty?
          if unsupported_media
            warn "[telegram] Unsupported media from #{username}: #{unsupported_media}" if Rubot.debug?
            send_message(chat_id, "⚠️ I can't read #{unsupported_media} yet. " \
                                  "Send text, or a screenshot as a photo or file.", thread_id)
          end
          return
        end

        # A plain-text message that arrives while this session is still
        # working steers the running turn instead of waiting behind it, the
        # same way typing mid-turn does in the TUI. Commands are handled
        # above, and media keeps its own turn: it is downloaded and described,
        # which a steer has no room for.
        reply_note = reply_context(message, session_id, chat_id)
        if attachments.empty? && !body.start_with?("/") && session_running?(session_id)
          steer_text = [ body, reply_note ].compact.reject(&:empty?).join("\n\n")
          if steer_session(session_id, steer_text)
            warn "[telegram] Steering the running turn: #{username}: #{body[0..120]}" if Rubot.debug?
            send_message(chat_id, "↳ Diteruskan ke tugas yang sedang berjalan.", thread_id)
            return
          end
        end

        notes = attachments.map { |attachment| receive_attachment(attachment, session_id, chat_id) }
        prompt = [ body, reply_note, *notes ].compact.reject(&:empty?).join("\n\n")

        # Track last active chat for cron message delivery
        @last_chat_id = chat_id
        @last_thread_id = thread_id

        # Set delivery context on the session's cron tool so new jobs are
        # tied to this chat/topic, and on the file tools so a generated image
        # comes back here.
        bind_delivery_context(session_id, chat_id, thread_id)

        warn "[telegram] #{username} (#{user_id})#{thread_id ? " [topic:#{thread_id}]" : ""}: #{prompt[0..120]}" if Rubot.debug?

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

        response = process_message(prompt, session_id: session_id, on_assistant_text: ->(narration) {
          send_narration(chat_id, thread_id, narration)
        }, on_tool_call: ->(tool_name, args, _snapshot) {
          notify_tool_started(chat_id, thread_id, tool_name, args)
        }, on_tool_result: ->(tool_name, result, _ui_diff) {
          notify_tool_finished(chat_id, thread_id, tool_name, result)
        }, on_subagent: ->(info) {
          notify_subagent(chat_id, thread_id, info)
        }, on_progress: ->(round, tool_count) {
          notify_progress(chat_id, thread_id, round)
        }, on_confirm: ->(tool_name, args, reason) {
          ask_confirmation(chat_id, thread_id, tool_name, args, reason)
        })

        stop_typing(chat_id, thread_id) unless is_general_topic

        # Clear any lingering status message before sending the real response
        clear_status_message(chat_id, thread_id)

        if response && !response.empty?
          warn "[telegram] Sending response (#{response.length} chars)" if Rubot.debug?
          # send_message already falls back to plain text per chunk, so there is
          # nothing left to retry here — a second pass would duplicate messages.
          warn "[telegram] Some chunks could not be delivered" unless send_message(chat_id, response, thread_id)
        else
          warn "[telegram] ⚠️ Empty response — agent produced no text output"
          send_message(chat_id, "⚠️ I completed processing but have no text result to share.", thread_id)
        end
      end

      # In legacy (in-process agent) mode, rebuild the per-session agent with
      # the persona stored for that topic. In actor mode the SessionPool reads
      # the persona when it spawns the actor.
      # Tell this turn's tools where they are: the chat and topic for delivery,
      # and for cron the directory whose store should hold a new reminder. Each
      # session actor owns its own tools, so this does not leak across topics.
      def bind_delivery_context(session_id, chat_id, thread_id)
        context = { chat_id: chat_id, thread_id: thread_id }

        cron_tool = session_for(session_id).tools.get("cron")
        if cron_tool
          cron_tool.delivery_context = context.merge(workspace: session_workspace(session_id))
        end

        # Let the agent send files back to this chat (e.g. generated images),
        # one at a time or as a batch in a single call.
        tool = session_for(session_id).tools.get("send_files")
        tool.delivery_context = context if tool
      end

      def session_for(session_id)
        return super if actor_mode? || @agent.nil?

        persona = persona_store.get_by_session(session_id)
        @agent.for_session(session_id, persona: persona&.to_h)
      end

      # --------------- Per-topic Persona ---------------

      def persona_store
        @persona_store ||= begin
          config = persona_config
          PersonaStore.new(
            dir: persona_dir,
            legacy_workspace: persona_workspace,
            available_models: persona_models.map { |model| model["name"] },
            available_presets: config ? config.model_preset_names : [ "default" ]
          )
        end
      end

      # Personas live next to config.yml so the web channel and this one read
      # the same file. Telegram topics keep model + prompt only and never get a
      # workspace of their own.
      def persona_dir
        config = persona_config
        return File.dirname(config.config_path) if config

        File.join(Dir.home, ".rubot")
      end

      def persona_workspace
        return @app_config.workspace if @app_config
        return @pool.workspace if @pool.respond_to?(:workspace) && @pool.workspace
        return @agent.config.workspace if @agent.respond_to?(:config) && @agent.config

        File.join(Dir.home, ".rubot", "workspace")
      end

      # The directory a session's agent actually runs in: the persona's own
      # when it has one, the default workspace otherwise. The cron tool needs
      # it to file a reminder where it was written.
      def session_workspace(session_id)
        rooted = @pool.workspace_for_session(session_id) if actor_mode? && @pool.respond_to?(:workspace_for_session)
        rooted || persona_workspace
      end

      def persona_config
        @app_config || (@agent.respond_to?(:config) ? @agent.config : nil)
      end

      def model_catalog
        return @model_catalog if @model_catalog

        config = persona_config
        return nil unless config

        @model_catalog = ModelCatalog.new(config: config)
      end

      # Config model entries (the fallback when the provider cannot list models).
      def config_model_entries
        config = persona_config
        models = if config
          config.models
        elsif @pool.respond_to?(:models)
          @pool.models
        else
          []
        end
        models.is_a?(Array) ? models.select { |model| model.is_a?(Hash) && model["name"] } : []
      end

      # The provider's /models catalog plus any config entries that are not
      # represented there. Each choice:
      #   "name"  => value stored on the persona (config name or provider id)
      #   "model" => provider model id (or "openai/..." for config entries)
      #   "label" => human-friendly name for the button
      def persona_models
        config_entries = config_model_entries
        catalog = model_catalog&.entries || []

        if catalog.empty?
          return config_entries.map do |entry|
            { "name" => entry["name"], "model" => entry["model"], "label" => entry["name"] }
          end
        end

        catalog_ids = catalog.to_h { |model| [ model["id"], true ] }
        choices = catalog.map do |model|
          { "name" => model["id"], "model" => model["id"], "label" => model["name"] }
        end

        config_entries.each do |entry|
          next if catalog_ids[model_id_from_entry(entry)]

          choices << { "name" => entry["name"], "model" => entry["model"], "label" => entry["name"] }
        end

        choices
      end

      def model_id_from_entry(entry)
        model = entry["model"].to_s
        model.include?("/") ? model.split("/").last : model
      end

      # Model presets, with the configured primary/default marked.
      def preset_choices
        config = persona_config
        return [] unless config

        primary = config.primary_model_preset_name
        names = config.model_preset_names
        # Do not list a separate implicit `default` when a named preset is
        # already the primary; they would resolve to the same model.
        names = names.reject { |name| name.casecmp?("default") } unless primary.casecmp?("default")

        names.filter_map do |name|
          preset = config.model_preset(name)
          next unless preset

          { "name" => name, "preset" => preset, "primary" => name.casecmp?(primary) }
        end
      end

      def preset_choice(name)
        wanted = name.to_s
        preset_choices.find { |choice| choice["name"].casecmp?(wanted) }
      end

      def persona_preset_label(name)
        return "(default)" if name.nil? || name.to_s.empty?

        config = persona_config
        preset = config&.model_preset(name)
        return name.to_s unless preset

        label = name.to_s
        label += " (primary)" if name.casecmp?(config.primary_model_preset_name)
        "#{label} (`#{preset['model']}`)"
      end

      def topic_session_id(chat_id, thread_id)
        thread_id ? "tg_#{chat_id}_#{thread_id}" : "tg_#{chat_id}"
      end

      def persona_topic_key(chat_id, thread_id)
        "#{chat_id}:#{thread_id}"
      end

      # Parse /persona and /cancel, tolerating the @BotName suffix groups add.
      def persona_command(text)
        normalized = text.strip.sub(/\A(\/[A-Za-z0-9_]+)@\S+/, '\\1')

        case normalized
        when %r{\A/persona(?:\s+(.*))?\z}i
          { name: "/persona", args: Regexp.last_match(1)&.strip }
        when %r{\A/cancel(?:\s+.*)?\z}i
          { name: "/cancel", args: nil }
        when %r{\A/stop(?:\s+.*)?\z}i
          { name: "/stop", args: nil }
        end
      end

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

      def handle_cancel_command(chat_id, thread_id)
        if cancel_persona_wizard(chat_id, thread_id)
          send_message(chat_id, "❌ Setup persona dibatalkan.", thread_id)
        else
          send_message(chat_id, "ℹ️ Tidak ada setup persona yang sedang berjalan.", thread_id)
        end
      end

      # /stop — stop the turn running in this chat/topic. The signal reaches
      # the session actor immediately (it does not queue behind the turn) and
      # kills any shell command the agent started.
      def handle_stop_command(chat_id, thread_id)
        session_id = topic_session_id(chat_id, thread_id)
        stopped = cancel_session(session_id)
        cancel_pending_confirmations(chat_id, thread_id)

        if stopped
          send_message(chat_id, "⏹️ Menghentikan tugas yang sedang berjalan…", thread_id)
        else
          send_message(chat_id, "ℹ️ Tidak ada tugas yang sedang berjalan.", thread_id)
        end
      rescue StandardError => e
        warn "[telegram] stop failed: #{e.class}: #{e.message}"
        send_message(chat_id, "❌ Gagal menghentikan tugas: #{e.message}", thread_id)
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

      # Sessions are central (next to config.yml), not in the workspace, so
      # this must not look in `persona_workspace/sessions` — that path stopped
      # being where sessions live and every topic then looked brand new.
      def sessions_dir
        config = persona_config
        return config.sessions_dir if config.respond_to?(:sessions_dir)

        File.join(persona_dir, "sessions")
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

      # --------------- Authorization ---------------

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

      # --------------- Inbound Reply Context ---------------

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

      # --------------- Action Confirmation ---------------

      CONFIRM_TIMEOUT_SECONDS = 120

      # Describe a dangerous action for the confirmation prompt. The tool's own
      # reason wins when it has one: it names the damage, not the tool.
      def describe_action(tool_name, args, reason = nil)
        return reason.to_s if reason && !reason.to_s.strip.empty?

        case tool_name
        when "shell_exec"
          "Shell command: `#{args["command"][0..120]}`"
        when "file_ops"
          "File operation: `#{args["operation"]}` on `#{args["path"]}`"
        else
          "#{tool_name}: #{args.inspect[0..120]}"
        end
      end

      # Name the action in the button message: "Overwrite the file" is a
      # question a user can answer; "Dangerous Action Detected" only startles.
      def confirmation_title(tool_name, args)
        operation = args.is_a?(Hash) ? args["operation"].to_s : ""
        case tool_name.to_s
        when "file_ops"
          operation == "delete" ? "Delete this file?" : "Overwrite this file?"
        when "shell_exec"
          "Run this command?"
        else
          "Confirm this action?"
        end
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

      # Send the model's own narration ("Let me check the structure first.") as a
      # regular chat message. Unlike the tool status, these are never edited or
      # deleted, so the conversation keeps a readable trace of what the bot did.
      # Controlled by `narration` (default: on) in the channel config.
      #
      # The tool status message is a live line about the current step, so it is
      # dropped before the narration goes out: the newest words from the model
      # must land at the bottom of the chat, and the next tool call opens a fresh
      # status message underneath them. Otherwise the previous card stays above
      # the narration that describes what happened after it.
      def send_narration(chat_id, thread_id, text)
        return unless @config.fetch("narration", true)

        text = text.to_s.strip
        return if text.empty?

        warn "[telegram] narration: #{text[0..80]}" if Rubot.debug?
        clear_status_message(chat_id, thread_id, reset_count: false)
        send_message(chat_id, text, thread_id)
      end

      # A sub agent changed phase. Record it and refresh the status card so the
      # reader sees how many are running and what each is doing. The card is
      # throttled like every other status edit, so a burst of tool events from
      # several sub agents does not flood the chat.

      def truncate(str, max_len)
        Rubot::Formatting.truncate(str, max_len)
      end

    end
  end
end
