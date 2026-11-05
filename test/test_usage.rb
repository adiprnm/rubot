# frozen_string_literal: true

require_relative "test_helper"

class TestUsage < Minitest::Test
  def test_normalizes_openai_usage
    usage = Rubot::Usage.from({
      "prompt_tokens" => 1000,
      "completion_tokens" => 200,
      "prompt_tokens_details" => { "cached_tokens" => 400 }
    })

    assert_equal 1000, usage.prompt_tokens
    assert_equal 200, usage.completion_tokens
    assert_equal 400, usage.cached_tokens
    assert_equal 1, usage.requests
    assert_in_delta 0.4, usage.cache_hit_rate
  end

  def test_normalizes_anthropic_usage_including_cache
    usage = Rubot::Usage.from({
      "input_tokens" => 100,
      "output_tokens" => 50,
      "cache_read_input_tokens" => 700,
      "cache_creation_input_tokens" => 200
    })

    assert_equal 1000, usage.prompt_tokens
    assert_equal 50, usage.completion_tokens
    assert_equal 700, usage.cached_tokens
    assert_equal 200, usage.cache_creation_tokens
    assert_in_delta 0.7, usage.cache_hit_rate
  end

  def test_normalizes_ollama_usage
    usage = Rubot::Usage.from({ "prompt_eval_count" => 123, "eval_count" => 45 })

    assert_equal 123, usage.prompt_tokens
    assert_equal 45, usage.completion_tokens
    assert_equal 0, usage.cached_tokens
  end

  def test_unknown_usage_returns_nil
    assert_nil Rubot::Usage.from(nil)
    assert_nil Rubot::Usage.from({})
    assert_nil Rubot::Usage.from({ "unrelated" => 1 })
  end

  def test_merge_accumulates
    a = Rubot::Usage.new(prompt_tokens: 100, completion_tokens: 10, cached_tokens: 20, requests: 1)
    b = Rubot::Usage.new(prompt_tokens: 50, completion_tokens: 5, cached_tokens: 5, requests: 1)

    merged = a.merge(b)

    assert_equal 150, merged.prompt_tokens
    assert_equal 15, merged.completion_tokens
    assert_equal 25, merged.cached_tokens
    assert_equal 2, merged.requests
  end

  def test_cost_uses_cached_rate
    usage = Rubot::Usage.new(prompt_tokens: 1_000_000, completion_tokens: 1_000_000, cached_tokens: 400_000)
    rates = { "input" => 1.0, "output" => 2.0, "cached_input" => 0.5 }

    cost = Rubot::Usage.cost(usage, rates)

    assert_in_delta 0.6, cost["input"]
    assert_in_delta 0.2, cost["cached_input"]
    assert_in_delta 2.0, cost["output"]
    assert_in_delta 2.8, cost["total"]
  end

  def test_cost_is_nil_without_rates
    assert_nil Rubot::Usage.cost(Rubot::Usage.zero, nil)
  end

  def test_session_persists_usage
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)

      session = Rubot::Session.new("usage", workspace: workspace)
      session.record_usage({ "prompt_tokens" => 300, "completion_tokens" => 30, "prompt_tokens_details" => { "cached_tokens" => 100 } })
      session.record_usage({ "prompt_tokens" => 200, "completion_tokens" => 20 })

      reloaded = Rubot::Session.new("usage", workspace: workspace)
      assert_equal 2, reloaded.usage.requests
      assert_equal 500, reloaded.usage.prompt_tokens
      assert_equal 50, reloaded.usage.completion_tokens
      assert_equal 100, reloaded.usage.cached_tokens
      assert_equal 200, reloaded.last_usage.prompt_tokens
      assert_equal 20, reloaded.last_usage.completion_tokens
    end
  end

  def test_clear_resets_usage
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)

      session = Rubot::Session.new("usage", workspace: workspace)
      session.record_usage({ "prompt_tokens" => 300, "completion_tokens" => 30 })
      session.clear!

      assert_equal 0, session.usage.requests
      assert_equal 0, session.usage.prompt_tokens
      assert_equal 0, session.last_usage.prompt_tokens
    end
  end

  def test_agent_usage_report
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      path = File.join(dir, "config.yml")
      File.write(path, {
        "agents" => { "defaults" => { "workspace" => workspace, "name" => "gpt-4o-mini" } },
        "models" => [
          { "name" => "gpt-4o-mini", "model" => "openai/gpt-4o-mini", "api_key" => "sk-test" }
        ],
        "provider" => "openai"
      }.to_yaml)

      config = Rubot::Config.new(path)
      provider = FakeUsageProvider.new(config.provider_settings)
      agent = Rubot::Agent.new(config: config, provider: provider, session_id: "usage")
      # Do not hit the pricing API from tests; fall back to bundled ModelInfo.
      agent.instance_variable_set(:@pricing_catalog, NoPricingCatalog.new)

      agent.process("hello", stream: false)
      report = agent.usage_report

      assert_equal "gpt-4o-mini", report[:model]
      assert_equal 128_000, report[:context_window]
      assert_equal 10_500, report[:context_used]
      assert_in_delta 8.2, report[:context_percent], 0.01
      assert_equal 10_000, report[:prompt_tokens]
      assert_equal 6_000, report[:cached_tokens]
      assert_in_delta 0.6, report[:cache_hit_rate]
      assert report[:cost]
      assert_in_delta 0.00135, report[:cost]["total"], 0.0000001
    end
  end

  def test_model_info_is_ractor_safe
    assert Ractor.shareable?(Rubot::ModelInfo::PRICES)
    assert Ractor.shareable?(Rubot::ModelInfo::CONTEXT_WINDOWS)

    rates = Ractor.new do
      Rubot::ModelInfo.rates("gpt-4o-mini", provider: "openai")
    end.value

    assert_in_delta 0.15, rates["input"]
  end

  class NoPricingCatalog
    def rates(*, **)
      nil
    end

    def context_window(*, **)
      nil
    end

    def source
      nil
    end
  end

  class FakeUsageProvider < Rubot::Provider
    def name
      "openai"
    end

    def chat(_messages, tools: nil)
      track_usage(
        "prompt_tokens" => 10_000,
        "completion_tokens" => 500,
        "prompt_tokens_details" => { "cached_tokens" => 6_000 }
      )
      { "content" => "hi" }
    end
  end
end
