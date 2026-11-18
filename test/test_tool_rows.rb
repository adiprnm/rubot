# frozen_string_literal: true

require_relative "test_helper"
require "rubot"

# Which tool rows a timeline draws, and the persona setting that decides it.
#
# A compact persona sees one row for the calls — the one the turn reached for
# last, plus whatever the reader has to come back for — while the text and the
# pauses the turn took stay where they happened; the transcript has to agree
# with the live turn, so both go through Rubot::Web::ToolRows.
class TestToolRows < Minitest::Test
  def tool(name, state: :ok, op: nil)
    row = { kind: :tool, name: name, detail: "", state: state, elapsed: 0.1 }
    row[:op] = op if op
    row
  end

  def text(body)
    { kind: :text, text: body, live: false }
  end

  def diff_item(html)
    { kind: :diff, html: html }
  end

  def thought(elapsed)
    { kind: :thinking, elapsed: elapsed, closed_at: elapsed }
  end

  # A thought still running: nothing has been reached for yet, so it is the row
  # on screen.
  def open_thought
    { kind: :thinking, elapsed: nil, closed_at: nil }
  end

  def names(items)
    items.select { |item| item[:kind] == :tool }.map { |item| item[:name] }
  end

  def kinds(items)
    items.map { |item| item[:kind] }
  end

  # --- the rule itself ---------------------------------------------------

  def test_verbose_is_the_default_and_the_other_mode_is_named
    refute Rubot::Web::ToolRows.compact?("verbose")
    refute Rubot::Web::ToolRows.compact?(nil)
    refute Rubot::Web::ToolRows.compact?("")
    assert Rubot::Web::ToolRows.compact?("compact")
  end

  # A turn runs text → call → thought → call → thought: the thought between two
  # A closed thought is the model answering the call above it, so that call
  # keeps its row in place — the pause is read under it, and the next call is
  # a new round. Only calls reached for in the same breath (no thought, no
  # words) collapse into one.
  def test_a_pause_leaves_with_the_call_it_was_taken_for
    items = [ text("Aku cek dulu, bentar."), tool("read"),
              thought(4), tool("grep") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[read grep], names(kept)
    assert_equal %i[text tool thinking tool], kinds(kept)
  end

  # A pause does not take the call above it away: it is drawn under it, as one
  # more "Thought for" line. Nothing below has been called yet, so the call
  # above is still the last call and the only row of it.
  def test_a_pause_stacks_under_the_call_it_ended
    items = [ tool("read"), open_thought ]

    assert_equal %i[tool thinking], kinds(Rubot::Web::ToolRows.collapse(items))
    assert_equal %w[read], names(Rubot::Web::ToolRows.collapse(items))
  end

  # One answer, four calls in the same breath: the timeline is read one row at a
  # time, so the fourth call is the row on screen — the first three are the same
  # work half-told, not four rows stacked.
  def test_compact_reads_a_batch_one_row_at_a_time
    items = [ tool("read"), tool("grep"), tool("read"), tool("grep") ]

    assert_equal %w[grep], names(Rubot::Web::ToolRows.collapse(items))
  end

  # …but a call the reader has to come back for keeps its own row: the batch is
  # not a licence to hide a file the turn changed.
  def test_a_batch_still_shows_the_call_that_changed_a_file
    items = [ tool("file_ops", op: "edit"), diff_item("<pre>a</pre>"),
              tool("read"), tool("grep") ]

    assert_equal %w[file_ops grep], names(Rubot::Web::ToolRows.collapse(items))
  end

  # The reader talking does not split a batch: it is one moment of the turn with
  # the reader's words in the middle of it, and the row on screen is still the
  # call the model reached for last.
  def test_a_steering_message_does_not_split_the_batch
    items = [ text("Aku cek dulu."), tool("read"),
              { kind: :steer, text: "jangan lupa b.rb" },
              tool("grep") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[grep], names(kept)
    assert_includes kinds(kept), :steer
  end

  # The sentences around the calls are the model talking to the reader, and
  # the answer is what the turn was for: neither is a call log to be trimmed.
  # A call the model answered in words keeps its row in its own place — the
  # reader looks for it right above that answer.
  def test_compact_keeps_the_text_around_the_calls
    items = [ text("Aku cek dulu."), tool("read"),
              text("Ketemu."), thought(5), tool("grep"),
              text("Ini hasilnya.") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[read grep], names(kept)
    assert_equal [ "Aku cek dulu.", "Ketemu.", "Ini hasilnya." ],
                 kept.select { |item| item[:kind] == :text }.map { |item| item[:text] }
  end

  # A model does not always think between two calls: it finishes one, answers,
  # and reaches for the next. The answer is the line between the rounds, so the
  # call above it keeps its row — it is the work behind those words, not a log
  # the turn moved on from.
  def test_an_answer_splits_the_round_without_a_pause
    items = [ tool("ls"), text("Bentar, aku lihat lagi."), tool("grep") ]

    assert_equal %w[ls grep], names(Rubot::Web::ToolRows.collapse(items))
  end

  # The whole shape of a live compact turn: two calls in the same breath, an
  # answer, the call it is on now. The batch collapses to its last call, but the
  # call the model answered in words stays where it was — one row per round.
  def test_the_call_it_is_on_is_the_only_call_drawn
    items = [ text("Aku cek dulu."), tool("ls"),
              tool("pwd"),
              text("Lanjut yang kedua."), tool("grep") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[pwd grep], names(kept)
    assert_equal [ "Aku cek dulu.", "Lanjut yang kedua." ],
                 kept.select { |item| item[:kind] == :text }.map { |item| item[:text] }
  end

  # A row that vanishes under a spinning clock reads as work disappearing
  # mid-flight: a call still running is drawn even when another call has come
  # after it.
  def test_a_running_call_is_not_hidden_by_a_later_one
    items = [ tool("grep", state: :running), tool("read") ]

    assert_equal %w[grep read], names(Rubot::Web::ToolRows.collapse(items))
  end


  # The answer is not a call that did anything: the call it reports on stays
  # above it, because a row that vanished the moment the answer started
  # streaming is the flicker the reader was promised not to see.
  def test_the_answer_keeps_the_call_it_reports_on
    items = [ text("Aku cek dulu."), tool("grep"),
              text("Ini hasilnya.") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[grep], names(kept)
    assert_equal [ "Aku cek dulu.", "Ini hasilnya." ],
                 kept.select { |item| item[:kind] == :text }.map { |item| item[:text] }
  end


  # A diff is drawn under the row that made the edit, so it is part of that
  # row's fate: hiding the call while leaving its diff would show a patch no
  # one can attribute. A file written earlier is still something the reader may
  # have to answer for, so the pair stays — together.
  def test_an_edit_keeps_the_row_and_the_diff_it_was_drawn_under
    items = [ tool("edit"), diff_item("<pre>a</pre>"),
              thought(4), tool("edit"), diff_item("<pre>b</pre>") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[edit edit], names(kept)
    assert_equal [ "<pre>a</pre>", "<pre>b</pre>" ],
                 kept.select { |item| item[:kind] == :diff }.map { |item| item[:html] }
  end

  # The operation is what tells a write from a read, because a write that
  # changed nothing draws no diff but still happened.
  def test_a_write_with_nothing_to_show_survives_a_later_call
    items = [ tool("file_ops", op: "write"), thought(4), tool("file_ops", op: "read") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[file_ops file_ops], names(kept)
    assert_equal %w[write read], kept.select { |item| item[:kind] == :tool }.map { |item| item[:op] }
  end

  def test_a_read_is_still_just_a_log_line
    items = [ tool("file_ops", op: "read"), tool("grep") ]

    assert_equal %w[grep], names(Rubot::Web::ToolRows.collapse(items))
  end

  # A failure the reader should hear about, not watch the model silently retry.
  def test_a_failed_call_survives_the_call_that_followed_it
    items = [ tool("shell_exec", state: :failed), thought(4), tool("read") ]

    assert_equal %w[shell_exec read], names(Rubot::Web::ToolRows.collapse(items))
  end

  # A file the agent handed back is content the reader may want to open again,
  # not a log line — it survives on its own, under a row that may not.
  def test_an_attachment_survives
    attachment = { kind: :attachments, list: [ { url: "/x.png", name: "x.png", kind: :picture } ] }
    items = [ tool("send_files"), attachment, thought(4), tool("read") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_includes kinds(kept), :attachments
    assert_equal %w[send_files read], names(kept)
  end

  # A run of thought → call pairs is one moment retold: only the last pair is
  # drawn, plus a trailing thought that has not reached for a call yet. Drawing
  # every pair reads as verbose, which is what compact mode exists to avoid.
  def test_a_thought_never_stacks_on_another
    items = [ thought(4), tool("read"),
              thought(5), tool("grep"),
              thought(6) ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %i[thinking tool thinking], kinds(kept)
    assert_equal [ 5, 6 ],
                 kept.select { |item| item[:kind] == :thinking }.map { |item| item[:elapsed] }
    assert_equal %w[grep], names(kept)
  end

  # …and a pause taken for a call the reader has to come back for stays under
  # it, because that call keeps its row.
  def test_a_pause_stays_under_a_call_that_keeps_its_row
    items = [ tool("shell_exec", state: :failed), thought(5), tool("read") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %i[tool thinking tool], kinds(kept)
    assert_equal %w[shell_exec read], names(kept)
  end

  # A run of thought → call pairs collapses to its last pair: the earlier
  # thought and call are the same moment retold, not separate rounds.
  def test_the_call_it_is_on_keeps_only_the_pause_nothing_was_called_for
    items = [ thought(4), tool("read"), thought(5), tool("grep") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %i[thinking tool], kinds(kept)
    assert_equal 5, kept.first[:elapsed]
    assert_equal %w[grep], names(kept)
  end

  # A thought that took a while is closed into a "Thought for Ns" row before the
  # call it led into (see Rubot::Web::Turn): the call it belongs to is the one
  # being drawn, so the row has to stand above it, not be swallowed by it.
  def test_a_long_thought_is_drawn_before_the_call_it_led_into
    items = [ thought(7), tool("read") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %i[thinking tool], kinds(kept)
    assert_equal 7, kept.first[:elapsed]
  end

  def test_a_timeline_with_no_calls_is_unchanged
    items = [ text("halo"), thought(2) ]

    assert_equal items, Rubot::Web::ToolRows.collapse(items)
  end

  def test_collapsing_leaves_the_given_timeline_alone
    items = [ tool("read"), thought(4), tool("grep") ]

    Rubot::Web::ToolRows.collapse(items)

    assert_equal 3, items.size
  end

  # --- what the rows carry ------------------------------------------------

  # A row is a row: the compact view reads the order the rows arrived in, so
  # nothing is stamped with a pass number, and a pause too quick to record
  # leaves no trace at all — verbose mode draws the log straight through it.
  def test_a_turn_stamps_nothing_and_a_quick_pause_leaves_no_row
    turn, = build_turn("verbose")

    turn.append_chunk("Aku cek dulu.")
    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.thinking
    turn.tool_started("grep", "wanderer")
    turn.append_chunk("Ini hasilnya.")

    assert_equal %i[text tool tool text], turn.items.map { |item| item[:kind] }
    assert(turn.items.none? { |item| item.key?(:round) }, "no pass numbers")
  end

  # With nothing to see between them, the two calls are one batch in compact
  # mode and the row on screen is the one it reached for last.
  def test_a_pause_too_quick_to_show_still_ends_the_batch
    turn, = build_turn("compact")

    turn.append_chunk("Bentar.")
    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.thinking
    turn.tool_started("grep", "wanderer")

    refute(turn.items.any? { |item| item[:kind] == :step }, "no marker row")
    assert_equal %w[grep], names(turn.items)
  end

  # A transcript longer than the live turn is read the same way, so nothing
  # breaks for the sessions already on disk: a thought splits the calls, and
  # the last call is still a row.
  def test_a_transcript_is_read_by_position
    items = [ text("Bentar."), tool("read"), thought(4), tool("grep") ]

    assert_equal %w[read grep], names(Rubot::Web::ToolRows.collapse(items))
  end

  # --- the live turn -----------------------------------------------------

  # A turn whose clock the test drives, so a thought can be slow enough to earn
  # a row without sleeping through it.
  def build_turn(mode)
    now = 0.0
    turn = Rubot::Web::Turn.new(id: "t1", session_id: "s1", tool_output: mode, clock: -> { now })
    [ turn, ->(seconds) { now += seconds } ]
  end

  # The shape the rule is about: what the model said, the call it made, the
  # thought it took, the next call, the thought it is taking now. A closed
  # thought is the model answering the call above it, so that call keeps its
  # row — the reader sees both calls, each with the pause it answered.
  def test_a_compact_turn_reads_one_call_at_a_time
    turn, advance = build_turn("compact")

    turn.append_chunk("Aku cek dulu, bentar.")
    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    assert_equal %i[text tool], kinds(turn.items), "the call it is on"

    advance.(5)
    turn.thinking
    assert_equal %i[text tool thinking], kinds(turn.items),
                 "the pause is drawn under the call it ended"

    advance.(4)
    turn.tool_started("grep", "wanderer")
    turn.tool_finished("grep", true)
    assert_equal %i[text tool thinking tool], kinds(turn.items),
                 "the call it left keeps its row, with the pause it answered"
    assert_equal %w[read grep], names(turn.items)

    advance.(6)
    turn.thinking
    assert_equal %i[text tool thinking tool thinking], kinds(turn.items),
                 "each call keeps its row, and the pause sits under the one it answered"
    assert_equal %w[read grep], names(turn.items)
  end

  # The model answering between two calls is not a call: the row it reports on
  # stays above that answer, in its own place. Only calls reached for in the
  # same breath collapse into one row.
  def test_an_answer_keeps_the_call_it_reports_on_in_a_live_turn
    turn, = build_turn("compact")

    turn.append_chunk("Aku cek dulu.")
    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.append_chunk("Lanjut yang lain.")
    turn.tool_started("grep", "wanderer")

    assert_equal %w[read grep], names(turn.items)
    assert_equal [ "Aku cek dulu.", "Lanjut yang lain." ],
                 turn.items.select { |item| item[:kind] == :text }.map { |item| item[:text] }
  end

  # The shape the reader asked for: prompt → tool → assistant text → tool →
  # answer. A call the model spoke after keeps its row where it happened; the
  # last call stays above the final answer. Nothing moves to the newest prompt.
  def test_a_round_keeps_its_call_between_the_words_it_produced
    items = [ text("Aku cek dulu."), tool("read"),
              text("Isi a.rb sudah kubaca."), tool("grep"),
              text("Ini jawabannya.") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[read grep], names(kept)
    assert_equal %i[text tool text tool text], kinds(kept)
  end

  # Two calls asked for in the same breath are one moment of the turn: the row
  # on screen is the one it reached for last. The call before it was answered
  # for by the next one, so it is not a row of its own.
  def test_a_compact_turn_keeps_the_row_it_is_on
    turn, advance = build_turn("compact")

    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    advance.(5)
    turn.thinking
    advance.(4)
    turn.tool_started("read", "b.rb")
    turn.tool_finished("read", true)
    turn.tool_started("grep", "wanderer")

    assert_equal %w[read grep], names(turn.items)
  end

  # A thought too quick to record draws no row, but the call after it still
  # replaces the call before it: the batch reads the same either way.
  def test_a_quick_thought_still_ends_the_batch
    turn, = build_turn("compact")

    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.thinking
    turn.tool_started("grep", "wanderer")

    assert_equal %w[grep], names(turn.items)
  end

  # …and nothing is drawn for the pause when it is too quick, in either mode:
  # no marker ever reaches the page.
  def test_a_quick_pause_is_never_a_row
    turn, = build_turn(nil)

    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.thinking
    turn.tool_started("grep", "wanderer")

    assert_equal %i[tool tool], turn.items.map { |item| item[:kind] }
  end

  # A write is the row a reader comes back for, and the live turn has the same
  # rule as the transcript: it carries its operation for exactly this.
  def test_a_compact_turn_keeps_the_file_it_wrote
    turn, advance = build_turn("compact")

    turn.tool_started("file_ops", "notes.md", op: "write")
    turn.tool_finished("file_ops", true)
    advance.(5)
    turn.thinking
    advance.(4)
    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)

    assert_equal %w[file_ops read], names(turn.items)
  end

  def test_a_verbose_turn_keeps_the_log
    turn, advance = build_turn(nil)

    turn.thinking
    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    advance.(5)
    turn.thinking
    advance.(4)
    turn.tool_started("grep", "wanderer")

    assert_equal %w[read grep], names(turn.items)
  end

  # The collapse runs on copies, so trimming a row must not reach back into
  # the timeline the producer is still writing to.
  def test_the_collapsed_list_is_not_the_turn_s_own_list
    turn, advance = build_turn("compact")

    turn.tool_started("read", "a.rb")
    shown = turn.items
    shown.clear

    turn.tool_finished("read", true)
    advance.(5)
    turn.thinking
    advance.(4)
    turn.tool_started("grep", "x")

    assert_equal %w[read grep], names(turn.items)
  end

  # --- the persona setting -----------------------------------------------

  def test_a_persona_without_a_choice_reads_as_verbose_and_stays_out_of_the_file
    persona = Rubot::Persona.new(name: "rubot")

    assert_equal "verbose", persona.tool_output
    refute persona.compact_tool_output?
    assert_nil persona.to_h["tool_output"], "the default is not written down"
  end

  def test_compact_round_trips_through_the_persona_file
    stored = Rubot::Persona.new(name: "rubot", tool_output: "Compact").to_h

    assert_equal "compact", stored["tool_output"]
    assert_equal "compact", Rubot::Persona.from(stored).tool_output
  end

  def test_a_mode_no_picker_can_produce_is_not_a_third_mode
    persona = Rubot::Persona.new(name: "rubot", tool_output: "ringkas")

    assert_equal "verbose", persona.tool_output
    assert_nil persona.to_h["tool_output"], "nor is a typo"
  end

  # Rebuilding a persona — a slug change, a model that left config.yml — must
  # not quietly reset the view the reader chose.
  def test_rebuilding_a_persona_keeps_the_mode
    dir = Dir.mktmpdir("rubot-personas")
    store = Rubot::PersonaStore.new(dir: dir)
    persona = Rubot::Persona.new(slug: "rubot", name: "rubot", tool_output: "compact")

    rebuilt = store.send(:rebuild, persona, model: nil)

    assert_equal "compact", rebuilt.tool_output
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end
end
