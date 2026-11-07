# frozen_string_literal: true

require "time"
require "tui"

module Rubot
  class TUI
    # The session list opened by /resume. It writes its rows straight into the
    # transcript, right below the echoed command, instead of floating a modal:
    # the last prompt on the left, the message count and age pinned to the
    # right edge. ↑/↓ move the highlight, enter resumes the session, and esc
    # removes the list again.
    class SessionList
      ROWS = 10
      INDENT = "  "

      def self.age(iso, now: Time.now)
        time = Time.iso8601(iso.to_s)
        seconds = now - time

        return "just now" if seconds < 60
        return "#{seconds.floor / 60}m ago" if seconds < 3600
        return "#{seconds.floor / 3600}h ago" if seconds < 86_400
        return "#{seconds.floor / 86_400}d ago" if seconds < 604_800

        time.strftime("%Y-%m-%d")
      rescue ArgumentError, TypeError
        "unknown"
      end

      def self.count(total)
        "#{total} #{total == 1 ? "msg" : "msgs"}"
      end

      def initialize(log:, on_select: nil, on_cancel: nil)
        @log = log
        @on_select = on_select
        @on_cancel = on_cancel
        @entries = []
        @index = 0
        @top = 0
        @rows = []
        @hint = nil
        @trailer = nil
      end

      attr_reader :entries, :index

      def open(entries)
        reset
        @entries = Array(entries)
        return false if @entries.empty?

        # One blank row between the echoed /resume and the list, and one
        # after it, the same as any other command output.
        @spacer = @log.add_entry([ [ "", nil ] ])
        render
        @trailer = @log.add_entry([ [ "", nil ] ])
        true
      end

      def active?
        !@entries.empty?
      end

      def handle_key(key)
        case key.name
        when :up then move(-1)
        when :down then move(1)
        when :page_up then move(-ROWS)
        when :page_down then move(ROWS)
        when :home then jump(0)
        when :end then jump(@entries.length - 1)
        when :enter then commit
        when :escape, :ctrl_c then dismiss
        end
        true # swallow everything while the list is up
      end

      private

      def render
        top, count = window
        count.times do |i|
          segments = row(@entries[top + i], selected: (top + i) == @index)
          if @rows[i]
            @log.set_entry(@rows[i], segments, keep_leading: true)
          else
            @rows << @log.add_entry(segments, keep_leading: true)
          end
        end
        @hint ||= @log.add_entry([ [ "#{INDENT}↑/↓ choose · enter resume · esc cancel", :dim ] ],
                                 keep_leading: true)
      end

      # Keep the highlighted session inside the fixed-size window of rows.
      def window
        count = [ ROWS, @entries.length ].min
        @top = @index if @index < @top
        @top = @index - count + 1 if @index >= @top + count
        @top = [ @top, @entries.length - count ].min
        [ @top, count ]
      end

      def move(delta)
        return if @entries.empty?

        jump((@index + delta).clamp(0, @entries.length - 1))
      end

      def jump(index)
        return if index == @index

        @index = index
        render
      end

      def commit
        entry = @entries[@index]
        # Stop handling keys before the worker answers with the replay; the
        # log is cleared by it, so there is nothing to take back out here.
        @entries = []
        @rows = []
        @hint = nil
        @spacer = nil
        @trailer = nil
        @index = 0
        @top = 0
        @on_select&.call(entry) if entry
      end

      def dismiss
        reset
        leave_blank
        @on_cancel&.call
      end

      # One blank line below the command, so whatever comes next is set
      # apart from it.
      def leave_blank
        @log.add_entry([ [ "", nil ] ])
      end

      # Take the rows, the hint and the blanks back out of the transcript.
      def reset
        removed = @rows.length + (@hint ? 1 : 0) + (@spacer ? 1 : 0) + (@trailer ? 1 : 0)
        removed.times { @log.remove_last }
        @rows = []
        @hint = nil
        @spacer = nil
        @trailer = nil
        @entries = []
        @index = 0
        @top = 0
      end

      def row(entry, selected:)
        width = [ @log.content_width, 1 ].max
        width = 80 if width <= 1
        width -= INDENT.length

        indent = [ INDENT, selected ? :selection : :text ]
        right = "#{self.class.count(entry[:messages])} · #{self.class.age(entry[:updated_at])}"
        right_width = ::TUI::Text.width(right)

        if right_width >= width
          return [ indent, [ ::TUI::Text.truncate(right, width), selected ? :selection : :dim ] ]
        end

        left_width = width - right_width
        prompt = ::TUI::Text.truncate(entry[:last_prompt].to_s, [ left_width - 1, 0 ].max)
        left = ::TUI::Text.pad(prompt, left_width)

        [ indent, [ left, selected ? :selection : :text ], [ right, selected ? :selection : :dim ] ]
      end
    end
  end
end
