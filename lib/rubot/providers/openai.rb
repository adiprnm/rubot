# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "securerandom"
require "uri"
require_relative "../provider"

module Rubot
  module Providers
    class OpenAI < Provider
      def initialize(config)
        super
        @extra_headers = {}

        if @config.respond_to?(:extra_headers) && @config.extra_headers.is_a?(Hash)
          @extra_headers.merge!(@config.extra_headers)
        end

        # OpenCode Go requires a per-session routing header, and it keys its
        # prompt cache on it: two requests with the same header share a cached
        # prefix, two requests with different headers share nothing. Measured
        # against the gateway, the same conversation re-sent under a fresh
        # header read 0 cached tokens where the old header still read 2816 of
        # 2833.
        #
        # So the value has to be the *conversation*, not the provider object.
        # A random value per instance meant every rebuild — a model switch, a
        # thinking-level change, a resumed session after a restart — started
        # the cache from zero while the conversation had not moved.
        if opencode_routing? && !@extra_headers.key?("x-opencode-session")
          @extra_headers["x-opencode-session"] = routing_session_id
        end
      end

      # A `role: "system"` message in the middle of a conversation keeps the
      # cached prefix on the OpenCode Go gateway: measured there, a system
      # message inserted before the last user turn answered 200 and the two
      # requests that followed still reported the same 2,816 cached tokens.
      # Other OpenAI-compatible endpoints are left to opt in — a wrong `true`
      # would lose the prefix this is meant to protect.
      def supports_mid_conversation_system?
        opencode_routing?
      end

      # The gateway asks for `x-opencode-session` on its own host, and pi also
      # treats the provider name as the same target (see isOpenCode in its
      # client). Both, because a gateway can be addressed by name with a
      # different base URL — and that is exactly how the routing behaviour gets
      # tested without a network.
      def opencode_routing?
        name = @config.provider.to_s.downcase
        return true if name == "opencode" || name == "opencode-go"

        api_base.include?("opencode.ai/zen")
      end

      # A digest, not the raw session id: the header is an opaque routing key,
      # and a stable one is what the cache needs. Deterministic across
      # restarts, which is the point — a resumed session keeps its route,
      # while the transcript it re-sends is still inside the provider's
      # five-minute window.
      def routing_session_id
        key = @config.respond_to?(:session_key) ? @config.session_key.to_s : ""
        return SecureRandom.hex(16) if key.empty?

        Digest::SHA256.hexdigest(key)[0, 32]
      end

      def chat(messages, tools: nil)
        reset_last_usage!
        payload = build_payload(messages, tools)
        response = make_request(payload)
        track_usage(response["usage"])
        extract_content(response)
      end

      def chat_stream(messages, tools: nil, &on_chunk)
        reset_last_usage!
        payload = build_payload(messages, tools, stream: true)
        make_stream_request(payload, &on_chunk)
      end

      # GET /models — OpenAI-compatible providers (including OpenCode Go)
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

      def make_request(payload)
        Rubot::Cancellation.check!
        uri = URI("#{api_base}/chat/completions")

        log_debug("Request: #{JSON.generate(payload)}")
        # Nothing streams here, so the whole wait is one number: there is no
        # first byte to separate it from.
        started = Rubot::Timing.clock
        response = with_retry do
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
        log_debug("Response: #{response.code} - #{response.body[0..500]}")

        unless response.code.to_i == 200
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

      def make_stream_request(payload, &on_chunk)
        Rubot::Cancellation.check!
        uri = URI("#{api_base}/chat/completions")
        log_debug("Stream request: #{JSON.generate(payload)}")

        buffer = ""
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

        with_retry(retryable: -> { accumulated.empty? }) do
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 30
          http.read_timeout = 300

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/json"
          request["Authorization"] = "Bearer #{@config.api_key}"
          apply_extra_headers(request)

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
                # The user may have stopped the turn: unwinding here closes the
                # response and aborts the request instead of streaming the rest
                # of the answer first.
                Rubot::Cancellation.check!
                buffer += chunk
                while (newline_idx = buffer.index("\n"))
                  line = buffer[0...newline_idx].strip
                  buffer = buffer[(newline_idx + 1)..] || ""
                  next if line.empty?
                  next unless line.start_with?("data: ")

                  data_str = line[6..]
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
          end

          # A provider that closes the connection mid-frame leaves the last
          # event in the buffer with no trailing newline. Parse it instead of
          # dropping it, so the tail of the answer is not lost.
          unless buffer.strip.empty?
            line = buffer.strip
            if line.start_with?("data: ") && line[6..] != "[DONE]"
              begin
                data = JSON.parse(line[6..])
                finish_reason = data.dig("choices", 0, "finish_reason") || finish_reason
                tail = data.dig("choices", 0, "delta", "content")
                if tail
                  accumulated += tail
                  yield tail, nil if on_chunk
                end
              rescue JSON::ParserError
                # skip malformed trailing frame
              end
            end
            buffer = ""
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
