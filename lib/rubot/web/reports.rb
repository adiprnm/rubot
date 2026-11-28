# frozen_string_literal: true

require "securerandom"
require "timeout"

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
      # The turn that writes an ordinary report is given no tools (see
      # Agent#process_background), and a model told nothing about that reaches
      # for one anyway: a DeepSeek template wrote a whole `shell_exec` call into
      # its prose and the reader was shown the markup. Saying so is cheaper than
      # cleaning up after it, and the cleanup still runs (see
      # Formatting.without_tool_markup).
      #
      # An acting report is the exception and gets REPORT_ACT_INSTRUCTION
      # instead: it is handed the toolset, so this note would be false in it.
      REPORT_TOOLS_NOTE = "Jawab dengan kalimat biasa. Turn ini tidak punya tool, jadi jangan " \
                          "menulis panggilan tool dalam bentuk apa pun.\n\n"
      # How long a report turn may take before it is treated as stuck. Generous:
      # a report is a provider request that may read a file or two, and the
      # answer is streaming to the page while it runs, so nothing is lost by
      # waiting. Long enough that a slow model is not cut, short enough that a
      # dead read does not take the answers with it.
      REPORT_TIMEOUT_SECONDS = 90
      # What an acting report is told. A report turn normally has no tools and
      # nobody to answer to (REPORT_TOOLS_NOTE below), so a model that wants to
      # do something has no way to ask and no way to act. The batch of answers
      # from a review is the one report that may need to act, because the reader
      # may already have said what should happen once it lands.
      #
      # Firm and complete on purpose: no human answers in this turn, so every
      # way out has to be named here. The permission comes from the
      # conversation, not from this text: with no such request, the turn is a
      # report like any other.
      #
      # Item 2 pins a string the model did not produce: `VERDICT: BLOCKERS OPEN`
      # is the verdict line of the `code-review` skill, copied here by hand. That
      # coupling is a silent one — a rename or a change of capitalisation in the
      # skill turns this fail-safe off without anything failing — so the string
      # has to be kept verbatim against the skill, and item 6 exists because a
      # report that is not acting has no pull request to name.
      REPORT_ACT_INSTRUCTION = <<~TEXT
        Turn ini PUNYA tool: kamu boleh membaca file, menjalankan perintah, dan mengubah repo.
        Tidak ada manusia yang menjawab di turn ini, jadi jangan menanyakan konfirmasi dan jangan
        menunggu jawaban.

        1. Bertindak HANYA kalau pembaca sudah meminta hal itu di percakapan ini — misalnya
           "kalau reviewer bilang aman, langsung commit dan buat PR". Kalau tidak ada permintaan
           seperti itu, cukup laporkan hasilnya dengan kalimat biasa dan JANGAN mengubah apa pun.
        2. Kalau hasil batch di bawah memuat baris `VERDICT: BLOCKERS OPEN` (verdict skill
           `code-review`, disalin persis), jangan commit apa pun dan cukup laporkan.
        3. Jangan commit di `main` atau `master`. Kalau branch yang aktif salah satu dari itu, buat
           branch dulu.
        4. Push branch-nya sebelum `gh pr create`: tanpa push, `gh pr create` menanyakan hal-hal
           secara interaktif, dan turn ini tidak bisa menjawabnya.
        5. Jangan menyentuh file di luar yang direview, dan jangan mengubah kode yang tidak diminta.
        6. Baris terakhirmu: kalau kamu bertindak, URL pull request-nya. Kalau kamu hanya
           melaporkan (tidak ada permintaan untuk bertindak), satu kalimat penutup yang menyebut
           apa yang kamu lakukan atau tidak lakukan. Kalau gagal, satu baris alasan kenapa gagal.
      TEXT
      # What the reader is left with when an acting report runs out of time
      # before it answers. It may not claim the work did not happen: the turn is
      # stopped at whatever point it had reached, and a commit or a push may
      # already be in the repo by then.
      REPORT_DEADLINE_OPEN = "Laporan ini kuhentikan setelah %<seconds>s detik karena belum selesai. " \
                             "Keadaan repo-nya belum pasti: commit, push, atau pull request-nya " \
                             "bisa saja sudah terjadi sebelum turn ini berhenti. Cek `git status` " \
                             "dan `git log` dulu sebelum menganggap tidak ada yang berubah."

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
      #
      # `act:` is the one difference between a report that only speaks and a
      # report that may work. An ordinary report is words: no tools, one round,
      # the short deadline. An acting report is handed the toolset, the caller's
      # round cap and the caller's longer deadline, because the reader may have
      # asked in this conversation for something to happen once the answers
      # land — and the turn that reads those words is the one that decides
      # whether they did (see REPORT_ACT_INSTRUCTION). Both share everything
      # else: the block, the stream, the lock, the deadline.
      #
      # A batch of answers is reported by that turn even when the reader never
      # asked for anything to happen, and the minutes it may take are paid for
      # anyway. The alternative is the channel deciding from the transcript
      # whether a request exists — parsing the reader's intent, with a stable
      # answer that only a test can lie about and a wrong answer in either
      # direction: a commit that was asked for and not made, or one that was not.
      # The model reads the transcript already; REPORT_ACT_INSTRUCTION makes the
      # decision explicit and leaves the report alone when nothing was asked.
      def deliver_report(sid, text:, label: "", act: false, max_rounds: nil,
                         timeout: REPORT_TIMEOUT_SECONDS)
        # The identity of the turn this report becomes. The deadline needs it:
        # the message waits in the actor's queue behind whatever is running, so a
        # stop without an identity would end the reader's own turn and let this
        # one start afterwards, past the deadline it was given (see
        # Actors::SessionHandle#cancel!).
        turn_id = SecureRandom.hex(8)
        report_lock(sid).synchronize do
          index = next_entry_index(sid)
          open_report_entry(sid, index)

          last_sent = 0.0
          handle = session_for(sid)
          begin
            reply = with_report_deadline(sid, seconds: timeout, what: act ? "acting report" : "report") do
              # No tools and one round unless the caller asked for work: a report
              # that arrives late is a report nobody reads, and a turn handed the
              # full toolset spent minutes investigating before it said a word —
              # long past the deadline above, which then deleted the block it had
              # opened. A report that may act is told so, and told everything it
              # needs to act without a human (see the two notes).
              handle.process_background(text,
                                        label: "#{label}#{act ? REPORT_ACT_INSTRUCTION : REPORT_TOOLS_NOTE}",
                                        tools: act, max_rounds: act ? max_rounds : nil,
                                        id: turn_id) do |written|
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
          rescue Timeout::Error
            # A deadline that only unblocks this thread leaves the turn running
            # inside the actor, where the next prompt of this conversation would
            # queue behind it. The channel already has the stop signal for that
            # (see SessionHandle#cancel!), so the turn goes with the deadline —
            # and it goes by name: if the message is still waiting in the queue,
            # naming it is what keeps it from running at all.
            handle.cancel!(turn_id)
            if act
              # An acting report may have committed and pushed before the stop
              # landed, so nothing here may say the work did not happen; the
              # reader is told where to look instead, and the block is closed on
              # that line so its cursor does not blink for an answer that is
              # never coming.
              close_report_entry(sid, index, format(REPORT_DEADLINE_OPEN, seconds: timeout))
            else
              # An ordinary report has nothing to say about a repo and no answer
              # to leave behind: the block it opened is taken back, exactly as
              # the failure below does.
              push_to_session(sid, :append,
                              %(<div id="#{report_anchor(index)}" hx-swap-oob="delete"></div>))
            end
            # Never swallowed, acting or not. The answers were marked read when
            # they were claimed (see Subagents#claim_subagent_results) and only
            # an exception makes the caller give them back
            # (Subagents#report_subagents_when_done): swallowing this one is what
            # lost a whole batch for good, in a state the store cannot recover
            # from on its own.
            raise
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

      # Whether a report turn is running in this conversation right now — the
      # question a caller asks before queueing one of its own. The lock above is
      # what serialises reports, so it is also what answers this: a report held
      # for the whole of an acting turn (minutes, see ACTING_REPORT_TIMEOUT_SECONDS)
      # must make the next caller leave its answers where they are rather than
      # stack a second turn behind the first and make the reader wait twice.
      def report_in_flight?(sid)
        report_lock(sid).locked?
      end

      # A report turn is a provider request nobody is watching, so a read that
      # never returns would hold the conversation's answers out of sight for good
      # — the claim never released and no line in the log.
      #
      # The body runs on a thread of this method's making, and that is the whole
      # point. `Thread#raise` is asynchronous: a watchdog that checked "is it
      # finished?" and then raised could be overtaken by the body returning, and
      # the error landed in the report's own `ensure` — after the answer had been
      # streamed, with `Timeout::Error` surfacing where nothing was waiting for
      # it, replacing a complete report with a deadline notice and cancelling a
      # turn that was already over. Nothing is injected into anybody here: either
      # the join says the body is done and its answer is used, or it is not done
      # and its thread is killed. A body that has returned is never touched,
      # because there is no moment at which it could be.
      #
      # Killing that thread is safe only because it is this method's own: it
      # holds no lock (the report lock belongs to the caller), and its `ensure`
      # still runs, which closes the event port of the turn the stopped thread
      # was reading. That port closing is how the actor learns the answer is
      # unwanted instead of writing into a receiver that is gone.
      #
      # The stack comes from the thread that is stuck, not from a timer: an
      # exception raised by `Timeout` carries the timer's stack, which says
      # nothing about the place the work was blocked.
      #
      # `seconds` and `what` are the caller's because one report is not another:
      # a batch that may act deserves a longer leash than a summary (see
      # Web::Subagents::ACTING_REPORT_TIMEOUT_SECONDS). The default stays the
      # report's, so both ordinary report paths — a batch of answers and a
      # stopped loop — read as they always did.
      def with_report_deadline(sid, seconds: REPORT_TIMEOUT_SECONDS, what: "report")
        body = Thread.new do
          Thread.current.report_on_exception = false
          begin
            [ :ok, yield ]
          rescue StandardError => e
            [ :failed, e ]
          end
        end

        unless body.join(seconds)
          warn "[report] #{what} for #{sid} still running after #{seconds}s at: " \
               "#{Array(body.backtrace).first(12).join(" | ")}"
          # The killing exception unwinds the body, so its `ensure` closes the
          # turn's event port and the actor is told nobody is listening.
          body.kill
          body.join(1)
          raise Timeout::Error, "#{what} deadline"
        end

        status, value = body.value
        raise value if status == :failed

        value
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
