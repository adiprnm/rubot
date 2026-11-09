# frozen_string_literal: true

module Rubot
  module Web
    # One in-flight agent turn plus the event log an SSE reader follows.
    #
    # The turn keeps an ordered *timeline*, not a text buffer and a separate
    # activity list: the thought the model took, what it said before running a
    # tool, the tool row itself, the answer that came out the other side. When
    # every chunk lands in one bubble the order is lost and the answer reads
    # as if it were appended above the calls that produced it.
    #
    # The timing rules are the TUI's on purpose — a thought shorter than
    # THINKING_SECONDS leaves no row at all, a tool call quicker than
    # SLOW_TOOL_SECONDS shows no duration — so both channels report a turn the
    # same way.
    #
    # The log holds *signals*, not rendered payloads. The reader renders the
    # current state of the turn when it sees the signal, which makes a burst
    # of token chunks collapse into a single HTML write and makes a reconnect
    # harmless: re-reading from the start simply re-renders the same timeline.
    class Turn
      HEARTBEAT_SECONDS = 15
      CONFIRM_TIMEOUT = 300
      FLUSH_INTERVAL = 0.05

      # A wait worth noticing earns a row; a quick one is not worth the space.
      THINKING_SECONDS = 3.0
      # Ditto for a tool call: the clock is for the call that makes the reader
      # wonder whether it hung.
      SLOW_TOOL_SECONDS = 3.0

      attr_reader :id, :session_id, :response, :epoch

      # `clock` is injectable so the timing rules can be tested without
      # sleeping through them.
      def initialize(id:, session_id:, clock: nil)
        @id = id
        @session_id = session_id
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        # When the prompt was accepted, on the wall clock. The timeline rows
        # count from the moment their own work started; the row that says the
        # turn is still running has nothing of its own to count from, so it
        # counts from here.
        @epoch = Time.now.to_f
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @events = []
        @closed = false
        @items = []
        @confirm = nil
        @response = nil
        @confirm_mutex = Mutex.new
        @confirm_cv = ConditionVariable.new
        @confirm_answer = nil
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      def confirm_prompt
        @mutex.synchronize { @confirm }
      end

      # A copy, so the renderer never shares a String the producer thread is
      # still appending to.
      def items
        @mutex.synchronize do
          @items.map do |item|
            copy = item.dup
            copy[:text] = item[:text].dup if item[:text]
            copy
          end
        end
      end

      # --- producer side (agent callbacks) --------------------------------

      # The model's answer, token by token. An answer that arrives after a
      # thought or a tool call opens its own block below them.
      def append_chunk(chunk)
        text = chunk.to_s
        return if text.empty?

        @mutex.synchronize do
          # The answer has started, so the model is done thinking. Closed here
          # rather than at the end of the turn: a long answer must not keep a
          # clock running over a thought that already stopped.
          close_thinking_locked
          block = @items.last
          if block && block[:kind] == :text && block[:live]
            block[:text] << text
          else
            @items << { kind: :text, text: +text, live: true }
          end
          publish_locked
        end
      end

      # The model's thinking, while it is still thinking. Only the state of
      # the wait is ever recorded — never the thought itself.
      def thinking(_delta = nil)
        @mutex.synchronize do
          last = @items.last
          return if last && last[:kind] == :thinking && last[:closed_at].nil?

          # A thought that arrives after an answer belongs to a new round: the
          # block above is finished, so the answer continues below this one
          # instead of being split in half by it.
          seal_text_locked
          @items << { kind: :thinking, started_at: @clock.call, epoch: epoch_now,
                      closed_at: nil, elapsed: nil }
          publish_locked
        end
      end

      def tool_started(name, detail)
        @mutex.synchronize do
          # Thinking is over once the model has decided what to run.
          close_thinking_locked
          # What it said before the call stays above the row, as its own
          # block; the answer that follows the result opens a new one.
          seal_text_locked
          @items << { kind: :tool, name: name.to_s, detail: detail.to_s, state: :running,
                      started_at: @clock.call, epoch: epoch_now, elapsed: nil }
          publish_locked
        end
      end

      def tool_finished(name, ok)
        @mutex.synchronize do
          entry = find_running_tool_locked(name)
          if entry
            entry[:state] = ok ? :ok : :failed
            entry[:elapsed] = @clock.call - entry[:started_at]
          end
          publish_locked
        end
      end

      # Called from the turn thread; blocks until the browser answers or the
      # deadline passes. Fails closed, like every other channel.
      def ask_confirm(name, reason)
        @confirm_mutex.synchronize { @confirm_answer = nil }
        @mutex.synchronize do
          @confirm = { name: name.to_s, reason: reason.to_s }
          @events << [ :confirm, nil ]
          @cond.broadcast
        end

        deadline = Time.now + CONFIRM_TIMEOUT
        answer = nil
        @confirm_mutex.synchronize do
          while @confirm_answer.nil?
            remaining = deadline - Time.now
            break if remaining <= 0

            @confirm_cv.wait(@confirm_mutex, remaining)
          end
          answer = @confirm_answer
        end

        @mutex.synchronize do
          @confirm = nil
          @events << [ :confirm, nil ]
          @cond.broadcast
        end

        answer == true
      end

      def answer_confirm(value)
        @confirm_mutex.synchronize do
          @confirm_answer = value
          @confirm_cv.broadcast
        end
        true
      end

      def notice(html)
        @mutex.synchronize do
          @events << [ :notice, html.to_s ]
          @cond.broadcast
        end
      end

      # Carry a rendered fragment to the reader under an event of its own. The
      # turn does not interpret it: the payload is HTML that already knows
      # where it belongs (an out-of-band swap), and the log's job is only to
      # deliver it in order.
      def emit(type, html)
        @mutex.synchronize do
          @events << [ type.to_sym, html.to_s ]
          @cond.broadcast
        end
      end

      def finish(response)
        answer = response.to_s

        @mutex.synchronize do
          close_thinking_locked
          # A turn that answered without streaming — a stop that arrived, or a
          # provider that never emitted a chunk — still has to show its answer.
          append_answer_locked(answer) unless answer.strip.empty?
          seal_text_locked
          @response = answer
          @events << [ :done, nil ]
          @closed = true
          @cond.broadcast
        end
      end

      def fail_with(message)
        notice(%(<div class="error">#{CGI.escapeHTML(message.to_s)}</div>))
        finish(nil)
      end

      # --- consumer side (SSE writer) -------------------------------------

      # Yields [type, payload] pairs in order and blocks while the turn is
      # still producing. Returns once the closing :done event was yielded.
      def each_event
        index = 0
        loop do
          pending = nil
          done = false

          @mutex.synchronize do
            @cond.wait(@mutex, HEARTBEAT_SECONDS) if @events.size <= index && !@closed
            pending = @events[index]
            done = @closed && pending.nil?
          end

          if pending.nil?
            return if done

            yield [ :heartbeat, nil ]
            next
          end

          index += 1

          if pending[0] == :turn
            # Collapse the bursts of chunk signals that piled up meanwhile:
            # the reader re-renders the whole timeline anyway, so one signal
            # is as good as fifty.
            skipped = 0
            @mutex.synchronize do
              skipped += 1 while @events[index + skipped] && @events[index + skipped][0] == :turn
            end
            index += skipped
            yield pending
            sleep FLUSH_INTERVAL
          else
            yield pending
          end

          return if pending[0] == :done
        end
      end

      private

      def publish_locked
        @events << [ :turn, nil ]
        @cond.broadcast
      end

      def epoch_now
        Time.now.to_f
      end

      # An answer that never streamed lands here instead.
      def append_answer_locked(answer)
        tail = @items.reverse.find { |item| item[:kind] == :text }
        if tail
          # The stream may have stopped short of the full answer; the complete
          # text is the truth, and it is never a second block.
          tail[:text] = answer if !tail[:text].empty? && answer.start_with?(tail[:text])
          return if tail[:text] == answer
        end

        @items << { kind: :text, text: answer.dup, live: false }
      end

      # No more chunks will be appended to the block being written.
      def seal_text_locked
        block = @items.last
        block[:live] = false if block && block[:kind] == :text
      end

      # Finish the thinking block. A wait worth noticing collapses to one row,
      # "Thought for 12s"; a quick one is dropped outright, so the timeline
      # only records pauses the reader could feel.
      def close_thinking_locked
        block = @items.last
        return unless block && block[:kind] == :thinking && block[:closed_at].nil?

        block[:elapsed] = @clock.call - block[:started_at]
        block[:closed_at] = Time.now.to_f
        @items.pop if block[:elapsed] <= THINKING_SECONDS
      end

      def find_running_tool_locked(name)
        running = @items.select { |item| item[:kind] == :tool && item[:state] == :running }
        running.reverse.find { |item| item[:name] == name.to_s } || running.last
      end
    end
  end
end
