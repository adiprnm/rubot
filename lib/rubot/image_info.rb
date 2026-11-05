# frozen_string_literal: true

module Rubot
  # Reads image dimensions straight from file headers.
  #
  # Cheaper than shelling out to `magick identify` for every file Telegram
  # sends. Only the first few hundred bytes of the file are read, which is
  # enough for every format Telegram sends.
  #
  # Returns nil for anything that is not a recognised image, so callers can
  # print the size without a dimension and keep going.
  module ImageInfo
    # JPEG SOF markers live after the EXIF/APP segments, so allow a generous
    # header window without reading the whole file.
    MAX_HEADER_BYTES = 256 * 1024

    module_function

    # @return [Hash, nil] { width:, height:, format: } or nil when unknown
    def probe(path)
      header = read_header(path)
      return nil unless header

      case header
      when /\A\x89PNG\r\n\x1A\n/n then png(header)
      when /\AGIF8[79]a/n       then gif(header)
      when /\A\xFF\xD8/n        then jpeg(header)
      when /\ARIFF....WEBP/n    then webp(header)
      end
    rescue StandardError
      nil
    end

    # Human-readable form used in prompts, e.g. "1920×1080".
    def dimensions(path)
      info = probe(path)
      return nil unless info

      "#{info[:width]}×#{info[:height]}"
    end

    def read_header(path)
      File.open(path, "rb") { |f| f.read(MAX_HEADER_BYTES) }
    rescue StandardError
      nil
    end

    def png(data)
      return nil unless data.byteslice(12, 4) == "IHDR"

      width, height = data.byteslice(16, 8).unpack("N2")
      return nil unless width.positive? && height.positive?

      { width: width, height: height, format: "png" }
    end

    def gif(data)
      width, height = data.byteslice(6, 4).unpack("v2")
      return nil unless width.positive? && height.positive?

      { width: width, height: height, format: "gif" }
    end

    # Walks the JPEG segment chain until a Start-Of-Frame marker appears.
    def jpeg(data)
      offset = 2
      while offset + 9 < data.bytesize
        return nil unless data.getbyte(offset) == 0xFF

        marker = data.getbyte(offset + 1)
        # Standalone markers carry no length field.
        if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)
          offset += 2
          next
        end

        length = data.byteslice(offset + 2, 2).unpack1("n")
        return nil if length.nil? || length < 2

        if sof_marker?(marker)
          height, width = data.byteslice(offset + 5, 4).unpack("n2")
          return nil unless width.to_i.positive? && height.to_i.positive?

          return { width: width, height: height, format: "jpeg" }
        end

        offset += 2 + length
      end
      nil
    end

    def sof_marker?(marker)
      [ 0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
        0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF ].include?(marker)
    end

    def webp(data)
      chunk = data.byteslice(12, 4)

      case chunk
      when "VP8X"
        width = little_endian_uint24(data.byteslice(24, 3)) + 1
        height = little_endian_uint24(data.byteslice(27, 3)) + 1
      when "VP8L"
        bits = data.byteslice(21, 4).unpack1("V")
        return nil unless bits

        width = (bits & 0x3FFF) + 1
        height = ((bits >> 14) & 0x3FFF) + 1
      when "VP8 "
        width, height = data.byteslice(26, 4).unpack("v2")
        width &= 0x3FFF
        height &= 0x3FFF
      else
        return nil
      end

      return nil unless width.to_i.positive? && height.to_i.positive?

      { width: width, height: height, format: "webp" }
    end

    def little_endian_uint24(bytes)
      return 0 unless bytes && bytes.bytesize == 3

      b0, b1, b2 = bytes.unpack("C3")
      b0 | (b1 << 8) | (b2 << 16)
    end
  end
end
