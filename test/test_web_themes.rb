# frozen_string_literal: true

require "test_helper"
require "rubot"
require_relative "support/web_channel_support"

module Rubot
  module Web
    # Colour themes: the palette, the switch between them and what a theme is allowed to change.
    class TestWebThemes < Minitest::Test
      include WebChannelSupport

      # --- reading the stylesheet -----------------------------------------

      # The size the prose is set in. Read once, so the tests below cannot
      # disagree about it — and refused outright when the sheet stops stating
      # it in px, rather than quietly comparing against `nil.to_f`, which is
      # zero and would let every "smaller than the prose" check pass.
      def prompt_size(css)
        size = css[/--prompt-size:\s*([\d.]+)px/, 1]
        refute_nil size, "the sheet has to state the prose size in px"
        size.to_f
      end

      # Every statement of the prose size, whichever unit it is written in. The
      # property name is what gets counted, not the px value: a media block that
      # restates `--prompt-size: 1rem` is the same second answer to the same
      # question, and a guard that matched only px read it as the one statement
      # it was looking for. A `var(--prompt-size)` reader does not match, because
      # it names the property without assigning it.
      def stated_sizes(css)
        css.scan(/^\s*--prompt-size\s*:/)
      end

      # The body of one rule, anchored to a selector that opens its own line.
      # A selector also appears in one-line rules — `.composer textarea {
      # grid-column: 1 / -1; }` sits above the real one — and an unanchored
      # capture runs on into the rule below, so a guard reads a property it was
      # never looking at and stays green while the rule it names loses it.
      def rule_body(css, selector)
        css[/^#{Regexp.escape(selector)} \{\n(.*?)\n\}/m, 1].to_s
      end

      # The body of every media block, found by counting braces rather than by
      # scanning for one rule's shape: a block that holds another is still read
      # whole, and a rule written in a nested block cannot fall outside the
      # guard by being one level deeper than the one it was written for.
      def media_bodies(css)
        bodies = []
        offset = 0
        while (open = css.match(/@media[^{]*\{/, offset))
          depth = 1
          cursor = open.end(0)
          while cursor < css.length && depth.positive?
            depth += 1 if css[cursor] == "{"
            depth -= 1 if css[cursor] == "}"
            cursor += 1
          end
          bodies << css[open.end(0)...(cursor - 1)]
          offset = open.end(0)
        end
        bodies
      end

      # --- themes ---------------------------------------------------------

      # The settings page as the reader gets it, for the tests about controls
      # that live there: the palette, the reading face, the notification toggle.

      # A theme is a list of names. A block that forgets one inherits it from
      # the default, which mixes two palettes: a light page with dark scrims,
      # or a green accent on a blue-grey one.
      def test_every_theme_defines_the_same_colours
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        blocks = %w[everforest dark light].map do |name|
          match = css.match(/:root\[data-theme="#{name}"\] \{(.*?)\n\}/m)
          refute_nil match, "theme #{name} needs its own block"
          match[1].scan(/--([\w-]+):/).flatten.sort
        end

        assert_equal blocks[0], blocks[1], "dark is missing names everforest sets"
        assert_equal blocks[0], blocks[2], "light is missing names everforest sets"
        assert_includes blocks[0], "scrim", "overlays have to follow the palette too"
        assert_includes blocks[0], "on-accent", "text on a filled button has to"
      end

      # The rows under the answer are set in the reader's face now, and that
      # face reads smaller than mono at the same number, so they sit close to
      # the prose. Close is the limit: a row that reaches --prompt-size stops
      # being a caption and argues with the reader's own words. One value for
      # the three rows, so a later bump cannot move one of them alone.
      def test_the_status_rows_stay_under_the_size_of_the_prose
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        prompt = prompt_size(css)
        row = css[/--row-size:\s*([\d.]+)px/, 1]
        refute_nil row, "a caption still has a size of its own"

        assert_operator row.to_f, :<, prompt, "a status row is not the size of the prompt"
        %w[.row .compaction-row .tool-row].each do |selector|
          body = rule_body(css, selector)
          refute_empty body, "#{selector} has to be drawn"
          assert_includes body, "font-size: var(--row-size)",
                          "#{selector} has to take the shared size, not a literal"
        end
      end

      # The field is where the reader writes, the thread is where they read it
      # back. Both used to carry their own number — 16.5px in the box, 17px in
      # the thread — so the same words changed size the moment they were sent,
      # and a phone dropped the field to a 16px literal on top of that. One
      # value now, and the phone is the surface that has to keep it: 16px is
      # also the size below which a phone zooms a focused field and moves the
      # page out from under the reader's thumb.
      def test_the_field_takes_the_size_of_the_prose_on_every_surface
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        prompt = prompt_size(css)
        assert_operator prompt, :>=, 16, "a phone zooms a field set below 16px"

        field = rule_body(css, ".composer textarea")
        refute_empty field, "the sheet has to draw the field"
        assert_includes field, "font-size: var(--prompt-size)",
                        "the field is the prose's size, not a number of its own"

        # One value means one. A media block that restates `--prompt-size` is a
        # second answer to the same question even when the number matches: the
        # value is then written twice, and the next edit can move one of them
        # alone. `.uniq` used to hide exactly that, so the count is of raw
        # statements — and of statements, not of px, since the same value as
        # `1rem` is the same drift.
        stated = stated_sizes(css)
        assert_equal 1, stated.size,
                     "the prose size is stated once, not overridden per surface"

        # The phone tightens the row a phone has less of, not the type: a size
        # written here is a second answer to the question above. Every textarea
        # rule inside a media block is read, not only the one in
        # `.composer-box` — the field's own `.composer textarea` restating the
        # size in the same block is the same drift, and naming one selector
        # let the other through.
        in_media = media_bodies(css).flat_map do |body|
          body.scan(/([^{}]*textarea[^{}]*)\{([^{}]*)\}/)
        end
        # A capture runs back to the closing brace of the rule above, so it
        # carries that rule's trailing comment and blank lines. The selector is
        # the last line of it.
        in_media = in_media.map { |selector, body| [ selector.lines.last.to_s.strip, body ] }
        assert(
          in_media.any? { |selector, _| selector == ".composer-box textarea" },
          "the phone block has to draw the field it shortens"
        )
        in_media.each do |selector, body|
          refute_includes body, "font-size",
                          "#{selector} does not restate the size of the field"
        end
      end

      # The count is of statements, not of one unit. A block that restates the
      # size as `1rem` used to pass a guard that only matched px, which is the
      # drift the guard claims to catch.
      def test_a_size_restated_in_another_unit_is_a_second_statement
        css = <<~CSS
          :root {
            --prompt-size: 16px;
          }
          @media (max-width: 40rem) {
            .composer textarea {
              --prompt-size: 1rem;
            }
          }
        CSS

        assert_equal 2, stated_sizes(css).size,
                     "a restatement in another unit is still a second answer"
      end

      # Reading the value is not stating it, or every `var(--prompt-size)` rule
      # would count as a second statement and the count could never reach one.
      def test_reading_the_size_is_not_stating_it
        css = <<~CSS
          :root {
            --prompt-size: 16px;
          }
          .thread { font-size: var(--prompt-size); }
        CSS

        assert_equal 1, stated_sizes(css).size
      end

      # A diff is a file's lines, not the reader's own words, so it sits under
      # the prose rather than beside it. The number is small on purpose: mono
      # reads larger than the reading face at the same size, which is why a
      # block that matched the prose's number would still come out bigger on
      # the page.
      def test_the_diff_stays_under_the_size_of_the_prose
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        prompt = prompt_size(css)
        block = rule_body(css, ".diff")
        refute_empty block, "the sheet has to draw a diff"

        diff = block[/font-size:\s*([\d.]+)px/, 1]
        refute_nil diff, "the diff block draws at a size of its own"
        assert_operator diff.to_f, :<, prompt, "a diff is not the size of the prose"
      end

      # A heading in an answer is the same prose, larger, so its ladder is a
      # set of ratios against the prose and not lengths of its own. In `rem` it
      # would measure against the browser's 16px instead, and the outline would
      # grow every time the prose came down — which is what happened when the
      # prose moved to 16px and every heading stayed at its pixel value.
      def test_a_heading_scales_with_the_prose_it_sits_in
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        %w[h1 h2 h3].each do |tag|
          rule = css[/^\.text #{tag} \{([^}]*)\}/, 1].to_s
          refute_empty rule, "the sheet sets the size of .text #{tag}"
          assert_match(/font-size: [\d.]+em/, rule,
                       "#{tag} takes its size from the prose, not from the page")
        end
      end

      # The theme is decided in the head, before the stylesheet can paint. Left
      # to a script at the end of the page, a light reader would get a dark
      # frame first — a flash across the whole screen. The reading face is the
      # same kind of choice and lands in the same place, or the paragraph
      # reflows once the real font arrives.
      def test_the_theme_and_the_face_are_set_before_the_first_paint
        html = View.render("layout", title: "x", content: "isi", asset_version: 1)
        script = html.index("rubot-theme")
        face = html.index("rubot-font")
        stylesheet = html.index("app.css")

        refute_nil script, "the head has to choose a theme"
        refute_nil face, "the head has to choose a face"
        assert script < stylesheet, "the choice must land before the stylesheet paints"
        assert face < stylesheet, "the face must land before the first paragraph is set"
        assert_includes html, %(setAttribute("data-theme", theme))
        assert_includes html, %(setAttribute("data-font", fonts.indexOf(font) >= 0 ? font : "serif")),
                        "an unknown name falls back to the serif, not to nothing"
        assert_includes html, "prefers-color-scheme",
                        "with no choice made, the system decides"
      end

      # Three palettes, one press each, each showing its own colours — a select
      # would hide two thirds of a choice that is meant to be looked at. The
      # picker is drawn by the settings page: a palette is chosen once, not
      # mid-conversation.
      def test_the_picker_offers_every_theme_as_its_own_button
        html = settings_page_html

        %w[everforest dark light].each do |name|
          assert_includes html, %(data-theme-choice="#{name}"),
                          "#{name} needs a button of its own"
        end
        assert_equal 3, html.scan("data-theme-choice=").size
        picker = html[/<div class="theme-picker".*?<\/div>/m].to_s
        assert_equal 3, picker.scan("aria-pressed=").size,
                     "the state has to be announceable, not just painted"
        assert_includes html, %(role="group")
      end

      # A face is offered the same way: one button per choice, each set in the
      # face it names so the control answers "what does this look like" before
      # it is pressed. The list lives in one place — the view draws the buttons
      # from it and the script validates against the same names, so a stored
      # choice cannot name a face nothing applies.
      def test_every_font_choice_is_a_button_set_in_its_own_face
        html = settings_page_html
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        offered = html.scan(/data-font-choice="([a-z]+)"/).flatten
        assert_equal offered.uniq, offered, "one button per face"
        assert_includes offered, "serif"
        assert_includes offered, "sans"
        assert_operator offered.size, :>=, 4, "more than two faces, or there is nothing to choose"

        picker = html[/<div class="font-picker".*?<\/div>/m].to_s
        assert_equal offered.size, picker.scan("aria-pressed=").size,
                     "the state has to be announceable, not just painted"

        # The button's own face, and the stack the choice applies.
        offered.each do |name|
          assert_match(/\.font-choice\[data-font-choice="#{name}"\] \{ font-family: var\(--/,
                       css, "#{name} has to be previewed in its own face")
        end

        # The script's list and the stylesheet's previews are the same set: the
        # page draws from View::FONT_CHOICES, so this also ties the buttons to
        # the names the script will accept.
        scripts = js[/const FONTS = \[(.*?)\];/m, 1].to_s.scan(/"([a-z]+)"/).flatten
        previews = css.scan(/\.font-choice\[data-font-choice="([a-z]+)"\]/).flatten
        assert_equal previews.sort, scripts.sort
        assert_equal offered.sort, scripts.sort
      end

      # The four stacks that are not the default each need their own block: a
      # name in `data-font` with no block is a choice that does nothing, and the
      # page would look untouched when it was pressed.
      def test_every_stored_face_changes_the_reading_stack
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        %w[sans mono georgia palatino].each do |name|
          block = css[/:root\[data-font="#{name}"\] \{[^}]*\}/]
          refute_nil block, "data-font=\"#{name}\" needs a block of its own"
          assert_includes block, "--reading:", "the block has to move the reading stack"
        end
      end

      # The chosen face reaches the small rows too. A tool call, a thought, the
      # working row and the compaction seam were mono whatever the reader
      # picked, and the model and the effort under the field are the same kind
      # of row: a mono sentence in the middle of a page set in Georgia reads as
      # two documents stapled together.
      def test_the_status_rows_take_the_face_the_reader_picked
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))

        %w[.row .tool-row .compaction-row .session-trigger .thinking-row-label].each do |selector|
          block = css[/^#{Regexp.escape(selector)} \{[^}]*\}/m]
          refute_nil block, "#{selector} needs a rule of its own"
          assert_includes block, "font-family: var(--reading)",
                          "#{selector} is read like the page, not set in a face of its own"
        end

        chips = css[/^\.thinking-chip span \{[^}]*\}/m]
        refute_nil chips, "the effort chips need a rule of their own"
        assert_includes chips, "font-family: var(--reading)",
                        "the level this session runs on is read, not decoded"

        # A declaration proves the face was asked for, not that the row is drawn
        # in it: a later rule naming the same element wins the cascade while the
        # block above stays green. So every rule that mentions a row is swept —
        # the model id and the level included, which carry no font of their own
        # and take the pill's.
        %w[.row .tool-row .compaction-row .session-trigger .session-trigger-model
           .session-trigger-thinking .thinking-row-label .thinking-chip].each do |selector|
          bodies = css.scan(/^[^\n{}]*#{Regexp.escape(selector)}[^{}]*\{([^}]*)\}/m).flatten
          refute_empty bodies, "nothing in the stylesheet sets #{selector}"

          mono = bodies.grep(/font-family:\s*var\(--mono\)/)
          assert_empty mono, "a rule puts #{selector} back in mono: #{mono.first}"
        end
      end

      # A face with proportional digits makes the clock shift the words beside
      # it once a second, so the row asks for figures that hold their width.
      def test_the_live_clock_asks_for_figures_that_hold_their_width
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        block = css[/^\.live-clock \{[^}]*\}/m]

        refute_nil block, "the clock needs a rule of its own"
        assert_includes block, "tabular-nums",
                        "the clock counts in place; a drifting box is a row that shakes"
      end

      # A choice is the reader's, on their own device: stored locally and never
      # sent to the server, so two people in one conversation keep their own.
      def test_a_theme_choice_is_kept_on_the_device
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, %(localStorage.setItem(THEME_KEY, theme))
        assert_includes js, %(localStorage.getItem(THEME_KEY))
        refute_match(/fetch\([^)]*theme/i, js, "the choice never goes to the server")
        assert_includes js, %(style.colorScheme), "native controls follow the theme too"

        # The face is stored the same way, for the same reason: it is this
        # device's, and a reader who moves to a laptop brings the palette too.
        assert_includes js, %(localStorage.setItem(FONT_KEY, font))
        assert_includes js, %(setAttribute("data-font", font))
      end

      # The notification toggle is a settings-page control. It says its own
      # state in words rather than being an unlabelled switch — "aktifkan",
      # "aktif", "diblokir" — because the permission may only be asked for on a
      # press, and a button that has not been pressed has to explain itself.
      def test_the_settings_page_carries_the_notification_toggle
        html = settings_page_html

        assert_includes html, "data-push-slug="
        assert_includes html, "data-push-toggle"
        assert_includes html, "data-push-label"
        assert_includes html, "data-push-test"
        assert_includes html, "/assets/app.js",
                        "the page has to load the script that wires the toggle"
      end

      # The three figures in the row are a glance; the panel is what the glance
      # is made of. Every one of them has to be spelled out, or opening the
      # panel answers nothing.
      def test_the_panel_spells_out_the_report_behind_the_row
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.usage_facts({
          model: "claude-sonnet-4", provider: "anthropic", messages: 42, requests: 17,
          prompt_tokens: 128_400, completion_tokens: 9_120, cached_tokens: 96_000,
          cache_hit_rate: 0.7477, cache_hit_rate_session: 0.9531,
          context_used: 41_200, context_window: 200_000,
          context_percent: 20.6,
          cost: { "total" => 0.0412, "input" => 0.0098, "cached_input" => 0.0028,
                  "cache_creation" => 0.0011, "output" => 0.0275 }
        })
        html = View.render("_usage_facts", **facts)

        assert_includes html, "claude-sonnet-4"
        assert_includes html, "$0.0412"
        assert_includes html, "128,400", "tokens are grouped, not a wall of digits"
        assert_includes html, "9,120"
        assert_includes html, "74.8%", "the cache share of the latest request"
        assert_includes html, "95.3%", "the session-wide share sits beside it"
        assert_includes html, Rubot::I18n.t("web.usage.facts.cache_shares",
                                            last: "74.8", session: "95.3", tokens: "96,000"),
                        "and says which one it is"
        assert_includes html, "41,200 / 200,000"
        assert_includes html,
                        Rubot::I18n.t("web.usage.facts.cost_cache_read",
                                      value: Rubot::UsageReport.money(0.0028)),
                        "the breakdown answers \"why this cost\""
      end

      # The panel is where a broken cache becomes visible. One figure cannot
      # tell a prefix that moves every request from a single cold request; the
      # run of zeros can, and that is what turns "cache 4%?" into an answer.
      def test_the_panel_shows_the_cache_share_of_each_recent_request
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.usage_facts({
          model: "m", provider: "openai", messages: 4, requests: 4,
          prompt_tokens: 4_000, completion_tokens: 40, cached_tokens: 90,
          cache_hit_rate: 0.0, cache_hit_rate_session: 0.0225,
          cache_history: [ 0.0, 0.0, 0.0, 0.09 ],
          context_used: 900, context_window: 128_000, context_percent: 0.7,
          cost: { "total" => 0.01 }
        })
        html = View.render("_usage_facts", **facts)

        assert_includes html, Rubot::I18n.t("web.usage.facts.cache_history")
        assert_includes html, "0% 0% 0% 9%", "oldest first, so the shape is readable"
        assert_includes html, CGI.escapeHTML(Rubot::I18n.t("web.usage.facts.cache_history_title")),
                        "the line explains what a run of zeros means"
      end

      # One request is not a history, and a panel row holding a single number
      # would repeat the line above it.
      def test_the_panel_omits_the_history_row_until_there_is_one
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.usage_facts({
          model: "m", provider: "openai", messages: 1, requests: 1,
          prompt_tokens: 100, completion_tokens: 10, cached_tokens: 0,
          cache_hit_rate: 0.0, cache_hit_rate_session: 0.0, cache_history: [ 0.0 ],
          context_used: 100, context_window: 128_000, context_percent: 0.1,
          cost: { "total" => 0.001 }
        })
        html = View.render("_usage_facts", **facts)

        refute_includes html, Rubot::I18n.t("web.usage.facts.cache_history")
      end

      # A launch has spent nothing and knows nothing yet. It says so rather
      # than printing a confident $0.00 over a conversation no request has
      # touched.
      def test_the_panel_admits_an_empty_report
        channel = Rubot::Channels::Web.new(channel_config: {})
        html = View.render("_usage_facts", **channel.usage_facts({}))

        assert_includes html, Rubot::I18n.t("web.usage.facts.unknown")
        assert_includes html, %(id="usage-facts")
        refute_includes html, "$0.0000"
      end

      # The cause of a miss is a log line, not a row: the panel answers "how
      # much did this cost", and a verdict on the cache in the middle of the
      # figures reads as an error even when nothing is wrong.
      def test_the_panel_never_names_the_cause_of_a_miss
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.usage_facts({
          model: "m", provider: "anthropic", messages: 4, requests: 4,
          prompt_tokens: 4_000, completion_tokens: 40, cached_tokens: 0,
          cache_hit_rate: 0.0, cache_hit_rate_session: 0.0,
          cache_cause: :trim_boundary,
          context_used: 900, context_window: 128_000, context_percent: 0.7,
          cost: { "total" => 0.01 }
        })
        html = View.render("_usage_facts", **facts)

        refute_includes html, "sebab miss"
        refute_includes html, "jendela history terpotong"
      end

      # The panel is where the money is explained: what the last request paid
      # in full, and what the cache kept from being spent.
      def test_the_panel_says_what_was_re_read_and_what_the_cache_saved
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.usage_facts({
          model: "m", provider: "openai", messages: 4, requests: 4,
          prompt_tokens: 100_000, completion_tokens: 400, cached_tokens: 87_600,
          cache_hit_rate: 0.876, cache_hit_rate_session: 0.9,
          last_re_read_tokens: 12_400,
          context_used: 900, context_window: 128_000, context_percent: 0.7,
          cost: { "total" => 0.0412, "input" => 0.0017, "cached_input" => 0.0004,
                  "cache_creation" => 0.0, "output" => 0.000_2, "saved" => 0.0153 }
        })
        html = View.render("_usage_facts", **facts)

        assert_includes html, Rubot::I18n.t("web.usage.facts.reread")
        assert_includes html, "12,400"
        assert_includes html, Rubot::I18n.t("web.usage.facts.saved")
        assert_includes html, "$0.0153"
      end

      # A rate the catalog does not have is priced at the input rate, which is
      # an upper bound. The panel says so rather than rounding the doubt away.
      def test_the_panel_marks_a_cost_that_is_only_an_upper_bound
        channel = Rubot::Channels::Web.new(channel_config: {})
        facts = channel.usage_facts({
          model: "m", provider: "google", messages: 1, requests: 1,
          prompt_tokens: 1_000, completion_tokens: 10, cached_tokens: 0,
          context_used: 900, context_window: 128_000, context_percent: 0.7,
          cost: { "total" => 0.4, "input" => 0.4, "cached_input" => 0.0,
                  "cache_creation" => 0.0, "output" => 0.0, "cache_price_unknown" => true }
        })
        html = View.render("_usage_facts", **facts)

        assert_includes html, "≤"
        refute_includes html, Rubot::I18n.t("web.usage.facts.saved")
      end

      # The panel lives inside the page from the first paint — it is a
      # Two panels, both `<details>` so neither needs a request to open. The
      # facts ride along with the page; the allowance does not, because it
      # belongs to the account rather than the session.
      def test_the_facts_panel_is_in_the_page_and_waits_for_nothing
        html = render_page
        sheet = html[/<details class="usage-sheet usage-sheet-facts".*?<\/details>/m]

        refute_nil sheet, "the status row needs its way into the report"
        assert_includes sheet, %(id="usage-facts")
        refute_includes sheet, "hx-get", "the facts are drawn with the page"
        assert html.index("usage-sheet-facts") > html.index(%(id="usage")),
               "the button sits at the end of the row it expands"
      end

      # The allowance used to sit three rows down inside the report sheet. It is
      # the reading a reader comes back to most often, so it has its own button,
      # and the fetch waits for the press.
      def test_the_allowance_has_a_panel_of_its_own_that_fetches_on_open
        html = render_page
        sheet = html[/<details class="usage-sheet usage-sheet-quota".*?<\/details>/m]

        refute_nil sheet, "the allowance needs a way in of its own"
        assert_includes sheet, %(hx-get="/s/web_rubot/quota")
        assert_includes sheet, %(hx-target="#usage-quota")
        assert_includes sheet, "toggle[this.open]",
                        "the allowance costs a request, so it waits for the reader"
        refute_includes sheet, "usage-facts", "the report does not come with the allowance"
        assert html.index("usage-sheet-quota") > html.index("usage-sheet-facts"),
               "the allowance is the outer of the two buttons"
      end

      # Both panels hang upward out of the same spot, so two open at once would
      # be one on top of the other. Opening either closes the other.
      def test_only_one_status_panel_is_open_at_a_time
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, ".status-line details.usage-sheet[open]"
        assert_includes js, 'document.addEventListener("toggle"'
        assert_includes js, "closeStatusPanels"
      end

      # A meter says two things: what is spent, and when the window comes back.
      # A provider that already cut the account off says that too.
      def test_the_quota_draws_one_meter_per_allowance
        channel = Rubot::Channels::Web.new(channel_config: {})
        meters = channel.quota_meters({ "rolling" => { "percent" => 12.5,
                                               "resets_at" => (Time.now + 3600).utc.iso8601 },
                                "monthly" => { "percent" => 100.0, "limited" => true } })
        html = View.render("_quota", meters: meters, note: "")

        assert_equal 2, meters.size, "only the windows the provider reported"
        assert_includes html, Rubot::I18n.t("web.quota.meters.rolling"),
                        "the provider's window, in the reader's words"
        assert_includes html, Rubot::I18n.t("web.quota.used", percent: "12.5")
        assert_includes html, %(style="width: 12.5%")
        assert_includes html, "is-limited", "an allowance that is gone is not green"
        assert_includes html, Rubot::I18n.t("web.quota.reset_in", when: "").strip
      end

      # The panel is about the account's allowances only. The context window
      # belongs to the session and has its own reading in the report sheet, so
      # it must not show up as a meter here.
      def test_the_quota_shows_only_the_provider_allowances
        channel = Rubot::Channels::Web.new(channel_config: {})
        meters = channel.quota_meters({ "rolling" => { "percent" => 12.5 } })

        assert_equal 1, meters.size
        refute_equal "Konteks", meters.first[:name]
      end

      # The provider reports the share that is spent, and the bar has always
      # been drawn as that share. The figure beside it counted down instead —
      # so a quarter gone read "75% sisa" next to a bar a quarter full. Both
      # now say the same thing.
      def test_the_quota_counts_what_is_spent_not_what_is_left
        channel = Rubot::Channels::Web.new(channel_config: {})
        html = View.render("_quota",
                           meters: channel.quota_meters({ "rolling" => { "percent" => 25.0 } }),
                           note: "")

        assert_includes html, Rubot::I18n.t("web.quota.used", percent: "25.0")
        refute_includes html, Rubot::I18n.t("web.quota.used", percent: "75.0"),
                        "the panel counts towards the limit, not away from it"
      end

      # The bar is coloured by how much of the allowance is gone: quiet while
      # there is room, warm past half, hot near the limit. The figure stays
      # exact either way — the colour is the second reading, not the only one.
      def test_the_quota_colours_the_bar_by_how_much_is_spent
        channel = Rubot::Channels::Web.new(channel_config: {})
        bands = ->(percent) { channel.quota_meters({ "rolling" => { "percent" => percent } }).first[:band] }

        assert_equal "calm", bands.call(12.5)
        assert_equal "calm", bands.call(49.9)
        assert_equal "warm", bands.call(50.0)
        assert_equal "warm", bands.call(79.9)
        assert_equal "hot", bands.call(80.0)
        assert_equal "hot", bands.call(100.0)

        html = View.render("_quota", meters: channel.quota_meters({ "weekly" => { "percent" => 62.0 } }), note: "")
        assert_includes html, "usage-meter is-warm", "the class the colour hangs on"
        assert_includes html, Rubot::I18n.t("web.quota.used", percent: "62.0"),
                        "the number is still there to be read"
      end

      # A provider that sells tokens by the drink has no allowance at all. That
      # is not a failure, and it must not be drawn as an empty box.
      def test_a_provider_without_an_allowance_says_so_in_one_sentence
        channel = Rubot::Channels::Web.new(channel_config: {})

        html = View.render("_quota", meters: channel.quota_meters({ unavailable: true }),
                                              note: channel.quota_note({ unavailable: true }))

        refute_includes html, "usage-meters"
        assert_includes html, Rubot::I18n.t("web.quota.unavailable")

        error = View.render("_quota", meters: [], note: channel.quota_note({ error: "HTTP 500" }))
        assert_includes error, Rubot::I18n.t("web.quota.error", error: "HTTP 500")
      end

      # The panel's facts ride along with the row: a reader watching an open
      # panel during a turn must not see the row move while the breakdown
      # under it stands still.
      def test_the_live_report_refreshes_the_panel_as_well_as_the_row
        channel = Rubot::Channels::Web.new(channel_config: {})
        report = { cost: { "total" => 0.5 }, requests: 3, prompt_tokens: 5000,
                   completion_tokens: 900, cached_tokens: 4000, cache_hit_rate: 0.8,
                   context_percent: 12.0, context_window: 100_000, context_used: 12_000 }

        markup = channel.usage_markup_from(report)

        assert_equal 2, markup.scan(%(hx-swap-oob="true")).size,
                     "the row and the facts both swap out of band"
        assert_includes markup, %(id="usage-facts" hx-swap-oob="true")
        assert_includes markup, "12,000 / 100,000"
        refute_includes markup, "masuk 0", "a breakdown of zeros explains nothing"
      end

      # A persona form asks for three fields and a prompt; a popover beside the
      # rail is too small to write in. It is a dialog in the middle of the
      # screen, with the page dimmed behind it.
      def test_the_new_persona_form_opens_as_a_dialog_in_the_middle
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        rule = css[/^\.rail-panel \{[^}]*\}/]

        refute_nil rule, "the .rail-panel rule is missing from app.css"
        assert_equal "fixed", rule[/position:\s*(\w+)/, 1]
        assert_match(/top:\s*50%/, rule)
        assert_match(/left:\s*50%/, rule)
        assert_match(/translate\(-50%,\s*-50%\)/, rule,
                     "the dialog has to be centred on its own box, not its corner")
        assert_match(/rail-new\[open\]::before \{[^}]*position: fixed/m, css,
                     "an open dialog dims the page behind it")
        assert_match(/side-edit\[open\]::before \{[^}]*position: fixed/m, css,
                     "the edit dialog dims it the same way")
      end

      # Dragging the corner of the prompt used to resize the whole dialog and
      # push the fields under it around. It grows with its text instead.
      def test_the_prompt_field_cannot_be_dragged_open
        css = File.read(File.expand_path("../lib/rubot/web/assets/app.css", __dir__))
        rule = css[/^\.rail-panel input,\n\.rail-panel select,\n\.rail-panel textarea \{[^}]*\}/]

        refute_nil rule, "the field rule is missing from app.css"
        assert_match(/resize:\s*none/, rule)
      end

      # The dimmed page is a way out: a click on it, or Escape, closes the
      # dialog. Without that the only close button is the one it covered. Both
      # persona dialogs — the new one in the rail, the edit one in the sidebar
      # — are the same mechanism, so both have to be wired.
      def test_the_persona_dialog_can_be_dismissed_from_the_page_behind_it
        js = File.read(File.expand_path("../lib/rubot/web/assets/app.js", __dir__))

        assert_includes js, %(details.rail-new[open])
        assert_includes js, %(details.side-edit[open])
        assert_includes js, "open.open = false"
        assert_includes js, %(event.key !== "Escape")
      end

      # A persona that already exists had no way to change its name, face or
      # prompt: the only form on the page made a new one. The edit form writes
      # the same record in place.
      def test_a_persona_can_be_edited_in_place
        created = "2026-01-02T03:04:05Z"
        channel = channel_with_sessions(
          personas: {
            "kanyaah" => { "slug" => "kanyaah", "name" => "Kanyaah", "emoji" => "🧠",
                           "preset" => "primary", "system_prompt" => "Lama",
                           "created_at" => created }
          },
          sessions: { "web_kanyaah" => "Halo" }
        )

        res = FakeResponse.new
        channel.edit_persona(edit_request(
                                      "name" => "Kanyaah ID", "emoji" => "✍️",
                                      "system_prompt" => "Baru", "session_id" => "web_kanyaah"
                                    ), res, "kanyaah")

        persona = channel.send(:persona_store)["kanyaah"]

        assert_equal "Kanyaah ID", persona.name
        assert_equal "✍️", persona.emoji
        assert_equal "Baru", persona.system_prompt
        assert_equal "primary", persona.preset, "the model is not one of the form's fields"
        assert_equal created, persona.created_at, "the roster is ordered by creation time"
        assert_equal 303, res.status
        assert_equal "/s/web_kanyaah", res.headers["Location"],
                     "the editor lands back on the conversation it was opened from"
      end

      # Emptying the prompt is how a persona goes back to the default voice:
      # the field means "no prompt of my own", not "keep the old one".
      def test_clearing_the_prompt_gives_the_persona_the_default_voice
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah", "emoji" => "🧠",
                                     "system_prompt" => "Lama" } }
        )

        channel.edit_persona(edit_request("name" => "", "emoji" => "",
                                                 "system_prompt" => ""),
                     FakeResponse.new, "kanyaah")

        persona = channel.send(:persona_store)["kanyaah"]

        assert_nil persona.system_prompt
        assert_nil persona.name, "an emptied name falls back to the slug"
        assert_equal "🧠", persona.emoji, "an empty face keeps the one it had"
      end

      # An id from another persona must not send the editor into a conversation
      # it does not own; the persona's own page is the safe landing.
      def test_an_edit_ignores_a_session_id_that_belongs_to_someone_else
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah" },
                      "rubot" => { "name" => "Rubot" } }
        )

        res = FakeResponse.new
        channel.edit_persona(edit_request("name" => "Kanyaah", "session_id" => "web_rubot"),
                     res, "kanyaah")

        assert_equal "/p/kanyaah", res.headers["Location"]
      end

      def test_editing_a_persona_that_does_not_exist_is_not_found
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })

        res = FakeResponse.new
        channel.edit_persona(edit_request("name" => "Hilang"), res, "hilang")

        assert_equal 404, res.status
      end

      # The picker is drawn from the directory the agent loads, so the form and
      # a session can never disagree about which skills exist.
      def test_the_persona_form_lists_every_installed_skill_switched_on
        channel = channel_with_skills(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          skills: { "writing" => "Menulis rapi", "opencode-usage" => "Cek kuota" }
        )

        choices = channel.persona_skill_choices(channel.send(:persona_store)["kanyaah"])

        assert_equal %w[opencode-usage writing], choices.map { |choice| choice[:name] }.sort
        assert choices.all? { |choice| choice[:enabled] }, "a new persona starts with every skill on"
        assert_equal [ "Cek kuota", "Menulis rapi" ],
                     choices.map { |choice| choice[:description] },
                     "the box shows the skill's own summary, not its folder name"
      end

      # What the persona switched off comes back unticked, and a skill it
      # requires is marked as one it cannot switch off from here.
      def test_the_picker_shows_what_the_persona_left_on
        channel = channel_with_skills(
          personas: { "kanyaah" => { "name" => "Kanyaah", "skills" => "writing",
                                     "disabled_skills" => "opencode-usage" } },
          skills: { "writing" => "Menulis rapi", "opencode-usage" => "Cek kuota" }
        )

        choices = channel.persona_skill_choices(channel.send(:persona_store)["kanyaah"]).to_h do |choice|
          [ choice[:name], choice ]
        end

        assert choices["writing"][:enabled]
        assert choices["writing"][:required], "an allow-listed skill is required, so it is not a switch"
        refute choices["opencode-usage"][:enabled]
        refute choices["opencode-usage"][:required]
      end

      # The partial is the form's half of the contract: every skill gets a box,
      # the hidden marker says the list arrived, and a required skill is drawn
      # checked and locked.
      def test_the_picker_renders_a_box_per_skill
        html = View.render(
          "_skill_picker",
          skill_choices: [
            { name: "writing", description: "Menulis rapi", enabled: true, required: true },
            { name: "opencode-usage", description: "Cek kuota", enabled: false, required: false }
          ],
          skills_dir: "~/.rubot/skills"
        )

        assert_includes html, %(name="skills_present" value="1")
        assert_includes html, %(name="skill" value="writing")
        assert_includes html, %(name="skill" value="opencode-usage")
        assert_match(/value="writing"\s+checked\s+disabled/, html, "a required skill is on and locked")
        assert_includes html, "writing#{Rubot::I18n.t("web.skills.required")}",
                        "the box says why it cannot be unticked"
      end

      def test_the_picker_says_so_when_no_skill_is_installed
        html = View.render("_skill_picker", skill_choices: [], skills_dir: "~/.rubot/skills")

        assert_includes html, Rubot::I18n.t("web.skills.empty")
        assert_includes html, %(name="skills_present" value="1"),
                       "an empty list still arrives as a choice, not as an absent form field"
      end

      # A form that posts no list is another editor of the same record, not a
      # persona that switched everything off.
      def test_a_form_without_a_list_keeps_the_skills_it_had
        channel = channel_with_skills(
          personas: { "kanyaah" => { "name" => "Kanyaah", "disabled_skills" => "opencode-usage" } },
          skills: { "writing" => "Menulis rapi", "opencode-usage" => "Cek kuota" }
        )

        channel.edit_persona(edit_request("name" => "Kanyaah"), FakeResponse.new, "kanyaah")

        assert_equal %w[opencode-usage], channel.send(:persona_store)["kanyaah"].disabled_skills
      end

      def test_unticking_a_skill_switches_it_off_for_that_persona
        channel = channel_with_skills(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          skills: { "writing" => "Menulis rapi", "opencode-usage" => "Cek kuota" }
        )

        channel.edit_persona(persona_form_request("/p/kanyaah/edit",
                                                        "name" => "Kanyaah",
                                                        "skills_present" => "1",
                                                        "skill" => "writing"),
                     FakeResponse.new, "kanyaah")

        assert_equal %w[opencode-usage], channel.send(:persona_store)["kanyaah"].disabled_skills
      end

      # Every box empty posts no `skill` at all — the whole list is the
      # exceptions, which is what the marker is there to say out loud.
      def test_unticking_every_skill_switches_them_all_off
        channel = channel_with_skills(
          personas: { "kanyaah" => { "name" => "Kanyaah" } },
          skills: { "writing" => "Menulis rapi", "opencode-usage" => "Cek kuota" }
        )

        channel.edit_persona(persona_form_request("/p/kanyaah/edit",
                                                        "name" => "Kanyaah",
                                                        "skills_present" => "1"),
                     FakeResponse.new, "kanyaah")

        assert_equal %w[opencode-usage writing], channel.send(:persona_store)["kanyaah"].disabled_skills.sort
      end

      # A required skill is locked in the form, so it must not end up in the
      # exceptions just because no box was sent for it.
      def test_a_required_skill_is_never_written_as_switched_off
        channel = channel_with_skills(
          personas: { "kanyaah" => { "name" => "Kanyaah", "skills" => "writing" } },
          skills: { "writing" => "Menulis rapi", "opencode-usage" => "Cek kuota" }
        )

        channel.edit_persona(persona_form_request("/p/kanyaah/edit",
                                                        "name" => "Kanyaah",
                                                        "skills_present" => "1",
                                                        "skill" => "opencode-usage"),
                     FakeResponse.new, "kanyaah")

        assert_empty channel.send(:persona_store)["kanyaah"].disabled_skills
      end

      # Both persona forms offer the choice: the empty "Persona baru" panel and
      # the edit panel of an existing persona. One partial draws it, so the two
      # cannot end up listing different modes.
      def test_both_persona_forms_offer_every_mode
        html = render_page(persona_tool_output: "compact")

        selects = html.scan(%r{<select name="tool_output".*?</select>}m)

        assert_equal 2, selects.size
        selects.each do |select|
          assert_includes select, 'value="verbose"'
          assert_includes select, 'value="compact"'
        end
        # The new-persona panel is the first of the two and starts on the
        # default; the edit panel starts on what the persona already runs on.
        assert_includes selects.first, '<option value="verbose" selected>'
        assert_includes selects.last, '<option value="compact" selected>'
      end

      # The persona form is where the mode is chosen; saving it is what the
      # live turn and every replayed page then read.
      def test_the_persona_form_saves_the_tool_output_mode
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })

        channel.edit_persona(edit_request("name" => "Kanyaah", "tool_output" => "compact"),
                     FakeResponse.new, "kanyaah")

        assert_equal "compact", channel.send(:persona_store)["kanyaah"].tool_output
      end

      # A form posted by an older page has no such field. That is not a request
      # for the default: it is a form that does not know about the setting.
      def test_a_form_without_the_mode_keeps_the_one_the_persona_had
        channel = channel_with_sessions(
          personas: { "kanyaah" => { "name" => "Kanyaah", "tool_output" => "compact" } }
        )

        channel.edit_persona(edit_request("name" => "Kanyaah"), FakeResponse.new, "kanyaah")

        assert_equal "compact", channel.send(:persona_store)["kanyaah"].tool_output
      end

      def test_a_mode_no_picker_can_produce_is_not_a_third_mode
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })

        channel.edit_persona(edit_request("name" => "Kanyaah", "tool_output" => "ringkas"),
                     FakeResponse.new, "kanyaah")

        assert_equal "verbose", channel.send(:persona_store)["kanyaah"].tool_output
      end

      # A new persona can be born in the mode instead of being edited twice.
      def test_a_new_persona_can_be_created_compact
        channel = channel_with_sessions(personas: {})

        res = FakeResponse.new
        channel.create_persona(persona_form_request("/personas", "slug" => "kanyaah",
                                                                         "name" => "Kanyaah",
                                                                         "tool_output" => "compact"), res)

        assert_equal 303, res.status
        assert_equal "compact", channel.send(:persona_store)["kanyaah"].tool_output
      end

      def test_a_new_persona_can_be_created_with_a_skill_switched_off
        channel = channel_with_skills(skills: { "writing" => "Menulis rapi",
                                                "opencode-usage" => "Cek kuota" })

        res = FakeResponse.new
        channel.create_persona(persona_form_request("/personas",
                                                           "slug" => "kanyaah",
                                                           "name" => "Kanyaah",
                                                           "skills_present" => "1",
                                                           "skill" => "writing"), res)

        persona = channel.send(:persona_store)["kanyaah"]

        assert_equal 303, res.status
        assert_equal %w[opencode-usage], persona.disabled_skills
      end

      # A form POST as WEBrick hands it over. The repeated `skill` keys survive
      # only in the raw body, which is why it is built here rather than as a
      # plain hash.

      # A channel over a throwaway ~/.rubot that also has skills installed. The
      # picker reads the shared directory, so the test owns a catalog of its own
      # instead of the one on this machine.

      # The settings page and its form are two routes, and both have to exist:
      # a page nobody can reach and a form that posts into the 404 handler look
      # identical from inside a template.
      def test_the_settings_routes_reach_their_handlers
        channel = channel_with_archive(personas: { "rubot" => { "name" => "Rubot" } },
                                       messages: { "web_rubot" => [ %w[user halo] ] })

        page = FakeResponse.new
        channel.send(:dispatch, FakeRequest.new("/settings"), page)
        assert_equal 200, page.status
        assert_includes page.body, Rubot::I18n.t("web.settings.heading")

        saved = FakeResponse.new
        post = FakeRequest.new("/settings", method: "POST",
                                           query: { "provider" => "ollama", "default_model" => "llama3" })
        channel.send(:dispatch, post, saved)
        assert_equal 303, saved.status
        assert_equal "ollama", Rubot::Session.store.setting("provider")
      end

      # The form's action is a route like any other, so the page it was written
      # into and the handler behind it have to agree on the path.
      def test_the_edit_form_posts_to_a_route_that_reaches_the_handler
        channel = channel_with_sessions(personas: { "kanyaah" => { "name" => "Kanyaah" } })
        request = Object.new
        request.define_singleton_method(:path) { "/p/kanyaah/edit" }
        request.define_singleton_method(:request_method) { "POST" }
        request.define_singleton_method(:query) { { "name" => "Kanyaah Baru" } }
        request.define_singleton_method(:[]) { |_key| nil }

        channel.send(:dispatch, request, FakeResponse.new)

        assert_equal "Kanyaah Baru", channel.send(:persona_store)["kanyaah"].name
      end

      # The dialog has to open with what is already saved, or saving would
      # overwrite a prompt with an empty field.
      def test_the_edit_dialog_arrives_with_what_is_already_saved
        html = render_page(persona_prompt: "Kamu spesialis undangan.")

        assert_includes html, %(class="side-edit")
        assert_includes html, %(hx-post="/p/rubot/edit")
        assert_includes html, "Kamu spesialis undangan."
        assert_includes html, %(name="session_id" value="web_rubot")
        assert_includes html, %(class="panel-hint"), "the slug is shown, not asked for"
      end


      def test_form_value_is_forced_to_utf8
        channel = Rubot::Channels::Web.new(channel_config: {})
        req = Object.new
        query = { "emoji" => "\xF0\x9F\xA7\xAA".b, "name" => "Uji Coba".b }
        req.define_singleton_method(:query) { query }

        assert_equal "🧪", channel.send(:form, req, "emoji")
        assert_equal Encoding::UTF_8, channel.send(:form, req, "name").encoding
        assert_equal "", channel.send(:form, req, "missing")
      end

      # WEBrick parses only the body of a form POST, so a URL that carries
      # `?token=` — which is what every link the page writes does — has to
      # authenticate on the query string. The sidebar's "+" button depends on
      # this: it submits before the page has had a chance to set a cookie.
      def test_a_post_authenticates_with_the_token_in_the_query_string
        channel = Rubot::Channels::Web.new(channel_config: { "token" => "t0k" })
        request = Struct.new(:query_string, :query, :cookies)

        assert channel.send(:authorized?, request.new("token=t0k", {}, []))
        refute channel.send(:authorized?, request.new("token=nope", {}, []))
        refute channel.send(:authorized?, request.new("", {}, []))
      end
    end
  end
end
