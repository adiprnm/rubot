# frozen_string_literal: true

module Rubot
  module Web
    # One phrase for a delegated run, wherever it is drawn.
    #
    # A run says the same thing in three places — the strip above the composer,
    # the footer panel, and the row it leaves in the transcript — and a reader
    # comparing them must not find three different sentences about one agent.
    # So the wording lives here: the count of calls it has made, plus whatever
    # the phase has to say (the call it is on while working, how long it took
    # once done).
    #
    # A failed run says why instead: a count would add nothing to a run that
    # never got anything done.
    module SubagentLine
      def self.line(calls:, phase:, detail:)
        detail = detail.to_s
        return detail if phase.to_s == "failed"

        count = calls.to_i
        return detail if count.zero?

        detail.empty? ? "#{count} call" : "#{count} call · #{detail}"
      end
    end
  end
end
