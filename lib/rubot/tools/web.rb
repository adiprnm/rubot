# frozen_string_literal: true

require "net/http"
require "ipaddr"
require "socket"
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
        # `hostname` (not `host`) strips the brackets from IPv6 literals.
        resolved_ip = resolve_and_check_host(uri.hostname)
        if resolved_ip.nil?
          return "ERROR: Access blocked by safety guard: #{uri.host} could not be resolved " \
                 "or resolves to a private/reserved address"
        end

        # FIX (VULN-12): Keep the hostname on the request (so SNI, the Host
        # header and certificate verification all stay correct) but pin the
        # TCP connection to the IP we already validated.
        http = Net::HTTP.new(uri.hostname, uri.port)
        http.ipaddr = resolved_ip
        http.open_timeout = 10
        http.read_timeout = 15
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER

        path = uri.path.empty? ? "/" : uri.path
        path += "?#{uri.query}" if uri.query

        headers = { "User-Agent" => "rubot/#{Rubot::VERSION}" }
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

        addresses = resolve_addresses(host)
        return nil if addresses.empty? # If we can't resolve, block it

        ips = addresses.filter_map do |addr_str|
          IPAddr.new(addr_str)
        rescue IPAddr::InvalidAddressError
          nil
        end
        return nil if ips.empty?

        blocked_ranges = BLOCKED_IP_RANGES.map { |r| IPAddr.new(r) }

        # Conservative: if any resolved address is private/reserved, block.
        return nil if ips.any? { |ip| blocked_ranges.any? { |range| range.include?(ip) } }

        # Prefer IPv4 — slim containers usually have no IPv6 route.
        (ips.find(&:ipv4?) || ips.first).to_s
      end

      # Resolve with Socket, not Resolv. `Resolv.getaddresses` keeps its cache in
      # the `Resolv::DefaultResolver` constant, which raises
      # Ractor::IsolationError inside the per-session Ractors — every web_fetch
      # then looked like a DNS failure. `Socket.getaddrinfo` is a plain C call
      # and is Ractor-safe.
      #
      # @param host [String] Hostname to resolve
      # @return [Array<String>] Unique IP addresses, empty when resolution fails
      def resolve_addresses(host)
        Socket.getaddrinfo(host, nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
              .map { |entry| entry[3] }
              .uniq
      rescue SocketError, SystemCallError
        []
      end
    end
  end
end
