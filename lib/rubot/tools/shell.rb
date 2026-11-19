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

      # A command that never exits — a program waiting on a terminal, a daemon
      # that does not detach, a stuck network call — would hold the turn open
      # forever, because nothing below this tool has a deadline. The whole
      # process group is killed once this many seconds have passed.
      # RUBOT_SHELL_TIMEOUT overrides it; 0 waits forever.
      DEFAULT_TIMEOUT = 600

      # Seconds to wait for a graceful exit after TERM, and after KILL.
      KILL_GRACE = 3

      # Seconds the pipes get to reach EOF once the process has exited. A
      # background child that inherited stdout keeps the write end open, so
      # waiting for EOF can block long after the command itself is done.
      DRAIN_GRACE = 2

      attr_accessor :safety_guard

      # Reads one pipe on its own thread while keeping whatever has already
      # arrived. Waiting for EOF is not an option: a background child that
      # inherited the write end keeps it open, and a plain `read` would block
      # there forever even though the command itself finished.
      class PipeReader
        CHUNK = 64 * 1024

        def initialize(io)
          @io = io
          @mutex = Mutex.new
          @text = +""
          @thread = Thread.new { read_all }
        end

        # Waits until `deadline` (monotonic clock) for EOF, then closes the pipe
        # to release the reader. Returns [text, forced?], where `forced?` says
        # the output may be short because the pipe had to be closed.
        def drain(deadline)
          return [ text, false ] if @thread.join(remaining(deadline))

          @io.close
          @thread.join(1)
          [ text, true ]
        rescue IOError
          [ text, true ]
        end

        # What has been read so far; safe to call while the reader is running.
        def text
          @mutex.synchronize { @text.dup }
        end

        private

        # One monotonic instant shared by both pipes, so a stdout that needs the
        # full grace does not make stderr wait for another one.
        def remaining(deadline)
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          left.positive? ? left : 0
        end

        def read_all
          loop do
            chunk = @io.readpartial(CHUNK)
            @mutex.synchronize { @text << chunk }
          end
        rescue EOFError, IOError, Errno::EBADF, Errno::EIO
          nil
        end
      end

      # `timeout:` is for tests; the real setting comes from the environment.
      def initialize(safety_guard: nil, timeout: nil)
        @safety_guard = safety_guard
        @timeout = timeout
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
          A command that has not exited after #{DEFAULT_TIMEOUT} seconds is
          killed, so do not use it to start long-running servers.
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

        stdout, stderr, status, problems = run_command(cmd)
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

        # Why the exit code is missing or late travels with the output: the
        # model has to see that the command did not simply end.
        output += "\n" + problems.join("\n") unless problems.empty?

        "[Exit code: #{exit_status_label(status)}]\n#{output}"
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
      #
      # The call always comes back: the process group is killed once the
      # deadline passes, and the pipe readers are released a couple of seconds
      # after the process exits instead of being awaited forever. Returns
      # [stdout, stderr, status, problems], where `status` is nil when the
      # process could not be reaped and `problems` explains anything that
      # stopped the output from arriving whole.
      def run_command(cmd)
        cancellation = Thread.current[:rubot_cancellation]
        limit = command_timeout

        # Run in the agent's workspace when one is set, so relative paths in
        # shell commands land where the agent's files live rather than in the
        # directory rubot was launched from.
        opts = { pgroup: true }
        opts[:chdir] = workspace if workspace && File.directory?(workspace)
        Open3.popen3(cmd, **opts) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          cancellation&.track(wait_thr.pid)
          begin
            out_reader = PipeReader.new(stdout)
            err_reader = PipeReader.new(stderr)
            problems = []

            status = wait_for_exit(wait_thr, limit)
            if status.nil?
              status = terminate(wait_thr)
              problems << "[the command was still running after #{limit}s, " \
                          "so its process group was killed]"
            end

            drain_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DRAIN_GRACE
            out, out_cut = out_reader.drain(drain_deadline)
            err, err_cut = err_reader.drain(drain_deadline)
            if out_cut || err_cut
              problems << "[output may be incomplete: a process started by the " \
                          "command kept the pipe open after it exited]"
            end

            [ out, err, status, problems ]
          ensure
            cancellation&.untrack(wait_thr.pid)
          end
        end
      end

      # Deadline for one command, in seconds, or nil for no limit.
      def command_timeout
        value = @timeout
        value = ENV["RUBOT_SHELL_TIMEOUT"] if value.nil?
        value = DEFAULT_TIMEOUT if value.nil? || value.to_s.strip.empty?
        return nil if value.to_f <= 0

        value.to_f
      end

      # Waits for the process to exit, checking the deadline instead of blocking
      # on it. A cancellation kills the group, which wakes this early.
      def wait_for_exit(wait_thr, limit)
        return wait_thr.value if limit.nil?

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
        loop do
          return wait_thr.value if wait_thr.join(0.1)
          return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        end
      end

      # TERM the group, then KILL it if it is still alive after the grace.
      def terminate(wait_thr)
        signal_group(wait_thr.pid, "TERM")
        return wait_thr.value if wait_thr.join(KILL_GRACE)

        signal_group(wait_thr.pid, "KILL")
        wait_thr.join(KILL_GRACE) ? wait_thr.value : nil
      end

      def signal_group(pid, signal)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(signal, pid)
        rescue StandardError
          nil
        end
      end

      def exit_status_label(status)
        return "unknown" if status.nil?
        return status.exitstatus.to_s if status.exitstatus

        "killed by signal #{status.termsig}"
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
