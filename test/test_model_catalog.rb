# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class TestModelCatalog < Minitest::Test
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
    @server_thread&.kill
    @server_thread&.join(2)
    FileUtils.remove_entry(@tmpdir) if File.directory?(@tmpdir)
  end

  def make_config(api_base:)
    File.write(@config_path, {
      "agents" => { "defaults" => { "workspace" => @workspace, "name" => "opencode-go" } },
      "models" => [
        {
          "name" => "opencode-go",
          "model" => "openai/deepseek-v4.1-flash",
          "api_key" => "sk-test",
          "api_base" => api_base
        }
      ]
    }.to_yaml)
    Rubot::Config.new(@config_path)
  end

  def start_models_server(body)
    @server = TCPServer.new("127.0.0.1", 0)
    port = @server.addr[1]

    @server_thread = Thread.new do
      loop do
        client = @server.accept
        request = +""
        request << client.readpartial(4096) until request.include?("\r\n\r\n")

        client.write("HTTP/1.1 200 OK\r\n")
        client.write("Content-Type: application/json\r\n")
        client.write("Content-Length: #{body.bytesize}\r\n")
        client.write("Connection: close\r\n\r\n")
        client.write(body)
      ensure
        client&.close
      end
    rescue IOError, Errno::EBADF
      nil
    end

    "http://127.0.0.1:#{port}/v1"
  end

  def models_body
    JSON.generate(
      "object" => "list",
      "data" => [
        { "id" => "deepseek-v4.1-flash", "name" => "DeepSeek V4.1 Flash" },
        { "id" => "deepseek-v4-pro", "name" => "DeepSeek V4 Pro" },
        { "id" => "glm-5.3", "name" => "GLM-5.3" }
      ]
    )
  end

  def test_fetches_provider_models_and_writes_the_cache
    api_base = start_models_server(models_body)
    catalog = Rubot::ModelCatalog.new(config: make_config(api_base: api_base))

    entries = catalog.entries

    assert_equal %w[deepseek-v4.1-flash deepseek-v4-pro glm-5.3], entries.map { |e| e["id"] }
    assert_equal "DeepSeek V4 Pro", entries.find { |e| e["id"] == "deepseek-v4-pro" }["name"]
    assert_equal %w[deepseek-v4.1-flash deepseek-v4-pro glm-5.3],
                 Rubot::ModelCatalog.cached_model_ids(@tmpdir)
  end

  def test_falls_back_to_the_disk_cache_when_the_provider_is_unreachable
    path = Rubot::ModelCatalog.cache_path(@tmpdir)
    File.write(path, JSON.generate(
      "models" => [ { "id" => "cached-model", "name" => "Cached Model" } ]
    ))

    catalog = Rubot::ModelCatalog.new(config: make_config(api_base: "http://127.0.0.1:1/v1"))

    assert_equal [ "cached-model" ], catalog.entries.map { |e| e["id"] }
  end

  def test_empty_catalog_when_no_cache_and_no_provider
    catalog = Rubot::ModelCatalog.new(config: make_config(api_base: "http://127.0.0.1:1/v1"))

    assert_empty catalog.entries
  end
end
