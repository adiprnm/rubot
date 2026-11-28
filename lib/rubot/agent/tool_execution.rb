# frozen_string_literal: true

module Rubot
  class Agent
    # Running the calls a model asked for: several at a time, reported in the
    # order it asked for them.
    #
    # This is the part of a turn that touches the world. It was inside #process
    # because that was the only place that knew which calls were approved; the
    # approval stays there and only the running lives here, which is why these
    # two methods take a call list and nothing else.
    module ToolExecution
      # Run one call. The set of tools this agent was offered is the whole
      # permission model: a name outside it does not run, whether the model
      # invented it, or a channel asks for it outside a turn. Public because
      # the channel handle executes a tool through the same door.
      def execute_tool(name, arguments)
        return refusal_for(name) unless offered_tool?(name)

        @tools.execute(name, arguments)
      end

      private

      # Whether this agent was offered a tool for this turn. `tool_definitions`
      # is what the provider is sent, so asking it cannot drift from what the
      # model was shown.
      def offered_tool?(name)
        definitions = tool_definitions
        return false if definitions.nil?

        definitions.any? { |tool| tool.name == name.to_s }
      end

      # The answer a refused call gets: which tool, and why. A model that names
      # a tool it was not offered (an invented name, or a write when only the
      # reading tool is present) is told plainly instead of running it.
      def refusal_for(name)
        "ERROR: Refused: '#{name}' is not one of the tools offered to this agent."
      end

      # Run the approved tool calls, several at a time, and return them in the
      # order they were asked for — a caller walking the result sees a transcript
      # exactly like the sequential one, with the wall time of the slowest call
      # instead of the sum. Calls already carrying a result are passed through.
      def execute_tool_calls(calls)
        todo = calls.reject { |call| call.key?(:result) }
        if todo.size < 2
          return calls.map { |call| call.key?(:result) ? call : call.merge(result: run_one_tool(call)) }
        end

        queue = Queue.new
        todo.each { |call| queue << call }
        results = {}
        lock = Mutex.new

        [ todo.size, MAX_PARALLEL_TOOLS ].min.times.map do
          Thread.new do
            while (call = begin
              queue.pop(true)
            rescue ThreadError
              nil
            end)
              result = run_one_tool(call)
              lock.synchronize { results[call.object_id] = result }
            end
          end
        end.each(&:join)

        calls.map { |call| call.key?(:result) ? call : call.merge(result: results[call.object_id]) }
      end

      # One tool call, with its output made safe for the transcript and the
      # request: a read can return a PNG, and an error is reported to the model
      # rather than raised, because a failed tool is a thing to answer about.
      def run_one_tool(call)
        result = execute_tool(call[:name], call[:arguments])
        Session.normalize_utf8(result.to_s)
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end
    end
  end
end
