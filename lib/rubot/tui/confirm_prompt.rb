# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The dangerous-action confirmation from the worker. It writes its
    # question straight into the transcript above the input — the same way
    # the /resume list does — instead of floating a modal over the screen,
    # so the description stays selectable/copyable with the mouse while it
    # is up.
    #
    # The two choices are chips: ←/→ move the highlight (it starts on
    # Reject), enter commits the highlighted choice, esc rejects. Other keys
    # are swallowed, except the mouse and scroll keys, which stay with the
    # log so drag-to-select (OSC 52 copy) keeps working.
    #
    # Once answered the whole exchange is taken back out of the transcript —
    # the tool rows that follow say what happened — and a single blank row
    # keeps the spacing the question occupied.
    class ConfirmPrompt
      INDENT = "  "

      # Index order matters for the rendering, not for safety: the highlight
      # starts on Reject (last option), so a blind enter never allows.
      OPTIONS = [
        { label: "✓ Allow", value: true },
        { label: "✗ Reject", value: false }
      ].freeze

      def initialize(log:)
        @log = log
        @on_answer = nil
        @pending = nil # { answered: }
        @rows = []
        @choice = OPTIONS.length - 1
        @choice_row = nil
        @hint = nil
        @spacer = nil
      end

      # REPL wires the answer hook once.
      def on_answer(&block)
        @on_answer = block
        self
      end

      def active?
        !@pending.nil?
      end

      # Publish the question into the log and take the keyboard. `answered`
      # is the Queue the worker blocks on; it is filled by #commit.
      def ask(tool_name, args, answered:)
        return false if active?

        @pending = { answered: answered }
        @choice = OPTIONS.length - 1
        @spacer = @log.add_entry([ [ "", nil ] ])
        describe(tool_name, args).each { |line| @rows << @log.add_entry([ [ INDENT, nil ] ] + line, keep_leading: true) }
        @choice_row = @log.add_entry(chips, keep_leading: true)
        @hint = @log.add_entry(
          [ [ INDENT, nil ], [ "←/→ choose · enter confirm · esc reject", :dim ] ],
          keep_leading: true
        )
        true
      end

      def handle_key(key)
        return false unless active?

        case key.name
        when :left then move(-1)
        when :right then move(1)
        when :enter then commit(OPTIONS[@choice][:value])
        when :escape then commit(false)
        # Selection and scrolling keep working while the question is up.
        when :mouse_press, :mouse_drag, :mouse_release, :wheel_up, :wheel_down,
             :page_up, :page_down
          return false
        end
        true # swallow everything else: an accidental key never answers
      end

      private

      def move(delta)
        @choice = (@choice + delta).clamp(0, OPTIONS.length - 1)
        @log.set_entry(@choice_row, chips, keep_leading: true)
        self
      end

      def chips
        segments = [ [ INDENT, nil ] ]
        OPTIONS.each_with_index do |option, i|
          segments << [ "   ", nil ] if i.positive?

          selected = i == @choice
          mark = selected ? "›" : " "
          segments << [ "#{mark} #{option[:label]} ", selected ? :selection : :muted ]
        end
        segments
      end

      def commit(value)
        answered = @pending[:answered]
        @pending = nil

        # Take the exchange back out: the rows that follow (tool result, the
        # next answer) are the record. One blank row keeps the spacing.
        removed = 1 + @rows.length + 2 # spacer, description, chips, hint
        removed.times { @log.remove_last }
        @log.add_entry([ [ "", nil ] ])

        @rows = []
        @choice_row = nil
        @hint = nil
        @spacer = nil
        @on_answer&.call(value)
      ensure
        answered << value if answered
      end

      # One segment-row per printed line, [text, style] pairs.
      def describe(tool_name, args)
        args = {} unless args.is_a?(Hash)
        lines = case tool_name.to_s
        when "shell_exec"
          [ "dangerous shell command:", args["command"].to_s[0, 400] ]
        when "file_ops"
          [ "#{args["operation"]} #{args["path"]}" ]
        else
          [ "#{tool_name} #{args.inspect[0, 400]}" ]
        end

        lines.compact.reject(&:empty?).each_with_index.map do |line, i|
          if i.zero?
            [ [ "⚠ ", :warning ], [ line, :text ] ]
          else
            [ [ line, :muted ] ]
          end
        end
      end
    end
  end
end
