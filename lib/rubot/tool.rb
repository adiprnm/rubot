# frozen_string_literal: true

require "json"

module Rubot
  # Base class for all tools. Subclass and implement:
  #   - name
  #   - description
  #   - parameters (JSON schema)
  #   - execute(arguments)
  class Tool
    # The directory relative paths are resolved against. Channels set this to
    # the agent's workspace: the persona directory on web, the configured
    # workspace on TUI. Without it, tools fall back to the process cwd, which
    # is where rubot happened to be launched and not where files belong.
    attr_writer :workspace

    def workspace
      @workspace
    end

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

    # Does this tool change the workspace? The default is yes, deliberately: a
    # tool added later has to opt out instead of being assumed harmless. The
    # reading tools answer no, and a role whose tools all answer no is read-only
    # because its list holds no writing tool: the list is the whole rule, with
    # no flag to keep in step. This is the one place that question is answered,
    # so a new write-capable tool cannot quietly widen a read-only role.
    def writes?
      true
    end

    # Returns true if the given arguments represent an action that could cause
    # data loss (e.g., overwriting an existing file, deleting files, destructive
    # shell commands). Used by the Agent to request user confirmation before
    # execution. Override in subclasses to define dangerous operations.
    def dangerous_action?(arguments)
      false
    end

    # A tool can answer with UI instead of words. `silent_operation?` says the
    # call is one of those (known before it runs, so the agent can skip the
    # progress narration); `silent_result?` confirms it after the run, so a
    # failed call still gets a normal answer from the model. The agent stops
    # the turn on a silent result — there is nothing for a model to add.
    def silent_operation?(_arguments)
      false
    end

    def silent_result?(_result)
      false
    end

    # Why #dangerous_action? said yes, in words the user can act on
    # ("overwrite build.log — 412 of 900 lines would be lost"), or nil when
    # the tool has nothing better to offer than its arguments. Channels put
    # this in the confirmation prompt so the question describes the damage
    # instead of shouting that something is dangerous.
    def dangerous_action_reason(arguments)
      nil
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
