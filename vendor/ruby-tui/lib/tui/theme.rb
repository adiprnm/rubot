# frozen_string_literal: true
#
# Theme -- the semantic style names components ask for.
#
# Components never hardcode a colour; they use names like :border, :selection
# or :danger. Swap the whole look by installing a different theme, or tweak
# single styles:
#
#   TUI::Theme.style(:accent, fg: 170, bold: true)

require_relative 'style'

module TUI
  module Theme
    PALETTE = {
      bg:        234,
      border:    238,
      border_hi: 244,
      track:     236,
      thumb:     245,
      text:      252,
      dim:       245,
      muted:     240,
      title:     231,
      # Kept for re-skins; the default theme does not use them (see below).
      accent:    51,
      accent2:   141,
      good:      84,
      warn:      220,
      bad:       203,
      sel_bg:    237,
      sel_fg:    231
    }.freeze

    # name => style opts
    DARK = {
      text:          { fg: PALETTE[:text] },
      muted:         { fg: PALETTE[:muted] },
      dim:           { fg: PALETTE[:dim] },
      title:         { fg: PALETTE[:title], bold: true },
      subtitle:      { fg: PALETTE[:dim], bold: true },

      # The accent is deliberately hueless: it inherits whatever foreground
      # the terminal is using and only goes bold, so the chrome never fights
      # the colour scheme you are running. Put a colour back with
      #   TUI::Theme.style(:accent, fg: TUI::Theme::PALETTE[:accent], bold: true)
      accent:        { bold: true },
      label:         { fg: PALETTE[:muted] },
      value:         { fg: PALETTE[:text] },
      success:       { fg: PALETTE[:good] },
      warning:       { fg: PALETTE[:warn] },
      danger:        { fg: PALETTE[:bad] },
      error:         { fg: PALETTE[:bad], bold: true },
      hint:          { fg: PALETTE[:muted] },

      # `bg: :default` lifts the terminal background back over the style, so
      # a filled run just before the edge cannot bleed into the border.
      border:        { fg: PALETTE[:border], bg: :default },
      border_focus:  { fg: PALETTE[:border_hi], bg: :default },
      track:         { fg: PALETTE[:track] },
      grid:          { fg: PALETTE[:muted], dim: true },
      thumb:         { fg: PALETTE[:thumb] },

      selection:     { fg: PALETTE[:sel_fg], bg: PALETTE[:sel_bg], bold: true },
      selection_dim: { fg: PALETTE[:dim], bg: PALETTE[:sel_bg] },
      # A cursor is a "here" marker, not a highlight: reverse video stays
      # neutral on any palette (and never fights the accent colour).
      cursor:        { reverse: true },

      tab_active:    { bold: true },
      tab_inactive:  { fg: PALETTE[:dim] },
      header:        { fg: PALETTE[:muted] },

      # Text fields carry no colour of their own: the value uses the
      # terminal's default foreground, the placeholder only goes faint and
      # the cursor only reverses. Nothing inside a text field can fight
      # whatever colours the terminal (or its theme) is running.
      field:         {},
      placeholder:   { dim: true },

      # While a field is empty it shows a hint, and the "cursor" over that
      # hint is just an underline: nothing paints a background over the
      # placeholder, so it stays transparent.
      cursor_placeholder: { underline: true }
    }.freeze

    # A completely hueless variant: no colour codes at all, only attributes
    # (bold / dim / reverse). Use it when the terminal's own theme should
    # decide every colour:
    #
    #   TUI::Theme.install(:plain)
    #
    # Status colours stay, because there the colour is information.
    PLAIN = {
      text: {}, value: {}, field: {},
      title: { bold: true }, subtitle: { bold: true }, accent: { bold: true },
      tab_active: { bold: true }, border_focus: { bold: true, bg: :default },
      thumb: { bold: true },
      muted: { dim: true }, dim: { dim: true }, hint: { dim: true },
      label: { dim: true }, header: { dim: true }, tab_inactive: { dim: true },
      placeholder: { dim: true }, border: { dim: true, bg: :default }, track: { dim: true },
      cursor_placeholder: { underline: true },
      grid: { dim: true }, selection_dim: { reverse: true },
      selection: { reverse: true }, cursor: { reverse: true },
      success: DARK[:success], warning: DARK[:warning],
      danger: DARK[:danger], error: DARK[:error]
    }.freeze

    # Everforest (dark) -- the exact palette omarchy ships as its
    # "everforest" theme (themes/everforest/colors.toml upstream), written
    # as truecolor hex so the TUI lands on the same colours as the editor
    # and terminal instead of an xterm approximation.
    EVERFOREST_PALETTE = {
      bg:        "#2d353b",
      bg_dim:    "#232a2e",
      bg1:       "#343f44",
      border:    "#4f585e",
      border_hi: "#859289",
      track:     "#3d484d",
      thumb:     "#9da9a0",
      text:      "#d3c6aa",
      dim:       "#9da9a0",
      muted:     "#859289",
      title:     "#d3c6aa",
      accent:    "#7fbbb3",
      accent2:   "#a7c080",
      good:      "#a7c080",
      warn:      "#dbbc7f",
      bad:       "#e67e80",
      sel_bg:    "#3d484d",
      sel_fg:    "#d3c6aa"
    }.freeze

    # Same semantic names as DARK, painted with the everforest palette. The
    # accent keeps its colour here (blue, then green as a secondary) because
    # everforest has one worth showing.
    EVERFOREST = {
      text:          { fg: EVERFOREST_PALETTE[:text] },
      muted:         { fg: EVERFOREST_PALETTE[:muted] },
      dim:           { fg: EVERFOREST_PALETTE[:dim] },
      title:         { fg: EVERFOREST_PALETTE[:title], bold: true },
      subtitle:      { fg: EVERFOREST_PALETTE[:dim], bold: true },

      accent:        { fg: EVERFOREST_PALETTE[:accent], bold: true },
      label:         { fg: EVERFOREST_PALETTE[:muted] },
      value:         { fg: EVERFOREST_PALETTE[:text] },
      success:       { fg: EVERFOREST_PALETTE[:good] },
      warning:       { fg: EVERFOREST_PALETTE[:warn] },
      danger:        { fg: EVERFOREST_PALETTE[:bad] },
      error:         { fg: EVERFOREST_PALETTE[:bad], bold: true },
      hint:          { fg: EVERFOREST_PALETTE[:muted] },

      border:        { fg: EVERFOREST_PALETTE[:border], bg: :default },
      border_focus:  { fg: EVERFOREST_PALETTE[:border_hi], bg: :default },
      track:         { fg: EVERFOREST_PALETTE[:track] },
      grid:          { fg: EVERFOREST_PALETTE[:muted], dim: true },
      thumb:         { fg: EVERFOREST_PALETTE[:thumb] },

      selection:     { fg: EVERFOREST_PALETTE[:sel_fg], bg: EVERFOREST_PALETTE[:sel_bg], bold: true },
      selection_dim: { fg: EVERFOREST_PALETTE[:dim], bg: EVERFOREST_PALETTE[:sel_bg] },
      cursor:        { reverse: true },

      tab_active:    { bold: true },
      tab_inactive:  { fg: EVERFOREST_PALETTE[:dim] },
      header:        { fg: EVERFOREST_PALETTE[:muted] },

      field:         {},
      placeholder:   { dim: true },
      cursor_placeholder: { underline: true }
    }.freeze

    # Kept at module level, not inside `class << self`: Spinel resolves
    # constants defined in a singleton class as nil, so the lookup below
    # would see THEMES as nil.
    THEMES = { dark: DARK, plain: PLAIN, everforest: EVERFOREST }.freeze

    class << self
      # Install a theme. :dark is the default, :plain uses no colours at all,
      # :everforest paints the omarchy "everforest" palette.
      def install(name = :dark)
        name = name.to_sym if name.respond_to?(:to_sym)
        styles = THEMES[name]
        raise ArgumentError, "unknown theme #{name.inspect} (have: #{THEMES.keys.join(', ')})" unless styles

        styles.each { |style_name, opts| Style.define(style_name, opts) }
        self
      end

      def themes
        THEMES.keys
      end

      # Override a single style, e.g. Theme.style(:accent, fg: 170).
      def style(name, **opts)
        Style.define(name, opts)
      end
    end
  end
end

TUI::Theme.install(:dark)
