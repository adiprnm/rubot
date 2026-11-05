# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "../provider"

module Rubot
  module Providers
    class Ollama < Provider
      def chat(messages, tools: nil)
        reset_last_usage!
        payload = build_payload(messages, tools)
        response = make_request(payload)
        track_usage(ollama_usage(response))
        extract_content(response)
      end

      def chat_stream(messages, tools: nil, &on_chunk)
        reset_last_usage!
        payload = build_payload(messages, tools, stream: true)
        make_stream_request(payload, &on_chunk)
      end

      def format_tools(tools)
        # Ollama uses the same OpenAI-compatible tool format
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
          "stream" => stream
        }
        if tools && !tools.empty?
          payload["tools"] = format_tools(tools)
        end
        payload
      end

      def api_base
        @config.api_base || "http://localhost:11434"
      end

      def make_request(payload)
        uri = URI("#{api_base}/api/chat")
        log_debug("Request: #{JSON.generate(payload)}")

        response = with_retry do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 30
          http.read_timeout = 300

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/json"

          http.request(request, JSON.generate(payload))
        end
        log_debug("Response: #{response.code}")

        unless response.code.to_i == 200
          if response.code.to_i == 429
            raise RateLimitError.new(parse_retry_after(response))
          end
          raise "Ollama API error #{response.code}: #{response.body}"
        end

        JSON.parse(response.body)
      end

      def make_stream_request(payload, &on_chunk)
        uri = URI("#{api_base}/api/chat")

        buffer = ""
        accumulated = ""
        tool_calls = nil
        usage = nil

        with_retry do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 30
          http.read_timeout = 300

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/json"

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

                begin
                  data = JSON.parse(line)
                  delta = data.dig("message")
                  next unless delta

                  if delta["content"]
                    accumulated += delta["content"]
                    yield delta["content"], nil if on_chunk
                  end

                  if delta["tool_calls"]
                    tool_calls = delta["tool_calls"]
                  end

                  if data["done"] == true
                    usage = ollama_usage(data)
                    break
                  end
                rescue JSON::ParserError
                  # skip malformed chunks
                end
              end
            end
          end

          track_usage(usage)
          [ accumulated, tool_calls ]
        end
      end

      def ollama_usage(raw)
        return nil unless raw.is_a?(Hash)
        return nil if raw["prompt_eval_count"].nil? && raw["eval_count"].nil?

        {
          "prompt_eval_count" => raw["prompt_eval_count"],
          "eval_count" => raw["eval_count"]
        }
      end

      def extract_content(response)
        message = response["message"] || {}
        content = message["content"] || ""

        if message["tool_calls"]
          # Convert Ollama tool_calls to OpenAI format
          tool_calls = message["tool_calls"].map do |tc|
            {
              "id" => tc["function"]["name"],
              "type" => "function",
              "function" => {
                "name" => tc["function"]["name"],
                "arguments" => JSON.generate(tc["function"]["arguments"])
              }
            }
          end
          return { "content" => content, "tool_calls" => tool_calls }
        end

        content
      end
    end
  end
end
