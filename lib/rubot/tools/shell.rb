# frozen_string_literal: true

require "open3"
require "shellwords"
require_relative "../tool"

module Rubot
  module Tools
    class Shell < Tool
      MAX_OUTPUT = 10_000 # characters

      attr_accessor :safety_guard

      def initialize(safety_guard: nil)
        @safety_guard = safety_guard
      end

      def name
        "shell_exec"
      end

      def description
        desc = <<~DESC.strip
          Execute a shell command and return its output.
          Use this for running system commands, scripts, git operations, etc.
          The command will be executed in the current working directory.
          Output is limited to #{MAX_OUTPUT} characters.
        DESC
        if @safety_guard&.restrict_to_workspace
          desc + "\nCommands are restricted to the workspace directory."
        else
          desc
        end
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "command" => {
              "type" => "string",
              "description" => "The shell command to execute"
            }
          },
          "required" => [ "command" ]
        }
      end

      def execute(arguments)
        cmd = arguments["command"]
        raise "No command provided" if cmd.nil? || cmd.strip.empty?

        # Block attempts to delete or reset memory via shell
        if targets_memory?(cmd)
          raise "Command rejected: cannot delete or reset MEMORY.md via shell. Memory is protected."
        end

        # Safety guard checks
        check_command_safety(cmd)

        stdout, stderr, status = Open3.capture3(cmd)
        output = ""
        output += stdout if stdout && !stdout.empty?
        output += "\nSTDERR: #{stderr}" if stderr && !stderr.empty?

        output = output.strip
        output = output[0...MAX_OUTPUT] + "\n... (output truncated)" if output.length > MAX_OUTPUT

        exit_status = status.exitstatus
        "[Exit code: #{exit_status}]\n#{output}"
      rescue Errno::ENOENT => e
        "ERROR: Command not found: #{e.message}"
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end

      private

      def check_command_safety(cmd)
        # Always check for dangerous patterns
        guard = @safety_guard
        if guard.nil?
          # Fallback to inline check if no safety guard configured
          if dangerous_command_fallback?(cmd)
            raise "Command rejected for safety: dangerous pattern detected"
          end
          warn "[shell:safety] NO safety guard configured" if Rubot.debug?
          return
        end

        warn "[shell:safety] restrict=#{guard.restrict_to_workspace} cmd=#{cmd[0..60]}" if Rubot.debug?

        # Always block dangerous commands regardless of mode
        if guard.dangerous_command?(cmd)
          raise "Command rejected for safety: dangerous pattern detected"
        end

        # In workspace-restricted mode, verify command path
        return unless guard.restrict_to_workspace

        begin
          guard.check_command(cmd)
        rescue SafetyGuard::SecurityError => e
          raise e.message
        end
      end

      def dangerous_command_fallback?(cmd)
        patterns = [
          /\brm\s+(-rf?|--recursive)\s+\/\s*$/,
          /\brm\s+(-rf?|--recursive)\s+\*\s*$/,
          /\bmkfs\b/,
          /\bdd\s+.*of=\/dev\//,
          /\bcurl\b.*\|\s*(sh|bash)\b/,
          /\bwget\b.*-O-.*\|\s*(sh|bash)\b/,
          /\bchmod\s+777\s+\/\s*$/,
          /\b:>.*\/etc\//,
          /\bmke2fs\b/,
          /\bmkswap\b/
        ]
        patterns.any? { |p| cmd =~ p }
      end

      # Check if a command targets MEMORY.md for deletion or truncation.
      # This is a dedicated defense-in-depth check independent of SafetyGuard.
      def targets_memory?(cmd)
        cmd =~ /MEMORY\.md/i && cmd =~ /(\brm\b|\btruncate\b|\b:>\s|\becho\s+.*>\s|cp\s+\/dev\/null)/
      end
    end
  end
end
