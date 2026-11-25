# frozen_string_literal: true

module Rubot
  module Channels
    class Telegram < Channel
      # The slash menu Telegram shows behind its / button, and the cron side of
      # the channel: the scheduler that belongs to whichever process runs it
      # (the agent's tool in direct mode, the cron actor in actor mode) and the
      # callback that turns a fired job back into a message in the topic that
      # asked for it.
      module Scheduling
        private

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
          when "loop_tick"
            # A loop iterates through a worktree and a session pool, and this
            # channel has neither: nothing here binds the loop tool to a runner,
            # so there is nobody to hand the id to. Say where it can be woken
            # rather than pretending the tick worked, and never raise: this runs
            # on the delivery port, where an exception would take the rest of
            # the fired batch with it.
            send_message(chat_id,
                         "🔁 Loop `#{result[:loop_id]}` is scheduled, but not resumed here: " \
                         "loops run on the web channel. Resume it from there.",
                         thread_id)
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
      end
    end
  end
end
