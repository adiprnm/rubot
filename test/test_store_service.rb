# frozen_string_literal: true

require_relative "test_helper"

class TestStoreService < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rubot-store-service")
    @store = Rubot::Store.new(File.join(@dir, "sessions.db"))
    @service = Rubot::StoreService.new(@store)
  end

  def teardown
    @service&.stop
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def test_sidebar_round_trips
    @service.call(operation: :append_messages, arguments: message_args)

    rows = @service.call(operation: :sidebar, arguments: { limit: 10 })

    assert_equal 1, rows.size
    assert_equal "s1", rows[0][:id]
    assert_equal 1, rows[0][:messages]
  end

  def test_append_and_load
    count = @service.call(operation: :append_messages, arguments: message_args)
    loaded = @service.call(operation: :load_session, arguments: { id: "s1" })

    assert_equal 1, count
    assert_equal "halo", loaded[:messages][0]["content"]
  end

  def test_upsert_session_ignores_unknown_keys
    @service.call(operation: :upsert_session, arguments: message_args(first: true))
    @service.call(
      operation: :upsert_session,
      arguments: { id: "s1", title: "judul", persona: "rubot", session_id: "lain" }
    )

    assert_equal "judul", @service.call(operation: :sidebar, arguments: {}).first[:title]
  end

  def test_upsert_session_answers_true_not_the_store
    # The store cannot cross a Ractor boundary; the reply has to be a primitive.
    assert_equal true, @service.call(
      operation: :upsert_session,
      arguments: { id: "s1", title: "judul" }
    )
  end

  def test_unknown_operation_raises_without_killing_the_service
    error = assert_raises(Rubot::StoreService::Error) do
      @service.call(operation: :tidak_ada)
    end

    assert_match(/unknown store operation/, error.message)
    assert @service.running?
    assert_equal 0, @service.call(operation: :counts)[:messages]
  end

  def test_a_bad_request_does_not_take_the_thread_down
    assert_raises(Rubot::StoreService::Error) do
      @service.call(operation: :load_session, arguments: {})
    end

    assert @service.running?
    assert_equal 0, @service.call(operation: :counts)[:sessions]
  end

  # The point of the service: a session actor is a Ractor and cannot open the
  # database itself. This is the crossing that has to work.
  def test_an_actor_can_use_the_store_through_the_port
    port = @service.port

    actor = Ractor.new(port) do |service_port|
      Rubot::StoreService.request(
        service_port,
        operation: :append_messages,
        arguments: { session_id: "dari_ractor", messages: [ { "role" => "user", "content" => "hai" } ] }
      )
      Rubot::StoreService.request(service_port, operation: :message_count, arguments: { session_id: "dari_ractor" })
    end

    assert_equal 1, actor.value
    assert_equal 1, @store.message_count("dari_ractor")
  end

  def test_concurrent_actors_do_not_lose_rows
    port = @service.port

    actors = 6.times.map do |i|
      Ractor.new(port, i) do |service_port, n|
        Rubot::StoreService.request(
          service_port,
          operation: :append_messages,
          arguments: {
            session_id: "sesi_#{n}",
            messages: 4.times.map { |k| { "role" => "user", "content" => "pesan #{n}-#{k}" } }
          }
        )
      end
    end

    assert_equal [ 4, 4, 4, 4, 4, 4 ], actors.map(&:value)
    assert_equal 24, @service.call(operation: :counts)[:messages]
  end

  def test_stop_closes_the_store
    @service.call(operation: :counts)
    @service.stop

    refute @service.running?
  end

  private

  def message_args(first: false)
    args = { session_id: "s1", messages: [ { "role" => "user", "content" => "halo" } ] }
    args[:id] = "s1" if first
    args
  end
end
