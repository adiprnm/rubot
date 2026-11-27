# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # The turn's ask, in the terminal: a dangerous-action confirmation, or a
    # question the model put to the reader.
    #
    # It writes the question straight into the transcript above the input — the
    # same way the /resume list does — instead of floating a modal over the
    # screen, so the text stays selectable/copyable with the mouse while it is
    # up.
    #
    # The choices are chips: ←/→ move the highlight, enter commits the
    # highlighted one, esc rejects a confirmation. Other keys are swallowed,
    # except the mouse and scroll keys, which stay with the log so
    # drag-to-select (OSC 52 copy) keeps working.
    #
    # A question's last chip is "Other": committing it hands the keyboard back
    # to the normal prompt and the next line typed is the answer. An inline
    # editor here would be a second input box inside a prompt that already is
    # one.
    #
    # Once answered the whole exchange is taken back out of the transcript —
    # the rows that follow say what happened — and a single blank row keeps the
    # spacing the question occupied.
    class ConfirmPrompt
      INDENT = "  "

      # Index order matters for the rendering, not for safety: the highlight
      # starts on Reject (last option), so a blind enter never allows.
      CONFIRM_OPTIONS = [
        { label: "✓ Allow", value: true },
        { label: "✗ Reject", value: false }
      ].freeze

      # The free-text choice, always last, on every question.
      OTHER = { label: "✎ Other", value: :custom }.freeze

      def initialize(log:)
        @log = log
        @on_answer = nil
        @pending = nil # { answered: }
        @rows = []
        @options = CONFIRM_OPTIONS
        @kind = :confirm
        @choice = CONFIRM_OPTIONS.length - 1
        @choice_row = nil
        @hint = nil
        @spacer = nil
        @awaiting = nil
      end

      # REPL wires the answer hook once.
      def on_answer(&block)
        @on_answer = block
        self
      end

      def active?
        !@pending.nil?
      end

      # True while a question is waiting for the line the reader types instead
      # of picking a chip.
      def awaiting_text?
        !@awaiting.nil?
      end

      # Publish the question into the log and take the keyboard. `answered` is
      # the Queue the worker blocks on; it is filled by #commit.
      def ask(tool_name, args, answered:, reason: nil)
        return false if active?

        open(CONFIRM_OPTIONS, answered, start: CONFIRM_OPTIONS.length - 1) do
          describe(tool_name, args, reason).each do |line|
            @rows << @log.add_entry([ [ INDENT, nil ] ] + line, keep_leading: true)
          end
        end
        true
      end

      # A question from the ask_user tool. Its own rows, the same chips, and the
      # same wait: whatever this returns travels back as the call's result.
      def ask_question(payload, answered:)
        return false if active?

        payload = {} unless payload.is_a?(Hash)
        options = Array(payload[:options])
        chips = options.map { |option| { label: option[:label].to_s, value: { outcome: :option, label: option[:label].to_s } } }
        # The confirmation that closes a list offers two answers and no free
        # text: a sentence typed there would have nowhere to go.
        chips << OTHER unless payload[:confirm]

        open(chips, answered, start: 0, kind: :question) do
          question_rows(payload).each do |line|
            @rows << @log.add_entry([ [ INDENT, nil ] ] + line, keep_leading: true)
          end
          # The consequence of each choice, one row per option, so the chips
          # below stay short enough to read at a glance.
          options.each_with_index do |option, index|
            next unless option[:description]

            @rows << @log.add_entry(
              [ [ INDENT, nil ], [ "#{index + 1}. ", :muted ], [ option[:description].to_s, :muted ] ],
              keep_leading: true
            )
          end
        end
        true
      end

      # The next line typed after "Other" was committed. Hands it to the worker
      # that is still waiting on the same answer.
      def deliver_text(text)
        queue = @awaiting
        @awaiting = nil
        return false if queue.nil?

        queue << { outcome: :custom, text: text.to_s.strip }
        true
      end

      def handle_key(key)
        return false unless active?

        case key.name
        when :left then move(-1)
        when :right then move(1)
        when :enter then commit(@options[@choice][:value])
        # A confirmation escapes to "no". A question has no safe default to
        # escape to, so escaping it does nothing: the deadline is what ends an
        # unanswered question, not a stray key.
        when :escape then return true if @kind == :question

                          commit(false)
        # Selection and scrolling keep working while the question is up.
        when :mouse_press, :mouse_drag, :mouse_release, :wheel_up, :wheel_down,
             :page_up, :page_down
          return false
        end
        true # swallow everything else: an accidental key never answers
      end

      private

      # `build` draws the rows above the chips, so the two kinds of ask share
      # everything else: the spacer, the chips, the hint, and how it all comes
      # back out again.
      def open(options, answered, start: 0, kind: :confirm)
        @pending = { answered: answered }
        @options = options
        @kind = kind
        # The confirmation starts on Reject so a blind enter never allows; a
        # question starts on its first suggestion, which is the best one.
        @choice = start
        @spacer = @log.add_entry([ [ "", nil ] ])
        @rows = []
        yield
        @choice_row = @log.add_entry(chips, keep_leading: true)
        @hint = @log.add_entry(
          [ [ INDENT, nil ], [ hint_text, :dim ] ],
          keep_leading: true
        )
      end

      def hint_text
        base = "←/→ choose · enter confirm"
        return "#{base} · esc leaves it unanswered" if @kind == :question

        "#{base} · esc reject"
      end

      def question_rows(payload)
        question = payload[:question].to_s
        # One row per line: the confirmation that closes a list reads the
        # answers back one per line, and a row is a line here.
        rows = question.split("\n").map do |line|
          line = line.strip
          line.empty? ? [ [ "", nil ] ] : [ [ "? ", :accent ], [ line, :text ] ]
        end
        if Array(payload[:options]).empty?
          rows << [ [ "Type your answer below, then enter.", :muted ] ]
        end
        rows
      end

      def move(delta)
        @choice = (@choice + delta).clamp(0, @options.length - 1)
        @log.set_entry(@choice_row, chips, keep_leading: true)
        self
      end

      def chips
        segments = [ [ INDENT, nil ] ]
        @options.each_with_index do |option, i|
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

        # "Other" needs the reader's own line, and that line arrives through the
        # prompt: the answer stays owed until #deliver_text fills it.
        if value == :custom
          @awaiting = answered
        else
          answered << value if answered
        end
      end

      # One segment-row per printed line, [text, style] pairs. `reason` is the
      # tool's own account of what would be lost ("overwrite x — 412 of 900
      # lines would be lost", "deletes files"); when the tool has none, the
      # arguments have to do the talking.
      def describe(tool_name, args, reason = nil)
        args = {} unless args.is_a?(Hash)
        lines = if reason && !reason.to_s.strip.empty?
          [ reason.to_s ]
        else
          case tool_name.to_s
          when "shell_exec"
            [ "dangerous shell command:", args["command"].to_s[0, 400] ]
          when "file_ops"
            [ "#{args["operation"]} #{args["path"]}" ]
          else
            [ "#{tool_name} #{args.inspect[0, 400]}" ]
          end
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
