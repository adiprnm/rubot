# frozen_string_literal: true

module Rubot
  # Names a conversation from the prompt that opened it.
  #
  # A session file holds a transcript; it does not hold a name. The first
  # prompt is the closest thing to one, but it is written for the agent, not
  # for a list a person scans — "tolong cek dulu kenapa build-nya gagal di CI
  # tapi lokal aman ya met" is a sentence, not a name. Asking the model for a
  # short title turns it into one.
  #
  # The call is small and one-shot per session (see Agent#run_session_naming),
  # and its tokens are recorded as auxiliary usage so naming never distorts the
  # context figure the status row shows.
  class SessionNamer
    # Room for a title that says something, less than the sidebar row can show
    # without being cut.
    MAX_TITLE_CHARS = 60

    # Same language as the prompt, no decoration, no preamble. Everything the
    # model is allowed to write is described here, because the answer is used
    # verbatim as a label.
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You name conversations. Given the first message of a chat between a user
      and their assistant, reply with a short title for that conversation.

      Rules:
      - 2 to 5 words, at most #{MAX_TITLE_CHARS} characters.
      - Write the title in the same language as the user's message.
      - Describe what the conversation is about, not what the user asked to do.
      - No quotes, no trailing period, no markdown, no "Title:" prefix.
      - No emoji or decoration.
      - If the message is a greeting or has no topic, name the greeting in two
        words instead of inventing one (for example: "Sapaan awal").

      Reply with the title only.
    PROMPT

    attr_reader :provider, :last_usage

    def initialize(provider:)
      @provider = provider
      @last_usage = nil
    end

    # The title for a conversation that started with `prompt`, or nil when the
    # model could not produce a usable one. Callers keep their own fallback:
    # naming is a nicety, never a reason for a turn to fail.
    def name(prompt, reply: nil)
      @last_usage = nil
      text = prompt.to_s.strip
      return nil if text.empty?

      result = @provider.chat(request_messages(text, reply), tools: nil)
      @last_usage = @provider.last_usage if @provider.respond_to?(:last_usage)

      clean(result_content(result))
    rescue StandardError => e
      warn "[session_namer] naming failed: #{e.class}: #{e.message}" if Rubot.debug?
      nil
    end

    private

    def request_messages(text, reply)
      content = "First message:\n#{text}"
      # The answer says what the conversation actually turned into, which is
      # often clearer than the request. Optional: a session can be named before
      # any answer exists.
      answer = reply.to_s.strip
      content += "\n\nAssistant's first answer (truncated):\n#{Session.snippet(answer, 400)}" unless answer.empty?

      [
        { "role" => "system", "content" => SYSTEM_PROMPT },
        { "role" => "user", "content" => content }
      ]
    end

    def result_content(result)
      return result["content"].to_s if result.is_a?(Hash)

      result.to_s
    end

    # Models like to decorate: quotes, a "Title:" label, a trailing period, or
    # a stray line of explanation. Keep only the first non-empty line and strip
    # the wrapper characters that would look wrong in a list.
    def clean(raw)
      line = raw.to_s.lines.map(&:strip).find { |l| !l.empty? }
      return nil if line.nil?

      line = line.sub(/\A(?:title|judul)\s*:\s*/i, "")
      line = line.delete_prefix("**").delete_suffix("**")
      line = line.gsub(/\A["'“”‘’]+|["'“”‘’]+\z/, "")
      line = line.delete_suffix(".").strip

      return nil if line.empty?

      # A model that ignored the instruction and wrote a paragraph is cut here
      # rather than left to break the sidebar row.
      line = line[0, MAX_TITLE_CHARS].strip if line.length > MAX_TITLE_CHARS
      line
    end
  end
end
