# frozen_string_literal: true

# Compatibility patches for the ruby-tui gem, kept local until they land
# upstream.
#
# 1. Screen#present writes ESC[K *after* each changed row. When a row's last
#    painted cell is the rightmost column (the input box border on the bottom
#    row does exactly this), the terminal leaves the cursor there with a
#    deferred wrap pending, and the trailing EL erases that cell — visually
#    clipping the right border. Erasing before the content fixes it while
#    still clearing stale cells from previous frames.
# 2. Term::SEQUENCES misses the shift+enter sequences sent by kitty/WezTerm/
#    iTerm2 (keyboard protocol) and xterm (modifyOtherKeys), which the prompt
#    needs to insert a newline instead of submitting.
#
# Mouse input (wheel, press, drag, release) is handled by the vendored gem's
# own Term#read_escape; do not install a second parser here — an overriding
# parser turns SGR mouse reports into :unknown keys, which silently kills
# wheel scrolling and drag-to-select.

require "tui"

module Rubot
  class TUI
    module Compat
      SHIFT_ENTER_SEQUENCES = {
        # kitty keyboard protocol / iTerm2 / WezTerm
        "\e[13;2u" => :shift_enter,
        # xterm modifyOtherKeys
        "\e[27;2u" => :shift_enter,
        # escape-prefixed enter as sent by terminals without the protocols above
        "\e\r"     => :shift_enter,
        "\e\n"     => :shift_enter
      }.freeze

      def self.apply
        originals = ::TUI::Term::SEQUENCES
        merged = originals.merge(SHIFT_ENTER_SEQUENCES).freeze
        ::TUI::Term.send(:remove_const, :SEQUENCES)
        ::TUI::Term.const_set(:SEQUENCES, merged)
        patch_screen!
      end

      # Toggled while the TUI runs, restored after. 1002 = wheel/btn
      # tracking, 1006 = SGR coordinates, and >1u is the kitty keyboard
      # protocol which makes terminals report shift+enter (and alt+enter)
      # as distinct sequences instead of a plain \r.
      TTY_ON  = "\e[?1002h\e[?1006h\e[>1u".freeze
      TTY_OFF = "\e[?1006l\e[?1002l\e[?1000l\e[<u".freeze

      def self.write_online
        ::TUI::Term.write($stdout, TTY_ON)
        ::TUI::Term.flush($stdout)
      rescue StandardError
        nil
      end

      def self.write_offline
        ::TUI::Term.write($stdout, TTY_OFF)
        ::TUI::Term.flush($stdout)
      rescue StandardError
        nil
      end

      # Replacement for Screen#present; identical to upstream except the
      # EL (erase to end of line) is written before the row content instead
      # of after it.
      def self.patch_screen!
        screen_class = ::TUI::Screen
        return if screen_class.method_defined?(:rubot_el_first_present)

        screen_class.class_eval do
          alias_method :rubot_el_first_present, :present

          def present(canvas)
            buf = +::TUI::Term::SYNC_ON

            i = 0
            while i < @h
              unless canvas.dirty?(i)
                i += 1
                next
              end

              buf << ::TUI::Term.move(i, 0) << "\e[K" << canvas.row(i)
              @prev[i] = canvas.row(i)
              i += 1
            end

            buf << ::TUI::Term::SYNC_OFF
            ::TUI::Term.write(@out, buf)
            ::TUI::Term.flush(@out)
            canvas.presented!
            self
          end
        end
      end
    end
  end
end
