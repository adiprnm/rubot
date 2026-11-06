# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The prompt: a multiline editor (::TUI::MultiLine base gives shift+enter
    # newlines and a cursor row/col) with command-line history (up / down
    # while the buffer is a single line), /command completion (tab cycles
    # the matches) and the slash-command palette (typing "/" lists the
    # commands, ↑/↓ move the highlight and enter takes the highlighted one
    # into the buffer). All key sets are consumed here so they never bubble
    # into global bindings or focus movement.
    class PromptInput < ::TUI::MultiLine
      def initialize(history, commands)
        super(max_rows: 6)
        @history = history
        @history_limit = history.length
        @hist_idx = nil
        @draft = nil
        @commands = commands
        @matches = nil
        @match_idx = nil

        @menu_items = []
        @menu_index = 0
        # Set after the palette drops a command into the buffer, so the
        # completion does not immediately pop the list back up. The next
        # edit clears it.
        @menu_suppressed = false
      end

      def set_history(lines)
        @history = lines
        @history_limit = lines.length
        @hist_idx = nil
        self
      end

      def value=(text)
        super
        @menu_suppressed = false
        refresh_menu
        self
      end

      def menu_open?
        !@menu_items.empty?
      end

      def menu_items
        @menu_items
      end

      def menu_index
        @menu_index
      end

      def handle_key(key)
        case key.name
        when :up
          if menu_open?
            move_menu(-1)
          elsif multiline?
            buffer.up
          else
            history_prev
          end
          true
        when :down
          if menu_open?
            move_menu(1)
          elsif multiline?
            buffer.down
          else
            history_next
          end
          true
        when :enter
          if menu_open?
            super if menu_enter == :submit
          else
            super
          end
          true
        when :escape
          return false unless menu_open?

          close_menu
          true
        when :tab
          complete
          true
        else
          reset_completion
          before = value
          handled = super
          # Only a real edit re-opens the palette; moving the cursor inside
          # an already accepted command leaves the list dismissed.
          if value != before
            @menu_suppressed = false
            refresh_menu
          end
          handled
        end
      end

      private

      # Enter in the palette: put the highlighted command in the box. When
      # the box already holds exactly that command, Enter runs it instead,
      # so a fully typed command is never swallowed by the highlight.
      def menu_enter
        current = @menu_items[@menu_index]
        if current == value
          close_menu
          :submit
        else
          buffer.set(current)
          @menu_suppressed = true
          close_menu
          emit(::TUI::Events::CHANGE, value)
          :accept
        end
      end

      def move_menu(delta)
        count = @menu_items.length
        return if count.zero?

        @menu_index = (@menu_index + delta) % count
        emit_menu
      end

      # Commands are offered only for a bare prefix: once the buffer has a
      # space or a second line, the user is typing an argument.
      def refresh_menu
        return close_menu if @menu_suppressed

        text = value
        unless text.start_with?("/") && !text.match?(/\s/)
          close_menu
          return
        end

        items = @commands.grep(/\A#{Regexp.escape(text)}/)
        if items.empty?
          close_menu
        else
          if items != @menu_items
            @menu_items = items
            @menu_index = 0
          else
            @menu_index = @menu_index.clamp(0, items.length - 1)
          end
          emit_menu
        end
      end

      def close_menu
        return if @menu_items.empty?

        @menu_items = []
        @menu_index = 0
        emit_menu
      end

      def emit_menu
        emit(:menu, @menu_items, @menu_index)
      end

      def multiline?
        buffer.lines.size > 1
      end

      def history_prev
        return if @history.empty?

        @draft = value if @hist_idx.nil?
        @hist_idx = @hist_idx.nil? ? @history.length - 1 : [ @hist_idx - 1, 0 ].max
        buffer.set(@history[@hist_idx])
      end

      def history_next
        return if @hist_idx.nil?

        if @hist_idx >= @history.length - 1
          @hist_idx = nil
          buffer.set(@draft.to_s)
          @draft = nil
        else
          @hist_idx += 1
          buffer.set(@history[@hist_idx].to_s)
        end
      end

      def complete
        current = value
        matches = @commands.grep(/\A#{Regexp.escape(current)}/) unless current.empty?
        return if !matches || matches.empty?

        if @matches != matches
          @matches = matches
          @match_idx = 0
        else
          @match_idx = (@match_idx + 1) % matches.length
        end
        buffer.set(matches[@match_idx])
        # Tab already cycled the matches, so the list has done its job.
        @menu_suppressed = true
        close_menu
        emit(::TUI::Events::CHANGE, value)
      end

      def reset_completion
        @matches = nil
        @match_idx = nil
      end
    end
  end
end
