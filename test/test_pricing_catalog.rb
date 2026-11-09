# frozen_string_literal: true

require_relative "test_helper"

class TestPricingCatalog < Minitest::Test
  PAYLOAD = {
    "openai" => {
      "models" => {
        "gpt-4o-mini" => {
          "cost" => { "input" => 0.15, "output" => 0.60, "cache_read" => 0.075 },
          "limit" => { "context" => 128_000 }
        },
        "gpt-image-1" => {
          "cost" => nil,
          "limit" => { "context" => 0 }
        },
        "gpt-5.6-terra" => {
          "cost" => {
            "input" => 2, "output" => 12, "cache_read" => 0.2, "cache_write" => 2.5,
            "tiers" => [
              {
                "input" => 4, "output" => 18, "cache_read" => 0.4, "cache_write" => 5,
                "tier" => { "type" => "context", "size" => 272_000 }
              }
            ]
          },
          "limit" => { "context" => 1_050_000 }
        }
      }
    },
    "google" => {
      "models" => {
        "gemini-2.0-flash" => {
          "cost" => { "input" => 0.10, "output" => 0.40 },
          "limit" => { "context" => 1_000_000 }
        }
      }
    }
  }.freeze

  def setup
    @dir = Dir.mktmpdir
    @workspace = File.join(@dir, "workspace")
    FileUtils.mkdir_p(@workspace)
    path = File.join(@dir, "config.yml")
    File.write(path, {
      "agents" => { "defaults" => { "workspace" => @workspace } },
      "models" => [],
      "provider" => "openai"
    }.to_yaml)
    @config = Rubot::Config.new(path)
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def test_rates_for_direct_provider
    catalog = StubCatalog.new(config: @config, payload: PAYLOAD)
    rates = catalog.rates("gpt-4o-mini", provider: "openai")

    assert_in_delta 0.15, rates["input"]
    assert_in_delta 0.60, rates["output"]
    assert_in_delta 0.075, rates["cached_input"]
    assert_in_delta 0.1875, rates["cache_creation_input"]
    assert_equal "models.dev", catalog.source
  end

  def test_context_window
    catalog = StubCatalog.new(config: @config, payload: PAYLOAD)

    assert_equal 128_000, catalog.context_window("gpt-4o-mini", provider: "openai")
    assert_nil catalog.context_window("unknown-model", provider: "openai")
  end

  def test_provider_alias
    catalog = StubCatalog.new(config: @config, payload: PAYLOAD)

    assert_equal 1_000_000, catalog.context_window("gemini-2.0-flash", provider: "gemini")
    assert_in_delta 0.10, catalog.rates("gemini-2.0-flash", provider: "gemini")["input"]
  end

  def test_model_id_with_provider_prefix
    catalog = StubCatalog.new(config: @config, payload: PAYLOAD)

    assert_in_delta 0.15, catalog.rates("openai/gpt-4o-mini", provider: "openai")["input"]
  end

  def test_writes_cache_file
    StubCatalog.new(config: @config, payload: PAYLOAD).rates("gpt-4o-mini", provider: "openai")

    path = Rubot::PricingCatalog.cache_path(@config.catalog_dir)
    assert File.exist?(path)

    data = JSON.parse(File.read(path))
    assert data["updated_at"]
    assert data["models"]["openai/gpt-4o-mini"]
  end

  def test_uses_fresh_cache_without_fetching
    StubCatalog.new(config: @config, payload: PAYLOAD).rates("gpt-4o-mini", provider: "openai")

    catalog = FailingCatalog.new(config: @config)
    rates = catalog.rates("gpt-4o-mini", provider: "openai")

    assert_in_delta 0.15, rates["input"]
    assert_equal "models.dev cache", catalog.source
  end

  def test_falls_back_to_stale_cache
    path = Rubot::PricingCatalog.cache_path(@config.catalog_dir)
    File.write(path, JSON.generate(
      "updated_at" => (Time.now - 2 * 86_400).utc.iso8601,
      "models" => {
        "openai/gpt-4o-mini" => {
          "id" => "gpt-4o-mini",
          "provider" => "openai",
          "input" => 0.15,
          "output" => 0.60,
          "cached_input" => 0.075,
          "context_window" => 128_000,
          "priced" => true
        }
      }
    ))

    catalog = FailingCatalog.new(config: @config)
    rates = catalog.rates("gpt-4o-mini", provider: "openai")

    assert_in_delta 0.15, rates["input"]
    assert_equal "models.dev cache (stale)", catalog.source
  end

  def test_parses_long_context_tiers
    catalog = StubCatalog.new(config: @config, payload: PAYLOAD)
    rates = catalog.rates("gpt-5.6-terra", provider: "openai")

    assert_equal 1, rates["tiers"].size
    tier = rates["tiers"].first
    assert_equal 272_000, tier["input_tokens_above"]
    assert_in_delta 4.0, tier["input"]
    assert_in_delta 0.4, tier["cached_input"]
    assert_in_delta 5.0, tier["cache_creation_input"]
  end

  def test_cost_applies_a_parsed_tier
    catalog = StubCatalog.new(config: @config, payload: PAYLOAD)
    rates = catalog.rates("gpt-5.6-terra", provider: "openai")
    usage = Rubot::Usage.new(prompt_tokens: 300_000, completion_tokens: 0)

    cost = Rubot::Usage.cost(usage, rates)

    assert_in_delta 1.2, cost["input"]
  end

  def test_network_false_does_not_fetch
    catalog = FailingCatalog.new(config: @config)

    assert_nil catalog.rates("gpt-4o-mini", provider: "openai", network: false)
  end

  def test_network_false_uses_the_stale_cache
    path = Rubot::PricingCatalog.cache_path(@config.catalog_dir)
    File.write(path, JSON.generate(
      "updated_at" => (Time.now - 2 * 86_400).utc.iso8601,
      "models" => {
        "openai/gpt-4o-mini" => {
          "id" => "gpt-4o-mini", "provider" => "openai", "input" => 0.15,
          "output" => 0.60, "cached_input" => 0.075, "context_window" => 128_000,
          "priced" => true
        }
      }
    ))

    catalog = FailingCatalog.new(config: @config)
    rates = catalog.rates("gpt-4o-mini", provider: "openai", network: false)

    assert_in_delta 0.15, rates["input"]
    assert_equal "models.dev cache (stale)", catalog.source
  end

  def test_unknown_model_returns_nil
    catalog = StubCatalog.new(config: @config, payload: PAYLOAD)

    assert_nil catalog.rates("unknown-model", provider: "openai")
    assert_nil catalog.context_window("unknown-model", provider: "openai")
  end

  class StubCatalog < Rubot::PricingCatalog
    def initialize(config:, payload:, ttl: Rubot::PricingCatalog::DEFAULT_TTL)
      super(config: config, ttl: ttl)
      @payload = payload
    end

    private

    def fetch_models
      @payload
    end
  end

  class FailingCatalog < Rubot::PricingCatalog
    private

    def fetch_models
      raise "network unavailable"
    end
  end
end
