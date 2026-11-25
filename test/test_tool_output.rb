# frozen_string_literal: true

require_relative "test_helper"

# A tool result is written into the transcript once and re-sent on every request
# that follows it, so an output that never stops growing is a cost paid again and
# again. `Rubot::ToolOutput.clip` puts a ceiling on what one result may weigh, on
# the way in, and only there: the text the transcript holds is then the same text
# every later round sends, which is what keeps the provider's cached prefix
# byte-identical.
class TestToolOutput < Minitest::Test
  # Answers from a script and records every request, so two rounds of one turn
  # can be compared message by message.
  class ScriptedProvider
    attr_reader :requests

    def initialize(script)
      @script = script.dup
      @requests = []
    end

    def name = "openai"

    def last_usage
      { "prompt_tokens" => 20, "completion_tokens" => 5 }
    end

    def chat(messages, tools: nil, on_retry: nil)
      @requests << messages
      raise "the provider was asked for more than the script holds" if @script.empty?

      @script.shift
    end
    alias chat_stream chat
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def build_agent(script, defaults: {})
    path = File.join(@tmpdir, "config.yml")
    File.write(path, {
      "agents" => { "defaults" => { "workspace" => @workspace, "max_rounds" => 6 }.merge(defaults) },
      "models" => [ { "name" => "test", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" } ]
    }.to_yaml)
    provider = ScriptedProvider.new(script)
    [ Rubot::Agent.new(config: Rubot::Config.new(path), provider: provider, session_id: "clip"), provider ]
  end

  def read_call(path, id)
    {
      "id" => id,
      "type" => "function",
      "function" => {
        "name" => "file_ops",
        "arguments" => JSON.generate({ "operation" => "read", "path" => path })
      }
    }
  end

  # A result that already fits is left exactly as it was: the clip is not a
  # normalizer and must not touch the text every result passes through.
  def test_a_result_under_the_limit_is_returned_unchanged
    text = "short enough\n" * 10

    clipped = Rubot::ToolOutput.clip(text)

    assert_same text, clipped, "the same text, not a copy of it"
    assert_equal text.length, clipped.length
  end

  def test_a_long_result_keeps_its_head_and_tail_and_names_what_it_left_out
    text = "HEAD-MARKER#{"a" * 20_000}TAIL-MARKER"

    clipped = Rubot::ToolOutput.clip(text)

    assert_operator clipped.length, :<, Rubot::ToolOutput::MAX_CHARS,
                    "the whole thing, note included, fits under the ceiling"
    assert clipped.start_with?("HEAD-MARKER"), "the beginning is what a reader looks at first"
    assert clipped.end_with?("TAIL-MARKER"), "the ending is where a failure says what went wrong"
    assert_match(/left out to keep the transcript small/, clipped)

    note = clipped[/\[\.\.\..*?\]/]
    removed = note[/(\d+) characters/, 1].to_i
    kept = clipped.length - note.length - 2
    assert_equal text.length - kept, removed, "the note counts exactly what is missing"
  end

  # The ceiling is a setting, not a constant: a persona whose workspace holds
  # large files wants a wider head than one that only runs commands. The default
  # is 6000 characters, and a caller may name its own.
  def test_the_clip_ceiling_is_a_setting_with_a_sensible_default
    path = File.join(@tmpdir, "bare.yml")
    File.write(path, {}.to_yaml)

    assert_equal 6_000, Rubot::Config::DEFAULT_TOOL_OUTPUT_MAX_CHARS
    assert_equal 6_000, Rubot::Config.new(path).tool_output_max_chars

    text = "a" * 3_000
    assert_operator Rubot::ToolOutput.clip(text, max_chars: 500).length, :<, 500,
                    "the named ceiling is the one the clip obeys"
  end

  def test_the_transcript_uses_the_configured_ceiling
    big = File.join(@workspace, "big.txt")
    File.write(big, "#{"0123456789" * 4_000}\n")
    agent, = build_agent(
      [ { "content" => "reading", "tool_calls" => [ read_call(big, "call_1") ] },
        { "content" => "done", "finish_reason" => "stop" } ],
      defaults: { "tool_output_max_chars" => 400 }
    )

    agent.process("look at the file", stream: false)

    tool_message = agent.session.messages.find { |message| message["role"] == "tool" }
    assert_operator tool_message["content"].length, :<, 400, "the configured ceiling, not the default"
    assert_includes tool_message["content"], "left out to keep the transcript small"
  end

  # The reason the clip happens on the way in rather than on the way out: the
  # transcript is written once, so the second round's request carries the first
  # round's text byte for byte and the cached prefix survives. Clipping at
  # request time would rewrite the conversation under the cache on every round.
  def test_the_prefix_of_a_transcript_does_not_change_between_rounds
    big = File.join(@workspace, "big.txt")
    File.write(big, "#{"0123456789" * 4_000}\n")
    call = ->(id) { read_call(big, id) }
    agent, provider = build_agent([
      { "content" => "reading", "tool_calls" => [ call.call("call_1") ] },
      { "content" => "reading again", "tool_calls" => [ call.call("call_2") ] },
      { "content" => "done", "finish_reason" => "stop" }
    ])
    tool_results = []

    agent.process("look at the file", stream: false,
                  on_tool_result: ->(_name, result, _diff) { tool_results << result.to_s })

    tool_messages = agent.session.messages.select { |message| message["role"] == "tool" }
    assert_equal 2, tool_messages.size
    tool_messages.each do |message|
      assert_operator message["content"].length, :<, Rubot::ToolOutput::MAX_CHARS,
                      "the transcript holds the clipped copy"
      assert_includes message["content"], "left out to keep the transcript small"
    end
    assert_operator tool_results.first.length, :>, Rubot::ToolOutput::MAX_CHARS,
                    "the reader is still shown the whole output"

    # Request 2 is the one after the first tool result, request 3 the one after
    # the second: everything request 2 carried must still be there, unchanged,
    # in request 3.
    before, after = provider.requests[1], provider.requests[2]
    assert_equal before, after.first(before.size),
                 "an old message must not move once it is in the transcript"
    assert_equal Digest::SHA256.hexdigest(JSON.generate(before)),
                 Digest::SHA256.hexdigest(JSON.generate(after.first(before.size))),
                 "the prefix digest is what the provider's cache is keyed on"
  end
end
