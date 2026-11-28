# frozen_string_literal: true

module Rubot
  module Web
    # Drawing a report in a conversation: the turn nobody typed.
    #
    # Two kinds of work report themselves this way — a finished batch of
    # delegated runs, and a loop that stopped — and neither can own the
    # machinery. A page has one thread, a message is drawn under an index the
    # archive hands out, and both reports land in the same conversation, so the
    # drawing lives here once and each feature hands in the text it wants the
    # model to read.
    #
    # Included into the channel through both of those modules and left public on
    # purpose: the tests drive these methods directly.
    module Reports
      # How often a report that is being written reaches the page. Faster than
      # this is a repaint the eye cannot follow; slower is a stall.
      REPORT_STREAM_SECONDS = 0.15
      # The turn that writes a report is given no tools (see Agent#process_background),
      # and a model told nothing about that reaches for one anyway: a DeepSeek
      # template wrote a whole `shell_exec` call into its prose and the reader was
      # shown the markup. Saying so is cheaper than cleaning up after it, and the
      # cleanup still runs (see Formatting.without_tool_markup).
      REPORT_TOOLS_NOTE = "Jawab dengan kalimat biasa. Turn ini tidak punya tool, jadi jangan " \
                          "menulis panggilan tool dalam bentuk apa pun.\n\n"
      # How long a report turn may take before it is treated as stuck. Generous:
      # a report is a provider request that may read a file or two, and the
      # answer is streaming to the page while it runs, so nothing is lost by
      # waiting. Long enough that a slow model is not cut, short enough that a
      # dead read does not take the answers with it.
      REPORT_TIMEOUT_SECONDS = 90
      # Guards the table of per-conversation locks, never a report itself: it is
      # held for the two lines that build or find one, and let go before any
      # drawing happens.
      REPORT_LOCKS_GUARD = Mutex.new

      # The report itself.
      #
      # Background, not a user message: the text is handed to the model as
      # context and only its reply joins the transcript. The reader asked for the
      # work; they did not say "Hasil subagent yang sudah selesai".
      #
      # Where the reply goes depends on what the page is showing. Idle, it is
      # appended to the thread and filled in as it is written, so the reader
      # watches it arrive. While a turn of their own is running, a block appended
      # now would sit before the answer still being written, and only a redraw
      # can put the two in the archive's order.
      #
      # One report per conversation at a time, because the block is opened once
      # and grown in place: a second report that read the same index would write
      # into the first one's element. A report waits its turn rather than
      # drawing over the other.
      def deliver_report(sid, text:, label: "")
        report_lock(sid).synchronize do
          index = next_entry_index(sid)
          open_report_entry(sid, index)

          last_sent = 0.0
          begin
            reply = with_report_deadline(sid) do
              # No tools, and one round: a report that arrives late is a report
              # nobody reads, and a turn handed the full toolset spent minutes
              # investigating before it said a word — long past the deadline
              # above, which then deleted the block it had opened.
              session_for(sid).process_background(text, label: "#{label}#{REPORT_TOOLS_NOTE}",
                                                  tools: false) do |written|
                now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                next if now - last_sent < REPORT_STREAM_SECONDS

                last_sent = now
                broadcast_report_entry(sid, index, written)
              end
            end
            # The last passage is always sent, and sent as the finished block: a
            # fixed cadence must not be what decides whether the reader sees the
            # end of the answer, and the cursor has to be retired with it.
            close_report_entry(sid, index, reply.to_s)
          rescue StandardError
            # The block opened for the answer would stand there empty, which is
            # worse than nothing: take it back and let the caller log the failure.
            push_to_session(sid, :append,
                            %(<div id="#{report_anchor(index)}" hx-swap-oob="delete"></div>))
            raise
          end
        end
      end

      # The lock one conversation's reports are drawn under.
      #
      # Built on first use: a report is rare, and a process with no delegation
      # and no loop never draws one, so nothing here belongs in the channel's
      # constructor. A plain `||=` would let two threads build two locks and
      # then draw under different ones, which is the one thing this must not do.
      def report_lock(sid)
        REPORT_LOCKS_GUARD.synchronize do
          @report_locks ||= {}
          @report_locks[sid] ||= Mutex.new
        end
      end

      # A report turn is a provider request nobody is watching, so a read that
      # never returns would hold the conversation's answers out of sight for good
      # — the claim never released and no line in the log.
      #
      # The deadline is watched by a thread that reads the stuck thread's stack
      # before it interrupts it: an exception raised by `Timeout` carries the
      # timer's stack, not the place the work was blocked, which is the one thing
      # that matters here.
      def with_report_deadline(sid)
        target = Thread.current
        watchdog = Thread.new do
          Thread.current.report_on_exception = false
          sleep REPORT_TIMEOUT_SECONDS
          next unless target.alive?

          warn "[report] report for #{sid} still running after #{REPORT_TIMEOUT_SECONDS}s at: " \
               "#{Array(target.backtrace).first(12).join(" | ")}"
          target.raise(Timeout::Error, "report deadline")
        end

        yield
      ensure
        watchdog&.kill
      end

      # The block the answer will be written into.
      #
      # Opened explicitly, and never inferred from a passage. A passage can clean
      # down to nothing (see Formatting.without_tool_markup: the model wrote a
      # tool call into its prose and dropping the markup left an empty string),
      # and an empty passage read as "open a block" drew a second one under the
      # same id — two rules, two cursors, and nothing left to retire either.
      #
      # Two things belong to the opening rather than to the words. The rule above
      # the block is the separator: this answer is not the continuation of the one
      # above it, and nobody typed the prompt it answers. The cursor is the same
      # blinking one a turn of the reader's own wears while it is being written —
      # the block opens unfinished with a live row inside it (see `is-done` and
      # `is-live` in the page's stylesheet) — so a report still arriving can be
      # told from one with nothing more to say.
      def open_report_entry(sid, index)
        push_to_session(sid, :append,
                        %(<div id="thread" hx-swap-oob="beforeend">#{report_open_block(index)}</div>))
      end

      # A passage of the answer as it is written. Only the prose *inside* the
      # block is replaced: re-sending the block re-created the element, and
      # `.turn` carries the animation that plays when a turn arrives — replayed
      # every 150ms it read as a blinking answer instead of a growing one.
      def broadcast_report_entry(sid, index, text)
        push_to_session(sid, :append,
                        %(<div id="#{report_text_anchor(index)}" hx-swap-oob="innerHTML">) +
                          View.prose(text) + %(</div>))
      end

      # The answer is complete, and the block is sent whole: retiring the cursor
      # is a change to the block and not to its words, and this is the block a
      # later load draws from the archive (see `_entry`).
      def close_report_entry(sid, index, text)
        push_to_session(sid, :append, report_finished_block(index, text))
      end

      # The two shapes the page gets, spelled out at the call site rather than
      # picked from a flag inside one method: they differ in three things at once
      # — the frame, the row, and what sits inside it — and a boolean would name
      # only one of them, leaving the other two to be inferred.
      #
      # `is-report` is what the page reads to know this block is not the turn the
      # reader is watching: the script follows a turn's own text, and following
      # this one scrolled the answer being read upward.
      def report_open_block(index)
        report_block(index, frame: "turn is-report", row: "text is-live")
      end

      def report_finished_block(index, text)
        # Sent as the element itself, so it replaces the block it grew in:
        # `hx-swap-oob="true"` swaps the outside of what it finds.
        report_block(index, frame: "turn is-done is-report", row: "text",
                            text: View.prose(text), swap: %( hx-swap-oob="true"))
      end

      def report_block(index, frame:, row:, text: "", swap: "")
        %(<div class="#{frame}" id="#{report_anchor(index)}"#{swap}>) +
          View.render("_report_sep") +
          %(<div class="turn-body"><div class="#{row}" id="#{report_text_anchor(index)}">) +
          text + %(</div></div></div>)
      end

      # The two ids a report is addressed by: the block its answer grows in, and
      # the prose row inside it. Neither is `m-<index>`, which is the name a
      # message of the transcript answers to: the index is read from the archive
      # before the answer is written, so a prompt that lands in between would
      # answer to the same name, and the swap that closes this block would have
      # taken the reader's own words off the page. A conversation with no archive
      # has no index to name and falls back to a name of its own.
      def report_anchor(index)
        index.nil? ? "report-block-live" : "report-block-#{index}"
      end

      def report_text_anchor(index)
        index.nil? ? "report-text-live" : "report-text-#{index}"
      end

      # Where the next message of a conversation will land. The report is drawn
      # with it, so that the block appended to an open page names the entry a
      # later load will draw it as — the index the answer is archived under.
      def next_entry_index(sid)
        store = Rubot::Archive.current
        return nil unless store

        store.last_index(sid).to_i + 1
      end
    end
  end
end
