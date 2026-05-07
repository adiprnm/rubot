# frozen_string_literal: true

require "pathname"

module Rubot
  # SafetyGuard provides workspace restriction and dangerous command filtering
  # for tool execution, inspired by PicoClaw's sandbox model.
  #
  # Two layers of protection:
  # 1. Workspace restriction — confines file/command access to a configured workspace
  # 2. Dangerous command blocking — rejects patterns that could harm the system
  class SafetyGuard
    # Device paths that are always accessible even when restricted
    SAFE_PATHS = %w[
      /dev/null /dev/zero /dev/random /dev/urandom
      /dev/stdin /dev/stdout /dev/stderr
    ].freeze

    # Dangerous command patterns that are always blocked, regardless of mode.
    # Pattern fixes: case-insensitive MEMORY.md, any rm flag order,
    # leading-zero chmod, sudo pipe bypass, additional destruction methods.
    DANGEROUS_PATTERNS = [
      # Bulk deletion — any flag order (-rf, -fr, -Rf, -fR)
      /\brm\s+-(?:r[fF]?|[fF]r|R[fF]?|[fF]R)\s+\/\s*$/,
      /\brm\s+-(?:r[fF]?|[fF]r|R[fF]?|[fF]R)\s+\*\s*$/,
      /\brm\s+--no-preserve-root\b/,
      # Mass deletion via find
      /\bfind\b.*-exec\b.*\brm\b/,
      /\bfind\b.*-delete\b/,
      # Disk formatting / low-level writes
      /\bmkfs\b/,
      /\bdd\b.*\bof=\/dev\//,
      /\bdd\b.*\bif=\/dev\//,
      /\bformat\s/,
      /\bdiskpart\b/,
      # Direct device writes
      /\bcat\s+.*>\s*\/dev\/sd/,
      /\btee\s+\/dev\/sd/,
      /\becho\s+.*>\s*\/dev\/sd/,
      # System shutdown
      /\bshutdown\b/,
      /\breboot\b/,
      /\bpoweroff\b/,
      # Fork bomb
      /:\(\)\s*\{.*:\|.*&.*\}\s*;/,
      # Pipe to shell (remote code execution) — includes sudo bypass
      /\bcurl\b.*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|fish)\b/,
      /\bwget\b.*-O-.*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|fish)\b/,
      /\bwget\b.*-qO-.*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|fish)\b/,
      # FIX (VULN-6): Pipe to interpreted languages (python, ruby, perl, node, php)
      /\bcurl\b.*\|\s*(?:sudo\s+)?(?:python3?|ruby|perl|node|php)\b/,
      /\bwget\b.*-O-.*\|\s*(?:sudo\s+)?(?:python3?|ruby|perl|node|php)\b/,
      /\bwget\b.*-qO-.*\|\s*(?:sudo\s+)?(?:python3?|ruby|perl|node|php)\b/,
      # FIX (VULN-1, VULN-6): Interpreted language inline execution
      /\b(python3?|ruby|perl|lua|node|php)\s+(-c|-e)\b/,
      /\b(python3?|ruby|perl)\s+-i\s*$/,  # interactive mode can be abused
      # FIX (VULN-2): Encoded payload decoders piped to shells
      /\bbase64\b.*(-d|--decode).*\|\s*(?:sudo\s+)?(?:sh|bash|zsh)\b/,
      /\bprintf\b.*\|\s*(?:sudo\s+)?(?:sh|bash|zsh)\b/,
      /\bxxd\b.*-r.*\|\s*(?:sudo\s+)?(?:sh|bash|zsh)\b/,
      # FIX (VULN-5): eval and exec shell builtins
      /\A\s*eval\b/,
      /\A\s*exec\b/,
      # Permission escalation on root — includes leading-zero octal and symbolic mode
      /\bchmod\s+0?777\s+\/\s*$/,
      /\bchmod\s+-R\s+0?777\s+\/\s*$/,
      /\bchmod\s+a\+rwx\s+\/\s*$/,
      # Filesystem destruction
      /\bmke2fs\b/,
      /\bmkswap\b/,
      /\bfsck\b.*-y\s+\/dev\//,
      # Memory destruction — case-insensitive, multiple methods (VULN-4, VULN-8 expansion)
      /\brm\b.*memory\.md/i,
      /\btruncate\b.*memory\.md/i,
      /\bunlink\b.*memory\.md/i,
      /\bshred\b.*memory\.md/i,
      /\bmv\b.*memory\.md/i,
      /\b:>\s*.*memory\.md/i,
      /\becho\s+.*>\s*.*memory\.md/i,
      /\bcp\s+\/dev\/null\s+.*memory\.md/i,
      /\bdd\b.*\bof=.*memory\.md/i,
      /\bln\s+-sf.*memory\.md/i,
      /\bsed\b.*memory\.md/i,
      /\btee\s+.*memory\.md/i,
      # FIX (VULN-10): Memory destruction via variable substitution
      /\brm\b.*\$.*(?:MEMORY|memory)/i,
      /\bfind\b.*memory\.md/i,
      /\bcat\s+\/dev\/null\s*>\s*.*memory\.md/i,
      # FIX (VULN-4): xargs can execute arbitrary commands
      /\bxargs\b.*(?:bash|sh|rm)\b/,
      # FIX (VULN-13): User management / privilege escalation
      /\buseradd\b/,
      /\busermod\b/,
      /\bpasswd\b/,
      /\bvisudo\b/,
      /\bchown\s+root/,
    ].freeze

    # FIX (VULN-3, VULN-12): Sensitive paths blocked in permissive mode.
    # Even when workspace restriction is disabled, these paths are never accessible
    # because they contain secrets or are critical system files.
    SENSITIVE_PATHS = %w[
      /etc/shadow /etc/gshadow /etc/security/opasswd
      /proc/self/environ /proc/1/environ
      /proc/kcore /proc/sysrq-trigger
      /sys/firmware
    ].freeze

    # Sensitive path regex patterns for broader matching
    SENSITIVE_PATH_PATTERNS = [
      %r{\A/etc/(shadow|gshadow|security/opasswd)\z},
      %r{\A/proc/\d+/environ\z},
      %r{\A/proc/kcore\z},
      %r{\A/proc/sysrq-trigger\z},
      %r{\A/sys/firmware},
      %r{\.ssh/id_},
      %r{\.aws/credentials},
      %r{\.kube/config},
      %r{\.env\z},
    ].freeze

    # Device path patterns to block in exec commands
    BLOCK_DEVICE_PATTERNS = %r{
      /dev/sd[a-z]       |  # SATA drives
      /dev/hd[a-z]       |  # IDE drives
      /dev/nvme\d+n\d+   |  # NVMe drives
      /dev/mmcblk\d+     |  # eMMC/SD cards
      /dev/loop\d+       |  # Loop devices
      /dev/dm-\d+        |  # Device mapper
      /dev/zd\d+            # ZFS volumes
    }x.freeze

    attr_reader :workspace, :restrict_to_workspace, :allow_read_outside

    # @param workspace [String] Absolute path to the workspace directory
    # @param restrict_to_workspace [Boolean] Whether to restrict all access to workspace
    # @param allow_read_outside [Boolean] Allow read-only access outside workspace when restricted
    def initialize(workspace: nil, restrict_to_workspace: false, allow_read_outside: false)
      @workspace = workspace ? Pathname.new(workspace).expand_path : nil
      @restrict_to_workspace = restrict_to_workspace
      @allow_read_outside = allow_read_outside
    end

    # Check if a file path is allowed for the given operation.
    # @param path [String, Pathname] The path to check
    # @param operation [Symbol] :read, :write, or :exec
    # @return [Boolean] true if the path is allowed
    # @raises [SecurityError] if the path is blocked
    def check_path(path, operation: :read)
      resolved = resolve_path(path)

      # FIX (VULN-3, VULN-12): Always block sensitive paths regardless of mode
      if sensitive_path?(resolved.to_s)
        raise SecurityError,
              "Path blocked by safety guard (sensitive system path: #{path})"
      end

      return true unless @restrict_to_workspace
      return true unless @workspace

      # Always allow safe device paths
      return true if SAFE_PATHS.include?(resolved.to_s)

      # Check if path is within workspace (symlinks resolved)
      in_workspace = path_within_workspace?(resolved)

      if in_workspace
        true
      elsif @allow_read_outside && operation == :read
        true
      else
        action = operation == :exec ? "executing" : "#{operation}ing"
        raise SecurityError,
              "Path blocked by safety guard: #{path} (#{action} outside workspace)"
      end
    end

    # Check if a command string is allowed for execution.
    # Modeled after PicoClaw's ExecTool.guardCommand.
    #
    # FIX (VULN-3): Dangerous pattern check runs BEFORE the early return,
    # so dangerous commands are always blocked regardless of workspace mode.
    #
    # @param command [String] The command to check
    # @return [Boolean] true if the command is allowed
    # @raises [SecurityError] if the command is blocked
    def check_command(command)
      cmd = command.strip
      return true if cmd.empty?

      # 0. FIX (VULN-3): Always check deny patterns FIRST — enforced even in permissive mode
      if dangerous_command?(cmd)
        raise SecurityError,
              "Command blocked by safety guard (dangerous pattern detected)"
      end

      # FIX (VULN-11): Rate limiting — track command executions
      check_rate_limit(cmd)

      # 0b. FIX (VULN-7): Block shell variable / command-substitution path bypasses
      if has_unresolved_path_variables?(cmd)
        raise SecurityError,
              "Command blocked by safety guard (shell variables could bypass path checking)"
      end

      # Workspace restriction checks — only apply when mode is strict
      return true unless @restrict_to_workspace
      return true unless @workspace

      # 1. Block path traversal
      if cmd.include?("../") || cmd.include?("..\\")
        raise SecurityError,
              "Command blocked by safety guard (path traversal detected)"
      end

      # 2. Find all absolute paths in the command and check each one
      abs_paths = extract_absolute_paths(cmd)
      abs_paths.each do |raw_path|
        # FIX (VULN-3): Block sensitive paths in commands too
        if sensitive_path?(raw_path)
          raise SecurityError,
                "Command blocked by safety guard (sensitive system path: #{raw_path})"
        end

        # Skip safe paths
        next if SAFE_PATHS.include?(raw_path)

        resolved = resolve_path(raw_path)
        next if path_within_workspace?(resolved)

        # Check using relative path (PicoClaw approach)
        rel = relative_to_workspace(resolved)
        if rel.to_s.start_with?("..")
          raise SecurityError,
                "Command blocked by safety guard (path outside working dir: #{raw_path})"
        end
      end

      true
    end

    # Extract all absolute file paths from a command string.
    # Modeled after PicoClaw's absolutePathPattern approach.
    #
    # FIX (VULN-6, VULN-10): Strip shell quotes from tokens and handle
    # command-substitution trailing metacharacters.
    #
    # @param command [String]
    # @return [Array<String>] List of absolute paths found
    def extract_absolute_paths(command)
      paths = []

      # Split on shell delimiters and whitespace
      command.split(/[\s;|&<>]+/).each do |token|
        # Handle --key=value and -k=value formats
        if token.include?("=")
          _key, value = token.split("=", 2)
          token = value
        end

        # FIX (VULN-6): Remove all shell quoting characters so that
        # cat '/etc/passwd' and ls '/etc'/passwd are both detected correctly.
        token = token.tr("'", '')
        token = token.tr('"', '')

        # FIX (VULN-10): Strip trailing command-substitution chars
        # so that $(echo /etc/passwd) → /etc/passwd, not /etc/passwd)
        token = token.delete_suffix(")").delete_suffix("}").delete_suffix("`")

        # Must start with /
        next unless token.start_with?("/")
        # Skip URL path components (//)
        next if token.start_with?("//")
        # Skip bare /
        next if token == "/"
        # Strip redirect markers
        next if token.start_with?(">", "<")

        paths << token
      end

      paths.uniq
    end

    # Compute the relative path from the workspace to the given path.
    # @param resolved [Pathname] Absolute path
    # @return [Pathname] Relative path
    def relative_to_workspace(resolved)
      resolved.relative_path_from(@workspace)
    rescue ArgumentError
      # Path is on a different drive/root
      Pathname.new("../escape")
    end

    # Check if a command matches any dangerous pattern.
    # This is always enforced regardless of workspace restriction.
    # @param command [String] The command to check
    # @return [Boolean] true if the command is dangerous
    def dangerous_command?(command)
      cmd = command.strip
      DANGEROUS_PATTERNS.any? { |pattern| cmd =~ pattern }
    end

    # Check if a command writes to a block device.
    # @param command [String] The command to check
    # @return [Boolean] true if the command writes to a block device
    def writes_to_block_device?(command)
      cmd = command.strip
      # Check for redirection to block devices
      return false unless cmd =~ /[>]/
      cmd =~ BLOCK_DEVICE_PATTERNS
    end

    # Detect shell variable references or command substitution that could
    # be used to bypass path checking by hiding paths in variables.
    #
    # FIX (VULN-7): Only enforced in strict mode to avoid breaking
    # legitimate variable usage in permissive mode.
    #
    # @param command [String]
    # @return [Boolean]
    def has_unresolved_path_variables?(command)
      return false unless @restrict_to_workspace
      # $VAR, ${VAR}, $(cmd), $((expr)), or backtick substitution
      command.match?(/\$[\w{(]/) || command.match?(/`[^`]+`/)
    end

    # Resolve a path to its absolute, symlink-resolved form.
    #
    # FIX (VULN-2, VULN-11): Uses File.realpath for existing paths so that
    # symlinks cannot be used to escape the workspace.
    #
    # @param path [String, Pathname]
    # @return [Pathname]
    def resolve_path(path)
      p = path.is_a?(Pathname) ? path : Pathname.new(path.to_s)
      expanded = p.expand_path
      # Resolve symlinks for existing paths to prevent workspace escape
      return expanded if expanded.to_s.start_with?("/dev/")
      if File.exist?(expanded.to_s)
        begin
          return Pathname.new(File.realpath(expanded.to_s))
        rescue SystemCallError
          # Fall back to expand_path if realpath fails (race condition)
        end
      end
      expanded
    end

    # Check if a path matches a sensitive system path.
    # Always enforced regardless of workspace mode.
    #
    # FIX (VULN-3, VULN-12): Blocks access to credential files,
    # process environment, and firmware even in permissive mode.
    #
    # @param path [String]
    # @return [Boolean]
    def sensitive_path?(path)
      SENSITIVE_PATHS.include?(path) ||
        SENSITIVE_PATH_PATTERNS.any? { |p| path =~ p }
    end

    # FIX (VULN-11): Simple rate limiting for shell command execution.
    # Tracks the number of executions within a sliding window.
    @@exec_timestamps = []
    @@exec_mutex = Mutex.new

    EXEC_WINDOW_SECONDS = 10
    EXEC_MAX_PER_WINDOW = 50

    def check_rate_limit(_command)
      return unless @restrict_to_workspace

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @@exec_mutex.synchronize do
        @@exec_timestamps.reject! { |t| now - t > EXEC_WINDOW_SECONDS }
        if @@exec_timestamps.size >= EXEC_MAX_PER_WINDOW
          raise SecurityError,
                "Command blocked by safety guard (rate limit exceeded: #{EXEC_MAX_PER_WINDOW} commands per #{EXEC_WINDOW_SECONDS}s)"
        end
        @@exec_timestamps << now
      end
    end

    # Check if a resolved path is within the workspace.
    #
    # FIX (VULN-2, VULN-11): Resolves symlinks for existing paths before
    # comparison, so a symlink pointing outside the workspace is detected.
    #
    # @param resolved [Pathname] Already-expanded path
    # @return [Boolean]
    def path_within_workspace?(resolved)
      return false unless @workspace

      # Resolve symlinks for existing paths
      check = resolved
      unless resolved.to_s.start_with?("/dev/")
        if File.exist?(resolved.to_s)
          begin
            check = Pathname.new(File.realpath(resolved.to_s))
          rescue SystemCallError
            check = resolved
          end
        end
      end

      workspace_str = @workspace.to_s + "/"
      resolved_str = check.to_s + "/" if check.file?
      resolved_str ||= check.to_s
      resolved_str.start_with?(workspace_str) || check.to_s == @workspace.to_s
    end

    # Extract the executable path from a command string.
    # Handles prefixes like env, sudo, cd, bash -c, etc.
    # @param command [String]
    # @return [String, nil] The command path or nil
    def extract_command_path(command)
      # Split on common shell operators
      cmd = command.split(/[;|&]/).first&.strip
      return nil if cmd.nil?

      # Handle subshell and command substitution
      cmd = cmd.gsub(/\$\(/, "").gsub(/`/, "")

      # Strip common prefixes
      prefixes = %w[env sudo nice time strace cd]
      prefixes.each do |prefix|
        if cmd.start_with?("#{prefix} ")
          parts = cmd.split
          parts.shift
          # Handle env VAR=val pairs
          parts.shift while parts.first&.include?("=")
          cmd = parts.join(" ")
        end
      end

      # Handle bash/sh -c "command"
      if cmd =~ /\A(?:bash|sh|zsh)\s+-c\s+/
        inner = cmd.match(/\A(?:bash|sh|zsh)\s+-c\s+["'](.+?)["']/)
        cmd = inner[1] if inner
      end

      # First word is the command
      cmd.split.first
    end

    # Generate a human-readable description of the current safety configuration.
    # @return [String]
    def to_s
      status = @restrict_to_workspace ? "ENABLED" : "DISABLED"
      mode = if @restrict_to_workspace
               @allow_read_outside ? "restrict-write" : "strict"
      else
               "permissive"
      end
      "SafetyGuard: #{status} (mode: #{mode}, workspace: #{@workspace || 'none'})"
    end

    # Custom error for security violations
    class SecurityError < StandardError; end
  end
end
