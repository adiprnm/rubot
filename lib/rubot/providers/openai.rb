# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "securerandom"
require "uri"
require_relative "../provider"
require_relative "../sse"

module Rubot
  module Providers
    class OpenAI < Provider
      def initialize(config)
        super
        @extra_headers = {}

        if @config.respond_to?(:extra_headers) && @config.extra_headers.is_a?(Hash)
          @extra_headers.merge!(@config.extra_headers)
        end
      end


      def chat(messages, tools: nil, on_retry: nil)
        reset_last_usage!
        payload = build_payload(messages, tools)
        response = make_request(payload, on_retry: on_retry)
        track_usage(response["usage"])
        extract_content(response)
      end

      def chat_stream(messages, tools: nil, on_retry: nil, &on_chunk)
        reset_last_usage!
        payload = build_payload(messages, tools, stream: true)
        make_stream_request(payload, on_retry: on_retry, &on_chunk)
      end

      # GET /models — OpenAI-compatible providers
      # expose their supported model list there.
      def list_models
        uri = URI("#{api_base}/models")
        request = Net::HTTP::Get.new(uri.request_uri)
        request["Authorization"] = "Bearer #{@config.api_key}" if @config.api_key
        apply_extra_headers(request)

        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: 10,
          read_timeout: 30
        ) { |http| http.request(request) }

        return [] unless response.code.to_i == 200

        body = JSON.parse(response.body)
        items = if body.is_a?(Hash)
          body["data"] || body["models"] || []
        else
          []
        end
        Array(items).filter_map do |item|
          item.is_a?(Hash) ? item : { "id" => item.to_s }
        end
      rescue StandardError => e
        log_debug("list_models failed: #{e.class}: #{e.message}")
        []
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

      # Rough size of what the provider was asked to read. Characters rather
      # than tokens: enough to watch a prompt grow, and free to compute.
      def prompt_bytes(payload)
        messages = payload["messages"]
        return 0 unless messages.is_a?(Array)

        # Messages reach here with string keys from the agent and symbol keys
        # from callers that build them by hand; both count.
        messages.sum do |message|
          content = message.is_a?(Hash) ? (message["content"] || message[:content]) : nil
          content.to_s.bytesize
        end
      end

      # OpenAI routes a request to whichever machine holds its cache; the key is
      # how it knows two requests belong to the same prefix. Without one every
      # request is a free choice, and a request that lands elsewhere pays for
      # the whole prefix again — the cache hit rate looks like a prompt problem
      # while the prompt was identical all along.
      #
      # The value covers exactly the part that has to be found again: the model,
      # the pinned system prompt and the tool catalog. Not the conversation —
      # that grows every turn, and a key that moved with it would route each
      # request to a different machine, which is the failure this prevents.
      # It is a digest, so it survives a restart: a request after `rubot` is
      # started again lands on the same partition as the one before it.
      #
      # Only real OpenAI gets it. The field is OpenAI's, and an OpenAI-compatible
      # gateway that does not recognise it answers 400 — which would turn a
      # routing hint into a broken request. The gate is the endpoint, not the
      # `provider:` label, because that label is also how a gateway is named.
      def prompt_cache_key(messages, tools)
        return nil unless openai_endpoint?

        system = messages.is_a?(Array) ? messages.first : nil
        prompt = system.is_a?(Hash) ? (system["content"] || system[:content]).to_s : ""
        catalog = Array(tools).map { |tool| [ tool.name, tool.description, tool.parameters ] }

        Digest::SHA1.hexdigest(JSON.generate([ @config.model, prompt, catalog ]))
      end

      def openai_endpoint?
        host = URI(api_base).host.to_s.downcase
        host == "api.openai.com" || host.end_with?(".openai.com")
      rescue URI::InvalidURIError
        false
      end

      def build_payload(messages, tools, stream: false)
        payload = {
          "model" => @config.model,
          "messages" => messages,
          "max_tokens" => @config.max_tokens,
          "temperature" => @config.temperature
        }
        payload["stream"] = true if stream
        payload["stream_options"] = { "include_usage" => true } if stream
        cache_key = prompt_cache_key(messages, tools)
        payload["prompt_cache_key"] = cache_key if cache_key
        effort = @config.respond_to?(:reasoning_effort) ? @config.reasoning_effort : nil
        payload["reasoning_effort"] = effort if effort
        if tools && !tools.empty?
          payload["tools"] = format_tools(tools)
          payload["tool_choice"] = "auto"
        end
        payload
      end

      def api_base
        @config.api_base || "https://api.openai.com/v1"
      end

      def apply_extra_headers(request)
        @extra_headers.each { |name, value| request[name] = value.to_s }
      end

      def make_request(payload, on_retry: nil)
        Rubot::Cancellation.check!
        uri = URI("#{api_base}/chat/completions")

        log_debug("Request: #{JSON.generate(payload)}")
        # Nothing streams here, so the whole wait is one number: there is no
        # first byte to separate it from.
        started = Rubot::Timing.clock
        response = with_retry(on_retry: on_retry) do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 30
          http.read_timeout = 120

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/json"
          request["Authorization"] = "Bearer #{@config.api_key}"
          apply_extra_headers(request)

          with_cancellable_http(http) do
            http.request(request, JSON.generate(payload))
          end
        end

        unless response.code.to_i == 200
          if quota_exhausted_response?(response)
            raise QuotaExhaustedError.new(nil, message: "API error #{response.code}: #{response.body}")
          end
          if response.code.to_i == 429
            raise RateLimitError.new(parse_retry_after(response))
          end
          raise "API error #{response.code}: #{response.body}"
        end

        body = JSON.parse(response.body)
        Rubot::Timing.record(
          model: @config.model,
          prompt_bytes: prompt_bytes(payload),
          total: Rubot::Timing.clock - started,
          kind: "request",
          usage: body["usage"]
        )
        body
      end

      def make_stream_request(payload, on_retry: nil, &on_chunk)
        Rubot::Cancellation.check!
        uri = URI("#{api_base}/chat/completions")
        log_debug("Stream request: #{JSON.generate(payload)}")

        reader = Sse::Reader.new
        accumulated = ""
        reasoning_content = ""
        tool_calls_accum = {}
        usage = nil
        finish_reason = nil
        saw_done = false
        # Two halves of the wait, kept apart: how long the provider took to say
        # anything at all, and how long the answer then took to finish.
        started = Rubot::Timing.clock
        first_byte = nil

        with_retry(retryable: -> { accumulated.empty? }, on_retry: on_retry) do
          http, request = stream_connection(uri)

          with_cancellable_http(http) do
            http.request(request, JSON.generate(payload)) do |response|
              Sse.raise_for_response(response) { parse_retry_after(response) }

              response.read_body do |chunk|
                reader.feed(chunk).each do |data_str|
                  if data_str == "[DONE]"
                    saw_done = true
                    next
                  end

                  begin
                    data = JSON.parse(data_str)
                    usage = data["usage"] if data["usage"].is_a?(Hash)
                    finish_reason = data.dig("choices", 0, "finish_reason") || finish_reason
                    delta = data.dig("choices", 0, "delta")
                    next unless delta

                    if delta["content"]
                      first_byte ||= Rubot::Timing.clock - started if Rubot::Timing.enabled?
                      accumulated += delta["content"]
                      yield delta["content"], nil if on_chunk
                    end

                    if delta["reasoning_content"]
                      first_byte ||= Rubot::Timing.clock - started if Rubot::Timing.enabled?
                      reasoning_content += delta["reasoning_content"]
                      # The caller renders the model's thinking as it arrives,
                      # so it is handed out on its own channel instead of
                      # being folded into the answer.
                      yield nil, nil, delta["reasoning_content"] if on_chunk
                    end

                    if delta["tool_calls"]
                      delta["tool_calls"].each { |tc| merge_tool_call_delta(tool_calls_accum, tc) }
                    end
                  rescue JSON::ParserError
                    # skip malformed chunks
                  end
                end
              end
            end
          end

          # A provider that closes the connection mid-frame leaves the last
          # event in the buffer with no trailing newline. Parse it instead of
          # dropping it, so the tail of the answer is not lost.
          if (tail = trailing_frame(reader))
            finish_reason = tail[:finish_reason] || finish_reason
            if (text = tail[:content])
              accumulated += text
              yield text, nil if on_chunk
            end
          end

          tool_calls = tool_calls_accum.empty? ? nil : tool_calls_accum.values
          track_usage(usage)

          Rubot::Timing.record(
            model: @config.model,
            prompt_bytes: prompt_bytes(payload),
            first_byte: first_byte,
            total: Rubot::Timing.clock - started,
            tool_calls: tool_calls&.size,
            usage: usage
          )

          extra = { "usage" => usage }.compact
          # A stream that never sent `data: [DONE]` was cut, not finished: the
          # text we hold is a prefix of the answer, whatever finish_reason says.
          extra["stream_incomplete"] = true unless saw_done

          result_hash(accumulated, finish_reason: finish_reason,
                                  tool_calls: tool_calls,
                                  reasoning_content: reasoning_content,
                                  extra: extra)
        end
      end

      # The connection and the POST a streaming turn is sent over, kept out of
      # #make_stream_request so the event loop below reads as the loop it is.
      def stream_connection(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 30
        http.read_timeout = 300

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{@config.api_key}"
        apply_extra_headers(request)
        [ http, request ]
      end

      # One delta of one tool call, folded into what has arrived so far. The
      # provider sends the name once and then the arguments a fragment at a
      # time, indexed per call, so the fragments are concatenated in order.
      def merge_tool_call_delta(accum, tc)
        idx = tc["index"]
        accum[idx] ||= {
          "id" => "",
          "type" => "function",
          "function" => { "name" => "", "arguments" => "" }
        }
        accum[idx]["id"] = tc["id"] if tc["id"]
        if tc.dig("function", "name")
          accum[idx]["function"]["name"] += tc["function"]["name"]
        end
        if tc.dig("function", "arguments")
          accum[idx]["function"]["arguments"] += tc["function"]["arguments"]
        end
      end

      # The frame left in the buffer when the connection closed. Returns
      # { finish_reason:, content: } or nil; a malformed tail is dropped, not
      # raised, because everything before it already reached the caller.
      def trailing_frame(reader)
        last = reader.tail
        return nil if last.nil? || last == "[DONE]"

        data = JSON.parse(last)
        {
          finish_reason: data.dig("choices", 0, "finish_reason"),
          content: data.dig("choices", 0, "delta", "content")
        }
      rescue JSON::ParserError
        nil
      end

      def extract_content(response)
        choice = response.dig("choices", 0)
        return result_hash("") unless choice

        message = choice["message"] || {}
        result_hash(message["content"] || "",
                    finish_reason: choice["finish_reason"],
                    tool_calls: message["tool_calls"],
                    reasoning_content: message["reasoning_content"])
      end
    end
  end
end
