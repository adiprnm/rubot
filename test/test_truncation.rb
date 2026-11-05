# frozen_string_literal: true

require_relative "test_helper"
require "socket"

# A model that runs out of output budget mid-sentence used to look exactly like
# a model that had finished: rubot sent the fragment, and when the model went
# silent after a tool round it sent the raw tool output instead of an answer.
# These tests cover both halves.
class TestProviderTruncation < Minitest::Test
  def openai_provider(api_base: "http://127.0.0.1:1/v1")
    settings = Rubot::ProviderSettings.new(
      provider: "openai",
      model: "openai/test-model",
      api_key: "sk-test",
      api_base: api_base,
      max_tokens: 4096,
      temperature: 0.7
    )
    Rubot::Providers::OpenAI.new(settings)
  end

  def extract(provider, response)
    provider.send(:extract_content, response)
  end

  # --- non-streaming ---

  def test_finish_reason_length_marks_the_answer_truncated
    result = extract(openai_provider, {
      "choices" => [
        { "message" => { "content" => "> 1. Kanalnya. Bisa satu," }, "finish_reason" => "length" }
      ]
    })

    assert_equal "> 1. Kanalnya. Bisa satu,", result["content"]
    assert_equal "length", result["finish_reason"]
    assert_equal true, result["truncated"]
  end

  def test_finished_answer_is_not_marked_truncated
    result = extract(openai_provider, {
      "choices" => [
        { "message" => { "content" => "Selesai." }, "finish_reason" => "stop" }
      ]
    })

    refute result["truncated"]
    assert_equal "stop", result["finish_reason"]
  end

  def test_tool_calls_survive_a_truncated_answer
    calls = [ { "id" => "c1", "type" => "function", "function" => { "name" => "file", "arguments" => "{" } } ]
    result = extract(openai_provider, {
      "choices" => [
        { "message" => { "content" => "", "tool_calls" => calls }, "finish_reason" => "length" }
      ]
    })

    assert_equal calls, result["tool_calls"]
    assert_equal true, result["truncated"]
  end

  def test_missing_choices_yields_an_empty_result
    result = extract(openai_provider, {})

    assert_equal "", result["content"]
    refute result["truncated"]
  end

  def test_reasoning_models_keep_finish_reason_alongside_reasoning_content
    result = extract(openai_provider, {
      "choices" => [
        {
          "message" => { "content" => "kepotong", "reasoning_content" => "berpikir panjang" },
          "finish_reason" => "length"
        }
      ]
    })

    assert_equal "berpikir panjang", result["reasoning_content"]
    assert_equal true, result["truncated"]
  end

  # --- streaming ---

  # Minimal SSE server: writes the given chunks verbatim, then closes.
  def with_sse_server(chunks)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      length = 0
      while (line = client.gets) && line != "\r\n"
        length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length:")
      end
      # Drain the request body: closing with unread bytes in the socket sends
      # an RST that kills the client's read of the response.
      client.read(length) if length.positive?
      client.write("HTTP/1.1 200 OK\r\n" \
                   "Content-Type: text/event-stream\r\n" \
                   "Connection: close\r\n\r\n")
      chunks.each do |chunk|
        client.write(chunk)
        client.flush
      end
      client.close
    end

    yield "http://127.0.0.1:#{port}/v1"
  ensure
    server&.close
    thread&.join(2)
  end

  def stream(provider)
    provider.send(:make_stream_request, { "model" => "m", "messages" => [] })
  end

  def test_stream_reports_the_finish_reason
    chunks = [
      "data: {\"choices\":[{\"delta\":{\"content\":\"Satu\"}}]}\n\n",
      "data: {\"choices\":[{\"delta\":{\"content\":\" tombol.\"},\"finish_reason\":\"stop\"}]}\n\n",
      "data: [DONE]\n\n"
    ]

    with_sse_server(chunks) do |base|
      result = stream(openai_provider(api_base: base))

      assert_equal "Satu tombol.", result["content"]
      assert_equal "stop", result["finish_reason"]
      refute result["truncated"]
      refute result["stream_incomplete"]
    end
  end

  def test_stream_cut_at_the_output_limit_is_marked_truncated
    chunks = [
      "data: {\"choices\":[{\"delta\":{\"content\":\"Bisa satu,\"}}]}\n\n",
      "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n",
      "data: [DONE]\n\n"
    ]

    with_sse_server(chunks) do |base|
      result = stream(openai_provider(api_base: base))

      assert_equal "Bisa satu,", result["content"]
      assert_equal true, result["truncated"]
    end
  end

  def test_stream_without_done_marker_is_marked_incomplete
    chunks = [ "data: {\"choices\":[{\"delta\":{\"content\":\"Bisa satu,\"}}]}\n\n" ]

    with_sse_server(chunks) do |base|
      result = stream(openai_provider(api_base: base))

      assert_equal "Bisa satu,", result["content"]
      assert_equal true, result["stream_incomplete"]
    end
  end

  def test_stream_keeps_a_trailing_frame_with_no_newline
    chunks = [
      "data: {\"choices\":[{\"delta\":{\"content\":\"Satu\"}}]}\n\n",
      # connection closes mid-frame: no trailing newline
      "data: {\"choices\":[{\"delta\":{\"content\":\" tombol.\"},\"finish_reason\":\"stop\"}]}"
    ]

    with_sse_server(chunks) do |base|
      result = stream(openai_provider(api_base: base))

      assert_equal "Satu tombol.", result["content"]
      assert_equal "stop", result["finish_reason"]
    end
  end
