# frozen_string_literal: true

require "json"
require "tui"

require_relative "../formatting"
require_relative "../i18n"
require_relative "../skill_load"
require_relative "../tool_caption"
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

      # The row is the sentence and the mark, nothing else: the tool's own name
      # (`file_ops`, `shell_exec`) is the agent's vocabulary, not the reader's,
      # and the sentence already says what it did. `name` stays in the
      # signature because the live renderer keys a running row by it.
      def self.tool_call(name, summary, skill)
        if skill
          [ [ "#{Rubot::TUI::MARK[:skill]} ", :accent ],
            [ "#{I18n.t("tool.skill.label")} ", :muted ], [ summary, :accent ] ]
        else
          [ [ "#{Rubot::TUI::MARK[:tool]} ", :muted ], [ summary, :text ] ]
        end
      end

      # A finished tool row. The marker stays ✓ when the call succeeded and
      # flips to ✗ when it did not (see .failure?), so a broken call is
      # visible without opening the transcript body.
      def self.tool_done(name, summary, skill = nil, failed: false)
        mark = failed ? Rubot::TUI::MARK[:err] : Rubot::TUI::MARK[:ok]
        style = failed ? :error : :tool_ok
        if skill
          # Slightly brighter than a finished tool row (muted): the skill name
          # is what the reader came for, the label only marks the row.
          [ [ "#{mark} ", style ], [ "#{I18n.t("tool.skill.label")} ", :dim ], [ summary, :dim ] ]
        else
          segments = [ [ "#{mark} ", style ] ]
          segments += [ [ summary, :dim ] ] if summary && !summary.empty?
          segments
        end
      end

      # The duration label lives in Rubot::Formatting so every channel reads the
      # same; this name stays because the TUI calls it.
      def self.elapsed_label(seconds)
        Rubot::Formatting.duration(seconds)
      end

      # The duration as a right-pinned tail (see LogView#add_entry). It reads
      # as a footnote to the row: dimmer than the summary, and pinned to the
      # end so a long call summary cannot push it out of view.
      def self.elapsed_tail(seconds)
        [ [ "· #{elapsed_label(seconds)}", :dim ] ]
      end

      # Shell results carry their status in a leading "[Exit code: N]" line,
      # every other tool reports a failure as a string starting with "ERROR:".
      EXIT_CODE = /\A\[Exit code: (-?\d+)\]/

      def self.failure?(result)
        text = result.to_s
        return true if text.start_with?("ERROR:")
        return false unless (match = EXIT_CODE.match(text))

        match[1].to_i != 0
      end

      # What the call is doing, in words: the same phrase the web timeline and
      # the Telegram card draw (see Rubot::ToolCaption), cut to the cells this
      # row has left rather than to a width of its own.
      def self.tool_summary(tool_name, args, max: 64)
        ::TUI::Text.truncate(Rubot::ToolCaption.caption(tool_name, args), max)
      end

      # The skills this tool call loaded, as the row reads them ("brain",
      # "brain dan grill"), or nil when it loaded none. The word in front of
      # them belongs to the dictionary (see .tool_call), so what is built here
      # is only the list.
      def self.skill_load(tool_name, args)
        names = Rubot::SkillLoad.names(tool_name, args)
        names.empty? ? nil : Rubot::ToolCaption.skill_list(names)
      end

      # Cells left for the sentence after the marker and the indent, keeping one
      # cell clear of the scrollbar. The tool's name is no longer drawn on the
      # row (see .tool_call), so its width is no longer taken out here; `name`
      # stays in the signature because both callers already have it.
      def self.summary_limit(_name, width)
        width = width.to_i
        return 64 if width <= 0

        [ width - 5, 0 ].max
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
        collect_tool_results(messages)

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
          add(self.class.tool_done(name, summary, skill, failed: self.class.failure?(@tool_results[call_id(call)])),
              keep_leading: true, indent: 2, nowrap: true)
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

      # Tool results are separate messages; keying them by tool_call_id lets
      # the row above know whether that exact call failed.
      def collect_tool_results(messages)
        @tool_results = {}
        messages.each do |msg|
          next unless msg["role"] == "tool"

          id = msg["tool_call_id"].to_s
          @tool_results[id] = msg["content"] unless id.empty?
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

      def add(segments, keep_leading: false, indent: 0, nowrap: false)
        @entries << { segments: segments, keep_leading: keep_leading, indent: indent, nowrap: nowrap }
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
