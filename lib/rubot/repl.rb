# frozen_string_literal: true

module Rubot
  class REPL
    HISTORY_FILE = File.expand_path("~/.rubot/history")

    COMMANDS = {
      "/help"     => "Show this help message",
      "/new"      => "Clear conversation and start a new session",
      "/clear"    => "Clear conversation history",
      "/session"  => "Show current session ID",
      "/session NAME" => "Switch to a new session",
      "/info"     => "Show agent info (provider, model, tools)",
      "/tools"    => "List available tools",
      "/soul"     => "Show the bot's soul (SOUL.md)",
      "/memory"   => "Show persistent memory (MEMORY.md)",
      "/agents"   => "Show agent rules (AGENTS.md)",
      "/cron"     => "List scheduled cron jobs",
      "/stream on|off" => "Toggle streaming output",
      "/quit"     => "Exit rubot"
    }

    def initialize(agent, stream: true)
      @agent = agent
      @stream = stream
      @logo = "🤖"
      @readline_available = setup_readline
      load_history
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
      info = @agent.startup_info
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
        @agent.clear_session
        puts "\n💬 Session cleared."
      when "/new"
        @agent.clear_session
        puts "\n✨ Started a new session. Previous conversation cleared."
      when "/session"
        if parts[1]
          @agent = Agent.new(
            config: @agent.config,
            provider: @agent.provider,
            session_id: parts[1],
            tools: @agent.tools
          )
          puts "\n📝 Session switched to: #{parts[1]}"
        else
          puts "\n📝 Current session: #{@agent.session.id}"
        end
      when "/info"
        info = @agent.startup_info
        puts "\nAgent Info:"
        info.each { |k, v| puts "  #{k}: #{v}" }
        puts
      when "/tools"
        puts "\nAvailable tools:"
        @agent.tools.all.each do |tool|
          puts "  - #{tool.name}: #{tool.description.lines.first.strip}"
        end
        puts
      when "/soul"
        if @agent.soul.enabled?
          puts "\n🧬 Soul (SOUL.md):"
          puts "---"
          puts @agent.soul
          puts "---"
        else
          puts "\n🧬 No soul file (SOUL.md) found in workspace."
          puts "Create one at: #{@agent.config.workspace}/SOUL.md"
        end
        puts
      when "/memory"
        if @agent.memory.enabled?
          puts "\n🧠 Memory (MEMORY.md):"
          puts "---"
          puts @agent.memory.read
          puts "---"
        else
          puts "\n🧠 Memory not available (no workspace configured)."
        end
        puts
      when "/agents"
        if @agent.agents_file.enabled?
          puts "\n📋 Agent Rules (AGENTS.md):"
          puts "---"
          puts @agent.agents_file.raw
          puts "---"
        else
          puts "\n📋 No AGENTS.md found in workspace."
          puts "Create one at: #{@agent.config.workspace}/AGENTS.md"
        end
        puts
      when "/cron"
        cron_tool = @agent.tools.get("cron")
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
      when "/quit", "/exit"
        puts
        exit
      else
        puts "Unknown command: #{cmd}. Type /help for available commands."
      end
    end

    def process_message(message)
      if @stream
        print "\n#{@logo} Assistant: "
        response = ""
        @agent.process(message) do |chunk|
          print chunk
          $stdout.flush
          response += chunk
        end
        puts "\n"
      else
        print "\n#{@logo} Assistant: "
        response = @agent.process(message)
        puts response
        puts
      end
    rescue StandardError => e
      puts "\n❌ Error: #{e.message}\n"
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
