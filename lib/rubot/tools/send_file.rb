# frozen_string_literal: true

require_relative "../tool"
require_relative "file_delivery"

module Rubot
  module Tools
    # Send a local file to the chat that asked for it.
    #
    # Where the bytes go and what the result says is `FileDelivery`'s business;
    # this tool is the one-path face of it. `send_files` is the same delivery
    # for several paths at once.
    #
    # This is what lets the agent hand back artifacts it produced — e.g. the
    # PNG written by the adipurnm-brand featured-image generator — instead of
    # only printing a path the user has to fetch manually.
    class SendFile < Tool
      include FileDelivery

      attr_accessor :delivery_context
      attr_writer :safety_guard

      def initialize(safety_guard: nil)
        @safety_guard = safety_guard
        @delivery_context = nil
      end

      def name
        "send_file"
      end

      def description
        <<~DESC.strip
          Send one local file to the user.
          Use this when the user should receive a file you produced, such as a
          generated featured image (PNG). Images (.png, .jpg, .jpeg, .webp, .gif)
          are delivered as pictures so they display inline; other files are
          delivered as documents. The path may be relative to the workspace or
          absolute.

          If the user asked for several files — "send the five pictures in
          Pictures" — use send_files once instead of calling this repeatedly:
          one call sends the batch and the pictures arrive together.
        DESC
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "path" => {
              "type" => "string",
              "description" => "Path to the file to send (relative to the workspace, or absolute)"
            },
            "caption" => {
              "type" => "string",
              "description" => "Optional caption shown with the file"
            }
          },
          "required" => [ "path" ]
        }
      end

      def execute(arguments)
        path = arguments["path"].to_s.strip
        return "ERROR: no path provided" if path.empty?

        context = @delivery_context
        return "ERROR: no delivery context — send_file only works inside a chat channel" unless context

        web = web?(context)
        # The report order matters to whoever is reading it: a Telegram that
        # cannot send at all is the first thing to say, before a path is
        # discussed.
        token = nil
        unless web
          token = ENV["TELEGRAM_BOT_TOKEN"].to_s
          return "ERROR: TELEGRAM_BOT_TOKEN is not set" if token.empty?
        end

        file = resolve(path)
        return "ERROR: file not found: #{path}" unless file.file?

        size = file.size
        return "ERROR: file is too large to send (#{size} bytes, limit #{MAX_BYTES})" if size > MAX_BYTES

        @safety_guard&.check_path(file, operation: :read)

        if web
          stored = deliver_web(file, context)
          return stored if stored.start_with?("ERROR")

          return "Sent #{file.basename} (#{size} bytes) as a picture. [#{WEB_MARKER} #{stored}]"
        end

        upload(file, size, token, context, arguments["caption"].to_s)
      rescue Errno::ENOENT
        "ERROR: file not found: #{arguments["path"]}"
      rescue SafetyGuard::SecurityError => e
        "ERROR: #{e.message}"
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end
    end
  end
end
