# frozen_string_literal: true

require_relative "../tool"

module Rubot
  module Tools
    # One question, put to the reader, answered in the middle of the turn.
    #
    # The tool carries the shape of the question and turns the outcome into
    # words the model can read. It cannot reach a screen by itself: the reader
    # arrives as a block, handed in by whoever is running the turn (see
    # Agent::TurnLoop), because the channel that can draw a question and the
    # Ractor that runs the call are not the same place.
    #
    # A missing reader is not an error. A background turn, a sub agent that
    # should never have had the tool, a channel with nowhere to ask: all of them
    # get the same honest answer, and the model decides on its own.
    class AskUser < Tool
      MIN_OPTIONS = 2
      MAX_OPTIONS = 4
      # One call may ask a short list, asked in order and confirmed at the end:
      # a decision that needs three facts is one interruption, not three.
      MAX_QUESTIONS = 5
      # How many times the reader may send the list back for a retry before the
      # sequence gives up rather than looping forever.
      MAX_RESTARTS = 3

      # Which of the confirmation's two answers sends the list, and which sends
      # the reader back to the first question.
      SEND_INDEX = 0
      RESTART_INDEX = 1
      INTERRUPTIONS = [ :cancelled, :expired ].freeze
      ANSWER_KINDS = [ :option, :custom ].freeze
      UNREADABLE_TEXT = "The answer could not be read. Decide with the safest " \
                        "default and say in one line what you assumed."

      # An argument the model got wrong. Reported as text, like every other
      # failed tool: the model can fix it, an exception cannot.
      class InvalidArguments < StandardError; end

      def name
        "ask_user"
      end

      def description
        <<~DESC.strip
          Put one or more questions to the user and wait for the answers.

          Ask when a decision is theirs and you cannot settle it from the code,
          the files or what you already know: which of two designs to build,
          whether to overwrite something, what to call a thing. Ask instead of
          guessing when guessing wrong would cost them real work.

          Never ask what you could look up yourself. A question interrupts
          someone: read the repo, run the search, check the config first.

          Pass `questions` with up to #{MAX_QUESTIONS} entries. They are put to
          the user one at a time, each replacing the last, and then shown back to
          them for confirmation — so a decision that needs three facts is one
          interruption, not three. Each entry takes a short `question` and, when
          there are sensible candidates, #{MIN_OPTIONS} to #{MAX_OPTIONS}
          `options`, best first, each with a short `label` and one line of
          `description` saying what picking it means. Leave `options` out only
          when you cannot guess the shape of the answer; the user then types it.

          The answers come back as this call's result. If the result says the
          user cancelled the turn, or that nobody can be asked on this surface,
          decide with the safest default, say in one line what you assumed, and
          do not ask again.

          How many times a turn may ask is not capped, so the restraint is yours:
          every question costs the reader a decision. Batch what belongs
          together into one call instead of asking one thing at a time.
        DESC
      end

      def parameters
        {
          "type" => "object",
          "properties" => {
            "questions" => {
              "type" => "array",
              "description" => "1 to #{MAX_QUESTIONS} questions, asked in order and confirmed at the end.",
              "items" => {
                "type" => "object",
                "properties" => {
                  "question" => {
                    "type" => "string",
                    "description" => "The question itself: one or two sentences, no preamble."
                  },
                  "options" => {
                    "type" => "array",
                    "description" => "#{MIN_OPTIONS} to #{MAX_OPTIONS} suggested answers, best first. " \
                                     "Omit for an open question.",
                    "items" => {
                      "type" => "object",
                      "properties" => {
                        "label" => { "type" => "string", "description" => "A few words; drawn as a button." },
                        "description" => {
                          "type" => "string",
                          "description" => "One line on what this choice means for the user."
                        }
                      },
                      "required" => [ "label" ]
                    }
                  }
                },
                "required" => [ "question" ]
              }
            }
          },
          "required" => [ "questions" ]
        }
      end

      # No reader is wired into the tool object on purpose: the agent hands one
      # in per call, so this only fires when a turn ran without a reader.
      def execute(arguments)
        ask(arguments, reader: nil)
      end

      # The whole call: validate, walk the list, and describe what came back.
      #
      # `reader` is a callable that takes one question payload and returns one
      # of the outcome hashes described in #format_outcome. The sequence lives
      # here rather than in each channel: every surface already knows how to put
      # one question in front of a reader, and putting the next one where the
      # last stood is the same call again.
      def ask(arguments, reader: nil)
        list = questions_of(arguments)
        return no_reader_text if reader.nil?

        # One question is asked and answered, with nothing to read back: asking
        # the reader to confirm the single choice they just made is friction
        # with no question behind it.
        return format_outcome(reader.call(list.first)) if list.size == 1

        status, payload = run_sequence(list, reader)
        return payload if status == :stop

        format_answers(list, payload)
      rescue InvalidArguments => e
        "ERROR: #{e.message}"
      end

      # The questions this call carries, validated. `questions` is the shape the
      # tool asks for; a lone `question` is still read, so a model that learned
      # the old signature is answered rather than scolded.
      def questions_of(arguments)
        args = arguments.is_a?(Hash) ? arguments : {}
        raw = args["questions"]

        list = if raw.is_a?(Array) && !raw.empty?
          raw
        elsif args.key?("question")
          [ { "question" => args["question"], "options" => args["options"] } ]
        else
          raise InvalidArguments, "ask_user needs `questions`: at least one question to ask."
        end

        if list.size > MAX_QUESTIONS
          raise InvalidArguments,
                "ask at most #{MAX_QUESTIONS} questions in one call (got #{list.size})."
        end

        list.map { |entry| question_payload(entry) }
      end

      # One question as a channel draws it, validated.
      def question_payload(entry)
        unless entry.is_a?(Hash)
          raise InvalidArguments, "every entry in `questions` must be an object with a `question`."
        end

        question = entry["question"]
        unless question.is_a?(String)
          raise InvalidArguments, "every question needs a `question` string."
        end

        question = question.strip
        raise InvalidArguments, "every question needs a non-empty `question` string." if question.empty?

        { question: question, options: options_of(entry["options"]) }
      end

      def format_outcome(outcome)
        data = outcome.is_a?(Hash) ? outcome : {}
        case data[:outcome] || data["outcome"]
        when :option
          label = data[:label] || data["label"]
          "The user chose: #{label}"
        when :custom
          text = (data[:text] || data["text"]).to_s.strip
          "The user answered in their own words: #{text}"
        when :expired
          "The question expired before the user answered."
        when :cancelled
          "The user cancelled the turn before answering the question."
        else
          no_reader_text
        end
      end

      def no_reader_text
        "Nobody can be asked on this surface. Decide with the safest default " \
          "and say in one line what you assumed."
      end

      private

      # Q1, then Q2 in the same place, then one confirmation over the whole
      # list. Returns [:answers, answers] or [:stop, text]: a reader that goes
      # away mid-list leaves no half-answer behind, so the model is never told
      # the user answered two of three things.
      def run_sequence(list, reader)
        attempts = 0

        loop do
          answers = []
          list.each do |payload|
            outcome = reader.call(payload)
            return [ :stop, format_outcome(outcome) ] if interrupted?(outcome)
            return [ :stop, UNREADABLE_TEXT ] if unreadable?(outcome)

            answers << outcome
          end

          attempts += 1
          verdict = confirm_sequence(reader, list, answers)
          return [ :stop, format_outcome(verdict) ] if interrupted?(verdict)
          return [ :stop, UNREADABLE_TEXT ] if unreadable?(verdict)
          return [ :answers, answers ] unless restart?(verdict)
          return [ :stop, restart_exhausted_text ] if attempts >= MAX_RESTARTS
        end
      end

      # The answers read back before they are used, so a misclick is caught by
      # the person who made it rather than by the model downstream.
      def confirm_sequence(reader, list, answers)
        summary = list.each_with_index.map do |payload, index|
          "#{index + 1}. #{payload[:question]} → #{answer_text(answers[index])}"
        end.join("\n")

        reader.call(question: "#{I18n.t("ask.confirm.question")}\n\n#{summary}",
                    options: confirm_options, confirm: true)
      end

      def confirm_options
        [
          { label: I18n.t("ask.confirm.send"), description: I18n.t("ask.confirm.send_description") },
          { label: I18n.t("ask.confirm.restart"), description: I18n.t("ask.confirm.restart_description") }
        ]
      end

      def restart?(verdict)
        data = verdict.is_a?(Hash) ? verdict : {}
        return false unless (data[:outcome] || data["outcome"]) == :option

        # Index first, label as the fallback: a channel that draws options from
        # its own list may hand back words instead of a position, and a restart
        # mistaken for an answer would send the list the reader asked to redo.
        index = data[:index] || data["index"]
        return index.to_i == RESTART_INDEX unless index.nil?

        label = (data[:label] || data["label"]).to_s
        label == I18n.t("ask.confirm.restart")
      end

      # An outcome the tool does not recognise is not an answer: the model must
      # not be handed a blank line where a decision should be.
      def unreadable?(outcome)
        return true unless outcome.is_a?(Hash)

        kind = outcome[:outcome] || outcome["outcome"]
        !ANSWER_KINDS.include?(kind)
      end

      def interrupted?(outcome)
        data = outcome.is_a?(Hash) ? outcome : {}
        INTERRUPTIONS.include?(data[:outcome] || data["outcome"])
      end

      def answer_text(outcome)
        data = outcome.is_a?(Hash) ? outcome : {}
        case data[:outcome] || data["outcome"]
        when :option then (data[:label] || data["label"]).to_s
        when :custom then (data[:text] || data["text"]).to_s.strip
        else ""
        end
      end

      def format_answers(list, answers)
        lines = list.each_with_index.map do |payload, index|
          "#{index + 1}. #{payload[:question]} → #{answer_text(answers[index])}"
        end

        "The user answered:\n#{lines.join("\n")}"
      end

      def restart_exhausted_text
        "The user asked to start over #{MAX_RESTARTS} times without answering. " \
          "Decide with the safest default and say in one line what you assumed."
      end

      def options_of(raw)
        return [] if raw.nil?

        unless raw.is_a?(Array)
          raise InvalidArguments, "`options` must be a list of objects with a `label`."
        end
        return [] if raw.empty?

        if raw.size < MIN_OPTIONS || raw.size > MAX_OPTIONS
          raise InvalidArguments,
                "give #{MIN_OPTIONS} to #{MAX_OPTIONS} options (got #{raw.size}), or none at all for an open question."
        end

        raw.map { |option| option_of(option) }
      end

      def option_of(option)
        unless option.is_a?(Hash)
          raise InvalidArguments,
                "each option is an object with a `label` (and optionally a `description`), not #{option.class}."
        end

        label = option["label"].to_s.strip
        raise InvalidArguments, "every option needs a non-empty `label`." if label.empty?

        entry = { label: label }
        description = option["description"].to_s.strip
        entry[:description] = description unless description.empty?
        entry
      end
    end
  end
end
