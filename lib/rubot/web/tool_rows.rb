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

      # The rows that mark a pause between rounds: a thought the model took, and
      # the marker left behind when it was too quick to earn a clock. A pause
      # opens the round below it (see tail_start).
      PAUSES = %i[thinking step].freeze

      # An edit the reader may have to answer for later. Nothing about the
      # compact view is worth losing the row that says "this file was written":
      # the diff under it is the receipt, and a row without a diff (a no-op
      # write, a file too large to draw) still has to be there to be found.
      MUTATING_OPS = %w[write append edit delete].freeze

      # When the model speaks, the work it asked for before that is done; a
      # thought between two calls means it decided to look again. So the
      # timeline of a turn runs text → call → thought → call → thought → text,
      # and the tail worth drawing starts at the round it is on — the thought
      # that led into the call, not the calls it already finished.
      #
      # `items` with the earlier log taken out. What survives from the log: the
      # text, the steering messages, the attachments, every diff together with
      # the row it was drawn under, and the calls that changed a file or failed.
      #
      # Inside the tail the timeline is read one row at a time, the way the turn
      # runs it: a pause gives way to the call it led into, and a call gives way
      # to the call after it, so a batch of four shows the fourth. Nothing is
      # lost that the reader has to come back for — an edit keeps its row and
      # its diff, a failure keeps the row that says it failed, and a call still
      # running from an earlier round is not hidden under a later one.
      def self.collapse(items)
        list = Array(items)
        tail = tail_start(list)
        return list if tail.nil?

        latest = list.rindex { |item| item[:kind] == :tool }

        list.each_with_index.filter_map do |item, index|
          next item if index < tail && survives?(list, index)
          next item if index >= tail && keeps_its_row?(list, index, latest)

          nil
        end
      end

      # A row of the tail that is drawn: everything but a call — the text, the
      # pause, the diff — plus the call the turn is on now, plus the calls that
      # have to stay findable whatever came after them.
      def self.keeps_its_row?(list, index, latest)
        item = list[index]
        return true unless item[:kind] == :tool
        return true if index == latest
        # The row that says what the turn did: the file it changed, the failure
        # it has to admit, the diff it drew. Replacing it with the call after it
        # would take the result away with the row, and the compact view would be
        # hiding the work rather than the log of it.
        return true if records_a_result?(item) || draws_a_diff?(list, index)
        # One row per batch: a call that another call of the same round already
        # answered for is the row before the row on screen.
        return false if superseded?(list, index, latest)
        # A call still running from an earlier round is work in flight that no
        # later row has answered for, so its row stays under the new one.
        item[:state] == :running
      end

      # Two calls of the same round are a batch the model asked for in one
      # breath: the newest one tells the reader what it is on, and the ones
      # before it are the same work half-told. A call from an earlier round is
      # not covered by that — the round's own passage leaves it behind (see
      # tail_start), and nothing here should hide it twice.
      #
      # A transcript written before the rows said which round they came from
      # goes by position: two calls with no sentence and no pause between them
      # were asked for in the same breath.
      def self.superseded?(list, index, latest)
        round = list[index][:round]
        return superseded_by_position?(list, index, latest) if round.nil?

        round == list[latest][:round]
      end

      def self.superseded_by_position?(list, index, latest)
        list[(index + 1)...latest].to_a.none? do |item|
          item[:kind] == :text || PAUSES.include?(item[:kind])
        end
      end

      # Where the tail begins: the round the turn is on, not the log behind it.
      #
      # A round opens either with what the model said or with a pause: the
      # thought that led into a call stands above that call, and a thought that
      # has not reached for anything yet stands alone. Everything is a boundary,
      # not just the pause, because a model does not always think between two
      # calls: it finishes one, answers, and calls again. Reading only the pause
      # left the tail on the round above that answer — the call before it stayed
      # on screen next to the call it is on now, which is exactly the log the
      # compact view is meant to drop.
      #
      # Nil when the turn made no call at all: there is nothing to collapse, and
      # the timeline is already the answer.
      def self.tail_start(list)
        rows = list.each_index.reject { |index| list[index][:kind] == :steer }
        kinds = rows.map { |index| list[index][:kind] }
        return nil unless kinds.include?(:tool)

        last_call = kinds.rindex(:tool)
        # Each row carries the round it belongs to (see Rubot::Web::Turn), so
        # the line is read off the row that is on screen rather than guessed
        # from what happens to sit next to it. That is what makes a short pause
        # — one that leaves no row of its own — and a call that came without
        # one leave the answer where it was.
        round = list[rows[last_call]][:round]
        return round_start(list, rows, kinds, last_call, round) unless round.nil?

        positional_tail_start(list, rows, kinds, last_call)
      end

      # The tail of a timeline whose rows say which round they belong to: the
      # first row of the round the last call was reached for, and everything it
      # opened with — the thought or the sentence above that call.
      def self.round_start(list, rows, kinds, last_call, round)
        last = kinds.size - 1
        # A pause below the last call is a round of its own: the thought is
        # what the turn is on, and the calls above it are finished work.
        if last > last_call && PAUSES.include?(kinds[last])
          index = rows[last]
          return index if list[index][:round].to_i > round
        end

        opening = rows.find { |index| list[index][:round] == round }
        return opening unless opening.nil?

        # The rows of that round are gone — a batch asked for before anything
        # was said. Keep the whole batch, or the reader cannot tell what ran.
        batch_start(rows, kinds, last_call)
      end

      # The same line, for a timeline that carries no round ids: the last
      # boundary (a sentence or a pause) above the last call. Replaying a
      # transcript written before the ids existed goes through here.
      def self.positional_tail_start(list, rows, kinds, last_call)
        # A thought with no call under it yet is a round of its own: the thought
        # is what the turn is on, and the calls above it are finished work.
        trailing = boundary_before(kinds, kinds.size)
        return rows[trailing] if trailing && trailing > last_call && PAUSES.include?(kinds[trailing])

        # Otherwise the round is the one that reached for the last call. A text
        # below it — the answer — is not a round that did anything, so the call
        # it belongs to stays above it: a row that vanished the moment the
        # answer started streaming is the flicker the reader was promised not
        # to see.
        opening = boundary_before(kinds, last_call)
        return rows[opening] if opening

        batch_start(rows, kinds, last_call)
      end

      # Nothing opened the round: the calls ran in the same breath.
      def self.batch_start(rows, kinds, last_call)
        first = last_call
        first -= 1 while first.positive? && kinds[first - 1] == :tool
        rows[first]
      end

      # The last row above `limit` that starts a round.
      def self.boundary_before(kinds, limit)
        (limit - 1).downto(0).find { |index| kinds[index] == :text || PAUSES.include?(kinds[index]) }
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
    end
  end
end
