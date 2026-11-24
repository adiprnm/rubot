# frozen_string_literal: true

module Rubot
  module Tools
    # Hand a self-contained task to another persona. The tool is a thin
    # adapter: the parent Agent owns the spawning, the guards and the event
    # stream, so this class only describes the call and forwards it.
    class Delegate < Tool
      attr_writer :agent

      def name
        "delegate"
      end

      def description
        "Delegate a self-contained task to another agent (a persona by slug). " \
          "The sub agent has its own model, prompt, memory and workspace. In a " \
          "channel that runs delegations in the background this returns as soon " \
          "as the run starts and the answer arrives on its own; in the others it " \
          "returns with the written result."
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "agent" => { "type" => "string", "description" => "Slug of the persona to delegate to" },
            "task" => { "type" => "string", "description" => "Complete, self-contained task" },
            "model" => { "type" => "string", "description" => "Optional one-off model override" }
          },
          "required" => %w[agent task]
        }
      end

      def execute(arguments)
        return "ERROR: no agent is attached to the delegate tool." unless @agent

        @agent.spawn_subagent(
          agent_slug: arguments["agent"],
          task: arguments["task"],
          model: arguments["model"]
        )
      end
    end
  end
end
