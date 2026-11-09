# frozen_string_literal: true

require "json"
require "net/http"
require "pathname"
require "securerandom"
require "fileutils"
require_relative "../tool"

module Rubot
  module Tools
    # Send a local file to the chat that asked for it.
    #
    # The channel sets `delivery_context` before each request, the same way the
    # cron tool receives its delivery target. Two channels deliver differently:
    #
    # * Telegram ({ chat_id:, thread_id: }) uploads with sendPhoto so pictures
    #   render inline; everything else goes through sendDocument.
    # * The web page ({ channel: "web", dir: ... }) has no upload endpoint: the
    #   file is copied into the conversation's own attachment folder, which the
    #   page already serves, and the result carries the stored name so the
    #   browser can draw it.
    #
    # This is what lets the agent hand back artifacts it produced — e.g. the
    # PNG written by the adipurnm-brand featured-image generator — instead of
    # only printing a path the user has to fetch manually.
    class SendFile < Tool
      MAX_BYTES = 50 * 1024 * 1024 # Telegram bot upload limit
      PHOTO_EXTENSIONS = %w[.png .jpg .jpeg .webp].freeze
      # The token the web channel reads back out of a tool result. It is how a
      # conversation drawn from disk a week later still knows which stored file
      # this call produced.
      WEB_MARKER = "web-attachment"
      WEB_MARKER_RE = /\[#{WEB_MARKER} ([^\]]+)\]/.freeze
      # What the web page can draw. Anything else is refused rather than stored
      # where nothing would ever show it.
      WEB_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp].freeze

      MIME_TYPES = {
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".webp" => "image/webp",
        ".gif" => "image/gif",
        ".pdf" => "application/pdf",
        ".json" => "application/json",
        ".txt" => "text/plain",
        ".md" => "text/markdown"
      }.freeze

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
          Send a local file to the user.
          Use this when the user should receive a file you produced, such as a
          generated featured image (PNG). Images (.png, .jpg, .jpeg, .webp, .gif)
          are delivered as pictures so they display inline; other files are
          delivered as documents. The path may be relative to the workspace or
          absolute.
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

        return deliver_web(file, size, context) if web

        upload(file, size, token, context, arguments["caption"].to_s)
      rescue Errno::ENOENT
        "ERROR: file not found: #{arguments["path"]}"
      rescue SafetyGuard::SecurityError => e
        "ERROR: #{e.message}"
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end

      private

      def web?(context)
        context[:channel].to_s == "web"
      end

      # The web page has no upload endpoint to hand bytes to. What it does have
      # is a folder it already serves for this one conversation, so the picture
      # is copied there under a name the page can trust and the result says
      # which name — that marker is the whole reason a refreshed page can draw
      # the picture again.
      def deliver_web(file, size, context)
        dir = context[:dir].to_s
        return "ERROR: this conversation has no attachment folder" if dir.empty?

        extension = file.extname.downcase
        return "ERROR: the web page can only send pictures (png, jpg, gif, webp)" unless WEB_EXTENSIONS.include?(extension)

        FileUtils.mkdir_p(dir)
        name = web_name(file)
        File.binwrite(File.join(dir, name), file.binread)

        "Sent #{file.basename} (#{size} bytes) as a picture. [#{WEB_MARKER} #{name}]"
      end

      # An id this process generated, the reader's own file name reduced to a
      # slug, and the extension: a download still reads like a file, while a
      # hand-typed path cannot name one.
      def web_name(file)
        extension = file.extname.downcase
        extension = ".jpg" if extension == ".jpeg"
        base = File.basename(file.basename, file.extname)
                   .downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, 60].to_s
        "#{SecureRandom.hex(16)}#{base.empty? ? "" : "-#{base}"}#{extension}"
      end

      def resolve(path)
        candidate = Pathname.new(path)
        unless candidate.absolute?
          base = @safety_guard&.workspace || Pathname.new(Dir.pwd)
          candidate = Pathname.new(base).join(candidate)
        end
        candidate.expand_path
      end

      # Build the multipart body by hand: Net::HTTP#set_form invokes a Proc that
      # belongs to the loading Ractor, which raises "defined with an
      # un-shareable Proc in a different Ractor" when the tool runs inside the
      # session Ractor.
      def upload(file, size, token, context, caption)
        photo = PHOTO_EXTENSIONS.include?(file.extname.downcase)
        method = photo ? "sendPhoto" : "sendDocument"
        field = photo ? "photo" : "document"

        boundary = "----Rubot#{SecureRandom.hex(16)}"
        body = String.new(encoding: Encoding::BINARY)
        append_field(body, boundary, "chat_id", context[:chat_id])
        append_field(body, boundary, "message_thread_id", context[:thread_id]) if context[:thread_id]
        append_field(body, boundary, "caption", caption) unless caption.empty?

        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"#{field}\"; filename=\"#{file.basename}\"\r\n"
        body << "Content-Type: #{mime_type(file)}\r\n\r\n"
        body << file.binread
        body << "\r\n"
        body << "--#{boundary}--\r\n"

        uri = URI("#{api_base}/bot#{token}/#{method}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 120

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
        request.body = body

        response = http.request(request)
        parsed = JSON.parse(response.body) rescue {}

        return "ERROR: Telegram rejected the file: #{parsed["description"] || response.code}" unless parsed["ok"]

        kind = photo ? "photo" : "document"
        "Sent #{file.basename} (#{size} bytes) to the chat as a #{kind}."
      end

      def append_field(body, boundary, name, value)
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
        body << value.to_s
        body << "\r\n"
      end

      def api_base
        ENV.fetch("RUBOT_TELEGRAM_API_BASE", "https://api.telegram.org")
      end

      def mime_type(file)
        MIME_TYPES.fetch(file.extname.downcase, "application/octet-stream")
      end
    end
  end
end
