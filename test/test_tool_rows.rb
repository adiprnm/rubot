# frozen_string_literal: true

require_relative "test_helper"
require "rubot"

# Which tool rows a timeline draws, and the persona setting that decides it.
#
# A compact persona sees the batch of calls the turn is on right now — plus the
# thought that led into it — not the log of every call before it; the transcript
# has to agree with the live turn, so both go through Rubot::Web::ToolRows.
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

  # A thought still running: the round it opens has not reached for anything.
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
  # calls means the model decided to look again, so what it did before that
  # thought is the log. The thought that led into the call it is on stays above
  # it, because that is the order the turn took.
  def test_compact_keeps_the_call_it_is_on_and_the_thought_that_led_into_it
    items = [ text("Aku cek dulu, bentar."), tool("read"),
              thought(4), tool("grep") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[grep], names(kept)
    assert_equal %i[text thinking tool], kinds(kept)
    assert_equal [ 4 ], kept.select { |item| item[:kind] == :thinking }.map { |item| item[:elapsed] }
  end

  # The pause opens the round below it, so the moment the model stops to think
  # again the calls it finished are gone: what the reader watches is one row
  # replacing one row, never a thought appearing under a call that then leaves.
  def test_a_pause_leaves_the_calls_of_the_round_it_ended_behind
    quick = [ tool("read"), { kind: :step } ]
    slow = [ tool("read"), open_thought ]

    assert_equal %i[step], kinds(Rubot::Web::ToolRows.collapse(quick))
    assert_equal %i[thinking], kinds(Rubot::Web::ToolRows.collapse(slow))
    assert_empty names(Rubot::Web::ToolRows.collapse(slow))
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
    items = [ tool("file_ops", op: "edit"), tool("read"), tool("grep") ]

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
  def test_compact_keeps_the_text_around_the_calls
    items = [ text("Aku cek dulu."), tool("read"),
              text("Ketemu."), thought(5), tool("grep"),
              text("Ini hasilnya.") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[grep], names(kept)
    assert_equal [ "Aku cek dulu.", "Ketemu.", "Ini hasilnya." ],
                 kept.select { |item| item[:kind] == :text }.map { |item| item[:text] }
  end

  # A model does not always think between two calls: it finishes one, answers,
  # and reaches for the next. The answer is the line between the rounds, so the
  # call above it is the log — reading only the pause left it on screen next to
  # the call the turn is on now.
  def test_an_answer_splits_the_round_without_a_pause
    items = [ tool("ls"), text("Bentar, aku lihat lagi."), tool("grep") ]

    assert_equal %w[grep], names(Rubot::Web::ToolRows.collapse(items))
  end

  # The whole shape of a live compact turn, in the order the rows arrive: two
  # finished rounds, an answer, the call it is on now.
  def test_the_round_it_is_on_is_the_only_call_drawn
    items = [ text("Aku cek dulu."), { kind: :step }, tool("ls"),
              { kind: :step }, tool("pwd"),
              text("Lanjut yang kedua."), tool("grep") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[grep], names(kept)
    assert_equal [ "Aku cek dulu.", "Lanjut yang kedua." ],
                 kept.select { |item| item[:kind] == :text }.map { |item| item[:text] }
  end

  # A row that vanishes under a spinning clock reads as work disappearing
  # mid-flight: the call it is on is drawn even when a round marker lands below
  # it before the result is back.
  def test_a_running_call_is_not_hidden_by_the_round_that_opened_below_it
    items = [ tool("grep", state: :running), { kind: :step }, tool("read") ]

    assert_equal %w[grep read], names(Rubot::Web::ToolRows.collapse(items))
  end


  # The answer is not a round that did anything: the call it reports on stays
  # above it, because a row that vanished the moment the answer started
  # streaming is the flicker the reader was promised not to see.
  def test_the_answer_keeps_the_call_it_reports_on
    items = [ text("Aku cek dulu."), { kind: :step }, tool("grep"),
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
    items = [ tool("file_ops", op: "read"), thought(4), tool("grep") ]

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
    items = [ tool("send_file"), attachment, thought(4), tool("read") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_includes kinds(kept), :attachments
    assert_equal %w[read], names(kept)
  end

  # A thought belongs to the round it opened: the calls of the round above it
  # are finished work, so they leave together with the thought that led into
  # them. What stays is the pause the turn is on and whatever it reached for
  # after it.
  def test_a_thought_leaves_with_the_call_it_led_into
    items = [ thought(4), tool("read"),
              thought(5), tool("grep"),
              thought(6) ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %i[thinking], kinds(kept)
    assert_equal 6, kept.first[:elapsed]
  end

  # …and its call is drawn under it the moment the model reaches for it.
  def test_the_round_it_is_on_keeps_its_own_call
    items = [ thought(4), tool("read"), thought(5), tool("grep") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %i[thinking tool], kinds(kept)
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

  # --- round ids ---------------------------------------------------------

  # Every row says which pass of the model it came from: what the model said
  # and the call it reached for are one round, a thought opens the next, and a
  # call joins the round it was reached for instead of opening one of its own.
  # That is what the compact view reads — the line it draws is the first row
  # carrying the round of the last call, never a count of the rows above it.
  def test_a_turn_stamps_the_round_each_row_came_from
    turn, = build_turn("verbose")

    turn.append_chunk("Aku cek dulu.")
    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.thinking
    turn.tool_started("grep", "wanderer")
    turn.append_chunk("Ini hasilnya.")

    assert_equal %i[text tool step tool text], kinds(turn.items)
    assert_equal [ 1, 1, 2, 2, 3 ], turn.items.map { |item| item[:round] }
  end

  # The pause that was too quick to earn a row still knows which round it
  # opened: the marker keeps the number, so the calls below it stay a round of
  # their own even though nothing on screen says a pause happened.
  def test_a_pause_too_quick_to_show_still_carries_its_round
    turn, = build_turn("compact")

    turn.append_chunk("Bentar.")
    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.thinking
    turn.tool_started("grep", "wanderer")

    step = turn.items.find { |item| item[:kind] == :step }
    refute_nil step, "the boundary stays even without a clock"
    assert_equal 2, step[:round]
    assert_equal %w[grep], names(turn.items)
  end

  # Two calls that came from different rounds are not one batch, even with
  # nothing between them to see: the number on the row decides, not the kind of
  # the row above it.
  def test_the_round_decides_not_the_row_above
    items = [ text("Bentar."), tool("read").merge(round: 1), tool("grep").merge(round: 2) ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[grep], names(kept)
    assert_equal [ "Bentar." ], kept.select { |item| item[:kind] == :text }.map { |item| item[:text] }
  end

  # A timeline with no rounds — a transcript written before they existed — is
  # read the way it always was, so nothing breaks for the sessions already on
  # disk.
  def test_a_timeline_without_rounds_is_read_by_position
    items = [ text("Bentar."), tool("read"), thought(4), tool("grep") ]

    assert_equal %w[grep], names(Rubot::Web::ToolRows.collapse(items))
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
  # thought it took, the next call, the thought it is taking now. The reader
  # watches one round at a time — the row it is on replaces the row before it,
  # and starting to think again is what ends the round above.
  def test_a_compact_turn_reads_one_round_at_a_time
    turn, advance = build_turn("compact")

    turn.append_chunk("Aku cek dulu, bentar.")
    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    assert_equal %i[text tool], kinds(turn.items), "the call it is on"

    advance.(5)
    turn.thinking
    assert_equal %i[text thinking], kinds(turn.items), "the finished call leaves as the thought opens"

    advance.(4)
    turn.tool_started("grep", "wanderer")
    turn.tool_finished("grep", true)
    assert_equal %i[text thinking tool], kinds(turn.items), "the thought stays above the call it led into"
    assert_equal %w[grep], names(turn.items)

    advance.(6)
    turn.thinking
    assert_equal %i[text thinking], kinds(turn.items), "the next round takes the batch above it"
    assert_empty names(turn.items)
  end

  # The model answering between two calls is what ends the round above, even
  # when it never stopped to think: the reader watches one call at a time.
  def test_an_answer_ends_the_round_in_a_live_turn
    turn, = build_turn("compact")

    turn.append_chunk("Aku cek dulu.")
    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.append_chunk("Lanjut yang lain.")
    turn.tool_started("grep", "wanderer")

    assert_equal %w[grep], names(turn.items)
    assert_equal [ "Aku cek dulu.", "Lanjut yang lain." ],
                 turn.items.select { |item| item[:kind] == :text }.map { |item| item[:text] }
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
    turn.tool_started("grep", "wanderer")

    assert_equal %w[grep], names(turn.items)
  end

  # A thought too quick to record draws no row, but it is still the line
  # between two rounds: the call before it is finished work, not part of the
  # batch the model is waiting on. Without the marker the two rounds read as one
  # batch and compact mode has nothing to hide, which is the same as no compact
  # mode at all on a turn whose thoughts are all quick.
  def test_a_quick_thought_still_ends_the_batch
    turn, = build_turn("compact")

    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.thinking
    turn.tool_started("grep", "wanderer")

    assert_equal %w[grep], names(turn.items)
  end

  # …and the marker itself is for the compact view, not the page: nothing draws
  # it in either mode.
  def test_the_round_marker_is_never_a_row
    turn, = build_turn(nil)

    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.thinking
    turn.tool_started("grep", "wanderer")

    assert_equal %i[tool step tool], turn.items.map { |item| item[:kind] }
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

    assert_equal %w[grep], names(turn.items)
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
