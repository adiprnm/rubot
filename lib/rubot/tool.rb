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
