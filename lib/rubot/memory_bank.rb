# frozen_string_literal: true

require_relative "memory"

module Rubot
  # Two layers of long-term memory:
  #
  #   global     ~/.rubot/MEMORY.md        facts about the user and the bot
  #                                        that hold in every project
  #   second     ~/.rubot/memory/<slug>.md what this project is about
  #              or <persona>/MEMORY.md    what this persona is about
  #
  # Both are injected into the system prompt as one merged document, section
  # by section, so a split memory still costs what a single file did. Writes
  # are always aimed at one layer (the second one by default).
  #
  # The second layer used to be the workspace's alone, keyed by the absolute
  # path of the workspace and stored next to `sessions/` rather than inside
  # the project, so opening a repository would not leave a MEMORY.md in its
  # git status. A persona now keeps its own file inside its own directory
  # (`<persona>/MEMORY.md`): there is nothing to pollute, and everything that
  # specialist is — its soul, its memory, its files — sits in one folder.
  class MemoryBank
    SCOPE_GLOBAL = "global"
    SCOPE_WORKSPACE = "workspace"
    SCOPE_PERSONA = "persona"

    attr_reader :global, :workspace, :workspace_label

    # `workspace_label` is what the model is told the second layer is called:
    # "persona" for a specialist, "workspace" for a project directory.
    def self.build(global_path:, workspace_path:, workspace_label: SCOPE_WORKSPACE)
      return nil if global_path.nil? && workspace_path.nil?

      new(global_path: global_path, workspace_path: workspace_path, workspace_label: workspace_label)
    end

    def initialize(global_path: nil, workspace_path: nil, workspace_label: SCOPE_WORKSPACE)
      label = workspace_label.to_s.strip.downcase
      @workspace_label = label.empty? ? SCOPE_WORKSPACE : label
      # The global file is created on first use (it is the one the bot has
      # always had); a workspace file only appears once something is written.
      @global = Memory.new(path: global_path, create: !global_path.nil?)
      @workspace = Memory.new(path: workspace_path, create: false)
    end

    # The per-file preamble of the merged document. The file-level boilerplate
    # is written twice otherwise, once per layer, so it lives here instead.
    def preamble
      <<~TEXT
        _This file is automatically managed by Rubot. Global entries apply in every
        workspace; #{@workspace_label} entries apply only to the #{@workspace_label} they were learned in._
      TEXT
    end

    def global_path
      @global.file_path
    end

    def workspace_path
      @workspace.file_path
    end

    # The merged document is what gets injected into the prompt.
    def to_s
      read
    end

    def enabled?
      @global.enabled? || @workspace.enabled?
    end

    # Merged view: the union of both files' sections, global bullets first.
    # Identical bullets are shown once, since the same fact can be learned in
    # both layers.
    def read
      sections, order = parse(@global.read)
      ws_sections, ws_order = parse(@workspace.read)

      ws_order.each { |name| order << name unless order.include?(name) }
      ws_sections.each do |name, bullets|
        (sections[name] ||= []).concat(bullets)
      end

      body = order.map do |name|
        bullets = dedupe(sections[name] || [])
        next "" if bullets.empty?

        "## #{name}\n\n#{bullets.map { |b| "- #{b}" }.join("\n")}\n"
      end.reject(&:empty?)

      return "" if body.empty?

      "# Memory\n\n#{preamble}\n#{body.join("\n")}"
    end

    # Bullets of one section, tagged with the layer they came from.
    def read_section(section)
      {
        SCOPE_GLOBAL => bullets_of(@global.read, section),
        SCOPE_WORKSPACE => bullets_of(@workspace.read, section)
      }
    end

    def append(section, line, scope: SCOPE_WORKSPACE, max_items: nil)
      layer(scope).append(section, line, max_items: max_items)
    end

    # One layer's own content. What a write needs to deduplicate against: a
    # fact already in the global file must not be copied into every persona
    # that hears it again.
    def layer_content(scope)
      layer(scope).read.to_s
    end

    def update_section(section, items, scope: SCOPE_WORKSPACE)
      layer(scope).update_section(section, items)
    end

    # Consolidate both layers; nil when neither changed.
    def consolidate!(limits: Memory::SECTION_LIMITS)
      results = [ @global.consolidate!(limits: limits), @workspace.consolidate!(limits: limits) ].compact
      return nil if results.empty?

      {
        removed: results.sum { |r| r[:removed].to_i },
        size: results.sum { |r| r[:size].to_i }
      }
    end

    private

    def layer(scope)
      scope.to_s.downcase == SCOPE_GLOBAL ? @global : @workspace
    end

    # Splits a memory file into { section => [bullets] } plus the section order
    # it was written in. Everything before the first "## " is the file's own
    # preamble and is dropped.
    def parse(content)
      sections = {}
      order = []
      return [ sections, order ] if content.nil? || content.empty?

      current = nil
      content.each_line do |line|
        if line.start_with?("## ")
          current = line.sub(/\A##\s+/, "").strip
          order << current unless order.include?(current)
          sections[current] ||= []
        elsif current && line.start_with?("- ")
          sections[current] << line.sub(/\A-\s+/, "").strip
        end
      end
      [ sections, order ]
    end

    def bullets_of(content, section)
      parse(content).first[section] || []
    end

    def dedupe(bullets)
      seen = {}
      bullets.each_with_object([]) do |bullet, out|
        key = bullet.downcase.gsub(/\s+/, " ").strip
        next if seen[key]

        seen[key] = true
        out << bullet
      end
    end
  end
end
