# frozen_string_literal: true

module Rubot
  module Web
    # Which tool rows a timeline draws.
    #
    # A long turn on a busy agent runs a dozen calls, and the log of them is not
    # what the reader came for: the answer is. A persona can ask for the
    # `compact` view, where the timeline keeps only the call the turn is on
    # right now — each new row replaces the one above it, so the row reads as
    # "what it is doing" rather than as history — while the sentences around the
    # calls, the answer, the files a tool handed back and the diffs stay where
    # they were.
    #
    # `verbose` is the timeline as it happened, every call in its place. Both
    # the live turn (see Rubot::Web::Turn) and the replayed transcript go
    # through here, so a refreshed page shows what the live one showed.
    module ToolRows
      def self.compact?(mode)
        mode.to_s == "compact"
      end

      # The kinds that carry the conversation rather than the state of a call:
      # what the model said, what the reader steered with, the files a tool
      # handed back. These stay wherever they happened.
      CONTENT = %i[text steer attachments].freeze

      # `items` with the earlier rounds taken out: the last call of the turn
      # stays, everything before it goes. A round is the call plus the thought
      # that led into it and the diff it drew, so all three leave together —
      # dropping the row but keeping the thought above it would pile "Thought
      # for 4s" over "Thought for 7s" and read as if the model had thought
      # twice before its first call, when the turn actually went call, thought,
      # call, thought. What the model said in an earlier round stays: it is
      # text the reader is in the middle of reading.
      def self.collapse(items)
        list = Array(items)
        last = list.rindex { |item| item[:kind] == :tool }
        return list if last.nil?

        kept = list[0...last].select { |item| CONTENT.include?(item[:kind]) }
        kept + list[last..]
      end
    end
  end
end
