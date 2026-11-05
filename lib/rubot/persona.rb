# frozen_string_literal: true

require "time"

module Rubot
  # A per-topic persona: the model and system prompt that apply to one
  # Telegram forum topic. Plain data (a value object), so it can be handed
  # to a session Ractor without sharing mutable state.
  class Persona
    attr_reader :name, :preset, :model, :system_prompt, :created_at

    def initialize(name: nil, preset: nil, model: nil, system_prompt: nil, created_at: nil)
      @name = normalize_string(name)
      @preset = normalize_string(preset)
      @model = normalize_string(model)
      @system_prompt = normalize_string(system_prompt)
      @created_at = created_at || Time.now.utc.iso8601
    end

    # Build a Persona from a Hash (string or symbol keys) or return the
    # Persona unchanged. Returns nil when the value carries no persona data.
    def self.from(value)
      return value if value.is_a?(Persona)
      return nil unless value.is_a?(Hash)

      fetch = lambda do |key|
        value[key] || value[key.to_sym]
      end

      persona = new(
        name: fetch.call("name"),
        preset: fetch.call("preset"),
        model: fetch.call("model"),
        system_prompt: fetch.call("system_prompt"),
        created_at: fetch.call("created_at")
      )
      persona.empty? ? nil : persona
    end

    def to_h
      {
        "name" => @name,
        "preset" => @preset,
        "model" => @model,
        "system_prompt" => @system_prompt,
        "created_at" => @created_at
      }
    end

    def empty?
      [ @name, @preset, @model, @system_prompt ].all? { |value| value.nil? || value.empty? }
    end

    private

    def normalize_string(value)
      return nil if value.nil?

      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
