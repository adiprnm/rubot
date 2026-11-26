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
      # How many questions one turn may spend. Without a ceiling a hesitant
      # model turns the turn into an interrogation, one interruption at a time.
      PER_TURN_LIMIT = 3

      # Arguments the model got wrong. Reported as text, like every other
      # failed tool: the model can fix it, an exception cannot.
      class InvalidArguments < StandardError; end

      def name
        "ask_user"
      end

      def description
        <<~DESC.strip
          Put one question to the user and wait for the answer.

          Ask when a decision is theirs and you cannot settle it from the code,
          the files or what you already know: which of two designs to build,
          whether to overwrite something, what to call a thing. Ask instead of
          guessing when guessing wrong would cost them real work.

          Never ask what you could look up yourself. A question interrupts
          someone: read the repo, run the search, check the config first.

          Give 2 to 4 `options`, best first, each with a short `label` and one
          line of `description` saying what picking it means. Leave `options`
          out only when you genuinely cannot guess the shape of the answer; the
          user then gets a single text box.

          The answer comes back as this call's result. Three other results mean
          you did not get one: the question expired, the user cancelled the
          turn, or you have already asked #{PER_TURN_LIMIT} questions in this
          turn. In those cases decide with the safest default, say in one line
          what you assumed, and do not ask again.
        DESC
      end

      def parameters
        {
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
      end

      # No reader is wired into the tool object on purpose: the agent hands one
      # in per call, so this only fires when a turn ran without a reader.
      def execute(arguments)
        ask(arguments, reader: nil)
      end

      # The whole call: validate, ask, and describe what came back.
      #
      # `reader` is a callable that takes the question payload and returns one
      # of the outcome hashes described in #format_outcome. Nil means nobody can
      # be asked on this surface.
      def ask(arguments, reader: nil)
        payload = question_payload(arguments)
        return no_reader_text if reader.nil?

        format_outcome(reader.call(payload))
      rescue InvalidArguments => e
        "ERROR: #{e.message}"
      end

      # The question as a channel draws it, validated.
      def question_payload(arguments)
        args = arguments.is_a?(Hash) ? arguments : {}
        question = args["question"].to_s.strip
        raise InvalidArguments, "ask_user needs a `question` string." if question.empty?

        { question: question, options: options_of(args["options"]) }
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

      # The ceiling is not an error the model should retry: it is a fact about
      # how much it has already interrupted this turn.
      def limit_reached_text
        "No more questions this turn: #{PER_TURN_LIMIT} were already asked. " \
          "Decide with the safest default and say in one line what you assumed."
      end

      def no_reader_text
        "Nobody can be asked on this surface. Decide with the safest default " \
          "and say in one line what you assumed."
      end

      private

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
