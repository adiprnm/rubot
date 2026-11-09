# frozen_string_literal: true

require_relative "test_helper"

# A conversation is named by one small request after its first turn. These
# tests cover the two things that decide whether the name is usable: what the
# model is asked, and what survives of its answer.
class TestSessionNamer < Minitest::Test
  # Answers with whatever the test scripted, and remembers what it was asked.
  class ScriptedProvider
    attr_reader :requests, :last_usage

    def initialize(reply)
      @reply = reply
      @requests = []
      @last_usage = nil
    end

    def name
      "openai"
    end

    def chat(messages, tools: nil)
      @requests << messages
      @last_usage = { "prompt_tokens" => 20, "completion_tokens" => 4 }
      { "content" => @reply.call, "finish_reason" => "stop" }
    end
  end

  # A provider that fails the way a flaky endpoint does: the sidebar must fall
  # back to the first prompt instead of losing the session.
  class FailingProvider
    attr_reader :last_usage

    def name
      "openai"
    end

    def chat(_messages, tools: nil)
      raise Rubot::RateLimitError, "slow down"
    end
  end

  def namer(reply)
    @provider = ScriptedProvider.new(reply)
    Rubot::SessionNamer.new(provider: @provider)
  end

  def test_the_title_is_the_models_answer
    title = namer(-> { "Perbaikan layout web" }).name("tolong rapikan layout sidebar-nya met")

    assert_equal "Perbaikan layout web", title
  end

  def test_the_prompt_carries_the_question_and_the_answer
    namer(-> { "Sesi layout" }).name("rapikan sidebar", reply: "Sudah saya rapikan.")

    content = @provider.requests.first.last["content"]

    assert_includes content, "rapikan sidebar"
    assert_includes content, "Sudah saya rapikan."
  end

  def test_the_answer_is_optional
    namer(-> { "Sesi layout" }).name("rapikan sidebar")

    content = @provider.requests.first.last["content"]

    refute_includes content, "Assistant's first answer"
  end

  def test_wrappers_are_stripped_from_the_answer
    [
      [ "Title: Perbaikan layout", "Perbaikan layout" ],
      [ "\"Perbaikan layout\"", "Perbaikan layout" ],
      [ "**Perbaikan layout**", "Perbaikan layout" ],
      [ "Perbaikan layout.", "Perbaikan layout" ],
      [ "Perbaikan layout\nThis names the conversation.", "Perbaikan layout" ]
    ].each do |raw, expected|
      assert_equal expected, namer(-> { raw }).name("rapikan sidebar"), "for #{raw.inspect}"
    end
  end

  def test_an_empty_answer_names_nothing
    assert_nil namer(-> { "   " }).name("rapikan sidebar")
    assert_nil namer(-> { "" }).name("rapikan sidebar")
  end

  def test_a_paragraph_is_cut_to_the_row_width
    title = namer(-> { "kata " * 40 }).name("rapikan sidebar")

    assert_operator title.length, :<=, Rubot::SessionNamer::MAX_TITLE_CHARS
  end

  def test_an_empty_prompt_is_not_sent_to_the_provider
    provider = ScriptedProvider.new(-> { "Sesi" })
    namer = Rubot::SessionNamer.new(provider: provider)

    assert_nil namer.name("   ")
    assert_empty provider.requests
  end

  def test_a_failing_provider_returns_nothing_instead_of_raising
    namer = Rubot::SessionNamer.new(provider: FailingProvider.new)

    assert_nil namer.name("rapikan sidebar")
  end

  def test_the_request_usage_is_readable_for_auxiliary_accounting
    namer(-> { "Perbaikan layout" }).name("rapikan sidebar")

    refute_nil @provider.last_usage
  end
end
