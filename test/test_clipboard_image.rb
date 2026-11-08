# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  class TestClipboardImage < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
    end

    def teardown
      FileUtils.remove_entry(@dir) if File.directory?(@dir)
    end

    def png_bytes
      "\x89PNG\r\n\x1A\n".b + "\x00\x00\x00\x00".b
    end

    # Every reader shells out to a desktop tool; the parse and file paths are
    # what the tests drive, with the reading stubbed.
    def stub_readers(found)
      original = ClipboardImage.method(:read_bytes)
      ClipboardImage.define_singleton_method(:read_bytes) { found }
      yield
    ensure
      ClipboardImage.define_singleton_method(:read_bytes, original)
    end

    def test_a_preferred_format_wins_over_the_first_one_listed
      types = "text/plain\nimage/svg+xml\nimage/png\n"
      assert_equal "image/png", ClipboardImage.image_type(types)
    end

    def test_an_unusual_image_type_is_still_used
      assert_equal "image/tiff", ClipboardImage.image_type("text/plain\nimage/tiff")
    end

    def test_a_clipboard_without_an_image_is_ignored
      assert_nil ClipboardImage.image_type("text/plain\nUTF8_STRING")
      assert_nil ClipboardImage.image_type("")
    end

    def test_extension_follows_the_mime_type
      assert_equal ".png", ClipboardImage.extension_for("image/png")
      assert_equal ".jpg", ClipboardImage.extension_for("image/jpeg")
      assert_equal ".png", ClipboardImage.extension_for("image/x-unknown")
    end

    def test_capture_writes_the_bytes_to_a_temp_file
      path = nil
      stub_readers([ png_bytes, ".png" ]) do
        path = ClipboardImage.capture(dir: @dir)
      end

      refute_nil path
      assert_equal @dir, File.dirname(path)
      assert_match(/\A#{Regexp.escape(ClipboardImage::PREFIX)}/, File.basename(path))
      assert_equal png_bytes, File.binread(path)
    end

    def test_files_land_in_the_system_temp_dir_by_default
      path = nil
      stub_readers([ png_bytes, ".png" ]) { path = ClipboardImage.capture }
      refute_nil path
      assert_equal File.realpath(Dir.tmpdir), File.realpath(File.dirname(path))
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    def test_an_empty_clipboard_saves_nothing
      stub_readers(nil) { assert_nil ClipboardImage.capture(dir: @dir) }
      stub_readers([ "".b, ".png" ]) { assert_nil ClipboardImage.capture(dir: @dir) }
      assert_empty Dir.glob(File.join(@dir, "#{ClipboardImage::PREFIX}*"))
    end

    def test_prune_drops_stale_files_and_keeps_fresh_ones
      stale = File.join(@dir, "#{ClipboardImage::PREFIX}old.png")
      fresh = File.join(@dir, "#{ClipboardImage::PREFIX}new.png")
      other = File.join(@dir, "somebody-elses.png")
      File.binwrite(stale, png_bytes)
      File.binwrite(fresh, png_bytes)
      File.binwrite(other, png_bytes)

      old = Time.now - ClipboardImage::MAX_AGE - 60
      File.utime(old, old, stale)

      ClipboardImage.prune(@dir)

      refute File.exist?(stale)
      assert File.exist?(fresh)
      # Only our own files are ever touched.
      assert File.exist?(other)
    end

    def test_prune_keeps_the_newest_files_when_there_are_too_many
      count = ClipboardImage::MAX_FILES + 5
      count.times do |i|
        path = File.join(@dir, "#{ClipboardImage::PREFIX}%03d.png" % i)
        File.binwrite(path, png_bytes)
        stamp = Time.now - (count - i)
        File.utime(stamp, stamp, path)
      end

      ClipboardImage.prune(@dir)

      left = Dir.glob(File.join(@dir, "#{ClipboardImage::PREFIX}*")).sort
      assert_equal ClipboardImage::MAX_FILES, left.length
      assert_includes left, File.join(@dir, "#{ClipboardImage::PREFIX}%03d.png" % (count - 1))
    end

    # --- several files at once ---------------------------------------------

    def test_a_file_uri_is_decoded_to_a_local_path
      assert_equal "/tmp/a b.png", ClipboardImage.local_path("file:///tmp/a%20b.png")
      assert_equal "/tmp/x.png", ClipboardImage.local_path("file://localhost/tmp/x.png")
      assert_nil ClipboardImage.local_path("https://example.com/x.png"),
                 "a remote URL is not ours to copy"
      assert_nil ClipboardImage.local_path("file://host/tmp/x.png")
    end

    def test_a_uri_list_becomes_one_temp_file_per_image
      source = File.join(@dir, "source")
      FileUtils.mkdir_p(source)
      a = File.join(source, "a.png")
      b = File.join(source, "b.jpg")
      note = File.join(source, "notes.txt")
      [ a, b ].each { |path| File.binwrite(path, png_bytes) }
      File.write(note, "not an image")

      list = [ a, b, note ].map { |path| "file://#{path}" }.join("\r\n")

      stub_uri_list(list) do
        paths = ClipboardImage.copy_uris(dir: @dir)
        assert_equal 2, paths.length, "the text file in the selection is skipped"
        assert_equal png_bytes, File.binread(paths[0])
        assert paths.all? { |path| path.end_with?(".png") || path.end_with?(".jpg") }
        assert paths.all? { |path| File.basename(path).start_with?(ClipboardImage::PREFIX) },
               "copies are named like any other paste, so one prune clears them"
      end
    end

    def test_capture_all_falls_back_to_the_bitmap_when_there_is_no_uri_list
      stub_uri_list(nil) do
        stub_readers([ png_bytes, ".png" ]) do
          assert_equal 1, ClipboardImage.capture_all(dir: @dir).length
        end
      end
    end

    def test_capture_all_is_empty_when_the_clipboard_holds_no_image
      stub_uri_list(nil) do
        stub_readers(nil) { assert_empty ClipboardImage.capture_all(dir: @dir) }
      end
    end

    def stub_uri_list(list)
      original = ClipboardImage.method(:uri_list)
      ClipboardImage.define_singleton_method(:uri_list) { list }
      yield
    ensure
      ClipboardImage.define_singleton_method(:uri_list, original)
    end
  end
end
