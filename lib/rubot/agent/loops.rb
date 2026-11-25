# frozen_string_literal: true

module Rubot
  class Agent
    # A loop asked for from inside a turn, and how the request leaves the
    # Ractor this turn runs in.
    #
    # A loop outlives the turn that starts it, so it needs a thread, a session
    # pool and a lambda that can reach an agent -- and none of those cross a
    # Ractor boundary. A channel in actor mode therefore cannot stamp a runner
    # onto the tool: the tool would only see a proxy. The shape that already
    # solves this is delegation (see agent/subagents.rb), so this is that shape
    # and not a second mechanism: the agent calls a callback with plain data,
    # the callback becomes an event, and the channel executes on its own side.
    #
    # Kept out of agent.rb for the reason Subagents is: the class is near its
    # ceiling, and this is a story of its own -- what the request carries, and
    # what the model is told while the channel works it.
    module Loops
      # A channel that can work a loop somewhere other than this turn's thread
      # -- the web channel, which owns the runner -- sets this. `request_loop`
      # then hands the request over instead of starting anything here.
      attr_accessor :on_loop

      # The operations a channel can be asked to perform. `status` and `list`
      # answer from the state file, which is a plain read the tool does itself,
      # so they never reach this.
      REQUEST_OPS = %i[start resume abort].freeze

      # Ask the channel to work this loop, or answer nil so the tool falls back
      # to a runner it already holds, and then to its honest "no runner"
      # message. nil is the signal, not an error: a channel that never set
      # `on_loop` keeps the synchronous behaviour it has today.
      #
      # The request carries plain data only, because it travels through the
      # actor's port to the main Ractor: the executor builds the runner from
      # the parent conversation, since an object graph cannot leave a Ractor.
      def request_loop(op:, id:, slug: nil)
        return nil unless @on_loop

        # A sub agent that starts a loop hands back an answer while the work it
        # began keeps spending tokens, with nobody watching it. The loop tool is
        # already taken off a sub agent (SUBAGENT_FORBIDDEN_TOOLS); this is the
        # same guard delegation puts on itself, for the paths that miss it.
        return "ERROR: a sub agent cannot start a loop." if @subagent_depth.to_i.positive?

        operation = op.to_s.to_sym
        return "ERROR: unknown loop operation #{op.inspect}." unless REQUEST_OPS.include?(operation)

        loop_id = id.to_s
        @on_loop.call(
          op: operation,
          id: loop_id,
          parent_session: @session.id.to_s,
          slug: (slug || @persona&.slug).to_s
        )
        loop_hand_off_sentence(operation, loop_id)
      rescue StandardError => e
        # Never raise into the turn: a tool owes the model a sentence either
        # way, and a callback that blew up is not a reason to fail the answer.
        "ERROR: the loop could not be handed to the channel: #{e.class}: #{e.message}"
      end

      private

      # What the model is told once the request is out of its hands. It mirrors
      # the delegation sentence: the work continues without the turn, the answer
      # arrives by itself, and asking for status is the way to look in on it.
      def loop_hand_off_sentence(operation, id)
        if operation == :abort
          return "Loop #{id} was asked to stop in the background: it stops after the " \
                 "iteration in flight, which is still paid for. A status call shows " \
                 "where it got."
        end

        verb = operation == :start ? "started" : "resumed"
        "Loop #{id} #{verb} in the background. It keeps working after this turn ends, " \
          "and the answer arrives on its own when it settles: do not sit and wait for " \
          "it, and do not call status in a loop or sleep until it is ready. A status " \
          "call shows where it got."
      end
    end
  end
end
