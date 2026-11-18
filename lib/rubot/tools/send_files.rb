# frozen_string_literal: true

require "json"

require_relative "../tool"
require_relative "file_delivery"

module Rubot
  module Tools
    # Send local files to the chat that asked for them, one call for any number
    # of paths.
    #
    # "Kirim 5 gambar di folder Pictures" is one instruction, and it used to cost
    # five rounds of the model: one call per picture, each waiting for the last.
    # One call now delivers the whole batch, and a single file is a batch of one.
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
          Send local files to the user in one call.
          Use this for any number of files: pass one path for a single file, or
          every path at once for a batch — e.g. "send the five pictures in
          Pictures" — so the pictures arrive together instead of one after
          another. Images (.png, .jpg, .jpeg,
          .webp, .gif) are delivered as pictures so they display inline; videos
          (.mp4, .webm, .mov) play inline too. A PDF or a markdown note (.md)
          arrives as a document the reader can open.
          Paths may be relative to the workspace or absolute. Up to #{MAX_FILES}
          files per call; a file that cannot be sent is reported and the rest
          still go.
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

      # `paths` is the shape this tool asks for, but models get it wrong in two
      # predictable ways, and both cost a round trip that the batch was meant to
      # save:
      #
      # * a single "path" key for one file;
      # * an array serialised back into a string — `"[\"/a.png\", \"/b.png\"]"`
      #   — which Array() wraps as one path, and every path is then "not found".
      #     Seen in the wild with ten paths in one call.
      #
      # A string that parses as a JSON array is taken at its word; anything else
      # stays a single path, because a file name may contain brackets.
      def requested_paths(arguments)
        list = arguments["paths"]
        list = [ arguments["path"] ] if list.nil? && arguments["path"]
        list = unwrap_json_array(list)

        Array(list).map { |path| path.to_s.strip }.reject(&:empty?).uniq
      end

      def unwrap_json_array(value)
        return value unless value.is_a?(String)

        text = value.strip
        return value unless text.start_with?("[")

        parsed = JSON.parse(text)
        parsed.is_a?(Array) ? parsed : value
      rescue JSON::ParserError
        value
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

        # One marker per file: the page reads every marker in the result,
        # which is how five pictures become one strip under the row rather than
        # a batch the reader has to open one by one. A batch may mix them — a
        # PDF report beside the screenshots it quotes — so the wording is the
        # one that is true of both.
        markers = sent.map { |entry| "[#{WEB_MARKER} #{entry[:stored]}]" }.join(" ")
        attachments = "Sent #{sent.size} #{noun} as attachments " \
                      "(#{WEB_EXTENSIONS.map { |ext| ext.delete_prefix(".") }.join(", ")}). #{markers}"
        attachments += " Failed: #{failures.join("; ")}." unless failures.empty?
        attachments
      end
    end
  end
end
