# frozen_string_literal: true

require "json"
require "fileutils"
require "net/http"
require "time"
require "uri"

module Rubot
  # Fetches model pricing and context windows from models.dev and caches a
  # slimmed copy in the workspace (`<workspace>/model_pricing.json`).
  #
  # Precedence used by Agent#usage_report:
  #   1. `pricing:` in config.yml (model preset / model entry)
  #   2. this catalog (fresh API response or the cached file)
  #   3. the bundled ModelInfo defaults
  #
  # The cache keeps /usage fast and keeps working when the network is down.
  # Delete the file to force a refresh.
  class PricingCatalog
    SOURCE_URL = "https://models.dev/api.json"
    CACHE_FILENAME = "model_pricing.json"
    DEFAULT_TTL = 24 * 60 * 60

    # Rubot provider names -> models.dev provider ids.
    PROVIDER_ALIASES = {
      "openai_compatible" => "openai",
      "azure" => "openai",
      "azure_openai" => "openai",
      "claude" => "anthropic",
      "gemini" => "google",
      "google_gemini" => "google",
      "opencode_go" => "opencode"
    }.freeze

    attr_reader :source

    def initialize(config:, ttl: DEFAULT_TTL)
      @config = config
      @ttl = ttl
      @models = {}
      @by_id = {}
      @provider_ids = {}
      @loaded_at = nil
      @source = nil
    end

    # Returns {"input" =>, "output" =>, "cached_input" =>,
    # "cache_creation_input" =>} in USD per 1M tokens, or nil when unknown.
    def rates(model, provider: nil)
      entry = entry_for(model, provider: provider)
      return nil unless entry && entry["priced"]

      {
        "input" => entry["input"].to_f,
        "output" => entry["output"].to_f,
        "cached_input" => (entry["cached_input"] || entry["input"]).to_f,
        "cache_creation_input" => (entry["cache_creation_input"] || entry["input"].to_f * 1.25)
      }
    end

    def context_window(model, provider: nil)
      entry = entry_for(model, provider: provider)
      window = entry && entry["context_window"].to_i
      window&.positive? ? window : nil
    end

    def self.cache_path(workspace)
      return nil if workspace.nil? || workspace.to_s.empty?

      File.join(workspace.to_s, CACHE_FILENAME)
    end

    private

    def entry_for(model, provider: nil)
      ensure_loaded

      provider_id = provider_key(provider)
      ids = candidate_ids(model, provider_id)

      ids.each do |id|
        entry = @models["#{provider_id}/#{id}"]
        return entry if entry
      end

      # The configured provider may not exist in models.dev (or may be an
      # OpenAI-compatible proxy). Fall back to the same model id elsewhere.
      ids.each do |id|
        entry = @by_id[id]
        return entry if entry
      end

      ids.each do |id|
        @models.each_value do |entry|
          return entry if entry["id"].to_s.split("/").last == id
        end
      end

      nil
    end

    def provider_key(provider)
      key = provider.to_s.downcase.strip
      PROVIDER_ALIASES.fetch(key, key)
    end

    def candidate_ids(model, provider_id)
      raw = model.to_s.strip
      return [] if raw.empty?

      ids = [ raw ]
      prefix, rest = raw.split("/", 2)
      if rest && (prefix == provider_id || @provider_ids[prefix])
        ids << rest
      end
      ids.uniq
    end

    def ensure_loaded
      return if @loaded_at && (Time.now - @loaded_at) < @ttl

      cached = read_cache
      if cached && fresh?(cached)
        install(cached["models"], "models.dev cache")
        return
      end

      fetched = fetch
      if fetched
        install(fetched, "models.dev")
        write_cache(fetched)
      elsif cached
        install(cached["models"], "models.dev cache (stale)")
      else
        install({}, nil)
      end
    end

    def install(models, source)
      @models = models
      @source = source
      @by_id = {}
      @provider_ids = {}

      models.each do |key, entry|
        next unless entry.is_a?(Hash)

        provider_id = key.to_s.split("/", 2).first
        @provider_ids[provider_id] = true

        id = entry["id"].to_s
        @by_id[id] ||= entry unless id.empty?
        short = id.split("/").last
        @by_id[short] ||= entry if short && !short.empty?
      end

      @loaded_at = Time.now
    end

    def fresh?(cached)
      updated_at = cached["updated_at"]
      return false unless updated_at

      (Time.now - updated_at) < @ttl
    rescue StandardError
      false
    end

    def fetch
      data = fetch_models
      return nil if data.nil?

      models = parse(data)
      return nil if models.empty?

      models
    rescue StandardError => e
      warn "[pricing_catalog] failed to fetch pricing: #{e.class}: #{e.message}"
      nil
    end

    # Overridable for tests.
    def fetch_models
      uri = URI(SOURCE_URL)
      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 10,
        read_timeout: 60
      ) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request["Accept"] = "application/json"
        request["User-Agent"] = "rubot/#{Rubot::VERSION}"
        http.request(request)
      end

      return {} unless response.code.to_i == 200

      JSON.parse(response.body)
    end

    def parse(data)
      return {} unless data.is_a?(Hash)

      result = {}
      data.each do |provider_id, provider|
        next unless provider.is_a?(Hash)

        models = provider["models"]
        next unless models.is_a?(Hash)

        models.each do |model_id, model|
          next unless model.is_a?(Hash)

          cost = model["cost"].is_a?(Hash) ? model["cost"] : {}
          limit = model["limit"].is_a?(Hash) ? model["limit"] : {}
          context = limit["context"].to_i
          priced = cost.key?("input") || cost.key?("output")
          next unless priced || context.positive?

          result["#{provider_id}/#{model_id}"] = {
            "id" => model_id.to_s,
            "provider" => provider_id.to_s,
            "input" => cost["input"],
            "output" => cost["output"],
            "cached_input" => cost["cache_read"],
            "cache_creation_input" => cost["cache_write"],
            "context_window" => context.positive? ? context : nil,
            "priced" => priced
          }
        end
      end
      result
    end

    def read_cache
      path = self.class.cache_path(@config.workspace)
      return nil unless path && File.exist?(path)

      data = JSON.parse(File.read(path))
      models = data["models"]
      return nil unless models.is_a?(Hash)

      updated_at = begin
        Time.parse(data["updated_at"].to_s)
      rescue StandardError
        nil
      end

      { "models" => models, "updated_at" => updated_at }
    rescue JSON::ParserError, SystemCallError => e
      warn "[pricing_catalog] ignoring unreadable #{path}: #{e.message}"
      nil
    end

    def write_cache(models)
      path = self.class.cache_path(@config.workspace)
      return unless path

      FileUtils.mkdir_p(File.dirname(path))
      payload = JSON.generate(
        "updated_at" => Time.now.utc.iso8601,
        "source" => SOURCE_URL,
        "models" => models
      )
      tmp = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
      File.write(tmp, payload)
      File.rename(tmp, path)
    rescue StandardError => e
      warn "[pricing_catalog] failed to write cache: #{e.class}: #{e.message}"
    ensure
      FileUtils.rm_f(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end
  end
end
