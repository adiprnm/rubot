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

    # Facts and preferences describe the user, so they are worth keeping in
    # every project; context describes the project being worked on and would be
    # noise anywhere else.
    #
    # That rule of thumb is only a fallback. The scope that decides where a
    # fact is written is asked of the extractor per item: "user is 183 cm tall"
    # is global even though it is a fact, and "the client prefers carousels
    # over reels" is a preference that only the Kanyaah persona should carry.
    # An item the extractor did not label, or labelled ambiguously, stays
    # local — a wrong guess then costs one persona's memory instead of
    # everyone's.

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

      Every item also carries a scope, and the scope is what decides which
      memory file it is written to:

      - "global" — true no matter which persona or project the user is talking
        to: who they are, where they live, how they want the assistant to
        behave, how tall they are, what language they speak.
      - "persona" — true only of the job being done here: this client's
        preferences, this brand's tone, this codebase's conventions, this
        training plan's target. A different persona must not inherit it.

      When you are not sure, use "persona". A fact wrongly kept local costs
      one persona some context; a fact wrongly made global follows the user
      into every conversation.

      Return a JSON object with these keys (each is an array of objects, or
      empty):
      {
        "facts": [{"fact": "...", "scope": "global"}],
        "preferences": [{"fact": "...", "scope": "persona"}],
        "context": [{"fact": "...", "scope": "persona"}]
      }

      Always write extracted facts in English, regardless of the
      input language.

      If nothing is worth remembering, return all empty arrays.
      Be conservative — only extract when confident it's valuable.
    PROMPT

    attr_reader :provider, :memory, :last_usage

    def initialize(provider:, memory:)
      @provider = provider
      @memory = memory
      @last_usage = nil
    end

    # Extract memory from one user message or a batch of them (an Array is
    # joined into a single request, which is what keeps extraction from
    # costing one provider call per message). Returns the items that were
    # actually stored (after deduplication), or empty array if nothing.
    #
    # `provider:` names the model for this request. The extractor is shared by
    # every session of a channel, so the provider cannot be decided once in
    # the constructor: a caller with an auxiliary model passes it per call, and
    # the one it was built with serves the rest.
    def extract(input, provider: nil)
      @last_usage = nil
      messages = Array(input).map { |m| m.to_s.strip }.reject(&:empty?)
      messages = messages.reject { |m| skip_message?(m) }
      return [] if messages.empty?

      items = call_extractor(messages, provider || @provider)
      return [] if items.values.all?(&:empty?)

      stored = []
      items.each do |section, facts|
        next if facts.empty?
        # Capitalize section name to match MEMORY.md conventions
        section_name = section.capitalize
        facts.each do |entry|
          fact, scope = normalize_item(entry)
          next if fact.nil? || fact.empty?

          next if duplicate?(section_name, fact, scope)
          @memory.append(section_name, fact, scope: scope)
          stored << { section: section_name, fact: fact, scope: scope }
        end
      end
      stored
    end

    private

    # One extracted item as [fact, scope]. The extractor is asked for objects
    # ("fact" + "scope"), but a plain string is still accepted — an older or
    # lazier reply then lands in the local layer instead of being dropped.
    def normalize_item(entry)
      fact = nil
      scope = nil

      case entry
      when Hash
        fact = entry["fact"] || entry["content"] || entry["text"]
        scope = entry["scope"] || entry["layer"]
      when String
        fact = entry
      end

      fact = fact.to_s.strip
      return [ nil, nil ] if fact.empty?

      # Only an explicit "global" leaves the local layer: "persona",
      # "workspace", a missing scope and anything unrecognised all stay home.
      label = scope.to_s.strip.downcase
      layer = label == MemoryBank::SCOPE_GLOBAL ? MemoryBank::SCOPE_GLOBAL : MemoryBank::SCOPE_WORKSPACE
      [ fact, layer ]
    end

    # Check if a message should be skipped (too short, trivial, etc.)
    def skip_message?(message)
      return true if message.nil?
      msg = message.strip
      return true if msg.length < MIN_MESSAGE_LENGTH
      TRIVIAL_PATTERNS.any? { |p| msg =~ p }
    end

    # Call the LLM to extract facts from the message(s)
    def call_extractor(batch, provider = @provider)
      messages = [
        { "role" => "system", "content" => EXTRACTION_SYSTEM_PROMPT },
        { "role" => "user", "content" => extraction_request(batch) }
      ]

      result = provider.chat(messages, tools: nil)
      @last_usage = provider.last_usage if provider.respond_to?(:last_usage)

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

    def extraction_request(batch)
      list = Array(batch)
      return "Extract memory from this message:\n\n#{list.first}" if list.size == 1

      joined = list.each_with_index.map { |message, i| "#{i + 1}. #{message}" }.join("\n\n")
      "Extract memory from these user messages (oldest first):\n\n#{joined}"
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

    # Check if a fact is already in the layer it would be written to. Checking
    # only that layer keeps a global fact from being copied into every persona
    # that happens to hear it again.
    def duplicate?(section, fact, scope = MemoryBank::SCOPE_WORKSPACE)
      return false unless @memory.enabled?

      content = if @memory.respond_to?(:layer_content)
        @memory.layer_content(scope)
      else
        @memory.read
      end
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
