# frozen_string_literal: true

require "open3"
require "shellwords"
require_relative "../tool"

module Rubot
  module Tools
    class Shell < Tool
      MAX_OUTPUT = 10_000 # characters

      def name
        "shell_exec"
      end

      def description
        <<~DESC.strip
          Execute a shell command and return its output.
          Use this for running system commands, scripts, git operations, etc.
          The command will be executed in the current working directory.
          Output is limited to #{MAX_OUTPUT} characters.
        DESC
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

        # Safety: reject obviously dangerous commands
        if dangerous_command?(cmd)
          return "ERROR: Command rejected for safety reasons. " \
                 "Commands like 'rm -rf /', 'dd', 'mkfs', 'curl|sh', etc. are not allowed."
        end

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

      def dangerous_command?(cmd)
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
    end
  end
end
