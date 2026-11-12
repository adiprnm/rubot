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

      # `items` with the earlier tool rows taken out: the last call of the turn
      # stays, everything before it goes. A diff belongs to the call above it —
      # in both producers the two are adjacent — so it leaves with the row it
      # was drawn under; an attachment is a file the reader may still want, so
      # it stays.
      def self.collapse(items)
        list = Array(items)
        last = list.rindex { |item| item[:kind] == :tool }
        return list if last.nil?

        hidden = false
        list.each_with_index.each_with_object([]) do |(item, index), kept|
          case item[:kind]
          when :tool
            hidden = index != last
            kept << item unless hidden
          when :diff
            kept << item unless hidden
          else
            # Anything else ends the call it followed, so a diff can never be
            # mistaken for the tail of a row that is still drawn.
            hidden = false
            kept << item
          end
        end
      end
    end
  end
end
