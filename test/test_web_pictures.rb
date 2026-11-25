# frozen_string_literal: true

require "test_helper"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # Pictures and attachments: what the browser uploads, what the page shows and what the model reads.
    class TestWebPictures < Minitest::Test
      include WebChannelSupport

      # --- pictures -------------------------------------------------------

      # The agent hands a picture back through send_files. The web channel has
      # no upload endpoint, so the tool copies the file into the conversation's
      # own folder and says which name it wrote — that name is what the page
      # draws, and what a refreshed page can draw again.
      def test_send_files_hands_a_picture_into_the_conversation
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        source = File.join(Dir.mktmpdir, "Desain Final (v2).png")
        File.binwrite(source, png_bytes)

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("path" => source)

        stored = result[/\[web-attachment ([^\]]+)\]/, 1]
        refute_nil stored, "the result has to name the file it stored: #{result}"
        assert_match(/\A[0-9a-f]{32}-desain-final-v2\.png\z/, stored)
        assert_equal png_bytes, File.binread(File.join(dir, stored))
      end

      # Only what the page can draw or hand back: a picture, a PDF, a markdown
      # note. A file stored where nothing would ever show it is worse than a
      # refusal.
      def test_send_files_refuses_what_the_page_cannot_draw
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        source = File.join(Dir.mktmpdir, "arsip.zip")
        File.binwrite(source, "PK\x03\x04")

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: channel.send(:attachments_dir, "web_kanyaah") }
        result = tool.execute("path" => source)

        assert result.start_with?("ERROR"), "a file the page cannot draw is refused, not stored"
        assert_includes result, "pictures, videos and documents"
      end

      # A PDF is not a picture, but the browser opens one on its own: it is
      # stored like a picture, and the page reads the marker's extension to
      # decide between a picture and a card.
      def test_send_files_hands_a_pdf_into_the_conversation
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        source = File.join(Dir.mktmpdir, "Laporan Triwulan.pdf")
        File.binwrite(source, "%PDF-1.4\n")

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("path" => source)

        stored = result[/\[web-attachment ([^\]]+)\]/, 1]
        assert_match(/\A[0-9a-f]{32}-laporan-triwulan\.pdf\z/, stored.to_s)
        assert_equal :document,
                     channel.send(:sent_attachments, "send_files", result, "web_kanyaah").first[:kind]
        assert_equal "%PDF-1.4\n", File.binread(File.join(dir, stored))
      end

      # A video is stored like a picture, but the page draws it with its own
      # controls so the reader can play it in place rather than download it.
      def test_send_files_hands_a_video_into_the_conversation
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        source = File.join(Dir.mktmpdir, "klip Liburan.mp4")
        File.binwrite(source, "\x00\x00\x00\x18ftypmp42fake")

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("path" => source)

        stored = result[/\[web-attachment ([^\]]+)\]/, 1]
        assert_match(/\A[0-9a-f]{32}-klip-liburan\.mp4\z/, stored.to_s)
        assert_equal :video,
                     channel.send(:sent_attachments, "send_files", result, "web_kanyaah").first[:kind]
        assert_equal File.binread(source), File.binread(File.join(dir, stored))
      end

      # The route serves a video under its own MIME type, so the browser can
      # play it from the same media URL a picture uses.
      def test_serve_media_sends_a_video_as_video
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        FileUtils.mkdir_p(dir)
        name = "#{"a" * 32}.mp4"
        File.binwrite(File.join(dir, name), "fake video")

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah", name)

        assert_equal "video/mp4", res.headers["Content-Type"]
        assert_equal "fake video", res.body
      end

      # `.markdown` is stored as `.md`, the same way `.jpeg` becomes `.jpg`:
      # one extension per format keeps the route that serves it to one shape.
      def test_send_files_stores_a_markdown_note_as_md
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        source = File.join(Dir.mktmpdir, "Catatan Rapat.markdown")
        File.write(source, "# Rapat\n\n- satu\n")

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("path" => source)

        stored = result[/\[web-attachment ([^\]]+)\]/, 1]
        assert_match(/\A[0-9a-f]{32}-catatan-rapat\.md\z/, stored.to_s)
        assert_equal :document,
                     channel.send(:sent_attachments, "send_files", result, "web_kanyaah").first[:kind]
        assert_includes File.read(File.join(dir, stored)), "# Rapat"
      end

      # "Kirim 5 gambar" is one instruction; one call stores all five and names
      # each of them, so the page draws the batch as one strip under one row.
      def test_send_files_hands_a_batch_into_the_conversation
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        sources = %w[satu dua tiga empat lima].map do |base|
          path = File.join(Dir.mktmpdir, "#{base}.png")
          File.binwrite(path, png_bytes)
          path
        end

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => sources)

        stored = result.scan(/\[web-attachment ([^\]]+)\]/).flatten

        assert_equal 5, stored.size, "every picture in the batch is named: #{result}"
        assert_equal %w[dua empat lima satu tiga], stored.map { |n| n[/-([a-z]+)\.png\z/, 1] }.sort
        stored.each { |name| assert_equal png_bytes, File.binread(File.join(dir, name)) }
      end

      # A batch may mix pictures and documents — a PDF report beside the
      # screenshots it quotes — and one strip holds both: the page decides per
      # file which of the two it draws.
      def test_send_files_hands_pictures_and_documents_into_one_strip
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        sources = [
          File.join(Dir.mktmpdir, "grafik.png").tap { |path| File.binwrite(path, png_bytes) },
          File.join(Dir.mktmpdir, "laporan.pdf").tap { |path| File.write(path, "%PDF-1.4\n") },
          File.join(Dir.mktmpdir, "catatan.md").tap { |path| File.write(path, "# Rapat\n") }
        ]

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => sources)

        stored = result.scan(/\[web-attachment ([^\]]+)\]/).flatten
        assert_equal 3, stored.size, "every file in the batch is named: #{result}"
        assert_includes result, "as attachments"

        attachments = channel.send(:sent_attachments, "send_files", result, "web_kanyaah")
        assert_equal %i[picture document document], attachments.map { |file| file[:kind] }
        assert_equal %w[MD PDF PNG], attachments.map { |file| file[:label] }.sort
        assert_equal %w[catatan.md grafik.png laporan.pdf],
                     attachments.map { |file| file[:name] }.sort
      end

      # A batch is not all-or-nothing: the file that is missing is said out
      # loud, and the rest still arrive.
      def test_send_files_sends_the_rest_when_one_path_is_missing
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        good = File.join(Dir.mktmpdir, "ada.png")
        File.binwrite(good, png_bytes)

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => [ good, File.join(Dir.mktmpdir, "hilang.png") ])

        assert_equal 1, result.scan(/\[web-attachment /).size
        assert_includes result, "hilang.png"
        assert_includes result, "not found"
        refute result.start_with?("ERROR"), "one good file still makes the call a success"
      end

      # Nothing sent, nothing to show: the call has to read as a failure.
      def test_send_files_reports_a_batch_that_sent_nothing
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => [ "/nowhere/a.png", "/nowhere/b.png" ])

        assert result.start_with?("ERROR"), result
        assert_includes result, "a.png"
        assert_includes result, "b.png"
      end

      def test_send_files_refuses_more_than_it_can_send_in_one_call
        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: Dir.mktmpdir }

        count = Tools::SendFiles::MAX_FILES + 1
        result = tool.execute("paths" => Array.new(count) { |i| "x#{i}.png" })

        assert result.start_with?("ERROR"), result
        assert_includes result, Tools::SendFiles::MAX_FILES.to_s
      end

      # A model that has just used send_files answers with "path"; a model
      # wrapping a long list sometimes serialises the array back into a string.
      # The second one used to make every path "not found" at once, because
      # Array() wraps the whole string as a single path.
      def test_send_files_accepts_a_json_encoded_array
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        sources = %w[satu dua tiga].map do |base|
          path = File.join(Dir.mktmpdir, "#{base}.png")
          File.binwrite(path, png_bytes)
          path
        end

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => JSON.generate(sources))

        assert_equal 3, result.scan(/\[web-attachment /).size, result
      end

      # Ten paths in one call is the case that found this: the array arrived as
      # a string and the whole batch failed as nine non-existent files.
      def test_send_files_accepts_ten_paths_in_one_json_string
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        sources = (1..10).map do |n|
          path = File.join(Dir.mktmpdir, "gambar-#{n}.png")
          File.binwrite(path, png_bytes)
          path
        end

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => JSON.generate(sources))

        assert_equal 10, result.scan(/\[web-attachment /).size, result
        refute_includes result, "not found"
      end

      # A path that merely begins with a bracket is still a path: parsing must
      # not swallow a real file name.
      def test_send_files_keeps_a_path_that_only_looks_like_json
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        source = File.join(Dir.mktmpdir, "[draft] catatan.png")
        File.binwrite(source, png_bytes)

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("paths" => [ source ])

        assert_equal 1, result.scan(/\[web-attachment /).size, result
      end

      def test_send_files_accepts_a_single_path_key
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        dir = channel.send(:attachments_dir, "web_kanyaah")
        source = File.join(Dir.mktmpdir, "satu.png")
        File.binwrite(source, png_bytes)

        tool = Tools::SendFiles.new
        tool.delivery_context = { channel: "web", dir: dir }
        result = tool.execute("path" => source)

        assert_equal 1, result.scan(/\[web-attachment /).size, result
      end

      # The marker is read back out of the result the transcript keeps, which is
      # how a conversation drawn a week later still knows which stored file that
      # call produced.
      def test_the_channel_reads_the_picture_back_out_of_the_tool_result
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        stored = "e" * 32 + "-desain.png"
        result = "Sent desain.png (12 bytes) as a picture. [web-attachment #{stored}]"

        picture = channel.send(:sent_attachments, "send_files", result, "web_kanyaah").first

        assert_equal "desain.png", picture[:name]
        assert_includes picture[:url], "/s/web_kanyaah/media/#{stored}"
        assert_equal "e" * 32, picture[:id],
                     "the stored id is what lets the page keep the picture's node"
        assert_equal :picture, picture[:kind]

        assert_empty channel.send(:sent_attachments, "shell", result, "web_kanyaah"),
                     "only a file-sending result names a picture"
        assert_empty channel.send(:sent_attachments, "send_files",
                                  "Sent x. [web-attachment ../../etc/passwd]", "web_kanyaah")
      end

      # Old transcripts still name the tool `send_file`. The tool is gone, but
      # the picture in that stored result is not: it has to keep rendering.
      def test_an_old_single_file_call_still_renders_its_picture
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        stored = "f" * 32 + "-desain.png"
        result = "Sent desain.png (12 bytes). [web-attachment #{stored}]"

        picture = channel.send(:sent_attachments, "send_file", result, "web_kanyaah").first

        assert_equal :picture, picture[:kind]
        assert_includes picture[:url], "/s/web_kanyaah/media/#{stored}"
      end

      # A PDF and a markdown note are read out of the same marker as a picture,
      # but they are not pictures: the page hands them over as a card, and the
      # badge on that card names the format.
      def test_a_document_is_read_back_as_a_card_not_a_picture
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        stored = "d" * 32 + "-laporan.pdf"
        result = "Sent laporan.pdf (12 bytes) as a document. [web-attachment #{stored}]"

        document = channel.send(:sent_attachments, "send_files", result, "web_kanyaah").first

        assert_equal :document, document[:kind]
        assert_equal "PDF", document[:label]
        assert_equal "laporan.pdf", document[:name]
        assert_includes document[:url], "/s/web_kanyaah/media/#{stored}"
      end

      # One call, several files: the result of send_files carries a marker
      # per file, and the page turns every one of them into a picture in the
      # same strip.
      def test_a_batch_result_names_every_picture_it_sent
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        names = %w[satu dua tiga].map { |base| "#{SecureRandom.hex(16)}-#{base}.png" }
        result = "Sent 3 files as attachments (png, jpg, gif, webp, pdf, md). " +
                 names.map { |name| "[web-attachment #{name}]" }.join(" ")

        pictures = channel.send(:sent_attachments, "send_files", result, "web_kanyaah")

        assert_equal 3, pictures.size, "every marker becomes a picture"
        assert_equal names.size, pictures.map { |p| p[:url] }.uniq.size
        assert_equal %w[tiga.png satu.png dua.png], pictures.map { |p| p[:name] }.sort.reverse
        assert_equal %i[picture picture picture], pictures.map { |p| p[:kind] }
      end

      # A picture belongs to a conversation: the route looks only inside that
      # conversation's folder, so a name borrowed from another session is a 404
      # rather than a leak.
      def test_a_picture_from_another_session_does_not_resolve
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { "web_kanyaah" => "Halo", "web_kanyaah~20261108-101010" => "Hai" }
        )
        name = write_picture(channel, "web_kanyaah")

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah~20261108-101010", name)
        assert_equal 404, res.status

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah", "../../etc/passwd")
        assert_equal 404, res.status
      end

      # Served inline under the type of its extension, with the reader's own
      # file name in the disposition rather than the stored id.
      def test_a_picture_is_served_back_under_its_own_name
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        name = write_picture(channel, "web_kanyaah", "desain-final.png")

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah", name)

        assert_equal 200, res.status
        assert_equal "image/png", res.headers["Content-Type"]
        assert_includes res.headers["Content-Disposition"], 'filename="desain-final.png"'
        assert_equal png_bytes, res.body
      end

      # A PDF is served as a PDF, so the browser's own viewer opens it. It is
      # inline rather than an attachment: a click on the card is a look at the
      # document, not a save it.
      def test_a_pdf_is_served_as_a_pdf
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        name = write_attachment(channel, "web_kanyaah", "laporan.pdf", "%PDF-1.4\n")

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah", name)

        assert_equal 200, res.status
        assert_equal "application/pdf", res.headers["Content-Type"]
        assert_includes res.headers["Content-Disposition"], 'filename="laporan.pdf"'
        assert_equal "%PDF-1.4\n", res.body
      end

      # A markdown note is served as text, not as text/markdown: a browser
      # downloads a type it has no viewer for, and a note the reader has to
      # save before reading is a note that never arrives.
      def test_a_markdown_note_is_served_as_text
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        name = write_attachment(channel, "web_kanyaah", "catatan.md", "# Rapat\n")

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah", name)

        assert_equal 200, res.status
        assert_equal "text/plain; charset=utf-8", res.headers["Content-Type"]
        assert_equal "# Rapat\n", res.body
      end

      # The route takes the names this channel writes and nothing else: an
      # extension it never generates is a 404, whatever is on disk.
      def test_a_name_the_channel_never_writes_is_not_served
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        name = write_attachment(channel, "web_kanyaah", "skrip.rb", "puts 1\n")

        res = FakeResponse.new
        channel.send(:serve_media, res, "web_kanyaah", name)

        assert_equal 404, res.status
      end

      def test_a_picture_that_does_not_exist_is_not_found
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        res = FakeResponse.new

        channel.send(:serve_media, res, "web_kanyaah", "a" * 32 + ".png")

        assert_equal 404, res.status
      end

      # A file the agent sent sits in the timeline under the row that produced
      # it, drawn by the same strip the answer's pictures use.
      def test_a_picture_the_agent_sent_is_drawn_in_the_timeline
        image = { url: "/s/web_kanyaah/media/x.png?token=t0k", name: "desain.png", kind: :picture }

        html = View.render("_timeline", items: [ { kind: :attachments, list: [ image ] } ])

        assert_includes html, %(class="attachments")
        assert_includes html, %(data-lightbox="#{image[:url]}")
        assert_includes html, %(download="desain.png")
      end

      # A video is a preview card: clicking it opens the same lightbox a
      # picture uses, which switches to a player for the video. The download
      # beside it is still a plain link.
      def test_a_video_the_agent_sent_opens_in_the_lightbox
        video = { url: "/s/web_kanyaah/media/#{"a" * 32}.mp4?token=t0k", name: "klip.mp4",
                  id: "a" * 32, kind: :video, label: "MP4" }

        html = View.render("_timeline", items: [ { kind: :attachments, list: [ video ] } ])

        assert_includes html, %(class="attachment attachment--video")
        assert_includes html, %(data-lightbox="#{video[:url]}")
        assert_includes html, %(data-lightbox-kind="video")
        assert_includes html, %(<video class="attachment-video")
        assert_includes html, %(src="#{video[:url]}")
        assert_includes html, %(download="klip.mp4")
      end

      # A document is not drawn into a sheet: the card is a link out to the
      # browser's own viewer, with the format written on it and the same
      # download beside it that a picture carries.
      def test_a_document_the_agent_sent_is_drawn_as_a_card
        document = { url: "/s/web_kanyaah/media/laporan.pdf?token=t0k", name: "laporan.pdf",
                     id: "c" * 32, kind: :document, label: "PDF" }

        html = View.render("_timeline", items: [ { kind: :attachments, list: [ document ] } ])

        assert_includes html, %(class="attachment-document")
        assert_includes html, %(href="#{document[:url]}")
        assert_includes html, %(target="_blank")
        assert_includes html, %(rel="noopener")
        assert_includes html, %(class="pdf-icon"), "a PDF wears its own mark"
        assert_includes html, %(>PDF</text>)
        assert_includes html, %(<span class="attachment-name">laporan.pdf</span>)
        assert_includes html, %(download="laporan.pdf")
        refute_includes html, "data-lightbox", "a PDF is not opened into the sheet"
        assert_includes html, %(id="file-#{"c" * 32}"), "a card is kept across a redraw too"
      end

      # Only a PDF gets the badge. Any other document keeps the plain format
      # label, so a note still says what it is without borrowing the PDF mark.
      def test_a_non_pdf_document_keeps_its_text_label
        document = { url: "/s/web_kanyaah/media/catatan.md?token=t0k", name: "catatan.md",
                     kind: :document, label: "MD" }

        html = View.render("_timeline", items: [ { kind: :attachments, list: [ document ] } ])

        assert_includes html, %(<span class="attachment-label" aria-hidden="true">MD</span>)
        refute_includes html, "pdf-icon", "a markdown note is not a PDF"
      end

      # A running turn redraws the whole timeline on every event. A picture
      # given a stable id and hx-preserve keeps the node it already has, so it
      # is not fetched and decoded again under a growing answer — which is what
      # made a strip of them blink.
      def test_a_picture_keeps_its_node_when_the_timeline_is_redrawn
        first = { url: "/s/web_kanyaah/media/#{"a" * 32}-satu.png", name: "satu.png", id: "a" * 32 }
        second = { url: "/s/web_kanyaah/media/#{"b" * 32}-dua.png", name: "dua.png", id: "b" * 32 }

        html = View.render("_timeline", items: [ { kind: :attachments, list: [ first, second ] } ])

        assert_equal 2, html.scan(/hx-preserve="true"/).size,
                     "every picture asks to be kept across a redraw"
        assert_includes html, %(id="picture-#{"a" * 32}")
        assert_includes html, %(id="picture-#{"b" * 32}"),
                        "two pictures must not answer to the same id"
      end

      # A caller that names no id — an older session file, or a bare partial in
      # a test — must still render: there is simply nothing to preserve by.
      def test_a_picture_without_an_id_is_drawn_without_a_preserve_marker
        image = { url: "/s/web_kanyaah/media/x.png", name: "x.png" }

        html = View.render("_attachments", attachments: [ image ])

        refute_includes html, "hx-preserve"
        assert_includes html, %(class="attachment")
      end

      # The transcript holds the call and its result; drawn back, the picture is
      # there again — the row first, the picture under it.
      def test_history_draws_a_picture_the_agent_sent
        sid = "web_kanyaah"
        stored = "f" * 32 + "-desain.png"
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { sid => "Buatkan gambar" }
        )
        write_messages(channel, sid, [
          { "role" => "user", "content" => "Buatkan gambar" },
          { "role" => "assistant", "content" => "Ini gambarnya.",
            "tool_calls" => [ { "id" => "call_1",
                                "function" => { "name" => "send_files",
                                                "arguments" => JSON.generate({ "path" => "desain.png" }) } } ] },
          { "role" => "tool", "tool_call_id" => "call_1",
            "content" => "Sent desain.png (12 bytes) as a picture. [web-attachment #{stored}]" }
        ])

        items = channel.history(sid).last[:items]

        assert_equal %i[tool attachments], items.last(2).map { |item| item[:kind] }
        assert_includes items.last[:list].first[:url], "/s/#{sid}/media/#{stored}"
        assert_equal :picture, items.last[:list].first[:kind]
      end

      # A reply nobody prompted — a finished batch of sub agents, a fired job —
      # carries a stamp so the transcript starts a block of its own for it. The
      # neighbours cannot say which it is (an answer after a tool row is the
      # same turn working on), and glued under the answer before it, the report
      # read as if nothing had arrived at all.
      def test_an_answer_that_follows_another_answer_gets_its_own_turn
        sid = "web_kanyaah"
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { sid => "Halo" }
        )
        write_messages(channel, sid, [
          { "role" => "user", "content" => "Halo" },
          { "role" => "assistant", "content" => "Halo juga." },
          { "role" => "assistant", "content" => "Hasil subagent: puisi jadi.", "background" => true }
        ])

        entries = channel.history(sid)

        assert_equal %i[prompt turn turn], entries.map { |entry| entry[:kind] }
        assert_equal "Hasil subagent: puisi jadi.", entries.last[:items].first[:text]
      end

      # The rounds of one turn still belong together: an answer after a tool row
      # is the same exchange carrying on.
      def test_a_tool_round_stays_inside_its_turn
        sid = "web_kanyaah"
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { sid => "Baca file" }
        )
        write_messages(channel, sid, [
          { "role" => "user", "content" => "Baca file" },
          { "role" => "assistant", "content" => "Siap, saya baca.",
            "tool_calls" => [ { "id" => "call_1",
                                "function" => { "name" => "read", "arguments" => "{}" } } ] },
          { "role" => "tool", "tool_call_id" => "call_1", "content" => "[Exit code: 0] isi" },
          { "role" => "assistant", "content" => "Isinya begini." }
        ])

        entries = channel.history(sid)

        assert_equal %i[prompt turn], entries.map { |entry| entry[:kind] }
        texts = entries.last[:items].select { |item| item[:kind] == :text }.map { |item| item[:text] }
        assert_equal [ "Siap, saya baca.", "Isinya begini." ], texts
      end

      # A refresh draws the same seam the live timeline showed: the event is
      # stored beside the transcript, not in a message the model would see.
      def test_history_replays_an_automatic_compaction_seam
        sid = "web_kanyaah"
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { sid => "Lanjutkan kerjaan" }
        )
        dir = channel.instance_variable_get(:@app_config).sessions_dir
        File.write(File.join(dir, "#{sid}.json"), JSON.generate({
          "id" => sid,
          "updated_at" => Time.now.utc.iso8601,
          "messages" => [
            { "role" => "user", "content" => "Lanjutkan kerjaan" },
            { "role" => "assistant", "content" => "Lanjut." }
          ],
          "compaction_events" => [
            { "index" => 1, "summarized" => 8, "before" => 2029, "after" => 1565 }
          ]
        }))

        items = channel.history(sid).last[:items]

        seam = items.find { |item| item[:kind] == :compaction }
        refute_nil seam, "the seam has to survive a refresh, not vanish with the cut"
        assert_equal 8, seam[:summarized]
        assert_equal :compaction, items.first[:kind], "the seam leads into the turn it belongs to"
        assert_equal :text, items.last[:kind], "the answer follows the seam"
      end

      # A PDF read back from a week-old transcript comes back as a card: the
      # word the tool result used is the only thing that has to survive.
      def test_history_draws_a_document_the_agent_sent
        sid = "web_kanyaah"
        stored = "f" * 32 + "-laporan.pdf"
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          sessions: { sid => "Buat laporan" }
        )
        write_messages(channel, sid, [
          { "role" => "user", "content" => "Buat laporan" },
          { "role" => "assistant", "content" => "Ini laporannya.",
            "tool_calls" => [ { "id" => "call_1",
                                "function" => { "name" => "send_files",
                                                "arguments" => JSON.generate({ "path" => "laporan.pdf" }) } } ] },
          { "role" => "tool", "tool_call_id" => "call_1",
            "content" => "Sent laporan.pdf (12 bytes) as a document. [web-attachment #{stored}]" }
        ])

        document = channel.history(sid).last[:items].last[:list].first

        assert_equal :document, document[:kind]
        assert_equal "PDF", document[:label]
        assert_equal "laporan.pdf", document[:name]
      end

      # A compact persona's transcript shows the row its live turn showed: the
      # call the answer belongs to stays under it, not the batch it came in.
      def test_a_compact_persona_s_transcript_keeps_the_call_before_the_answer
        channel = channel_with_sessions(
          personas: { "rubot" => { "name" => "Rubot", "tool_output" => "compact" } },
          sessions: { "web_rubot" => "Cek dua file" }
        )
        write_two_reads(channel)

        items = channel.history("web_rubot").last[:items]

        assert_equal [ "Reading b.rb" ],
                     items.select { |item| item[:kind] == :tool }.map { |item| item[:detail] }
        assert_includes items.map { |item| item[:kind] }, :text, "the answer is not part of the log"
      end

      # A second round of work is where the first one lets go: the transcript
      # reads the same boundary the live turn draws, so only the calls the
      # model is on come back from the log.
      def test_a_compact_persona_s_transcript_drops_the_round_before_the_last
        channel = channel_with_sessions(
          personas: { "rubot" => { "name" => "Rubot", "tool_output" => "compact" } },
          sessions: { "web_rubot" => "Cek dua file" }
        )
        write_two_rounds(channel)

        items = channel.history("web_rubot").last[:items]

        assert_equal [ "Reading b.rb" ],
                     items.select { |item| item[:kind] == :tool }.map { |item| item[:detail] }
      end

      # A call the model answered in words keeps its row in the replayed
      # transcript too: prompt → tool → text → tool → answer reads the same
      # after a refresh as it did live. Only calls in the same breath collapse.
      def test_a_compact_persona_s_transcript_keeps_a_call_between_words
        channel = channel_with_sessions(
          personas: { "rubot" => { "name" => "Rubot", "tool_output" => "compact" } },
          sessions: { "web_rubot" => "Cek dua file" }
        )
        sid = "web_rubot"
        call = lambda do |id, path|
          { "role" => "assistant", "content" => "",
            "tool_calls" => [ { "id" => id,
                                "function" => { "name" => "file_ops",
                                                "arguments" => JSON.generate({ "path" => path }) } } ] }
        end
        write_messages(channel, sid, [
                         { "role" => "user", "content" => "Cek dua file" },
                         call.call("c1", "a.rb"),
                         { "role" => "tool", "tool_call_id" => "c1", "content" => "isi a" },
                         { "role" => "assistant", "content" => "Isi a.rb sudah kubaca." },
                         call.call("c2", "b.rb"),
                         { "role" => "tool", "tool_call_id" => "c2", "content" => "isi b" },
                         { "role" => "assistant", "content" => "Dua-duanya oke." }
                       ])

        items = channel.history(sid).last[:items]

        assert_equal [ "Reading a.rb", "Reading b.rb" ],
                     items.select { |item| item[:kind] == :tool }.map { |item| item[:detail] }
        assert_equal %i[tool text tool text], items.map { |item| item[:kind] }
      end

      # The transcript carries the rows in the order they happened and nothing
      # else: no step markers, no pass numbers. A verbose persona keeps both
      # rounds, because that is what its live turn showed.
      def test_a_replayed_transcript_stamps_nothing
        channel = channel_with_sessions(personas: { "rubot" => { "name" => "Rubot" } },
                                        sessions: { "web_rubot" => "Cek dua file" })
        write_two_rounds(channel)

        items = channel.history("web_rubot").last[:items]

        assert(items.none? { |item| item[:kind] == :step }, "no marker rows")
        assert(items.none? { |item| item.key?(:round) }, "no pass numbers")
        assert_equal [ "Reading a.rb", "Reading b.rb" ],
                     items.select { |item| item[:kind] == :tool }.map { |item| item[:detail] }
      end

      def test_a_verbose_persona_s_transcript_keeps_every_call
        channel = channel_with_sessions(
          personas: { "rubot" => { "name" => "Rubot" } },
          sessions: { "web_rubot" => "Cek dua file" }
        )
        write_two_reads(channel)

        items = channel.history("web_rubot").last[:items]

        assert_equal [ "Reading a.rb", "Reading b.rb" ],
                     items.select { |item| item[:kind] == :tool }.map { |item| item[:detail] }
      end

      # One prompt, one message from the model asking twice, one answer — the
      # batch a live turn draws as two rows at once.

      # One prompt, one call, another call, then the answer: the model came
      # back after the first result, so the second call is a round of its own.

      # The prompt is what the reader typed, and nothing else: pictures from the
      # composer are not part of this channel yet.
      def test_a_prompt_is_drawn_as_text_only
        html = View.render("_message", role: "user", text: "Halo")

        assert_includes html, %(class="msg user")
        refute_includes html, %(class="attachments")
        assert_includes html, "Halo"
      end

      # The composer is text and one button: no file picker, no drop target.
      def test_the_composer_carries_no_picture_input
        html = View.render("_composer", session_id: "web_rubot", token_query: "?token=t0k")

        refute_includes html, %(type="file")
        refute_includes html, "data-upload"
        refute_includes html, %(name="images")

        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))
        refute_includes js, "async attach(files)"
        refute_includes js, "X-Filename"
      end

      # One sheet per page, not one per picture. A thread can hold a hundred
      # images; the lightbox is filled in when one of them is pressed.
      def test_the_page_carries_one_lightbox
        html = View.render("index",
                           personas: [], groups: { pinned: [], recent: [], page: 1, pages: 1, recent_total: 0, pinned_limit: 10, current: "web_rubot" },
                           slug: "rubot", persona_label: "Rubot", persona_emoji: "🤖",
                           persona_prompt: "",
                           persona_model: "m", session_id: "web_rubot",
                    persona_model_value: "", model_choices: [],
                    session_model: "", session_thinking: "medium", persona_thinking: "medium",
                    persona_tool_output: "verbose",
                    skill_choices: [], skills_dir: "~/.rubot/skills",
                           session_short: "web_rubot", session_label: "Sesi baru",
                           document_title: "rubot · Rubot", live_turn: nil, token_query: "",
                           page: { entries: [], more: false, before: 0 }, older_url: "",
                           usage: { cost: "—", cache: "—", ctx: "—" },
                           usage_facts: { model: "m", cost: "—", breakdown: "", requests: "0",
                                          messages: "0", tokens_in: "0", tokens_out: "0",
                                          reasoning: "", cache: "—",
                                          cache_history: "", re_read: "0", saved: "", ctx: "—" })

        assert_equal 1, html.scan(%(id="lightbox")).size
        assert_match(/id="lightbox"[^>]*hidden/, html)
        assert_includes html, 'class="btn lightbox-download"'
        assert_includes html, 'class="lightbox-video"', "the sheet holds a player for videos"

        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))
        assert_includes js, "function openLightbox", "the sheet has to be able to open"
        assert_includes js, %(event.target.closest("[data-lightbox]")),
                        "the handler is delegated: the thread is rewritten by htmx"
        assert_includes js, "trigger.dataset.lightboxKind",
                        "the handler tells a video from a picture"
      end

      # An image written in markdown is the same affordance as an attachment.
      def test_a_markdown_image_can_be_opened_and_downloaded
        html = Format.markdown("![papan](/img/a.png)")

        assert_includes html, %(<img src="/img/a.png" alt="papan")
        assert_includes html, %(data-lightbox="/img/a.png")
        assert_includes html, %(download="papan")
      end

      # A prompt is text; anything else is not a prompt this channel can carry.
      def test_a_turn_with_no_text_is_refused
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        channel.define_singleton_method(:owner_slug) { |_sid| "kanyaah" }

        res = FakeResponse.new
        channel.create_turn(turn_request("   "), res, "web_kanyaah")

        assert_equal 400, res.status
        assert_includes res.body, Rubot::I18n.t("web.turn.empty_message")
      end

      # "Still working" sits between the conversation and the field, so the room
      # above it is the band's own margin plus the thread's bottom padding, and
      # the room below it is the margin under the band. Both must read the same,
      # or the row looks glued to the last thing the turn said. Measured in a
      # browser: 0.15rem + 0.6rem above, 0.75rem below.
      def test_the_working_row_has_the_same_room_above_and_below
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        band = css[/^\.working-band \{[^}]*\}/]
        thread = css[/^\.thread \{[^}]*\}/]

        refute_nil band, "the .working-band rule is missing from app.css"
        refute_nil thread, "the .thread rule is missing from app.css"

        margin = band[/margin: ([^;]+);/, 1]
        refute_nil margin, "the band needs a margin shorthand so both gaps are visible"
        top, _sides, bottom = margin.split
        padding = thread[/padding: ([^;]+);/, 1].to_s.split

        assert_equal "0.75rem", bottom, "the room under the row is the composer's 0.75rem"
        assert_in_delta 0.75, rem(top) + rem(padding[2] || padding[0]), 0.001,
                        "the room above the row is the band's margin plus the thread's own padding"
      end

      # The header does not stick, so any scroll outside the thread takes it off
      # the screen and it never comes back on its own. On a phone two things do
      # exactly that: the momentum at the end of the conversation chains into the
      # document, and the browser's toolbar collapsing grows `dvh` past the body.
      # Neither can happen once the page itself cannot scroll.
      def test_the_page_itself_cannot_scroll
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        shell = css[/^html, body \{[^}]*\}/]
        thread = css[/^\.thread \{[^}]*\}/]

        refute_nil shell, "the html, body rule is missing from app.css"
        assert_match(/overflow: hidden;/, shell, "the document must not be a scroller")
        assert_match(/overscroll-behavior: none;/, shell, "and pull-to-refresh must not reload a running turn")
        assert_match(/overscroll-behavior-y: contain;/, thread,
                     "the momentum at the end of the thread stops at the thread")
      end

      # A phone's keys do not resize the layout viewport on every browser, and the
      # page cannot scroll to reveal the field any more — it is a page that never
      # scrolls, on purpose. So the shell ends where the keys begin: the browser
      # is asked to resize the layout viewport where it can, and app.js mirrors
      # the visible height into `--vvh` where it cannot.
      def test_the_field_climbs_above_the_keyboard
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))
        layout = File.read(File.expand_path("../lib/rubot/web/views/layout.erb", __dir__))

        assert_includes layout, "interactive-widget=resizes-content"
        assert_match(/height: var\(--vvh, 100dvh\);/, css[/^\.app \{[^}]*\}/],
                     "the shell has to take its height from the visible box")
        assert_includes js, "visualViewport"
        assert_includes js, "--vvh"
        assert_includes js, "view.scale > 1.01",
                        "a pinch-zoom shrinks the visual viewport too, and the shell must not follow it"
      end

      # `dvh` is a dynamic unit, and a browser is free to publish it before it
      # has settled the things that make it dynamic. Installed as an app it did:
      # opening a session laid the shell out at the height of a window that was
      # no longer there, and the field and the figures under it fell past the
      # bottom edge until the browser recounted — which touching the field did.
      # So the height is measured, always, and measured again once the browser
      # has had a paint to settle.
      def test_the_shell_measures_itself_rather_than_trusting_dvh
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, "function fitToViewport"
        assert_includes js, 'window.addEventListener("pageshow", fitToViewport)',
                        "a page back out of the cache was laid out for another window"
        assert_includes js, "requestAnimationFrame(fitToViewport)",
                        "a toolbar still moving at `load` reports its old height"
        refute_match(/KEYBOARD_SLACK/, js,
                     "a threshold is what let a viewport the shell had outgrown stand uncorrected")
      end

      # A phone keeps the browser's hover state on whatever was tapped last, so a
      # hover rule is a *stuck* rule there: the send button stayed filled green
      # until something else was touched, which read as a message still going.
      # Hover belongs to a pointer that can leave the button; the press is what a
      # finger gets instead.
      def test_the_send_button_does_not_stay_filled_after_a_tap
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        hover = css[/@media \(hover: hover\) \{\n(.*?)\n\}/m, 1]

        refute_nil hover, "the buttons' hover needs a pointer that can leave"
        assert_includes hover, ".btn.primary:hover"
        assert_includes hover, ".composer-stop:hover"

        elsewhere = css.sub(hover, "")
        refute_includes elsewhere, ".btn.primary:hover",
                        "a hover outside the query sticks to a tapped button"
        refute_includes elsewhere, ".composer-stop:hover"
        assert_includes elsewhere, ".btn.primary:active",
                        "the press has to answer on a screen with no hover"
      end


      # The page is drawn under the home indicator (`viewport-fit=cover`), so the
      # last row and the field sat inside that strip on a phone: the field ended
      # at the very edge of the screen, where a thumb rests. The inset belongs to
      # the column that holds them, and it is zero everywhere else.
      def test_a_phone_with_a_home_indicator_keeps_the_field_out_of_it
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        chat = css[/^\.chat \{[^}]*\}/]

        refute_nil chat, "the .chat rule is missing from app.css"
        assert_match(/padding-bottom: var\(--safe-bottom, env\(safe-area-inset-bottom, 0px\)\);/,
                     chat, "the bottom of the column has to clear the indicator")
        assert_match(/box-sizing: border-box/, css,
                     "the inset is only free if the height includes it")
      end

      # "Thinking…" and "Thought for 12s" are pauses in the work, and a pause
      # needs air on both sides: with no top margin the row sat hard against
      # the text above it, which made it look like the end of that sentence.
      def test_the_thinking_rows_have_room_above_and_below
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        rule = css[/^\.row\.thinking \{[^}]*\}/]

        refute_nil rule, "the .row.thinking rule is missing from app.css"

        margin = rule.match(/margin:\s*([\d.]+)rem\s+0\s+([\d.]+)rem/)

        refute_nil margin, "the thinking row needs a margin shorthand with a top value"
        assert_operator margin[1].to_f, :>, 0, "a thought needs room above it"
        assert_operator margin[2].to_f, :>, 0, "and room below it"
      end

      # The timeline carries no marks any more: a thought, a call and a seam say
      # what they have to say in words, and while they wait the words are what
      # moves. Only the row above the field keeps a drawn ring — a rotation
      # needs an arc with a gap in it, and no fallback glyph turns the same way
      # on two machines.
      def test_only_the_turn_that_is_running_still_carries_a_mark
        thinking = View.render("_timeline",
                               items: [ { kind: :thinking, epoch: 1.0, started_at: 0.0,
                                          closed_at: nil, elapsed: nil } ])
        working = View.render("_working", since: 1.0)
        running = View.render("_timeline",
                              items: [ { kind: :tool, name: "shell", detail: "ls",
                                         state: :running, epoch: 2.0, elapsed: 1.0 } ])
        done = View.render("_timeline",
                           items: [ { kind: :tool, name: "shell", detail: "ls",
                                      state: :ok, elapsed: 0.4 } ])
        seam = View.render("_timeline",
                           items: [ { kind: :compaction, epoch: 3.0 } ])

        assert_includes working, "mark-svg"
        refute_includes thinking, "mark", "the word is the row: no mark beside it"
        refute_includes running, "mark"
        refute_includes done, "✓", "a finished call says nothing with a glyph"
        refute_includes done, "mark"
        refute_includes seam, "mark"
      end

      # The live thought glows one letter at a time, so the word is drawn as one
      # span per letter carrying its own index. "Thought for 12s" is a fact
      # about the past, not a wait, and keeps a plain label.
      def test_the_live_thought_glows_one_letter_at_a_time
        thinking = View.render("_timeline",
                               items: [ { kind: :thinking, epoch: 1.0, started_at: 0.0,
                                          closed_at: nil, elapsed: nil } ])
        thought = View.render("_timeline",
                              items: [ { kind: :thinking, epoch: 1.0, started_at: 0.0,
                                         closed_at: 4.0, elapsed: 12.0 } ])

        assert_includes thinking, %(class="label glow")
        assert_equal 9, thinking.scan(/<span style="--i:\d+">/).size,
                     "one span per letter of \"Thinking…\""
        assert_includes thinking, %(<span style="--i:8">…</span>)
        assert_includes thinking, %(aria-label="Thinking…"),
                        "a screen reader should read the word, not the letters"

        refute_includes thought, "label glow"
      end

      # Motion belongs only where a redraw cannot restart it. The timeline is
      # rewritten on every chunk of an answer — twenty times a second — and a
      # redraw begins every animation in it again, so a thought is the row that
      # can carry one: it is drawn when the wait starts and nothing redraws it
      # until tokens arrive, which is when it is replaced anyway. A call row is
      # the same bargain: it changes when its clock does, and not before.
      def test_the_glow_travels_across_the_word
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        assert_match(/@keyframes label-glow/, css, "the glow keyframes are missing")
        assert_match(/\.row \.label\.glow span,\s*\.compaction-row \.compaction-label\.glow span,\s*\.tool-row \.tool-detail\.glow span \{[^}]*animation: label-glow/,
                     css, "the three waits wear the same light")
        assert_match(/animation-delay: calc\(var\(--i/, css, "each letter needs its own phase")
      end

      # A tenth of a second per letter is the pace "Thinking…" wants and the
      # wrong one for a sentence: the delay keeps counting past the two-second
      # cycle, so a long row came back round in the middle and lit two places at
      # once. The step is handed to the row instead, so any word crosses in the
      # same second and a half whatever its length.
      def test_the_sweep_takes_the_same_time_whatever_the_row_says
        thinking = View.render("_timeline",
                               items: [ { kind: :thinking, epoch: 1.0, started_at: 0.0,
                                          closed_at: nil, elapsed: nil } ])
        call = View.render("_timeline",
                           items: [ { kind: :tool, name: "shell",
                                      detail: "bundle exec rake test",
                                      state: :running, epoch: 2.0, elapsed: nil } ])
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        assert_includes thinking, %(style="--glow-step:0.167s")
        assert_operator call[/--glow-step:([\d.]+)s/, 1].to_f, :<, 0.167,
                        "a longer row gives each letter less of the light"
        assert_match(/animation-delay: calc\(var\(--i, 0\) \* var\(--glow-step, 0\.1s\)\)/, css)
      end

      # A row gets one thing that moves, and on a call it is the sentence: the
      # ring that used to sit beside it left with the rest of the marks, and the
      # light travels the words instead. Only while the call is open — a page of
      # settled rows all glowing is a page with nothing to look at — and the
      # sweep across the whole row stays gone: two motions saying "still
      # running" was one too many, and a ring plus a light is the same mistake
      # in the other order.
      def test_an_open_call_moves_once_and_a_settled_one_keeps_still
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        running = View.render("_timeline",
                              items: [ { kind: :tool, name: "shell", detail: "ls",
                                         state: :running, epoch: 2.0, elapsed: 1.0 } ])
        settled = View.render("_timeline",
                              items: [ { kind: :tool, name: "shell", detail: "ls",
                                         state: :ok, elapsed: 1.0 } ])
        failed = View.render("_timeline",
                             items: [ { kind: :tool, name: "shell", detail: "ls",
                                        state: :failed, elapsed: 1.0 } ])

        assert_includes running, "tool-detail glow", "the words are the row's motion"
        refute_includes running, "mark-svg", "the ring went with the marks"
        refute_includes settled, "glow", "a call that settled stops moving"
        refute_includes failed, "glow", "and a call that failed is red, not lit"
        refute_match(/@keyframes tool-sweep/, css, "the sweep is gone")
        refute_match(/\.tool-row\.running::after/, css)
      end

      # The newest call keeps its light after it returns, so a page watched
      # mid-turn has one row alive rather than none: the turn says so with
      # `awake`, and the row that carries it glows as if it were still open.
      def test_a_settled_call_that_the_turn_still_holds_glows
        awake = View.render("_timeline",
                            items: [ { kind: :tool, name: "shell", detail: "ls",
                                       state: :ok, elapsed: 1.0, awake: true } ])

        assert_includes awake, "tool-detail glow"
        assert_includes awake, %(aria-label="ls"), "the split letters still read as a row"
      end

      # A turn redraws its whole timeline on every event, so the call row is a
      # new node each time and an animation written straight onto the stylesheet
      # would replay on every stream tick. The row therefore carries its own age
      # — as a negative animation-delay, which seeks the fresh node to the frame
      # the last one had reached — and the class that names the animation.
      def test_a_swapped_call_row_can_say_how_long_it_has_been_here
        fresh = View.render("_timeline",
                            items: [ { kind: :tool, name: "shell", detail: "ls",
                                       state: :ok, elapsed: 1.0, swap_ms: 0 } ])
        mid = View.render("_timeline",
                          items: [ { kind: :tool, name: "shell", detail: "ls",
                                     state: :ok, elapsed: 1.0, swap_ms: 120 } ])
        settled = View.render("_timeline",
                              items: [ { kind: :tool, name: "shell", detail: "ls",
                                         state: :ok, elapsed: 1.0 } ])
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes fresh, 'data-tool-key="shell·ls"'
        assert_includes fresh, "is-swapped"
        assert_includes fresh, 'style="animation-delay: -0ms"'
        assert_includes mid, 'style="animation-delay: -120ms"',
                        "each redraw resumes the fade where the last frame was"
        refute_includes settled, "is-swapped", "a row past the fade is left alone"
        refute_includes settled, "animation-delay"
        assert_match(/\.tool-row\.is-swapped \{ animation: tool-row-swap/, css)
        refute_includes js, "is-swapped",
                        "the browser does not guess: the server sends the age"
      end

      # The age is the turn's to know: it is the only place that remembers what
      # the timeline showed a moment ago, since every redraw throws the nodes
      # away. So a call row that has just arrived is marked as arriving, keeps
      # the mark while the fade lasts — through its own state change, which is
      # not an arrival — and loses it afterwards.
      def test_a_fresh_call_row_carries_the_age_of_its_fade
        now = 100.0
        turn = Turn.new(id: "t1", session_id: "s1", clock: -> { now }, epoch_clock: -> { now })

        turn.tool_started("shell_exec", "ls")
        assert_equal 0, turn.items.last[:swap_ms]

        now += 0.05
        turn.tool_finished("shell_exec", true)
        assert_equal 50, turn.items.last[:swap_ms],
                     "the same call turning ok does not start the fade over"

        now += 0.2
        assert_equal 250, turn.items.last[:swap_ms],
                     "the age is measured from when the call was made, not redrawn"

        now += 0.1
        assert_nil turn.items.last[:swap_ms], "past the fade, the row is left alone"

        turn.tool_started("file_ops", "a.rb", op: "edit")
        assert_equal 0, turn.items.last[:swap_ms], "the next call starts its own fade"
        assert_equal 1, turn.items.count { |item| item[:kind] == :tool && item[:swap_ms] },
                     "and only itself: the call that came before stays put"
      end

      # A call the model answered in words only earns its row when the next
      # call arrives. Its fade is measured from when it was made, not from when
      # it appeared, so an old row does not blink back to life on every redraw.
      def test_a_call_revealed_later_does_not_restart_its_fade
        now = 100.0
        turn = Turn.new(id: "t1", session_id: "s1", tool_output: "compact",
                        clock: -> { now }, epoch_clock: -> { now })

        turn.tool_started("file_ops", "a.rb")
        turn.tool_finished("file_ops", true)
        turn.append_chunk("Isi a.rb sudah kubaca.")
        now += 1.0
        turn.tool_started("file_ops", "b.rb")
        turn.tool_finished("file_ops", true)

        rows = turn.items.select { |item| item[:kind] == :tool }
        assert_equal %w[a.rb b.rb], rows.map { |item| item[:detail] }
        assert_nil rows.first[:swap_ms], "the old call stays put"
        assert_equal 0, rows.last[:swap_ms], "only the new call fades in"
      end

      # A row says what the file tool did inside one sentence, without the
      # tool's own name in front of it: the name alone cannot tell a read from
      # a write, and a chip beside the sentence repeated what it already said.
      def test_a_file_tool_row_says_what_it_did_in_its_sentence
        edited = View.render("_timeline",
                             items: [ { kind: :tool, name: "file_ops",
                                        detail: ToolCaption.caption("file_ops",
                                                                    { "operation" => "edit", "path" => "lib/a.rb" }),
                                        op: "edit", state: :ok, elapsed: nil } ])
        assert_includes edited, "Editing lib/a.rb"
        assert_includes edited, %(<span class="tool-detail">Editing lib/a.rb</span>),
                        "the sentence is the row's own text"
        refute_includes edited, "tool-op", "the operation is part of the sentence, not a chip"
        refute_includes edited, "tool-name", "the tool's name is not the reader's word for it"

        plain = View.render("_timeline",
                            items: [ { kind: :tool, name: "shell_exec", detail: "Ran a command in the terminal",
                                       state: :ok, elapsed: nil } ])
        assert_includes plain, "Ran a command in the terminal"
      end

      # The thought is a word and nothing else. The half disc that used to sit
      # beside it was a state that never moved, which beside a word already
      # moving is a second thing asking to be read. A finished thought is a fact
      # about the past, so it keeps a plain label: no light, no mark.
      def test_a_thought_is_its_word_and_nothing_else
        thinking = View.render("_timeline",
                               items: [ { kind: :thinking, epoch: 1.0, started_at: 0.0,
                                          closed_at: nil, elapsed: nil } ])
        thought = View.render("_timeline",
                              items: [ { kind: :thinking, epoch: 1.0, started_at: 0.0,
                                         closed_at: 4.0, elapsed: 12.0 } ])

        assert_includes thinking, "label glow", "the word is what moves here"
        refute_includes thinking, "mark"
        assert_includes thought, "Thought for 12s"
        refute_includes thought, "glow", "a finished thought must not keep glowing"
        refute_includes thought, "mark"
      end

      # Spinning a full ring would look exactly like a still ring, so a mark that
      # turns is an arc: the gap is what the eye reads as motion. Only the turn
      # that is running wears one — the thought and a compaction in progress
      # both wear the still half disc, so they are not checked here.
      def test_a_mark_that_turns_is_an_arc
        working = View.render("_working", since: 1.0)
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        assert_includes working, "stroke-dasharray", "a full ring cannot show that it turns"
        assert_match(/@keyframes mark-spin/, css, "the spin keyframes are missing")
        assert_match(/\.mark \.mark-svg\.spin \{[^}]*animation: mark-spin/,
                     css, "the live mark has to be the one that turns")
      end

      # The seam usually lands under the tool call that was running when the
      # summarizer took over. The tool row keeps 0.4rem under itself and
      # .turn-body is a flex column, so the two rows would sit 6px apart and
      # read as one block of log. The seam takes the paragraph's air instead.
      def test_a_compaction_seam_gives_way_from_the_tool_row_above_it
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        # Same declaration as the thought, so the two pauses stay the same
        # distance under the call that came before them.
        assert_match(/\.tool-row \+ \.row\.thinking,\s*\.tool-row \+ \.compaction-row \{[^}]*margin-top/,
                     css, "the seam must share the thought's room under a tool row")
      end

      # Centring is the box's job: the mark has no baseline to sit on, so the
      # row centres it instead, and a square box means the drawing's own centre
      # is the box's centre. Without the square, a wider mark would drift.
      def test_the_round_marks_are_centred_by_a_square_box
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        row = css[/^\.row \{[^}]*\}/m]
        refute_nil row, "the .row rule is missing from app.css"
        assert_includes row, "align-items: center"

        mark = css[/^\.row \.mark \{[^}]*\}/m]
        refute_nil mark, "the .row .mark rule is missing from app.css"
        assert_includes mark, "width: 0.8em"
        assert_includes mark, "height: 0.8em"
      end


      # A picture already in the conversation's folder, named the way the
      # channel names what it serves.
      # A file in a conversation's folder, named the way the channel writes
      # names: an id in front, the reader's own name behind it.
    end
  end
end
