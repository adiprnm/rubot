# frozen_string_literal: true

module Rubot
  module Tools
    # Every tool this install can run, by name. What an agent may call is a
    # separate question, answered by the list of tools it was offered for the
    # turn (see Agent#tool_definitions); this registry only knows what exists.
    class Registry
      attr_reader :tools, :safety_guard

      def initialize(safety_guard: nil)
        @tools = {}
        @safety_guard = safety_guard
        register_defaults
      end

      def register(tool)
        @tools[tool.name] = tool
      end

      def get(name)
        @tools[name]
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

      def execute(name, arguments)
        tool = @tools[name]
        raise "Unknown tool: #{name}" if tool.nil?

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
        register FileRead.new(safety_guard: @safety_guard)
        register FileWrite.new(safety_guard: @safety_guard)
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