end

class TestAgentTruncationHandling < Minitest::Test
  # Replies from a script, one entry per provider round-trip. Calls made by the
  # agent's own helper extractors (memory, feedback) are answered here and do
  # not consume a script entry, so `calls` counts the real turn only.
  class ScriptedProvider
    AUXILIARY_PROMPTS = [ "memory extraction", "feedback" ].freeze

    attr_reader :calls, :requests

    def initialize(script)
      @script = script
      @calls = 0
      @requests = []
    end

    def chat(messages, tools: nil)
      system = messages.find { |m| m["role"] == "system" }
      system = system ? system["content"].to_s : ""
      return { "content" => "{}", "finish_reason" => "stop" } if AUXILIARY_PROMPTS.any? { |p| system.include?(p) }

      @requests << messages.map { |m| { "role" => m["role"], "content" => m["content"].to_s } }
      result = @script[[ @calls, @script.size - 1 ].min]
      @calls += 1
      result
    end

    def chat_stream(messages, tools: nil, &_on_chunk)
      chat(messages, tools: tools)
    end

    def name
      "scripted"
    end

    def last_usage
      nil
    end
  end

  def build_agent(script, max_tool_iterations: 10)
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(@tmpdir, "config.yml")

    File.write(config_path, {
      "agents" => { "defaults" => {
        "workspace" => workspace,
        "max_tool_iterations" => max_tool_iterations
      } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)

    @provider = ScriptedProvider.new(script)
    Rubot::Agent.new(
      config: Rubot::Config.new(config_path),
      provider: @provider,
      session_id: "truncation-test"
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def tool_call(name: "file", id: "call_1", arguments: JSON.generate({ "operation" => "list", "path" => "." }))
    {
      "id" => id,
      "type" => "function",
      "function" => { "name" => name, "arguments" => arguments }
    }
  end

  def test_truncated_answer_is_continued_and_joined
    agent = build_agent([
      { "content" => "Yang perlu diisi cuma tiga hal. 1. Kanalnya. Bisa satu,", "finish_reason" => "length", "truncated" => true },
      { "content" => " bisa dua. Tiap kanal dapat satu tombol.", "finish_reason" => "stop" }
    ])

    answer = agent.process("draft slide 5", stream: false)

    assert_equal 2, @provider.calls
    assert_includes answer, "Bisa satu, bisa dua."
    refute_includes answer, "cut off"
    assert_includes @provider.requests.last.map { |m| m["content"] }, Rubot::Agent::CONTINUE_PROMPT
  end

  def test_truncation_notice_is_added_when_continuations_run_out
    agent = build_agent([
      { "content" => "Kalimat yang tidak pernah selesai,", "finish_reason" => "length", "truncated" => true }
    ])

    answer = agent.process("tulis panjang", stream: false)

    assert_equal 1 + Rubot::Agent::MAX_CONTINUATIONS, @provider.calls
    assert_includes answer, "cut off at the output limit"
  end

  def test_incomplete_stream_is_treated_as_truncated
    agent = build_agent([
      { "content" => "Bisa satu,", "stream_incomplete" => true },
      { "content" => " bisa dua.", "finish_reason" => "stop" }
    ])

    answer = agent.process("draft", stream: false)

    assert_equal 2, @provider.calls
    assert_includes answer, "Bisa satu, bisa dua."
  end

  def test_truncated_tool_call_is_not_executed
    agent = build_agent([
      {
        "content" => "",
        "finish_reason" => "length",
        "truncated" => true,
        "tool_calls" => [ tool_call(arguments: "{\"operation\":\"li") ]
      },
      { "content" => "Sudah gue ulang.", "finish_reason" => "stop" }
    ])

    answer = agent.process("baca folder", stream: false)

    tool_messages = agent.session.safe_history(limit: 50).select { |m| m["role"] == "tool" }
    assert_equal 1, tool_messages.size
    assert_includes tool_messages.first["content"], "cut off before its arguments finished"
    assert_equal "Sudah gue ulang.", answer
  end

  def test_silent_turn_is_asked_again_instead_of_dumping_tool_output
    agent = build_agent([
      { "content" => "", "finish_reason" => "stop", "tool_calls" => [ tool_call ] },
      { "content" => "", "finish_reason" => "stop" }
    ])

    answer = agent.process("kirim gambarnya", stream: false)

    # third round-trip is the re-ask, which the script answers with the last entry
    assert_equal 3, @provider.calls
    assert_includes @provider.requests[2].map { |m| m["content"] }, Rubot::Agent::ANSWER_NOW_PROMPT
    refute_includes answer, "[Exit code"
  end

  def test_answered_turn_is_not_reasked
    agent = build_agent([
      { "content" => "", "finish_reason" => "stop", "tool_calls" => [ tool_call ] },
      { "content" => "Ini hasilnya.", "finish_reason" => "stop" }
    ])

    answer = agent.process("baca folder", stream: false)

    assert_equal 2, @provider.calls
    assert_equal "Ini hasilnya.", answer
  end

  def test_fallback_names_the_last_tool_instead_of_dumping_its_output
    agent = build_agent([ { "content" => "", "finish_reason" => "stop", "tool_calls" => [ tool_call ] } ])

    answer = agent.process("baca folder", stream: false)

    assert_includes answer, "without writing an answer"
    assert_includes answer, "file"
    refute_includes answer, "[Exit code"
    refute_includes answer, "I completed"
  end
end

class TestAgentEmptyAnswerRecovery < Minitest::Test
  # A reasoning model can spend the whole output budget before writing any
  # visible text; the reply is then empty with finish_reason "length".
  class EmptyThenAnswerProvider
    attr_reader :calls, :requests

    def initialize
      @calls = 0
      @requests = []
    end

    def chat(messages, tools: nil)
      system = messages.find { |m| m["role"] == "system" }
      return { "content" => "{}", "finish_reason" => "stop" } if system && system["content"].to_s.include?("memory extraction")

      @requests << messages.map { |m| m["content"].to_s }
      @calls += 1
      if @calls == 1
        { "content" => "", "finish_reason" => "length", "truncated" => true }
      else
        { "content" => "Ini jawabannya.", "finish_reason" => "stop" }
      end
    end

    def chat_stream(messages, tools: nil, &_on_chunk)
      chat(messages, tools: tools)
    end

    def name
      "empty-then-answer"
    end

    def last_usage
      nil
    end
  end

  class AlwaysEmptyProvider < EmptyThenAnswerProvider
    def chat(messages, tools: nil)
      system = messages.find { |m| m["role"] == "system" }
      return { "content" => "{}", "finish_reason" => "stop" } if system && system["content"].to_s.include?("memory extraction")

      @requests << messages.map { |m| m["content"].to_s }
      @calls += 1
      { "content" => "", "finish_reason" => "length", "truncated" => true }
    end
  end

  def build_agent(provider)
    @tmpdir = Dir.mktmpdir
    workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(@tmpdir, "config.yml")

    File.write(config_path, {
      "agents" => { "defaults" => { "workspace" => workspace, "max_tool_iterations" => 10 } },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)

    Rubot::Agent.new(
      config: Rubot::Config.new(config_path),
      provider: provider,
      session_id: "empty-answer-test"
    )
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def test_empty_truncated_reply_is_asked_again
    provider = EmptyThenAnswerProvider.new
    agent = build_agent(provider)

    answer = agent.process("apa itu kartu live?", stream: false)

    assert_equal 2, provider.calls
    assert_equal "Ini jawabannya.", answer
    assert_includes provider.requests.last, Rubot::Agent::EMPTY_ANSWER_PROMPT
  end

  def test_two_empty_replies_produce_a_notice_not_silence
    provider = AlwaysEmptyProvider.new
    agent = build_agent(provider)

    answer = agent.process("apa itu kartu live?", stream: false)

    refute_empty answer
    assert_includes answer, "returned an empty reply"
  end
end
