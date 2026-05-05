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

    # Dangerous command patterns that are always blocked, even without workspace restriction
    DANGEROUS_PATTERNS = [
      # Bulk deletion
      /\brm\s+-rf\s+\/\s*$/,
      /\brm\s+-rf\s+\*\s*$/,
      /\brm\s+--no-preserve-root\s/,
      # Disk formatting / low-level writes
      /\bmkfs\b/,
      /\bdd\s+.*of=\/dev\//,
      /\bdd\s+if=\/dev\//,
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
      # Pipe to shell (remote code execution)
      /\bcurl\b.*\|\s*(sh|bash|zsh)\b/,
      /\bwget\b.*-O-.*\|\s*(sh|bash|zsh)\b/,
      # Permission escalation on root
      /\bchmod\s+777\s+\/\s*$/,
      /\bchmod\s+-R\s+777\s+\/\s*$/,
      # Filesystem destruction
      /\bmke2fs\b/,
      /\bmkswap\b/,
      /\bfsck\b.*-y\s+\/dev\//,
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
      return true unless @restrict_to_workspace
      return true unless @workspace

      resolved = resolve_path(path)

      # Always allow safe device paths
      return true if SAFE_PATHS.include?(resolved.to_s)

      # Check if path is within workspace
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
    # @param command [String] The command to check
    # @return [Boolean] true if the command is allowed
    # @raises [SecurityError] if the command is blocked
    def check_command(command)
      return true unless @restrict_to_workspace
      return true unless @workspace

      cmd = command.strip
      return true if cmd.empty?

      # 1. Check deny patterns (always enforced)
      if dangerous_command?(cmd)
        raise SecurityError,
              "Command blocked by safety guard (dangerous pattern detected)"
      end

      # 2. Block path traversal
      if cmd.include?("../") || cmd.include?("..\\")
        raise SecurityError,
              "Command blocked by safety guard (path traversal detected)"
      end

      # 3. Find all absolute paths in the command and check each one
      abs_paths = extract_absolute_paths(cmd)
      abs_paths.each do |raw_path|
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

        # Must start with /
        next unless token.start_with?("/")
        # Skip URL path components (//)
        next if token.start_with?("//")
        # Skip bare /
        next if token == "/"
        # Strip trailing quotes if present
        token = token.delete_suffix('"').delete_suffix("'")
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

    # Resolve a path to its absolute, expanded form.
    # @param path [String, Pathname]
    # @return [Pathname]
    def resolve_path(path)
      p = path.is_a?(Pathname) ? path : Pathname.new(path.to_s)
      p.expand_path
    end

    # Check if a resolved path is within the workspace.
    # @param resolved [Pathname] Already-expanded path
    # @return [Boolean]
    def path_within_workspace?(resolved)
      return false unless @workspace
      workspace_str = @workspace.to_s + "/"
      resolved_str = resolved.to_s + "/" if resolved.file?
      resolved_str ||= resolved.to_s
      resolved_str.start_with?(workspace_str) || resolved.to_s == @workspace.to_s
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
