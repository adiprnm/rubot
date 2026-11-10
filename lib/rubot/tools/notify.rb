# frozen_string_literal: true

require_relative "../tool"

module Rubot
  module Tools
    # "Tell me when you are done."
    #
    # The tool carries the request; the channel is what can actually reach a
    # device, and it says so when the turn ends — before then there is nothing
    # to report. That split is deliberate: a tool that sent the push itself
    # would announce work that is still running, and it would have to reach
    # across the session's isolation to do it.
    #
    # In a channel with nowhere to send (the terminal, Telegram), the answer
    # simply arrives where the reader is looking, which is what was promised.
    class Notify < Tool
      def name
        "notify"
      end

      def description
        <<~DESC.strip
          Ask for the end of this turn to be announced on the user's devices.

          Use it when the user says "tell me when you are done", "kabari kalau
          sudah kelar", or asks to be notified about long work. The
          notification arrives when the turn finishes and opens this
          conversation; it never interrupts the turn or stops the work.

          Pass `message` to choose what the notification says — the result in
          one line. Without it, the opening of your answer travels instead.
        DESC
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "message" => {
              "type" => "string",
              "description" => "One line for the notification, e.g. \"Migrasi selesai, 5 test lulus\""
            }
          },
          "required" => []
        }
      end

      def execute(arguments)
        message = arguments["message"].to_s.strip
        return "Noted — the end of this turn will be announced." if message.empty?

        "Noted — the announcement will say: #{message}"
      end
    end
  end
end
