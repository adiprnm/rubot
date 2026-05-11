# frozen_string_literal: true

module Rubot
  # Converts standard Markdown to Telegram MarkdownV2 format.
  #
  # Strategy:
  #   1. Extract code blocks / inline code → replace with safe placeholders
  #   2. Extract links → replace with safe placeholders
  #   3. Convert markdown syntax to Telegram format using internal tokens
  #   4. Escape all remaining special characters
  #   5. Restore formatting tokens → Telegram delimiters
  #   6. Restore links and code blocks
  module TelegramMarkdown
    SPECIAL_CHARS = /([_*\[\]()~`>#+\-=|{}.!\\])/

    # Internal formatting tokens (control chars — won't appear in normal text)
    T_BOLD       = "\x01"
    T_ITALIC     = "\x02"
    T_UNDERLINE  = "\x03"
    T_STRIKE     = "\x04"
    T_SPOILER    = "\x05"
    T_BLOCKQUOTE = "\x06"

    # Placeholder tokens — non-special-char sequences with index embedded
    # Format: CTL + "C" + index + CTL for code, CTL + "L" + index + CTL for links
    CTL = "\x10"  # Data Link Escape — safe control character

    # Regex patterns
    RE_CODE_BLOCK    = /```(\w*)\n(.*?)```/m
    RE_INLINE_CODE   = /`([^`]+?)`/m
    RE_LINK          = /\[([^\]]+)\]\(([^)]+)\)/
    RE_BOLD_ITALIC   = /\*\*\*([^*]+?)\*\*\*/m
    RE_BOLD          = /\*\*([^*]+?)\*\*/m
    RE_DUNDER        = /__([^_]+?)__/m
    RE_ITALIC        = /(?:^|(?<=\s))_([^_]+?)_(?:$|(?=\s|[^a-zA-Z0-9]))/m
    RE_STRIKE2       = /~~([^~]+?)~~/m
    RE_STRIKE1       = /~([^~]+?)~/m
    RE_SPOILER       = /\|\|([^|]+?)\|\|/m
    RE_BLOCKQUOTE    = /^\s*>\s*(.*)/m
    RE_HEADING       = /^\#{1,6}\s+(.+)$/

    # Map internal tokens → Telegram MarkdownV2 delimiters
    FORMAT_RESTORE = {
      T_BOLD       => "*",
      T_ITALIC     => "_",
      T_UNDERLINE  => "__",
      T_STRIKE     => "~",
      T_SPOILER    => "||",
      T_BLOCKQUOTE => ">",
    }.freeze

    class << self
      # Convert standard Markdown text to Telegram MarkdownV2-safe text.
      def convert(text)
        return "" unless text && !text.empty?

        code_blocks = []
        links       = []

        # Pass 1: isolate code blocks and links
        text = isolate_code_blocks(text, code_blocks)
        text = isolate_links(text, links)

        # Pass 2: convert markdown syntax → internal tokens
        text = apply_formatting(text)

        # Pass 3: escape special characters in plain text
        text = text.gsub(SPECIAL_CHARS) { "\\#{$1}" }

        # Pass 4: restore formatting tokens → Telegram delimiters
        FORMAT_RESTORE.each { |token, replacement| text.gsub!(token, replacement) }

        # Pass 5: restore links and code blocks
        links.each_with_index do |(link_text, url), i|
          converted_text = convert(link_text)
          placeholder = "#{CTL}L#{i}#{CTL}"
          safe_url = url.gsub("\\") { "\\\\" }.gsub("(", "\\(").gsub(")", "\\)").gsub("_", "\\_")
          text.gsub!(placeholder) { "[#{converted_text}](#{safe_url})" }
        end

        code_blocks.each_with_index do |block, i|
          placeholder = "#{CTL}C#{i}#{CTL}"
          text.gsub!(placeholder) { block }
        end

        text
      end

      private

      def isolate_code_blocks(text, store)
        # Fenced (triple-backtick) code blocks first
        text = text.gsub(RE_CODE_BLOCK) do
          lang    = Regexp.last_match(1)
          content = Regexp.last_match(2)
          # Strip trailing newline before closing ```
          content = content.chomp
          # Inside code: escape \ and `
          content = content.gsub("\\") { "\\\\" }.gsub("`", "\\`")
          reconstructed = "```#{lang}\n#{content}\n```"
          idx = store.size
          store << reconstructed
          "#{CTL}C#{idx}#{CTL}"
        end

        # Inline (single-backtick) code — run after fenced blocks so they don't clash
        text = text.gsub(RE_INLINE_CODE) do
          content = Regexp.last_match(1)
          # Inside inline code: escape \ and `
          content = content.gsub("\\") { "\\\\" }.gsub("`", "\\`")
          reconstructed = "`#{content}`"
          idx = store.size
          store << reconstructed
          "#{CTL}C#{idx}#{CTL}"
        end

        text
      end

      def isolate_links(text, store)
        text.gsub(RE_LINK) do
          link_text = Regexp.last_match(1)
          url       = Regexp.last_match(2)
          idx = store.size
          store << [link_text, url]
          "#{CTL}L#{idx}#{CTL}"
        end
      end

      def apply_formatting(text)
        # # headings → **bold** (strip the # prefix)
        text.gsub!(RE_HEADING) { "#{T_BOLD}#{$1}#{T_BOLD}" }
        # ***bold italic***
        text.gsub!(RE_BOLD_ITALIC) { "#{T_BOLD}#{T_ITALIC}#{$1}#{T_ITALIC}#{T_BOLD}" }
        # **bold**
        text.gsub!(RE_BOLD) { "#{T_BOLD}#{$1}#{T_BOLD}" }
        # __underline__
        text.gsub!(RE_DUNDER) { "#{T_UNDERLINE}#{$1}#{T_UNDERLINE}" }
        # ~~strikethrough~~
        text.gsub!(RE_STRIKE2) { "#{T_STRIKE}#{$1}#{T_STRIKE}" }
        # ~strikethrough~
        text.gsub!(RE_STRIKE1) { "#{T_STRIKE}#{$1}#{T_STRIKE}" }
        # ||spoiler||
        text.gsub!(RE_SPOILER) { "#{T_SPOILER}#{$1}#{T_SPOILER}" }
        # _italic_ (single underscore, whitespace-bounded)
        text.gsub!(RE_ITALIC) { "#{T_ITALIC}#{$1}#{T_ITALIC}" }
        # > blockquote
        text.gsub!(RE_BLOCKQUOTE) { "#{T_BLOCKQUOTE}#{$1}" }
        text
      end
    end
  end
end
