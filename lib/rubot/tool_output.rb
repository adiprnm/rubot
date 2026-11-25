# frozen_string_literal: true

module Rubot
  # A tool's answer, as it enters the transcript.
  #
  # A request re-sends the whole conversation, so one tool result that never
  # stops being sent is a cost paid on every round that follows it: a `grep`
  # over a large tree, a `read` of a whole file, a command that printed a
  # build log. None of that is read again by the model either -- the head says
  # what was found and the tail says how it ended, and the middle is the part
  # nobody asks a second question about.
  #
  # The clip happens once, when the result is written down, and never again:
  # the same text is what every later round re-sends, so the prefix the provider
  # caches stays byte-identical (see test/test_tool_output.rb). Clipping at
  # request time would do the opposite -- the transcript would be rewritten
  # under the cache on every round.
  module ToolOutput
    # What one tool result may weigh in the transcript, in characters, when the
    # caller names no ceiling of its own. The default lives in Config
    # (`agents.defaults.tool_output_max_chars`): a workspace of large files
    # wants a wider head than one that only runs commands.
    MAX_CHARS = Config::DEFAULT_TOOL_OUTPUT_MAX_CHARS
    # Where the cut falls: most of the budget to the head, because the beginning
    # of an output is where a search result, a file's structure and a command's
    # first error live. The tail keeps the last lines, where a failure usually
    # says what went wrong.
    HEAD_SHARE = 0.7
    # How the cut is described in the middle. It names the count, because a
    # reader (and the model) should know how much is missing, and it is plain
    # text so a provider sees it as content rather than a marker to interpret.
    NOTE = "[... %<removed>d characters of this tool result were left out to keep the transcript small ...]"
    # The room the note itself may take, so the number in it is known before the
    # two ends are measured. Wider than the note at any count this file produces,
    # which is what keeps the whole thing strictly under MAX_CHARS.
    NOTE_RESERVE = 160

    module_function

    # The text as the transcript will hold it: unchanged when it already fits,
    # otherwise head, the note and tail, all inside the ceiling. `max_chars` is
    # the configured budget; a caller that names none gets the default.
    def clip(text, max_chars: MAX_CHARS)
      text = text.to_s
      max_chars = max_chars.to_i
      max_chars = MAX_CHARS unless max_chars.positive?
      return text if text.length <= max_chars

      # The two ends share what the note leaves, and the note counts what they
      # did not keep: the result is strictly shorter than the cap, never at it.
      # A ceiling smaller than the note itself has no room to share, so the note
      # wins and the ends get one character each.
      room = [ max_chars - NOTE_RESERVE - 3, 1 ].max
      head = (room * HEAD_SHARE).to_i
      tail = room - head
      note = format(NOTE, removed: text.length - room)

      "#{text[0, head]}\n#{note}\n#{text[-tail, tail]}"
    end
  end
end
