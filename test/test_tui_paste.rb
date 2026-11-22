# frozen_string_literal: true

require "stringio"
require "test_helper"
require "rubot"
require_relative "support/tui_support"

module Rubot
  # What arrives from outside the box: a clipboard image, a long paste, and the thinking block that collapses.
  class TestTUI < Minitest::Test
    include TuiSupport

    # --- clipboard paste ---------------------------------------------------



    def test_paste_key_puts_an_image_token_in_the_prompt
      Dir.mktmpdir do |dir|
        path = png_file(dir)
        repl = build_repl
        app = repl.instance_variable_get(:@app)
        prompt = repl.instance_variable_get(:@prompt)

        stub_clipboard(images: [ path ]) do
          assert_equal false, prompt.handle_key(::TUI::Key.new(:ctrl_v)),
                       "the prompt passes the key on, so the app binding runs"
          app.send(:dispatch, ::TUI::Key.new(:ctrl_v))
        end

        assert_equal "[Image 1]", prompt.value,
                     "the box shows a token, not a sentence and not a path"
        assert_equal [ path ], prompt.images
      end
    end

    def test_paste_key_numbers_several_images
      Dir.mktmpdir do |dir|
        first = png_file(dir, name: "a.png")
        second = png_file(dir, name: "b.png")
        third = png_file(dir, name: "c.png")
        repl = build_repl
        prompt = repl.instance_variable_get(:@prompt)

        stub_clipboard(images: [ first, second, third ]) { repl.paste_clipboard }

        assert_equal "[Image 1] [Image 2] [Image 3]", prompt.value
        assert_equal [ first, second, third ], prompt.images
      end
    end

    def test_a_second_paste_continues_the_numbering
      Dir.mktmpdir do |dir|
        first = png_file(dir, name: "a.png")
        second = png_file(dir, name: "b.png")
        repl = build_repl
        prompt = repl.instance_variable_get(:@prompt)

        stub_clipboard(images: [ first ]) { repl.paste_clipboard }
        stub_clipboard(images: [ second ]) { repl.paste_clipboard }

        assert_equal "[Image 1] [Image 2]", prompt.value
        assert_equal [ first, second ], prompt.images
      end
    end

    def test_the_submitted_message_carries_the_image_paths_and_no_prose
      Dir.mktmpdir do |dir|
        path = png_file(dir)
        repl = build_repl
        prompt = repl.instance_variable_get(:@prompt)
        mailbox = repl.instance_variable_get(:@mailbox)

        stub_clipboard(images: [ path ]) { repl.paste_clipboard }
        prompt.insert(" jelaskan ini")
        prompt.handle_key(::TUI::Key.new(:enter))

        line = mailbox.pop
        assert_equal "#{path} jelaskan ini", line,
                     "the token becomes the path, with nothing else added"
        refute_match(/attached/i, line)
      end
    end

    def test_paste_key_keeps_the_prompt_text_around_the_image
      Dir.mktmpdir do |dir|
        path = png_file(dir)
        repl = build_repl
        prompt = repl.instance_variable_get(:@prompt)
        prompt.value = "lihat:"

        stub_clipboard(images: [ path ]) { repl.paste_clipboard }

        assert_equal "lihat: [Image 1]", prompt.value, "a space separates the token from the text"
      end
    end

    def test_paste_key_says_nothing_when_the_clipboard_is_empty
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      events = repl.instance_variable_get(:@events)

      stub_clipboard { repl.paste_clipboard }

      assert_equal "", prompt.value
      assert_empty events, "an empty clipboard is not worth a line of output"
    end

    def test_paste_key_inserts_clipboard_text_when_there_is_no_image
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)

      stub_clipboard(text: "one\ntwo") { repl.paste_clipboard }

      assert_equal "one\ntwo", prompt.value
    end

    def test_insert_places_text_at_the_cursor
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      "ac".each_char { |c| input.handle_key(::TUI::Key.printable(c)) }
      input.handle_key(::TUI::Key.new(:left))

      changes = 0
      input.on(:change) { changes += 1 }
      input.insert("b")

      assert_equal "abc", input.value
      assert_equal 1, changes, "one change event per insertion"
    end

    # --- long pastes -------------------------------------------------------


    def test_a_short_paste_lands_in_the_buffer_as_typed
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      input.handle_key(::TUI::Key.new(:paste, "one\ntwo"))

      assert_equal "one\ntwo", input.value
    end

    def test_a_long_paste_is_collapsed_to_a_token
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      input.handle_key(::TUI::Key.new(:paste, long_text(500)))

      assert_equal "[pasted 500 lines #1]", input.value,
                   "the buffer holds a token, not 500 lines the renderer must draw"
      assert_equal 1, input.buffer.lines.size
    end

    def test_a_long_single_line_paste_is_collapsed_too
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      input.handle_key(::TUI::Key.new(:paste, "x" * 2000))

      assert_match(/\A\[pasted 1 lines #\d+\]\z/, input.value)
    end

    def test_expanding_a_token_gives_back_the_pasted_text
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      pasted = long_text(500)
      input.handle_key(::TUI::Key.new(:paste, pasted))
      input.handle_key(::TUI::Key.printable("?"))
      input.handle_key(::TUI::Key.printable(" "))

      assert_equal "#{pasted}? ", input.expand(input.value),
                   "the text comes back untouched, with what was typed around it"
    end

    def test_expansion_happens_once
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      input.handle_key(::TUI::Key.new(:paste, long_text(20)))
      input.expand(input.value)

      assert_equal "[pasted 20 lines #1]", input.expand(input.value),
                   "a stale token is left alone instead of expanding to nothing"
    end

    def test_several_pastes_each_keep_their_own_text
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      first = long_text(10)
      second = long_text(20).sub("line 1", "other 1")
      input.handle_key(::TUI::Key.new(:paste, first))
      input.handle_key(::TUI::Key.printable("\n"))
      input.handle_key(::TUI::Key.new(:paste, second))

      assert_equal "#{first}\n#{second}", input.expand(input.value)
    end

    def test_the_submitted_message_carries_the_pasted_text
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      mailbox = repl.instance_variable_get(:@mailbox)
      pasted = long_text(300)

      prompt.handle_key(::TUI::Key.new(:paste, pasted))
      prompt.handle_key(::TUI::Key.printable("!"))
      prompt.handle_key(::TUI::Key.new(:enter))

      assert_equal "#{pasted}!", mailbox.pop, "the model sees the paste, not the token"
      assert_equal "", prompt.value
    end

    def test_history_recall_collapses_a_long_message_again
      repl = build_repl
      prompt = repl.instance_variable_get(:@prompt)
      pasted = long_text(400)

      prompt.handle_key(::TUI::Key.new(:paste, pasted))
      prompt.handle_key(::TUI::Key.new(:enter))
      prompt.handle_key(::TUI::Key.new(:up))

      assert_equal 1, prompt.buffer.lines.size, "recall must not put 400 rows back"
      assert_equal pasted, prompt.expand(prompt.value)
    end

    def test_repeated_pastes_do_not_grow_the_store_without_bound
      input = TUI::PromptInput.new([], TUI::COMPLETABLE)
      (TUI::PromptInput::MAX_PASTES + 4).times do |i|
        input.handle_key(::TUI::Key.new(:paste, long_text(10 + i)))
      end

      assert_operator input.instance_variable_get(:@pastes).size,
                      :<=, TUI::PromptInput::MAX_PASTES
    end

    # --- thinking block ------------------------------------------------



    def test_the_block_shows_the_state_of_the_wait_and_nothing_of_the_thought
      repl = build_repl

      repl.apply_event([ :thinking, "Let me look at the repo first." ])
      age_thinking(repl, 1.5)
      repl.refresh_thinking

      texts = log_texts(repl)
      bar = texts.find { |text| text.include?("Thinking") }
      assert bar, "a thinking row appears with the first fragment"
      refute texts.any? { |text| text.include?("Let me look at the repo first.") },
             "the thought itself never reaches the transcript: #{texts.inspect}"
      refute_includes bar, "·", "a wait under the threshold shows no clock"
    end

    def test_thinking_block_shows_elapsed_time_once_it_has_been_a_while
      repl = build_repl

      repl.apply_event([ :thinking, "Still going." ])
      age_thinking(repl, 5)
      repl.refresh_thinking

      bar = log_texts(repl).find { |text| text.include?("Thinking") }
      assert_includes bar, "Thinking… · 5s", "the clock starts past the threshold"
    end

    def test_a_long_thought_collapses_to_one_line_when_the_answer_starts
      repl = build_repl

      repl.apply_event([ :thinking, "Let me look at the repo first." ])
      age_thinking(repl, 5)
      repl.apply_event([ :chunk, "Here it is." ])

      texts = log_texts(repl)
      assert texts.any? { |text| text.include?("Thought for 5s") }, "the wait is recorded: #{texts.inspect}"
      refute texts.any? { |text| text.include?("Let me look at the repo first.") },
             "the thought itself is folded away"
      assert texts.any? { |text| text.include?("Here it is.") }, "the answer follows it"
    end

    # Every new fragment rewrites the block. The clock must not blink out of
    # the row while the model is still streaming: fragments arrive faster than
    # the tick that would put it back.
    def test_the_clock_survives_a_new_fragment
      repl = build_repl

      repl.apply_event([ :thinking, "Counting. " ])
      age_thinking(repl, 6)
      repl.apply_event([ :thinking, "Still counting." ])

      texts = log_texts(repl)
      bar = texts.find { |text| text.include?("Thinking") }
      assert_includes bar, "· 6s", "the elapsed label is kept across fragments"
      refute texts.any? { |text| text.include?("Still counting.") }, "the fragment itself stays hidden"
      assert_equal 1, texts.count { |text| text.include?("Thinking") }, "still one block, not one per fragment"
    end

    # Some gateways open the stream with an empty `content` chunk *before* the
    # reasoning arrives. That is not the answer, so it must not fold the block
    # away before the thought has been seen.
    def test_an_empty_chunk_does_not_close_the_block
      repl = build_repl

      repl.apply_event([ :thinking, "Let me count." ])
      age_thinking(repl, 4)
      repl.apply_event([ :chunk, "" ])
      repl.refresh_thinking

      bar = log_texts(repl).find { |text| text.include?("Thinking") }
      assert bar, "the block survives an empty fragment"
      assert_includes bar, "· 4s", "and keeps its clock"
      refute log_texts(repl).any? { |text| text.include?("Thought for") },
             "the block is not closed by an empty chunk"
    end

    # Some gateways interleave `reasoning_content` with `content` inside the
    # same answer. Splitting the answer row there cut the message in two at a
    # chunk boundary — mid-word, with a blank row between the halves.
    def test_a_fragment_mid_answer_does_not_split_the_answer
      repl = build_repl

      repl.apply_event([ :stream_start ])
      repl.apply_event([ :chunk, "Sem" ])
      repl.apply_event([ :thinking, "Wait, the tag should be TUI." ])
      repl.apply_event([ :chunk, "ua item itu untuk TUI." ])
      repl.apply_event([ :stream_end, false ])

      texts = log_texts(repl)
      assert_includes texts, "Semua item itu untuk TUI.",
                      "the answer stays in one row: #{texts.inspect}"
      refute texts.any? { |text| text.include?("Thinking") },
             "a mid-answer fragment opens no block of its own"
    end

    def test_a_quick_thought_is_removed_without_a_trace
      repl = build_repl

      repl.apply_event([ :thinking, "Quick." ])
      age_thinking(repl, 1)
      repl.apply_event([ :chunk, "Hi." ])

      texts = log_texts(repl)
      refute texts.any? { |text| text.include?("Thought for") }, "no footer for a pause nobody felt"
      refute texts.any? { |text| text.include?("Quick.") }, "the block is gone"
      refute texts.each_cons(2).any? { |above, below| above.empty? && below.empty? },
             "the blank the block sat under is reused, not doubled"
    end

    # A dropped block has to take its own spacer with it. The tool row that
    # arrives right after it lands *below* the block, so at close time the
    # block is no longer the last entry: probing for "a blank at the end"
    # would find the one already there and leave the spacer orphaned.
    def test_a_quick_thought_leaves_no_orphan_blank_above_a_tool_call
      repl = build_repl

      repl.apply_event([ :stream_start ])
      repl.apply_event([ :chunk, "Let me check." ])
      repl.apply_event([ :tool_call, "shell_exec", { "command" => "ls" } ])
      repl.apply_event([ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      repl.apply_event([ :stream_start ])
      repl.apply_event([ :thinking, "Quick thought." ])
      age_thinking(repl, 1)
      repl.apply_event([ :tool_call, "shell_exec", { "command" => "cat x" } ])

      texts = log_texts(repl)
      refute texts.each_cons(2).any? { |above, below| above.empty? && below.empty? },
             "no double blank left behind: #{texts.map { |t| t.empty? ? '·' : t }.inspect}"
      assert_equal texts.index { |text| text.include?("✓ shell_exec ls") } + 1,
                   texts.index { |text| text.include?("⚒ shell_exec cat x") },
                   "back-to-back tool rows stay adjacent"
    end

    # The retained block keeps its spacer: the separator above it is what makes
    # it read as a remark about the turn rather than part of the answer.
    def test_a_kept_block_keeps_the_blank_row_above_it
      repl = build_repl

      repl.apply_event([ :stream_start ])
      repl.apply_event([ :chunk, "Let me check." ])
      repl.apply_event([ :tool_call, "shell_exec", { "command" => "ls" } ])
      repl.apply_event([ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      repl.apply_event([ :stream_start ])
      repl.apply_event([ :thinking, "A long thought." ])
      age_thinking(repl, 6)
      repl.apply_event([ :tool_call, "shell_exec", { "command" => "cat x" } ])

      texts = log_texts(repl)
      thought = texts.index { |text| text.include?("Thought for 6s") }
      assert thought, "the block is kept: #{texts.inspect}"
      assert_equal "", texts[thought - 1], "with a blank row above it"
    end

    # A kept block is set off on both sides, including between two tool rows:
    # it is a remark on the turn, not a step in the tool chain.
    def test_a_kept_block_between_two_tool_calls_is_set_off_both_sides
      repl = build_repl

      repl.apply_event([ :stream_start ])
      repl.apply_event([ :chunk, "Let me check." ])
      repl.apply_event([ :tool_call, "shell_exec", { "command" => "ls" } ])
      repl.apply_event([ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      repl.apply_event([ :stream_start ])
      repl.apply_event([ :thinking, "A long thought." ])
      age_thinking(repl, 6)
      repl.apply_event([ :tool_call, "shell_exec", { "command" => "cat x" } ])
      repl.apply_event([ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      texts = log_texts(repl)
      thought = texts.index { |text| text.include?("Thought for 6s") }
      assert thought, "the block is kept: #{texts.inspect}"
      assert_equal "", texts[thought - 1], "with a blank row above it"
      assert_equal "", texts[thought + 1], "and one below it"
      assert texts[thought + 2].include?("cat x"), "the next tool row follows the blank"
    end

    # A quick thought between two tool rows leaves no seed of a blank: the
    # rows sit adjacent, exactly as if the model had never paused.
    def test_a_quick_block_between_two_tool_calls_leaves_the_rows_adjacent
      repl = build_repl

      repl.apply_event([ :stream_start ])
      repl.apply_event([ :chunk, "Let me check." ])
      repl.apply_event([ :tool_call, "shell_exec", { "command" => "ls" } ])
      repl.apply_event([ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      repl.apply_event([ :stream_start ])
      repl.apply_event([ :thinking, "Quick." ])
      age_thinking(repl, 1)
      repl.apply_event([ :tool_call, "shell_exec", { "command" => "cat x" } ])
      repl.apply_event([ :tool_done, "shell_exec", nil, "[Exit code: 0] ok" ])

      texts = log_texts(repl)
      refute texts.any? { |text| text.include?("Thought for") }, "no block: #{texts.inspect}"
      first = texts.index { |text| text.include?("shell_exec ls") }
      assert_equal first + 1, texts.index { |text| text.include?("shell_exec cat x") },
                   "the two tool rows are adjacent"
    end

    # The block's own blank row is the separator the footer needs. Adding the
    # footer's blank on top of it would leave two in a row.
    def test_a_kept_block_at_the_end_of_a_turn_does_not_double_the_blank
      repl = build_repl

      repl.apply_event([ :thinking, "A long thought." ])
      age_thinking(repl, 6)
      repl.apply_event([ :stream_end, false ])

      texts = log_texts(repl)
      thought = texts.index { |text| text.include?("Thought for 6s") }
      assert thought, "the block is kept: #{texts.inspect}"
      assert_equal "", texts[thought + 1], "one blank under the block"
      assert texts[thought + 2].include?("Turn took"), "then the footer, not another blank"
    end

    def test_a_tool_call_closes_the_thinking_block
      repl = build_repl

      repl.apply_event([ :thinking, "I need the directory listing." ])
      age_thinking(repl, 4)
      repl.apply_event([ :tool_call, "shell_exec", { "command" => "ls" } ])

      texts = log_texts(repl)
      assert texts.any? { |text| text.include?("Thought for 4s") }
      refute texts.any? { |text| text.include?("I need the directory listing.") }
    end

    # The transcript records that the model was thinking, never what it was
    # thinking about: no fragment of a long chain of thought may leak into it,
    # however long the stream runs.
    def test_a_long_thought_is_never_echoed_into_the_transcript
      repl = build_repl
      thought = (1..12).map { |i| "step #{i}\n" }.join

      repl.apply_event([ :thinking, thought ])

      texts = log_texts(repl)
      assert_equal 1, texts.count { |text| text.include?("Thinking") }, "one block for the whole thought"
      refute texts.any? { |text| text.include?("step ") }, "not one row of it is shown"
    end

    # The agent hands reasoning over on its own callback; the worker has to
    # turn it into transcript events, not throw it away.
    def test_process_message_forwards_reasoning_to_the_transcript
      repl = build_repl
      agent = repl.instance_variable_get(:@agent)
      agent.define_singleton_method(:process) do |_msg, on_reasoning: nil, **_opts, &blk|
        on_reasoning&.call("pondering ")
        on_reasoning&.call("deeply")
        blk&.call("Answer.")
        "Answer."
      end
      agent.define_singleton_method(:flush_learning) { nil }
      agent.define_singleton_method(:usage_report) do
        { requests: 1, prompt_tokens: 10, cache_hit_rate: 0.0,
          context_used: 20, context_window: 128_000, context_percent: 0.1,
          cost: { "total" => 0.0 } }
      end

      repl.process_message("hi")

      events = repl.instance_variable_get(:@events)
      queued = []
      queued << events.pop until events.empty?
      thought = queued.select { |event| event[0] == :thinking }.map { |event| event[1] }
      assert_equal [ "pondering ", "deeply" ], thought

      queued.each { |event| repl.apply_event(event) }
      texts = log_texts(repl)
      assert texts.any? { |text| text.include?("Answer.") }, "the answer is on screen"
      refute texts.any? { |text| text.include?("pondering") },
             "a thought under the threshold is gone by the time the answer lands"
    end
  end
end
