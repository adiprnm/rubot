# frozen_string_literal: true

require "net/http"
require "ipaddr"
require "socket"
require "uri"
require_relative "../tool"

module Rubot
  module Tools
    class Web < Tool
      # Truncation cap for the body that enters the transcript. HTML pages are
      # stripped to plain text *before* this cap applies, so the cap buys the
      # model 5000 characters of content, not raw markup.
      MAX_BODY = 5_000

      # Structuring tags that become newlines so paragraphs and lists do not
      # end up as one unreadable line after the other tags are removed.
      STRUCTURAL_TAGS = "br|p|div|section|article|header|footer|nav|aside|li|tr|h[1-6]" \
                        "|blockquote|figcaption|caption|dt|dd".freeze

      # Entities present in virtually every page. Numeric and hex forms are
      # decoded generically; anything unknown becomes a space so that markup
      # noise like "&weirdthing;" never reaches the transcript.
      NAMED_ENTITIES = { "amp" => "&", "lt" => "<", "gt" => ">",
                         "quot" => '"', "apos" => "'", "nbsp" => " " }.freeze

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
          HTML pages are returned as readable plain text (scripts, styles, and
          tags removed); JSON and other raw bodies are passed through as-is.
          Output is truncated to #{MAX_BODY} characters.
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

        content_type = response["content-type"].to_s
        body = normalize_body(response.body.to_s, content_type)
        body = extract_text(body) if html?(content_type, body)
        body = body[0...MAX_BODY] + "\n... (body truncated)" if body.length > MAX_BODY

        "HTTP #{response.code} #{response.message} (#{content_type.split(';').first.to_s.strip})\n#{body}"
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

      # Net::HTTP returns bytes; decode with the declared charset and always
      # end up with UTF-8, so that both the text extraction and the transcript
      # stay valid UTF-8 regardless of what the server sent.
      def normalize_body(body, content_type)
        charset = content_type[/charset=([^\s;]+)/i, 1]
        begin
          body = body.force_encoding(charset || "UTF-8")
        rescue ArgumentError
          body = body.dup.force_encoding("UTF-8")
        end
        body = body.encode("UTF-8", invalid: :replace, undef: :replace) unless body.valid_encoding?
        body = body.encode("UTF-8") unless body.encoding == Encoding::UTF_8
        body
      rescue StandardError, ArgumentError
        body.to_s.scrub
      end

      # Prefer the Content-Type, but fall back to sniffing: some servers omit
      # the header, and the model still benefits from readable text there.
      def html?(content_type, body)
        return true if content_type =~ %r{text/html|application/xhtml}i
        return false unless content_type.strip.empty?

        body =~ %r{<\s*(!DOCTYPE\s+html|html[\s>]|\?xml)}i
      end

      # Turn an HTML page into plain text. Deliberately regex-based and
      # dependency-free: this output is for the model, not for rendering, so a
      # corner case rendering slightly wrong is acceptable where burning a
      # parser dependency is not.
      def extract_text(html)
        text = html.dup

        # Keep the document title, then drop the whole head (metadata, links,
        # inline styles) and every other non-text block.
        title = text[%r{<\s*title[^>]*>(.*?)<\s*/\s*title\s*>}im, 1].to_s.scrub.strip
        text = text.gsub(%r{<\s*(script|style|noscript|template|head|iframe|svg|canvas)\b.*?<\s*/\s*\1\s*>}im, " ")
        text = text.gsub(%r{<!--.*?-->}m, " ")

        # Structural tags become newlines so paragraphs and lists stay readable.
        text = text.gsub(%r{<\s*(?:#{STRUCTURAL_TAGS})\b[^>]*>}i, "\n")
        text = text.gsub(%r{</\s*(?:#{STRUCTURAL_TAGS})\s*>}i, "\n")

        # Everything else that is left over.
        text = text.gsub(%r{<[^>]+>}, " ")
        text = decode_entities(title.empty? ? text : "#{title}\n\n#{text}")

        text
          .gsub(/[ \t\r\f\v]+/, " ")
          .gsub(/[ \t]*\n[ \t]*/, "\n")
          .gsub(/\n{3,}/, "\n\n")
          .strip
      end

      # Decode the entities a page cannot avoid. Unknown names degrade to a
      # space instead of being sent to the model as literal "&name;".
      def decode_entities(text)
        text.gsub(/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/) do
          entity = Regexp.last_match(1)
          case entity
          when /\A#x([0-9a-fA-F]+)\z/i then codepoint($1.to_i(16))
          when /\A#(\d+)\z/           then codepoint($1.to_i)
          else NAMED_ENTITIES.fetch(entity.downcase, " ")
          end
        end
      end

      def codepoint(number)
        number.positive? && number <= 0x10FFFF ? [ number ].pack("U") : " "
      rescue RangeError
        " "
      end

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
