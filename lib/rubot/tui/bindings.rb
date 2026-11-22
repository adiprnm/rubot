# frozen_string_literal: true

module Rubot
  class TUI
    # Where every key is wired: the scrolling and selection keys the log and
    # the prompt own, the ones the App answers itself, and the handful that
    # steer or cancel the turn in flight.
    #
    # The table is deliberately flat and in one place: a key that is missing
    # from here is a key that does nothing, and /help lists the same names in
    # KEYS. Nothing rebinds itself later, so reading this method top to bottom
    # is the whole keyboard.
    module Bindings
      private

      # The keyboard is registered in four passes, in this order: scrolling,
      # the pointer, the keys that act on the turn, and what the prompt
      # reports back. Nothing is rebound later.
      def wire_bindings
        wire_scroll_keys
        wire_pointer
        wire_turn_keys
        wire_prompt
        wire_tick
      end

      def wire_scroll_keys
        @app.on_key(:page_up) { @log.scroll_by(-10) }
        @app.on_key(:page_down) { @log.scroll_by(10) }
        @app.on_key(:wheel_up) { @log.scroll_by(-3) }
        @app.on_key(:wheel_down) { @log.scroll_by(3) }
      end

      def wire_pointer
        # Drag with the left button to select; on release the text is copied
        # through OSC 52 (terminal clipboard). A press on the scrollbar column
        # grabs the bar instead: from there the drag scrolls the log until the
        # button comes up, wherever the cursor goes.
        @app.on_key(:mouse_press) do |key|
          next unless key.mouse_button.zero?

          # A fresh press always clears a grab, so a release the terminal
          # never delivered cannot leave the log stuck to the cursor.
          @log.end_scrollbar_drag
          # The pill floats over the log's last row, so it is hit-tested before
          # the log: a click on it jumps back to the newest row.
          if @jump.hit?(key.mouse_x, key.mouse_y)
            @log.scroll_to_bottom
          elsif @log.scrollbar_at?(key.mouse_x, key.mouse_y)
            @log.begin_scrollbar_drag(key.mouse_x, key.mouse_y)
          else
            @log.begin_selection(key.mouse_x, key.mouse_y)
          end
        end
        @app.on_key(:mouse_drag) do |key|
          # Checked before the button, so a terminal that reports motion with
          # no button held (mode 1003) cannot drop the grab halfway through.
          if @log.scrollbar_dragging?
            @log.drag_scrollbar(key.mouse_y)
            next
          end
          next unless key.mouse_button.zero?

          @log.extend_selection(key.mouse_x, key.mouse_y)
        end
        @app.on_key(:mouse_release) do |key|
          if @log.scrollbar_dragging?
            @log.end_scrollbar_drag
            next
          end
          next unless key.mouse_button.zero?

          copy_selection
        end
      end

      def wire_turn_keys
        @app.on_key(:ctrl_c) { @app.quit }
        # Hand the prompt to $EDITOR and take the result back into the input.
        @app.on_key(:ctrl_g) { edit_prompt }
        # A terminal only forwards text, so a screenshot on the clipboard is
        # fetched and saved here before it can reach the prompt.
        @app.on_key(:ctrl_v) { paste_clipboard }
        @app.on_key(:escape) do
          @log.end_scrollbar_drag
          @log.clear_selection
          cancel_turn
        end
      end

      def wire_prompt
        # Typing, scrolling and new output all move the rows out from under a
        # highlight that was left on screen after a copy.
        @prompt.on(:change) { @log.clear_selection }
        # The prompt owns the palette keys; it only reports what should be on
        # screen. See PromptInput#handle_key.
        @prompt.on(:menu) { |items, index| @menu.set_items(items, index) }

        @prompt.on(:submit) do |text|
          # Collapsed pastes go back to their full text here, once: what the
          # model sees is what was pasted, not the token on screen. Image
          # tokens become the file paths, without a sentence around them.
          line = @prompt.expand(@prompt.expand_images(text)).strip
          @prompt.value = ""
          next if line.empty?

          record_history(line)

          # A message typed while a turn is running steers it instead of
          # waiting behind it: the agent hands it to the model between rounds,
          # after the tool calls of the round in flight. A command is not
          # something the model can act on, so it runs on the command lane
          # instead: now, next to the turn, rather than after the answer.
          if @busy && !line.start_with?("/") && steer_running_turn(line)
            @events << [ :steer, line ]
            next
          end

          # Echo the prompt on screen, ahead of the assistant entry that
          # arrives with :stream_start.
          publish prompt_echo(line), keep_leading: true, hang: ECHO_HANG
          # A command typed while a turn is running skips the mailbox: the
          # worker is inside that turn, so anything left there only runs once
          # the answer is done. The lane runs it now.
          if @busy
            @command_mailbox << line
          else
            @mailbox << line
          end
        end
      end

      def wire_tick
        @app.every(0.1) do
          pump
          refresh_thinking
          refresh_slow_tools
          @working.tick(@busy ? (@stopping ? :cancel : :work) : nil)
        end
      end
    end
  end
end
