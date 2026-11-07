# frozen_string_literal: true

require "tui"

module Rubot
  class TUI
    # One-row strip between the prompt box and the usage footer: the
    # directory rubot was launched from, followed by the current git branch
    # when there is one. The home directory is abbreviated to `~` so the path
    # keeps as much room as possible before the line truncates.
    class WorkspaceLine < ::TUI::Component
      BRANCH_MARK = "@"

      attr_reader :directory

      def initialize
        super
        @directory = ""
        @display = ""
        @head_path = nil
        @head_mtime = nil
        @branch = nil
      end

      def workspace=(path)
        @directory = File.expand_path(path.to_s)
        @display = abbreviate(@directory)
        @head_path = find_head(@directory)
        @head_mtime = head_mtime
        @branch = read_branch(@head_path)
        self
      end

      # The text the row renders: the directory, then the branch if the
      # directory (or one of its parents) is a git work tree.
      def label
        refresh_branch
        @branch ? "#{@display} #{BRANCH_MARK} #{@branch}" : @display
      end

      def measure(_max_w, _max_h)
        [ 10, 1 ]
      end

      def render(canvas)
        return self if @display.empty?

        text = ::TUI::Text.truncate(label, @rect.w)
        canvas.put(@rect.x, @rect.y, text, :dim)
        self
      end

      private

      def abbreviate(path)
        home = Dir.home
        return path if home.nil? || home.empty?

        path.sub(/\A#{Regexp.escape(home)}(?=\/|\z)/, "~")
      rescue ArgumentError
        path
      end

      # Re-read HEAD only when it changes, so a `git checkout` during the
      # session shows up without a file read on every frame.
      def refresh_branch
        mtime = head_mtime
        return if mtime == @head_mtime

        @head_mtime = mtime
        @branch = read_branch(@head_path)
      end

      def head_mtime
        @head_path ? File.mtime(@head_path) : nil
      rescue SystemCallError
        nil
      end

      def find_head(dir)
        path = File.expand_path(dir)
        loop do
          git = File.join(path, ".git")
          head = if File.directory?(git)
            File.join(git, "HEAD")
          elsif File.file?(git)
            worktree_head(git)
          end
          return head if head && File.file?(head)

          parent = File.dirname(path)
          return nil if parent == path

          path = parent
        end
      end

      # A linked worktree (or submodule) has a `.git` file instead of a
      # directory: "gitdir: /path/to/repo/.git/worktrees/<name>".
      def worktree_head(git_file)
        match = File.read(git_file).match(/\Agitdir:\s*(.+?)\s*\z/)
        return nil unless match

        File.join(File.expand_path(match[1], File.dirname(git_file)), "HEAD")
      rescue SystemCallError
        nil
      end

      # "ref: refs/heads/main" -> "main"; a detached HEAD -> the short SHA.
      def read_branch(head_path)
        return nil unless head_path

        content = File.read(head_path).strip
        if content.start_with?("ref: ")
          ref = content.delete_prefix("ref: ").delete_prefix("refs/heads/")
          ref.empty? ? nil : ref
        elsif content.match?(/\A[0-9a-f]{40}\z/i)
          content[0, 7]
        end
      rescue SystemCallError
        nil
      end
    end
  end
end
