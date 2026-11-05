# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "timeout"
require "yaml"

# Integration tests for the Ractor-backed session/cron actors.
class TestActors < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @config_path = File.join(@tmpdir, "config.yml")
    @server = nil
    @server_thread = nil
  end

  def teardown
    @server&.close rescue nil
    @server_thread&.join(2)
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def write_config(api_base: "http://127.0.0.1:1/v1")
    File.write(@config_path, {
      "agents" => { "defaults" => { "workspace" => @workspace, "name" => "test" } },
      "models" => [
        {
          "name" => "test",
          "model" => "openai/test-model",
          "api_key" => "sk-test",
          "api_base" => api_base
        }
      ]
    }.to_yaml)
    Rubot::Config.new(@config_path)
  end

  # Minimal SSE server that answers every POST with two content chunks.
  def start_sse_server
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]

    @server_thread = Thread.new do
      loop do
        client = @server.accept
        handle_client(client)
      rescue IOError, Errno::EBADF
        break
      rescue StandardError
        nil
      end
    end

    "http://127.0.0.1:#{@port}/v1"
  end

  def handle_client(client)
    headers = +""
    headers << client.readpartial(4096) until headers.include?("\r\n\r\n")
    header, body = headers.split("\r\n\r\n", 2)
    length = header[/Content-Length:\s*(\d+)/i, 1].to_i
    body ||= +""
    body << client.read(length - body.bytesize) if body.bytesize < length

    sse = +""
    sse << "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n"
    sse << "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n"
    sse << "data: [DONE]\n\n"

    client.write("HTTP/1.1 200 OK\r\n")
    client.write("Content-Type: text/event-stream\r\n")
    client.write("Content-Length: #{sse.bytesize}\r\n")
    client.write("Connection: close\r\n\r\n")
    client.write(sse)
  ensure
    client.close rescue nil
  end

  def test_session_handle_processes_a_turn_through_the_actor
    api_base = start_sse_server
    config = write_config(api_base: api_base)
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      handle = pool.for("actor-test")
      chunks = []
      response = handle.process("hi") { |chunk| chunks << chunk }

      assert_equal "Hello world", response
      assert_equal [ "Hello", " world" ], chunks
      assert_equal "actor-test", handle.session.id
      assert_equal 2, handle.session.message_count
      assert File.exist?(File.join(@workspace, "sessions", "actor-test.json"))
    ensure
      pool.shutdown
    end
  end

  def test_flush_learning_is_available_through_the_actor
    api_base = start_sse_server
    config = write_config(api_base: api_base)
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      handle = pool.for("learning-test")
      handle.process("hello there friend")

      # One message is below the default batch size, so this is a no-op that
      # must still complete without raising across the Ractor boundary.
      assert_nil handle.flush_learning
    ensure
      pool.shutdown
    end
  end

  def test_sessions_are_isolated_from_each_other
    api_base = start_sse_server
    config = write_config(api_base: api_base)
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      a = pool.for("session-a")
      b = pool.for("session-b")

      assert_equal "Hello world", a.process("hi")
      assert_equal 2, a.session.message_count
      assert_equal 0, b.session.message_count
      assert_equal %w[session-a session-b], pool.session_ids.sort
    ensure
      pool.shutdown
    end
  end

  def test_session_control_requests
    config = write_config
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      handle = pool.for("control")

      assert_equal "test-model", handle.active_model_name
      assert_equal "openai", handle.provider.name
      assert_equal [ "test" ], handle.config.models.map { |m| m["name"] }
      assert_equal @workspace, handle.config.workspace
      assert_includes handle.tools.names, "cron"
      refute handle.skill_registry.any?
      assert handle.memory.enabled?
    ensure
      pool.shutdown
    end
  end

  def test_pool_applies_persona_from_store_when_spawning
    config = write_config
    File.write(File.join(@workspace, "personas.json"), JSON.generate(
      "-100123:42" => {
        "name" => "trading",
        "model" => "test",
        "system_prompt" => "Kamu adalah asisten trading."
      }
    ))
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      handle = pool.for("tg_-100123_42")

      assert_equal "test-model", handle.active_model_name
      assert_equal "trading", handle.persona["name"]
      assert_equal "Kamu adalah asisten trading.", handle.persona["system_prompt"]
      assert_nil pool.for("tg_123").persona, "General topic must use the default persona"
    ensure
      pool.shutdown
    end
  end

  def test_set_persona_op_updates_a_live_session
    config = write_config
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      handle = pool.for("tg_-100123_42")
      assert_nil handle.persona

      applied = handle.set_persona(
        "name" => "trading",
        "model" => "test",
        "system_prompt" => "Jawab singkat."
      )

      assert_equal "Jawab singkat.", applied["system_prompt"]
      assert_equal "Jawab singkat.", handle.persona["system_prompt"]
      assert_equal "test-model", handle.active_model_name

      assert_nil handle.set_persona(nil)
      assert_nil handle.persona
    ensure
      pool.shutdown
    end
  end

  def test_cron_actor_add_list_and_remove
    config = write_config
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      add = pool.cron.call(
        operation: "add",
        arguments: {
          "operation" => "add",
          "message" => "ping",
          "every_seconds" => 60
        }
      )
      assert_includes add, "ping"

      list = pool.cron.call(operation: "list", arguments: { "operation" => "list" })
      assert_includes list, "ping"

      job_id = list[/`([^`]+)`/, 1]
      removed = pool.cron.call(
        operation: "remove",
        arguments: { "operation" => "remove", "job_id" => job_id }
      )
      assert_includes removed, "removed"
    ensure
      pool.shutdown
    end
  end

  def test_cron_actor_delivers_fired_jobs
    delivery = Ractor::Port.new
    config = write_config
    pool = Rubot::Actors::SessionPool.new(config: config, delivery: delivery)

    begin
      pool.cron.call(
        operation: "add",
        arguments: {
          "operation" => "add",
          "message" => "ping",
          "at_seconds" => 1
        }
      )

      sleep 1.1
      fired = pool.cron.fire_due
      assert_equal 1, fired.size

      event = delivery.receive
      assert_equal :cron_fire, event[0]
      assert_equal "ping", event[1][:result][:agent_message]
    ensure
      pool.shutdown
    end
  end

  # Exercises the wire protocol without a real Agent: a fake actor replies
  # with the same event shapes a SessionActor produces.
  # Regression (real actor code path): handle_message must create the
  # confirmation port itself, otherwise control.receive raises
  # "only allowed from the creator Ractor of this port".
  def test_session_actor_confirmation_round_trip
    ractor = Ractor.new do
      agent = Class.new do
        def process(_text, on_confirm: nil, **_callbacks)
          approved = on_confirm.call("shell_exec", { "command" => "rm -rf build" })
          approved ? "approved" : "rejected"
        end
      end.new

      msg = Ractor.receive
      Rubot::Actors::SessionActor.handle_message(agent, msg)
    end

    handle = Rubot::Actors::SessionHandle.new(ractor, "real-confirm")
    asked = []

    response = Timeout.timeout(5) do
      handle.process("go", on_confirm: ->(name, args) {
        asked << [ name, args ]
        true
      })
    end

    assert_equal "approved", response
    assert_equal [ [ "shell_exec", { "command" => "rm -rf build" } ] ], asked
  ensure
    begin
      ractor&.send({ type: :shutdown })
    rescue StandardError
      nil # the actor exits after serving one message
    end
    ractor&.join
  end

  # Regression: the confirmation port must be created by the session Ractor,
  # because Ractor::Port#receive only works in the Ractor that created it.
  def test_session_handle_confirm_round_trip
    ractor = Ractor.new do
      loop do
        msg = Ractor.receive
        case msg[:type]
        when :message
          control = Ractor::Port.new
          msg[:events] << [ :control, control ]
          msg[:events] << [ :confirm, "abc123", "shell_exec", { "command" => "rm -rf build" } ]
          reply = control.receive
          control.close
          msg[:events] << [ :chunk, reply.inspect ]
          msg[:events] << [ :done, "done" ]
        when :shutdown
          break
        end
      end
    end

    handle = Rubot::Actors::SessionHandle.new(ractor, "fake-confirm")
    asked = []
    chunks = []

    response = Timeout.timeout(5) do
      handle.process("go", on_confirm: ->(name, args) {
        asked << [ name, args ]
        true
      }) { |chunk| chunks << chunk }
    end

    assert_equal "done", response
    assert_equal [ [ "shell_exec", { "command" => "rm -rf build" } ] ], asked
    assert_equal [ [ :confirm_result, "abc123", true ].inspect ], chunks
  ensure
    ractor&.send({ type: :shutdown })
    ractor&.join
  end

  # A failing confirmation callback must fail closed, not hang the actor.
  def test_session_handle_confirm_error_fails_closed
    ractor = Ractor.new do
      loop do
        msg = Ractor.receive
        case msg[:type]
        when :message
          control = Ractor::Port.new
          msg[:events] << [ :control, control ]
          msg[:events] << [ :confirm, "abc123", "shell_exec", { "command" => "rm -rf build" } ]
          reply = control.receive
          control.close
          msg[:events] << [ :chunk, reply.inspect ]
          msg[:events] << [ :done, "done" ]
        when :shutdown
          break
        end
      end
    end

    handle = Rubot::Actors::SessionHandle.new(ractor, "fake-confirm-error")
    chunks = []

    response = Timeout.timeout(5) do
      handle.process("go", on_confirm: ->(_name, _args) { raise "network down" }) { |chunk| chunks << chunk }
    end

    assert_equal "done", response
    assert_equal [ [ :confirm_result, "abc123", false ].inspect ], chunks
  ensure
    ractor&.send({ type: :shutdown })
    ractor&.join
  end

  def test_session_handle_translates_events
    ractor = Ractor.new do
      loop do
        msg = Ractor.receive
        case msg[:type]
        when :request
          msg[:port] << [ :ok, msg[:op] ]
        when :message
          msg[:events] << [ :chunk, "he" ]
          msg[:events] << [ :assistant_text, "Checking first." ]
          msg[:events] << [ :tool_started, "shell_exec", { "command" => "ls" } ]
          msg[:events] << [ :progress, 1, 1 ]
          msg[:events] << [ :done, "#{msg[:text]}!" ]
        when :shutdown
          break
        end
      end
    end

    handle = Rubot::Actors::SessionHandle.new(ractor, "fake")
    tool_calls = []
    chunks = []
    narrations = []
    response = handle.process(
      "hi",
      on_tool_call: ->(name, args) { tool_calls << [ name, args ] },
      on_assistant_text: ->(text) { narrations << text }
    ) do |chunk|
      chunks << chunk
    end

    assert_equal "hi!", response
    assert_equal [ "he" ], chunks
    assert_equal [ "Checking first." ], narrations
    assert_equal [ [ "shell_exec", { "command" => "ls" } ] ], tool_calls
    assert_equal :info, handle.call(:info)
  ensure
    ractor&.send({ type: :shutdown })
    ractor&.join
  end
end

class TestActorModelPresets < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @config_path = File.join(@tmpdir, "config.yml")

    File.write(@config_path, {
      "agents" => { "defaults" => {
        "workspace" => @workspace,
        "name" => "test",
        "model_preset" => "fast"
      } },
      "models" => [
        {
          "name" => "test",
          "model" => "openai/fast-model",
          "api_key" => "sk-test",
          "api_base" => "http://127.0.0.1:1/v1"
        }
      ],
      "model_presets" => {
        "fast" => { "model" => "fast-model", "max_tokens" => 1024, "temperature" => 0.2 },
        "deep" => { "model" => "deep-model", "max_tokens" => 8192, "temperature" => 0.1 }
      }
    }.to_yaml)

    @config = Rubot::Config.new(@config_path)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def test_actor_exposes_and_switches_model_presets
    pool = Rubot::Actors::SessionPool.new(config: @config)

    begin
      handle = pool.for("preset-actor")

      assert_equal "fast", handle.active_model_preset["name"]
      assert_equal "fast-model", handle.active_model_name
      assert_equal %w[fast deep], handle.model_presets.map { |preset| preset["name"] }

      applied = handle.use_model_preset("deep")

      assert_equal "deep", applied["name"]
      assert_equal "deep-model", applied["model"]
      assert_equal "deep-model", handle.active_model_name
      assert_equal "deep", handle.session.model_preset

      other = pool.for("another-actor")
      assert_equal "fast", other.active_model_preset["name"]
    ensure
      pool.shutdown
    end
  end
end
