# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/rubot/loop_worktree"

require "open3"

class TestLoopWorktree < Minitest::Test
  ID = "first"

  def setup
    @tmpdir = Dir.mktmpdir
    @repo = init_repo(File.join(@tmpdir, "app"))
    @root = File.join(@tmpdir, "worktrees")

    @seed = File.join(@repo, "seed.txt")
    File.write(@seed, "original\n")
    git(@repo, "add", "seed.txt")
    git(@repo, "commit", "-m", "seed")

    @worktrees = Rubot::LoopWorktree.new(root: @root, repo: @repo)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_create_makes_a_worktree_on_its_own_branch
    dir = @worktrees.create(id: ID)

    assert_equal File.join(@root, "app-#{ID}"), dir
    assert File.directory?(dir)
    assert @worktrees.exists?(ID)
    assert_equal "loop/#{ID}", @worktrees.branch(ID)
    assert_equal "main", git(@repo, "rev-parse", "--abbrev-ref", "HEAD").strip
  end

  def test_create_outside_a_repo_raises
    plain = File.join(@tmpdir, "plain")
    FileUtils.mkdir_p(plain)
    worktrees = Rubot::LoopWorktree.new(root: @root, repo: plain)

    error = assert_raises(Rubot::LoopWorktree::Error) { worktrees.create(id: ID) }
    assert_includes error.message, "not a git repository"
  end

  def test_changed_and_diff_stat
    @worktrees.create(id: ID)

    refute @worktrees.changed?(ID)
    assert_equal "", @worktrees.diff_stat(ID)

    File.write(File.join(@worktrees.path(ID), "seed.txt"), "edited\n")

    assert @worktrees.changed?(ID)
    assert_includes @worktrees.diff_stat(ID), "seed.txt"
  end

  def test_commit_stages_and_commits
    dir = @worktrees.create(id: ID)
    File.write(File.join(dir, "note.txt"), "iteration one\n")

    sha = @worktrees.commit(ID, message: "iterate one")

    assert_match(/\A[0-9a-f]{40}\z/, sha)
    refute @worktrees.changed?(ID)
    assert_equal "iterate one", git(dir, "log", "-1", "--format=%s").strip
  end

  # The head is what tells an iteration's own commit apart from one made for it,
  # so it must be the sha the worktree is on and must follow it.
  def test_head_is_the_commit_the_worktree_is_on_and_follows_a_new_commit
    dir = @worktrees.create(id: ID)

    assert_equal git(dir, "rev-parse", "HEAD").strip, @worktrees.head(ID)
    assert_match(/\A[0-9a-f]{40}\z/, @worktrees.head(ID))

    File.write(File.join(dir, "note.txt"), "iteration one\n")
    sha = @worktrees.commit(ID, message: "iterate one").strip

    assert_equal sha, @worktrees.head(ID)
    refute_equal git(@repo, "rev-parse", "main").strip, @worktrees.head(ID),
                 "the loop's own branch, never the user's"
  end

  # An agent that commits its own work makes the commit before anyone knows
  # whether a verdict could be bought, so the marker has to be added to a commit
  # that already exists. The body is kept, the sha moves (the caller re-reads
  # the head), and a second call is a no-op rather than a second marker.
  def test_mark_unverified_puts_the_marker_on_the_newest_commit_and_keeps_its_body
    dir = @worktrees.create(id: ID)
    File.write(File.join(dir, "note.txt"), "iteration one\n")
    before = @worktrees.commit(ID, message: "agent step one\n\nwhat it did, in its own words")

    sha = @worktrees.mark_unverified(ID, "[unverified]")

    refute_equal before, sha, "the amend rewrites the commit, so its sha moves"
    assert_equal sha, @worktrees.head(ID)
    assert_equal "[unverified] agent step one", git(dir, "log", "-1", "--format=%s").strip
    assert_includes git(dir, "log", "-1", "--format=%B"), "what it did, in its own words"
    assert_equal 2, git(dir, "rev-list", "--count", "HEAD").to_i, "an amend adds no step"

    assert_equal sha, @worktrees.mark_unverified(ID, "[unverified]"), "a marked commit is left alone"
    assert_equal "[unverified] agent step one", git(dir, "log", "-1", "--format=%s").strip
  end

  # The marker is read while a stop is being written down, so a worktree that
  # will not answer says nil instead of raising in the middle of the entry.
  def test_mark_unverified_answers_nil_without_a_worktree
    assert_nil @worktrees.mark_unverified("never-created", "[unverified]")
  end

  # A head nobody can read is not progress: the comparison that reads it must
  # answer nil rather than raise, whether the worktree is gone or was never one.
  def test_head_of_a_worktree_git_cannot_answer_for_is_nil
    assert_nil @worktrees.head("never-created")

    dir = @worktrees.create(id: ID)
    @worktrees.remove(ID)
    assert_nil @worktrees.head(ID)

    # A plain directory at the loop's path is not a worktree, and git refuses to
    # read a head in it.
    FileUtils.mkdir_p(dir)
    assert_nil @worktrees.head(ID)
  end

  # What the verifier is shown: the loop's own work, as git names it, from the
  # commit the loop started at to the head it is on now.
  def test_changed_files_names_what_the_loop_did_against_its_base
    dir = @worktrees.create(id: ID)
    base = @worktrees.head(ID)

    assert_equal [], @worktrees.changed_files(ID, base), "a worktree that just appeared changed nothing"

    File.write(File.join(dir, "note.txt"), "iteration one\n")
    File.write(File.join(dir, "seed.txt"), "edited\n")
    @worktrees.commit(ID, message: "iterate one")

    assert_equal [ "A note.txt", "M seed.txt" ], @worktrees.changed_files(ID, base).sort
  end

  # A verifier that cannot be told what changed is still a verifier, and this is
  # asked mid-run, so nothing to compare answers an empty list rather than raise.
  def test_changed_files_is_empty_without_a_base_or_without_a_worktree
    assert_nil @worktrees.head(ID)
    assert_equal [], @worktrees.changed_files(ID, nil)
    assert_equal [], @worktrees.changed_files("never-created", "HEAD")

    dir = @worktrees.create(id: ID)
    base = @worktrees.head(ID)
    File.write(File.join(dir, "note.txt"), "iteration one\n")
    @worktrees.commit(ID, message: "iterate one")
    @worktrees.remove(ID)

    assert_equal [], @worktrees.changed_files(ID, base)
  end

  # A loop of a thousand files must not become a prompt of a thousand lines, and
  # a list cut short has to say so: an unmarked cap reads as "that was all".
  def test_changed_files_caps_a_long_list_and_says_how_many_were_left_out
    dir = @worktrees.create(id: ID)
    base = @worktrees.head(ID)
    65.times { |index| File.write(File.join(dir, format("f%02d.txt", index)), "x\n") }
    @worktrees.commit(ID, message: "many files")

    files = @worktrees.changed_files(ID, base)

    assert_equal Rubot::LoopWorktree::CHANGED_FILES_LIMIT + 1, files.size
    assert_equal "5 more files not listed", files.last
    assert_equal Rubot::LoopWorktree::CHANGED_FILES_LIMIT, files.count { |line| line.start_with?("A ") }
  end

  # Bug: a blank message reached `git commit -m ""`, which aborts, so an
  # iteration that worked but produced no note blew up instead of stopping the
  # way "nothing to commit" does.
  def test_commit_with_a_blank_message_records_nothing
    dir = @worktrees.create(id: ID)
    before = commit_count(dir)
    File.write(File.join(dir, "note.txt"), "iteration one\n")

    assert_nil @worktrees.commit(ID, message: "")
    assert_nil @worktrees.commit(ID, message: " \n\t  ")

    assert_equal before, commit_count(dir)
    assert_equal "seed", git(dir, "log", "-1", "--format=%s").strip
    # The work is still uncommitted rather than lost or half-staged.
    assert @worktrees.changed?(ID)
  end

  def test_commit_with_nothing_to_do_returns_nil
    dir = @worktrees.create(id: ID)
    before = commit_count(dir)

    assert_nil @worktrees.commit(ID, message: "nothing happened")

    assert_equal before, commit_count(dir)
  end

  def test_reset_last_undoes_one_commit_and_stops_at_the_root
    dir = @worktrees.create(id: ID)
    File.write(File.join(dir, "note.txt"), "iteration one\n")
    @worktrees.commit(ID, message: "iterate one")
    assert_equal 2, commit_count(dir)

    assert @worktrees.reset_last(ID)

    assert_equal 1, commit_count(dir)
    refute File.exist?(File.join(dir, "note.txt"))

    refute @worktrees.reset_last(ID)
    assert_equal 1, commit_count(dir)
  end

  def test_remove_deletes_the_worktree
    dir = @worktrees.create(id: ID)

    @worktrees.remove(ID)

    refute File.exist?(dir)
    refute @worktrees.exists?(ID)
    refute_includes git(@repo, "worktree", "list"), dir
  end

  # Bug: create used to fail forever after a remove, because it always passed
  # -b and remove deliberately keeps the branch. The restarted loop must find
  # its own branch, and its commits with it.
  def test_create_after_remove_reattaches_the_existing_branch
    dir = @worktrees.create(id: ID)
    File.write(File.join(dir, "note.txt"), "iteration one\n")
    sha = @worktrees.commit(ID, message: "iterate one").strip

    @worktrees.remove(ID)
    refute @worktrees.exists?(ID)
    assert_equal sha, git(@repo, "rev-parse", "refs/heads/loop/#{ID}").strip

    again = @worktrees.create(id: ID)

    assert_equal dir, again
    assert @worktrees.exists?(ID)
    assert_equal "loop/#{ID}", @worktrees.branch(ID)
    assert_equal sha, git(again, "rev-parse", "HEAD").strip
    assert_equal "iteration one\n", File.read(File.join(again, "note.txt"))
  end

  def test_remove_of_a_missing_loop_does_not_raise
    # False, not nil: the caller is told there was nothing to clean up, which
    # is what keeps a loop's log from announcing a removal that never happened.
    assert_equal false, @worktrees.remove("never-created")

    refute @worktrees.exists?("never-created")
  end

  # Bug: git had forgotten the worktree (a crash, or a prune) while the
  # directory was still on disk, so remove returned early and left it there,
  # which is exactly what made the next create fail.
  def test_remove_cleans_up_a_worktree_git_has_forgotten
    dir = @worktrees.create(id: ID)
    File.write(File.join(dir, "note.txt"), "iteration one\n")
    sha = @worktrees.commit(ID, message: "iterate one").strip

    # Park the directory, let git prune the entry, then put it back: git no
    # longer knows the worktree, the filesystem still has it.
    parked = "#{dir}-parked"
    FileUtils.mv(dir, parked)
    git(@repo, "worktree", "prune")
    FileUtils.mv(parked, dir)

    refute @worktrees.exists?(ID)

    # True: the leftover directory was actually cleaned up.
    assert_equal true, @worktrees.remove(ID)

    refute File.exist?(dir)
    refute @worktrees.exists?(ID)
    assert_equal sha, git(@repo, "rev-parse", "refs/heads/loop/#{ID}").strip
  end

  def test_ids_cannot_escape_the_root
    outside = File.join(@tmpdir, "outside.txt")
    File.write(outside, "keep me\n")

    assert_raises(ArgumentError) { @worktrees.path("../escape") }
    assert_raises(ArgumentError) { @worktrees.remove("../escape") }

    assert File.exist?(outside)
    refute File.exist?(File.join(@tmpdir, "escape"))
  end

  # Bug: two loops whose ids differ only in case could land on one directory.
  # The id validator is what stops that, and it must keep refusing rather than
  # hand the second loop the first one's worktree.
  def test_an_id_that_differs_only_in_case_is_refused
    dir = @worktrees.create(id: ID)
    File.write(File.join(dir, "note.txt"), "iteration one\n")
    @worktrees.commit(ID, message: "iterate one")

    assert_raises(ArgumentError) { @worktrees.create(id: "First") }
    assert_raises(ArgumentError) { @worktrees.exists?("First") }
    assert_raises(ArgumentError) { @worktrees.remove("First") }

    assert @worktrees.exists?(ID)
    assert_equal "loop/#{ID}", @worktrees.branch(ID)
    assert_equal "iteration one\n", File.read(File.join(dir, "note.txt"))
  end

  # Bug: a path that already holds a worktree was handed to git, which answered
  # with its own "already exists" and left the caller to read a raw git error.
  # The refusal is the class's own now, and the worktree is left alone.
  def test_a_second_create_for_a_live_worktree_is_refused
    dir = @worktrees.create(id: ID)
    head = git(dir, "rev-parse", "HEAD").strip

    error = assert_raises(Rubot::LoopWorktree::Error) { @worktrees.create(id: ID) }
    assert_includes error.message, "already has a worktree"

    assert @worktrees.exists?(ID)
    assert_equal head, git(dir, "rev-parse", "HEAD").strip
    assert_equal "loop/#{ID}", @worktrees.branch(ID)
  end

  # Bug: with the same repo basename the two loops want one path in the root.
  # The second repo must say so instead of adopting the worktree, and its
  # remove must not delete what is not its own.
  def test_a_worktree_of_another_repo_is_never_reused_or_deleted
    dir = @worktrees.create(id: ID)
    other_repo = init_repo(File.join(@tmpdir, "other", "app"))
    other = Rubot::LoopWorktree.new(root: @root, repo: other_repo)

    assert_equal dir, other.path(ID)

    error = assert_raises(Rubot::LoopWorktree::Error) { other.create(id: ID) }
    assert_includes error.message, dir
    assert_raises(Rubot::LoopWorktree::Error) { other.remove(ID) }

    assert @worktrees.exists?(ID)
    assert_equal "loop/#{ID}", @worktrees.branch(ID)
    assert_includes git(@repo, "worktree", "list"), dir
  end

  # Bug: a plain directory that merely sits at the loop's path is nobody's
  # worktree, and was silently reused by create and deleted by remove.
  def test_a_plain_directory_at_the_loops_path_is_refused
    dir = @worktrees.path(ID)
    FileUtils.mkdir_p(dir)
    kept = File.join(dir, "notes.txt")
    File.write(kept, "not a worktree\n")

    error = assert_raises(Rubot::LoopWorktree::Error) { @worktrees.create(id: ID) }
    assert_includes error.message, "not a worktree"
    assert_raises(Rubot::LoopWorktree::Error) { @worktrees.remove(ID) }

    refute @worktrees.exists?(ID)
    assert_equal "not a worktree\n", File.read(kept)
  end

  def test_two_loops_use_two_worktrees_at_once
    one = @worktrees.create(id: "one")
    two = @worktrees.create(id: "two")

    refute_equal one, two
    assert @worktrees.exists?("one")
    assert @worktrees.exists?("two")

    File.write(File.join(one, "one.txt"), "1\n")
    File.write(File.join(two, "two.txt"), "2\n")

    refute_equal @worktrees.commit("one", message: "one"), @worktrees.commit("two", message: "two")

    refute @worktrees.changed?("one")
    refute @worktrees.changed?("two")
    refute File.exist?(File.join(one, "two.txt"))
    assert_equal "loop/two", @worktrees.branch("two")
  end

  def test_the_users_checkout_is_untouched
    head = git(@repo, "rev-parse", "HEAD").strip
    branch = git(@repo, "rev-parse", "--abbrev-ref", "HEAD").strip
    status = git(@repo, "status", "--porcelain")

    dir = @worktrees.create(id: ID)
    File.write(File.join(dir, "seed.txt"), "agent edit\n")
    @worktrees.commit(ID, message: "iterate one")
    @worktrees.reset_last(ID)

    assert_equal "original\n", File.read(@seed)
    assert_equal head, git(@repo, "rev-parse", "HEAD").strip
    assert_equal branch, git(@repo, "rev-parse", "--abbrev-ref", "HEAD").strip
    assert_equal status, git(@repo, "status", "--porcelain")
  end

  private

  # A repo of its own. The identity is local so the test never depends on
  # whatever git config the machine carries, and `-b main` keeps the branch
  # name out of that config too.
  def init_repo(dir)
    FileUtils.mkdir_p(dir)
    git(dir, "init", "-b", "main")
    git(dir, "config", "user.name", "Loop Test")
    git(dir, "config", "user.email", "loop@example.test")
    dir
  end

  # The tests check git's own view of the repo, so they read it the same way
  # the class does: an argument array, never a shell string.
  def git(dir, *args)
    out, err, status = Open3.capture3("git", *args, chdir: dir)
    assert status.success?, "git #{args.join(' ')} failed in #{dir}: #{err}"
    out
  end

  def commit_count(dir)
    git(dir, "rev-list", "--count", "HEAD").strip.to_i
  end
end
