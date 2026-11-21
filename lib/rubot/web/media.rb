# frozen_string_literal: true

module Rubot
  module Web
    # The pictures and documents a conversation hands back: where they are
    # stored, how a tool call is pointed at that folder, and the route that
    # serves one.
    #
    # Included into the channel, so it can ask the channel for the persona store
    # and the session it is serving. The stored-name shape comes from the route
    # table, because the reader that picks a name out of a tool result and the
    # route that serves it have to agree exactly.
    module Media
      # A markdown note is served as text, not as text/markdown: a browser
      # downloads a type it has no viewer for, and a note the reader has to save
      # first is a note they cannot read. PDFs are served as PDFs and opened by
      # the browser's own viewer.
      MEDIA_TYPES = {
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".mp4" => "video/mp4",
        ".webm" => "video/webm",
        ".pdf" => "application/pdf",
        ".md" => "text/plain; charset=utf-8"
      }.freeze

      private

      # Where this conversation's pictures live: the folder that send_files
      # copies into, inside the persona's own workspace. It is the same
      # per-session folder the Telegram channel writes to, so a tool call that
      # worked in one channel has somewhere to land in the other.
      def attachments_dir(sid)
        store = persona_store
        slug = owner_slug(sid)
        return nil unless store && slug

        workspace = store.workspace_for(slug)
        workspace && File.join(workspace, "attachments", sid)
      end

      # Where a picture is drawn from. The token rides in it like every other
      # URL the page writes: an <img> cannot send a cookie it was not given.
      def media_url(sid, name)
        "/s/#{sid}/media/#{name}#{token_query}"
      end

      # The files a call handed back, read out of the result the call left in
      # the transcript. The markers are the only record of which stored files it
      # produced — that is how a conversation drawn from disk a week later can
      # still show them. One result can name several: `send_files` sends a batch
      # in a single call and writes a marker per file.
      #
      # A picture is drawn as a picture and anything else as a document card,
      # and the type the route serves it under is what decides which: the two
      # questions have one answer.
      def sent_attachments(name, result, sid)
        # Old transcripts still carry calls named `send_file` from before the
        # two tools were merged. They are read here, never produced: the only
        # tool now is `send_files`.
        return [] unless %w[send_files send_file].include?(name.to_s)

        result.to_s.scan(Rubot::Tools::SendFiles::WEB_MARKER_RE).flatten.filter_map do |stored|
          next unless Router::MEDIA_NAME.match?(stored)

          extension = File.extname(stored)
          url = media_url(sid, stored)

          # The stored file's own id is its stable identity on the page: the
          # timeline is redrawn on every token, and a file that kept its node
          # is not fetched or decoded again while the answer grows under it.
          { url: url, name: download_name(stored), id: stored[0, 32],
            kind: attachment_kind(stored),
            label: extension.delete_prefix(".").upcase }
        end.uniq { |attachment| attachment[:id] }
      end

      def attachment_kind(name)
        type = MEDIA_TYPES.fetch(File.extname(name), "")
        return :video if type.start_with?("video/")
        return :picture if type.start_with?("image/")

        :document
      end

      def picture?(name)
        MEDIA_TYPES.fetch(File.extname(name), "").start_with?("image/")
      end

      # Point the agent's file tools at this conversation, so a picture they
      # hand back lands where the page can serve it. Telegram sets the same
      # field with a chat id; here it is a folder. Plain strings only, because
      # the value crosses into the session's Ractor.
      def bind_file_delivery(sid)
        dir = attachments_dir(sid)
        return unless dir

        tool = session_for(sid).tools.get("send_files")
        tool.delivery_context = { channel: "web", dir: dir } if tool
      end

      # What a file is called when it is downloaded: the stored name minus the
      # id in front of it. A name the slug could not keep — a file called only
      # in symbols — falls back to a word for what it is.
      def download_name(name)
        extension = File.extname(name)
        base = File.basename(name, extension).sub(/\A[0-9a-f]{32}-?/, "")
        return "#{base}#{extension}" unless base.empty?

        "#{picture?(name) ? "gambar" : "berkas"}#{extension}"
      end

      def serve_media(res, sid, name)
        return not_found(res) unless owner_slug(sid) && Router::MEDIA_NAME.match?(name)

        dir = attachments_dir(sid)
        path = dir && File.join(dir, name)
        return not_found(res) unless path && File.file?(path)

        res["Content-Type"] = MEDIA_TYPES.fetch(File.extname(name), "application/octet-stream")
        res["Content-Length"] = File.size(path).to_s
        res["Cache-Control"] = "private, max-age=3600"
        # The name the reader can download as is set by the `download`
        # attribute on the anchor; inline keeps a click from navigating away
        # from the conversation on browsers that ignore it.
        res["Content-Disposition"] = %(inline; filename="#{download_name(name)}")
        res.body = File.binread(path)
      end
    end
  end
end
