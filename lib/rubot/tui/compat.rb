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
#    needs to insert a newline instead of submitting, and the ctrl+arrow
#    sequences that move the prompt caret from word to word.
# 3. Term.session pushes the keyboard protocol *before* switching to the
#    alternate screen. Terminals keep a separate flag stack per screen, so
#    that push is discarded the moment the alternate screen is entered and
#    shift+enter degrades to a plain \r (submit). The push has to happen
#    after the screen switch; see patch_session!.
# 4. Term#read_key names only ctrl+c, ctrl+d and ctrl+z; every other control
#    byte is handed back as a printable character. Terminals without the
#    keyboard protocol send ctrl+g as 0x07 (BEL), which would be typed into
#    the prompt instead of opening the editor; see patch_control_keys!.
#
# The terminal is also handed to a child process (the external editor) and
# taken back afterwards; see hand_over.
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
        "\e[13;3u" => :shift_enter, # alt+enter
        # xterm modifyOtherKeys level 2 and tmux extended-keys: CSI 27 ; mod ; code ~
        "\e[27;2;13~" => :shift_enter,
        "\e[27;3;13~" => :shift_enter,
        # escape-prefixed enter as sent by terminals without the protocols above
        "\e\r"     => :shift_enter,
        "\e\n"     => :shift_enter,
        # ctrl+arrow: xterm/kitty/iTerm2 use "CSI 1;5D", a few terminals
        # omit the leading "1;" and send "CSI 5D".
        "\e[1;5D" => :ctrl_left,
        "\e[1;5C" => :ctrl_right,
        "\e[5D"   => :ctrl_left,
        "\e[5C"   => :ctrl_right
      }.freeze

      # The keyboard protocol sends keys that have no legacy encoding as
      # "CSI code;modifiers u". Two of those matter to the app: Esc becomes
      # CSI 27u (so the bare \e that cancels a turn never arrives) and ctrl+c
      # becomes CSI 99;5u instead of 0x03 (so the quit binding never fires).
      CSI_U    = /\A\e\[(\d+)(?:;(\d+))?u\z/
      MOD_ALT  = 2
      MOD_CTRL = 4

      # Kitty's private key codes for the arrow keys when the protocol
      # reports them as CSI-u instead of their legacy CSI form.
      ARROW_CODES = { 57350 => :left, 57351 => :right, 57352 => :up, 57353 => :down }.freeze

      # Table lookup with a CSI u fallback. Kept as a Hash subclass so the
      # vendored Term#read_escape needs no patching.
      class Sequences < Hash
        def [](sequence)
          super || from_csi_u(sequence)
        end

        private

        def from_csi_u(sequence)
          match = CSI_U.match(sequence.to_s)
          return nil unless match

          code = match[1].to_i
          mods = match[2] ? match[2].to_i - 1 : 0 # the parameter is 1-based

          return :enter if code == 13 && mods.zero?
          return :shift_enter if code == 13 && (mods & MOD_ALT).positive?
          return :escape if code == 27 && mods.zero?
          return :"ctrl_#{code.chr}" if (mods & MOD_CTRL).positive? && code.between?(97, 122)

          arrow = ARROW_CODES[code]
          return :"ctrl_#{arrow}" if arrow && (mods & MOD_CTRL).positive?

          nil
        end
      end

      def self.apply
        originals = ::TUI::Term::SEQUENCES
        merged = Sequences.new
        originals.each { |sequence, name| merged[sequence] = name }
        merged.merge!(SHIFT_ENTER_SEQUENCES)
        ::TUI::Term.send(:remove_const, :SEQUENCES)
        ::TUI::Term.const_set(:SEQUENCES, merged.freeze)
        patch_screen!
        patch_session!
        patch_control_keys!
      end

      # Toggled while the TUI runs, restored after. 1002 = wheel/btn
      # tracking, 1006 = SGR coordinates, >1u is the kitty keyboard protocol
      # which makes terminals report shift+enter (and alt+enter) as distinct
      # sequences instead of a plain \r, and >4;2m is xterm's modifyOtherKeys
      # (level 2) for the terminals that only speak that dialect.
      TTY_ON  = "\e[?1002h\e[?1006h\e[>4;2m\e[>1u".freeze
      TTY_OFF = "\e[>4;0m\e[<u\e[?1006l\e[?1002l\e[?1000l".freeze

      def self.write_online(output = $stdout)
        ::TUI::Term.write(output, TTY_ON)
        ::TUI::Term.flush(output)
      rescue StandardError
        nil
      end

      def self.write_offline(output = $stdout)
        ::TUI::Term.write(output, TTY_OFF)
        ::TUI::Term.flush(output)
      rescue StandardError
        nil
      end

      # Term.session writes ALT_ON, then yields. The keyboard/mouse modes
      # are pushed from inside that block so they land on the alternate
      # screen's own stack, and popped before it is left again.
      def self.patch_session!
        term = ::TUI::Term
        return if term.singleton_class.method_defined?(:rubot_keyboard_session)

        term.singleton_class.class_eval do
          alias_method :rubot_keyboard_session, :session

          def session(output = $stdout, input = $stdin, &block)
            Rubot::TUI::Compat.capture_terminal_state
            rubot_keyboard_session(output, input) do
              Rubot::TUI::Compat.write_online(output)
              begin
                block.call
              ensure
                Rubot::TUI::Compat.write_offline(output)
              end
            end
          end
        end
      end

      # Control bytes the gem does not name (everything but ctrl+c, ctrl+d
      # and ctrl+z, which Term#read_key handles itself) arrive as printable
      # characters holding the raw byte. Normalise the whole C0 range to
      # :ctrl_a .. :ctrl_z so bindings work on terminals that lack the
      # keyboard protocol, and so a control byte is never typed into a
      # buffer.
      def self.patch_control_keys!
        term = ::TUI::Term
        return if term.singleton_class.method_defined?(:rubot_control_keys_read_key)

        term.singleton_class.class_eval do
          alias_method :rubot_control_keys_read_key, :read_key

          def read_key(timeout = 0.0)
            key = rubot_control_keys_read_key(timeout)
            Rubot::TUI::Compat.control_key(key) || key
          end
        end
      end

      # The named key for a raw C0 byte (0x01-0x1a), or nil when `key` is
      # not one.
      def self.control_key(key)
        return nil unless key&.printable?

        char = key.name.to_s
        return nil unless char.bytesize == 1 && char.ord.between?(1, 26)

        ::TUI::Key.new(:"ctrl_#{(char.ord + 96).chr}")
      end

      # The cooked termios state Term.session is about to replace with raw
      # mode. hand_over puts it back while a child process owns the tty.
      def self.capture_terminal_state
        @saved_terminal = `stty -g 2>/dev/null`.to_s.strip
        nil
      rescue StandardError
        @saved_terminal = ""
        nil
      end

      # Hand the terminal to another program (the external editor) and take
      # it back afterwards: alternate screen, raw mode, mouse tracking and
      # the keyboard protocol all belong to the TUI, and a full-screen
      # editor needs the main screen, cooked input and none of our key
      # modes in front of it. The caller has to invalidate the screen on
      # return, because the alternate screen comes back blank.
      def self.hand_over(output = $stdout)
        # Only a real terminal has a termios state to give back; writing to
        # a StringIO (tests, snapshots) must not touch the tty.
        saved = output.equal?($stdout) ? @saved_terminal.to_s : ""
        write_offline(output)
        ::TUI::Term.write(output, ::TUI::Term::SHOW_CURSOR + ::TUI::Term::ALT_OFF + ::TUI::Style::RESET)
        ::TUI::Term.flush(output)
        system("stty #{saved}") unless saved.empty?
        begin
          yield
        ensure
          system("stty raw -echo") unless saved.empty?
          ::TUI::Term.write(output, ::TUI::Term::ALT_ON + ::TUI::Term::CLEAR + ::TUI::Term::HIDE_CURSOR)
          ::TUI::Term.flush(output)
          write_online(output)
        end
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
