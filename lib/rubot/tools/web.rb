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

        # FIX (VULN-12): Resolve IP FIRST and connect directly to the IP address
        # to prevent DNS rebinding attacks where the hostname resolves to a
        # different IP between the safety check and the actual connection.
        resolved_ip = resolve_and_check_host(uri.host)
        if resolved_ip.nil?
          return "ERROR: Access blocked by safety guard: #{uri.host} could not be resolved"
        end

        http = Net::HTTP.new(resolved_ip, uri.port)
        http.open_timeout = 10
        http.read_timeout = 15
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER

        # FIX (VULN-12): For HTTPS, configure SNI with the original hostname
        # so certificate verification works when connecting by IP address
        if http.use_ssl
          http.ssl_context = OpenSSL::SSL::SSLContext.new.tap do |ctx|
            ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
            ctx.verify_hostname = true
            ctx.servername = uri.host  # SNI uses hostname, not IP
          end
        end

        path = uri.path.empty? ? "/" : uri.path
        path += "?#{uri.query}" if uri.query

        # FIX (VULN-12): Use original hostname for Host header and SNI,
        # but we connected to the resolved IP address directly.
        headers = {
          "User-Agent" => "rubot/#{Rubot::VERSION}",
          "Host" => uri.host
        }
        http.set_debug_output(nil)  # prevent info leaks

        response = http.get(path, headers)

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

      # FIX (VULN-12): Resolve a hostname and return the IP address if it's
      # safe, or nil if it's blocked. This returns the IP for direct connection,
      # preventing DNS rebinding where the hostname changes between check and use.
      #
      # @param host [String] Hostname to check
      # @return [String, nil] The safe IP address, or nil if blocked
      def resolve_and_check_host(host)
        # Block obvious localhost patterns
        return nil if host =~ /\A(localhost|localhost\.localdomain)\z/i

        # Resolve all IPs for the host and check each
        begin
          require "resolv"
          addresses = Resolv.getaddresses(host)
        rescue StandardError
          return nil # If we can't resolve, block it
        end

        blocked_ranges = BLOCKED_IP_RANGES.map { |r| IPAddr.new(r) }

        addresses.each do |addr_str|
          begin
            ip = IPAddr.new(addr_str)
            blocked_ranges.each do |range|
              return nil if range.include?(ip) # Blocked — return nil
            end
          rescue IPAddr::InvalidAddressError
            next # Skip invalid addresses
          end
        end

        # Return the first non-blocked address for direct connection
        # This prevents DNS rebinding — we connect to this specific IP
        addresses.each do |addr_str|
          begin
            ip = IPAddr.new(addr_str)
            unless blocked_ranges.any? { |range| range.include?(ip) }
              return addr_str
            end
          rescue IPAddr::InvalidAddressError
            next
          end
        end

        nil # All addresses blocked
      end
    end
  end
end
