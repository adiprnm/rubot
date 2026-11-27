# frozen_string_literal: true

require "open3"
require "fileutils"

require_relative "loop_store"

module Rubot
  # The git worktree a loop lives in.
  #
  # A loop is a goal an agent works at over many iterations, and it must never
  # touch what the user has checked out. Each loop therefore gets a worktree of
  # its own on a branch of its own: one commit per iteration lands there, and
  # the user's working copy, index and HEAD never move while it happens.
  #
  # Nothing here pushes. Publishing is the user's decision, taken from their
  # own checkout once they have read what the loop did, so this file only knows
  # how to make, read and unwind a local worktree. It is filesystem and git
  # only: no agents, no models, no tokens, so a loop can be created and
  # inspected without a session behind it.
  class LoopWorktree
    # Carries git's own stderr, so a failed iteration can say why it failed in
    # the loop's log instead of just "git failed".
    class Error < StandardError; end

    # The same rule the loop store applies to an id. It is the only thing
    # standing between a caller-supplied id and a path: no dots, no slashes,
    # no case games, no "..", so `path` can never point outside the root.
    ID_PATTERN = LoopStore::ID_PATTERN

    # How many changed paths reach a verifier's prompt. A loop of a thousand
    # files must not become a prompt of a thousand lines, and the last entry of
    # a capped list says how many were left out.
    CHANGED_FILES_LIMIT = 60

    attr_reader :root, :repo

    def initialize(root:, repo:)
      @root = File.expand_path(root)
      @repo = File.expand_path(repo)
    end

    # Where loop `id`'s worktree belongs. The repo's name is part of the path
    # because one root outlives many repos; two repos of one name collide here,
    # which `create` refuses rather than resolves.
    def path(id)
      validate_id!(id)
      File.join(root, "#{File.basename(repo)}-#{id}")
    end

    # A directory that only looks like a worktree (a leftover from a crash, or
    # a plain directory in the root) is not one, so ask git rather than the
    # filesystem. It must also be a worktree of *this* repo: two repos can
    # share one name, and a loop of one must never answer for the other's.
    def exists?(id)
      dir = path(id)
      return false unless File.directory?(dir)

      out, _err, ok = capture(dir, "rev-parse", "--show-toplevel")
      return false unless ok && same_path?(out.strip, dir)

      owned?(dir)
    rescue SystemCallError
      # The directory went away between the check and the call.
      false
    end

    # Give the loop a worktree. The branch is named after the id so that
    # `git branch --list "loop/*"` in the user's repo lists exactly the loops
    # that exist. `remove` keeps that branch on purpose, so a removed loop that
    # starts again finds it: a missing ref is created, an existing one is
    # reattached to with its commits intact.
    def create(id:, base: "HEAD", branch: nil)
      dir = path(id)
      branch ||= "loop/#{id}"
      FileUtils.mkdir_p(root)
      refuse_taken_path!(id, dir)
      onto = branch_exists?(branch) ? [ dir, branch ] : [ "-b", branch, dir, base ]
      git(repo, "worktree", "add", *onto)
      dir
    end

    # Removing a loop's worktree leaves its branch behind on purpose: the
    # commits are the loop's record, and the caller decides whether to keep
    # reading them. Doing nothing for a loop that was never created keeps
    # cleanup idempotent.
    #
    # A directory git no longer knows as a worktree (a crash, or a prune after
    # the path went missing) goes too, since it is what makes the next create
    # fail. Anything else at that path is somebody else's: refused, not deleted.
    def remove(id, force: false)
      dir = path(id)
      # True when something was actually removed, so a caller can say so
      # instead of announcing a cleanup that had nothing to clean.
      return false unless File.exist?(dir)
      if exists?(id)
        args = [ "worktree", "remove" ]
        args << "--force" if force
        git(repo, *args, dir)
      elsif leftover?(dir)
        FileUtils.remove_entry(dir, true)
      else
        raise Error, "refusing to remove #{dir}: it is not a worktree of #{repo}"
      end
      true
    end

    def branch(id)
      git(path(id), "rev-parse", "--abbrev-ref", "HEAD").strip
    end

    # The commit the worktree is on, or nil when it cannot be read: a loop that
    # is gone, pruned, or sitting in a directory git will not answer for are all
    # the same answer here. A caller comparing two reads is asking whether
    # anything moved, and an unreadable worktree must never count as progress,
    # so this question never raises.
    def head(id)
      out, _err, ok = capture(path(id), "rev-parse", "HEAD")
      return nil unless ok

      out.strip.then { |sha| sha.empty? ? nil : sha }
    rescue SystemCallError
      # The worktree went away between the path and the call.
      nil
    end

    # The newest commit's subject on the loop's branch, or nil when the worktree
    # cannot answer. The subject is where an unverified iteration says so (see
    # LoopRun::UNVERIFIED_MARKER), so this is the one question a report asks the
    # branch: is there work sitting here that nobody judged? Never raises, for
    # the same reason `head` does not -- it is read while a stop is being written
    # down, and a directory that went away is an answer, not an exception.
    def head_subject(id)
      out, _err, ok = capture(path(id), "log", "-1", "--format=%s")
      ok ? out.strip : nil
    rescue SystemCallError
      # The worktree went away between the path and the call.
      nil
    end

    def changed?(id)
      !git(path(id), "status", "--porcelain").strip.empty?
    end

    def diff_stat(id)
      git(path(id), "diff", "--stat", "HEAD")
    end

    # What one commit changed, in git's own summary: the numbers a reader needs
    # to weigh keeping an iteration against dropping it. Read from the commit
    # and not from the worktree, because a worktree diff cannot see a file that
    # was never tracked -- which is most of what an iteration adds -- and by the
    # time the entry is written the commit is the only place the change exists.
    # A commit that cannot be asked answers nothing rather than raising: this is
    # read while a stop is being written down.
    def commit_stat(id, sha)
      from = sha.to_s.strip
      return "" if from.empty?

      out, _err, ok = capture(path(id), "show", "--stat", "--format=", from)
      ok ? out : ""
    rescue SystemCallError
      # The worktree went away between the commit and the entry.
      ""
    end

    # What the loop changed, from the commit it started at to the head the
    # worktree is on now: git's own letter in front of each path, so the
    # verifier can check a constraint the goal states in terms of paths ("do not
    # touch files outside catatan/") against what was actually touched. The
    # criteria alone never mention them, which is how a loop ended DONE with a
    # stray file at the repository root.
    #
    # Committed work only: an iteration lands as one commit before it is judged,
    # so the iteration being verified is in the range. A list longer than
    # CHANGED_FILES_LIMIT is cut and says how many entries it left out, because
    # an unmarked cap reads as "that was all".
    #
    # Nothing to compare -- no base recorded, or a worktree that is gone -- is an
    # empty list rather than an exception: this is asked mid-run, and a verifier
    # that cannot be told what changed is still a verifier.
    def changed_files(id, base)
      from = base.to_s.strip
      return [] if from.empty?

      out, _err, ok = capture(path(id), "diff", "--name-status", from, "HEAD")
      return [] unless ok

      entries = out.lines.filter_map { |line| name_status(line) }
      return entries if entries.size <= CHANGED_FILES_LIMIT

      entries.first(CHANGED_FILES_LIMIT) + [ "#{entries.size - CHANGED_FILES_LIMIT} more files not listed" ]
    rescue SystemCallError
      # The worktree went away between the path and the call.
      []
    end

    # One commit per iteration, or nil when the iteration left nothing worth
    # recording: an empty commit would add a step to the loop's history that a
    # reader cannot tell from real work. A blank message answers the same way
    # because git would abort, and returning before the `add` keeps that work
    # uncommitted rather than half-staged.
    def commit(id, message:)
      dir = path(id)
      text = message.to_s.strip
      return nil if text.empty?

      git(dir, "add", "-A")
      return nil if git_ok?(dir, "diff", "--cached", "--quiet")

      git(dir, "commit", "-m", text)
      git(dir, "rev-parse", "HEAD").strip
    end

    # Nothing above the root commit is an ordinary place for a loop to end up,
    # so the caller gets false there instead of an exception.
    def reset_last(id)
      dir = path(id)
      return false unless git_ok?(dir, "rev-parse", "--verify", "--quiet", "HEAD~1")

      git(dir, "reset", "--hard", "HEAD~1")
      true
    end

    private

    def validate_id!(id)
      return id if id.is_a?(String) && ID_PATTERN.match?(id)

      raise ArgumentError, "invalid loop id: #{id.inspect}"
    end

    # One `git diff --name-status` line as "letter path". A rename or a copy
    # carries two paths and both are the answer: the old one is a path the loop
    # may have been told not to touch.
    def name_status(line)
      status, *paths = line.chomp.split("\t")
      return nil if status.to_s.empty? || paths.empty?

      "#{status} #{paths.join(" -> ")}"
    end

    # `loop/<id>` outlives its worktree, so the ref is often already there.
    def branch_exists?(branch)
      git_ok?(repo, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}")
    end

    # Nothing is ever adopted. A live worktree for this id means a second
    # create, worth naming; anything else at that path is somebody else's.
    def refuse_taken_path!(id, dir)
      return unless File.exist?(dir)
      raise Error, "loop #{id} already has a worktree at #{dir}" if exists?(id)

      raise Error, "refusing to use #{dir}: it is not a worktree of #{repo}"
    end

    # A worktree git has forgotten still carries the `.git` file naming the
    # admin directory it belonged to, and that name sits under this repo's own
    # worktrees directory: the last clue that the directory came from here.
    def leftover?(dir)
      gitfile = File.join(dir, ".git")
      return false unless File.file?(gitfile)

      line = File.read(gitfile, 4096).strip
      return false unless line.start_with?("gitdir:")

      File.expand_path(line.delete_prefix("gitdir:").strip, dir).start_with?(File.join(admin_dir, ""))
    rescue SystemCallError
      false
    end

    # Where this repo keeps a worktree's admin directory. The common dir is the
    # main repo's even when `repo` is itself a linked worktree.
    def admin_dir
      File.join(File.expand_path(git(repo, "rev-parse", "--git-common-dir").strip, repo), "worktrees")
    end

    # Git's own list of the worktrees this repo owns, read without raising:
    # `exists?` is a question, and a repo git cannot read owns none of them.
    def owned?(dir)
      out, _err, ok = capture(repo, "worktree", "list", "--porcelain")
      return false unless ok

      out.lines.filter_map { |line| line.delete_prefix("worktree ").strip if line.start_with?("worktree ") }
        .any? { |path| same_path?(path, dir) }
    end

    # Paths are compared as the filesystem spells them: a root reached through
    # a symlink (`/tmp` on macOS, for one) is the same directory as its target.
    def same_path?(one, other)
      File.realpath(one) == File.realpath(other)
    rescue SystemCallError
      false
    end

    # Every git call in this file is a capture of an argument array with a
    # working directory, never a string handed to a shell: an id or a branch
    # name can therefore never grow into a second command. Returns
    # [stdout, stderr, success?], because the bare status object is truthy even
    # for a failed git, which would turn every check here into a "yes".
    def capture(dir, *args)
      out, err, status = Open3.capture3("git", *args, chdir: dir)
      [ out, err, status.success? ]
    end

    # For calls whose success is the only thing worth reading.
    def git_ok?(dir, *args)
      _out, _err, ok = capture(dir, *args)
      ok
    end

    # For calls that must succeed, where the output is the answer.
    def git(dir, *args)
      out, err, ok = capture(dir, *args)
      raise Error, failure_message(args, out, err) unless ok

      out
    end

    def failure_message(args, out, err)
      detail = err.to_s.strip
      detail = out.to_s.strip if detail.empty?
      "git #{args.first} failed: #{detail}"
    end
  end
end
