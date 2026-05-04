# frozen_string_literal: true

require "json"
require "fileutils"
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
      @messages.map do |msg|
        entry = { "role" => msg["role"], "content" => msg["content"] }
        entry["tool_calls"] = msg["tool_calls"] if msg["tool_calls"]
        entry["tool_call_id"] = msg["tool_call_id"] if msg["tool_call_id"]
        entry
      end
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
      if @messages.size > 100
        @messages = @messages[-100..]
      end
    end
  end
end
