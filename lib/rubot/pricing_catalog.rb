# frozen_string_literal: true

require "json"
require "fileutils"
require "net/http"
require "time"
require "uri"
require_relative "usage"
require_relative "model_info"

module Rubot
  # Fetches model pricing and context windows from models.dev and caches a
  # slimmed copy next to config.yml (`model_pricing.json`, see
  # Config#catalog_dir) — one file for the whole install, shared by every
  # persona and every workspace.
  #
  # Precedence used by Agent#usage_report:
  #   1. `pricing:` in config.yml (model preset / model entry)
  #   2. this catalog (fresh API response or the cached file)
  #   3. the bundled ModelInfo defaults
  #
  # The cache keeps /context fast and keeps working when the network is down.
  # Delete the file to force a refresh.
  #
  # `network: false` reads only the cache file. The agent uses that while a
  # turn is running so a slow or unreachable models.dev never delays an answer;
  # the report path (and the footer after the turn) still refreshes it.
  class PricingCatalog
    SOURCE_URL = "https://models.dev/api.json"
    CACHE_FILENAME = "model_pricing.json"
    DEFAULT_TTL = 24 * 60 * 60
    # Bump when the slimmed entry shape changes (e.g. adding `tiers`), so an
    # older cache file is refreshed instead of being used for another day.
    CACHE_VERSION = 2

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
    # "cache_creation_input" =>, "tiers" =>} in USD per 1M tokens, or nil when
    # unknown. Tiers carry the rates that apply above a given input size.
    def rates(model, provider: nil, network: true)
      entry = entry_for(model, provider: provider, network: network)
      return nil unless entry && entry["priced"]

      rates = {
        "input" => entry["input"].to_f,
        "output" => entry["output"].to_f,
        # nil is not zero. A missing cache-read rate would otherwise be priced
        # at the full input rate *silently*, which reads as a measurement; a
        # zero is a provider that really bills cache reads at nothing, and that
        # is one. The input rate here makes the total an upper bound, and the
        # flag below says it is one.
        "cached_input" => entry["cached_input"].nil? ? entry["input"].to_f : entry["cached_input"].to_f,
        # Same reasoning for the write side, minus the premium: the 1.25x of a
        # 5-minute write is Anthropic's number, and the catalog carries it for
        # the models that have one. Inventing it for everybody else would price
        # an OpenAI-compatible write (billed as ordinary input) 25% too high.
        "cache_creation_input" =>
          entry["cache_creation_input"].nil? ? entry["input"].to_f : entry["cache_creation_input"].to_f
      }
      rates["cached_input_unknown"] = true if entry["cached_input"].nil?
      rates["cache_creation_unknown"] = true if entry["cache_creation_input"].nil?
      tiers = entry["tiers"]
      rates["tiers"] = tiers if tiers.is_a?(Array) && !tiers.empty?
      rates
    end

    def context_window(model, provider: nil, network: true)
      entry = entry_for(model, provider: provider, network: network)
      window = entry && entry["context_window"].to_i
      window&.positive? ? window : nil
    end

    # Every distinct model id the catalog knows, so a caller can fall back to
    # the longest known prefix when an exact lookup misses (gateway suffixes
    # like "hy4-flash-free" for "hy4").
    def context_window_ids
      ensure_loaded(network: false)
      @by_id.keys.map { |id| ModelInfo.normalize(id) }.uniq
    end

    # The shared cache file lives next to config.yml (see
    # Config#catalog_dir), not in a workspace: every persona asks the same
    # question of the same file.
    def self.cache_path(dir)
      return nil if dir.nil? || dir.to_s.empty?

      File.join(dir.to_s, CACHE_FILENAME)
    end

    private

    def entry_for(model, provider: nil, network: true)
      ensure_loaded(network: network)

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

    def ensure_loaded(network: true)
      return if @loaded_at && (Time.now - @loaded_at) < @ttl

      cached = read_cache
      if cached && fresh?(cached)
        install(cached["models"], "models.dev cache")
        return
      end

      # The turn path must never block on the network: fall back to the stale
      # cache (or the bundled defaults) and let the report path refresh.
      unless network
        install(cached["models"], "models.dev cache (stale)") if cached
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
      return false unless cached["version"] == CACHE_VERSION

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

          entry = {
            "id" => model_id.to_s,
            "provider" => provider_id.to_s,
            "input" => cost["input"],
            "output" => cost["output"],
            "cached_input" => cost["cache_read"],
            "cache_creation_input" => cost["cache_write"],
            "context_window" => context.positive? ? context : nil,
            "priced" => priced
          }
          tiers = parse_tiers(cost)
          entry["tiers"] = tiers if tiers
          result["#{provider_id}/#{model_id}"] = entry
        end
      end
      result
    end

    # models.dev publishes long-context surcharges as
    # `cost.tiers[].tier.size`; Pi matches them against the request's input
    # size (cached tokens included). Normalize them to the same shape as the
    # base rates so Usage.cost can pick one.
    def parse_tiers(cost)
      raw = cost["tiers"]
      return nil unless raw.is_a?(Array)

      tiers = raw.filter_map do |tier|
        next unless tier.is_a?(Hash)

        spec = tier["tier"].is_a?(Hash) ? tier["tier"] : {}
        threshold = (spec["size"] || tier["input_tokens_above"] || tier["inputTokensAbove"]).to_i
        next unless threshold.positive?

        {
          "input_tokens_above" => threshold,
          "input" => tier["input"],
          "output" => tier["output"],
          "cached_input" => tier["cache_read"] || tier["cacheRead"],
          "cache_creation_input" => tier["cache_write"] || tier["cacheWrite"]
        }.reject { |_, value| value.nil? }
      end
      return nil if tiers.empty?

      tiers.sort_by { |tier| tier["input_tokens_above"] }
    end

    def read_cache
      path = self.class.cache_path(@config.catalog_dir)
      return nil unless path && File.exist?(path)

      data = JSON.parse(File.read(path))
      models = data["models"]
      return nil unless models.is_a?(Hash)

      updated_at = begin
        Time.parse(data["updated_at"].to_s)
      rescue StandardError
        nil
      end

      { "models" => models, "updated_at" => updated_at, "version" => data["version"] }
    rescue JSON::ParserError, SystemCallError => e
      warn "[pricing_catalog] ignoring unreadable #{path}: #{e.message}"
      nil
    end

    def write_cache(models)
      path = self.class.cache_path(@config.catalog_dir)
      return unless path

      FileUtils.mkdir_p(File.dirname(path))
      payload = JSON.generate(
        "version" => CACHE_VERSION,
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
