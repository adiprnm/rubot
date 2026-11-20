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

      # How long a call row takes to fade in once it stands where the previous
      # one stood. The stylesheet owns the keyframes (tool-row-swap); the number
      # is here because the turn has to know when the fade is over and stop
      # asking for it.
      SWAP_SECONDS = 0.30

      attr_reader :id, :session_id, :response, :epoch, :prompt, :subagents

      # `clock` is injectable so the timing rules can be tested without
      # sleeping through them. `epoch_clock` is the wall clock the timeline rows
      # stamp themselves with, injectable for the same reason: the working row
      # and a restarted clock are microseconds apart, and a poor thing to
      # assert on.
      def initialize(id:, session_id:, prompt: nil, clock: nil, epoch_clock: nil, tool_output: nil)
        @id = id
        @session_id = session_id
        # How the reader asked this turn's calls to be drawn (see
        # Rubot::Web::ToolRows). The turn holds it, not the renderer, so the
        # live timeline and the transcript it becomes agree.
        @tool_output = tool_output.to_s
        # The prompt is kept here because the session file only learns about it
        # when the turn is written at the end. A page refreshed mid-answer has
        # to draw the bubble it is answering, and this is the only copy.
        @prompt = prompt.to_s
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @epoch_clock = epoch_clock || -> { Time.now.to_f }
        # When the prompt was accepted, on the wall clock. The timeline rows
        # count from the moment their own work started; the row that says the
        # turn is still running counts from here and nowhere else. It is drawn
        # once, when the turn starts, and a tool call does not re-send it: the
        # row never changes, so a second copy would only make the text flash.
        @epoch = @epoch_clock.call
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @events = []
        @closed = false
        # The timeline in the order the turn produced it: a batch of calls, the
        # thought that led into it, the answer that came out. The compact view
        # reads that order back (see Rubot::Web::ToolRows).
        @items = []
        # When each call row was first drawn, by row id, and the id itself. The
        # timeline is redrawn whole on every event of a turn, so a row is a new
        # node every fifty milliseconds and a fade written into the stylesheet
        # would start over on each one — the reader saw a flash instead of a
        # fade. The age travels with the row instead, and the stylesheet seeks
        # into the keyframes with it (see note_entering_locked).
        @entered = {}
        @row_seq = 0
        @confirm = nil
        @response = nil
        @confirm_mutex = Mutex.new
        @confirm_cv = ConditionVariable.new
        @confirm_answer = nil
        # Sub agents this turn delegated to, keyed by run id. Each holds its
        # latest phase and detail, so the strip above the composer can show how
        # many are running and what each is doing. Plain data, rendered on the
        # reader's side from a snapshot.
        @subagents = {}
      end

      # A snapshot of the sub agents, newest first. A copy so the renderer never
      # shares a Hash the producer thread is still updating.
      def subagent_list
        @mutex.synchronize { @subagents.values.reverse.map(&:dup) }
      end

      # How many sub agents are still running.
      def running_subagents
        @mutex.synchronize { @subagents.values.count { |s| RUNNING_PHASES.include?(s[:phase]) } }
      end

      RUNNING_PHASES = %w[started thinking tool].freeze

      # Called from the agent's on_subagent callback. Records the latest state
      # of one run and publishes a dedicated SSE event so the strip updates
      # without re-rendering the whole timeline.
      def subagent(info)
        run_id = info[:run_id].to_s
        return if run_id.empty?

        @mutex.synchronize do
          entry = (@subagents[run_id] ||= { run_id: run_id })
          entry[:agent] = info[:agent].to_s
          entry[:phase] = info[:phase].to_s
          entry[:detail] = info[:detail].to_s
          entry[:depth] = info[:depth].to_i
          entry[:epoch] = epoch_now
          @events << [ :subagents, nil ]
          @cond.broadcast
        end
      end

      # A sub agent's phase becomes a timeline row too, so the finished turn
      # records that work happened in another persona. Kept as a plain item so
      # the transcript it becomes carries the same rows the live page showed.
      def subagent_item(info)
        @mutex.synchronize do
          @items << {
            kind: :subagent,
            agent: info[:agent].to_s,
            phase: info[:phase].to_s,
            detail: info[:detail].to_s,
            epoch: epoch_now
          }
          publish_locked
        end
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      def confirm_prompt
        @mutex.synchronize { @confirm }
      end

      # A copy, so the renderer never shares a String the producer thread is
      # still appending to. The mode decides which rows survive: a compact turn
      # keeps only the call it is on (see Rubot::Web::ToolRows).
      def items
        @mutex.synchronize do
          list = @items.map do |item|
            copy = item.dup
            copy[:text] = item[:text].dup if item[:text]
            copy[:html] = item[:html].dup if item[:html]
            copy[:list] = item[:list].dup if item[:list]
            copy
          end
          list = ToolRows.collapse(list) if ToolRows.compact?(@tool_output)
          note_entering_locked(list)
          list
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
          block = tail_locked
          if block && block[:kind] == :text
            # A sealed block is still where the answer was written: sealing only
            # means a later passage may open a block below it. A provider that
            # interleaves reasoning with the answer closes and re-opens the
            # thought between two chunks, and when that thought was too quick to
            # record the answer came back as a second block — a line break in
            # the middle of a word ("S" then "aya").
            block[:text] << text
            block[:live] = true
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
          last = tail_locked
          return if last && last[:kind] == :thinking && last[:closed_at].nil?

          # A thought that arrives while the answer is still being written is
          # an out-of-band fragment: some gateways interleave their reasoning
          # with the answer, and it lands between two chunks of one word. It is
          # dropped rather than recorded, because opening a block here would
          # seal the answer and split it — "S" above the row, "aya" below it,
          # which the reader sees as a newline in the middle of a word. The TUI
          # reached the same rule for the same reason: only a pause *between*
          # calls deserves a row, and a real one always starts with the answer
          # closed, since a tool call and the end of the turn both close it.
          return if last && last[:kind] == :text && last[:live]

          # A thought that arrives after a finished answer belongs to the work
          # below it: the block above is done, so the answer continues below
          # this one instead of being split in half by it.
          seal_text_locked
          @items << { kind: :thinking, started_at: @clock.call, epoch: epoch_now,
                      closed_at: nil, elapsed: nil }
          publish_locked
        end
      end

      def tool_started(name, detail, op: nil)
        @mutex.synchronize do
          # Thinking is over once the model has decided what to run.
          close_thinking_locked
          # What it said before the call stays above the row, as its own
          # block; the answer that follows the result opens a new one.
          seal_text_locked
          # Nothing is stamped on the row: the compact view keeps the last call
          # and drops the ones before it (see Rubot::Web::ToolRows), and what
          # stands between two calls on screen is whatever the model left
          # there — a thought, a sentence — not a number this turn keeps.
          row = { kind: :tool, name: name.to_s, detail: detail.to_s, state: :running,
                  started_at: @clock.call, epoch: epoch_now, elapsed: nil,
                  row_id: @row_seq += 1 }
          # The operation a file tool was asked for. The compact view keeps a
          # row that changed a file even when it has no diff to show (see
          # Rubot::Web::ToolRows), and the name alone cannot tell a read from a
          # write.
          # The instagram tool is named after the service, so its `connect`
          # operation would otherwise read "instagram connect connect".
          row[:op] = op.to_s unless op.to_s.empty? || (name.to_s == "instagram" && op.to_s == "connect")
          @items << row
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

      # A file the agent handed back during this turn. It joins the answer
      # where the tool that produced it finished, not above the whole turn: the
      # reader sees it in the place the work happened.
      #
      # Consecutive files share one strip, so a turn that sends four of them
      # scrolls sideways at one height instead of stacking four rows.
      def add_attachment(url:, name:, id: nil, kind: :picture, label: nil)
        file = { url: url.to_s, name: name.to_s, kind: kind }
        file[:id] = id.to_s unless id.to_s.empty?
        file[:label] = label.to_s unless label.to_s.empty?
        @mutex.synchronize do
          # The reader can have spoken while the model was thinking, so the
          # strip is the last row that is not their message.
          last = @items[@items.rindex { |item| item[:kind] != :steer } || @items.length]
          if last && last[:kind] == :attachments
            last[:list] = last[:list] + [ file ]
          else
            @items << { kind: :attachments, list: [ file ], epoch: epoch_now }
          end
          publish_locked
        end
      end

      # The edit a tool made, drawn under the row that made it. The fragment is
      # built once, here, rather than by the renderer: the timeline is redrawn
      # on every chunk, and a diff recomputed per chunk would walk the whole
      # file again for every token of the answer.
      def add_diff(html)
        body = html.to_s
        return if body.empty?

        @mutex.synchronize do
          @items << { kind: :diff, html: body, epoch: epoch_now }
          publish_locked
        end
      end

      # The connect card the instagram tool asked for. It is a timeline item
      # like any other so a refresh mid-answer still draws the button — the
      # alternative, an out-of-band swap, would vanish on the next redraw.
      def add_instagram_card
        @mutex.synchronize do
          @items << { kind: :instagram_connect, epoch: epoch_now }
          publish_locked
        end
      end

      # Text the reader sent while this turn was already running. It joins the
      # timeline where it was typed, not where the model got around to reading
      # it: a steering message that only shows up after a refresh looks like it
      # was never sent at all, and the reader has no way to tell whether to say
      # it again.
      #
      # The agent still consumes it between rounds; this is the page's copy of
      # the moment, drawn in the same bubble the session file will draw later.
      def add_steer(text)
        body = text.to_s.strip
        return if body.empty?

        @mutex.synchronize do
          @items << { kind: :steer, text: body, epoch: epoch_now }
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
      #
      # A reader that joins a turn already in flight asks for `from_now`: what
      # it needs is the state the turn is in, not the log that produced it. The
      # log is written for the reader who was there — every :turn in it is a
      # whole re-render, and replayed one by one with the flush pause between
      # them a long answer would take minutes to catch up with itself. The
      # first paint after a refresh is the latest state, and the events that
      # follow are the live ones.
      def each_event(from_now: false)
        index = 0

        if from_now
          closed = false
          @mutex.synchronize do
            # Taken under the lock, so an event produced between here and the
            # first read below is not skipped.
            index = @events.size
            closed = @closed
          end
          yield [ :turn, nil ]
          if closed
            yield [ :done, nil ]
            return
          end
        end

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
        @epoch_clock.call
      end

      # Marks a call row that has just arrived with how long it has been here,
      # so the stylesheet can resume its fade instead of restarting it. Each
      # event of a turn sends the whole timeline again, which makes every row a
      # fresh node: an animation that begins at zero on each one blinks once per
      # stream tick. `animation-delay: -120ms` puts the new node at the point the
      # last node had reached, so what the reader sees is one fade of 180ms
      # rather than a dozen flashes of nothing.
      #
      # The age is measured from when the call was made (`epoch`), not from when
      # it first appeared in the collapsed timeline. A call the model answered
      # in words only earns its row when the next call arrives (see
      # Rubot::Web::ToolRows), and timing it from that moment made an old call
      # fade in all over again — a row that had been on screen for a minute
      # blinked on every redraw. The row's own clock is the truth either way.
      #
      # The age stops being sent once the fade is over, and rows that left the
      # timeline are forgotten, so the bookkeeping is as long as the turn is.
      def note_entering_locked(list)
        now = epoch_now
        live = {}
        list.each do |item|
          next unless item[:kind] == :tool && item[:row_id]

          live[item[:row_id]] = true
          born = item[:epoch] || now
          age = now - born
          item[:swap_ms] = (age * 1000).round if age >= 0 && age < SWAP_SECONDS
        end
        @entered.keep_if { |row_id, _| live[row_id] }
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
        block = tail_locked
        block[:live] = false if block && block[:kind] == :text
      end

      # The last row the turn drew. A steering message is the reader talking,
      # not the turn moving on: it is drawn where it was typed, and it must not
      # stand between a block and its own continuation. Read from the end rather
      # than trusted to be `@items.last`, because the reader can speak at any
      # moment — including in the middle of a thought.
      def tail_locked
        index = @items.rindex { |item| item[:kind] != :steer }
        index && @items[index]
      end

      # Where the last visible row sits, for the writes that have to look at it
      # (an open thought, a strip of files). Same skipping rule as tail_locked.
      def tail_index_locked
        @items.rindex { |item| item[:kind] != :steer }
      end

      # Finish the thinking block. A wait worth noticing becomes the row
      # "Thought for 12s"; a quick one is dropped outright, so the timeline only
      # records pauses the reader could feel. Nothing depends on the dropped
      # row: the compact view keeps the last call whatever stands between it and
      # the one before (see Rubot::Web::ToolRows), so a pause nobody could feel
      # needs no marker to remember it by.
      def close_thinking_locked
        index = tail_index_locked
        return unless index

        block = @items[index]
        return unless block[:kind] == :thinking && block[:closed_at].nil?

        block[:elapsed] = @clock.call - block[:started_at]
        block[:closed_at] = Time.now.to_f
        return if block[:elapsed] > THINKING_SECONDS

        # Deleted by index, not popped: the reader can have spoken while the
        # model was thinking, and a `pop` would take their message instead of
        # the pause that is too short to mention.
        @items.delete_at(index)
      end

      def find_running_tool_locked(name)
        running = @items.select { |item| item[:kind] == :tool && item[:state] == :running }
        running.reverse.find { |item| item[:name] == name.to_s } || running.last
      end
    end
  end
end
