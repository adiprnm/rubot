# frozen_string_literal: true

require_relative "store_service"

module Rubot
  # A Session's handle on the archive.
  #
  # It holds nothing but a port, so it can be built inside a session actor and
  # shared by the Agent and Session that live there. All the work happens in
  # StoreService on the main Ractor, where SQLite is allowed.
  #
  # Deliberately dumb: `load` returns what the store holds, `append` writes only
  # the messages it is given. Deciding which messages are new is Session's job
  # (it tracks the offset), not this one's.
  class StoreClient
    def initialize(port)
      @port = port
    end

    # @return [Hash, nil] { messages:, meta:, start: } or nil when unknown
    def load(id)
      result = request(:load_session, id: id)
      return nil unless result

      {
        messages: result[:messages] || [],
        meta: result[:meta] || {},
        start: result[:start].to_i
      }
    end

    def append(id, messages, start_index:)
      request(:append_messages, session_id: id, messages: messages, start_index: start_index)
    end

    def save_meta(id, meta:, messages_start:, title: nil, cwd: nil, created_at: nil)
      request(
        :upsert_session,
        id: id,
        title: title.to_s,
        cwd: cwd,
        meta: meta,
        messages_start: messages_start,
        created_at: created_at
      )
    end

    def message_count(id)
      request(:message_count, session_id: id)
    end

    # One row per provider request, for the cache diagnosis (see
    # Store#append_cache_record). `record` is a plain hash of strings and
    # numbers so it can cross the port.
    def record_cache(id, record)
      request(:append_cache_record, session_id: id, record: record)
    end

    def cache_records(id, limit: 50)
      request(:cache_records, session_id: id, limit: limit)
    end

    private

    def request(operation, **arguments)
      StoreService.request(@port, operation: operation, arguments: arguments)
    end
  end
end
