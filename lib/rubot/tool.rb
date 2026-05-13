# frozen_string_literal: true

require "json"

module Rubot
  # Base class for all tools. Subclass and implement:
  #   - name
  #   - description
  #   - parameters (JSON schema)
  #   - execute(arguments)
  class Tool
    # Human-readable name of the tool
    def name
      raise NotImplementedError, "#{self.class} must implement #name"
    end

    # Description shown to the LLM
    def description
      raise NotImplementedError, "#{self.class} must implement #description"
    end

    # JSON Schema for the tool's input parameters
    def parameters
      {
        "type" => "object",
        "properties" => {},
        "required" => []
      }
    end

    # Execute the tool with the given arguments (parsed JSON hash).
    # Returns a string result.
    def execute(arguments)
      raise NotImplementedError, "#{self.class} must implement #execute"
    end

    # Returns true if the given arguments represent an action that could cause
    # data loss (e.g., overwriting an existing file, deleting files, destructive
    # shell commands). Used by the Agent to request user confirmation before
    # execution. Override in subclasses to define dangerous operations.
    def dangerous_action?(arguments)
      false
    end

    # Convert to the provider's native tool definition format.
    # Delegates to the provider's format_tools method.
    def to_provider_format(provider_name)
      {
        "type" => "function",
        "function" => {
          "name" => name,
          "description" => description,
          "parameters" => parameters
        }
      }
    end
  end
end
