# frozen_string_literal: true

require "json"
require "net/http"
require "pathname"
require "securerandom"
require "fileutils"

module Rubot
  module Tools
    # Everything a tool needs to hand one file to the chat that asked for it.
    #
    # `send_files` delivers any number of paths, from one file to a batch. Where
    # the bytes go, what they are called and what the result says are the same
    # questions either way, so they are answered here once.
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
    module FileDelivery
      MAX_BYTES = 50 * 1024 * 1024 # Telegram bot upload limit
      PHOTO_EXTENSIONS = %w[.png .jpg .jpeg .webp].freeze
      # Telegram has a separate sendVideo method; a video sent as a document
      # loses its player and the reader has to download it before watching.
      VIDEO_EXTENSIONS = %w[.mp4 .webm .mov].freeze
      # The token the web channel reads back out of a tool result. It is how a
      # conversation drawn from disk a week later still knows which stored file
      # this call produced. One result can carry several — a batch sends a
      # marker per picture.
      WEB_MARKER = "web-attachment"
      WEB_MARKER_RE = /\[#{WEB_MARKER} ([^\]]+)\]/.freeze
      # What the web page can draw or offer back: the pictures it shows as a
      # picture, and the two documents a browser already knows how to open —
      # a PDF it views in a tab of its own and a markdown note it shows as
      # text. Anything else is refused rather than stored where nothing would
      # ever show it.
      WEB_IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp].freeze
      WEB_VIDEO_EXTENSIONS = %w[.mp4 .webm].freeze
      WEB_DOCUMENT_EXTENSIONS = %w[.pdf .md .markdown].freeze
      WEB_EXTENSIONS = (WEB_IMAGE_EXTENSIONS + WEB_VIDEO_EXTENSIONS + WEB_DOCUMENT_EXTENSIONS).freeze

      MIME_TYPES = {
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".webp" => "image/webp",
        ".gif" => "image/gif",
        ".mp4" => "video/mp4",
        ".webm" => "video/webm",
        ".mov" => "video/quicktime",
        ".pdf" => "application/pdf",
        ".json" => "application/json",
        ".txt" => "text/plain",
        ".md" => "text/markdown",
        ".markdown" => "text/markdown"
      }.freeze

      private

      def web?(context)
        context[:channel].to_s == "web"
      end

      # The web page has no upload endpoint to hand bytes to. What it does have
      # is a folder it already serves for this one conversation, so the file is
      # copied there under a name the page can trust and the result says which
      # name — that marker is the whole reason a refreshed page can draw the
      # picture again, or offer the document again.
      #
      # Returns the stored name, or an error string.
      def deliver_web(file, context)
        dir = context[:dir].to_s
        return "ERROR: this conversation has no attachment folder" if dir.empty?

        extension = file.extname.downcase
        unless WEB_EXTENSIONS.include?(extension)
          return "ERROR: the web page can send pictures, videos and documents " \
                 "(#{WEB_EXTENSIONS.map { |ext| ext.delete_prefix(".") }.join(", ")}): #{file.basename}"
        end

        FileUtils.mkdir_p(dir)
        name = web_name(file)
        File.binwrite(File.join(dir, name), file.binread)
        name
      end

      # An id this process generated, the reader's own file name reduced to a
      # slug, and the extension: a download still reads like a file, while a
      # hand-typed path cannot name one. `.markdown` is stored as `.md`, the
      # same way `.jpeg` is stored as `.jpg`: one extension per format keeps
      # the route that serves it to a single shape.
      def web_name(file)
        extension = file.extname.downcase
        extension = ".jpg" if extension == ".jpeg"
        extension = ".md" if extension == ".markdown"
        base = File.basename(file.basename, file.extname)
                   .downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, 60].to_s
        "#{SecureRandom.hex(16)}#{base.empty? ? "" : "-#{base}"}#{extension}"
      end

      def resolve(path)
        candidate = Pathname.new(path)
        unless candidate.absolute?
          base = workspace || @safety_guard&.workspace || Pathname.new(Dir.pwd)
          candidate = Pathname.new(base).join(candidate)
        end
        candidate.expand_path
      end

      # Build the multipart body by hand: Net::HTTP#set_form invokes a Proc that
      # belongs to the loading Ractor, which raises "defined with an
      # un-shareable Proc in a different Ractor" when the tool runs inside the
      # session Ractor.
      def upload(file, size, token, context, caption)
        extension = file.extname.downcase
        photo = PHOTO_EXTENSIONS.include?(extension)
        video = VIDEO_EXTENSIONS.include?(extension)
        method = if photo then "sendPhoto" elsif video then "sendVideo" else "sendDocument" end
        field = if photo then "photo" elsif video then "video" else "document" end

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

        kind = if photo then "photo" elsif video then "video" else "document" end
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
