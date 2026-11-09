# frozen_string_literal: true

require_relative "../tool"
require_relative "file_delivery"

module Rubot
  module Tools
    # Send several local files in one call.
    #
    # "Kirim 5 gambar di folder Pictures" is one instruction, and it used to cost
    # five rounds of the model: one call per picture, each waiting for the last.
    # This is the same delivery `send_file` does, once per path, reported as one
    # result — a batch the reader asked for arrives as a batch.
    #
    # A batch is not all-or-nothing: a missing or oversized file is reported and
    # the rest still go, because half of what was asked for beats none of it.
    class SendFiles < Tool
      include FileDelivery

      # Telegram's own ceiling for one album is ten; going past it here would
      # only mean a longer wait for the same result.
      MAX_FILES = 10

      attr_accessor :delivery_context
      attr_writer :safety_guard

      def initialize(safety_guard: nil)
        @safety_guard = safety_guard
        @delivery_context = nil
      end

      def name
        "send_files"
      end

      def description
        <<~DESC.strip
          Send several local files to the user in one call.
          Use this whenever the user asks for more than one file at once — e.g.
          "send the five pictures in Pictures" — rather than calling send_file
          once per file: one call sends the whole batch and the pictures arrive
          together instead of one after another. Images (.png, .jpg, .jpeg,
          .webp, .gif) are delivered as pictures so they display inline; other
          files are delivered as documents. Paths may be relative to the
          workspace or absolute. Up to #{MAX_FILES} files per call; a file that
          cannot be sent is reported and the rest still go.
        DESC
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "paths" => {
              "type" => "array",
              "items" => { "type" => "string" },
              "description" => "Paths of the files to send (relative to the workspace, or absolute)"
            },
            "caption" => {
              "type" => "string",
              "description" => "Optional caption shown with the first file"
            }
          },
          "required" => [ "paths" ]
        }
      end

      def execute(arguments)
        paths = requested_paths(arguments)
        return "ERROR: no path provided" if paths.empty?
        return "ERROR: too many files (#{paths.size}, limit #{MAX_FILES})" if paths.size > MAX_FILES

        context = @delivery_context
        return "ERROR: no delivery context — send_files only works inside a chat channel" unless context

        token = nil
        unless web?(context)
          token = ENV["TELEGRAM_BOT_TOKEN"].to_s
          return "ERROR: TELEGRAM_BOT_TOKEN is not set" if token.empty?
        end

        caption = arguments["caption"].to_s
        sent = []
        failures = []

        paths.each_with_index do |path, index|
          file = resolve(path)
          unless file.file?
            failures << "#{path}: file not found"
            next
          end

          size = file.size
          if size > MAX_BYTES
            failures << "#{path}: too large (#{size} bytes, limit #{MAX_BYTES})"
            next
          end

          @safety_guard&.check_path(file, operation: :read)

          if web?(context)
            stored = deliver_web(file, context)
            if stored.start_with?("ERROR")
              failures << "#{path}: #{stored.sub(/\AERROR: /, "")}"
            else
              sent << { name: file.basename, size: size, stored: stored }
            end
          else
            # The caption belongs to one message, so only the first file carries
            # it; repeating it would print it above every picture in the batch.
            result = upload(file, size, token, context, index.zero? ? caption : "")
            if result.start_with?("ERROR")
              failures << "#{path}: #{result.sub(/\AERROR: /, "")}"
            else
              sent << { name: file.basename, size: size }
            end
          end
        rescue SafetyGuard::SecurityError => e
          failures << "#{path}: #{e.message}"
        rescue Errno::ENOENT
          failures << "#{path}: file not found"
        rescue StandardError => e
          failures << "#{path}: #{e.class}: #{e.message}"
        end

        report(sent, failures)
      end

      private

      # `paths` is the shape this tool asks for, but a model that has just used
      # `send_file` sometimes answers with a single "path". Accepting both costs
      # nothing and saves a round trip.
      def requested_paths(arguments)
        list = arguments["paths"]
        list = [ arguments["path"] ] if list.nil? && arguments["path"]

        Array(list).map { |path| path.to_s.strip }.reject(&:empty?).uniq
      end

      def report(sent, failures)
        # Nothing got through: the channel and the reason still have to be said
        # the same way a single-file failure says them, and "ERROR" in front is
        # what tells the turn this call did not do its job.
        return "ERROR: #{failures.join("; ")}" if sent.empty?

        total = sent.sum { |entry| entry[:size] }
        noun = sent.size == 1 ? "file" : "files"
        summary = "Sent #{sent.size} #{noun} (#{total} bytes): #{sent.map { |e| e[:name] }.join(", ")}."
        summary += " Failed: #{failures.join("; ")}." unless failures.empty?
        return summary unless sent.first[:stored]

        # One marker per picture: the page reads every marker in the result,
        # which is how five pictures become one strip under the row rather than
        # a batch the reader has to open one by one.
        markers = sent.map { |entry| "[#{WEB_MARKER} #{entry[:stored]}]" }.join(" ")
        pictures = "Sent #{sent.size} #{noun} as pictures (png, jpg, gif, webp). #{markers}"
        pictures += " Failed: #{failures.join("; ")}." unless failures.empty?
        pictures
      end
    end
  end
end
