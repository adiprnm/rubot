# frozen_string_literal: true

require_relative "test_helper"
require "socket"

# The gateway routes a request by the conversation header the client sends, and
# keys its prompt cache on that route. These tests hold the two properties the
# cache depends on: the route belongs to the session (so a rebuilt provider
# keeps it), and a different session never inherits it.
class TestProviderRouting < Minitest::Test
  ROUTE_HEADER = "x-opencode-session"

  def setup
    @servers = []
    @threads = []
  end

  def teardown
    @threads.each(&:kill)
    @servers.each { |server| server.close rescue nil } # rubocop:disable Style/RescueModifier
  end

  # A throwaway OpenAI-compatible endpoint that records the headers of every
  # request it answers. Reading the body before writing is deliberate: a stub
  # that closes with the POST payload unread makes the kernel answer with RST
  # and the client sees ECONNRESET instead of the response.
  def with_recording_server
    server = TCPServer.new("127.0.0.1", 0)
    @servers << server
    seen = []

    thread = Thread.new do
      loop do
        client = server.accept
        begin
          headers = {}
          while (line = client.gets)
            break if line == "\r\n"

            name, value = line.split(":", 2)
            headers[name.to_s.strip.downcase] = value.to_s.strip
          end
          length = headers["content-length"].to_i
          client.read(length) if length.positive?
          seen << headers

          body = JSON.generate({
            "choices" => [ { "message" => { "content" => "ok" }, "finish_reason" => "stop" } ],
            "usage" => { "prompt_tokens" => 10, "completion_tokens" => 1 }
          })
          client.write("HTTP/1.1 200 OK\r\n")
          client.write("Content-Type: application/json\r\n")
          client.write("Content-Length: #{body.bytesize}\r\n")
          client.write("Connection: close\r\n\r\n")
          client.write(body)
        ensure
          client&.close
        end
      end
    rescue IOError, Errno::EBADF
      nil
    end
    @threads << thread

    yield "http://127.0.0.1:#{server.addr[1]}", seen
  end

  def settings(base, provider: "opencode", session_key: nil, extra_headers: {})
    Rubot::ProviderSettings.new(
      provider: provider, model: "deepseek-v4.1-flash", api_key: "sk-test",
      api_base: base, max_tokens: 64, temperature: 0.3,
      extra_headers: extra_headers, session_key: session_key
    )
  end

  def route_of(provider)
    provider.instance_variable_get(:@extra_headers)[ROUTE_HEADER]
  end

  def test_a_rebuilt_provider_keeps_the_session_route
    base = "https://opencode.ai/zen/go/v1"

    first = Rubot::Providers::OpenCode.new(settings(base, session_key: "web_rubot~20261113-025157"))
    second = Rubot::Providers::OpenCode.new(settings(base, session_key: "web_rubot~20261113-025157"))

    refute_nil route_of(first)
    assert_equal route_of(first), route_of(second)
  end

  def test_two_sessions_never_share_a_route
    base = "https://opencode.ai/zen/go/v1"

    one = Rubot::Providers::OpenCode.new(settings(base, session_key: "session-one"))
    two = Rubot::Providers::OpenCode.new(settings(base, session_key: "session-two"))

    refute_equal route_of(one), route_of(two)
  end

  def test_the_route_is_a_digest_of_the_session
    base = "https://opencode.ai/zen/go/v1"
    provider = Rubot::Providers::OpenCode.new(settings(base, session_key: "web_rubot~20261113-081444"))

    assert_equal Digest::SHA256.hexdigest("web_rubot~20261113-081444")[0, 32], route_of(provider)
  end

  def test_without_a_session_the_route_is_still_opaque_and_per_instance
    base = "https://opencode.ai/zen/go/v1"

    one = Rubot::Providers::OpenCode.new(settings(base))
    two = Rubot::Providers::OpenCode.new(settings(base))

    refute_nil route_of(one)
    refute_equal route_of(one), route_of(two), "an unstamped provider must not settle on a shared route"
  end

  def test_a_configured_header_wins
    base = "https://opencode.ai/zen/go/v1"
    provider = Rubot::Providers::OpenCode.new(
      settings(base, session_key: "s", extra_headers: { ROUTE_HEADER => "pinned-route" })
    )

    assert_equal "pinned-route", route_of(provider)
  end

  def test_a_non_opencode_provider_sends_no_routing_header
    provider = Rubot::Providers::OpenAI.new(
      settings("https://api.openai.com/v1", provider: "openai", session_key: "s")
    )

    assert_nil route_of(provider)
  end

  def test_the_route_reaches_the_wire
    with_recording_server do |base, seen|
      provider = Rubot::Providers::OpenCode.new(settings(base, session_key: "wire-session"))
      provider.chat([ { "role" => "user", "content" => "halo" } ])

      assert_equal 1, seen.size
      assert_equal Digest::SHA256.hexdigest("wire-session")[0, 32], seen.first[ROUTE_HEADER]
    end
  end

  def test_two_requests_of_one_session_share_the_route_on_the_wire
    with_recording_server do |base, seen|
      # Two providers, as a rebuild would produce, from the same session.
      2.times do
        Rubot::Providers::OpenCode.new(settings(base, session_key: "same-session"))
                        .chat([ { "role" => "user", "content" => "halo" } ])
      end

      assert_equal 2, seen.size
      assert_equal 1, seen.map { |headers| headers[ROUTE_HEADER] }.uniq.size
    end
  end

  def test_stamping_settings_is_a_no_op_when_the_key_already_matches
    settings = Rubot::ProviderSettings.new(
      provider: "opencode", model: "m", api_key: "k", api_base: "http://x/v1",
      max_tokens: 8, temperature: 0, session_key: "s"
    )

    assert_same settings, settings.with_session_key("s")
    refute_same settings, settings.with_session_key("other")
    assert_equal "other", settings.with_session_key("other").session_key
  end

  def test_a_changed_effort_keeps_the_route
    settings = Rubot::ProviderSettings.new(
      provider: "opencode", model: "m", api_key: "k", api_base: "http://x/v1",
      max_tokens: 8, temperature: 0, session_key: "s", reasoning_effort: "low"
    )
    louder = settings.with_effort("high")

    assert_equal "high", louder.reasoning_effort
    assert_equal "s", louder.session_key
  end
end
