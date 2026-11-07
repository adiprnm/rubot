# frozen_string_literal: true

require "tui"

require_relative "file_index"

module Rubot
  class TUI
    # The prompt: a multiline editor (::TUI::MultiLine base gives shift+enter
    # newlines and a cursor row/col) with command-line history (up / down
    # while the buffer is a single line), /command completion (tab cycles
    # the matches), the slash-command palette (typing "/" lists the
    # commands, ↑/↓ move the highlight and enter runs the highlighted one
    # right away) and the file palette (typing "@" lists the files under the
    # working directory, ↑/↓ move the highlight and enter drops the path in
    # the buffer instead of submitting). All key sets are consumed here so
    # they never bubble into global bindings or focus movement.
    class PromptInput < ::TUI::MultiLine
      # An @token at the cursor: where its "@" sits and what was typed after
      # it. Nil while the caret is not inside a mention.
      Mention = Struct.new(:start, :token)

      COMMAND = :command
      FILE = :file

      # An inline session list opened by /resume. While it is set it owns the
      # keyboard, so the prompt neither edits nor submits until it is done.
      attr_accessor :list

      def initialize(history, commands, files: nil)
        super(max_rows: 6)
        @history = history
        @history_limit = history.length
        @hist_idx = nil
        @draft = nil
        @commands = commands
        @files = files || FileIndex.new
        @matches = nil
        @match_idx = nil

        @menu_items = []
        @menu_index = 0
        @menu_mode = COMMAND
        @mention = nil
        @command_items = []
        # The file tree is walked once per palette session, not per keystroke.
        @files_stale = true
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

      # :command or :file — which palette the keys are driving.
      def menu_mode
        @menu_mode
      end

      def handle_key(key)
        return @list.handle_key(key) if @list

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
          # A mention is text, not a command: enter completes the path and
          # the message waits for a second enter.
          return pick_mention if file_menu?

          pick_menu if menu_open?
          super
          true
        when :escape
          return false unless menu_open?

          close_menu
          true
        when :tab
          file_menu? ? pick_mention : complete
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

      # Enter in the palette: run the highlighted command right away. The
      # buffer is set to it just long enough for the submit that follows, so
      # the command never needs a second Enter.
      def pick_menu
        buffer.set(@menu_items[@menu_index])
        close_menu
        emit(::TUI::Events::CHANGE, value)
      end

      def move_menu(delta)
        count = @menu_items.length
        return if count.zero?

        @menu_index = (@menu_index + delta) % count
        emit_menu
      end

      # Commands are offered only for a bare prefix, files only while the
      # caret sits in an @token. Either way the palette shows one source at a
      # time and closes as soon as nothing matches.
      def refresh_menu
        return close_menu if @menu_suppressed

        mode, mention = menu_source
        items = mode == FILE ? files_for(mention) : @command_items
        return close_menu if items.empty?

        if items != @menu_items || mode != @menu_mode
          @menu_items = items
          @menu_index = 0
        else
          @menu_index = @menu_index.clamp(0, items.length - 1)
        end
        @menu_mode = mode
        @mention = mention
        emit_menu
      end

      def menu_source
        text = value
        if text.start_with?("/") && !text.match?(/\s/)
          @command_items = @commands.grep(/\A#{Regexp.escape(text)}/)
          return [ COMMAND, nil ]
        end

        @command_items = []
        mention = current_mention
        return [ COMMAND, nil ] unless mention

        [ FILE, mention ]
      end

      def files_for(mention)
        @files.refresh if @files_stale
        @files_stale = false
        @files.matches(mention.token)
      end

      # An @token counts only at the start of a line or after a space, so an
      # email address typed into a message never opens the palette.
      def current_mention
        head = buffer.current_line.to_s[0, buffer.col].to_s
        match = head.match(/(?:\A|\s)@(\S*)\z/)
        return nil unless match

        Mention.new(match.begin(0) + match[0].index("@"), match[1])
      end

      # Drop the highlighted path in place of what was typed after the "@".
      # A directory leaves the mention open so the next keystroke filters
      # inside it; a file ends the mention with a space.
      def pick_mention
        return false unless file_menu?

        path = @menu_items[@menu_index].to_s
        start = @mention ? @mention.start : buffer.col
        (buffer.col - start).times { buffer.backspace }
        buffer.insert("@#{path}#{path.end_with?('/') ? '' : ' '}")

        @menu_suppressed = false
        emit(::TUI::Events::CHANGE, value)
        refresh_menu
        true
      end

      def close_menu
        @files_stale = true
        return if @menu_items.empty?

        @menu_items = []
        @menu_index = 0
        @menu_mode = COMMAND
        @mention = nil
        emit_menu
      end

      def file_menu?
        @menu_mode == FILE && !@menu_items.empty?
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
