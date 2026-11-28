# frozen_string_literal: true

module Rubot
  module Tools
    class Registry
      # What a read-only caller may use. Deliberately an allowlist: a tool that
      # can change the workspace and is not named here is denied, so a tool
      # added later cannot quietly widen what a read-only role can do. A denylist
      # was tried first and was already wrong, because it named file_ops and
      # shell_exec while cron, loop and memory could write too.
      #
      # shell is absent on purpose, not by oversight: a shell command can write
      # any file a guard would have to refuse, so there is no read-only shell.
      READ_ONLY_SAFE_TOOLS = %w[file_ops search web_fetch].freeze

      attr_reader :tools, :safety_guard, :read_only_tools

      def initialize(safety_guard: nil)
        @tools = {}
        @read_only_tools = {}
        @safety_guard = safety_guard
        register_defaults
      end

      def register(tool)
        @tools[tool.name] = tool
      end

      # The read-only face of a tool, for the few that have one. It is a second
      # instance only because a name can map to one object at a time; the guard
      # itself is a property of the class (see FileReadTool), so no agent can
      # turn it off by writing to the instance.
      def register_read_only(tool)
        @read_only_tools[tool.name] = tool
      end

      def get(name)
        @tools[name]
      end

      def read_only_tool(name)
        @read_only_tools[name]
      end

      # The tool a call is about, as this caller is allowed to see it. nil means
      # "not available to you": the confirmation step treats it as absent, and
      # #execute says so in words.
      def tool_for(name, read_only: false)
        return nil unless @tools.key?(name)
        return @tools[name] unless read_only

        @read_only_tools[name] || (READ_ONLY_SAFE_TOOLS.include?(name) ? @tools[name] : nil)
      end

      def all
        @tools.values
      end

      def names
        @tools.keys
      end

      def enabled?(name)
        @tools.key?(name)
      end

      def execute(name, arguments, read_only: false)
        tool = tool_for(name, read_only: read_only)
        if tool.nil?
          raise "Refused: '#{name}' is not available to a read-only agent." if read_only && @tools.key?(name)

          raise "Unknown tool: #{name}"
        end

        tool.execute(arguments)
      end

      # Convert all tools to the provider's native format
      def to_provider_definitions(provider_name)
        all.map { |t| t.to_provider_format(provider_name) }
      end

      def count
        @tools.size
      end

      def clear
        @tools = {}
      end

      private

      def register_defaults
        register Shell.new(safety_guard: @safety_guard)
        register FileTool.new(safety_guard: @safety_guard)
        register_read_only FileReadTool.new(safety_guard: @safety_guard)
        register AskUser.new
        register Search.new(safety_guard: @safety_guard)
        register Web.new
        register Cron.new
        register SendFiles.new(safety_guard: @safety_guard)
        register Notify.new
        register Instagram.new
        register Delegate.new
        register SubagentResults.new
        register Loop.new
      end
    end
  end
end
