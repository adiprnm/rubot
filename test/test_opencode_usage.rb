# frozen_string_literal: true

require_relative "test_helper"

class TestOpencodeUsage < Minitest::Test
  def test_supports_opencode_api_bases
    assert Rubot::OpencodeUsage.supported?("https://opencode.ai/zen/go/v1")
    assert Rubot::OpencodeUsage.supported?("https://opencode.ai/inference/openai/v1")
    refute Rubot::OpencodeUsage.supported?("https://api.openai.com/v1")
    refute Rubot::OpencodeUsage.supported?(nil)
  end

  def test_origin_keeps_scheme_host_and_port
    assert_equal "https://opencode.ai", Rubot::OpencodeUsage.origin("https://opencode.ai/zen/go/v1")
    assert_equal "http://localhost:8080", Rubot::OpencodeUsage.origin("http://localhost:8080/v1")
    assert_equal Rubot::OpencodeUsage::DEFAULT_ORIGIN, Rubot::OpencodeUsage.origin(nil)
  end

  def test_parses_meters
    meters = Rubot::OpencodeUsage.parse({
      "usage" => {
        "rolling" => { "status" => "ok", "percent" => 12.5, "resetsAt" => "2026-01-01T00:00:00Z" },
        "weekly" => { "status" => "rate-limited", "percent" => 100 },
        "monthly" => { "status" => "ok", "percent" => 42 }
      }
    })

    assert_equal 12.5, meters["rolling"]["percent"]
    refute meters["rolling"]["limited"]
    assert_equal 100.0, meters["weekly"]["percent"]
    assert meters["weekly"]["limited"]
    assert_equal 42.0, meters["monthly"]["percent"]
  end

  def test_parse_accepts_a_bare_usage_hash
    meters = Rubot::OpencodeUsage.parse({ "rolling" => { "percent" => 5 } })

    assert_equal 5.0, meters["rolling"]["percent"]
  end

  def test_parse_rejects_payloads_without_meters
    assert Rubot::OpencodeUsage.parse({})[:error]
    assert Rubot::OpencodeUsage.parse(nil)[:error]
  end

  def test_fetch_rejects_non_opencode_provider
    result = Rubot::OpencodeUsage.fetch(api_base: "https://api.openai.com/v1", api_key: "sk-test")

    assert_includes result[:error], "not OpenCode"
  end

  def test_render_lists_every_meter
    text = Rubot::OpencodeUsageReport.render({
      "rolling" => { "percent" => 12.5, "limited" => false, "resets_at" => nil },
      "weekly" => { "percent" => 100.0, "limited" => true, "resets_at" => nil },
      "monthly" => { "percent" => 42.0, "limited" => false, "resets_at" => Time.now + 3600 }
    })

    assert_includes text, "Rolling:"
    assert_includes text, "12.5% used"
    assert_includes text, "Weekly:"
    assert_includes text, "rate limited"
    assert_includes text, "resets in"
  end

  def test_render_explains_missing_allowance_and_errors
    assert_includes Rubot::OpencodeUsageReport.render({ unavailable: true }), "No OpenCode Go allowance"
    assert_includes Rubot::OpencodeUsageReport.render({ error: "HTTP 500" }), "HTTP 500"
  end

  def test_agent_fetches_usage_for_the_active_provider
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      path = File.join(dir, "config.yml")
      File.write(path, {
        "agents" => { "defaults" => { "workspace" => workspace, "name" => "opencode-go" } },
        "models" => [
          {
            "name" => "opencode-go",
            "model" => "opencode/claude-sonnet-4",
            "api_key" => "sk-opencode",
            "api_base" => "https://opencode.ai/zen/go/v1"
          }
        ]
      }.to_yaml)

      captured = nil
      fetch = lambda do |api_base:, api_key:|
        captured = { api_base: api_base, api_key: api_key }
        { "rolling" => { "percent" => 1.0, "limited" => false, "resets_at" => nil } }
      end

      config = Rubot::Config.new(path)
      agent = Rubot::Agent.new(config: config, session_id: "opencode-usage")

      mod = Rubot::OpencodeUsage
      mod.singleton_class.alias_method(:fetch_without_test_stub, :fetch)
      mod.define_singleton_method(:fetch) { |**kwargs| fetch.call(**kwargs) }
      begin
        result = agent.opencode_usage
      ensure
        mod.singleton_class.alias_method(:fetch, :fetch_without_test_stub)
        mod.singleton_class.remove_method(:fetch_without_test_stub)
      end

      assert_equal "https://opencode.ai/zen/go/v1", captured[:api_base]
      assert_equal "sk-opencode", captured[:api_key]
      assert_equal 1.0, result["rolling"]["percent"]
    end
  end
end
