# frozen_string_literal: true

require_relative "test_helper"
require "json"

class TestMemoryExtractor < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @memory = Rubot::Memory.new(workspace: @workspace)
    @provider = FakeProvider.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_skips_short_messages
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)
    result = extractor.extract("hi")
    assert_empty result
    # Provider should not have been called
    refute @provider.called
  end

  def test_skips_trivial_messages
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)
    %w[yes no okay thanks cool great awesome got it right wrong nope maybe i see hmm wow
       iya sip oke siap mantap keren makasih tidak nggak nggak bisa ngerti paham waduh wah oh].each do |msg|
      result = extractor.extract(msg)
      assert_empty result
      refute @provider.called, "Provider should not be called for '#{msg}'"
    end
  end

  def test_extracts_facts_when_provider_returns_json
    @provider.response = '{"facts": ["User works in Jakarta"], "preferences": [], "context": []}'
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    result = extractor.extract("I work in Jakarta as a software engineer.")
    assert_equal 1, result.size
    assert_equal "Facts", result.first[:section]
    assert_equal "User works in Jakarta", result.first[:fact]
  end

  def test_extracts_multiple_sections
    @provider.response = '{"facts": ["Uses Ruby"], "preferences": ["Prefers dark mode"], "context": ["Working on a chatbot"]}'
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    result = extractor.extract("I use Ruby and prefer dark mode. I'm building a chatbot.")
    assert_equal 3, result.size

    sections = result.map { |r| r[:section] }
    assert_includes sections, "Facts"
    assert_includes sections, "Preferences"
    assert_includes sections, "Context"
  end

  def test_returns_empty_when_nothing_to_extract
    @provider.response = '{"facts": [], "preferences": [], "context": []}'
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    result = extractor.extract("This message has nothing worth remembering.")
    assert_empty result
  end

  def test_deduplicates_existing_facts
    @memory.append("Facts", "User works in Jakarta")
    @provider.response = '{"facts": ["User works in Jakarta"], "preferences": [], "context": []}'
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    result = extractor.extract("Just to reiterate, I work in Jakarta.")
    assert_empty result
  end

  # The section alone no longer decides where a fact goes: a persona's
  # preferences stay in the persona's memory, while a fact about the user
  # follows them everywhere.
  def test_each_item_is_stored_in_the_layer_its_scope_names
    bank = persona_bank
    @provider.response = JSON.generate(
      "facts" => [ { "fact" => "User is 183 cm tall", "scope" => "global" } ],
      "preferences" => [ { "fact" => "Client prefers carousels over reels", "scope" => "persona" } ],
      "context" => [ { "fact" => "Working on a wedding invitation brand", "scope" => "persona" } ]
    )
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: bank)

    result = extractor.extract("Saya 183 cm. Klien saya lebih suka carousel untuk brand undangan.")

    assert_equal 3, result.size
    assert_includes File.read(bank.global_path), "183 cm tall"
    refute_includes File.read(bank.global_path), "carousels"
    assert_includes File.read(bank.workspace_path), "carousels"
    refute_includes File.read(bank.workspace_path), "183 cm tall"
  end

  def test_an_item_without_a_scope_stays_local
    bank = persona_bank
    @provider.response = '{"facts": ["Suka kopi tanpa gula"], "preferences": [], "context": []}'
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: bank)

    extractor.extract("Saya suka kopi tanpa gula setiap pagi.")

    assert_includes File.read(bank.workspace_path), "kopi"
    refute_includes File.read(bank.global_path), "kopi"
  end

  def persona_bank
    Rubot::MemoryBank.new(
      global_path: File.join(@tmpdir, "MEMORY.md"),
      workspace_path: File.join(@tmpdir, "personas", "trainer", "MEMORY.md"),
      workspace_label: "persona"
    )
  end

  def test_handles_non_json_response
    @provider.response = "I don't think there's anything to extract here."
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    result = extractor.extract("Some message with details.")
    assert_empty result
  end

  def test_handles_malformed_json
    @provider.response = '{"facts": ["broken json'
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    result = extractor.extract("Some message with details.")
    assert_empty result
  end

  def test_extracts_json_from_wrapped_response
    @provider.response = <<~RESPONSE
      Here are the extracted facts:

      ```json
      {"facts": ["User likes Python"], "preferences": [], "context": []}
      ```

      Hope that helps!
    RESPONSE
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    result = extractor.extract("I really love programming in Python.")
    assert_equal 1, result.size
    assert_equal "User likes Python", result.first[:fact]
  end

  def test_skips_nil_message
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)
    result = extractor.extract(nil)
    assert_empty result
  end

  def test_skips_whitespace_only
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)
    result = extractor.extract("   \n  \t  ")
    assert_empty result
  end

  def test_skips_just_numbers
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)
    result = extractor.extract("42")
    assert_empty result
  end

  def test_extracts_from_indonesian_message
    @provider.response = '{"facts": ["User lives in Jakarta"], "preferences": [], "context": []}'
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    result = extractor.extract("Saya tinggal di Jakarta dan bekerja sebagai engineer.")
    assert_equal 1, result.size
    assert_equal "Facts", result.first[:section]
    assert_equal "User lives in Jakarta", result.first[:fact]
  end

  def test_extracts_indonesian_preferences
    @provider.response = '{"facts": [], "preferences": ["User prefers Bahasa Indonesia"], "context": []}'
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    result = extractor.extract("Saya lebih suka pakai bahasa Indonesia.")
    assert_equal 1, result.size
    assert_equal "Preferences", result.first[:section]
  end

  # Mock provider for testing
  class FakeProvider
    attr_accessor :response, :called, :last_messages

    def initialize
      @called = false
      @response = '{"facts": [], "preferences": [], "context": []}'
    end

    def chat(messages, tools: nil)
      @called = true
      @last_messages = messages
      @response
    end
  end
