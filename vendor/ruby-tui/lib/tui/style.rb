# frozen_string_literal: true
#
# Style -- the styling mechanism.
#
# A style is either a registered Symbol (:text, :border, ...) or a raw SGR
# string, so components can paint gradients without registering a colour per
# cell. Canvases store styles as small Integers (see Style.id) and turn them
# back into escape codes when a row is composed.

module TUI
  module Style
    RESET = "\e[0m"

    # Teal -> green -> amber -> red, used by anything that shows a value.
    RAMP = [51, 50, 49, 48, 47, 46, 82, 118, 154, 190, 226, 220, 214, 208, 202, 196].freeze

    class << self
      # Raw SGR escapes, usable directly as a style value.
      def fg(n)
        "\e[38;5;#{n}m"
      end

      def bg(n)
        "\e[48;5;#{n}m"
      end

      # Colour from the shared ramp for t in 0.0..1.0. The escape is
      # memoised, so repeated calls hand out the same String object and
      # Style.id can hit its cache by identity.
      def ramp(t)
        i = (t.clamp(0.0, 1.0) * (RAMP.length - 1)).round
        @ramp ||= Array.new(RAMP.length) { |k| fg(RAMP[k]) }
        @ramp[i]
      end

      def define(name, opts)
        @defs ||= {}
        @cache ||= {}
        @defs[name] = opts
        @cache.delete(name)
        @ids = {}
        @last_style = nil
      end

      def defined?(name)
        @defs ||= {}
        @defs.key?(name)
      end

      def names
        (@defs || {}).keys
      end

      # A style value -> SGR escape string.
      def resolve(style)
        return RESET if style.nil?
        return style if style.is_a?(String)

        @cache ||= {}
        @cache[style] ||= build(style)
      end

      # Styles are stored per cell as integers. 0 means "no style".
      def id(style)
        return 0 if style.nil?
        return @last_id if style.equal?(@last_style)

        @ids ||= {}
        @sgr ||= [RESET]
        cached = @ids[style]
        unless cached
          @sgr << resolve(style)
          cached = @sgr.length - 1
          @ids[style] = cached
        end
        @last_style = style
        @last_id = cached
      end

      def sgr(id)
        @sgr ||= [RESET]
        @sgr[id] || RESET
      end

      private

      def build(name)
        @defs ||= {}
        opts = @defs[name]
        unless opts
          raise ArgumentError,
                "unknown style #{name.inspect} (known: #{names.sort.join(', ')})"
        end

        codes = []
        codes << '1' if opts[:bold]
        codes << '2' if opts[:dim]
        codes << '3' if opts[:italic]
        codes << '4' if opts[:underline]
        codes << '7' if opts[:reverse]
        codes << color_code('38', opts[:fg]) if colour?(opts[:fg])
        codes << color_code('48', opts[:bg]) if colour?(opts[:bg])
        # `bg: :default` paints the terminal's own background back on, which
        # keeps a filled run from bleeding into a chrome run that follows it
        # (see the border style).
        codes << '49' if opts[:bg] == :default
        codes.empty? ? RESET : "\e[#{codes.join(';')}m"
      end

      # A colour is either an xterm-256 index (Integer) or a "#rrggbb"
      # String, which is emitted as truecolor. That lets a theme use the
      # exact palette of the running terminal colour scheme instead of an
      # xterm approximation of it.
      def colour?(value)
        value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A#\h{6}\z/))
      end

      def color_code(prefix, value)
        if value.is_a?(String) && (m = value.match(/\A#(\h{2})(\h{2})(\h{2})\z/))
          "#{prefix};2;#{m[1].to_i(16)};#{m[2].to_i(16)};#{m[3].to_i(16)}"
        else
          "#{prefix};5;#{value}"
        end
      end
    end
  end
end
