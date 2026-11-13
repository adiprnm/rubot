# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "../provider"

module Rubot
  module Providers
    class Ollama < Provider
      def chat(messages, tools: nil, on_retry: nil)
        reset_last_usage!
        payload = build_payload(messages, tools)
        response = make_request(payload, on_retry: on_retry)
        track_usage(ollama_usage(response))
        extract_content(response)
      end

      def chat_stream(messages, tools: nil, on_retry: nil, &on_chunk)
        reset_last_usage!
        payload = build_payload(messages, tools, stream: true)
        make_stream_request(payload, on_retry: on_retry, &on_chunk)
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

      # GET /api/tags — the models Ollama has pulled locally.
      def list_models
        uri = URI("#{api_base}/api/tags")
        request = Net::HTTP::Get.new(uri.request_uri)
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
        items = body.is_a?(Hash) ? (body["models"] || []) : []
        Array(items).filter_map do |item|
          next unless item.is_a?(Hash)

          name = item["name"] || item["model"]
          next if name.nil? || name.to_s.strip.empty?

          { "id" => name.to_s.strip, "name" => name.to_s.strip }
        end
      rescue StandardError => e
        log_debug("list_models failed: #{e.class}: #{e.message}")
        []
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

      def make_request(payload, on_retry: nil)
        Rubot::Cancellation.check!
        uri = URI("#{api_base}/api/chat")
        log_debug("Request: #{JSON.generate(payload)}")

        response = with_retry(on_retry: on_retry) do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 30
          http.read_timeout = 300

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/json"

          with_cancellable_http(http) do
            http.request(request, JSON.generate(payload))
          end
        end
        log_debug("Response: #{response.code}")

        unless response.code.to_i == 200
          if quota_exhausted_response?(response)
            raise QuotaExhaustedError.new(nil, message: "Ollama API error #{response.code}: #{response.body}")
          end
          if response.code.to_i == 429
            raise RateLimitError.new(parse_retry_after(response))
          end
          raise "Ollama API error #{response.code}: #{response.body}"
        end

        JSON.parse(response.body)
      end

      def make_stream_request(payload, on_retry: nil, &on_chunk)
        Rubot::Cancellation.check!
        uri = URI("#{api_base}/api/chat")

        buffer = ""
        accumulated = ""
        tool_calls = nil
        usage = nil
        done_reason = nil
        saw_done = false

        with_retry(retryable: -> { accumulated.empty? }, on_retry: on_retry) do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 30
          http.read_timeout = 300

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/json"

          with_cancellable_http(http) do
            http.request(request, JSON.generate(payload)) do |response|
              unless response.code.to_i == 200
                body = +""
                response.read_body { |b| body << b }
                if Rubot::Provider.quota_exhausted_text?(body)
                  raise QuotaExhaustedError.new(nil, message: "API error #{response.code}: #{body}")
                end
                if response.code.to_i == 429
                  raise RateLimitError.new(parse_retry_after(response))
                end
                raise "API error #{response.code}: #{body}"
              end

              response.read_body do |chunk|
                # Abort at the next chunk after a stop, rather than reading the
                # whole answer and discarding it afterwards.
                Rubot::Cancellation.check!
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
                      done_reason = data["done_reason"]
                      saw_done = true
                      break
                    end
                  rescue JSON::ParserError
                    # skip malformed chunks
                  end
                end
              end
            end
          end

          track_usage(usage)

          extra = {}
          extra["stream_incomplete"] = true unless saw_done

          result_hash(accumulated, finish_reason: done_reason,
                                  tool_calls: tool_calls,
                                  extra: extra)
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

        # Ollama reports the same signal as OpenAI under `done_reason`;
        # it is "length" when the output budget ran out.
        tool_calls = if message["tool_calls"]
          message["tool_calls"].map do |tc|
            {
              "id" => tc["function"]["name"],
              "type" => "function",
              "function" => {
                "name" => tc["function"]["name"],
                "arguments" => JSON.generate(tc["function"]["arguments"])
              }
            }
          end
        end

        result_hash(content, finish_reason: response["done_reason"] || response["stop_reason"], tool_calls: tool_calls)
      end
    end
  end
end
