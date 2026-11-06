# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # Modal dialog for dangerous tool actions. Blocks the worker thread on a
    # Queue until the user answers; y = allow, enter/esc/n = deny, and any
    # other key is swallowed so a stray ctrl-c cannot quit mid-confirmation.
    class ConfirmDialog < ::TUI::Layout::Box
      def initialize
        super(title: " ⚠️  confirm ", padding: 1, footer: " y allow · enter/esc deny ")
        @text = ::TUI::Label.new("", wrap: true)
        add(@text)
      end

      def show(tool_name, args)
        @text.text = describe(tool_name, args)
        self
      end

      def focusable?
        true
      end

      def handle_key(key)
        answer(key.name == "y" || key.name == "Y")
        true # swallow everything while the dialog is up
      end

      # REPL wires the answer hook each time the dialog is shown.
      def on_answer(&block)
        @on_answer = block
        self
      end

      private

      def describe(tool_name, args)
        case tool_name
        when "shell_exec"
          "dangerous shell command:\n#{args["command"].to_s[0, 400]}"
        when "file_ops"
          "#{args["operation"]} #{args["path"]}"
        else
          "#{tool_name} #{args.inspect[0, 400]}"
        end
      end

      def answer(value)
        handler = @on_answer
        handler&.call(value)
        self
      end
    end
  end
end
