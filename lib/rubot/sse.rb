# frozen_string_literal: true

require_relative "provider"

module Rubot
  # The half of reading a server-sent event stream that does not depend on
  # which provider is speaking: framing, cancellation, and classifying the
  # error a provider sends instead of a stream. What the JSON inside a frame
  # means stays with the provider.
  #
  # This sits beside Provider rather than inside providers/ on purpose: it is
  # transport, not an implementation of the provider contract.
  module Sse
    module_function

    # A refused streaming call never streams: the error arrives in one piece
    # and has to be read before it can be classified. The retry hint comes
    # from a block because reading it costs a header lookup that is only
    # worth doing when the status says the wait is the point.
    def raise_for_response(response)
      return if response.code.to_i == 200

      body = +""
      response.read_body { |b| body << b }
      if Rubot::Provider.quota_exhausted_text?(body)
        raise QuotaExhaustedError.new(nil, message: "API error #{response.code}: #{body}")
      end
      raise RateLimitError.new(yield) if response.code.to_i == 429

      raise "API error #{response.code}: #{body}"
    end

    # Turns a socket that hands over arbitrary chunks into whole frames. Both
    # providers speak the `data: {...}` dialect; this class only knows where a
    # frame starts and ends.
    class Reader
      def initialize
        @buffer = +""
      end

      # Feed one chunk, answering with the payload of every frame it completes.
      # Cancellation is checked per chunk so a cancelled turn stops reading
      # instead of draining a provider that is still talking.
      def feed(chunk)
        Rubot::Cancellation.check!
        @buffer << chunk
        frames = []
        while (newline = @buffer.index("\n"))
          line = @buffer[0...newline].strip
          @buffer = @buffer[(newline + 1)..] || +""
          next if line.empty?
          next unless line.start_with?("data: ")

          frames << line[6..]
        end
        frames
      end

      # A provider that closes the connection mid-frame leaves the last event
      # in the buffer with no trailing newline. Hand it back instead of
      # dropping it, so the tail of the answer is not lost.
      def tail
        line = @buffer.strip
        @buffer = +""
        return nil unless line.start_with?("data: ")

        line[6..]
      end
    end
  end
end
