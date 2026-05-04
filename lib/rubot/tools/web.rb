# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "../tool"

module Rubot
  module Tools
    class Web < Tool
      MAX_BODY = 5_000

      def name
        "web_fetch"
      end

      def description
        <<~DESC.strip
          Fetch content from a URL via HTTP GET. Useful for reading web pages,
          APIs, or any publicly accessible HTTP resource.
          Returns the response body (truncated to #{MAX_BODY} characters).
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
    end
  end
end
