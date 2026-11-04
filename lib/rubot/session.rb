# frozen_string_literal: true

require "json"
require "fileutils"
require "set"
require "time"

module Rubot
  class Session
    attr_reader :id, :messages, :workspace
    attr_accessor :summary, :forced_skill, :model_override

    def initialize(id = "default", workspace: nil)
      @id = id
      @messages = []
      @workspace = workspace
      @summary = nil
      @forced_skill = nil
      @model_override = nil
      load!
    end

    # Returns true if summarization has already been applied to this session
    def summarized?
      !@summary.nil? && !@summary.strip.empty?
    end

    # Append additional text to the existing summary
    def append_summary(text)
      clean = self.class.normalize_utf8(text.to_s)
      if @summary.nil? || @summary.strip.empty?
        @summary = clean
      else
        @summary += "\n" + clean
      end
      save!
    end

    # Tool output (binary files, PNG bytes, latin-1 from a CLI) can be invalid
    # UTF-8. Such strings break JSON generation for the session file and for the
    # provider request, so everything that enters the transcript is forced to
    # valid UTF-8 here. Invalid bytes are replaced with U+FFFD.
    def self.normalize_utf8(value)
      case value
      when String
        str = value.dup.force_encoding(Encoding::UTF_8)
        str.valid_encoding? ? str : str.scrub
      when Array
        value.map { |item| normalize_utf8(item) }
      when Hash
        value.each_with_object({}) do |(key, val), acc|
          acc[normalize_utf8(key)] = normalize_utf8(val)
        end
      else
        value
      end
    end

    def add(role, content, tool_calls: nil, tool_call_id: nil, reasoning_content: nil)
      msg = {
        "role" => self.class.normalize_utf8(role),
        "content" => self.class.normalize_utf8(content),
        "timestamp" => Time.now.iso8601
      }
      msg["tool_calls"] = self.class.normalize_utf8(tool_calls) if tool_calls
      msg["tool_call_id"] = self.class.normalize_utf8(tool_call_id) if tool_call_id
      msg["reasoning_content"] = self.class.normalize_utf8(reasoning_content) if reasoning_content
      @messages << msg
      trim! if @workspace
      save!
      msg
    end

    def conversation_history
      history = @messages.map do |msg|
        entry = { "role" => msg["role"], "content" => msg["content"] }
        entry["tool_calls"] = msg["tool_calls"] if msg["tool_calls"]
        entry["tool_call_id"] = msg["tool_call_id"] if msg["tool_call_id"]
        entry["reasoning_content"] = msg["reasoning_content"] if msg["reasoning_content"]
        entry
      end
      remove_orphaned_tool_messages(history)
    end

    # Returns conversation history with an optional limit, ensuring no orphaned
    # tool_call_id references (tool results whose parent tool_call was trimmed).
    def safe_history(limit: nil)
      history = conversation_history
      return history if limit.nil?
      return history if history.size <= limit

      trim_index = history.size - limit

      # If the first kept message is a tool result, its parent assistant was
      # trimmed out. Skip all consecutive tool results to avoid orphaned IDs.
      while trim_index < history.size && history[trim_index]["role"] == "tool"
        trim_index += 1
      end

      history[trim_index..]
    end

    def message_count
      @messages.size
    end

    def clear!
      @messages = []
      @forced_skill = nil
      @summary = nil
      @model_override = nil
      save!
    end

    # Summarize the oldest messages that would be trimmed, append to
    # the running summary, and then trim those messages. Called when
    # the conversation approaches the history limit.
    #
    # Returns the text that was summarized (the new summary fragment),
    # or nil if nothing was trimmed.
    def summarize_and_trim!(provider:, system_prompt:)
      return nil unless @workspace
      return nil if @messages.empty?

      # Calculate how many messages to trim (keep 60% of the limit)
      limit = 100  # session hard limit
      return nil if @messages.size <= limit * 0.6

      trim_count = @messages.size - (limit * 0.6).to_i
      return nil if trim_count <= 0

      # Collect the messages to be summarized
      to_summarize = @messages[0...trim_count]
      summary_text = call_summarizer(provider, system_prompt, to_summarize)
      return nil if summary_text.nil? || summary_text.strip.empty?

      # Append to existing summary
      append_summary(summary_text.strip)

      # Trim the messages
      @messages = @messages[trim_count..]

      # Ensure we don't start with orphaned tool messages
      while @messages.first && @messages.first["role"] == "tool"
        @messages.shift
      end

      save!
      summary_text.strip
    end

    # Returns the summary text for inclusion in the system prompt
    def summary_text
      return nil if @summary.nil? || @summary.strip.empty?
      @summary.strip
    end

    def file_path
      return nil unless @workspace
      File.join(@workspace, "sessions", "#{@id}.json")
    end

    # Persist session to disk. Uses an exclusive file lock so a session
    # file is never partially written even if another process/Ractor
    # touches it at the same time.
    def save!
      return unless file_path
      FileUtils.mkdir_p(File.dirname(file_path))
      data = {
        "id" => @id,
        "created_at" => @messages.first&.fetch("timestamp", Time.now.iso8601),
        "updated_at" => Time.now.iso8601,
        "messages" => @messages
      }
      data["summary"] = @summary if @summary
      data["forced_skill"] = @forced_skill if @forced_skill
      data["model_override"] = @model_override if @model_override

      # Generate before opening the file: JSON.pretty_generate can raise (e.g.
      # invalid UTF-8), and truncating first would leave an empty session file.
      payload = JSON.pretty_generate(self.class.normalize_utf8(data))

      File.open(file_path, File::WRONLY | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX)
        file.truncate(0)
        file.write(payload)
        file.flush
        file.flock(File::LOCK_UN)
      end
    end

    private

    # Call the LLM to summarize a batch of old messages into a compact form
    def call_summarizer(provider, system_prompt, messages)
      # Build a minimal context for summarization
      context = messages.map do |msg|
        role = msg["role"]
        content = msg["content"] || ""
        "[#{role}]: #{content}"
      end.join("\n")

      summarize_prompt = <<~PROMPT.strip
        Summarize the following conversation history into a concise paragraph.
        Preserve important facts, decisions, and outcomes. Omit pleasantries
        and redundant exchanges. Keep it under 200 words.

        Conversation:
        #{context}
      PROMPT

      result = provider.chat(
        [{ "role" => "user", "content" => summarize_prompt }],
        tools: nil
      )

      if result.is_a?(Hash)
        result["content"]
      else
        result.to_s
      end
    rescue StandardError => e
      warn "[session:summarize] Failed: #{e.class}: #{e.message}" if Rubot.debug?
      nil
    end

    def load!
      return unless file_path && File.exist?(file_path)

      raw = File.read(file_path)
      return if raw.strip.empty?

      data = JSON.parse(raw)
      @messages = self.class.normalize_utf8(data["messages"] || [])
      @summary = data["summary"] if data["summary"]
      @forced_skill = data["forced_skill"] if data["forced_skill"]
      @model_override = data["model_override"] if data["model_override"]
    rescue JSON::ParserError => e
      # A truncated/corrupt session must not take the bot down: start fresh.
      warn "[session] ignoring unreadable session #{file_path}: #{e.message}"
      @messages = []
    end

    def trim!
      # Keep only the last N messages to avoid context overflow
      return unless @workspace
      # We'll use the config's history_limit later, for now keep last 100
      limit = 100
      return unless @messages.size > limit

      trim_index = @messages.size - limit

      # If the first kept message is a tool result, its parent assistant message
      # (with tool_calls) was trimmed out. Skip all consecutive tool results to
      # prevent orphaned tool_call_id references that cause API errors.
      while trim_index < @messages.size && @messages[trim_index]["role"] == "tool"
        trim_index += 1
      end

      @messages = @messages[trim_index..]
    end

    # Remove tool messages whose tool_call_id doesn't correspond to any
    # tool_call ID remaining in the history (safety net for edge cases).
    def remove_orphaned_tool_messages(history)
      valid_ids = Set.new
      history.each do |msg|
        next unless msg["tool_calls"]
        msg["tool_calls"].each do |tc|
          valid_ids << tc["id"] if tc["id"]
        end
      end
      history.reject { |msg| msg["role"] == "tool" && !valid_ids.include?(msg["tool_call_id"]) }
    end
  end
end
