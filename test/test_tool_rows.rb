# frozen_string_literal: true

require_relative "test_helper"
require "rubot"

# Which tool rows a timeline draws, and the persona setting that decides it.
#
# A compact persona sees the call the turn is on right now, not the log of
# every call it made; the transcript has to agree with the live turn, so both
# go through Rubot::Web::ToolRows.
class TestToolRows < Minitest::Test
  def tool(name)
    { kind: :tool, name: name, detail: "", state: :ok, elapsed: 0.1 }
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

  def names(items)
    items.select { |item| item[:kind] == :tool }.map { |item| item[:name] }
  end

  # --- the rule itself ---------------------------------------------------

  def test_verbose_is_the_default_and_the_other_mode_is_named
    refute Rubot::Web::ToolRows.compact?("verbose")
    refute Rubot::Web::ToolRows.compact?(nil)
    refute Rubot::Web::ToolRows.compact?("")
    assert Rubot::Web::ToolRows.compact?("compact")
  end

  def test_compact_keeps_only_the_call_the_turn_is_on
    items = [ tool("read"), tool("grep"), tool("write") ]

    assert_equal %w[write], names(Rubot::Web::ToolRows.collapse(items))
  end

  # The sentences around the calls are the model talking to the reader, and
  # the answer is what the turn was for: neither is a call log to be trimmed.
  def test_compact_keeps_the_text_around_the_calls
    items = [ text("Aku cek dulu."), tool("read"), text("Ketemu."), tool("grep"), text("Ini hasilnya.") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[grep], names(kept)
    assert_equal [ "Aku cek dulu.", "Ketemu.", "Ini hasilnya." ],
                 kept.select { |item| item[:kind] == :text }.map { |item| item[:text] }
  end

  # A diff is drawn under the row that made the edit, so it is part of that
  # row's fate: hiding the call while leaving its diff would show a patch no
  # one can attribute.
  def test_a_diff_leaves_with_the_row_it_was_drawn_under
    items = [ tool("edit"), diff_item("<pre>a</pre>"), tool("edit"), diff_item("<pre>b</pre>") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[edit], names(kept)
    assert_equal [ "<pre>b</pre>" ], kept.select { |item| item[:kind] == :diff }.map { |item| item[:html] }
  end

  # A file the agent handed back is content the reader may want to open again,
  # not a log line — it survives the call above it.
  def test_an_attachment_survives_the_row_that_produced_it
    attachment = { kind: :attachments, list: [ { url: "/x.png", name: "x.png", kind: :picture } ] }
    items = [ tool("send_file"), attachment, tool("read") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[read], names(kept)
    assert_includes kept.map { |item| item[:kind] }, :attachments
  end

  # A thought belongs to the call it led into: the row for that call is gone,
  # so the thought goes with it. Left behind, three rounds would read
  # "thought, thought, thought, call" instead of the call, thought, call,
  # thought the turn actually took.
  def test_a_thought_leaves_with_the_call_it_led_into
    items = [ thought(4), tool("read"), thought(5), tool("grep"), thought(6) ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %w[grep], names(kept)
    assert_equal [ 6 ], kept.select { |item| item[:kind] == :thinking }.map { |item| item[:elapsed] }
  end

  # The thought after the surviving call is the turn's current state, so it is
  # the one row that must survive: the reader watches it tick.
  def test_the_thought_after_the_surviving_call_stays_last
    items = [ tool("read"), thought(4), tool("grep"), thought(2), text("Ini hasilnya.") ]

    kept = Rubot::Web::ToolRows.collapse(items)

    assert_equal %i[tool thinking text], kept.map { |item| item[:kind] }
  end

  def test_a_timeline_with_no_calls_is_unchanged
    items = [ text("halo") ]

    assert_equal items, Rubot::Web::ToolRows.collapse(items)
  end

  # --- the live turn -----------------------------------------------------

  def test_a_compact_turn_drops_the_call_it_has_moved_past
    turn = Rubot::Web::Turn.new(id: "t1", session_id: "s1", tool_output: "compact")

    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.tool_started("grep", "wanderer")
    turn.tool_finished("grep", true)

    assert_equal %w[grep], names(turn.items)
  end

  def test_a_verbose_turn_keeps_the_log
    turn = Rubot::Web::Turn.new(id: "t1", session_id: "s1")

    turn.tool_started("read", "a.rb")
    turn.tool_finished("read", true)
    turn.tool_started("grep", "wanderer")

    assert_equal %w[read grep], names(turn.items)
  end

  # The collapse runs on copies, so trimming a row must not reach back into
  # the timeline the producer is still writing to.
  def test_the_collapsed_list_is_not_the_turn_s_own_list
    turn = Rubot::Web::Turn.new(id: "t1", session_id: "s1", tool_output: "compact")

    turn.tool_started("read", "a.rb")
    shown = turn.items
    shown.clear

    turn.tool_finished("read", true)
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
