# frozen_string_literal: true

require "open3"
require "shellwords"
require_relative "../tool"

module Rubot
  module Tools
    class Shell < Tool
      # Characters returned for one command. A test suite or build log is
      # usually most useful at the end, so a long result keeps both ends.
      MAX_OUTPUT = 20_000
      HEAD_OUTPUT = 6_000

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
          Write any new helper script in Ruby and run it with `ruby -e '...'`
          or by writing a .rb file; do not introduce Python for new work.
          Output is limited to #{MAX_OUTPUT} characters (the beginning and the
          end are kept when it is longer).
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

        stdout, stderr, status = run_command(cmd)
        output = ""
        output += stdout if stdout && !stdout.empty?
        output += "\nSTDERR: #{stderr}" if stderr && !stderr.empty?

        output = output.strip
        if output.length > MAX_OUTPUT
          tail_size = MAX_OUTPUT - HEAD_OUTPUT
          omitted = output.length - MAX_OUTPUT
          output = output[0...HEAD_OUTPUT] +
                   "\n... (#{omitted} characters omitted; narrow the command with grep/head/tail) ...\n" +
                   output[-tail_size..]
        end

        exit_status = status.exitstatus
        "[Exit code: #{exit_status}]\n#{output}"
      rescue Errno::ENOENT => e
        "ERROR: Command not found: #{e.message}"
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end

      # Returns true if the command could cause data loss or destructive changes.
      def dangerous_action?(arguments)
        !dangerous_action_reason(arguments).nil?
      end

      # Which of the destructive patterns the command hit, in words the
      # confirmation prompt can show.
      def dangerous_action_reason(arguments)
        cmd = arguments["command"]
        return nil if cmd.nil? || cmd.strip.empty?

        # Match against the command with plain quoted text removed, so
        # `echo "rm -rf build"` or a commit message does not ask for
        # confirmation while `rm -rf build` still does. A shell invoked with
        # -c runs its string as code, so there the quotes are kept.
        cmd = strip_quoted(cmd) unless cmd =~ /\b(?:ba|z|k)?sh\s+-c\b/

        match = DESTRUCTIVE_PATTERNS.find { |_label, pattern| cmd =~ pattern }
        match && match[0]
      end

      # Destructive patterns that could cause data loss, with a label for the
      # confirmation prompt. Deeply frozen: this is read from inside a session
      # Ractor, and a nested array that is merely frozen at the top level is
      # not shareable, so reading it there raises Ractor::IsolationError.
      DESTRUCTIVE_PATTERNS = [
        # File/directory deletion
        [ "deletes files", /\brm\b/ ],
        # Truncate to zero length
        [ "truncates a file", /\btruncate\b/ ],
        [ "truncates a file", /\b:>\s/ ],
        # In-place editing that modifies files destructively
        [ "edits files in place", /\bsed\s+(-i|--in-place)/ ],
        # Disk/partition operations
        [ "writes raw data to a device", /\bdd\b/ ],
        [ "formats a filesystem", /\bmkfs\b/ ],
        [ "formats a filesystem", /\bmkswap\b/ ],
        [ "formats a filesystem", /\bmke2fs\b/ ],
        # Recursive permission changes
        [ "changes permissions recursively", /\bchmod\s+-R/ ],
        # Git destructive
        [ "resets git history", /\bgit\s+reset\s+--hard/ ],
        [ "force-pushes a branch", /\bgit\s+push\s+--force/ ],
        # Docker destructive
        [ "prunes docker data", /\bdocker\s+system\s+prune/ ],
        [ "removes docker images", /\bdocker\s+rmi\s+-f/ ],
        [ "removes docker containers", /\bdocker\s+rm\s+-f/ ],
        # shred / secure delete
        [ "wipes a file beyond recovery", /\bshred\b/ ]
      ].map { |label, pattern| [ label, pattern ].freeze }.freeze

      private

      # Remove the contents of '...' and "..." pairs. Used only to decide
      # whether a command needs confirmation, so dropping the text is enough.
      def strip_quoted(text)
        out = +""
        quote = nil
        escaped = false
        text.each_char do |ch|
          if quote
            if escaped
              escaped = false
            elsif ch == "\\"
              escaped = true
            elsif ch == quote
              quote = nil
            end
          elsif ch == "'" || ch == "\""
            quote = ch
          else
            out << ch
          end
        end
        out
      end

      # Run the command in its own process group so /stop can kill it and
      # anything it started, not just the shell wrapper. The cancellation
      # token is set per turn by the agent.
      def run_command(cmd)
        cancellation = Thread.current[:rubot_cancellation]

        Open3.popen3(cmd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          cancellation&.track(wait_thr.pid)
          begin
            out_reader = Thread.new { stdout.read }
            err_reader = Thread.new { stderr.read }
            status = wait_thr.value
            [ out_reader.value, err_reader.value, status ]
          ensure
            cancellation&.untrack(wait_thr.pid)
          end
        end
      end

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
      #
      # FIX (VULN-8, VULN-10): Expanded to catch dd, tee, cat /dev/null,
      # variable substitution, find -delete, and other destruction methods.
      #
      # FIX (PEN-09): Also blocks commands using indirect variable references
      # where the destruction keyword appears near a shell variable (defense-in-depth).
      def targets_memory?(cmd)
        cmd =~ /MEMORY\.md/i && cmd =~ %r{
          \brm\b                    |
          \btruncate\b              |
          :>\s*                     |
          echo\s+.*>\s              |
          cp\s+/dev/(?:null|zero)   |
          \bdd\b                    |
          \btee\b                   |
          \bfind\b.*\b-delete\b     |
          \$\{?MEMORY               |
          \$\{?memory
        }x ||
        # Indirect variable: destruction command near any $var reference
        # (defense-in-depth — catches rm $VAR where VAR was set to MEMORY.md)
        (cmd =~ /MEMORY\.md/i && cmd =~ /\$[A-Za-z_]/ && cmd =~ %r{
          \brm\b                    |
          \btruncate\b              |
          \bshred\b                 |
          \bunlink\b
        }x)
      end
    end
  end
end
