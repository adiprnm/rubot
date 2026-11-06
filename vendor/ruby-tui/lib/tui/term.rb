# frozen_string_literal: true
#
# Term -- the terminal backend: size, raw mode, alternate screen and key
# reading. No widget knows it exists; it is used by TUI::App only.

require 'io/console'
require_relative 'event'

module TUI
  module Term
    ESC = "\e"
    CSI = "\e["

    CLEAR       = "#{CSI}2J"
    HIDE_CURSOR = "#{CSI}?25l"
    SHOW_CURSOR = "#{CSI}?25h"
    ALT_ON      = "#{CSI}?1049h"
    ALT_OFF     = "#{CSI}?1049l"
    # DEC 2026: present everything between these as one atomic frame.
    SYNC_ON     = "#{CSI}?2026h".freeze
    SYNC_OFF    = "#{CSI}?2026l".freeze

    ZERO_WIDTH = [0x0300..0x036F, 0x200B..0x200F, 0xFE00..0xFE0F].freeze
    WIDE = [
      0x1100..0x115F, 0x2E80..0x303E, 0x3041..0x33FF, 0x3400..0x4DBF,
      0x4E00..0x9FFF, 0xA000..0xA4CF, 0xAC00..0xD7A3, 0xF900..0xFAFF,
      0xFE30..0xFE6F, 0xFF00..0xFF60, 0xFFE0..0xFFE6,
      0x1F300..0x1F64F, 0x1F900..0x1F9FF, 0x20000..0x3FFFD
    ].freeze

    SEQUENCES = {
      "\e[A" => :up,    "\e[B" => :down,
      "\e[C" => :right, "\e[D" => :left,
      "\e[H" => :home,  "\e[F" => :end,
      "\e[1~" => :home, "\e[4~" => :end,
      "\e[2~" => :insert, "\e[3~" => :delete,
      "\e[5~" => :page_up, "\e[6~" => :page_down,
      "\e[Z" => :backtab,
      # function keys, both the xterm (ESC O x) and console (ESC [ nn~) forms
      # shift+enter: kitty keyboard protocol, xterm modifyOtherKeys, and
      # the escape-prefixed-enter fallback used by other terminals
      "\e[13;2u" => :shift_enter, "\e[27;2u" => :shift_enter,
      "\e\r" => :shift_enter, "\e\n" => :shift_enter,
      "\eOP" => :f1, "\eOQ" => :f2, "\eOR" => :f3, "\eOS" => :f4,
      "\e[11~" => :f1, "\e[12~" => :f2, "\e[13~" => :f3, "\e[14~" => :f4,
      "\e[15~" => :f5, "\e[17~" => :f6, "\e[18~" => :f7, "\e[19~" => :f8,
      "\e[20~" => :f9, "\e[21~" => :f10, "\e[23~" => :f11, "\e[24~" => :f12,
      "OA" => :up, "OB" => :down, "OC" => :right, "OD" => :left,
      "OH" => :home, "OF" => :end
    }.freeze

    WIDTH_CACHE = {}

    class << self
      # --- geometry -----------------------------------------------------

      def size
        rows, cols = begin
          $stdout.tty? ? $stdout.winsize : nil
        rescue SystemCallError, IOError
          nil
        end

        cols = cols.to_i
        rows = rows.to_i
        cols = ENV['COLUMNS'].to_i if cols <= 0
        rows = ENV['LINES'].to_i   if rows <= 0
        cols = 80 if cols <= 0
        rows = 24 if rows <= 0
        [cols, rows]
      end

      def codepoint_width(cp)
        WIDTH_CACHE[cp] ||= begin
          if ZERO_WIDTH.any? { |r| r.cover?(cp) } then 0
          elsif WIDE.any? { |r| r.cover?(cp) }   then 2
          else 1
          end
        end
      end

      def width(ch)
        codepoint_width(ch.ord)
      end

      def text_width(str)
        total = 0
        str.to_s.split('').each { |ch| total += width(ch) }
        total
      end

      # Write to an output that may be $stdout or a StringIO. Spinel only
      # lowers IO#print when the receiver is statically an IO, so route the
      # real terminal through $stdout explicitly and fall back to the dynamic
      # call (StringIO, a File, ...) otherwise.
      def write(output, str)
        if output.equal?($stdout)
          $stdout.print(str)
        else
          output.print(str)
        end
        nil
      end

      def flush(output)
        if output.equal?($stdout)
          $stdout.flush
        else
          output.flush
        end
        nil
      end

      # --- session ------------------------------------------------------

      # Enter the alternate screen and raw mode. Yields, then restores the
      # terminal no matter what happens inside.
      #
      # Raw mode goes through `stty` rather than IO#raw: Spinel's io/console
      # only implements IO#winsize, and IO#ioctl is not available either, so
      # saving/restoring the tty via stty is the portable path.
      def session(output = $stdout, _input = $stdin)
        write(output, ALT_ON + HIDE_CURSOR + CLEAR)
        flush(output)
        saved = raw_mode_on
        begin
          yield
        ensure
          raw_mode_off(saved)
          write(output, SHOW_CURSOR + ALT_OFF + Style::RESET)
          flush(output)
        end
        nil
      end

      # Switch the tty to raw mode. Returns the saved stty state, or nil when
      # there is no tty (or no stty), in which case the session runs without
      # raw mode instead of failing.
      def raw_mode_on
        saved = `stty -g 2>/dev/null`.to_s.strip
        return nil if saved.empty?

        system('stty raw -echo')
        saved
      end

      def raw_mode_off(saved)
        return if saved.nil?

        system("stty #{saved}")
        nil
      end

      # --- input --------------------------------------------------------

      # Reads one key. Returns nil when nothing arrives within `timeout`.
      #
      # Note: deliberately not IO#getch, which on Ruby 2.6 re-toggles the
      # terminal mode per call and silently drops keystrokes.
      def read_key(timeout = 0.0)
        return nil unless IO.select([$stdin], nil, nil, timeout)

        ch = read_char
        return nil if ch.nil?

        case ch
        when ESC            then read_escape
        when "\r", "\n"     then Key.new(:enter)
        when "\t"           then Key.new(:tab)
        when "\u007F", "\b" then Key.new(:backspace)
        when "\u0003"       then Key.new(:ctrl_c)
        when "\u0004"       then Key.new(:ctrl_d)
        when "\u001A"       then Key.new(:ctrl_z)
        else Key.printable(ch)
        end
      rescue Interrupt
        Key.new(:ctrl_c)
      end

      # One character, plus UTF-8 continuation bytes when needed.
      def read_char
        first = $stdin.read_nonblock(1)
        return nil if first.nil?

        bytes = first.dup.force_encoding(Encoding::BINARY)
        lead = bytes.getbyte(0)
        if lead && lead >= 0xC0
          need = lead < 0xE0 ? 1 : (lead < 0xF0 ? 2 : 3)
          catch(:enough) do
            need.times do
              throw :enough unless IO.select([$stdin], nil, nil, 0.01)
              more = $stdin.read_nonblock(1)
              throw :enough if more.nil?
              bytes << more.force_encoding(Encoding::BINARY)
            end
          end
        end

        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        utf8.valid_encoding? ? utf8 : bytes
      rescue IO::WaitReadable, Errno::EAGAIN, Errno::EINTR, EOFError, IOError
        nil
      end

      def read_escape
        buf = +ESC
        deadline = 0.03
        # An SGR mouse report is at most "ESC [ < " + button + three digits
        # each for column and row + modifiers + final byte, so 24 bytes is
        # enough to never truncate one (a smaller cap drops the final byte on
        # wide/tall terminals and the report parses as :unknown).
        while buf.bytesize < 24 && IO.select([$stdin], nil, nil, deadline)
          c = read_char
          break if c.nil? || c.empty?
          buf << c
          break if buf.bytesize > 2 && c =~ /[A-Za-z~]/
          deadline = 0.005
        end
        return Key.new(:escape) if buf.bytesize == 1

        # SGR mouse report: button;col;row with a final M (press/motion)
        # or m (release). Button codes: 0..2 buttons, +32 drag motion,
        # +64 wheel steps, +4/+8/+16 modifier bits (shift/alt/ctrl).
        mouse = buf.match(/\A\e\[<(\d+);(\d+);(\d+)([Mm])\z/)
        return mouse_key(Regexp.last_match) if mouse

        Key.new(SEQUENCES[buf] || :unknown)
      end

      # Normalise an SGR mouse report into a named Key with cell coords.
      # Release events keep :mouse_release so apps can finalise drags;
      # other buttons and modifier-only steps surface as :unknown.
      def mouse_key(m)
        raw, col, row, kind = m[1].to_i, m[2].to_i, m[3].to_i, m[4]
        button = raw & 3
        kind_flag = raw & ~0x1C

        name =
          if kind == "m"
            :mouse_release
          elsif raw >= 64
            raw.odd? ? :wheel_down : :wheel_up
          elsif (raw & 32) != 0
            :mouse_drag
          else
            :mouse_press
          end

        key = Key.new(name)
        key.at(col - 1, row - 1, button: button)
      end

      def move(row, col)
        "#{CSI}#{row + 1};#{col + 1}H"
      end
    end
  end
end