end

class TestMemoryExtractorBatching < Minitest::Test
  class BatchProvider
    attr_accessor :response
    attr_reader :calls, :requests

    def initialize
      @calls = 0
      @requests = []
      @response = '{"facts": [], "preferences": [], "context": []}'
    end

    def chat(messages, tools: nil)
      @calls += 1
      @requests << messages
      @response
    end

    def last_usage
      { "prompt_tokens" => 100, "completion_tokens" => 20 }
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @workspace = File.join(@tmpdir, "workspace")
    FileUtils.mkdir_p(@workspace)
    @memory = Rubot::Memory.new(workspace: @workspace)
    @provider = BatchProvider.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_extracts_from_a_batch_in_one_request
    @provider.response = '{"facts": ["User uses Ruby"], "preferences": [], "context": []}'
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    result = extractor.extract([
      "I have been writing Ruby for years.",
      "Try again with the slides please."
    ])

    assert_equal 1, @provider.calls
    assert_equal 1, result.size
  end

  def test_skips_trivial_messages_inside_a_batch
    @provider.response = '{"facts": ["User uses Ruby"], "preferences": [], "context": []}'
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    extractor.extract([ "ok", "sip", "I have been writing Ruby for years.", "My team ships on Fridays." ])

    prompt = @provider.requests.last.last["content"]
    refute_includes prompt, "ok"
    assert_includes prompt, "1. I have been writing Ruby for years."
    assert_includes prompt, "2. My team ships on Fridays."
  end

  def test_returns_empty_without_calling_the_provider_when_the_whole_batch_is_trivial
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    assert_empty extractor.extract([ "ok", "thanks" ])
    assert_equal 0, @provider.calls
  end

  def test_records_the_usage_of_the_extraction_request
    @provider.response = '{"facts": [], "preferences": [], "context": []}'
    extractor = Rubot::MemoryExtractor.new(provider: @provider, memory: @memory)

    extractor.extract("I have been writing Ruby for years.")

    refute_nil extractor.last_usage
  end
end
