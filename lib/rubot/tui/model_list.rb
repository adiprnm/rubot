# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The model picker opened by /models. It lists the models the provider
    # supports and writes its rows straight into the transcript, right below
    # the echoed command. ↑/↓ move the highlight, enter switches the active
    # session to the highlighted model, and esc takes the list back off the
    # screen.
    #
    # Typing searches the list: every keystroke narrows it to the models
    # whose id or name contains what has been typed so far, backspace undoes
    # a character, and esc clears the search before it closes the list.
    class ModelList
      ROWS = 12
      INDENT = "  "
      ACTIVE_MARK = "✓"
      IDLE_MARK = " "

      def initialize(log:, on_select: nil, on_cancel: nil)
        @log = log
        @on_select = on_select
        @on_cancel = on_cancel
        @all = []
        @entries = []
        @filter = ""
        @index = 0
        @top = 0
        @rows = []
        @hint = nil
        @header = nil
        @search = nil
        @top_blank = nil
        @gap = []
        @trailer = nil
        @title = nil
      end

      attr_reader :entries, :index, :filter

      # Opens the picker. `entries` are hashes with an "id" (the id passed to
      # the provider), a "label" (a friendlier name) and an "active" flag.
      # `filter` is the search the list starts with.
      #
      # The layout in the transcript:
      #
      #   (blank)
      #     Models supported by openai (4)
      #   (blank)
      #     search: (type to filter)
      #   (blank)
      #     ✓ model-a   Model A
      #       model-b   Model B
      #   (blank)
      #     ↑/↓ choose · enter select · esc cancel
      #   (blank)
      def open(entries, title: nil, filter: nil)
        reset
        @title = title
        @all = Array(entries)
        @filter = filter.to_s.strip
        apply_filter
        return false if @entries.empty?

        @top_blank = @log.add_entry([ [ "", nil ] ])
        @header = @log.add_entry([ [ header_text, :muted ] ], indent: 2)
        @gap << @log.add_entry([ [ "", nil ] ])
        @search = @log.add_entry([ [ search_text, :dim ] ], keep_leading: true)
        @gap << @log.add_entry([ [ "", nil ] ])
        render
        @gap << @log.add_entry([ [ "", nil ] ])
        @hint = @log.add_entry([ [ hint_text, :dim ] ], keep_leading: true)
        @trailer = @log.add_entry([ [ "", nil ] ])
        true
      end

      def active?
        !@entries.empty?
      end

      # Does the entry match the search text? An empty search matches
      # everything.
      def self.matches?(entry, query)
        text = query.to_s.strip.downcase
        return true if text.empty?

        entry[:id].to_s.downcase.include?(text) || entry[:label].to_s.downcase.include?(text)
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
        when :backspace then search_backspace
        when :escape, :ctrl_c then dismiss
        else
          return false unless key.printable?

          search_add(key.char)
        end
        true # swallow everything while the list is up
      end

      private

      def apply_filter
        @entries = @all.select { |entry| self.class.matches?(entry, @filter) }
        @index = 0
        @top = 0
      end

      # A keystroke changed the search: keep the header, the search row and
      # the blank rows, and rebuild the model rows.
      def refresh
        apply_filter
        @log.set_entry(@search, [ [ search_text, :dim ] ], keep_leading: true) if @search
        @log.set_entry(@header, [ [ header_text, :muted ] ]) if @header
        rerender
      end

      def search_add(char)
        text = char.to_s
        return if text.empty?

        @filter += text
        refresh
      end

      def search_backspace
        return if @filter.empty?

        @filter = @filter[0..-2].to_s
        refresh
      end

      # The model rows, the gap below them, the hint and the trailer are the
      # last entries of the log, so they are taken off and written again.
      def rerender
        count = @rows.length + (@gap.last ? 1 : 0) + (@hint ? 1 : 0) + (@trailer ? 1 : 0)
        count.times { @log.remove_last }
        @rows = []
        @gap.pop
        @hint = nil
        @trailer = nil

        render
        @gap << @log.add_entry([ [ "", nil ] ])
        @hint = @log.add_entry([ [ hint_text, :dim ] ], keep_leading: true)
        @trailer = @log.add_entry([ [ "", nil ] ])
      end

      def render
        if @entries.empty?
          segments = [ [ INDENT, :text ], [ "no model matches", :dim ] ]
          @rows << @log.add_entry(segments, keep_leading: true)
          return
        end

        top, count = window
        count.times do |i|
          segments = row(@entries[top + i], selected: (top + i) == @index)
          if @rows[i]
            @log.set_entry(@rows[i], segments, keep_leading: true)
          else
            @rows << @log.add_entry(segments, keep_leading: true)
          end
        end
      end

      # Keep the highlighted model inside the fixed-size window of rows.
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

      # The rows are taken back out of the transcript: the switch is
      # reported by the command that follows.
      def commit
        entry = @entries[@index]
        reset
        leave_blank
        @on_select&.call(entry) if entry
      end

      # Esc clears the search first; once it is empty, it closes the list.
      def dismiss
        if @filter.empty?
          reset
          leave_blank
          @on_cancel&.call
          return
        end

        @filter = ""
        refresh
      end

      # One blank line below the command, so whatever comes next is set
      # apart from it.
      def leave_blank
        @log.add_entry([ [ "", nil ] ])
      end

      # Take the rows, the hint and the blanks back out of the transcript.
      def reset
        removed = @rows.length + @gap.length + (@hint ? 1 : 0) + (@trailer ? 1 : 0) +
                  (@search ? 1 : 0) + (@header ? 1 : 0) + (@top_blank ? 1 : 0)
        removed.times { @log.remove_last }
        @rows = []
        @gap = []
        @hint = nil
        @header = nil
        @search = nil
        @top_blank = nil
        @trailer = nil
        @all = []
        @entries = []
        @filter = ""
        @index = 0
        @top = 0
        @title = nil
      end

      def header_text
        title = @title.to_s
        title = "Models" if title.empty?

        if @filter.empty?
          "#{title} (#{@all.length})"
        else
          "#{title} (#{@entries.length}/#{@all.length})"
        end
      end

      def search_text
        text = @filter.empty? ? "(type to filter)" : @filter
        "#{INDENT}search: #{text}"
      end

      def hint_text
        if @filter.empty?
          "#{INDENT}↑/↓ choose · enter select · esc cancel"
        else
          "#{INDENT}↑/↓ choose · enter select · esc clear"
        end
      end

      def row(entry, selected:)
        width = [ @log.content_width, 1 ].max
        width = 80 if width <= 1
        width -= INDENT.length

        style = selected ? :selection : :text
        mark = entry[:active] ? "#{ACTIVE_MARK} " : "#{IDLE_MARK} "

        label = entry[:label].to_s
        label = "" if label == entry[:id].to_s
        right_width = label.empty? ? 0 : ::TUI::Text.width(label) + 1
        left_width = [ width - right_width, 1 ].max

        left = ::TUI::Text.truncate("#{mark}#{entry[:id]}", left_width)
        left = ::TUI::Text.pad(left, left_width)

        segments = [ [ INDENT, selected ? :selection : :text ], [ left, style ] ]
        segments << [ label, selected ? :selection : :dim ] unless label.empty?
        segments
      end
    end
  end
end
