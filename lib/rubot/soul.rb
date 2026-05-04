# frozen_string_literal: true

module Rubot
  # Manages SOUL.md — the bot's personality and identity.
  # A freeform Markdown file describing who the bot is, its values,
  # communication style, and character traits.
  #
  # Loaded from workspace/SOUL.md and injected into the system prompt.
  class Soul
    attr_reader :content, :file_path

    # Default soul content when no SOUL.md exists
    DEFAULT_SOUL = <<~SOUL.freeze
      # Soul

      You are Rubot, a helpful AI assistant running in the terminal.

      You are written in Ruby, using only the standard library.
      You value simplicity, clarity, and pragmatism.

      You communicate concisely and directly.
      You prefer small, composable solutions over complex architectures.
    SOUL

    def initialize(workspace: nil)
      @workspace = workspace
      @file_path = workspace ? File.join(workspace, "SOUL.md") : nil
      @content = load_content
    end

    # Returns the soul content, or nil if no soul is configured
    def to_s
      @content
    end

    def enabled?
      !@content.nil? && !@content.empty?
    end

    # Write a new soul file
    def write(content)
      return unless @file_path
      File.write(@file_path, content)
      @content = content
    end

    private

    def load_content
      return nil unless @file_path && File.exist?(@file_path)
      File.read(@file_path)
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end
  end
end
