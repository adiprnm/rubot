# frozen_string_literal: true

module Rubot
  module Web
    # One phrase for a delegated run, wherever it is drawn.
    #
    # A run says the same thing in the strip above the composer, the footer
    # panel, and the row it leaves in the transcript, and a reader comparing
    # them must not find three different sentences about one agent. So the
    # wording lives here: the count of steps it has taken, plus the one thing
    # the phase has to say — the task while it works, how long it took once
    # done. A step is "langkah" on screen — "call" is the agent's word for it,
    # not the reader's, and a row of one is the first thing they see.
    #
    # What a run reaches for is never part of the sentence: which tool it called
    # and how that call would be captioned is the agent's business, and dressing
    # it as a phrase of its own made the row read "3 langkah · Menjalankan
    # perintah di terminal" for the whole run, next to the name of an agent
    # doing something else entirely.
    #
    # A failed run says why instead: a count would add nothing to a run that
    # never got anything done.
    module SubagentLine
      # How much of a task a row carries. A task is a whole brief and the row is
      # one line wide: the beginning is enough to tell two runs apart, and the
      # whole of it stays on the row's tooltip.
      SUBJECT_CHARS = 60

      def self.line(calls:, phase:, detail:)
        detail = detail.to_s
        return detail if phase.to_s == "failed"

        count = calls.to_i
        return detail if count.zero?

        detail.empty? ? "#{count} langkah" : "#{count} langkah · #{subject(detail)}"
      end

      def self.subject(detail)
        return detail if detail.length <= SUBJECT_CHARS

        "#{detail[0, SUBJECT_CHARS - 1]}…"
      end
    end
  end
end
