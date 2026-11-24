# frozen_string_literal: true

require_relative "test_helper"

# The delegated runs a conversation owns while they are still going. The turn
# that asked for one may already be over, so this registry is the only thing
# that knows a run exists, what it is doing, and what it came back with.
class TestSubagentJobs < Minitest::Test
  def setup
    @now = 100.0
    @jobs = Rubot::Web::SubagentJobs.new(clock: -> { @now })
  end

  def test_a_run_moves_from_started_to_done_and_counts_its_calls
    changed = []
    @jobs.on_change { |sid| changed << sid }

    @jobs.start(session_id: "s1", run_id: "r1", agent: "writer", task: "write a poem")
    assert_equal 1, @jobs.running_count("s1")

    @jobs.update(session_id: "s1", run_id: "r1", phase: "tool")
    @jobs.update(session_id: "s1", run_id: "r1", phase: "tool")
    run = @jobs.runs("s1").first
    assert_equal "2 langkah · write a poem", run[:line],
                 "the task stays the subject of the row while the run works"
    assert_equal 1, @jobs.running_count("s1")

    @now += 12.4
    @jobs.finish(session_id: "s1", run_id: "r1", status: "done", result: "a poem")

    run = @jobs.runs("s1").first
    assert_equal "done", run[:phase]
    assert_equal "a poem", run[:result]
    assert_equal "2 langkah · 12.4s", run[:line]
    assert_equal 0, @jobs.running_count("s1")
    assert_equal [ "s1" ] * 4, changed
  end

  def test_a_failed_run_says_why_instead_of_counting_calls
    @jobs.start(session_id: "s1", run_id: "r1", agent: "writer", task: "poem")
    @jobs.update(session_id: "s1", run_id: "r1", phase: "tool")
    @jobs.finish(session_id: "s1", run_id: "r1", status: "failed", error: "rate limited")

    run = @jobs.runs("s1").first
    assert_equal "rate limited", run[:line]
    refute_includes run[:line], "call"
    refute_includes run[:line], "langkah"
    assert_equal 0, @jobs.running_count("s1")
  end

  def test_runs_are_kept_newest_first_and_scoped_to_their_session
    @jobs.start(session_id: "s1", run_id: "a", agent: "writer", task: "one")
    @jobs.start(session_id: "s1", run_id: "b", agent: "researcher", task: "two")
    @jobs.start(session_id: "s2", run_id: "c", agent: "planner", task: "three")

    assert_equal %w[b a], @jobs.runs("s1").map { |run| run[:run_id] }
    assert_equal %w[c], @jobs.runs("s2").map { |run| run[:run_id] }
    assert_empty @jobs.runs("nobody")
  end

  def test_an_unknown_run_is_ignored_rather_than_created
    @jobs.update(session_id: "s1", run_id: "ghost", phase: "tool")
    @jobs.finish(session_id: "s1", run_id: "ghost", status: "done", result: "x")

    assert_empty @jobs.runs("s1")
  end

  def test_a_snapshot_is_a_copy_the_reader_can_keep
    @jobs.start(session_id: "s1", run_id: "r1", agent: "writer", task: "poem")
    snapshot = @jobs.runs("s1").first
    @jobs.update(session_id: "s1", run_id: "r1", phase: "tool")

    assert_equal "poem", snapshot[:detail]
  end

  def test_the_sheet_is_only_in_the_row_when_there_is_something_to_say
    refute Rubot::Web::SubagentJobs.visible?([])
    assert Rubot::Web::SubagentJobs.visible?([{ phase: "tool" }])
    assert Rubot::Web::SubagentJobs.visible?([{ phase: "done", finished_at: Time.now }])
    assert Rubot::Web::SubagentJobs.visible?([{ phase: "failed", finished_at: Time.now }])

    stale = Time.now - (Rubot::Web::SubagentJobs::DONE_MARK_SECONDS + 60)
    refute Rubot::Web::SubagentJobs.visible?([{ phase: "done", finished_at: stale }])
  end

  # The row's subject is the task, never the calls: what a delegated agent
  # reaches for is its own business, and its captions read as if the reader's
  # own agent were running them. The count of steps is the progress.
  def test_the_line_counts_a_running_run_and_names_what_happened_once_it_ends
    assert_equal "3 langkah · write a poem",
                 Rubot::Web::SubagentLine.line(calls: 3, phase: "tool", detail: "write a poem")
    assert_equal "3 langkah · write a poem",
                 Rubot::Web::SubagentLine.line(calls: 3, phase: "thinking", detail: "write a poem")
    assert_equal "write a poem", Rubot::Web::SubagentLine.line(calls: 0, phase: "started",
                                                               detail: "write a poem")
    assert_equal "3 langkah", Rubot::Web::SubagentLine.line(calls: 3, phase: "done", detail: "")
    assert_equal "12s", Rubot::Web::SubagentLine.line(calls: 0, phase: "done", detail: "12s")
    assert_equal "boom", Rubot::Web::SubagentLine.line(calls: 4, phase: "failed", detail: "boom")
  end

  # A task is a whole brief and the row is one line wide. The beginning has to
  # survive — it is what tells two runs apart — and the rest is on the tooltip.
  def test_a_long_task_is_cut_to_the_beginning_rather_than_swallowed_by_the_row
    task = "Review an uncommitted change in the Ruby project and report every bug you find"
    line = Rubot::Web::SubagentLine.line(calls: 2, phase: "tool", detail: task)

    assert line.start_with?("2 langkah · Review an uncommitted"), line
    assert line.end_with?("…"), line
    assert_operator line.length, :<=, "2 langkah · ".length + Rubot::Web::SubagentLine::SUBJECT_CHARS
  end
end
