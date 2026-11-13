# frozen_string_literal: true

require "digest"
require "securerandom"
require_relative "openai"

module Rubot
  module Providers
    # OpenCode Go is an OpenAI-compatible gateway, but it is not a generic
    # one: it routes by `x-opencode-session` and keys its prompt cache on that
    # route, and it accepts a system message mid-conversation without losing
    # the cached prefix in front of it (measured: still 2,816 cached tokens
    # after inserting one).
    class OpenCode < OpenAI
      def initialize(config)
        super
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
        unless @extra_headers.key?("x-opencode-session")
          @extra_headers["x-opencode-session"] = routing_session_id
        end
      end

      # A `role: "system"` message in the middle of a conversation keeps the
      # cached prefix on the OpenCode Go gateway: measured there, a system
      # message inserted before the last user turn answered 200 and the two
      # requests that followed still reported the same 2,816 cached tokens.
      def supports_mid_conversation_system?
        true
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
    end
  end
end
