# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"

module Rubot
  # Pulls an image off the system clipboard and parks it in a temp file.
  #
  # A terminal never delivers an image through a paste: the clipboard carries
  # pixels, the terminal only forwards text. So the TUI asks the desktop for
  # the clipboard itself. Whatever it finds is written to a file, and the
  # path is what the model gets -- the same "attached an image" line the
  # Telegram channel produces for a photo.
  #
  # Temp files live in the system temp directory, never in the session
  # directory: they are scratch input, not conversation history, and a
  # screenshot left behind in a session would be copied into every resume of
  # it. Old ones are pruned on every write.
  module ClipboardImage
    # Every file this module writes starts with this, which is what makes
    # pruning them safe: nothing else in the temp directory matches.
    PREFIX = "rubot-paste-"
    # A screenshot the user pasted this morning is not worth keeping, and the
    # temp directory is not ours to fill.
    MAX_AGE = 6 * 60 * 60
    MAX_FILES = 40

    # Raster formats first: ImageInfo can read their dimensions, and a model
    # reading a PNG is more reliable than a model reading an SVG sent as a
    # clipboard image.
    PREFERRED = %w[
      image/png image/jpeg image/jpg image/webp image/gif image/bmp
    ].freeze

    module_function

    # Write everything the clipboard holds as images to temp files, in the
    # order the clipboard lists them.
    #
    # A clipboard carries one bitmap at a time, but a file manager hands over
    # a `text/uri-list` with every file that was selected, so "copy three
    # screenshots and paste" arrives here as three paths.
    #
    # @return [Array<String>] paths of the new files; empty when the
    #   clipboard holds no image (or no clipboard tool is available)
    def capture_all(dir: nil)
      paths = copy_uris(dir: dir)
      return paths unless paths.empty?

      found = read_bytes
      return [] unless found

      bytes, extension = found
      return [] if bytes.nil? || bytes.empty?

      path = save(bytes, extension, dir: dir)
      path ? [ path ] : []
    rescue StandardError
      []
    end

    # The first image on the clipboard, for callers that take one.
    def capture(dir: nil)
      capture_all(dir: dir).first
    end

    # The clipboard as text, for the fallback path: a terminal without
    # bracket-aware paste still gets a working paste key.
    def text
      if wayland? && executable?("wl-paste")
        out, status = run("wl-paste", "--no-newline")
        return out if status && !out.empty?
      end
      return nil unless ENV["DISPLAY"].to_s != "" && executable?("xclip")

      out, status = run("xclip", "-selection", "clipboard", "-o")
      status && !out.empty? ? out : nil
    rescue StandardError
      nil
    end

    # --- platform readers --------------------------------------------------

    # Files copied from a file manager arrive as a list of file:// URIs.
    # Each image in that list is copied into the temp directory, so the
    # paste survives the source being moved or deleted afterwards.
    def copy_uris(dir: nil)
      list = uri_list
      return [] if list.nil?

      list.split("\n")
          .map(&:strip)
          .reject { |line| line.empty? || line.start_with?("#") }
          .map { |uri| local_path(uri) }
          .compact
          .select { |path| image_file?(path) }
          .filter_map { |path| copy(path, dir: dir) }
    rescue StandardError
      []
    end

    def uri_list
      if wayland? && executable?("wl-paste")
        types, status = run("wl-paste", "--list-types")
        if status && types.to_s.include?("text/uri-list")
          out, ok = run("wl-paste", "--type", "text/uri-list", "--no-newline")
          return out.dup.force_encoding(Encoding::UTF_8) if ok && !out.empty?
        end
      end

      return nil unless ENV["DISPLAY"].to_s != "" && executable?("xclip")

      out, ok = run("xclip", "-selection", "clipboard", "-t", "text/uri-list", "-o")
      ok && !out.empty? ? out.dup.force_encoding(Encoding::UTF_8) : nil
    rescue StandardError
      nil
    end

    # file:///tmp/a%20b.png -> /tmp/a b.png. Anything that is not a local
    # file URI (an http URL, a mailto) is not ours to copy.
    def local_path(uri)
      return nil unless uri.to_s.start_with?("file://")

      raw = uri.sub(%r{\Afile://}, "")
      # file://host/path carries a host; a local one is empty or "localhost".
      raw = raw.sub(%r{\Alocalhost/}, "/")
      return nil unless raw.start_with?("/")

      decoded = raw.b.gsub(/%([0-9A-Fa-f]{2})/n) { [ Regexp.last_match(1) ].pack("H2") }
      decoded.force_encoding(Encoding::UTF_8)
    end

    IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .webp .gif .bmp .tif .tiff .svg].freeze

    def image_file?(path)
      return false unless File.file?(path)

      IMAGE_EXTENSIONS.include?(File.extname(path).downcase)
    end

    # Same naming and pruning rules as a raw clipboard bitmap, so one sweep
    # clears both kinds.
    def copy(path, dir: nil)
      dir ||= Dir.tmpdir
      FileUtils.mkdir_p(dir)
      prune(dir)

      stamp = Time.now.strftime("%Y%m%d-%H%M%S")
      name = "#{PREFIX}#{stamp}-#{format('%<n>04d', n: rand(10_000))}#{File.extname(path).downcase}"
      dest = File.join(dir, name)
      FileUtils.cp(path, dest)
      dest
    rescue SystemCallError
      nil
    end

    def read_bytes
      found = wayland_image || x11_image || macos_image
      return nil unless found

      mime, bytes = found
      [ bytes, extension_for(mime) ]
    end

    def wayland_image
      return nil unless wayland? && executable?("wl-paste")

      types, status = run("wl-paste", "--list-types")
      return nil unless status

      mime = image_type(types)
      return nil unless mime

      bytes, ok = run("wl-paste", "--type", mime, "--no-newline")
      ok && !bytes.empty? ? [ mime, bytes ] : nil
    end

    def x11_image
      return nil unless ENV["DISPLAY"].to_s != "" && executable?("xclip")

      targets, status = run("xclip", "-selection", "clipboard", "-t", "TARGETS", "-o")
      return nil unless status

      mime = image_type(targets)
      return nil unless mime

      bytes, ok = run("xclip", "-selection", "clipboard", "-t", mime, "-o")
      ok && !bytes.empty? ? [ mime, bytes ] : nil
    end

    # macOS has no clipboard-to-stdout tool in the base system, but pngpaste
    # is a one-liner install and returns the PNG on stdout with "-".
    def macos_image
      return nil unless executable?("pngpaste")

      bytes, ok = run("pngpaste", "-")
      ok && !bytes.empty? ? [ "image/png", bytes ] : nil
    end

    def wayland?
      ENV["WAYLAND_DISPLAY"].to_s != ""
    end

    # Pick the type to ask for out of a clipboard type list. Preferred
    # formats win regardless of order; anything else image/* is a fallback
    # so an unusual clipboard still works.
    def image_type(types)
      list = types.to_s.split("\n").map(&:strip).reject(&:empty?)
      images = list.select { |type| type.start_with?("image/") }
      return nil if images.empty?

      PREFERRED.find { |mime| images.include?(mime) } || images.first
    end

    def extension_for(mime)
      case mime.to_s
      when "image/png"        then ".png"
      when "image/jpeg",
           "image/jpg"        then ".jpg"
      when "image/webp"       then ".webp"
      when "image/gif"        then ".gif"
      when "image/bmp"        then ".bmp"
      when "image/svg+xml"    then ".svg"
      else                         ".png"
      end
    end

    # --- files -------------------------------------------------------------

    def save(bytes, extension, dir: nil)
      dir ||= Dir.tmpdir
      FileUtils.mkdir_p(dir)
      prune(dir)

      stamp = Time.now.strftime("%Y%m%d-%H%M%S")
      path = File.join(dir, "#{PREFIX}#{stamp}-#{format('%<n>04d', n: rand(10_000))}#{extension}")
      File.binwrite(path, bytes)
      path
    rescue SystemCallError
      nil
    end

    # Best effort: a failed prune must never cost the user their paste.
    def prune(dir, now: Time.now)
      stale = Dir.glob(File.join(dir, "#{PREFIX}*")).select do |path|
        age = now - (File.mtime(path) rescue now)
        age > MAX_AGE
      end
      stale.each { |path| FileUtils.rm_f(path) }

      kept = Dir.glob(File.join(dir, "#{PREFIX}*")).sort_by { |path| File.mtime(path) rescue now }
      kept[0...-MAX_FILES].to_a.each { |path| FileUtils.rm_f(path) }
    rescue StandardError
      nil
    end

    # --- processes ---------------------------------------------------------

    def executable?(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, name)
        File.file?(path) && File.executable?(path)
      end
    end

    # Returns [output, success]. Output is binary so a PNG survives intact;
    # a clipboard tool that hangs must not hang the TUI, so every call is
    # bounded.
    def run(*command)
      out, _err, status = Open3.capture3(*command)
      [ out.dup.force_encoding(Encoding::BINARY), status.success? ]
    rescue StandardError
      [ "".b, false ]
    end
  end
end
