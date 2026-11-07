# frozen_string_literal: true

module Rubot
  module Tools
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
        tool = get(name)
        raise "Unknown tool: #{name}" unless tool
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
        register Search.new(safety_guard: @safety_guard)
        register Web.new
        register Cron.new
        register SendFile.new(safety_guard: @safety_guard)
      end
    end
  end
end
