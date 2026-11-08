# frozen_string_literal: true

require_relative "../tool"

module Rubot
  module Tools
    # Detects when a user corrects the bot and stores the correction
    # in memory so the bot avoids repeating the same mistake.
    #
    # This is pattern-based — no LLM call needed.
    class FeedbackLearner < Tool
      # Patterns that indicate a correction or negative feedback
      CORRECTION_PATTERNS = [
        # English
        /\A\s*(no[,!.\s]|nope|wrong|incorrect|not quite|not exactly|that'?s wrong|that'?s not|that'?s incorrect)/i,
        /\A\s*(i meant|i said|as i said|as i mentioned|like i said|like i mentioned)/i,
        /\A\s*(actually|no actually|wait no|hold on|wait,? no)/i,
        /\A\s*(do(n't| not) (do that|say that|use that|use|run|execute))/i,
        /\A\s*(that'?s not what|that'?s not right|that'?s not correct|that'?s not helpful)/i,
        /\A\s*(you (forgot|missed|overlooked|ignored))/i,
        /\A\s*(I told you|I already said|I already told you)/i,
        # Bahasa Indonesia
        /\A\s*(bukan|bukan begitu|bukan itu|bukan itu maksud|bukan seperti itu|bukan yang itu)/i,
        /\A\s*(salah|salah itu|jawabannya salah|itu salah|kurang tepat|tidak tepat)/i,
        /\A\s*(maksud saya|maksud gue|yang saya maksud|bukan itu yang saya maksud)/i,
        /\A\s*(sebenarnya|tapi sebenarnya|tapi sebenarnya bukan|seharusnya)/i,
        /\A\s*(jangan|jangan begitu|jangan lakukan)/i,
        /\A\s*(udah saya bilang|sudah saya bilang|udah saya katakan|sudah saya katakan|udah saya kasih tahu|sudah saya kasih tahu)/i,
        /\A\s*(kamu lupa|kamu salah|kau lupa|kau salah|lo salah|elo salah)/i,
        /\A\s*(tidak|nggak|enggak|gak|gk)[,!.\s]+(bukan|salah|tepat|benar|begitu|itu)/i,
      ].freeze

      # Messages that are too short to be meaningful corrections
      MIN_CORRECTION_LENGTH = 3

      # The log is injected into every prompt, so it is kept short. Older
      # corrections are dropped (and archived) once this many exist.
      MAX_CORRECTIONS = 10

      attr_reader :memory

      def initialize(memory:)
        @memory = memory
      end

      def name
        "feedback_learner"
      end

      def description
        <<~DESC.strip
          Internal tool — not exposed to the LLM.
          Learns from user corrections to avoid repeating mistakes.
        DESC
      end

      def parameters
        { "type" => "object", "properties" => {} }
      end

      # Check if a user message is a correction and, if so,
      # store the previous interaction as a learned correction.
      #
      # @param user_message [String] The current user message
      # @param previous_turns [Array] The last assistant response + user messages
      # @return [Boolean] True if a correction was stored
      def process(user_message, previous_turns)
        return false if user_message.nil? || user_message.strip.length < MIN_CORRECTION_LENGTH
        return false unless correction?(user_message)

        # Extract the last assistant response and what the user originally asked
        assistant_response = find_last_assistant_response(previous_turns)
        user_request = find_last_user_request(previous_turns)

        return false if assistant_response.nil? || user_request.nil?

        store_correction(user_request.strip, assistant_response.strip, user_message.strip)
      end

      # Generate the corrections section for the system prompt
      def to_system_prompt
        return "" unless @memory&.enabled?
        content = @memory.read
        return "" if content.nil? || content.empty?

        section = extract_corrections_section(content)
        return "" if section.nil? || section.strip.empty?

        "## Learned Corrections\n\n#{section}\n\nWhen you encounter a similar situation, follow the correction and avoid the mistake."
      end

      def execute(_arguments)
        "Internal tool — not callable by the LLM"
      end

      private

      # Check if a message matches correction patterns
      def correction?(message)
        CORRECTION_PATTERNS.any? { |p| message =~ p }
      end

      # Find the last assistant message in the previous turns
      def find_last_assistant_response(turns)
        turns.reverse_each do |turn|
          return turn["content"] if turn["role"] == "assistant" && turn["content"] && !turn["content"].empty?
        end
        nil
      end

      # Find the last user message (the original request) in previous turns
      def find_last_user_request(turns)
        turns.reverse_each do |turn|
          return turn["content"] if turn["role"] == "user" && turn["content"] && !turn["content"].empty?
        end
        nil
      end

      # Store a correction in memory
      def store_correction(original_request, bot_response, user_correction)
        return false unless @memory&.enabled?

        # Truncate if too long
        original_request = original_request[0..200] + "..." if original_request.length > 200
        bot_response = bot_response[0..200] + "..." if bot_response.length > 200
        user_correction = user_correction[0..200] + "..." if user_correction.length > 200

        correction_line = "User asked: '#{original_request}' → Bot response was wrong/inadequate. User feedback: '#{user_correction}'"
        return false if duplicate_correction?(user_correction)

        # Corrections are about how the bot should behave, which does not
        # depend on the project, so they go to the global layer.
        @memory.append("Learned Corrections", correction_line, max_items: MAX_CORRECTIONS, scope: "global")
        true
      rescue StandardError => e
        warn "[feedback_learner] Failed to store correction: #{e.class}: #{e.message}" if Rubot.debug?
        false
      end

      # A correction the user already gave teaches nothing new.
      def duplicate_correction?(user_correction)
        content = @memory.read
        return false if content.nil? || content.empty?

        needle = normalize_for_comparison(user_correction)
        return false if needle.empty?

        extract_corrections_section(content).to_s.lines.any? do |line|
          normalize_for_comparison(line).include?(needle)
        end
      end

      def normalize_for_comparison(text)
        text.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").gsub(/\s+/, " ").strip
      end

      # Extract the "Learned Corrections" section from memory content
      def extract_corrections_section(content)
        lines = content.lines
        header_idx = lines.index { |l| l.strip == "## Learned Corrections" }
        return nil unless header_idx

        # Find the end of the section
        next_section = lines[(header_idx + 1)..]&.index { |l| l.start_with?("##") }
        end_idx = next_section ? (header_idx + 1 + next_section) : lines.length

        lines[(header_idx + 1)...end_idx].join.strip
      end
    end
  end
end
