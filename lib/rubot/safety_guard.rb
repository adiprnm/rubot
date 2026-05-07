# frozen_string_literal: true

require "pathname"
require "etc"

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

    # Common prefixes that can be stripped from command fragments before
    # checking anchor-dependent dangerous patterns.
    STRIP_PREFIXES = %w[env sudo nice time nohup stdbuf ionice].freeze

    # Dangerous command patterns that are always blocked, regardless of mode.
    #
    # NOTE: Patterns using `$` anchor are applied to individual command fragments
    # after splitting on shell operators (`;`, `&&`, `||`, `|&`). This prevents
    # command chaining bypasses like `rm -rf /; echo done`.
    #
    # Patterns using `\beval\b` / `\bexec\b` (no anchor) are applied to
    # prefix-stripped fragments, preventing bypasses like `env eval 'rm -rf /'`.
    DANGEROUS_PATTERNS = [
      # --- Bulk deletion — any flag order, with optional extra flags ---
      /\brm\s+-(?:[rvfidRV]+[rR][rvfidRV]*|[rvfidRV]*[rR][rvfidRV]+)\s+\/\s*$/,
      /\brm\s+-(?:[rvfidRV]+[rR][rvfidRV]*|[rvfidRV]*[rR][rvfidRV]+)\s+\*\s*$/,
      /\brm\s+-[rvfidRV]*[rR][rvfidRV]*\s+\.\//,       # rm -rf ./*
      /\brm\s+--[rR]ecursive\s+--[fF]orce\s+/,   # rm --recursive --force
      /\brm\s+--[fF]orce\s+--[rR]ecursive\s+/,   # rm --force --recursive
      /\brm\s+(-[rvfidRV]+\s+)+\/\s*$/,             # rm -r -f / (separate flags)
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
      # Fork bomb (multiple syntaxes)
      /:\(\)\s*\{.*:\|.*&.*\}\s*;/,
      /:\(\)\s*\{.*:\|:\s*&.*\}\s*;/,             # space after &
      /[a-zA-Z_:]+\(\)\s*\{.*\|.*&/,     # named fork bomb (any name)
      /\bwhile\s+true\s*;\s*do.*&\s*done\b/,      # while-loop fork bomb
      # Pipe to shell (remote code execution) — includes sudo bypass
      /\bcurl\b.*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|fish)\b/,
      /\bwget\b.*-O-.*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|fish)\b/,
      /\bwget\b.*-qO-.*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|fish)\b/,
      # Pipe to interpreted languages (python, ruby, perl, node, php)
      /\bcurl\b.*\|\s*(?:sudo\s+)?(?:python3?|ruby|perl|node|php)\b/,
      /\bwget\b.*-O-.*\|\s*(?:sudo\s+)?(?:python3?|ruby|perl|node|php)\b/,
      /\bwget\b.*-qO-.*\|\s*(?:sudo\s+)?(?:python3?|ruby|perl|node|php)\b/,
      # Interpreted language inline execution
      /\b(python3?|ruby|perl|lua|node|php)\s+(-c|-e)\b/,
      /\b(python3?|ruby|perl)\s+-i\s*$/,  # interactive mode can be abused
      # Encoded payload decoders piped to shells
      /\bbase64\b.*(-d|--decode).*\|\s*(?:sudo\s+)?(?:sh|bash|zsh)\b/,
      /\bprintf\b.*\|\s*(?:sudo\s+)?(?:sh|bash|zsh)\b/,
      /\bxxd\b.*-r.*\|\s*(?:sudo\s+)?(?:sh|bash|zsh)\b/,
      # eval and exec shell builtins (checked on prefix-stripped fragments)
      /\beval\s+/,
      /\bexec\s+/,
      # Heredoc with eval/exec — check inner content
      /\b(?:bash|sh|zsh)\s*<<.*\beval\b/m,
      /\b(?:bash|sh|zsh)\s*<<.*\bexec\b/m,
      # Permission escalation on root — includes leading-zero octal and symbolic mode
      /\bchmod\s+0?777\s+\/\s*$/,
      /\bchmod\s+-R\s+0?777\s+\/\s*$/,
      /\bchmod\s+a\+rwx\s+\/\s*$/,
      # Filesystem destruction
      /\bmke2fs\b/,
      /\bmkswap\b/,
      /\bfsck\b.*-y\s+\/dev\//,
      # Memory destruction — case-insensitive, multiple methods
      /\brm\b.*memory\.md/i,
      /\btruncate\b.*memory\.md/i,
      /\bunlink\b.*memory\.md/i,
      /\bshred\b.*memory\.md/i,
      /\bmv\b.*memory\.md/i,
      /:>\s*.*memory\.md/i,
      /\becho\s+.*>\s*.*memory\.md/i,
      /\bcp\s+\/dev\/null\s+.*memory\.md/i,
      /\bdd\b.*\bof=.*memory\.md/i,
      /\bln\s+-sf.*memory\.md/i,
      /\bsed\b.*memory\.md/i,
      /\btee\s+.*memory\.md/i,
      # Memory destruction via variable substitution
      /\brm\b.*\$.*(?:MEMORY|memory)/i,
      /\bfind\b.*memory\.md/i,
      /\bcat\s+\/dev\/null\s*>\s*.*memory\.md/i,
      # xargs can execute arbitrary commands
      /\bxargs\b.*(?:bash|sh|rm)\b/,
      # User management / privilege escalation
      /\buseradd\b/,
      /\busermod\b/,
      /\bpasswd\b/,
      /\bvisudo\b/,
      /\bchown\s+root/,
      # Reverse shells via netcat/socat
      /\b(?:nc|ncat|netcat)\b.*(?:-e|-c)\s*(?:\/bin\/)?(?:ba)?sh\b/,
      /\b(?:nc|ncat|netcat)\b.*<\s*(?:\/etc\/|\/proc\/|\/sys\/|\/tmp\/|\/home)/,
      /\bsocat\b.*(?:EXEC:|exec,)/,
      # Scheduled execution bypass (at/batch)
      /\bat\s+(?:now|today|tomorrow|\+\d+\s*(?:min|hour|day|week|month))/,
      /\bat\s+-f\s+/,
      /\bbatch\b/,
      # Download-then-execute chains (checked on full command before splitting)
      /\bcurl\b.*(?:-o|-O)\s+\S+.*&&\s*(?:sudo\s+)?(?:ba)?sh\b/,
      /\bwget\b.*(?:-O\s+\S+|-O-).*&&\s*(?:sudo\s+)?(?:ba)?sh\b/,
      /\bwget\b.*(?:-O\s+\S+|-O-).*&&\s+\/\S+\s*$/,  # direct script execution
      # Process substitution pipe bypass
      /\|\s*tee\s+>\(\s*(?:sudo\s+)?(?:ba)?sh\b/,
      /\|\s*cat\s+>\(\s*(?:sudo\s+)?(?:ba)?sh\b/,
      # Environment variable manipulation
      /\b(?:PATH|LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|LD_BIND_NOW)\s*=/,
      /\bexport\s+(?:PATH|LD_PRELOAD|LD_LIBRARY_PATH)\s*=/,
      # Debugger arbitrary code execution
      /\bgdb\b.*(?:-ex|-batch)/,
      /\bpython3?\s+-m\s+pdb\b/,
      /\blldb\b.*-o\b/,
    ].freeze

    # Sensitive paths blocked in permissive mode.
    SENSITIVE_PATHS = %w[
      /etc/shadow /etc/gshadow /etc/security/opasswd
      /proc/self/environ /proc/1/environ
      /proc/kcore /proc/sysrq-trigger
      /sys/firmware
    ].freeze

    # Sensitive path regex patterns for broader matching.
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

    def initialize(workspace: nil, restrict_to_workspace: false, allow_read_outside: false)
      @workspace = workspace ? Pathname.new(workspace).expand_path : nil
      @restrict_to_workspace = restrict_to_workspace
      @allow_read_outside = allow_read_outside
    end

    def check_path(path, operation: :read)
      resolved = resolve_path(path)

      if sensitive_path?(resolved.to_s)
        raise SecurityError,
              "Path blocked by safety guard (sensitive system path: #{path})"
      end

      return true unless @restrict_to_workspace
      return true unless @workspace
      return true if SAFE_PATHS.include?(resolved.to_s)

      in_workspace = path_within_workspace?(resolved)

      if in_workspace
        true
      elsif @allow_read_outside && operation == :read
        true
      else
        op = operation.to_s
        action = op == "exec" ? "executing" : "#{op}ing"
        raise SecurityError,
              "Path blocked by safety guard: #{path} (#{action} outside workspace)"
      end
    end

    def check_command(command)
      cmd = command.strip
      return true if cmd.empty?

      if dangerous_command?(cmd)
        raise SecurityError,
              "Command blocked by safety guard (dangerous pattern detected)"
      end

      check_rate_limit(cmd)

      # FIX (PEN-02): Check tilde-expanded paths against sensitive patterns
      check_tilde_sensitive_paths(cmd)

      if has_unresolved_path_variables?(cmd)
        raise SecurityError,
              "Command blocked by safety guard (shell variables could bypass path checking)"
      end

      return true unless @restrict_to_workspace
      return true unless @workspace

      if cmd.include?("../") || cmd.include?("..\\")
        raise SecurityError,
              "Command blocked by safety guard (path traversal detected)"
      end

      abs_paths = extract_absolute_paths(cmd)
      abs_paths.each do |raw_path|
        if sensitive_path?(raw_path)
          raise SecurityError,
                "Command blocked by safety guard (sensitive system path: #{raw_path})"
        end

        next if SAFE_PATHS.include?(raw_path)

        resolved = resolve_path(raw_path)
        next if path_within_workspace?(resolved)

        rel = relative_to_workspace(resolved)
        if rel.to_s.start_with?("..")
          raise SecurityError,
                "Command blocked by safety guard (path outside working dir: #{raw_path})"
        end
      end

      true
    end

    def extract_absolute_paths(command)
      paths = []

      command.split(/[\s;|&<>]+/).each do |token|
        if token.include?("=")
          _key, value = token.split("=", 2)
          token = value
        end

        token = token.tr("'", "")
        token = token.tr('"', "")

        token = token.delete_suffix(")").delete_suffix("}").delete_suffix("`")

        next unless token.start_with?("/")
        next if token.start_with?("//")
        next if token == "/"
        next if token.start_with?(">", "<")

        paths << token
      end

      paths.uniq
    end

    def relative_to_workspace(resolved)
      resolved.relative_path_from(@workspace)
    rescue ArgumentError
      Pathname.new("../escape")
    end

    # Check if a command matches any dangerous pattern.
    #
    # FIX (PEN-01): Commands are split on shell operators before checking,
    # so chaining like `rm -rf /; echo done` is caught.
    #
    # FIX (PEN-02): Prefixes (env, sudo, nice, etc.) are stripped before
    # checking, so `env eval 'rm -rf /'` is caught.
    def dangerous_command?(command)
      cmd = command.strip
      return false if cmd.empty?

      # Check download-execute chains on full command before splitting
      return true if cmd =~ /\bcurl\b.*(?:-o|-O)\s+\S+.*&&\s*(?:sudo\s+)?(?:ba)?sh\b/
      return true if cmd =~ /\bwget\b.*(?:-O\s+\S+|-O-).*&&\s*(?:sudo\s+)?(?:ba)?sh\b/
      # wget download and direct execution (no explicit bash)
      return true if cmd =~ /\bwget\b.*(?:-O\s+\S+|-O-).*&&\s+\/\S+\s*$/
      # Fork bomb patterns that contain shell operators (split would break them)
      return true if cmd =~ /\bwhile\s+true\s*;\s*do.*&\s*done\b/

      split_commands(cmd).any? do |fragment|
        fragment = fragment.strip
        next false if fragment.empty?

        stripped = strip_prefixes(fragment)

        DANGEROUS_PATTERNS.any? { |pattern| fragment =~ pattern } ||
          DANGEROUS_PATTERNS.any? { |pattern| stripped =~ pattern }
      end
    end

    # Split a command string on shell control operators.
    def split_commands(command)
      command.split(/(?:\s*(?:;|\|\||&&|\|&)\s*)/)
    end

    # Strip common command prefixes that can be used to bypass patterns.
    def strip_prefixes(command)
      cmd = command.strip
      loop do
        prefix = STRIP_PREFIXES.find { |p| cmd.start_with?("#{p} ") }
        break unless prefix

        parts = cmd.split
        parts.shift
        parts.shift while prefix == "env" && parts.first&.include?("=") && parts.first =~ /\A[A-Za-z_]/
        cmd = parts.join(" ")
      end
      cmd
    end

    def writes_to_block_device?(command)
      cmd = command.strip
      return false unless cmd =~ /[>]/
      cmd =~ BLOCK_DEVICE_PATTERNS
    end

    def has_unresolved_path_variables?(command)
      return false unless @restrict_to_workspace
      command.match?(/\$[\w{(]/) || command.match?(/`[^`]+`/)
    end

    def resolve_path(path)
      p = path.is_a?(Pathname) ? path : Pathname.new(path.to_s)
      expanded = p.expand_path
      return expanded if expanded.to_s.start_with?("/dev/")
      if File.exist?(expanded.to_s)
        begin
          return Pathname.new(File.realpath(expanded.to_s))
        rescue SystemCallError
        end
      end
      expanded
    end

    def sensitive_path?(path)
      SENSITIVE_PATHS.include?(path) ||
        SENSITIVE_PATH_PATTERNS.any? { |p| path =~ p }
    end

    # FIX (PEN-02): Check tilde-expanded paths against sensitive patterns.
    def check_tilde_sensitive_paths(command)
      command.split(/[\s;|&<>]+/).each do |token|
        token = token.tr("'", "").tr('"', "")
        next unless token.start_with?("~")

        expanded = expand_tilde(token)
        next unless expanded && expanded.start_with?("/")

        if sensitive_path?(expanded)
          raise SecurityError,
                "Command blocked by safety guard (sensitive system path: #{token})"
        end
      end
    rescue ArgumentError
      nil
    end

    # Expand a tilde path token to an absolute path.
    def expand_tilde(token)
      match = token.match(/\A~(\w*)/)
      return nil unless match

      username = match[1]
      home = if username.empty?
        Dir.home
      else
        Etc.getpwnam(username).dir
      end

      home + token[match[0].length..]
    rescue ArgumentError
      nil
    end

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

    def path_within_workspace?(resolved)
      return false unless @workspace

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

    def extract_command_path(command)
      cmd = command.split(/[;|&]/).first&.strip
      return nil if cmd.nil?

      cmd = cmd.gsub(/\$\(/, "").gsub(/`/, "")

      prefixes = %w[env sudo nice time strace cd]
      prefixes.each do |prefix|
        if cmd.start_with?("#{prefix} ")
          parts = cmd.split
          parts.shift
          parts.shift while parts.first&.include?("=")
          cmd = parts.join(" ")
        end
      end

      if cmd =~ /\A(?:bash|sh|zsh)\s+-c\s+/
        inner = cmd.match(/\A(?:bash|sh|zsh)\s+-c\s+["'](.+?)["']/)
        cmd = inner[1] if inner
      end

      cmd.split.first
    end

    def to_s
      status = @restrict_to_workspace ? "ENABLED" : "DISABLED"
      mode = if @restrict_to_workspace
               @allow_read_outside ? "restrict-write" : "strict"
      else
               "permissive"
      end
      "SafetyGuard: #{status} (mode: #{mode}, workspace: #{@workspace || 'none'})"
    end

    class SecurityError < StandardError; end
  end
end
