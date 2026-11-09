# frozen_string_literal: true

require_relative "../tool"
require_relative "../memory_bank"

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
        label = scope_label
        <<~DESC.chomp
          Read and update the bot's persistent memory.
          Use this to remember important facts, user preferences,
          or context across sessions.

          Memory has two layers, chosen with `scope`:
          - #{label} (default): what is true for this #{label} only. Stored in
            its own file, so no other #{label} sees it.
          - global: what is true everywhere — who the user is, how they want you
            to behave. Shared by every workspace and every persona.

          Rule of thumb: facts about the user that hold everywhere go to global;
          anything true only of this job, this client, this project or this
          persona's own domain stays in #{label}.

          Memory is additive: there is no full replace.

          Operations:
          - read: Read the memory (both layers merged)
          - append: Add a fact to a section (Facts, Preferences, Context, Learned Corrections)
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
              "description" => "Memory operation (there is no full-replace write)"
            },
            "scope" => {
              "type" => "string",
              "enum" => [ scope_label, "global" ],
              "description" => "Which layer to read/write (default: #{scope_label})"
            },
            "section" => {
              "type" => "string",
              "description" => "Section name for append/update_section (e.g., 'Facts', 'Preferences', 'Context')"
            },
            "content" => {
              "type" => "string",
              "description" => "Fact to append"
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
        scope = scope_for(arguments["scope"])

        case operation
        when "read"
          read_memory
        when "append"
          append_memory(arguments["section"], arguments["content"], scope)
        when "update_section"
          update_section(arguments["section"], arguments["items"], scope)
        else
          "ERROR: Unknown operation '#{operation}'. Use: read, append, update_section. NOTE: Full memory reset (write) is NOT allowed."
        end
      rescue => e
        "ERROR: #{e.class}: #{e.message}"
      end

      private

      # What this memory's own layer is called: "persona" for a specialist,
      # "workspace" for a project. The model reads the label, so a persona is
      # never told its memory belongs to a workspace.
      def scope_label
        return MemoryBank::SCOPE_WORKSPACE unless @memory.respond_to?(:workspace_label)

        @memory.workspace_label
      end

      # Unknown or missing scope falls back to the local layer, which is what
      # an unattended write should touch: a wrong guess stays local.
      def scope_for(scope)
        return MemoryBank::SCOPE_GLOBAL if scope.to_s.downcase == MemoryBank::SCOPE_GLOBAL

        MemoryBank::SCOPE_WORKSPACE
      end

      def read_memory
        @memory.read
      end

      def append_memory(section, fact, scope)
        return "ERROR: Memory not available (no workspace configured)" unless @memory.enabled?
        return "ERROR: 'section' and 'content' are required for append" unless section && fact
        @memory.append(section, fact, scope: scope)
        "Added to #{section} (#{scope}): #{fact}"
      end

      def update_section(section, items, scope)
        return "ERROR: Memory not available (no workspace configured)" unless @memory.enabled?
        return "ERROR: 'section' and 'items' are required for update_section" unless section && items
        @memory.update_section(section, items, scope: scope)
        "Updated section '#{section}' (#{scope}) with #{items.size} item(s)."
      end
    end
  end
end
