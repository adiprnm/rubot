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

      # Markdown gets a larger cap because it carries no markup tax: a
      # documentation page that costs 200KB of HTML arrives as a few KB of
      # markdown, and the headings, code fences and tables survive intact.
      MAX_MARKDOWN_BODY = 12_000

      # Redirect chains are common enough (http to https, trailing slash, moved
      # docs) that not following them looked like "the site returned nothing".
      MAX_REDIRECTS = 5
      REDIRECT_CODES = %w[301 302 303 307 308].freeze

      MARKDOWN_TYPES = %r{text/markdown|text/x-markdown|application/markdown}i

      # Everything URI considers unsafe inside a Location header, minus "%" so
      # that already-encoded URLs are not escaped a second time.
      UNSAFE_LOCATION_CHARS = %r{[^A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]}

      # Request headers for every fetch. Two things matter here:
      #
      # * `Accept` lists markdown first. Documentation platforms (Cloudflare,
      #   Mintlify, Anthropic) answer with text/markdown when asked, which is
      #   both smaller and more faithful than anything we can extract from their
      #   HTML. `*/*` keeps the odd API from answering 406.
      # * `Accept-Encoding` is deliberately absent. Net::HTTP adds its own gzip
      #   header and decompresses the body for us; setting it by hand switches
      #   that off and hands the model compressed bytes.
      #
      # The User-Agent is added per request because Rubot::VERSION is defined
      # after this file is loaded.
      REQUEST_HEADERS = {
        "Accept" => "text/markdown;q=1.0, text/html;q=0.9, application/json;q=0.8, */*;q=0.7",
        "Accept-Language" => "en-US,en;q=0.9,id;q=0.8"
      }.freeze

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
          Fetch content from a URL via HTTP GET, following redirects. Useful for
          reading web pages, APIs, or any publicly accessible HTTP resource.
          Documentation sites are returned as markdown (code blocks and tables
          intact); other HTML pages are converted to readable plain text.
          JSON and other raw bodies are passed through as-is.
          Output is truncated to #{MAX_BODY} characters (#{MAX_MARKDOWN_BODY} for markdown).
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

        response, final_uri = request_with_redirects(uri)
        return response if response.is_a?(String)

        content_type = response["content-type"].to_s
        body = normalize_body(response.body.to_s, content_type)
        body, kind, origin = readable_body(body, content_type, final_uri, response.code)

        render(response, uri, origin, body, kind)
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

      # Follow redirects, re-running the SSRF guard on every hop: a first
      # response from a public host is no promise that its Location header
      # points somewhere safe.
      #
      # @return [Array(Net::HTTPResponse, URI), Array(String, URI)] response or
      #   an error message, plus the URL the body actually came from
      def request_with_redirects(uri)
        current = uri
        (MAX_REDIRECTS + 1).times do |hop|
          response = perform_request(current)
          return [ response, current ] if response.is_a?(String)

          location = response["location"].to_s
          return [ response, current ] unless REDIRECT_CODES.include?(response.code) && !location.strip.empty?
          return [ "ERROR: Too many redirects (limit #{MAX_REDIRECTS}): #{uri}", current ] if hop == MAX_REDIRECTS

          target = redirect_target(current, location)
          # An unusable Location header is not a fetch failure: the 3xx response
          # we already have is still an answer.
          return [ response, current ] if target.nil?

          current = target
        end

        [ "ERROR: Too many redirects (limit #{MAX_REDIRECTS}): #{uri}", uri ]
      end

      # Resolve the Location header against the URL that produced it, so a
      # relative "/login" or "page2" works as well as an absolute URL.
      #
      # @return [URI, nil] nil when the header cannot be turned into a safe
      #   http(s) URL with a host
      def redirect_target(uri, location)
        target = URI.join(uri.to_s, normalize_location(location))
        return nil unless %w[http https].include?(target.scheme)
        # "Location: https:" parses with a scheme but no host at all.
        return nil if target.hostname.to_s.empty?

        target
      rescue URI::Error, ArgumentError
        nil
      end

      # Servers do emit Location headers with raw spaces and non-ASCII paths,
      # and URI rejects both outright. Percent-encode only what is not already
      # URI-safe, so an existing "%20" is left alone instead of double-escaped.
      def normalize_location(location)
        location.strip.gsub(UNSAFE_LOCATION_CHARS) do |char|
          char.bytes.map { |byte| format("%%%02X", byte) }.join
        end
      end

      # One request, one validated connection.
      def perform_request(uri)
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
        http.set_debug_output(nil)  # prevent info leaks

        http.get(request_path(uri), request_headers)
      end

      def request_headers
        { "User-Agent" => "Mozilla/5.0 (compatible; rubot/#{Rubot::VERSION})" }.merge(REQUEST_HEADERS)
      end

      def request_path(uri)
        path = uri.path.empty? ? "/" : uri.path
        path += "?#{uri.query}" if uri.query
        path
      end

      # Choose the most readable form of the response body.
      #
      # @return [Array(String, Symbol, URI)] body, its kind (:raw, :html,
      #   :markdown or :markdown_variant) and the URL it actually came from
      def readable_body(body, content_type, uri, code)
        return [ body, :markdown, uri ] if markdown?(content_type, body)
        return [ body, :raw, uri ] unless html?(content_type, body)

        text = extract_text(body)
        # Sites like docs.stripe.com and docs.github.com serve markdown only
        # from a ".md" suffix; they ignore content negotiation. Probing that
        # suffix on every page would double the requests we make to every site
        # we touch, so only pages that actually look like documentation are
        # worth the second call.
        return [ text, :html, uri ] unless probe_worthy?(body, uri, code)

        variant, variant_uri = fetch_markdown_variant(uri)
        # A ".md" suffix does not always mean "the same page as markdown":
        # docs.github.com serves a link index there, which is worse than the
        # text we can get from the HTML.
        return [ text, :html, uri ] if variant.nil? || link_index?(variant)

        [ variant, :markdown_variant, variant_uri ]
      end

      # Every condition that must hold before spending a second request on the
      # markdown variant of a page.
      def probe_worthy?(body, uri, code)
        code.to_s.start_with?("2") && docs_like?(body) && markdown_probeable?(uri)
      end

      def render(response, requested_uri, origin_uri, body, kind)
        limit = kind == :markdown || kind == :markdown_variant ? MAX_MARKDOWN_BODY : MAX_BODY
        body = "#{body[0...limit]}\n... (body truncated)" if body.length > limit

        status = "HTTP #{response.code} #{response.message} (#{content_type_label(response, kind)})"
        # The model should know when it landed somewhere other than the URL it
        # asked for: relative links and canonical pages depend on it. The body
        # may also have come from a ".md" sibling of the page.
        status += "\nFinal URL: #{origin_uri}" unless origin_uri.to_s == requested_uri.to_s

        "#{status}\n#{body}"
      end

      def content_type_label(response, kind)
        declared = response["content-type"].to_s.split(";").first.to_s.strip

        return "text/markdown" if kind == :markdown_variant
        return "text/markdown" if kind == :markdown && declared.match?(MARKDOWN_TYPES)

        declared.empty? ? "text/plain" : declared
      end

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
      # the header, and others send an HTML error page while declaring markdown
      # or plain text, and the model still benefits from readable text there.
      def html?(content_type, body)
        return true if content_type =~ %r{text/html|application/xhtml}i
        return false unless content_type.strip.empty? || content_type =~ %r{markdown|text/plain}i

        body =~ %r{<\s*(!DOCTYPE\s+html|html[\s>]|\?xml|!--)}i
      end

      # Markdown is never converted: its headings, code fences and tables are
      # the whole point, and the HTML stripper would flatten exactly those.
      def markdown?(content_type, body)
        # A few servers answer with HTML whatever the Accept header says, so the
        # declared type alone is not proof. A BOM or a leading comment is a
        # common way for the deception to start, hence the wide window.
        return false if body[0, 1024].to_s.sub(/\A\uFEFF/, "").match?(%r{\A\s*(?:<!doctype|<html|<\?xml|<!--)}i)

        return true if content_type =~ MARKDOWN_TYPES
        return false unless content_type.strip.empty? || content_type =~ %r{text/plain}i

        fenced_markdown?(body)
      end

      # Sniffing fallback for the plain-text case. Fences are required here: a
      # leading "# comment" line is just as common in config files as in prose,
      # and only a pair of fences is strong evidence of a markdown document.
      def fenced_markdown?(body)
        text = body.sub(/\A\uFEFF/, "").lstrip
        return false unless text.start_with?("#") || text.include?("```")

        text.scan(/^```/).size >= 2
      end

      # Documentation pages are worth a second request for their markdown
      # variant; marketing pages, news articles and blogs are not. Code samples
      # are the cheapest reliable signal that a page is documentation.
      def docs_like?(html)
        html.scan(%r{<\s*pre\b}i).size >= 2 || html.scan(%r{<\s*code\b}i).size >= 3
      end

      # Only plain page paths get a ".md" probe: an ".html" page may have a
      # sibling, but a ".png" or ".json" URL does not, and appending a suffix to
      # a query string is meaningless.
      def markdown_probeable?(uri)
        return false unless uri.query.nil?

        [ "", ".html", ".htm" ].include?(File.extname(uri.path))
      end

      # Ask the same page for its markdown source. Returns nil whenever the site
      # does not offer one, so the caller can fall back to the extracted HTML.
      #
      # @return [Array(String, URI), nil] markdown body and the URL it came from
      def fetch_markdown_variant(uri)
        candidate = markdown_variant_url(uri)

        response, target = request_with_redirects(candidate)
        return nil if response.is_a?(String)
        return nil unless response.code == "200"

        content_type = response["content-type"].to_s
        body = normalize_body(response.body.to_s, content_type)
        markdown?(content_type, body) ? [ body, target ] : nil
      rescue StandardError
        nil
      end

      # "/docs/api" becomes "/docs/api.md", but "/docs/api.html" must become
      # "/docs/api.md" too, not "/docs/api.html.md".
      def markdown_variant_url(uri)
        candidate = uri.dup
        path = candidate.path.sub(%r{/+\z}, "").sub(/\.html?\z/i, "")
        candidate.path = path.empty? ? "/index.md" : "#{path}.md"
        candidate
      end

      # docs.github.com serves a link index from its ".md" suffix rather than
      # the page itself. A window that is nothing but bullets and links costs
      # the model more than the HTML-derived text it would replace.
      def link_index?(markdown)
        lines = markdown.lines.map(&:strip).reject(&:empty?)
        return false if lines.size < 5

        links = lines.count { |line| line.match?(%r{\A(?:[-*+]|\d+\.)\s+\[[^\]]+\]\([^)]+\)\z}) }
        links.fdiv(lines.size) > 0.6
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
        # IPv4-mapped IPv6 addresses (::ffff:127.0.0.1) are family 10, so an
        # IPv4 range list never matches them and they would sail straight to
        # loopback or the cloud metadata endpoint. Unwrap before the check.
        return nil if ips.any? { |ip| blocked_ranges.any? { |range| range.include?(ip.native) } }

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
