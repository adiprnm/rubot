# frozen_string_literal: true

require_relative "persona_store"

module Rubot
  # What a delegated run is handed before it starts: which persona it answers
  # as, which model and thinking level it runs on, and where its workspace is.
  #
  # Two paths need this and must agree. The synchronous path builds the sub
  # agent inside the parent's session (see Agent#build_subagent); the
  # background path builds it in a Ractor of its own, from plain data, because
  # an object graph cannot cross that boundary. Keeping the rules here means a
  # delegated run behaves the same whichever path started it.
  module SubagentSpec
    # The persona hash a delegated run answers as, with the overrides applied.
    #
    # Per-sub-agent settings win over the built-in definition. A bare model
    # name clears the preset, because resolve_initial_preset checks `preset`
    # first and would otherwise ignore the model field. The global
    # `subagent_model` is the fallback for sub agents without their own.
    def self.persona_data(config:, persona:, slug:, model_override: nil)
      data = persona.respond_to?(:to_h) ? persona.to_h : persona.to_h.dup
      data = data.transform_keys(&:to_s)

      settings = config.respond_to?(:subagent_settings) ? config.subagent_settings(slug) : {}
      model = settings["model"].to_s.strip
      model = config.subagent_model.to_s.strip if model.empty? && config.respond_to?(:subagent_model)
      unless model.empty?
        data["model"] = model
        data["preset"] = nil
      end

      thinking = settings["thinking"].to_s.strip
      data["thinking"] = thinking unless thinking.empty?

      override = model_override.to_s.strip
      if override.empty?
        # Nothing to resolve without a name.
      elsif config.model_entry_by_name(override) || config.model_preset(override)
        data["model"] = override
        data["preset"] = nil
      end

      data
    end

    # Where the run is rooted. A persona with a workspace of its own gets a
    # config rooted there, so its SOUL.md, AGENTS.md, skills and memory are its
    # own instead of the main workspace's.
    def self.workspace_for(config:, slug:)
      PersonaStore.from_config(config, dir: File.dirname(config.personas_file)).workspace_for(slug)
    rescue StandardError
      nil
    end

    # The config a delegated run reads its workspace from, as plain data (which
    # is all a Ractor will accept).
    def self.config_data(config:, slug:)
      workspace = workspace_for(config: config, slug: slug)
      base = config.respond_to?(:with_persona_workspace) ? config : Config.from_data(config.snapshot, config_path: config.config_path)
      scoped = workspace ? base.with_persona_workspace(workspace) : base
      scoped.snapshot
    end
  end
end
