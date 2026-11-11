# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "provider"

module Rubot
  # Fetches the list of models supported by the configured provider.
  #
  # OpenAI-compatible endpoints (including OpenCode Go) expose GET /models.
  # The list is cached in memory and on disk (`model_catalog.json` next to
  # config.yml, see Config#catalog_dir) so a provider that is temporarily
  # unreachable does not empty the picker, so session actors in other Ractors
  # can validate a persona model without their own network request, and so
  # every persona shares one copy instead of refreshing its own.
  class ModelCatalog
    CACHE_FILENAME = "model_catalog.json"
    DEFAULT_TTL = 300

    def initialize(config:, ttl: DEFAULT_TTL)
      @config = config
      @ttl = ttl
      @mutex = Mutex.new
      @entries = nil
      @fetched_at = nil
    end

    # Returns [{ "id" => "deepseek-v4-pro", "name" => "DeepSeek V4 Pro" }, ...].
    def entries
      cached = @mutex.synchronize do
        @entries if @entries && @fetched_at && (Time.now - @fetched_at) < @ttl
      end
      return cached if cached

      fetched = fetch
      if fetched.empty?
        fetched = read_cache
      else
        begin
          write_cache(fetched)
        rescue StandardError => e
          warn "[model_catalog] failed to write cache: #{e.class}: #{e.message}"
        end
      end

      @mutex.synchronize do
        @entries = fetched
        @fetched_at = Time.now
      end

      fetched
    end

    def clear!
      @mutex.synchronize do
        @entries = nil
        @fetched_at = nil
      end
    end

    # The ids of the models already loaded in memory. No network call is
    # made: an empty list means the catalog was never fetched.
    def cached_ids
      @mutex.synchronize do
        Array(@entries).filter_map { |model| model.is_a?(Hash) ? model["id"] : nil }
      end
    end

    def self.cache_path(dir)
      File.join(dir.to_s, CACHE_FILENAME)
    end

    # Entries from the on-disk cache, without touching the network. What a
    # caller wants when a slow provider must not block a page.
    def self.cached_entries(dir)
      path = cache_path(dir)
      return [] unless File.exist?(path)

      data = JSON.parse(File.read(path))
      models = data.is_a?(Hash) ? data["models"] : data
      Array(models).select { |model| model.is_a?(Hash) }
    rescue JSON::ParserError, SystemCallError => e
      warn "[model_catalog] ignoring unreadable #{path}: #{e.message}"
      []
    end

    # Model ids from the on-disk cache. Used by PersonaStore and Agent to
    # resolve a provider model id that is not a config.yml entry.
    def self.cached_model_ids(dir)
      cached_entries(dir).filter_map { |model| model["id"] || model["name"] }
    end

    private

    def fetch
      settings = @config.provider_settings
      provider = Provider.build(settings)
      return [] unless provider.respond_to?(:list_models)

      provider.list_models.filter_map do |model|
        next unless model.is_a?(Hash)

        id = model["id"] || model["model"] || model["name"]
        next if id.nil? || id.to_s.strip.empty?

        {
          "id" => id.to_s.strip,
          "name" => (model["name"] || id).to_s.strip
        }
      end
    rescue StandardError => e
      warn "[model_catalog] failed to list models: #{e.class}: #{e.message}"
      []
    end

    def read_cache
      path = self.class.cache_path(@config.catalog_dir)
      return [] unless File.exist?(path)

      data = JSON.parse(File.read(path))
      models = data.is_a?(Hash) ? data["models"] : data
      Array(models).filter_map do |model|
        next unless model.is_a?(Hash)

        id = model["id"] || model["name"]
        next if id.nil? || id.to_s.strip.empty?

        {
          "id" => id.to_s.strip,
          "name" => (model["name"] || id).to_s.strip
        }
      end
    rescue JSON::ParserError, SystemCallError => e
      warn "[model_catalog] ignoring unreadable #{path}: #{e.message}"
      []
    end

    def write_cache(entries)
      dir = @config.catalog_dir
      return if dir.nil? || dir.to_s.empty?

      path = self.class.cache_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
      File.write(tmp, JSON.pretty_generate(
        "updated_at" => Time.now.utc.iso8601,
        "models" => entries
      ))
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end
  end
end
