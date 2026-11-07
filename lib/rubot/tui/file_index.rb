# frozen_string_literal: true

module Rubot
  class TUI
    # The source of the @-mention palette: every file and directory under a
    # root (the working directory by default) as paths relative to it. The
    # tree is walked once per menu session and then filtered in memory, so
    # typing after the "@" does not hit the disk again.
    class FileIndex
      # Heavy or generated trees nobody wants to scroll past.
      SKIP_DIRS = %w[.bundle .git .rubot .sass-cache build coverage
                     node_modules target tmp vendor].freeze
      MAX_DEPTH = 6
      LIMIT = 2000

      def initialize(root = nil)
        @root = root
        @entries = nil
      end

      def root
        @root || Dir.pwd
      end

      # Force a fresh walk, e.g. when the palette is opened again after files
      # were created or removed.
      def refresh
        @entries = nil
        self
      end

      def entries
        @entries ||= scan
      end

      # Directories carry a trailing "/" so the palette can walk into them,
      # and paths that start with what was typed come first.
      def matches(token)
        needle = token.to_s.downcase
        list = needle.empty? ? entries : entries.select { |entry| entry.downcase.include?(needle) }
        list.sort_by { |entry| [ entry.downcase.start_with?(needle) ? 0 : 1, entry.count("/"), entry ] }
            .first(LIMIT)
      end

      private

      def scan
        dir = root
        return [] unless File.directory?(dir)

        out = []
        walk(dir, nil, out, 0)
        out
      end

      def walk(dir, rel, out, depth)
        return if depth > MAX_DEPTH || out.length >= LIMIT

        children = begin
          Dir.children(dir).sort
        rescue StandardError
          []
        end

        children.each do |name|
          break if out.length >= LIMIT
          next if name.start_with?(".")

          path = rel ? "#{rel}/#{name}" : name
          full = File.join(dir, name)
          if File.directory?(full)
            next if SKIP_DIRS.include?(name)

            out << "#{path}/"
            walk(full, path, out, depth + 1)
          else
            out << path
          end
        end
      end
    end
  end
end
