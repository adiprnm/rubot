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
require_relative "telegram/messaging"
require_relative "telegram/persona"
require_relative "telegram/persona_wizard"
require_relative "telegram/scheduling"
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

      # The slash menu and the cron jobs: see telegram/scheduling.rb.
      include Scheduling

      # The slash commands: see telegram/commands.rb.
      include Commands

      # Who may talk, quoting and confirmations: see telegram/messaging.rb.
      include Messaging

      # Persona lookups, workspaces and presets: see telegram/persona.rb.
      include PersonaDirectory

      # The per-topic persona wizard: see telegram/persona_wizard.rb.
      include PersonaWizard

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
        # Questions from the ask_user tool, keyed by question id and waited on
        # the same way: a button press or the next typed message fills :result.
        @pending_questions = {}
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
          [ :skip, I18n.t("telegram.start") ]
        when "/new"
          request_agent.clear_session
          [ :skip, I18n.t("telegram.new_session") ]
        when "/stop"
          if cancel_session(request_session_id)
            [ :skip, I18n.t("telegram.stop.stopped") ]
          else
            [ :skip, I18n.t("telegram.stop.nothing") ]
          end
        when "/compact"
          handle_compact_command
        when "/repin"
          handle_repin_command
        when "/help"
          bot_name = @config.fetch("bot_name", "Rubot")
          [ :skip, "#{I18n.t("telegram.help.header", bot_name: bot_name)}\n\n" \
                    "#{I18n.t("telegram.help.lead")}\n\n#{I18n.t("telegram.help.commands")}" ]
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
        return if handle_persona_prompt(chat_id, thread_id, text)

        # Fallback for bots that cannot see forum_topic_created (privacy mode
        # on, or not an admin): the first message in a brand-new topic opens
        # the wizard. The message itself is still processed below.
        maybe_start_persona_wizard_for_new_topic(chat_id, thread_id)

        # A question from the ask_user tool is waiting for exactly this: the
        # next thing typed in this conversation is its answer, not a new
        # prompt. A command is not an answer, though: /stop has to keep
        # stopping, so anything starting with a slash goes its usual way.
        return if !text.to_s.start_with?("/") && deliver_question_answer(chat_id, thread_id, text)

        run_turn(message, chat_id, thread_id, text, caption)
      end

      # The three commands that answer from the topic rather than from a turn,
      # plus the reply the wizard is waiting for. Returns true when the text was
      # answered here and must not reach the agent.
      def handle_persona_prompt(chat_id, thread_id, text)
        return false if text.nil? || text.strip.empty?

        command = persona_command(text)
        case command&.fetch(:name)
        when "/cancel"
          handle_cancel_command(chat_id, thread_id)
          return true
        when "/stop"
          handle_stop_command(chat_id, thread_id)
          return true
        when "/persona"
          handle_persona_command(chat_id, thread_id, command[:args])
          return true
        end

        # While the wizard waits for a system prompt, the next plain text
        # belongs to the wizard, not to the agent.
        intercept_persona_prompt(chat_id, thread_id, text)
      end

      # What a readable message costs: who it is from, the files that came with
      # it, and whether it steers the turn already running instead of starting
      # one of its own.
      def run_turn(message, chat_id, thread_id, text, caption)
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

        start_turn(message, chat_id, thread_id, session_id, prompt)
      end

      # Run the turn with the typing indicator on, then put the answer back in
      # the topic the question came from.
      def start_turn(message, chat_id, thread_id, session_id, prompt)
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
        }, on_ask: ->(payload) {
          # Blocks this turn until a button is pressed or the next message
          # arrives; the answer travels back as the ask_user call's result.
          ask_question(chat_id, thread_id, payload)
        })

        stop_typing(chat_id, thread_id) unless is_general_topic

        # Clear any lingering status message before sending the real response
        clear_status_message(chat_id, thread_id)

        deliver_response(response, chat_id, thread_id)
      end

      # Say what happened: the answer, or the fact that there was no text to
      # send, which otherwise looks like the bot ignored the message.
      def deliver_response(response, chat_id, thread_id)
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
        when "file_write"
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
        when "file_write"
          operation == "delete" ? "Delete this file?" : "Overwrite this file?"
        when "shell_exec"
          "Run this command?"
        else
          "Confirm this action?"
        end
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

      # What a test may drive: the update loop and the pieces each update goes
      # through (the persona store, the status card, the transport, the
      # attachments, the wizard). A Telegram connection is the only other way
      # in, so these are public on purpose; anything not named here stays
      # private.
      public :attachment_filename, :attachments_root, :bind_delivery_context,
             :cancel_pending_confirmations, :clear_status_message, :deliver,
             :extract_attachments, :flood_remaining, :format_elapsed,
             :handle_stop_command, :maybe_start_persona_wizard_for_new_topic,
             :notify_progress, :notify_subagent, :notify_tool_started, :persona_store,
             :post_edit, :process_update, :register_bot_commands, :reply_context,
             :send_narration, :status_key, :track_running_session,
             :untrack_running_session, :update_or_send_status, :wizard_for_topic
    end
  end
end
