# frozen_string_literal: true

require_relative "store"

module Rubot
  # The archive, served from the main Ractor over a port.
  #
  # A SessionActor cannot open the database itself: SQLite3::Database raises
  # Ractor::UnsafeError from open_v2 inside a non-main Ractor, and no amount of
  # tuning changes that. So one Store lives here, in a thread of the main Ractor
  # (a plain thread outside a Ractor may use SQLite), and actors reach it by
  # sending a request and waiting for the reply.
  #
  # One writer is also the reason there is no SQLITE_BUSY to handle: every append
  # in the process goes through this one thread.
  #
  # Cost of the round trip, measured over 200 requests: 0.47 ms average, 0.98 ms
  # p95, 3.84 ms worst. A turn takes seconds, so the crossing is free; it only
  # matters that it never happens per token.
  class StoreService
    # Raised in the caller when the service reports a failure, so a bad request
    # does not need its own error plumbing at every call site.
    class Error < StandardError; end

    attr_reader :port, :store

    def initialize(store)
      @store = store
      @port = Ractor::Port.new
      @running = true
      @thread = Thread.new { serve }
      @thread.name = "rubot-store"
    end

    # Shareable code, called from inside a session actor:
    #
    #   StoreService.request(port, operation: :load_session, arguments: { id: sid })
    #
    # The reply port is per call, so concurrent callers cannot take each other's
    # answers off a shared queue.
    def self.request(port, operation:, arguments: {})
      reply = Ractor::Port.new
      port << { type: :call, operation: operation, arguments: arguments, port: reply }
      status, value = reply.receive
      raise Error, value.to_s if status == :error

      value
    end

    # The same thing from this Ractor, without a needless copy.
    def call(operation:, arguments: {})
      self.class.request(@port, operation: operation, arguments: arguments)
    end

    def stop
      return unless @running

      @running = false
      @port << { type: :stop }
      @thread.join(2)
      self
    end

    def running? = @running

    private

    def serve
      while @running
        message = @port.receive
        case message[:type]
        when :call
          reply(message[:port], dispatch(message[:operation], message[:arguments] || {}))
        when :stop
          break
        end
      end
    rescue Ractor::ClosedError
      nil
    ensure
      @store.close unless @store.nil?
    end

    # A reply that cannot cross the boundary must still answer the caller: the
    # port it waits on will never be written to otherwise, and a session would
    # hang instead of failing.
    def reply(port, payload)
      port << payload
    rescue Ractor::Error => e
      port << [ :error, "reply could not be sent: #{e.message}" ]
    rescue Ractor::ClosedError
      nil
    end

    # Every operation answers [status, value]: an exception inside one request
    # must not take the thread down and leave every other session without a
    # store.
    def dispatch(operation, arguments)
      result = execute(operation, arguments)
      [ :ok, result ]
    rescue StandardError => e
      [ :error, "#{e.class}: #{e.message}" ]
    end

    def execute(operation, arguments)
      case operation
      when :sidebar
        @store.sidebar(limit: arguments.fetch(:limit, 40))
      when :load_session
        @store.load_session(arguments.fetch(:id), all: arguments.fetch(:all, false))
      when :append_messages
        @store.append_messages(
          arguments.fetch(:session_id),
          arguments.fetch(:messages),
          start_index: arguments.fetch(:start_index, 0)
        )
      when :upsert_session
        @store.upsert_session(**session_attributes(arguments))
        # upsert_session returns the store itself, which cannot cross a Ractor
        # boundary; the caller only needs to know it worked.
        true
      when :last_index
        @store.last_index(arguments.fetch(:session_id))
      when :message_count
        @store.message_count(arguments.fetch(:session_id))
      when :session_ids
        @store.session_ids
      when :append_cache_record
        @store.append_cache_record(
          arguments.fetch(:session_id),
          arguments.fetch(:record)
        )
        # The record hash came from another Ractor; answering with `true` keeps
        # the reply trivially shareable, exactly like upsert_session.
        true
      when :cache_records
        @store.cache_records(arguments.fetch(:session_id), limit: arguments.fetch(:limit, 50))
      when :start_subagent_run
        @store.start_subagent_run(**arguments)
        true
      when :finish_subagent_run
        @store.finish_subagent_run(**arguments)
        true
      when :subagent_runs
        @store.subagent_runs(
          arguments.fetch(:parent_session), limit: arguments.fetch(:limit, 50)
        )
      when :pending_subagent_results
        @store.pending_subagent_results(
          arguments.fetch(:parent_session), limit: arguments.fetch(:limit, 20),
          newest_first: arguments.fetch(:newest_first, false)
        )
      when :mark_subagent_results_reported
        @store.mark_subagent_results_reported(arguments.fetch(:run_ids, []))
      when :release_subagent_results
        @store.release_subagent_results(arguments.fetch(:run_ids, []))
      when :counts
        @store.counts
      when :ig_settings
        @store.settings
      when :ig_execute
        @store.db.execute(arguments.fetch(:sql), arguments.fetch(:params, []))
      when :ig_first_row
        @store.db.get_first_row(arguments.fetch(:sql), arguments.fetch(:params, []))
      when :ig_first_value
        @store.db.get_first_value(arguments.fetch(:sql), arguments.fetch(:params, []))
      when :ig_last_insert_row_id
        @store.db.last_insert_row_id
      when :ig_changes
        @store.db.changes
      when :ig_transaction
        @store.db.transaction { InstagramService.run_statements(@store, arguments.fetch(:statements, [])) }
        true
      else
        raise ArgumentError, "unknown store operation: #{operation.inspect}"
      end
    end

    # Run a batch of plain SQL statements inside one transaction. Only used by
    # the Instagram operations that must be atomic (re-pointing the default
    # account); the statements and their params are plain arrays that crossed
    # the Ractor boundary, so nothing unshareable is touched here.
    module InstagramService
      def self.run_statements(store, statements)
        statements.each { |spec| store.db.execute(spec.fetch("sql"), spec.fetch("params", [])) }
      end
    end

    # Only the four fields upsert_session knows about, so a caller may pass the
    # hash it already has without tripping over an unknown key.
    SESSION_FIELDS = %i[id title created_at updated_at cwd bytes meta messages_start].freeze

    def session_attributes(arguments)
      arguments.select { |key, _| SESSION_FIELDS.include?(key.to_sym) }
                .transform_keys(&:to_sym)
    end
  end
end
