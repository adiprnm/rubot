# frozen_string_literal: true

require "json"
require "tui"

require_relative "markdown"
require_relative "diff"

module Rubot
  class TUI
    # Rebuilds a saved session's transcript as the exact log entries the TUI
    # produced while the conversation was live: the echoed user prompt, the
    # streamed answer (Markdown), the finished tool rows, and the boundaries
    # between them. The tool-row builders are shared with the live renderer,
    # so a restored session and an active one cannot drift apart.
    class Transcript
      # An entry is { segments:, keep_leading:, indent: }.
      def self.entries(messages, width: 0)
        new(width: width).run(messages).entries
      end

      # --- row builders shared with the live TUI -------------------------

      def self.tool_call(name, summary, skill)
        if skill
          [ [ "#{Rubot::TUI::MARK[:skill]} ", :accent ], [ "skill ", :muted ], [ summary, :accent ] ]
        else
          [ [ "#{Rubot::TUI::MARK[:tool]} ", :muted ], [ name.to_s, :accent ], [ " ", :muted ], [ summary, :dim ] ]
        end
      end

      def self.tool_done(name, summary, skill = nil)
        if skill
          # Slightly brighter than a finished tool row (muted): the skill name
          # is what the reader came for, the label only marks the row.
          [ [ "#{Rubot::TUI::MARK[:ok]} ", :tool_ok ], [ "skill ", :dim ], [ summary, :dim ] ]
        else
          segments = [ [ "#{Rubot::TUI::MARK[:ok]} ", :tool_ok ], [ name.to_s, :muted ] ]
          segments += [ [ " ", :muted ], [ summary, :dim ] ] if summary && !summary.empty?
          segments
        end
      end

      def self.tool_summary(tool_name, args, max: 64)
        args = {} unless args.is_a?(Hash)
        raw = case tool_name.to_s
        when "shell_exec" then args["command"].to_s
        when "file_ops"
                "#{args["operation"]} #{args["path"]}"
        else
                args.inspect
        end
        ::TUI::Text.truncate(raw.lines.first.to_s.strip, max)
      end

      # Returns the skill name when this tool call reads a skill's SKILL.md,
      # nil otherwise. Only reads count: writing a skill file is not loading it.
      def self.skill_load(tool_name, args)
        args = {} unless args.is_a?(Hash)
        raw = nil
        case tool_name.to_s
        when "file_ops"
          raw = args["path"] if args["operation"].to_s == "read"
        when "shell_exec"
          raw = args["command"] if args["command"].to_s.match?(Rubot::TUI::READ_COMMANDS)
        end
        name = Rubot::TUI::SKILL_PATH.match(raw.to_s)&.[](1)
        name if name && !name.empty?
      end

      # Cells left for the argument preview after the marker, the tool name
      # and the separator, keeping one cell clear of the scrollbar.
      def self.summary_limit(name, width)
        width = width.to_i
        return 64 if width <= 0

        [ width - 4 - ::TUI::Text.width(name.to_s) - 2, 0 ].max
      end

      def initialize(width: 0)
        @width = width.to_i
        @entries = []
      end

      attr_reader :entries

      def run(messages)
        turn_open = false
        messages = normalize(messages)
        collect_ui_diffs(messages)

        messages.each do |msg|
          case msg["role"].to_s
          when "user"
            content = msg["content"].to_s
            next if content.strip.empty?

            blank if turn_open
            add([ [ "❯ ", :accent ], [ content, :text ] ])
            turn_open = true
          when "assistant"
            assistant(msg)
          end
        end

        blank if turn_open
        self
      end

      private

      def assistant(msg)
        content = msg["content"].to_s
        calls = Array(msg["tool_calls"])

        unless content.strip.empty?
          blank unless blank?
          add(Markdown.to_segments(content), keep_leading: true, indent: 2)
        end

        return if calls.empty?

        # Live puts one blank between the narration and the first tool row,
        # and none between back-to-back tool rows.
        blank if !content.strip.empty? && !blank?

        calls.each do |call|
          name, args = call_parts(call)
          skill = self.class.skill_load(name, args)
          summary = if skill
            ::TUI::Text.truncate(skill, self.class.summary_limit("skill", @width))
          else
            self.class.tool_summary(name, args, max: self.class.summary_limit(name, @width))
          end
          add(self.class.tool_done(name, summary, skill), keep_leading: true, indent: 2)
          add_ui_diff(@ui_diffs[call_id(call)]) if @ui_diffs
        end
      end

      # Tool messages carry the before/after of a successful write (see
      # Agent#file_ui_diff). Keyed by tool_call_id so a diff is drawn under
      # the exact row that produced it, in the same block the live TUI uses.
      def collect_ui_diffs(messages)
        @ui_diffs = {}
        messages.each do |msg|
          next unless msg["role"] == "tool" && msg["ui_diff"].is_a?(Hash)

          id = msg["tool_call_id"].to_s
          @ui_diffs[id] = msg["ui_diff"] unless id.empty?
        end
      end

      def add_ui_diff(spec)
        return unless spec && @width.positive?

        width = [ @width - 4, 20 ].max
        rows = Rubot::TUI::Diff.rows(spec["before"], spec["after"], path: spec["path"], width: width)
        rows&.each { |segments| add(segments, keep_leading: true, indent: 4) }
      end

      def call_id(call)
        return "" unless call.is_a?(Hash)

        (call["id"] || call[:id]).to_s
      end

      # Drop the instructions rubot sends itself (continuations, re-asks) and
      # join answer fragments that were streamed into one live entry.
      def normalize(messages)
        filtered = Array(messages).reject do |msg|
          msg["role"] == "user" && synthetic?(msg["content"].to_s)
        end

        filtered.each_with_object([]) do |msg, out|
          previous = out.last
          if mergeable?(msg) && previous && mergeable?(previous)
            out[-1] = previous.merge("content" => previous["content"].to_s + msg["content"].to_s)
          else
            out << msg
          end
        end
      end

      def mergeable?(msg)
        msg["role"] == "assistant" && Array(msg["tool_calls"]).empty?
      end

      def synthetic?(content)
        return false unless defined?(Rubot::Agent)

        [ Rubot::Agent::CONTINUE_PROMPT, Rubot::Agent::ANSWER_NOW_PROMPT,
          Rubot::Agent::EMPTY_ANSWER_PROMPT ].include?(content)
      end

      def call_parts(call)
        fn = call.is_a?(Hash) ? (call["function"] || call[:function]) : nil
        name = fn.is_a?(Hash) ? (fn["name"] || fn[:name]) : nil
        raw = fn.is_a?(Hash) ? (fn["arguments"] || fn[:arguments]) : nil

        args = case raw
        when Hash then raw
        when String
                 begin
                   JSON.parse(raw)
                 rescue JSON::ParserError
                   {}
                 end
        else {}
        end

        [ name.to_s, args ]
      end

      def add(segments, keep_leading: false, indent: 0)
        @entries << { segments: segments, keep_leading: keep_leading, indent: indent }
        self
      end

      def blank
        add([ [ "", nil ] ])
      end

      def blank?
        return false if @entries.empty?

        @entries.last[:segments].all? { |text, _style| text.to_s.empty? }
      end
    end
  end
end
