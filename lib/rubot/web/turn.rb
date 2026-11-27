# frozen_string_literal: true

require_relative "subagent_line"

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
      # How often a streaming answer is redrawn. Every flush re-renders the
      # block being written and sends its whole HTML, so this is both CPU and
      # bytes the reader pays: at 0.05 a 42KB answer cost 20 renders a second.
      # 0.12 is still a steady crawl to the reader's eye (about 8 a second) and
      # a third of the work.
      FLUSH_INTERVAL = 0.12

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
        # The number each timeline row is addressed by on the page. Assigned
        # when a row is first read (see #items), never reused.
        @seq = 0
        @confirm = nil
        @response = nil
        @confirm_mutex = Mutex.new
        @confirm_cv = ConditionVariable.new
        @confirm_answer = nil
        # Sub agents this turn delegated to, keyed by run id. Each holds its
        # latest phase and detail: the transcript row a run leaves reads its
        # count of calls from here. Plain data, rendered on the reader's side
        # from a snapshot; what is happening live is read in the footer instead.
        @subagents = {}
      end

      # A phase after which the run has nothing left to say.
      TERMINAL_PHASES = %w[done failed].freeze

      # Called from the agent's on_subagent callback. Records the latest state
      # of one run: the phase it is in, and how many calls it has made.
      #
      # Nothing is published here. The live view of a delegated run is the
      # footer's sheet, which is written by the run itself (see
      # Web::SubagentJobs); this entry is what the row in the transcript is
      # built from, and that row arrives through #subagent_item below.
      def subagent(info)
        run_id = info[:run_id].to_s
        return if run_id.empty?

        phase = info[:phase].to_s

        @mutex.synchronize do
          entry = (@subagents[run_id] ||= { run_id: run_id, calls: 0 })
          entry[:agent] = info[:agent].to_s
          entry[:phase] = phase
          entry[:detail] = info[:detail].to_s
          entry[:depth] = info[:depth].to_i
          entry[:epoch] = epoch_now
          entry[:calls] = entry[:calls].to_i + 1 if phase == "tool"
          entry[:task] = info[:detail].to_s if phase == "started"
          entry[:line] = subagent_line(entry, phase)
        end
      end

      # A sub agent's phase becomes a timeline row too, so the finished turn
      # records that work happened in another persona. Kept as a plain item so
      # the transcript it becomes carries the same rows the live page showed.
      #
      # In a compact turn the row is written once, when the run ends. While the
      # agent is still working the footer's sheet is the view of it, and a row
      # per tool call would tell the reader the same thing twice. What a
      # finished turn still has to answer for is how much work it took, so the
      # row carries the count of calls. A verbose turn keeps every phase.
      #
      # A thought is never a row: the footer already shows the agent is
      # working, and the transcript has nothing to add to that.
      def subagent_item(info)
        run_id = info[:run_id].to_s
        return if run_id.empty?

        phase = info[:phase].to_s
        return if phase == "thinking"

        @mutex.synchronize do
          entry = (@subagents[run_id] ||= { run_id: run_id, calls: 0 })

          return if ToolRows.compact?(@tool_output) && !TERMINAL_PHASES.include?(phase)

          @items << {
            kind: :subagent,
            run_id: run_id,
            agent: info[:agent].to_s,
            phase: phase,
            detail: detail_for_row(info, phase, entry),
            task: entry[:task].to_s,
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
      #
      # Each row also gets a number the first time it is read, and keeps it for
      # the life of the turn. It is an identity, not a position: a row the
      # compact view drops and later puts back (a call that turned out to lead
      # into an answer) comes back with the number it had, which is what lets
      # the page replace that row where it stands instead of redrawing the
      # whole timeline (see Web::Turns#turn_updates).
      def items
        @mutex.synchronize do
          @items.each { |item| item[:seq] ||= (@seq = @seq.to_i + 1) }
          list = @items.map do |item|
            copy = item.dup
            copy[:text] = item[:text].dup if item[:text]
            copy[:html] = item[:html].dup if item[:html]
            copy[:list] = item[:list].dup if item[:list]
            copy[:task] = item[:task].dup if item[:task]
            copy
          end
          list = ToolRows.collapse(list) if ToolRows.compact?(@tool_output)
          note_entering_locked(list)
          mark_live_block(list)
          mark_awake_call(list)
          list
        end
      end

      # The cursor belongs to the block still being written, which is the last
      # row and only while the turn is open. Derived here rather than carried on
      # the row: sealing used to clear the flag on the tail alone, so a narration
      # a tool row had pushed out of the tail kept a blinking caret for the rest
      # of the turn — the stylesheet is explicit that only the live block gets
      # one ("an earlier narration stays still above the tool row").
      def mark_live_block(list)
        last = list.last
        list.each { |item| item[:live] = false if item[:kind] == :text }
        last[:live] = true if last && last[:kind] == :text && !@closed
      end

      # The light a call row wears does not go out the moment the call returns:
      # the newest call stays lit while the turn is between things — until the
      # agent speaks again, or the turn closes. A call that finished a second
      # ago is still the last thing the agent did, and a page waiting for the
      # next step reads better with one line warm than with none.
      #
      # The agent's own words end it. Once an answer is being written, the call
      # before it is history: the answer is the thing the reader is watching
      # now, and a machine row still glowing underneath it says work is
      # happening where the work has already been reported. Same for a turn that
      # closes — a finished page with a moving line in it reads as still going.
      #
      # One row moves at a time, which is the whole point of the arrangement: a
      # thought that is still open is already the moving thing on the page, and
      # so is a call in flight or a compaction being written. The light on a
      # settled call goes out for the duration and comes back when the page is
      # quiet again — "Thinking…" and the call before it glowing at once is two
      # things asking for the same eye, and the reader has one.
      #
      # A call that failed is left out. Red is the news there, and the light is
      # a colour of its own: lit, the row would walk its red away and say
      # "working" over the one line that is not.
      def mark_awake_call(list)
        return if @closed
        return if list.any? { |item| still_moving?(item) }
        return if answered_since_the_call?

        newest = @items.reverse.find { |item| item[:kind] == :tool }
        return unless newest

        # Only the call that really is the newest: the compact view can drop it
        # (an edit that changed nothing has no row of its own), and lighting
        # whatever call happens to be left would point at work from three
        # rounds ago.
        row = list.reverse.find { |item| item[:kind] == :tool }
        row[:awake] = true if row && row[:seq] == newest[:seq] && row[:state] != :failed
      end

      # The agent has spoken over the call: words of its own have landed after
      # the last thing it reached for, so the call is no longer the edge of the
      # work.
      def answered_since_the_call?
        index = @items.rindex { |item| item[:kind] == :tool }
        return false if index.nil?

        @items[(index + 1)..].to_a.any? { |item| item[:kind] == :text }
      end

      # A row that is already the moving one: an open thought, a call still in
      # flight, a compaction being written. Their own light is a state, so it
      # does not wait for the turn to end to go out.
      def still_moving?(item)
        case item[:kind]
        when :thinking then item[:closed_at].nil?
        when :tool then item[:state] == :running
        when :compaction then item[:state] == :running
        else false
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

      # The summarizer request is the slow part of an automatic compaction.
      # Draw its row as soon as it starts, so the reader sees that the pause is
      # work in progress rather than a turn that stopped answering. The row is
      # replaced in place by #compaction when the result arrives; a failed or
      # cancelled compaction leaves the running row behind, which is the honest
      # record of work that was attempted.
      def compaction_start
        @mutex.synchronize do
          seal_text_locked
          @items << { kind: :compaction, state: :running, epoch: epoch_now }
          publish_locked
        end
      end

      # The summarizer failed or found nothing to do. Retire the "in progress"
      # row so it does not sit there glowing forever; the reader is told the
      # attempt did not take, and the transcript is left untouched.
      def compaction_failed
        @mutex.synchronize do
          row = @items.reverse.find { |item| item[:kind] == :compaction && item[:state] == :running }
          if row
            row[:state] = :failed
          else
            @items << { kind: :compaction, state: :failed, epoch: epoch_now }
          end
          publish_locked
        end
      end

      # An automatic compaction is a seam in the work, not a tool call: the
      # transcript before it was summarized away and the model carried on with
      # less context. It gets its own row so the reader can see why the answer
      # that follows no longer has the earlier detail in view.
      def compaction(result)
        @mutex.synchronize do
          row = @items.reverse.find { |item| item[:kind] == :compaction && item[:state] == :running }
          if row
            row.delete(:state)
            row[:summarized] = result[:summarized_messages].to_i
            row[:before] = result[:context_before].to_i
            row[:after] = result[:context_after].to_i
            row[:elapsed] = result[:elapsed].to_f
          else
            seal_text_locked
            @items << {
              kind: :compaction,
              summarized: result[:summarized_messages].to_i,
              before: result[:context_before].to_i,
              after: result[:context_after].to_i,
              elapsed: result[:elapsed].to_f,
              epoch: epoch_now
            }
          end
          publish_locked
        end
      end

      # `detail` is the phrase the row reads; `title` is what the call actually
      # asked for, kept for the row's tooltip rather than its text; `skills` are
      # the skills this call loaded, so the row can name them in code without a
      # template reading the arguments back.
      def tool_started(name, detail, op: nil, title: nil, skills: nil)
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
          row[:title] = title.to_s unless title.to_s.empty?
          row[:skills] = Array(skills).map(&:to_s).reject(&:empty?) unless Array(skills).empty?
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

      # What a delegated run says about itself, at any moment: the count of
      # calls it has made plus the phase's own detail (the call it is on while
      # working, how long it took once done). The footer draws this while the
      # run is in flight and the transcript row takes the same string when it
      # ends, so the two can never disagree.
      #
      # A failed run says why instead; a count would add nothing to a run that
      # never got anything done.
      def subagent_line(entry, phase)
        SubagentLine.line(calls: entry[:calls], phase: phase, detail: entry[:detail])
      end

      # A verbose turn keeps every phase in its own row, each with the detail
      # that phase carried. A compact turn has one row, and it reads the run
      # the way the footer last read it.
      def detail_for_row(info, phase, entry)
        return info[:detail].to_s unless ToolRows.compact?(@tool_output)

        (entry[:line] || subagent_line(entry, phase)).to_s
      end

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
          # text is the truth, and it is never a second block. The two are also
          # the same answer when they differ only by the trailing whitespace a
          # provider put in its last chunk and the closing response dropped —
          # compared apart, that difference appended the whole answer below the
          # answer, which reads as the model having said it twice.
          streamed = tail[:text]
          same = answer.start_with?(streamed) || streamed.strip == answer.strip
          tail[:text] = answer if !streamed.empty? && same
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
