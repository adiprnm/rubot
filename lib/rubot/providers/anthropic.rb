# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "../provider"

module Rubot
  module Providers
    class Anthropic < Provider
      API_VERSION = "2023-06-01"

      def chat(messages, tools: nil)
        reset_last_usage!
        # Extract system prompt from messages
        system_msg = messages.find { |m| m["role"] == "system" }
        system_prompt = system_msg ? system_msg["content"] : nil
        non_system = messages.reject { |m| m["role"] == "system" }

        payload = build_payload(non_system, tools, system_prompt)
        response = make_request(payload)
        track_usage(response["usage"])
        extract_content(response)
      end

      def chat_stream(messages, tools: nil, &on_chunk)
        reset_last_usage!
        system_msg = messages.find { |m| m["role"] == "system" }
        system_prompt = system_msg ? system_msg["content"] : nil
        non_system = messages.reject { |m| m["role"] == "system" }

        payload = build_payload(non_system, tools, system_prompt, stream: true)
        make_stream_request(payload, &on_chunk)
      end

      def format_tools(tools)
        Array(tools).map do |t|
          {
            "name" => t.name,
            "description" => t.description,
            "input_schema" => t.parameters
          }
        end
      end

      # GET /v1/models — the models Anthropic serves.
      def list_models
        uri = URI("#{api_base}/v1/models")
        request = Net::HTTP::Get.new(uri.request_uri)
        request["x-api-key"] = api_key if api_key
        request["anthropic-version"] = API_VERSION
        extra_headers.each { |name, value| request[name] = value.to_s }

        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: 10,
          read_timeout: 30
        ) { |http| http.request(request) }

        return [] unless response.code.to_i == 200

        body = JSON.parse(response.body)
        items = body.is_a?(Hash) ? (body["data"] || []) : []
        Array(items).filter_map do |item|
          next unless item.is_a?(Hash)

          id = item["id"]
          next if id.nil? || id.to_s.strip.empty?

          { "id" => id.to_s.strip, "name" => (item["display_name"] || id).to_s.strip }
        end
      rescue StandardError => e
        log_debug("list_models failed: #{e.class}: #{e.message}")
        []
      end

      private

      def build_payload(messages, tools, system_prompt, stream: false)
        mapped = messages.map { |m| anthropic_message(m) }
        markers = cache_markers_enabled?(system_prompt, tools, mapped)

        payload = {
          "model" => @config.model,
          "messages" => mapped,
          "max_tokens" => @config.max_tokens,
          "temperature" => @config.temperature
        }
        payload["stream"] = true if stream

        if system_prompt
          system_block = { "type" => "text", "text" => system_prompt }
          system_block["cache_control"] = cache_control_marker if markers
          payload["system"] = [ system_block ]
        end

        if tools && !tools.empty?
          payload["tools"] = format_tools(tools)
          # Re-apply marker decision consistently: format_tools already gated on
          # markers, but it could not see the full prefix, so fix up here.
          if markers && payload["tools"].is_a?(Array) && !payload["tools"].empty?
            payload["tools"].last["cache_control"] = cache_control_marker
          elsif !markers && payload["tools"].is_a?(Array)
            payload["tools"].each { |t| t.delete("cache_control") }
          end
        end

        if markers && !mapped.empty?
          # Rolling breakpoint on the last message of the request.
          mark_cache_control(mapped.last, cache_control_marker)
          # Anchor on the last message of the previous turn, when there is one,
          # so tool-heavy turns keep a stable block inside the lookback window.
          mark_cache_control(mapped[-2], cache_control_marker) if mapped.size >= 2
        end

        payload
      end

      def anthropic_message(msg)
        case msg["role"]
        when "assistant"
          result = { "role" => "assistant" }
          if msg["tool_calls"]
            content = []
            if msg["content"] && !msg["content"].to_s.empty?
              content << { "type" => "text", "text" => msg["content"] }
            end
            msg["tool_calls"].each do |tc|
              fn = tc.is_a?(Hash) ? tc["function"] : tc.function
              content << {
                "type" => "tool_use",
                "id" => tc.is_a?(Hash) ? tc["id"] : tc.id,
                "name" => fn.is_a?(Hash) ? fn["name"] : fn.name,
                "input" => fn.is_a?(Hash) ? JSON.parse(fn["arguments"]) : JSON.parse(fn.arguments)
              }
            end
            result["content"] = content
          else
            text = msg["content"]
            result["content"] = text.is_a?(Array) ? text : [ { "type" => "text", "text" => text.to_s } ]
          end
          result
        when "tool"
          {
            "role" => "user",
            "content" => [ {
              "type" => "tool_result",
              "tool_use_id" => msg["tool_call_id"],
              "content" => msg["content"].to_s
            } ]
          }
        else
          text = msg["content"]
          content = text.is_a?(Array) ? text : [ { "type" => "text", "text" => text.to_s } ]
          { "role" => "user", "content" => content }
        end
      end

      def cache_control_marker
        { "type" => "ephemeral" }
      end

      def cache_markers_enabled?(system_prompt, tools, mapped)
        estimate = (system_prompt.to_s.length +
                    Array(tools).map(&:to_s).join.length +
                    Array(mapped).map(&:to_s).join.length) / 4
        estimate >= cache_min_tokens
      end

      def cache_min_tokens
        model = @config.model.to_s.downcase
        return 512 if model.match?(/opus-5|sonnet-5\.5|haiku-5\.5|fable|mythos/)
        return 2048 if model.include?("opus-4.7")
        return 4096 if model.match?(/opus-4\.[56]|haiku-4\.5/)
        1024
      end

      def mark_cache_control(message, marker)
        return unless message.is_a?(Hash)

        content = message["content"]
        if content.is_a?(Array) && !content.empty?
          last = content.last
          last["cache_control"] = marker.dup if last.is_a?(Hash)
        elsif content.is_a?(String)
          message["content"] = [ { "type" => "text", "text" => content, "cache_control" => marker.dup } ]
        end
      end

      def api_base
        @config.api_base || "https://api.anthropic.com"
      end

      def api_key
        @config.api_key
      end

      def make_request(payload)
        Rubot::Cancellation.check!
        uri = URI("#{api_base}/v1/messages")
        log_debug("Request: #{JSON.generate(payload)}")

        response = with_retry do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 30
          http.read_timeout = 120

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/json"
          request["x-api-key"] = api_key
          request["anthropic-version"] = API_VERSION

          with_cancellable_http(http) do
            http.request(request, JSON.generate(payload))
          end
        end
        log_debug("Response: #{response.code}")

        unless response.code.to_i == 200
          if response.code.to_i == 429
            raise RateLimitError.new(parse_retry_after(response))
          end
          raise "Anthropic API error #{response.code}: #{response.body}"
        end

        JSON.parse(response.body)
      end

      def make_stream_request(payload, &on_chunk)
        Rubot::Cancellation.check!
        uri = URI("#{api_base}/v1/messages")

        buffer = ""
        accumulated = ""
        tool_calls_accum = {}
        current_tool_name = ""
        current_tool_id = ""
        current_tool_input = ""
        usage = nil
        stop_reason = nil
        saw_stop = false

        with_retry(retryable: -> { accumulated.empty? }) do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 30
          http.read_timeout = 300

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/json"
          request["x-api-key"] = api_key
          request["anthropic-version"] = API_VERSION

          with_cancellable_http(http) do
            http.request(request, JSON.generate(payload)) do |response|
              unless response.code.to_i == 200
                body = +""
                response.read_body { |b| body << b }
                if response.code.to_i == 429
                  raise RateLimitError.new(parse_retry_after(response))
                end
                raise "API error #{response.code}: #{body}"
              end

              response.read_body do |chunk|
                # Stop at the next chunk when the turn was cancelled: raising
                # here aborts the request instead of draining the stream.
                Rubot::Cancellation.check!
                buffer += chunk
                while (newline_idx = buffer.index("\n"))
                  line = buffer[0...newline_idx].strip
                  buffer = buffer[(newline_idx + 1)..] || ""
                  next if line.empty?
                  next unless line.start_with?("data: ")

                  data_str = line[6..]
                  begin
                    data = JSON.parse(data_str)
                    type = data["type"]

                    case type
                    when "message_start"
                      start_usage = data.dig("message", "usage")
                      usage = start_usage.dup if start_usage.is_a?(Hash)
                    when "message_delta"
                      delta_usage = data["usage"]
                      usage = (usage || {}).merge(delta_usage) if delta_usage.is_a?(Hash)
                      stop_reason = data.dig("delta", "stop_reason") || stop_reason
                    when "message_stop"
                      saw_stop = true
                    when "content_block_start"
                      block = data["content_block"]
                      if block && block["type"] == "tool_use"
                        current_tool_name = block["name"]
                        current_tool_id = block["id"]
                        current_tool_input = block["input"] ? JSON.generate(block["input"]) : ""
                      end
                    when "content_block_delta"
                      delta = data["delta"]
                      if delta
                        if delta["type"] == "text_delta"
                          accumulated += delta["text"]
                          yield delta["text"], nil if on_chunk
                        elsif delta["type"] == "input_json_delta"
                          current_tool_input += delta["partial_json"]
                        end
                      end
                    when "content_block_stop"
                      if current_tool_name && current_tool_id
                        idx = tool_calls_accum.size
                        tool_calls_accum[idx] = {
                          "id" => current_tool_id,
                          "type" => "function",
                          "function" => {
                            "name" => current_tool_name,
                            "arguments" => current_tool_input
                          }
                        }
                        current_tool_name = ""
                        current_tool_id = ""
                        current_tool_input = ""
                      end
                    end
                  rescue JSON::ParserError
                    # skip malformed chunks
                  end
                end
              end
            end
          end

          tool_calls = tool_calls_accum.empty? ? nil : tool_calls_accum.values
          track_usage(usage)

          extra = { "usage" => usage }.compact
          # Without `message_stop` the connection died mid-answer.
          extra["stream_incomplete"] = true unless saw_stop

          result_hash(accumulated, finish_reason: anthropic_finish_reason(stop_reason),
                                  tool_calls: tool_calls,
                                  extra: extra)
        end
      end

      def extract_content(response)
        content_parts = response["content"] || []
        text_parts = []
        tool_calls = []

        content_parts.each do |part|
          case part["type"]
          when "text"
            text_parts << part["text"]
          when "tool_use"
            tool_calls << {
              "id" => part["id"],
              "type" => "function",
              "function" => {
                "name" => part["name"],
                "arguments" => JSON.generate(part["input"])
              }
            }
          end
        end

        result_hash(text_parts.join,
                    finish_reason: anthropic_finish_reason(response["stop_reason"]),
                    tool_calls: tool_calls)
      end

      # Anthropic says `max_tokens` where OpenAI says `length`; normalize so the
      # agent has one value to test.
      def anthropic_finish_reason(stop_reason)
        stop_reason == "max_tokens" ? "length" : stop_reason
      end
    end
  end
end
