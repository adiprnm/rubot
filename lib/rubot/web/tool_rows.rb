# frozen_string_literal: true

module Rubot
  module Web
    # Which tool rows a timeline draws.
    #
    # A long turn on a busy agent runs a dozen calls, and the log of them is not
    # what the reader came for: the answer is. A persona can ask for the
    # `compact` view, where the timeline keeps one call row — the one the turn
    # reached for last — plus every edit it touched, while the sentences around
    # it, the thoughts it took, the answer and the files a tool handed back stay
    # where they were. The row reads as "what it is doing" rather than as
    # history.
    #
    # One row, in its own place: a call replaced by a later call is dropped from
    # where it stood, and nothing moves up to fill the gap. What separates two
    # calls on screen is therefore whatever the model left between them — a
    # thought it took, a sentence it said — not a rule of this module.
    #
    # `verbose` is the timeline as it happened, every call in its place. Both
    # the live turn (see Rubot::Web::Turn) and the replayed transcript go
    # through here, so a refreshed page shows what the live one showed.
    module ToolRows
      def self.compact?(mode)
        mode.to_s == "compact"
      end

      # A write/append/delete the reader may have to answer for later. Nothing
      # about the compact view is worth losing the row that says "this file was
      # written": the diff under it is the receipt, and a row without a diff (a
      # no-op write, a file too large to draw) still has to be there to be
      # found.
      #
      # An edit is different: it only earns its row when it actually changed
      # something, i.e. when a diff is drawn under it. An edit whose diff is
      # empty (a no-op edit) is dropped in compact mode, the same as a read.
      MUTATING_OPS = %w[write append delete].freeze

      # `items` with the log of old calls taken out.
      #
      # Read top to bottom, a turn is text → call → thought → call → thought,
      # and every call but the last is the log: the model has already got its
      # answer and moved on from it. So the last call keeps its row and the
      # others leave — except the ones the reader has to be able to come back
      # for (a file changed, a failure, a diff, work still running).
      #
      # A pause goes wherever the call it was taken for goes. A "Thought for"
      # row is read as belonging to the row above it — the model paused, then
      # reached for that call — so a call that leaves takes its pause with it.
      # Left behind, the pauses piled up: three "Thought for" lines in a row,
      # nothing between them, telling the reader nothing about what happened in
      # between. The first pause of a turn is the exception: nothing above it
      # was called yet, so there is nothing to leave with.
      #
      # Everything that is not a call or a pause stays exactly where it
      # happened: the sentences, the steering messages, the diffs, the files a
      # tool handed back. That is the whole rule — there is no round to find,
      # no line to draw above the batch, and therefore nothing to guess from the
      # neighbouring rows when the transcript carries no marker.
      def self.collapse(items)
        list = Array(items)
        latest = list.rindex { |item| item[:kind] == :tool }
        return list if latest.nil?

        kept = []
        list.each_with_index do |item, index|
          next kept << index unless item[:kind] == :tool
          # The latest call is the row on screen — unless it is an edit that
          # changed nothing, which has no diff to show and is dropped like a read.
          next kept << index if index == latest && !empty_edit?(item, list, index)
          next kept << index if keeps_call?(item)
          next kept << index if draws_a_diff?(list, index)
        end
        kept = kept.to_h { |index| [ index, true ] }

        # What the pause above is drawn under: nil until a call has been seen,
        # then whether that call survived.
        under = nil
        list.each_with_index.filter_map do |item, index|
          case item[:kind]
          when :tool
            under = kept.key?(index)
            item if under
          when :thinking
            item if under.nil? || under
          else
            item
          end
        end
      end

      # A call whose result the reader has to be able to find again: a file it
      # changed, a failure it should hear about rather than watch the model
      # silently retry, and a call still running — a row that vanished under a
      # spinning clock reads as work disappearing mid-flight.
      def self.keeps_call?(item)
        records_a_result?(item) || item[:state] == :running
      end

      # The two results a row owes the reader even when the turn moved on: what
      # it touched, and where it broke.
      def self.records_a_result?(item)
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

      # An edit that changed nothing: no diff is drawn under it. Such a row is
      # dropped in compact mode, the same as a read.
      def self.empty_edit?(item, list, index)
        return false unless item[:kind] == :tool
        return false unless item[:op].to_s == "edit"
        !draws_a_diff?(list, index)
      end
    end
  end
end
