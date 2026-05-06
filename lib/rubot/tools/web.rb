# frozen_string_literal: true

require "net/http"
require "ipaddr"
require "uri"
require_relative "../tool"

module Rubot
  module Tools
    class Web < Tool
      MAX_BODY = 5_000

      # Private/reserved IP ranges to block (SSRF protection)
      BLOCKED_IP_RANGES = [
        "10.0.0.0/8",       # RFC 1918 private
        "172.16.0.0/12",    # RFC 1918 private
        "192.168.0.0/16",   # RFC 1918 private
        "127.0.0.0/8",      # Loopback
        "169.254.0.0/16",   # Link-local
        "0.0.0.0/8",        # Current network
        "::1/128",           # IPv6 loopback
        "fc00::/7",         # IPv6 unique local
        "fe80::/10"        # IPv6 link-local
      ].freeze

      def name
        "web_fetch"
      end

      def description
        <<~DESC.strip
          Fetch content from a URL via HTTP GET. Useful for reading web pages,
          APIs, or any publicly accessible HTTP resource.
          Returns the response body (truncated to #{MAX_BODY} characters).
          Internal/private IPs are blocked for safety.
        DESC
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "url" => {
              "type" => "string",
              "description" => "The URL to fetch"
            }
          },
          "required" => [ "url" ]
        }
      end

      def execute(arguments)
        url = arguments["url"]
        raise "No URL provided" if url.nil? || url.strip.empty?

        uri = URI(url)
        # Safety: only allow http and https
        unless %w[http https].include?(uri.scheme)
          return "ERROR: Only http and https URLs are allowed."
        end

        # Safety: block private/internal IPs (SSRF protection)
        blocked_ip = check_blocked_host(uri.host)
        if blocked_ip
          return "ERROR: Access blocked by safety guard: #{uri.host} resolves to internal/private address (#{blocked_ip})"
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = 10
        http.read_timeout = 15
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER

        path = uri.path.empty? ? "/" : uri.path
        path += "?#{uri.query}" if uri.query

        response = http.get(path, { "User-Agent" => "rubot/#{Rubot::VERSION}" })

        body = response.body.to_s
        body = body[0...MAX_BODY] + "\n... (body truncated)" if body.length > MAX_BODY

        "HTTP #{response.code} #{response.message}\n#{body}"
      rescue SocketError => e
        "ERROR: Could not resolve host: #{e.message}"
      rescue Errno::ECONNREFUSED => e
        "ERROR: Connection refused: #{e.message}"
      rescue Net::OpenTimeout, Net::ReadTimeout
        "ERROR: Request timed out"
      rescue StandardError => e
        "ERROR: #{e.class}: #{e.message}"
      end

      private

      # Check if a hostname resolves to a blocked (private/internal) IP.
      # @param host [String] Hostname to check
      # @return [String, nil] The blocked IP address, or nil if safe
      def check_blocked_host(host)
        # Block obvious localhost patterns
        return "localhost" if host =~ /\A(localhost|localhost\.localdomain)\z/i

        # Resolve all IPs for the host and check each
        begin
          require "resolv"
          addresses = Resolv.getaddresses(host)
        rescue StandardError
          return nil # If we can't resolve, let the connection attempt handle it
        end

        blocked_ranges = BLOCKED_IP_RANGES.map { |r| IPAddr.new(r) }

        addresses.each do |addr_str|
          begin
            ip = IPAddr.new(addr_str)
            blocked_ranges.each do |range|
              return addr_str if range.include?(ip)
            end
          rescue IPAddr::InvalidAddressError
            next # Skip invalid addresses
          end
        end

        nil
      end
    end
  end
end
