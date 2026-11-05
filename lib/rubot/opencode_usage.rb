# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"

module Rubot
  # OpenCode Go subscription allowance, as reported by the provider.
  #
  # GET {origin}/zen/go/v1/usage with the configured API key returns:
  #
  #   {
  #     "usage" => {
  #       "rolling" => { "status" => "ok", "percent" => 12.5, "resetsAt" => "..." },
  #       "weekly"  => { ... },
  #       "monthly" => { ... }
  #     }
  #   }
  #
  # A 403 means the account has no OpenCode Go allowance. Everything here is
  # plain data so the result can cross a Ractor boundary.
  module OpencodeUsage
    USAGE_PATH = "/zen/go/v1/usage"
    METERS = %w[rolling weekly monthly].freeze
    DEFAULT_ORIGIN = "https://opencode.ai"

    module_function

    # True when the active API base points at OpenCode (OpenCode Go / Zen).
    def supported?(api_base)
      uri = parse_uri(api_base)
      return false unless uri

      uri.host.to_s.downcase.end_with?("opencode.ai")
    end

    # Returns a Hash of meter name => meter data, or a Hash with :error /
    # :unavailable describing why there is nothing to show.
    def fetch(api_base:, api_key: nil, open_timeout: 10, read_timeout: 15)
      unless supported?(api_base)
        return { error: "the active provider is not OpenCode (api_base: #{api_base || 'not set'})" }
      end

      uri = URI.join(origin(api_base), USAGE_PATH)
      request = Net::HTTP::Get.new(uri.request_uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{api_key}" if api_key && !api_key.to_s.empty?

      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: open_timeout,
        read_timeout: read_timeout
      ) { |http| http.request(request) }

      case response.code.to_i
      when 200
        parse(JSON.parse(response.body))
      when 403
        { unavailable: true }
      else
        { error: "HTTP #{response.code}" }
      end
    rescue JSON::ParserError
      { error: "the provider returned an invalid JSON response" }
    rescue StandardError => e
      { error: "#{e.class}: #{e.message}" }
    end

    # Normalizes the provider payload into { "rolling" => {...}, ... }.
    def parse(body)
      usage = body.is_a?(Hash) ? (body["usage"] || body) : {}
      usage = {} unless usage.is_a?(Hash)

      meters = METERS.each_with_object({}) do |name, acc|
        meter = meter_data(usage[name])
        acc[name] = meter if meter
      end
      return { error: "the provider response did not include any usage meters" } if meters.empty?

      meters
    end

    def meter_data(raw)
      return nil unless raw.is_a?(Hash)

      percent = raw["percent"] || raw["usedPercent"] || raw["used_percent"]
      return nil if percent.nil?

      {
        "percent" => [ percent.to_f, 0.0 ].max.clamp(0.0, 100.0),
        "limited" => raw["status"].to_s == "rate-limited" || raw["limited"] == true,
        "resets_at" => raw["resetsAt"] || raw["resets_at"]
      }
    end

    def origin(api_base)
      uri = parse_uri(api_base)
      return DEFAULT_ORIGIN unless uri

      "#{uri.scheme}://#{uri.host}#{":#{uri.port}" if uri.port && uri.port != uri.default_port}"
    end

    def parse_uri(value)
      return nil if value.nil? || value.to_s.strip.empty?

      uri = URI.parse(value.to_s)
      uri.host ? uri : nil
    rescue URI::InvalidURIError
      nil
    end
  end

  # Plain-text renderer for the /usage command.
  module OpencodeUsageReport
    module_function

    def render(report)
      return "📈 OpenCode usage\n   No OpenCode Go allowance is available for this account." if report[:unavailable]

      if report[:error]
        return "📈 OpenCode usage\n   Unavailable — #{report[:error]}"
      end

      lines = [ "📈 OpenCode Go usage" ]
      OpencodeUsage::METERS.each do |name|
        meter = report[name]
        next unless meter

        lines << format("   %-8s %5.1f%% used%s%s", label(name), meter["percent"], limited(meter), reset(meter))
      end
      lines.join("\n")
    end

    def label(name)
      "#{name.capitalize}:"
    end

    def limited(meter)
      meter["limited"] ? " — rate limited" : ""
    end

    def reset(meter)
      time = parse_time(meter["resets_at"])
      return "" unless time

      " — resets in #{relative(time)}"
    end

    def parse_time(value)
      case value
      when Time then value
      when Numeric
        seconds = value.to_f
        seconds /= 1000 if seconds > 100_000_000_000
        Time.at(seconds)
      when String
        return nil if value.strip.empty?

        Time.parse(value)
      end
    rescue ArgumentError
      nil
    end

    def relative(time)
      seconds = (time - Time.now).to_i
      return "now" if seconds <= 0

      days, rest = seconds.divmod(86_400)
      hours, rest = rest.divmod(3_600)
      minutes = rest / 60

      if days.positive?
        "#{days}d #{hours}h"
      elsif hours.positive?
        "#{hours}h #{minutes}m"
      else
        "#{minutes}m"
      end
    end
  end
end
