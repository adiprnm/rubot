# frozen_string_literal: true

module Rubot
  # Whether a tool call is loading a skill, and which ones.
  #
  # A skill never arrives through a tool of its own: the model picks one up by
  # reading its SKILL.md through `file_read`, or by catting it in a shell,
  # because that is what the system prompt tells it to do (see
  # SkillRegistry#to_system_prompt). Read that way a skill load looks like any
  # other file read, which is why every surface asks this module before it
  # writes a row: a call that picked up instructions is worth saying out loud,
  # and it should be said the same way in the TUI, the web timeline, the
  # replayed transcript and the Telegram card.
  #
  # Only reads count. Writing or editing a SKILL.md is the agent authoring a
  # skill, not loading one, and a row that claimed otherwise would be a lie.
  module SkillLoad
    # The tail every skill file has: <skills dir>/<name>/SKILL.md. What comes
    # before it differs per install (~/.rubot/skills, ~/.rubot/workspace/skills,
    # a project's own), so only the tail is matched and the name is taken from
    # the directory the file sits in. `SKILL.md.bak` is a backup, not a skill,
    # which is what the lookahead rules out.
    PATH = %r{/skills/([^/\s]+)/SKILL\.md(?![\w.-])}

    # Shell commands that only dump a file's contents: `cat brain/SKILL.md`
    # loads a skill the same way the file tool's read does.
    READ_COMMANDS = /\b(cat|bat|less|more|head|tail)\b/

    # The names this call loaded, in the order the call asked for them, without
    # repeats. Empty when the call loaded none.
    def self.names(tool_name, args)
      read_arguments(tool_name.to_s, args).filter_map do |raw|
        PATH.match(raw.to_s)&.[](1)
      end.uniq
    end

    # What the call asked to read: one path, several, or the whole shell line,
    # which is searched for a skill path as it stands. A write, a listing and a
    # tool that takes no path all come back empty. The decision is about the
    # operation, not the tool name, so a reading tool added later is covered
    # without touching this module.
    def self.read_arguments(tool_name, args)
      args = {} unless args.is_a?(Hash)
      return [] unless read_operation?(tool_name, args)

      case tool_name
      when "file_read", "file_write"
        read_paths(args)
      when "shell_exec"
        command = args["command"].to_s
        command.match?(READ_COMMANDS) ? [ command ] : []
      else
        []
      end
    end

    # `paths` wins over `path`, which the file tool ignores once the list is
    # there: naming a skill from the ignored argument would say a skill was
    # loaded that the call never opened.
    def self.read_paths(args)
      paths = Array(args["paths"]).map(&:to_s).reject(&:empty?)
      return paths unless paths.empty?

      [ args["path"].to_s ].reject(&:empty?)
    end

    # A reading tool reads when told nothing (file_read defaults to read); the
    # writing tool has no such default, so a call to it that names no operation
    # is not a load.
    def self.read_operation?(tool_name, args)
      operation = args["operation"].to_s
      return true if operation == "read"

      operation.empty? && tool_name.to_s != "file_write"
    end
  end
end
