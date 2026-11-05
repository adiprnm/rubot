# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "model_catalog"
require_relative "persona"

module Rubot
  # File-backed store for per-topic personas.
  #
  # The file lives at `<workspace>/personas.json` so it survives container
  # restarts and can be edited by hand. Keys are `"<chat_id>:<thread_id>"`
  # because a Telegram thread id is only unique inside its chat.
  #
  # The file is read on every lookup instead of being cached: the Telegram
  # channel and the SessionPool own separate store instances, and a persona
  # saved by the channel must be visible to the pool immediately.
  class PersonaStore
    FILENAME = "personas.json"
    KEY_PATTERN = /\A-?\d+:\d+\z/

    attr_reader :workspace, :available_models, :available_presets

    def initialize(workspace:, available_models: nil, available_presets: nil)
      @workspace = workspace || File.join(Dir.home, ".rubot", "workspace")
      @available_models = Array(available_models)
        .map { |name| name.to_s.strip }
        .reject(&:empty?)
      @available_presets = Array(available_presets)
        .map { |name| name.to_s.strip }
        .reject(&:empty?)
      @mutex = Mutex.new
    end

    def path
      File.join(workspace, FILENAME)
    end

    # Returns a Hash of key => Persona.
    def all
      @mutex.synchronize { load_from_disk }
    end

    def [](key)
      all[key.to_s]
    end

    def get(chat_id, thread_id)
      key = self.class.key_for(chat_id, thread_id)
      key && self[key]
    end

    def get_by_session(session_id)
      key = self.class.key_for_session(session_id)
      key && self[key]
    end

    def key_for(chat_id, thread_id)
      self.class.key_for(chat_id, thread_id)
    end

    def set(key, persona)
      key = key.to_s
      raise ArgumentError, "invalid persona key: #{key.inspect}" unless valid_key?(key)

      persona = Persona.from(persona)
      raise ArgumentError, "invalid persona" unless persona

      persona = normalize_persona(persona)

      @mutex.synchronize do
        data = load_from_disk
        data[key] = persona
        write!(data)
      end

      persona
    end

    def delete(key)
      key = key.to_s
      @mutex.synchronize do
        data = load_from_disk
        removed = data.delete(key)
        write!(data) if removed
        removed
      end
    end

    # "chat:thread", or nil for non-topic sessions (Telegram's General
    # topic uses the global/default persona).
    def self.key_for(chat_id, thread_id)
      return nil if chat_id.nil? || thread_id.nil?

      chat = chat_id.to_s
      thread = thread_id.to_s
      return nil unless chat.match?(/\A-?\d+\z/) && thread.match?(/\A\d+\z/)

      "#{chat}:#{thread}"
    end

    # Maps a Telegram session id ("tg_<chat>_<thread>") to a persona key.
    def self.key_for_session(session_id)
      match = /\Atg_(-?\d+)_(\d+)\z/.match(session_id.to_s)
      match && "#{match[1]}:#{match[2]}"
    end

    private

    def valid_key?(key)
      KEY_PATTERN.match?(key)
    end

    # A persona whose model disappeared from config.yml must fall back to
    # the default model rather than breaking the topic.
    def normalize_persona(persona)
      if persona.preset
        alias_preset = persona.preset.casecmp?("default") || persona.preset.casecmp?("primary")
        valid_preset = alias_preset || available_presets.empty? ||
                       available_presets.any? { |name| name.casecmp?(persona.preset) }
        return persona if valid_preset

        warn "[persona] model preset '#{persona.preset}' is not configured — using the session default"
        return Persona.new(
          name: persona.name,
          model: persona.model,
          system_prompt: persona.system_prompt,
          created_at: persona.created_at
        )
      end

      model = persona.model
      return persona if model.nil? || available_models.empty?
      return persona if available_models.include?(model)
      return persona if ModelCatalog.cached_model_ids(workspace).include?(model)

      warn "[persona] model '#{model}' is not in config.yml — using the default model"
      Persona.new(
        name: persona.name,
        model: nil,
        system_prompt: persona.system_prompt,
        created_at: persona.created_at
      )
    end

    def load_from_disk
      return {} unless File.exist?(path)

      raw = File.read(path)
      return {} if raw.strip.empty?

      parsed = JSON.parse(raw)
      return {} unless parsed.is_a?(Hash)

      parsed.each_with_object({}) do |(key, value), personas|
        unless valid_key?(key)
          warn "[persona] ignoring invalid key #{key.inspect} in #{path}"
          next
        end

        persona = Persona.from(value)
        next unless persona

        personas[key] = normalize_persona(persona)
      end
    rescue JSON::ParserError => e
      warn "[persona] ignoring unreadable #{path}: #{e.message}"
      {}
    end

    def write!(data)
      FileUtils.mkdir_p(File.dirname(path))
      payload = JSON.pretty_generate(data.transform_values(&:to_h))
      tmp = "#{path}.tmp.#{Process.pid}.#{Thread.current.object_id}"

      File.write(tmp, payload)
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end
  end
end
