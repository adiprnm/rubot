# frozen_string_literal: true

require "time"

module Rubot
  # A persona: one agent specialised in one field.
  #
  # Two kinds share this value object. A Telegram forum topic is keyed by
  # "<chat>:<thread>" and only carries model + prompt. A web persona is keyed by
  # a slug and also owns a workspace (see PersonaStore#workspace_for), which is
  # where its SOUL.md, AGENTS.md, skills/ and working files live.
  #
  # Plain data (a value object), so it can be handed to a session Ractor without
  # sharing mutable state. The workspace path is deliberately *not* stored here:
  # it is derived from the store's directory and the slug, so the file stays
  # portable and cannot point an agent at an arbitrary path.
  class Persona
    attr_reader :slug, :name, :emoji, :accent, :preset, :model, :system_prompt, :created_at

    def initialize(slug: nil, name: nil, emoji: nil, accent: nil, preset: nil, model: nil,
                   system_prompt: nil, created_at: nil)
      @slug = normalize_string(slug)
      @name = normalize_string(name)
      @emoji = normalize_string(emoji)
      @accent = normalize_string(accent)
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
        slug: fetch.call("slug"),
        name: fetch.call("name"),
        emoji: fetch.call("emoji"),
        accent: fetch.call("accent"),
        preset: fetch.call("preset"),
        model: fetch.call("model"),
        system_prompt: fetch.call("system_prompt"),
        created_at: fetch.call("created_at")
      )
      persona.empty? ? nil : persona
    end

    def to_h
      {
        "slug" => @slug,
        "name" => @name,
        "emoji" => @emoji,
        "accent" => @accent,
        "preset" => @preset,
        "model" => @model,
        "system_prompt" => @system_prompt,
        "created_at" => @created_at
      }
    end

    def empty?
      [ @slug, @name, @emoji, @accent, @preset, @model, @system_prompt ]
        .all? { |value| value.nil? || value.empty? }
    end

    # What the chat header shows. Falls back to the slug so a persona without a
    # display name is never rendered as a blank row.
    def label
      @name || @slug
    end

    def emoji_or(default = "🤖")
      @emoji || default
    end

    private

    def normalize_string(value)
      return nil if value.nil?

      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
