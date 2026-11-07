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

  def test_normalizes_deepseek_prompt_cache_hit_tokens
    usage = Rubot::Usage.from({
      "prompt_tokens" => 1_000,
      "completion_tokens" => 100,
      "prompt_cache_hit_tokens" => 600
    })

    assert_equal 600, usage.cached_tokens
    assert_in_delta 0.6, usage.cache_hit_rate
  end

  def test_normalizes_openai_cache_write_tokens
    usage = Rubot::Usage.from({
      "prompt_tokens" => 1_000,
      "completion_tokens" => 100,
      "prompt_tokens_details" => { "cached_tokens" => 600, "cache_write_tokens" => 200 }
    })

    assert_equal 600, usage.cached_tokens
    assert_equal 200, usage.cache_creation_tokens
  end

  def test_normalizes_anthropic_one_hour_cache_writes
    usage = Rubot::Usage.from({
      "input_tokens" => 100,
      "output_tokens" => 50,
      "cache_read_input_tokens" => 700,
      "cache_creation_input_tokens" => 200,
      "cache_creation" => { "ephemeral_5m_input_tokens" => 150, "ephemeral_1h_input_tokens" => 50 }
    })

    assert_equal 200, usage.cache_creation_tokens
    assert_equal 50, usage.cache_write_1h_tokens
  end

  def test_cost_charges_one_hour_cache_writes_at_double_the_input_rate
    usage = Rubot::Usage.new(
      prompt_tokens: 1_000_000, completion_tokens: 0,
      cache_creation_tokens: 1_000_000, cache_write_1h_tokens: 1_000_000
    )
    rates = { "input" => 3.0, "output" => 15.0, "cache_creation_input" => 3.75 }

    cost = Rubot::Usage.cost(usage, rates)

    assert_in_delta 6.0, cost["cache_creation"]
    assert_in_delta 6.0, cost["total"]
  end

  def test_cost_uses_a_long_context_tier_above_the_threshold
    usage = Rubot::Usage.new(prompt_tokens: 300_000, completion_tokens: 0)
    rates = {
      "input" => 2.0, "output" => 4.0, "cached_input" => 0.2,
      "tiers" => [ { "input_tokens_above" => 200_000, "input" => 4.0, "output" => 8.0 } ]
    }

    cost = Rubot::Usage.cost(usage, rates)

    assert_in_delta 1.2, cost["input"]
  end

  def test_cost_ignores_a_tier_the_request_does_not_reach
    usage = Rubot::Usage.new(prompt_tokens: 10_000, completion_tokens: 0)
    rates = {
      "input" => 2.0, "output" => 4.0,
      "tiers" => [ { "input_tokens_above" => 200_000, "input" => 4.0, "output" => 8.0 } ]
    }

    cost = Rubot::Usage.cost(usage, rates)

    assert_in_delta 0.02, cost["input"]
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

  def test_usage_report_cache_hit_rate_describes_the_latest_request
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
      agent = Rubot::Agent.new(config: config, provider: SequencedUsageProvider.new, session_id: "latest-cache")
      agent.instance_variable_set(:@pricing_catalog, NoPricingCatalog.new)

      agent.process("one", stream: false)
      agent.process("two", stream: false)
      report = agent.usage_report

      # Cumulative would be 50%, but the latest request only hit 10%.
      assert_in_delta 0.1, report[:cache_hit_rate]
      assert_equal 1_000, report[:last_prompt_tokens]
      assert_equal 2_000, report[:prompt_tokens]
    end
  end

  def test_usage_report_footer
    report = {
      requests: 2, prompt_tokens: 1_000, cache_hit_rate: 0.6,
      context_used: 10_500, context_window: 128_000, context_percent: 8.2,
      cost: { "total" => 0.001234 }
    }

    assert_equal "$0.001 · cache 60% · ctx 8.2%",
                 Rubot::UsageReport.footer(report)
  end

  def test_usage_report_footer_rounds_price_to_three_decimals
    report = { requests: 1, prompt_tokens: 1_000, cache_hit_rate: 0.0,
               context_used: 0, context_window: nil, context_percent: nil,
               cost: { "total" => 1.23456 } }

    assert_equal "$1.235", Rubot::UsageReport.price(report)
  end

  def test_usage_report_footer_is_populated_before_the_first_request
    report = {
      requests: 0, prompt_tokens: 0, cache_hit_rate: 0.0,
      context_used: 3_100, context_window: 128_000, context_percent: 2.4,
      cost: { "total" => 0.0 }
    }

    assert_equal "$0.000 · cache — · ctx 2.4%", Rubot::UsageReport.footer(report)
  end

  def test_usage_report_footer_says_what_is_missing
    report = {
      requests: 1, prompt_tokens: 0, cache_hit_rate: 0.0,
      context_used: 900, context_window: nil, context_percent: nil, cost: nil
    }

    assert_equal "cost n/a · cache n/a · ctx 900", Rubot::UsageReport.footer(report)
  end

  def test_compact_tokens
    assert_equal "900", Rubot::UsageReport.compact_tokens(900)
    assert_equal "1.5k", Rubot::UsageReport.compact_tokens(1_500)
    assert_equal "128k", Rubot::UsageReport.compact_tokens(128_000)
    assert_equal "2M", Rubot::UsageReport.compact_tokens(2_000_000)
    assert_equal "1.2M", Rubot::UsageReport.compact_tokens(1_234_567)
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

  class SequencedUsageProvider < Rubot::Provider
    def initialize
      super(nil)
      @calls = 0
    end

    def name
      "openai"
    end

    def chat(_messages, tools: nil)
      @calls += 1
      track_usage(
        "prompt_tokens" => 1_000,
        "completion_tokens" => 10,
        "prompt_tokens_details" => { "cached_tokens" => @calls == 1 ? 900 : 100 }
      )
      { "content" => "hi" }
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
