# frozen_string_literal: true

require_relative "openai"

module Rubot
  module Providers
    # OpenCode Go is an OpenAI-compatible gateway, but it is not a generic
    # one: it routes by `x-opencode-session` and keys its prompt cache on that
    # route, and it accepts a system message mid-conversation without losing
    # the cached prefix in front of it (measured: still 2,816 cached tokens
    # after inserting one).
    #
    # Both facts are properties of this gateway, not of a URL string, so they
    # live here instead of as host checks inside OpenAI. The base class keeps
    # the same checks as a fallback for a config that addresses the gateway by
    # name with a different base URL.
    class OpenCode < OpenAI
      def supports_mid_conversation_system?
        true
      end

      def opencode_routing?
        true
      end
    end
  end
end
