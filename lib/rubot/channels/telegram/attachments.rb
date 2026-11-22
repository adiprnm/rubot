# frozen_string_literal: true

module Rubot
  module Channels
    class Telegram < Channel
      # Inbound media: a photo or a document the user sent, saved next to the
      # workspace so the agent can read it with its normal tools.
      #
      # Telegram never puts media in "text" - photos and captions arrive as
      # separate fields - so this is where the message is read for what it
      # carries, downloaded, and described for the prompt. A failed download
      # becomes a note the model can act on, never an exception that would
      # swallow the user's caption.
      module Attachments
        FILE_API_BASE = "https://api.telegram.org/file/bot"
        # Bot API refuses getFile above 20 MB.
        MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
        UNSUPPORTED_MEDIA = %w[sticker voice video video_note audio animation].freeze

        private

        # Telegram delivers media in its own fields, never in "text": a photo
        # arrives as an array of pre-scaled `photo` entries, a file as `document`.
        # Returns [attachments, unsupported].
        def extract_attachments(message)
          return [ [], nil ] unless @config.fetch("attachments", true)

          photos = message["photo"]
          if photos.is_a?(Array) && !photos.empty?
            best = photos.max_by { |photo| photo["file_size"].to_i }
            return [ [ {
              file_id: best["file_id"],
              kind: :image,
              unique_id: best["file_unique_id"],
              extension: ".jpg"
            } ], nil ]
          end

          document = message["document"]
          if document.is_a?(Hash) && document["file_id"]
            mime = document["mime_type"].to_s
            return [ [ {
              file_id: document["file_id"],
              kind: mime.start_with?("image/") ? :image : :file,
              unique_id: document["file_unique_id"],
              name: document["file_name"],
              size: document["file_size"].to_i
            } ], nil ]
          end

          [ [], UNSUPPORTED_MEDIA.find { |field| message[field] } ]
        end

        # Download one attachment and describe it for the agent's prompt.
        # Never raises: a failed download becomes a note the model can act on
        # instead of an exception that would swallow the user's caption.
        def receive_attachment(attachment, session_id, chat_id)
          label = attachment[:kind] == :image ? "an image" : "a file"

          if (attachment[:size] || 0) > MAX_ATTACHMENT_BYTES
            warn "[telegram] Attachment too large: #{attachment[:size]} bytes"
            return "\u{1F4CE} User attached #{label} but it exceeds Telegram's " \
                   "#{MAX_ATTACHMENT_BYTES / (1024 * 1024)} MB download limit."
          end

          dest = download_attachment(attachment, session_id)
          unless dest
            warn "[telegram] Failed to download #{label} for chat #{chat_id}"
            return "\u{1F4CE} User attached #{label} but it could not be downloaded."
          end

          details = [ Rubot::ImageInfo.dimensions(dest), human_size(File.size(dest)) ].compact
          suffix = details.empty? ? "" : " (#{details.join(', ')})"
          "\u{1F4CE} User attached #{label}: #{dest}#{suffix}"
        end

        # Resolve the Telegram file_path for a file_id and stream it to disk.
        # Returns the local path, or nil on any failure.
        def download_attachment(attachment, session_id)
          file_path = telegram_file_path(attachment[:file_id])
          return nil unless file_path

          dir = File.join(attachments_root, sanitize_component(session_id))
          FileUtils.mkdir_p(dir)
          dest = File.join(dir, attachment_filename(attachment, file_path))

          uri = URI("#{FILE_API_BASE}#{@token}/#{file_path}")
          downloaded = false
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.open_timeout = 10
            http.read_timeout = 120
            http.request_get(uri.request_uri) do |response|
              unless response.code.to_i == 200
                warn "[telegram] File download failed: #{response.code}"
                next
              end
              File.open(dest, "wb") do |file|
                response.read_body { |chunk| file.write(chunk) }
              end
              downloaded = true
            end
          end

          return dest if downloaded && File.size?(dest)

          # Do not leave a zero-byte file behind for the agent to trip over.
          FileUtils.rm_f(dest)
          nil
        rescue StandardError => e
          warn "[telegram] Download error: #{e.class}: #{e.message}"
          FileUtils.rm_f(dest) if dest
          nil
        end

        def telegram_file_path(file_id)
          url = URI("#{API_BASE}#{@token}/getFile?#{URI.encode_www_form('file_id' => file_id)}")
          response = http_get(url)
          unless response["ok"]
            warn "[telegram] getFile error: #{response['description']}"
            return nil
          end

          response.dig("result", "file_path")
        rescue StandardError => e
          warn "[telegram] getFile failed: #{e.class}: #{e.message}"
          nil
        end

        # Attachments stay inside the workspace so the safety guard lets the
        # agent read them, and so the user finds them on the host.
        def attachments_root
          workspace =
            if @app_config
              @app_config.workspace
            elsif @agent.respond_to?(:config) && @agent.config
              @agent.config.workspace
            else
              File.join(Dir.home, ".rubot", "workspace")
            end
          File.join(workspace, "attachments")
        end

        def attachment_filename(attachment, file_path)
          extension = File.extname(file_path)
          extension = File.extname(attachment[:name].to_s) if extension.empty?
          extension = attachment[:extension].to_s if extension.empty?
          extension = ".jpg" if extension.empty?

          unique = sanitize_component(attachment[:unique_id].to_s)
          unique = SecureRandom.hex(6) if unique.empty?

          original = attachment[:name].to_s
          base = sanitize_component(File.basename(original, File.extname(original)))
          base = "#{base}-#{unique}" unless base.empty?       # keeps the human name
          base = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{unique}" if base.empty?

          "#{base}#{extension}"
        end

        # Keeps files inside the attachments directory: no slashes, no leading dots.
        def sanitize_component(value)
          value.to_s.gsub(/[^A-Za-z0-9_.-]/, "_").sub(/\A\.+/, "")[0, 80].to_s
        end

        def human_size(bytes)
          return "0 B" unless bytes.to_i.positive?

          if bytes >= 1024 * 1024
            format("%.1f MB", bytes / (1024.0 * 1024.0))
          elsif bytes >= 1024
            format("%.0f KB", bytes / 1024.0)
          else
            "#{bytes} B"
          end
        end
      end
    end
  end
end
