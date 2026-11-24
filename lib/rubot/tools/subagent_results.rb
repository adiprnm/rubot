# frozen_string_literal: true

module Rubot
  module Tools
    # Read what a background delegation came back with.
    #
    # Delegation is asynchronous in the channels that support it: the run keeps
    # working after the turn that started it, so its answer cannot be the return
    # value of the `delegate` call. It is written to the archive instead, and
    # this tool is how the parent reads it — when it wants it, not when it
    # arrives.
    #
    # Like `delegate`, this class only describes the call; the Agent owns the
    # query and the bookkeeping that stops an answer being handed over twice.
    class SubagentResults < Tool
      attr_writer :agent

      def name
        "subagent_results"
      end

      def description
        "Read the answer of a delegated agent that finished in the background. " \
          "Background runs keep working after the turn that started them, so " \
          "their answer is collected here. Each answer is returned once. In a " \
          "channel that runs delegations in the background the batch is also " \
          "handed back to you on its own once the last run of it lands, so this " \
          "is for when you need one now, or when an answer told you that more " \
          "are waiting: never poll it in a loop or sleep until something is ready."
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "run_id" => {
              "type" => "string",
              "description" => "Optional: read only the run with this id"
            }
          },
          "required" => []
        }
      end

      def execute(arguments)
        return "ERROR: no agent is attached to the subagent_results tool." unless @agent

        @agent.subagent_results(run_id: arguments["run_id"])
      end
    end
  end
end
