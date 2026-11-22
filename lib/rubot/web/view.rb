# frozen_string_literal: true

require "cgi"
require "erb"

require_relative "format"

module Rubot
  module Web
    # Tiny ERB renderer. Views live next to the channel, locals become methods
    # on the rendering scope, and compiled templates are cached per process.
    module View
      ROOT = File.expand_path("views", __dir__)

      ICONS = {
        ok: "✓",
        failed: "✗",
        unknown: "·"
      }.freeze

      # The status row is drawn with inline SVG rather than glyphs: Martian
      # Mono carries only ASCII and a handful of symbols, so a symbol like ⟳ or
      # ⊙ was silently borrowed from whatever fallback font the reader's
      # system happened to supply — differently on every machine.
      #
      # 10×10, stroke only, currentColor, so they inherit the row's colour and
      # none of them carries a fill of its own.
      SVG_ICONS = {
        cost: %(<circle cx="5" cy="5" r="3.4"/>) +
              %(<path d="M5 2.6v4.8"/>),
        cache: %(<path d="M2 5a3 3 0 0 1 5.1-1.1"/>) +
               %(<path d="M7.4 1.9v2.2H5.2"/>) +
               %(<path d="M8 5a3 3 0 0 1-5.1 1.1"/>) +
               %(<path d="M2.6 8.1V5.9h2.2"/>),
        context: %(<path d="M1.6 7.4V5.2"/>) +
                 %(<path d="M5 7.4V2"/> ) +
                 %(<path d="M8.4 7.4V3.6"/>),
        # The button that opens the whole report. It used to be three bars, which
        # is the context mark redrawn a fraction of a millimetre away — two
        # different things asking to be read as one. A card with two lines says
        # "there is more written down in here".
        usage: %(<rect x="1.5" y="1.6" width="7" height="6.8" rx="1.1"/>) +
               %(<path d="M3.3 4h3.4"/>) +
               %(<path d="M3.3 6.1h2.1"/>),
        # Delegated work. Three marks over one line, because a delegation is
        # several agents answering to one conversation — and it must not read as
        # the report card or the meter two slots away.
        subagent: %(<circle cx="2.4" cy="6.6" r="1.1"/>) +
                  %(<circle cx="5" cy="3.4" r="1.1"/>) +
                  %(<circle cx="7.6" cy="6.6" r="1.1"/>) +
                  %(<path d="M2.4 8.4h5.2"/>),
        # The allowance. A dial rather than the card above: an allowance is a
        # share of a limit, so the shape that says "meter" is the one an
        # instrument panel taught everyone to read — an arc with a needle in
        # it, not another page of numbers.
        quota: %(<path d="M1.7 7.5a3.3 3.3 0 0 1 6.6 0"/>) +
               %(<path d="M5 7.5 6.5 4.8"/>),
        # The footer button that asks for a compaction now. Three lines closing
        # in on the middle, so it reads as "make this smaller" next to the
        # meter and the card the other two toggles wear.
        compact: %(<path d="M1.5 2.5h7"/>) +
                 %(<path d="M2.5 5h5"/>) +
                 %(<path d="M3.5 7.5h3"/>)
      }.freeze

      # The round marks are drawn for the same reason: ◌ and ◐ are a fallback
      # font's business, so the ring changed weight and rode low or high beside
      # "Thinking…" depending on the system that painted it. An SVG in a square
      # box is the same size everywhere and centres by construction (see
      # `.row .mark`), which is what a mark beside a line of text has to do.
      #
      # The shape is the same ring with a gap in it, on a 10px grid. The circle
      # is r=3.5, so one turn is 2πr ≈ 22 units — a 15-unit stroke leaves a
      # 7-unit gap, and CSS turns the whole mark once a second. The three-quarter
      # arc is what makes a rotation legible: a full ring spinning looks exactly
      # like a ring sitting still, which is the thing the mark was replacing.
      def self.spinner_mark(class_names)
        %(<svg class="#{class_names}" viewBox="0 0 10 10" fill="none" stroke="currentColor" ) +
          %(stroke-width="1.2" stroke-linecap="round" aria-hidden="true" focusable="false">) +
          %(<circle cx="5" cy="5" r="3.5" stroke-dasharray="15 7"/></svg>)
      end

      # A drawn ring means "this is turning", so a drawn ring that is not turning
      # reads as a spinner that stopped — which is why the thought does not get
      # one. The half disc is a *state*, not a rotation: the mark the working row
      # wore before the spinner, and the one piece of the row that can sit still
      # beside a label that is already moving. "Thought for 12s" keeps its dashed
      # arc, and a live row that is working spins.
      MARKS = {
        think: "◐",
        working: spinner_mark("mark-svg spin").freeze,
        running: spinner_mark("mark-svg spin").freeze,
        thought: %(<svg class="mark-svg" viewBox="0 0 10 10" fill="none" stroke="currentColor" ) +
                 %(stroke-width="1.2" stroke-linecap="round" aria-hidden="true" focusable="false">) +
                 %(<circle cx="5" cy="5" r="3.5" stroke-dasharray="1.7 1.5"/></svg>).freeze,
        # A seam in the transcript: two pages folding into one. Drawn rather
        # than typed so the mark keeps the same weight as the other row marks.
        compaction: %(<svg class="mark-svg" viewBox="0 0 10 10" fill="none" stroke="currentColor" ) +
                    %(stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" ) +
                    %(aria-hidden="true" focusable="false">) +
                    %(<path d="M1.5 2.5h3l1 5h3"/><path d="M7 6l1.5 1.5L7 9"/></svg>).freeze
      }.freeze

      # The reading faces the settings page offers, in the order they are drawn.
      #
      # `value` is the string <html data-font> carries and the one app.js
      # validates against; the stack behind each name lives in app.css, so a
      # name and a block there are the pair that has to stay in step. Two of
      # these are the device's own fonts — on a phone without Georgia the
      # button still works, it just sets the text in the serif it falls back to.
      FONT_CHOICES = [
        { value: "serif", label: "Serif",
          title: "Bawaan: Source Serif 4, dengan Charter dan Georgia sebagai cadangan" },
        { value: "sans", label: "Sans serif",
          title: "Huruf sistem tanpa kait: Segoe UI, Roboto, atau SF di perangkat Apple" },
        { value: "mono", label: "Mono",
          title: "Martian Mono, huruf berjarak tetap yang dipakai nama mesin" },
        { value: "georgia", label: "Georgia",
          title: "Georgia milik perangkat, dengan Times sebagai cadangan" },
        { value: "palatino", label: "Palatino",
          title: "Palatino milik perangkat, dengan serif sistem sebagai cadangan" }
      ].freeze

      class Scope
        def initialize(locals)
          locals.each { |key, value| define_singleton_method(key) { value } }
        end

        # The count the drawer's handle wears. A page drawn outside the channel
        # — a test, or any caller with no roster to count — has nothing waiting;
        # the channel passes the real number and its singleton method wins.
        def unread_total
          0
        end

        # The faces the persona forms offer. Same reason as the count above: a
        # page drawn outside the channel still has to draw a whole form, and the
        # roster is the persona's own, not the channel's.
        def emoji_choices
          Persona::EMOJI_CHOICES
        end

        def h(text)
          CGI.escapeHTML(text.to_s)
        end

        def fmt(text)
          Format.markdown(text, quotable: true)
        end

        # A prompt is rendered as markdown too — the same parser, so a list in a
        # message reads as a list instead of as a run of asterisks — but without
        # the quote mark: that control hands a paragraph back to the composer,
        # and a prompt is already the composer's own words. The paragraph rules
        # are shared; only the mark is left out.
        def fmt_prompt(text)
          Format.markdown(text, quotable: false)
        end

        def icon(state)
          ICONS.fetch(state, "·")
        end

        # A drawn mark for the two rows whose glyph was a ring: the thought and
        # the turn that is still running. The state rows keep their glyphs —
        # ✓ and ✗ sit on the baseline where every mono font puts them.
        def mark(kind)
          MARKS.fetch(kind, "")
        end

        # The pin on a sidebar row. Drawn rather than written: 📌 is whatever
        # emoji font the reader has, at whatever weight, and this button has to
        # line up with the × beside it. One stroke, currentColor, so it takes
        # the row's colour — filled when the conversation is pinned, outlined
        # when it is not.
        def pin_icon(pinned: false)
          fill = pinned ? "currentColor" : "none"
          %(<svg class="pin-icon" viewBox="0 0 24 24" width="11" height="11" ) +
            %(fill="#{fill}" stroke="currentColor" stroke-width="1.8" ) +
            %(stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" ) +
            %(focusable="false"><path d="M9 3h6l-1 6 3 3v2H7v-2l3-3z"/>) +
            %(<path d="M12 14v7"/></svg>)
        end

        # A tool row's mark. A call that is open gets the same turning arc as the
        # rows above it instead of the half disc, which was a fallback font's
        # shape. The ring is the row's only motion: a sweep across the whole row
        # was tried beside it and taken out, because two things saying "still
        # running" in the same 16px is one of them too many.
        def state_mark(state)
          state == :running ? MARKS[:running] : icon(state)
        end

        # The way into the archive. A drawn magnifier rather than an emoji: an
        # emoji is whatever picture the system font happens to carry, so it
        # changes shape and weight per machine next to a button that is otherwise
        # the same everywhere. 12×12, stroke only, currentColor, so it takes the
        # button's colour the way the status row's marks do.
        def search_icon
          %(<svg class="search-icon" viewBox="0 0 12 12" width="12" height="12" fill="none" ) +
            %(stroke="currentColor" stroke-width="1.3" stroke-linecap="round" aria-hidden="true" ) +
            %(focusable="false"><circle cx="5.2" cy="5.2" r="3.3"/><path d="M7.7 7.7 10.5 10.5"/></svg>)
        end

        # The mark on a PDF card. A filled badge with the three letters, drawn
        # rather than left to an emoji font: the red is the one every reader
        # already knows as "PDF", and the letters take the theme's contrasting
        # colour so both light and dark stay legible. Decorative — the link's
        # own aria-label says what the file is.
        def pdf_icon
          %(<svg class="pdf-icon" viewBox="0 0 24 24" width="18" height="18" ) +
            %(aria-hidden="true" focusable="false">) +
            %(<rect class="pdf-icon-bg" x="2" y="4" width="20" height="16" rx="3"/>) +
            %(<text class="pdf-icon-text" x="12" y="15.6" text-anchor="middle" ) +
            %(font-family="Arial, Helvetica, sans-serif" font-size="7.5" font-weight="700">PDF</text></svg>)
        end

        # A 10px stroked mark. Decorative: the row's title carries the meaning,
        # so the drawing is hidden from a screen reader.
        def usage_icon(name)          body = SVG_ICONS.fetch(name, "")
          %(<svg class="metric-icon" viewBox="0 0 10 10" width="10" height="10" ) +
            %(fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" ) +
            %(stroke-linejoin="round" aria-hidden="true" focusable="false">#{body}</svg>)
        end

        def dur(seconds)
          Format.duration(seconds)
        end

        # A label drawn one letter per span, each carrying its own index, so the
        # glow can travel from the first letter to the last and start over. The
        # index is a custom property rather than a per-letter delay: the timing
        # belongs in the stylesheet with the rest of the motion, and a page read
        # without it still shows the whole word.
        def glow(text)
          text.to_s.each_char.with_index.map do |char, index|
            %(<span style="--i:#{index}">#{CGI.escapeHTML(char)}</span>)
          end.join
        end

        # The turn body is rendered from Ruby rather than through a nested
        # partial call in ERB, so the template only ever says "draw the
        # timeline up to here".
        def timeline(turn)
          token = respond_to?(:token_query) ? token_query.to_s : ""
          accounts = respond_to?(:ig_accounts) ? ig_accounts : []
          linkable = respond_to?(:ig_linkable_accounts) ? ig_linkable_accounts : []
          persona = respond_to?(:ig_persona) ? ig_persona.to_s : ""
          View.turn_body(turn, token_query: token, ig_accounts: accounts,
                              ig_linkable_accounts: linkable, ig_persona: persona)
        end

        # A partial rendered by a test has no files unless the caller passes
        # them, and `_attachments` should not have to spell that out.
        def attachments
          []
        end

        # A partial rendered by a test has no sub-agent list to pass; the
        # working band still draws without one.
        # The footer's panel is drawn from the background runs the channel
        # knows about. A page rendered outside the channel has none.
        def subagent_runs
          []
        end

        # The connect card defaults to no linked accounts when a caller (a
        # test, or a page outside the channel) has no Instagram status to pass.
        # The channel's own locals override this.
        def ig_accounts
          []
        end

        def ig_linkable_accounts
          []
        end

        def ig_persona
          ""
        end

        # The option list every model picker on the settings page shares. It is
        # here because six pickers repeated the same three cases: the catalogue,
        # a blank entry for "follow the default", and the current value even
        # when the catalogue no longer lists it — an install pinned to a model
        # its provider stopped advertising must not move to whichever name
        # happens to be first just because the page was opened and saved.
        def model_option_tags(choices, selected, blank: nil)
          current = selected.to_s
          out = +""
          out << %(<option value="">#{CGI.escapeHTML(blank)}</option>) unless blank.nil?
          choices.each do |choice|
            value = choice[:value].to_s
            out << %(<option value="#{CGI.escapeHTML(value)}"#{value == current ? " selected" : ""}>)
            out << CGI.escapeHTML(choice[:label].to_s)
            out << "</option>"
          end
          if !current.empty? && choices.none? { |choice| choice[:value].to_s == current }
            out << %(<option value="#{CGI.escapeHTML(current)}" selected>#{CGI.escapeHTML(current)}</option>)
          end
          out
        end

        # The face list is the view's own, not the channel's: a settings page
        # drawn by a test still has to offer every choice. The names are also
        # what app.js accepts, so there is one list rather than two.
        def font_choices
          View::FONT_CHOICES
        end

        # The persona a device-wide control speaks for — the notification test
        # button is addressed to one. Outside the channel there is none to name.
        def push_persona
          ""
        end

        def token_query
          ""
        end

        def context
          binding
        end
      end

      @cache = {}
      @mutex = Mutex.new

      class << self
        def render(name, locals = {})
          template = compiled(name)
          template.result(Scope.new(locals).context)
        end

        # The body of a live turn: everything it has done, and nothing else.
        # The row that says the turn is still running is not part of it — it
        # lives in the band above the composer, so the timeline stays a record
        # of the work rather than a place the last row keeps sliding down.
        def turn_body(turn, token_query: "", ig_accounts: [], ig_linkable_accounts: [], ig_persona: "")
          render("_timeline", items: turn.items, token_query: token_query,
                              ig_accounts: ig_accounts, ig_linkable_accounts: ig_linkable_accounts,
                              ig_persona: ig_persona)
        end

        # A block of prose, rendered exactly as a turn's text is. The report that
        # is written while the reader watches replaces this and nothing else: the
        # entry around it carries the animation that plays when a turn arrives,
        # and re-creating it on every passage made the answer blink instead of
        # grow.
        def prose(text)
          Format.markdown(text.to_s, quotable: true)
        end

        private

        def compiled(name)
          @mutex.synchronize do
            @cache[name] ||= begin
              path = File.join(ROOT, "#{name}.erb")
              ERB.new(File.read(path), trim_mode: "-")
            end
          end
        end
      end
    end
  end
end
