# frozen_string_literal: true

module Rubot
  class Agent
    # The state of one turn: what it is allowed to spend, what it has spent, and
    # what it has to show for it.
    #
    # #process used to keep all of this in local variables, which is why every
    # phase of a turn had to live inside one 400-line method: there was nowhere
    # else to put them. They are one object now, so a phase can be handed the
    # turn instead of reaching into the middle of a method.
    #
    # What is deliberately *not* here yet: the pool of per-round values
    # (`response`, `tool_calls`, `reasoning_content`, `finish_reason`) and
    # `@turn_start_index`. Those describe one round, or the request as a whole,
    # and move when the round loop gets its own class (see the F5 plan).
    class Turn
      # How many provider rounds this turn may take.
      attr_reader :limit
      # The answer, assembled across continuations and steering messages.
      attr_reader :answer

      attr_accessor :rounds, :tool_rounds, :continuations, :reasked, :truncated,
                    :silent_answer, :stopped, :limit_hit

      def initialize(limit:)
        @limit = limit
        @answer = +""
        @rounds = 0
        @tool_rounds = 0
        @continuations = 0
        @reasked = false
        @truncated = false
        @silent_answer = false
        @stopped = false
        @limit_hit = false
      end

      # One more provider round would be one more than the turn was allowed.
      def exhausted?
        rounds >= limit
      end
    end
  end
end
