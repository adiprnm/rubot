# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "../provider"

module Rubot
  module Providers
    class OpenAI < Provider
      def chat(messages, tools: nil)
        payload = build_payload(messages, tools)
        response = make_request(payload)
        extract_content(response)
      end

      def chat_stream(messages, tools: nil, &on_chunk)
        payload = build_payload(messages, tools, stream: true)
        make_stream_request(payload, &on_chunk)
      end

      def format_tools(tools)
        tools.map do |t|
          {
            "type" => "function",
            "function" => {
              "name" => t.name,
              "description" => t.description,
              "parameters" => t.parameters
            }
          }
        end
      end

      private

      def build_payload(messages, tools, stream: false)
        payload = {
          "model" => @config.model,
          "messages" => messages,
          "max_tokens" => @config.max_tokens,
          "temperature" => @config.temperature
        }
        payload["stream"] = true if stream
        if tools && !tools.empty?
          payload["tools"] = format_tools(tools)
          payload["tool_choice"] = "auto"
        end
        payload
      end

      def api_base
        @config.api_base || "https://api.openai.com/v1"
      end

      def make_request(payload)
        uri = URI("#{api_base}/chat/completions")

        log_debug("Request: #{JSON.generate(payload)}")
        response = with_retry do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 30
          http.read_timeout = 120

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/json"
          request["Authorization"] = "Bearer #{@config.api_key}"

          http.request(request, JSON.generate(payload))
        end
        log_debug("Response: #{response.code} - #{response.body[0..500]}")

        unless response.code.to_i == 200
          if response.code.to_i == 429
            raise RateLimitError.new(parse_retry_after(response))
          end
          raise "API error #{response.code}: #{response.body}"
        end

        JSON.parse(response.body)
      end

      def make_stream_request(payload, &on_chunk)
        uri = URI("#{api_base}/chat/completions")
        log_debug("Stream request: #{JSON.generate(payload)}")

        buffer = ""
        accumulated = ""
        reasoning_content = ""
        tool_calls_accum = {}

        with_retry do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 30
          http.read_timeout = 300

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/json"
          request["Authorization"] = "Bearer #{@config.api_key}"

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
                next if data_str == "[DONE]"

                begin
                  data = JSON.parse(data_str)
                  delta = data.dig("choices", 0, "delta")
                  next unless delta

                  if delta["content"]
                    accumulated += delta["content"]
                    yield delta["content"], nil if on_chunk
                  end

                  if delta["reasoning_content"]
                    reasoning_content += delta["reasoning_content"]
                  end

                  if delta["tool_calls"]
                    delta["tool_calls"].each do |tc|
                      idx = tc["index"]
                      tool_calls_accum[idx] ||= {
                        "id" => "",
                        "type" => "function",
                        "function" => { "name" => "", "arguments" => "" }
                      }
                      tool_calls_accum[idx]["id"] = tc["id"] if tc["id"]
                      if tc.dig("function", "name")
                        tool_calls_accum[idx]["function"]["name"] += tc["function"]["name"]
                      end
                      if tc.dig("function", "arguments")
                        tool_calls_accum[idx]["function"]["arguments"] += tc["function"]["arguments"]
                      end
                    end
                  end
                rescue JSON::ParserError
                  # skip malformed chunks
                end
              end
            end
          end

          tool_calls = tool_calls_accum.empty? ? nil : tool_calls_accum.values

          # Return as Hash for consistency with non-streaming extract_content
          result = { "content" => accumulated }
          result["tool_calls"] = tool_calls if tool_calls
          result["reasoning_content"] = reasoning_content if !reasoning_content.empty?
          result
        end
      end

      def extract_content(response)
        choice = response.dig("choices", 0)
        return "" unless choice

        message = choice["message"]
        content = message["content"] || ""
        reasoning_content = message["reasoning_content"]

        # Handle tool calls
        if message["tool_calls"]
          result = {
            "content" => content,
            "tool_calls" => message["tool_calls"]
          }
          result["reasoning_content"] = reasoning_content if reasoning_content
          return result
        end

        # Return reasoning_content alongside content for non-tool responses
        if reasoning_content
          { "content" => content, "reasoning_content" => reasoning_content }
        else
          content
        end
      end
    end
  end
end
