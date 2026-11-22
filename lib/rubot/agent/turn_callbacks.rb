# frozen_string_literal: true

module Rubot
  class Agent
    # Everything a turn reports back to the channel that started it.
    #
    # #process is handed these as keywords, fifteen of them, and it used to pass
    # the ones it needed down to each phase as fifteen keywords again. One object
    # built at the top of the turn is the same information in one argument, so a
    # phase names the callbacks it actually uses and the rest travel with it.
    #
    # Readers, not shorthand methods: the call sites already say what they are
    # doing (`callbacks.usage&.call(live: live)`), and a wrapper method per
    # callback would only move the nil check one level away from the reader.
    class TurnCallbacks
      attr_reader :tool_call, :tool_result, :progress, :confirm, :assistant_text,
                  :reasoning, :steer, :stopped, :usage, :subagent, :delegate,
                  :compaction, :compaction_start, :compaction_failed, :retry_callback

      def initialize(tool_call: nil, tool_result: nil, progress: nil, confirm: nil,
                     assistant_text: nil, reasoning: nil, steer: nil, stopped: nil,
                     usage: nil, subagent: nil, delegate: nil, compaction: nil,
                     compaction_start: nil, compaction_failed: nil, retry_callback: nil)
        @tool_call = tool_call
        @tool_result = tool_result
        @progress = progress
        @confirm = confirm
        @assistant_text = assistant_text
        @reasoning = reasoning
        @steer = steer
        @stopped = stopped
        @usage = usage
        @subagent = subagent
        @delegate = delegate
        @compaction = compaction
        @compaction_start = compaction_start
        @compaction_failed = compaction_failed
        @retry_callback = retry_callback
      end
    end
  end
end
