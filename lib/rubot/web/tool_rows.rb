# frozen_string_literal: true

module Rubot
  module Web
    # Which tool rows a timeline draws.
    #
    # A long turn on a busy agent runs a dozen calls, and the log of them is not
    # what the reader came for: the answer is. A persona can ask for the
    # `compact` view, where the timeline keeps only what the turn is on right
    # now — the batch of calls the model is waiting for, the thought that led
    # into it, and every edit it touched — while the sentences around it, the
    # answer, and the files a tool handed back stay where they were. The row
    # reads as "what it is doing" rather than as history.
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

      # An edit the reader may have to answer for later. Nothing about the
      # compact view is worth losing the row that says "this file was written":
      # the diff under it is the receipt, and a row without a diff (a no-op
      # write, a file too large to draw) still has to be there to be found.
      MUTATING_OPS = %w[write append edit delete].freeze

      # When the model speaks, the work it asked for before that is done; a
      # thought between two calls means it decided to look again. So the
      # timeline of a turn runs text → call → thought → call → thought → text,
      # and the tail worth drawing starts at the batch it is on: the calls it
      # asked for in the same breath, plus the thought that led into them.
      #
      # `items` with the earlier log taken out. What survives from the log: the
      # text, the steering messages, the attachments, every diff together with
      # the row it was drawn under, and the calls that changed a file or failed.
      def self.collapse(items)
        list = Array(items)
        tail = tail_start(list)
        return list if tail.nil?

        list.each_with_index.filter_map do |item, index|
          next item if index >= tail
          next item if survives?(list, index)

          nil
        end
      end

      # Where the tail begins. Nil when the turn made no call at all: there is
      # nothing to collapse, and the timeline is already the answer.
      def self.tail_start(list)
        rows = list.each_index.reject { |index| list[index][:kind] == :steer }
        last = rows.rindex { |index| list[index][:kind] == :tool }
        return nil if last.nil?

        first = last
        first -= 1 while first.positive? && list[rows[first - 1]][:kind] == :tool
        first -= 1 while first.positive? && list[rows[first - 1]][:kind] == :thinking
        rows[first]
      end

      # An item from the log that is not a call log. A diff stays whatever it is
      # drawn under: it is a change the turn made, and the row above it stays
      # too whenever it drew one (see draws_a_diff?), so the patch is never left
      # without the call it belongs to.
      def self.survives?(list, index)
        item = list[index]
        return true if CONTENT.include?(item[:kind]) || item[:kind] == :diff
        return false unless item[:kind] == :tool

        keeps_call?(item) || draws_a_diff?(list, index)
      end

      # A call whose result the reader has to be able to find again: a file it
      # changed, or a failure it should hear about rather than watch the model
      # silently retry.
      def self.keeps_call?(item)
        item[:state] == :failed || MUTATING_OPS.include?(item[:op].to_s)
      end

      # The diff this row drew, if any: it is the next row down, and only the
      # reader talking can come between them.
      def self.draws_a_diff?(list, index)
        list[(index + 1)..].to_a.each do |item|
          case item[:kind]
          when :diff then return true
          when :steer, :attachments then next
          else return false
          end
        end
        false
      end
    end
  end
end
