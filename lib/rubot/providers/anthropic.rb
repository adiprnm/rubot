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
        tools.map do |t|
          {
            "name" => t.name,
            "description" => t.description,
            "input_schema" => t.parameters
          }
        end
      end

      private

      def build_payload(messages, tools, system_prompt, stream: false)
        payload = {
          "model" => @config.model,
          "messages" => messages.map { |m| anthropic_message(m) },
          "max_tokens" => @config.max_tokens,
          "temperature" => @config.temperature
        }
        payload["stream"] = true if stream
        payload["system"] = system_prompt if system_prompt
        if tools && !tools.empty?
          payload["tools"] = format_tools(tools)
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
            result["content"] = msg["content"] || ""
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
          { "role" => "user", "content" => msg["content"] || "" }
        end
      end

      def api_base
        @config.api_base || "https://api.anthropic.com"
      end

      def api_key
        @config.api_key
      end

      def make_request(payload)
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

          http.request(request, JSON.generate(payload))
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
        uri = URI("#{api_base}/v1/messages")

        buffer = ""
        accumulated = ""
        tool_calls_accum = {}
        current_tool_name = ""
        current_tool_id = ""
        current_tool_input = ""
        usage = nil

        with_retry do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 30
          http.read_timeout = 300

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/json"
          request["x-api-key"] = api_key
          request["anthropic-version"] = API_VERSION

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

          tool_calls = tool_calls_accum.empty? ? nil : tool_calls_accum.values
          track_usage(usage)
          [ accumulated, tool_calls ]
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

        return { "content" => text_parts.join, "tool_calls" => tool_calls } unless tool_calls.empty?
        text_parts.join
      end
    end
  end
end
