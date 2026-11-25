# frozen_string_literal: true

require "date"
require "fileutils"
require "securerandom"
require "time"
require "yaml"

module Rubot
  # A loop is a goal an agent works through over many iterations: one markdown
  # file per loop at <dir>/<id>.md, YAML frontmatter for the facts and a "## Log"
  # of newest-first bullets, so `cat` shows the state and an editor can repair it.
  class LoopStore
    # The id becomes a file name, so it is validated rather than trusted: no
    # separators, no dots, nothing that could climb out of `dir`.
    ID_PATTERN = /\A[a-z0-9][a-z0-9-]{0,63}\z/
    STATUSES = %w[active paused done stalled].freeze
    LOG_HEADING = "## Log"
    # Every frontmatter fact; a save diffs these to find the caller's own edits.
    FACT_KEYS = %i[id goal done_criteria repo branch worktree base status iterations tokens
                   max_iterations max_tokens created_at updated_at].freeze

    # A file that exists but cannot be read back as a loop. Distinct from a
    # missing file on purpose: defaulting the counters (tokens 0, status active)
    # would hand a spent budget back and re-arm a finished loop.
    class Corrupt < StandardError; end

    Entry = Struct.new(:at, :text, keyword_init: true)

    # A loop as read from disk, mutable on purpose: #update hands one out and the
    # caller edits it. `log` is newest first, the order the file keeps.
    class State
      # The cap lives in the file, not in whoever happens to construct the run:
      # a resumed run, a cron retry or a second process must not be able to hand
      # a spent loop a fresh budget just by forgetting an argument.
      DEFAULT_MAX_TOKENS = 500_000
      # Five, because a real iteration costs about 85k tokens of worker and
      # verifier together: at eight the budget above was always spent first and
      # the cap decided nothing. Five of them fit under it (5 * 85k = 425k) and
      # leave room for the one iteration a budget stop can overshoot by.
      DEFAULT_MAX_ITERATIONS = 5

      attr_reader :id, :goal, :done_criteria, :repo, :created_at, :log
      # `base` is the commit the worktree was created from, nil for a file
      # written before it was recorded. It is a fact in the file rather than
      # something derived from git when it is needed: this store is a
      # file-backed record that reaches no repository, a finished loop has had
      # its worktree taken away and keeps only its branch, and a resumed loop
      # reattaches a branch that has moved -- so a base worked out late would
      # measure the loop's work from wherever the loop had already got to.
      attr_accessor :branch, :worktree, :base, :status, :iterations, :tokens, :max_iterations,
                    :max_tokens, :updated_at
      # What the file said when this was read, nil for a state built in memory:
      # #save diffs against it, so a stale object carries edits, not an overwrite.
      attr_accessor :origin

      def initialize(id:, goal:, done_criteria:, repo:, branch: nil, worktree: nil, base: nil,
                     status: "active", iterations: 0, tokens: 0, max_iterations: DEFAULT_MAX_ITERATIONS,
                     max_tokens: DEFAULT_MAX_TOKENS, created_at: nil, updated_at: nil, log: [])
        @id, @goal, @done_criteria, @repo = id, goal, done_criteria, repo
        @branch, @worktree, @base, @status = branch, worktree, base, status
        @iterations, @tokens, @max_iterations = iterations, tokens, max_iterations
        @max_tokens = max_tokens
        @created_at, @updated_at, @log = created_at, updated_at, log
      end

      def add_entry(entry) = @log.unshift(entry)

      # One entry per frontmatter fact: a diff of two states is a diff of the file.
      def facts = FACT_KEYS.to_h { |key| [ key, public_send(key) ] }

      # The lock a save holds is not the truth it writes: `disk` is the file now,
      # this object is what was read plus the edits since, so a field it never
      # touched keeps the file's value and the log keeps both sides, newest first.
      def rebase(disk)
        return self if disk.nil? || origin.nil?

        changed = facts.reject { |key, value| origin[key] == value }
        State.new(**disk.facts.merge(changed), log: (disk.log - log) + log)
      end
    end

    def initialize(dir:)
      raise ArgumentError, "dir is required" if dir.nil? || dir.to_s.strip.empty?

      @dir = File.expand_path(dir.to_s)
    end

    # Filtered through ID_PATTERN: a stray note or a temp file is not a loop.
    def ids
      Dir.glob(File.join(@dir, "*.md")).map { |file| File.basename(file, ".md") }.grep(ID_PATTERN).sort
    end

    def path(id)
      name = id.to_s
      raise ArgumentError, "invalid loop id: #{name.inspect}" unless ID_PATTERN.match?(name)

      File.join(@dir, "#{name}.md")
    end

    def load(id)
      file = path(id)
      # Read-only: a missing directory means "no loops yet", not an error, and
      # a listing must never create the thing it is listing.
      content = with_lock(file, exclusive: false, create_dir: false) { |handle| handle.read }
      content && state_from(content, File.basename(file, ".md"), file)
    rescue Errno::ENOENT
      nil
    end

    def create(goal:, done_criteria:, repo:, branch: nil, worktree: nil,
               max_iterations: State::DEFAULT_MAX_ITERATIONS, max_tokens: nil)
      now = Time.now.utc
      state = State.new(id: next_id(now), goal: goal.to_s, done_criteria: done_criteria.to_s,
                        repo: repo.to_s, branch: blank_to_nil(branch), worktree: blank_to_nil(worktree),
                        max_iterations: max_iterations,
                        max_tokens: max_tokens || State::DEFAULT_MAX_TOKENS,
                        created_at: now, updated_at: now)
      # The log starts with the loop itself, so no reader gets an empty section.
      state.add_entry(Entry.new(at: now, text: "loop started"))
      save(state)
    end

    # The one full-write path: it takes the lock #update takes, for the whole
    # write, and lands the file atomically underneath it. State#rebase says what a
    # stale caller gets, #write_file the fsyncs.
    def save(state)
      file = path(state.id)
      status = state.status.to_s
      unless STATUSES.include?(status)
        raise ArgumentError, "#{file}: unknown status #{status.inspect} (expected #{STATUSES.join(", ")})"
      end

      FileUtils.mkdir_p(@dir)
      with_lock(File.join(@dir, ".lock"), exclusive: true) { write_file(file, state.rebase(disk_at(file))) }
      state
    end

    # Read, yield, write under the lock: two processes cannot each save half a change.
    def update(id)
      with_lock(File.join(@dir, ".lock"), exclusive: true) do
        state = load(id) or next
        yield state
        state.updated_at = Time.now.utc
        save(state)
      end
    end

    def append_log(id, text, at: Time.now)
      update(id) { |state| state.add_entry(Entry.new(at: at, text: one_line(text))) }
    end

    private

    # Shared for a read, exclusive for read-modify-write. It has a file of its own
    # because #save renames over the data file, and that inode then dies.
    #
    # `create_dir: false` is what a read passes: listing loops must not create the
    # directory it lists, so a read of a missing store answers nil.
    def with_lock(file, exclusive:, create_dir: true)
      # Re-entrant per THREAD, not per instance. One store is shared by every
      # loop thread of a conversation, and a thread that mistook another
      # thread's lock for its own would skip flock altogether: both read the
      # same file, both write, and one charge disappears. flock belongs to the
      # file description, so only the thread already inside may skip it.
      held = Thread.current[:rubot_loop_store_lock]
      return yield(nil) if held == file

      FileUtils.mkdir_p(File.dirname(file)) if create_dir
      flags = exclusive ? File::RDWR | File::CREAT : File::RDONLY
      File.open(file, flags, 0o644) do |handle|
        handle.flock(exclusive ? File::LOCK_EX : File::LOCK_SH)
        Thread.current[:rubot_loop_store_lock] = file
        begin
          yield handle
        ensure
          Thread.current[:rubot_loop_store_lock] = held
        end
      end
    end

    # The state the file holds now, nil when there is nothing to merge with: a
    # missing file is a plain write, one that will not parse is about to be replaced.
    def disk_at(file)
      state_from(File.read(file), File.basename(file, ".md"), file)
    rescue Errno::ENOENT, Corrupt
      nil
    end

    # Beside the target, then renamed over it, so a reader never sees half a file.
    # The temp file is fsynced before the rename and the directory after it: skip
    # that and a power cut can leave a zero-byte state file, which here means a
    # lost budget and a loop that starts over. Its name carries pid, thread and
    # random bytes, so two writers cannot collide, and it never outlives a failure.
    def write_file(file, state)
      # Named before the render, so a render that raises still leaves the ensure
      # with a path to clean up (there is no file yet) rather than a nil.
      tmp = "#{file}.#{Process.pid}.#{Thread.current.object_id.to_s(36)}.#{SecureRandom.hex(8)}.tmp"
      content = render(state)
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |handle|
        handle.write(content)
        handle.flush
        handle.fsync
      end
      File.rename(tmp, file)
      fsync_dir(@dir)
    ensure
      FileUtils.rm_f(tmp)
    end

    # Durable once the rename's directory entry is on disk. A platform that will
    # not open a directory to read (Windows) skips it: the file itself is fsynced.
    def fsync_dir(dir)
      File.open(dir, File::RDONLY, &:fsync)
    rescue SystemCallError, IOError
      nil
    end

    def render(state)
      fields = [
        [ "id", state.id ], [ "goal", quoted(state.goal) ],
        [ "done_criteria", block(state.done_criteria) ], [ "repo", quoted(state.repo) ],
        [ "branch", state.branch && quoted(state.branch) ], [ "worktree", state.worktree && quoted(state.worktree) ],
        [ "base", state.base && quoted(state.base) ],
        [ "status", state.status ], [ "iterations", state.iterations.to_i ],
        [ "tokens", state.tokens.to_i ], [ "max_iterations", state.max_iterations.to_i ],
        [ "max_tokens", (state.max_tokens || State::DEFAULT_MAX_TOKENS).to_i ],
        [ "created_at", iso(state.created_at) ], [ "updated_at", iso(state.updated_at) ]
      ].reject { |_, value| value.nil? }.map { |key, value| "#{key}: #{value}\n" }.join
      log = state.log.map { |entry| "- #{[ iso(entry.at), entry.text ].reject(&:empty?).join(" ")}\n" }.join
      "---\n#{fields}---\n\n#{LOG_HEADING}\n\n#{log}"
    end

    # Psych would fold long plain scalars, and this file is read one key per line.
    # Built by hand rather than with String#dump, because dump escapes "#{" as
    # "\#{" and YAML has no such escape: one goal containing an interpolation
    # came back empty, and the next save wrote that emptiness over the file.
    # These are the escapes a YAML double-quoted scalar actually reads back.
    def quoted(value)
      escaped = value.to_s.gsub(/[\\"\x00-\x1f\x7f]/) do |char|
        case char
        when "\\" then "\\\\"
        when '"' then '\\"'
        when "\n" then "\\n"
        when "\t" then "\\t"
        when "\r" then "\\r"
        else format("\\x%02x", char.ord)
        end
      end
      "\"#{escaped}\""
    end
    # "|-" not "|": a block keeping its trailing newline comes back a char longer.
    def block(value)
      lines = value.to_s.split("\n", -1).map { |line| line.empty? ? "" : "  #{line}" }
      "|-\n#{lines.join("\n")}"
    end
    def iso(time) = time.nil? ? "" : time.to_time.utc.iso8601

    # The file name is the id, and the frontmatter follows it: a renamed file
    # must not resurrect its old id as a second file beside itself. Disagreeing
    # with the name is repairable, so it is rewritten on the next save; only a
    # file that cannot be parsed is refused.
    def state_from(content, fallback_id, file)
      data, body = split(content, file)

      state = State.new(
        id: fallback_id, goal: data["goal"].to_s,
        done_criteria: data["done_criteria"].to_s, repo: data["repo"].to_s,
        branch: blank_to_nil(data["branch"]), worktree: blank_to_nil(data["worktree"]),
        base: blank_to_nil(data["base"]),
        status: (data["status"] || "active").to_s, iterations: data["iterations"].to_i,
        tokens: data["tokens"].to_i,
        max_iterations: (data["max_iterations"] || State::DEFAULT_MAX_ITERATIONS).to_i,
        max_tokens: (data["max_tokens"] || State::DEFAULT_MAX_TOKENS).to_i,
        created_at: parse_time(data["created_at"]), updated_at: parse_time(data["updated_at"]),
        log: entries(body)
      )
      # What this read saw, so a save made from it later can tell its own edits
      # from what someone else wrote while it held the object.
      state.origin = state.facts
      state
    end

    # A file a human broke is reported, never repaired by guessing: yielding no
    # facts would reset tokens, iterations and status, which is exactly how a
    # spent budget gets handed back and a finished loop gets re-armed.
    def split(content, file = nil)
      where = file || "loop file"
      text = content.to_s
      lines = text.lines
      closing = text.start_with?("---") ? lines[1..].index { |line| line.strip == "---" } : nil
      raise Corrupt, "#{where}: no frontmatter" unless closing

      data = begin
        YAML.safe_load(lines[1..closing].join, permitted_classes: [ Time, Date ])
      rescue Psych::Exception => e
        raise Corrupt, "#{where}: frontmatter will not parse (#{e.message})"
      end
      raise Corrupt, "#{where}: frontmatter is not a mapping" unless data.is_a?(Hash)

      [ data, lines[(closing + 2)..].to_a.join ]
    end

    def entries(body)
      lines = body.lines
      heading = lines.index { |line| line.strip == LOG_HEADING } or return []

      lines.drop(heading + 1).take_while { |line| !line.start_with?("## ") }.grep(/\A- /).map do |line|
        stamp, text = line.delete_prefix("- ").strip.split(" ", 2)
        at = parse_time(stamp)
        Entry.new(at: at, text: text.to_s) if at
      end.compact
    end

    def parse_time(value)
      value.is_a?(Time) ? value : Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # The timestamp alone does not name the file: two loops can start in one second.
    def next_id(now)
      stamp = now.strftime("%Y%m%d-%H%M%S")
      loop do
        id = "#{stamp}-#{SecureRandom.hex(2)}"
        return id unless File.exist?(path(id))
      end
    end

    # An empty branch in the frontmatter means "not recorded", not "".
    def blank_to_nil(value) = value.to_s.empty? ? nil : value.to_s
    # One bullet per entry: a newline in a note would break the format the next
    # append parses. A class method because the run flattens the same text for
    # its own log entries.
    def self.one_line(text) = text.to_s.gsub(/\s*\n\s*/, " ").strip

    def one_line(text) = self.class.one_line(text)
  end
end
