# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  class TestImageInfo < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
    end

    def teardown
      FileUtils.remove_entry(@dir) if File.directory?(@dir)
    end

    def write(name, bytes)
      path = File.join(@dir, name)
      File.binwrite(path, bytes)
      path
    end

    def png_bytes(width, height)
      ihdr = [ width, height, 8, 2, 0, 0, 0 ].pack("N2C5")
      "\x89PNG\r\n\x1A\n".b + [ 13 ].pack("N") + "IHDR" + ihdr + [ 0 ].pack("N")
    end

    def gif_bytes(width, height)
      "GIF89a".b + [ width, height ].pack("v2") + "\x00\x00\x00".b
    end

    # Minimal JPEG: SOI, an APP0 segment that must be skipped, then SOF0.
    def jpeg_bytes(width, height)
      app0 = "\xFF\xE0".b + [ 16 ].pack("n") + ("JFIF\x00".b + "\x00" * 9)
      sof0 = "\xFF\xC0".b + [ 17 ].pack("n") + "\x08".b + [ height, width ].pack("n2") + "\x03".b + ("\x00" * 9)
      "\xFF\xD8".b + app0 + sof0 + "\xFF\xD9".b
    end

    def webp_vp8x_bytes(width, height)
      data = "RIFF".b + [ 30 ].pack("V") + "WEBP".b + "VP8X".b + [ 10 ].pack("V") + ("\x00" * 4)
      data += uint24(width - 1) + uint24(height - 1)
      data
    end

    def uint24(value)
      [ value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF ].pack("C3")
    end

    def test_probes_png
      info = ImageInfo.probe(write("a.png", png_bytes(1864, 1200)))
      assert_equal({ width: 1864, height: 1200, format: "png" }, info)
    end

    def test_probes_gif
      info = ImageInfo.probe(write("a.gif", gif_bytes(320, 240)))
      assert_equal({ width: 320, height: 240, format: "gif" }, info)
    end

    def test_probes_jpeg_and_skips_app_segments
      info = ImageInfo.probe(write("a.jpg", jpeg_bytes(1080, 1920)))
      assert_equal({ width: 1080, height: 1920, format: "jpeg" }, info)
    end

    def test_probes_webp_vp8x
      info = ImageInfo.probe(write("a.webp", webp_vp8x_bytes(1200, 630)))
      assert_equal({ width: 1200, height: 630, format: "webp" }, info)
    end

    def test_returns_nil_for_non_image
      assert_nil ImageInfo.probe(write("a.txt", "just text, no magic bytes"))
    end

    def test_returns_nil_for_missing_file
      assert_nil ImageInfo.probe(File.join(@dir, "nope.png"))
    end

    def test_returns_nil_for_truncated_png
      assert_nil ImageInfo.probe(write("t.png", "\x89PNG\r\n\x1A\n".b))
    end

    def test_dimensions_string
      assert_equal "1864×1200", ImageInfo.dimensions(write("a.png", png_bytes(1864, 1200)))
    end
  end
end
