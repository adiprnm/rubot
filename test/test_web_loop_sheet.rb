# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

require "rubot/web/loops"

# The footer's loop panel: which loops it draws, what a card says, and the two
# states around it — hidden while nothing runs, polling only while it is open.
#
# Everything is read from real state files under a temporary workspace, because
# the panel's whole job is to describe what a loop has written down: a fake row
# would test the template against itself.
class TestWebLoopSheet < Minitest::Test
  # As much channel as these methods need: the module reaches its state through
  # `self`, and a workspace is one directory.
  class Harness
    include Rubot::Web::Loops

    # What the channel would have written to the page. A panel that only
    # appears on the next reload is the bug this records against.
    attr_reader :pushed

    def initialize(base:)
      @base = base
      @pushed = []
    end

    def workspace_for_session(_sid) = @base
    def owner_slug(_sid) = "implementer"
    def token_query = "?token=t"
    def push_to_session(_sid, type, markup) = @pushed << [ type, markup ]
  end

  def setup
    @base = Dir.mktmpdir("rubot-web-loop-sheet")
    @store = Rubot::LoopStore.new(dir: File.join(@base, "loops"))
    @harness = Harness.new(base: @base)
  end

  def teardown
    FileUtils.remove_entry(@base) if File.exist?(@base)
    Rubot::I18n.locale = Rubot::I18n::DEFAULT_LOCALE
  end

  # A loop in the workspace, with the numbers under test.
  def loop_state(goal: "make the demo honest", max_tokens: 12_000_000, max_iterations: 3, status: nil)
    state = @store.create(goal: goal, done_criteria: "the demo test is green",
                          repo: @base, max_iterations: max_iterations, max_tokens: max_tokens)
    @store.update(state.id) do |loop|
      loop.iterations = 2
      loop.tokens = 8_400_000
      loop.status = status if status
    end
    @store.load(state.id)
  end

  def sheet(loops)
    Rubot::Web::View.render("_loop_sheet", loops: loops,
                                            session_id: "web_rubot", token_query: "?token=t")
  end

  # -- what a card says ------------------------------------------------------

  # The two figures a reader opens this panel for: how far the loop got, and
  # what is left of its budget. Everything else a card used to carry was one of
  # these facts said twice, or a word about the panel itself.
  def test_an_active_loop_states_its_iterations_and_remaining_budget
    state = loop_state
    rows = @harness.loop_rows("web_rubot")

    assert_equal 1, rows.size
    html = Rubot::Web::View.render("_loop_rows", loops: rows)

    assert_includes html, "make the demo honest"
    assert_includes html, "2/3 iterations"
    assert_includes html, "3,600,000 of 12,000,000 left"

    refute_includes html, state.id, "the card names a loop the reader already asked for"
    refute_includes html, "tokens used", "spent and left are the same fact"
    refute_includes html, "updated", "a clock on a panel nobody leaves open"
  end

  # The turn that crosses the line can be charged past the budget, and a
  # negative "left" is the one number a reader would have to stop and decode.
  def test_remaining_budget_never_goes_negative
    state = @store.create(goal: "spend it all", done_criteria: "done", repo: @base, max_tokens: 1_000)
    @store.update(state.id) { |loop| loop.tokens = 2_500 }

    row = @harness.loop_rows("web_rubot").first

    assert_equal 0, row[:remaining]
    assert_includes Rubot::Web::View.render("_loop_rows", loops: [ row ]), "0 of 1,000 left"
  end

  # The panel is about work in flight. A paused loop is the reader's own doing
  # and a finished one said so in the transcript, so neither belongs here.
  def test_a_paused_loop_is_not_drawn
    loop_state(goal: "still running")
    paused = loop_state(goal: "waiting for me", status: "paused")

    rows = @harness.loop_rows("web_rubot")

    assert_equal 1, rows.size
    assert_includes Rubot::Web::View.render("_loop_rows", loops: rows), "still running"
    refute_includes Rubot::Web::View.render("_loop_rows", loops: rows), paused.goal
  end

  # -- the sheet around it ---------------------------------------------------

  # A conversation that never started a loop gets no control for one.
  def test_the_toggle_is_hidden_while_nothing_runs
    html = sheet([])

    assert_includes html, %(id="loop-sheet" hidden)
    assert_includes html, "No loop running."
  end

  def test_the_toggle_is_shown_when_a_loop_is_active
    loop_state
    rows = @harness.loop_rows("web_rubot")

    refute_includes sheet(rows), %(id="loop-sheet" hidden)
  end

  # The panel asks for its rows again because a loop's progress is a file on
  # disk, and only while it is open: a timer behind a closed sheet would be one
  # request every three seconds for nothing.
  def test_the_body_polls_only_while_the_sheet_is_open
    html = sheet(@harness.loop_rows("web_rubot"))

    assert_includes html, 'hx-get="/s/web_rubot/loops?token=t"'
    assert_includes html, %(hx-trigger="every 3s [this.closest('details').open]")
    assert_includes html, 'hx-swap="innerHTML"'
  end

  # -- the route ------------------------------------------------------------

  # The same partial the page drew, so the poll can never describe a loop in
  # words the panel around it does not use.
  def test_the_poll_answers_with_the_same_rows
    loop_state

    assert_equal Rubot::Web::View.render("_loop_rows", loops: @harness.loop_rows("web_rubot")),
                 @harness.loop_rows_markup("web_rubot")
  end

  def test_the_poll_answers_with_the_empty_sentence_when_nothing_runs
    assert_includes @harness.loop_rows_markup("web_rubot"), "No loop running."
  end

  # A workspace with no loop folder at all is not an error: it is a
  # conversation that never started one.
  def test_a_missing_loops_folder_answers_with_no_rows
    empty = Harness.new(base: File.join(@base, "nowhere"))

    assert_equal [], empty.loop_rows("web_rubot")
  end

  # -- words ----------------------------------------------------------------

  # Both languages, and the one that is not the process default.
  def test_the_panel_speaks_the_chosen_language
    rows = [ { goal: "make the demo honest", iterations: 2,
              max_iterations: 3, max_tokens: 12_000_000,
              remaining: 3_600_000, age_seconds: 125 } ]

    en = Rubot::Web::View.render("_loop_rows", loops: rows)
    Rubot::I18n.locale = "id"
    id = Rubot::Web::View.render("_loop_rows", loops: rows)

    assert_includes en, "3,600,000 of 12,000,000 left"
    assert_includes id, "sisa 3,600,000 dari 12,000,000"
    assert_includes id, "2/3 iterasi"

    assert_equal [], Rubot::I18n.missing_keys
  end

  # -- arriving without a reload ---------------------------------------------

  # The reason the panel is pushed at all: a loop is started by a turn, and the
  # toggle that watches it did not exist when the page was drawn. Waiting for a
  # reload is the bug.
  def test_a_loop_beginning_redraws_the_sheet_out_of_band
    loop_state
    @harness.push_loop_sheet("web_rubot")

    type, markup = @harness.pushed.last
    assert_equal :"loop-sheet", type
    assert_includes markup, %(id="loop-sheet" hx-swap-oob="true")
    refute_includes markup, %(id="loop-sheet" hidden)
    assert_includes markup, %(id="loop-sheet-body")
  end

  # A second loop starting is not a reason to close the panel a reader has
  # open: the sheet stays where it is and only its rows are replaced.
  def test_a_second_loop_redraws_only_the_rows
    loop_state(goal: "first")
    @harness.push_loop_sheet("web_rubot")
    loop_state(goal: "second")
    @harness.push_loop_sheet("web_rubot")

    _type, markup = @harness.pushed.last
    assert_includes markup, %(<div id="loop-sheet-body" hx-swap-oob="innerHTML">)
    refute_includes markup, "<details"
    assert_includes markup, "second"
  end

  # A loop that stops is no longer something to watch, and the toggle has to go
  # the same way it came: without a reload.
  def test_a_loop_ending_hides_the_toggle
    state = loop_state
    @harness.push_loop_sheet("web_rubot")
    @store.update(state.id) { |loop| loop.status = "paused" }
    @harness.push_loop_sheet("web_rubot")

    _type, markup = @harness.pushed.last
    assert_includes markup, %(id="loop-sheet" hx-swap-oob="true")
    assert_match(/id="loop-sheet"[^>]*\shidden>/, markup)
    assert_includes markup, "No loop running."
  end
end
