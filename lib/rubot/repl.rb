# frozen_string_literal: true

require_relative "usage"
require_relative "opencode_usage"

module Rubot
  class REPL
    HISTORY_FILE = File.expand_path("~/.rubot/history")

    COMMANDS = {
      "/help"     => "Show this help message",
      "/new"      => "Clear conversation and start a new session",
      "/compact"  => "Summarize older messages to free context",
      "/clear"    => "Clear conversation history",
      "/session"  => "Show current session ID",
      "/session NAME" => "Switch to a new session",
      "/info"     => "Show agent info (provider, model, tools)",
      "/context"  => "Show context usage, cache hit rate, and estimated cost",
      "/usage"    => "Show OpenCode Go subscription usage",
      "/models"   => "List available models from config",
      "/model"    => "Show current active model",
      "/use-model NAME" => "Switch to a model for this session",
      "/tools"    => "List available tools",
      "/soul"     => "Show the bot's soul (SOUL.md)",
      "/memory"   => "Show persistent memory (MEMORY.md)",
      "/agents"   => "Show agent rules (AGENTS.md)",
      "/cron"     => "List scheduled cron jobs",
      "/stream on|off" => "Toggle streaming output",
      "/use SKILL" => "Force a specific skill for the next message",
      "/unuse"    => "Clear the forced skill",
      "/quit"     => "Exit rubot"
    }

    def initialize(agent = nil, stream: true, pool: nil)
      @agent = agent
      @pool = pool
      @session_id = "default"
      @stream = stream
      @logo = "🤖"
      @readline_available = setup_readline
      load_history
    end

    # Current session handle, either a legacy in-process Agent or a
    # Ractor-backed SessionHandle.
    def agent
      @pool ? @pool.for(@session_id) : @agent
    end

    # Switch the active session. In actor mode this simply points the REPL
    # at another session handle (one actor per session).
    def switch_session(name)
      if @pool
        @session_id = name.to_s
        agent
      else
        @agent.switch_session(name)
      end
    end

    def run
      print_banner
      puts

      if @readline_available
        interactive_with_readline
      else
        interactive_simple
      end

      puts "\n👋 Goodbye!"
    end

    private

    def setup_readline
      # reline is bundled with Ruby 3+; readline was removed in Ruby 4.0
      require "reline"
      true
    rescue LoadError
      false
    end

    def interactive_with_readline
      Reline.completion_proc = completion_handler

      loop do
        input = begin
          Reline.readline("#{@logo} You: ")
        rescue Interrupt
          puts
          break
        end
        break unless input

        input = input.strip
        next if input.empty?

        save_history(input)
        dispatch(input)
      end
    rescue Interrupt
      puts
    end

    def interactive_simple
      loop do
        print "#{@logo} You: "
        input = begin
          $stdin.gets
        rescue Interrupt
          puts
          break
        end
        break unless input

        input = input.strip
        next if input.empty?

        save_history(input)
        dispatch(input)
      end
    rescue Interrupt
      puts
    end

    def dispatch(input)
      if input.start_with?("/")
        handle_command(input)
      else
        process_message(input)
      end
    end

    def print_banner
      info = agent.startup_info
      puts "╔══════════════════════════════════════════════╗"
      puts "║         🤖  Rubot AI Assistant  🤖          ║"
      puts "╠══════════════════════════════════════════════╣"
      printf "║  Provider: %-28s║\n", info[:provider]
      printf "║  Model:    %-28s║\n", info[:model]
      printf "║  Tools:    %-28s║\n", "#{info[:tools]} loaded"
      puts "╠══════════════════════════════════════════════╣"
      puts "║  Type /help for commands, /quit to exit     ║"
      puts "╚══════════════════════════════════════════════╝"
    end

    def handle_command(input)
      parts = input.split
      cmd = parts.first.downcase

      case cmd
      when "/help"
        puts "\nAvailable commands:"
        COMMANDS.each do |syntax, desc|
          puts "  %-20s %s" % [ syntax, desc ]
        end
        puts
      when "/clear"
        agent.clear_session
        puts "\n💬 Session cleared."
      when "/new"
        agent.clear_session
        puts "\n✨ Started a new session. Previous conversation cleared."
      when "/compact"
        result = agent.compact_session
        if result
          puts "\n🗜️  Compaction complete."
          puts "   Summarized: #{result[:summarized_messages]} messages"
          puts "   Kept:       #{result[:kept_messages]} messages"
          puts "   Context:    ~#{result[:context_before]} → ~#{result[:context_after]} tokens (estimated)"
        else
          puts "\nℹ️  Nothing to compact yet (the conversation is short or summarization failed)."
        end
      when "/session"
        if parts[1]
          switch_session(parts[1])
          puts "\n📝 Session switched to: #{parts[1]}"
          model = agent.active_model_name
          if agent.session.model_override
            puts "  Model: #{model} (session override)"
          end
        else
          puts "\n📝 Current session: #{agent.session.id}"
          model = agent.active_model_name
          puts "  Model: #{model}"
        end
      when "/info"
        info = agent.startup_info
        puts "\nAgent Info:"
        info.each { |k, v| puts "  #{k}: #{v}" }
        puts
      when "/context"
        puts
        puts Rubot::UsageReport.render(agent.usage_report)
        puts
      when "/usage"
        puts
        puts Rubot::OpencodeUsageReport.render(agent.opencode_usage)
        puts
      when "/models"
        models = agent.config.models
        if models.empty?
          puts "\nNo models configured in config.yml."
        else
          active = agent.active_model_name
          puts "\nAvailable models:"
          models.each do |m|
            marker = m["name"] == active ? " → " : "   "
            puts "  #{marker}#{m["name"]} (#{m["model"]})"
          end
          puts
        end
      when "/model"
        active = agent.active_model_name
        entry = agent.config.model_entry_by_name(active) || agent.config.active_model_entry
        puts "\nCurrent model: #{active} (#{entry["model"]})"
        if agent.session.model_override
          puts "  (session override — will be cleared on /new)"
        end
        puts
      when "/use-model"
        model_name = parts[1]
        if model_name.nil?
          puts "\n⚠️  Usage: /use-model <model-name>"
          models = agent.config.models
          unless models.empty?
            puts "\nAvailable models:"
            models.each { |m| puts "  - #{m['name']}" }
          end
        else
          result = agent.use_model(model_name)
          if result
            entry = agent.config.model_entry_by_name(result)
            puts "\n✅ Switched to model: #{result} (#{entry['model']})"
            puts "  Provider: #{agent.provider.name}"
            puts "  Model will persist for this session (cleared on /new)."
          else
            puts "\n❌ Model '#{model_name}' not found in config.yml."
            puts "\nAvailable models:"
            agent.config.models.each { |m| puts "  - #{m['name']}" }
          end
        end
        puts
      when "/tools"
        puts "\nAvailable tools:"
        agent.tools.all.each do |tool|
          puts "  - #{tool.name}: #{tool.description.lines.first.strip}"
        end
        puts
      when "/soul"
        if agent.soul.enabled?
          puts "\n🧬 Soul (SOUL.md):"
          puts "---"
          puts agent.soul
          puts "---"
        else
          puts "\n🧬 No soul file (SOUL.md) found in workspace."
          puts "Create one at: #{agent.config.workspace}/SOUL.md"
        end
        puts
      when "/memory"
        if agent.memory.enabled?
          puts "\n🧠 Memory (MEMORY.md):"
          puts "---"
          puts agent.memory.read
          puts "---"
        else
          puts "\n🧠 Memory not available (no workspace configured)."
        end
        puts
      when "/agents"
        if agent.agents_file.enabled?
          puts "\n📋 Agent Rules (AGENTS.md):"
          puts "---"
          puts agent.agents_file.raw
          puts "---"
        else
          puts "\n📋 No AGENTS.md found in workspace."
          puts "Create one at: #{agent.config.workspace}/AGENTS.md"
        end
        puts
      when "/cron"
        cron_tool = agent.tools.get("cron")
        if cron_tool
          result = cron_tool.execute({ "operation" => "list" })
          puts "\n#{result}"
        else
          puts "\nCron tool not available."
        end
        puts
      when "/stream"
        if parts[1]
          @stream = parts[1].downcase == "on"
          puts "\nStreaming: #{@stream ? 'ON' : 'OFF'}"
        else
          puts "\nStreaming: #{@stream ? 'ON' : 'OFF'} (use /stream on or /stream off)"
        end
      when "/use"
        skill_name = parts[1]
        if skill_name.nil?
          puts "\n⚠️  Usage: /use <skill-name>"
          puts "Available skills: #{agent.skill_registry.all.keys.join(', ') || '(none)'}"
        elsif agent.skill_registry.get(skill_name)&.enabled?
          agent.session.forced_skill = skill_name
          agent.session.save! if agent.session.respond_to?(:save!)
          puts "\n✅ Skill '#{skill_name}' will be used for the next message."
        else
          puts "\n❌ Skill '#{skill_name}' not found or not enabled."
          puts "Available skills: #{agent.skill_registry.all.keys.join(', ') || '(none)'}"
        end
      when "/unuse"
        if agent.session.forced_skill
          agent.session.forced_skill = nil
          agent.session.save! if agent.session.respond_to?(:save!)
          puts "\n✅ Forced skill cleared."
        else
          puts "\nℹ️  No forced skill is set."
        end
      when "/quit", "/exit"
        puts
        exit
      else
        puts "Unknown command: #{cmd}. Type /help for available commands."
      end
    end

    def process_message(message)
      on_confirm = build_confirm_callback

      if @stream
        print "\n#{@logo} Assistant: "
        response = ""
        agent.process(message, on_confirm: on_confirm, stream: @stream) do |chunk|
          print chunk
          $stdout.flush
          response += chunk
        end
        puts "\n"
      else
        print "\n#{@logo} Assistant: "
        response = agent.process(message, on_confirm: on_confirm, stream: false)
        puts response
        puts
      end

      # Learning runs once the answer is on screen, never before it.
      agent.flush_learning
    rescue StandardError => e
      puts "\n❌ Error: #{e.message}\n"
    end

    def build_confirm_callback
      return nil unless @readline_available

      proc do |tool_name, args|
        description = describe_action(tool_name, args)
        print "\n⚠️  Dangerous action (could cause data loss): #{description}\nConfirm? [y/N] "
        $stdout.flush
        answer = $stdin.gets&.strip&.downcase
        answer == "y" || answer == "yes"
      end
    end

    def describe_action(tool_name, args)
      case tool_name
      when "shell_exec"
        "shell command: #{args["command"][0..120]}"
      when "file_ops"
        "#{args["operation"]} #{args["path"]}"
      else
        "#{tool_name} #{args.inspect[0..120]}"
      end
    end

    def completion_handler
      proc { |s| COMMANDS.keys.grep(/^#{Regexp.escape(s)}/) }
    end

    def load_history
      return unless File.exist?(HISTORY_FILE)
      lines = File.readlines(HISTORY_FILE).map(&:chomp)
      if @readline_available
        lines.each { |line| Reline::HISTORY << line unless line.empty? }
      end
    rescue StandardError
      # ignore history load errors
    end

    def save_history(input)
      File.open(HISTORY_FILE, "a") { |f| f.puts(input) }
    rescue StandardError
      # ignore history save errors
    end
  end
end
