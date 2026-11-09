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
    @requests = 0
    @bodies = []
    @requests_mutex = Mutex.new
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
  # A delay keeps the request in flight, which is what a /stop interrupts.
  def start_sse_server(delay: 0)
    @sse_delay = delay
    @requests = 0
    @bodies = []
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

    @requests_mutex.synchronize do
      @requests += 1
      @bodies << body
    end

    sleep @sse_delay if @sse_delay&.positive?

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
      assert File.exist?(File.join(config.sessions_dir, "actor-test.json"))
    ensure
      pool.shutdown
    end
  end

  def request_count
    @requests_mutex.synchronize { @requests }
  end

  def request_bodies
    @requests_mutex.synchronize { @bodies.dup }
  end

  # The post-answer learning pass sends a naming request before (and apart
  # from) memory extraction, so the two are counted separately rather than
  # lumped into the total.
  def naming_request_count
    request_bodies.count { |body| body.include?("You name conversations") }
  end

  def extraction_request_count
    request_bodies.count { |body| body.include?("memory extraction assistant") }
  end

  # Regression: last_user_message reads Agent::CONTINUE_PROMPT and friends from
  # inside the session Ractor. When those strings are not frozen, every
  # post-answer learning pass dies with Ractor::IsolationError, and because
  # flush_learning rescues it the bot looks healthy while extraction silently
  # never runs. The backlog is the observable difference.
  def test_flush_learning_runs_extraction_inside_the_actor
    api_base = start_sse_server
    config = write_config(api_base: api_base)
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      handle = pool.for("learning-ractor")
      handle.process("I live in Jakarta and work on Ruby")
      handle.process("I prefer short answers please")
      handle.process("My project is called rubot")

      assert_equal 3, request_count

      # Default batch size is 3, so this flush must reach the provider once,
      # plus the one request that names the conversation.
      handle.flush_learning

      assert_equal 1, extraction_request_count, "the batched extraction request must be sent"
      assert_equal 1, naming_request_count, "the first flush names the conversation"
      session = JSON.parse(File.read(File.join(config.sessions_dir, "learning-ractor.json")))
      assert_empty Array(session["memory_backlog"]), "the batch must be consumed by extraction"
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

      # One message is below the default batch size, so extraction is a no-op
      # that must still complete without raising across the Ractor boundary.
      assert_nil handle.flush_learning
      assert_equal 0, extraction_request_count, "a flush below the batch size must not extract"
      assert_equal 1, naming_request_count, "but the conversation is still named"
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

  def test_stop_cancels_a_running_turn
    api_base = start_sse_server(delay: 1)
    config = write_config(api_base: api_base)
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      handle = pool.for("stop-test")
      response = nil
      runner = Thread.new { response = handle.process("hi") }

      sleep 0.2
      # A fresh handle for the same session must be able to signal the busy
      # actor; a normal request would queue behind the turn it stops.
      assert pool.for("stop-test").cancel!, "the stop signal must reach the session actor"

      assert runner.join(10), "the turn must end after /stop"
      assert_equal Rubot::Agent::STOP_NOTICE, response
      assert_equal 1, handle.session.message_count, "only the user message was kept"
    ensure
      pool.shutdown
    end
  end

  def test_steer_reaches_a_busy_turn_and_gets_its_own_round
    api_base = start_sse_server(delay: 0.3)
    config = write_config(api_base: api_base)
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      handle = pool.for("steer-test")
      steered = []
      runner = Thread.new do
        handle.process("hi", on_steer: ->(text) { steered << text })
      end

      sleep 0.15
      # A fresh handle for the same session must reach the busy actor; a
      # normal request would only be read after the turn it steers.
      assert pool.for("steer-test").steer("focus on the logs"),
             "the steer must reach the session actor"

      assert runner.join(10), "the turn must finish"
      assert_equal [ "focus on the logs" ], steered, "the steer is reported when delivered"
      assert_equal 2, request_count, "the steer opens a second round"
      assert_includes request_bodies.last, "focus on the logs"
      assert_equal 4, handle.session.message_count,
                   "user, the first answer, the steered user turn, the final answer"
    ensure
      pool.shutdown
    end
  end

  # A request must not queue behind a turn, whatever it does: the turn runs on
  # its own thread inside the actor, so the loop is free to answer. Reads and
  # writes both, since /clear and /usage are as ordinary as /help.
  def test_requests_are_answered_while_a_turn_is_running
    api_base = start_sse_server(delay: 1)
    config = write_config(api_base: api_base)
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      handle = pool.for("read-during-turn")
      runner = Thread.new { handle.process("hi") }
      sleep 0.2

      # A fresh handle for the same session, the way a /command gets one.
      reader = pool.for("read-during-turn")
      name = nil
      queried = Thread.new { name = reader.active_model_name }

      assert queried.join(0.6), "the read answers without waiting for the turn"
      assert_equal "test-model", name

      # A write is answered just as promptly. It is allowed to change what the
      # turn is working on — that is the user's call to make mid-answer.
      flipped = nil
      writer = Thread.new { flipped = reader.set_auto_approve(true) }
      assert writer.join(0.6), "a write is answered without waiting for the turn"
      assert flipped

      assert runner.join(10), "the turn still finishes"
    ensure
      pool.shutdown
    end
  end

  # One turn at a time: a second message waits for the first one instead of
  # running beside it on the same agent.
  def test_a_second_message_waits_for_the_turn_in_flight
    api_base = start_sse_server(delay: 0.3)
    config = write_config(api_base: api_base)
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      handle = pool.for("serial-turns")
      order = Queue.new
      first = Thread.new { handle.process("first") && order << :first_done }
      sleep 0.1
      second = Thread.new { handle.process("second") && order << :second_done }

      assert first.join(10) && second.join(10), "both turns finish"
      assert_equal [ :first_done, :second_done ], [ order.pop, order.pop ],
                   "the second turn runs after the first, not beside it"
      assert_equal 4, handle.session.message_count, "two user turns, two answers"
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

  def test_session_handle_exposes_the_provider_models
    config = write_config
    File.write(File.join(@workspace, "model_catalog.json"), JSON.generate(
      "models" => [ { "id" => "deepseek-v4-pro", "name" => "DeepSeek V4 Pro" } ]
    ))
    pool = Rubot::Actors::SessionPool.new(config: config)

    begin
      handle = pool.for("models")

      assert_equal [ "deepseek-v4-pro" ], handle.provider_models.map { |model| model["id"] }
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
          approved = on_confirm.call("shell_exec", { "command" => "rm -rf build" }, "deletes files")
          approved ? "approved" : "rejected"
        end
      end.new

      msg = Ractor.receive
      Rubot::Actors::SessionActor.handle_message(agent, msg)
    end

    handle = Rubot::Actors::SessionHandle.new(ractor, "real-confirm")
    asked = []

    response = Timeout.timeout(5) do
      handle.process("go", on_confirm: ->(name, args, reason) {
        asked << [ name, args, reason ]
        true
      })
    end

    assert_equal "approved", response
    assert_equal [ [ "shell_exec", { "command" => "rm -rf build" }, "deletes files" ] ], asked
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
      handle.process("go", on_confirm: ->(name, args, _reason) {
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
      handle.process("go", on_confirm: ->(_name, _args, _reason) { raise "network down" }) { |chunk| chunks << chunk }
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
      on_tool_call: ->(name, args, _snapshot) { tool_calls << [ name, args ] },
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

  # A 429 is not a bug, so it must reach the caller as a RateLimitError with a
  # readable message instead of an ActorError carrying a stack trace from
  # inside the session Ractor.
  def test_session_handle_keeps_rate_limit_error_class
    ractor = Ractor.new do
      loop do
        msg = Ractor.receive
        case msg[:type]
        when :message
          msg[:events] << [ :error, "Rubot::RateLimitError",
                            "Rate limited by the provider (429 Too Many Requests) after 6 attempts.",
                            [ "lib/rubot/providers/openai.rb:175" ] ]
        when :shutdown
          break
        end
      end
    end

    handle = Rubot::Actors::SessionHandle.new(ractor, "fake-rate-limit")
    error = assert_raises(Rubot::RateLimitError) do
      Timeout.timeout(5) { handle.process("hi") }
    end

    assert_includes error.message, "429"
    refute_includes error.message, "openai.rb:175" unless Rubot.debug?
  ensure
    ractor&.send({ type: :shutdown })
    ractor&.join
  end

  def test_session_handle_wraps_unknown_errors_as_actor_error
    ractor = Ractor.new do
      loop do
        msg = Ractor.receive
        case msg[:type]
        when :message
          msg[:events] << [ :error, "RuntimeError", "boom", [ "lib/rubot/agent.rb:1" ] ]
        when :shutdown
          break
        end
      end
    end

    handle = Rubot::Actors::SessionHandle.new(ractor, "fake-unknown-error")
    error = assert_raises(Rubot::Actors::ActorError) do
      Timeout.timeout(5) { handle.process("hi") }
    end

    assert_includes error.message, "RuntimeError: boom"
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

# Constants the tools read while running inside a session Ractor have to be
# shareable. A constant that is only frozen at the top level (an Array of
# Arrays, a Hash of Hashes) is not: reading it from a non-main Ractor raises
# Ractor::IsolationError, which reaches the user as "Action failed" in the
# middle of a turn. This caught exactly that after the destructive-action
# labels were added.
class TestRactorShareableConstants < Minitest::Test
  CONSTANTS = %w[
    Rubot::Tools::Shell::DESTRUCTIVE_PATTERNS
    Rubot::TUI::AUTO_TOGGLE
    Rubot::Channels::Telegram::AUTO_TOGGLE
  ].freeze

  def test_tool_constants_are_shareable
    CONSTANTS.each do |name|
      value = Object.const_get(name)
      assert Ractor.shareable?(value), "#{name} must be deeply frozen to cross a Ractor"
    end
  end

  # The real check: the tool that reads them, used from a Ractor.
  def test_shell_patterns_can_be_read_inside_a_ractor
    ractor = Ractor.new do
      Rubot::Tools::Shell.new.dangerous_action_reason({ "command" => "rm -rf build" })
    end

    assert_equal "deletes files", ractor.value
  end

  def test_auto_mode_toggle_is_readable_inside_a_ractor
    ractor = Ractor.new { Rubot::TUI::AUTO_TOGGLE["on"] }

    assert_equal true, ractor.value
  end
end
