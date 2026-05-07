# frozen_string_literal: true

require "json"
require "fileutils"
require "set"
require "time"

module Rubot
  class Session
    attr_reader :id, :messages, :workspace

    def initialize(id = "default", workspace: nil)
      @id = id
      @messages = []
      @workspace = workspace
      load!
    end

    def add(role, content, tool_calls: nil, tool_call_id: nil)
      msg = {
        "role" => role,
        "content" => content,
        "timestamp" => Time.now.iso8601
      }
      msg["tool_calls"] = tool_calls if tool_calls
      msg["tool_call_id"] = tool_call_id if tool_call_id
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
      save!
    end

    def file_path
      return nil unless @workspace
      File.join(@workspace, "sessions", "#{@id}.json")
    end

    private

    def load!
      return unless file_path && File.exist?(file_path)
      data = JSON.parse(File.read(file_path))
      @messages = data["messages"] || []
    end

    def save!
      return unless file_path
      FileUtils.mkdir_p(File.dirname(file_path))
      File.write(file_path, JSON.pretty_generate({
        "id" => @id,
        "created_at" => @messages.first&.fetch("timestamp", Time.now.iso8601),
        "updated_at" => Time.now.iso8601,
        "messages" => @messages
      }))
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
