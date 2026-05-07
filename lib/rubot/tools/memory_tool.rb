# frozen_string_literal: true

require_relative "../tool"

module Rubot
  module Tools
    # Tool that lets the bot read and update its own MEMORY.md file.
    # This enables the bot to remember important information across sessions.
    class MemoryTool < Tool
      def initialize(memory)
        @memory = memory
      end

      def name
        "memory"
      end

      def description
        <<~DESC.chomp
          Read and update the bot's persistent memory.
          Use this to remember important facts, user preferences,
          or project context across sessions.

          IMPORTANT: Memory can NEVER be fully erased or reset.
          Only additive operations (append, update_section) are allowed.

          Operations:
          - read: Read the entire memory
          - append: Add a fact to a section (Facts, Preferences, or Context)
          - update_section: Replace all items in a section
        DESC
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "operation" => {
              "type" => "string",
              "enum" => [ "read", "append", "update_section" ],
              "description" => "The memory operation to perform. Note: 'write' (full replace) is NOT available — memory cannot be reset."
            },
            "section" => {
              "type" => "string",
              "description" => "Section name for append/update_section (e.g., 'Facts', 'Preferences', 'Context')"
            },
            "content" => {
              "type" => "string",
              "description" => "Content for write, or the fact to append"
            },
            "items" => {
              "type" => "array",
              "items" => { "type" => "string" },
              "description" => "List of items for update_section"
            }
          },
          "required" => [ "operation" ]
        }
      end

      def execute(arguments)
        operation = arguments["operation"]

        case operation
        when "read"
          read_memory
        when "append"
          append_memory(arguments["section"], arguments["content"])
        when "update_section"
          update_section(arguments["section"], arguments["items"])
        else
          "ERROR: Unknown operation '#{operation}'. Use: read, append, update_section. NOTE: Full memory reset (write) is NOT allowed."
        end
      rescue => e
        "ERROR: #{e.class}: #{e.message}"
      end

      private

      def read_memory
        @memory.read
      end

      def append_memory(section, fact)
        return "ERROR: Memory not available (no workspace configured)" unless @memory.enabled?
        return "ERROR: 'section' and 'content' are required for append" unless section && fact
        @memory.append(section, fact)
        "Added to #{section}: #{fact}"
      end

      def update_section(section, items)
        return "ERROR: Memory not available (no workspace configured)" unless @memory.enabled?
        return "ERROR: 'section' and 'items' are required for update_section" unless section && items
        @memory.update_section(section, items)
        "Updated section '#{section}' with #{items.size} item(s)."
      end
    end
  end
end
