# frozen_string_literal: true

require "digest"
require "json"

module Rubot
  # A per-block fingerprint of one request, and the answer to "where did this
  # request stop matching the one before it?".
  #
  # A cache hit rate says a request missed. The digests the session already
  # keeps say *which* of the three things a prefix is made of changed (the
  # pinned prompt, the tool catalog, the history) but not where inside them.
  # That is enough for a prompt edit and useless for the interesting case: a
  # request that appended one message and still missed, because a block in the
  # middle of the transcript was rewritten.
  #
  # So: one short digest per block, in the order a provider hashes them — the
  # system prompt, then every tool definition, then every message. Compare the
  # list against the previous request's and the first index that differs is the
  # block that broke the prefix. `diverged_at` is stored with the request, and
  # the fingerprint is stored for the newest request only (see Store), because
  # one request is all the next comparison needs.
  module CacheProbe
    # A 16-hex-character prefix of SHA-256 (64 bits). Full digests would be
    # four times the size for a diagnosis nobody reads by hand, and 64 bits is
    # far past the point where a collision between two blocks of one prompt is
    # a realistic explanation for a miss.
    DIGEST_CHARS = 16

    # Block kinds, so a fingerprint reads as what it is: `s` is the system
    # prompt, `t` a tool definition, `m` a message.
    SYSTEM = "s"
    TOOL = "t"
    MESSAGE = "m"

    module_function

    # The blocks of one request, in provider order, joined into one string.
    #
    # `tools` is anything that answers to `name`, `description` and
    # `parameters` (a Tool), and `messages` is the provider-shaped list — the
    # same list that was sent, not the session's, so a trimmed window is
    # fingerprinted as it was sent.
    def fingerprint(system:, tools: [], messages: [])
      blocks = [ entry(SYSTEM, system) ]
      tools.each do |tool|
        blocks << entry(TOOL, [ tool.name, tool.description, tool.parameters ].to_json)
      end
      messages.each { |message| blocks << entry(MESSAGE, JSON.generate(message)) }
      blocks.join(",")
    end

    # Index of the first block where `current` stops matching `previous`.
    #
    # - nil when there is nothing to compare against (the first request of a
    #   session, or a session that predates the fingerprint).
    # - -1 when the whole of `previous` is still a prefix of `current`: the
    #   request only appended, which is the shape of a request that should hit.
    # - an index otherwise. A message rewritten in the middle reports that
    #   message's index; a changed system prompt reports 0; a changed tool
    #   reports its position after the system prompt.
    #
    # A shorter `current` that matches `previous` all the way is reported at
    # `current`'s length: the history was cut, and everything the provider
    # cached past that point is gone.
    def first_divergence(previous, current)
      return nil if previous.nil? || current.nil?

      before = previous.to_s.split(",")
      now = current.to_s.split(",")
      shared = [ before.size, now.size ].min

      shared.times do |index|
        return index unless before[index] == now[index]
      end

      return now.size if now.size < before.size

      -1
    end

    # How many blocks a fingerprint holds. Kept here so the caller does not
    # have to know the separator.
    def block_count(fingerprint)
      return 0 if fingerprint.nil? || fingerprint.to_s.empty?

      fingerprint.to_s.count(",") + 1
    end

    # What kind of block sits at an index, for a reader that wants words
    # instead of a number. `tools` is the number of tool definitions sent.
    def block_kind(index, tools: 0)
      return nil if index.nil?
      return nil if index.negative?
      return SYSTEM if index.zero?
      return TOOL if index <= tools.to_i

      MESSAGE
    end

    def entry(kind, value)
      "#{kind}#{Digest::SHA256.hexdigest(value.to_s)[0, DIGEST_CHARS]}"
    end
  end
end
