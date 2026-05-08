# frozen_string_literal: true

require "json"

module Rubot
  # Extracts facts, preferences, and context from user messages
  # using a focused LLM call. Results are appended to MEMORY.md.
  #
  # Designed to be cheap and selective — short or trivial messages
  # are skipped entirely. Extracted items are deduplicated against
  # existing memory content.
  class MemoryExtractor
    # Messages shorter than this are considered trivial (skip extraction)
    MIN_MESSAGE_LENGTH = 15

    # Skip messages that are just acknowledgments or single words
    TRIVIAL_PATTERNS = [
      /\A\s*(yes|no|yeah|nah|ok|okay|sure|thanks|thank you|cool|nice|great|awesome|got it|right|wrong|nope|maybe|i see|hmm|wow)\s*\z/i,
      /\A\s*\d+\s*\z/,                                          # just a number
      /\A\s*[!?.,;:]+\s*\z/,                                    # just punctuation
      # Indonesian acknowledgments
      /\A\s*(iya|oh|wah|waduh|sip|oke|okeh|siap|mantap|keren|makasih|terima kasih|tidak|nggak|enggak|bisa|tidak bisa|ngerti|paham|tidak paham)\s*\z/i,
    ].freeze

    # System prompt for extraction — returns structured JSON.
    # Supports English and Bahasa Indonesia.
    EXTRACTION_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a memory extraction assistant. Your job is to identify
      important facts, preferences, and context from a user message that
      should be stored in long-term memory.

      The user may write in English or Bahasa Indonesia. Detect the
      language automatically and extract accordingly.

      Extract ONLY information that is:
      - About the user (their preferences, background, location, etc.)
      - About their projects or work
      - Technical details that will be useful later (languages, frameworks, tools)
      - Explicit instructions about how the assistant should behave

      Do NOT extract:
      - Temporary or one-off requests
      - Information already commonly known
      - Questions the user is asking
      - Ephemeral context (what they're doing right now unless it reveals a preference)

      Examples:
      - "Saya tinggal di Jakarta" → facts: ["User lives in Jakarta"]
      - "Saya lebih suka pakai bahasa Indonesia" → preferences: ["User prefers Bahasa Indonesia"]
      - "I work on a Ruby project" → context: ["User works on a Ruby project"]

      Return a JSON object with these keys (each is an array of strings, or empty):
      {
        "facts": [],
        "preferences": [],
        "context": []
      }

      Always write extracted facts in English, regardless of the
      input language.

      If nothing is worth remembering, return all empty arrays.
      Be conservative — only extract when confident it's valuable.
    PROMPT

    attr_reader :provider, :memory

    def initialize(provider:, memory:)
      @provider = provider
      @memory = memory
    end

    # Extract memory from a user message. Returns the items that were
    # actually stored (after deduplication), or empty array if nothing.
    def extract(message)
      return [] if skip_message?(message)

      items = call_extractor(message)
      return [] if items.values.all?(&:empty?)

      stored = []
      items.each do |section, facts|
        next if facts.empty?
        # Capitalize section name to match MEMORY.md conventions
        section_name = section.capitalize
        facts.each do |fact|
          next if duplicate?(section_name, fact)
          @memory.append(section_name, fact)
          stored << { section: section_name, fact: fact }
        end
      end
      stored
    end

    private

    # Check if a message should be skipped (too short, trivial, etc.)
    def skip_message?(message)
      return true if message.nil?
      msg = message.strip
      return true if msg.length < MIN_MESSAGE_LENGTH
      TRIVIAL_PATTERNS.any? { |p| msg =~ p }
    end

    # Call the LLM to extract facts from the message
    def call_extractor(message)
      messages = [
        { "role" => "system", "content" => EXTRACTION_SYSTEM_PROMPT },
        { "role" => "user", "content" => "Extract memory from this message:\n\n#{message}" }
      ]

      result = @provider.chat(messages, tools: nil)

      # Parse the response as JSON
      content = if result.is_a?(Hash)
        result["content"] || result.to_s
      else
        result.to_s
      end

      # Try to find JSON in the response
      json_str = extract_json(content)
      return { "facts" => [], "preferences" => [], "context" => [] } if json_str.nil?

      parsed = JSON.parse(json_str)
      {
        "facts" => parsed["facts"] || [],
        "preferences" => parsed["preferences"] || [],
        "context" => parsed["context"] || []
      }
    rescue JSON::ParserError, StandardError => e
      warn "[memory_extractor] Extraction failed: #{e.class}: #{e.message}" if Rubot.debug?
      { "facts" => [], "preferences" => [], "context" => [] }
    end

    # Extract a JSON object from a potentially noisy response
    def extract_json(text)
      # Try parsing the whole thing first
      return text if valid_json_object?(text.strip)

      # Try to find a JSON object in the text
      start_idx = text.index("{")
      return nil unless start_idx

      # Find the matching closing brace (simple brace counting)
      depth = 0
      in_string = false
      escape_next = false

      (start_idx...text.length).each do |i|
        char = text[i]
        if escape_next
          escape_next = false
          next
        end
        if char == "\\"
          escape_next = true
          next
        end
        if char == '"'
          in_string = !in_string
          next
        end
        next if in_string
        depth += 1 if char == "{"
        depth -= 1 if char == "}"
        if depth == 0
          candidate = text[start_idx..i]
          return candidate if valid_json_object?(candidate)
        end
      end
      nil
    end

    def valid_json_object?(text)
      parsed = JSON.parse(text)
      parsed.is_a?(Hash)
    rescue JSON::ParserError
      false
    end

    # Check if a fact is already in memory (deduplication)
    def duplicate?(section, fact)
      return false unless @memory.enabled?
      content = @memory.read
      return false if content.nil? || content.empty?

      # Check for exact match or close similarity
      normalized_fact = normalize(fact)
      content.lines.any? do |line|
        line.strip.start_with?("- ") && normalize(line.sub(/\A- /, "")) == normalized_fact
      end
    end

    def normalize(text)
      text.strip.downcase.gsub(/\s+/, " ").gsub(/[.!?]+$/, "")
    end
  end
end
