# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The prompt: a multiline editor (::TUI::MultiLine base gives shift+enter
    # newlines and a cursor row/col) with command-line history (up / down
    # while the buffer is a single line) and /command completion (tab cycles
    # the matches). All key sets are consumed here so they never bubble into
    # global bindings or focus movement.
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
      end

      def set_history(lines)
        @history = lines
        @history_limit = lines.length
        @hist_idx = nil
        self
      end

      def handle_key(key)
        case key.name
        when :up
          if multiline?
            buffer.up
          else
            history_prev
          end
          true
        when :down
          if multiline?
            buffer.down
          else
            history_next
          end
          true
        when :tab
          complete
          true
        else
          reset_completion
          super
        end
      end

      private

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
      end

      def reset_completion
        @matches = nil
        @match_idx = nil
      end
    end
  end
end
