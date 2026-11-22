# frozen_string_literal: true

require "rake/testtask"
require "etc"
require "open3"

# Running the suite serially takes ~48s, almost all of it spent sleeping inside
# the actor/cron/channel tests (user CPU is only ~5s). Every test file is
# independent - test_helper points HOME at a per-process tmpdir and each test
# builds its own isolated workspace - so the work can safely be spread over
# multiple Ruby processes.
#
# Units of work are (file, test methods) pairs, not whole files: single files
# like test_actors.rb hold 20+ slow tests, and leaving them unsplit would put a
# ~21s floor under an otherwise parallel suite.
#
#   bundle exec rake test              # auto: one worker per CPU
#   JOBS=4 bundle exec rake test       # limit workers
#   TESTS_PER_SHARD=4 bundle exec rake test
#   bundle exec rake test_serial       # one process, for debugging
TEST_FILES = FileList["test/test_*.rb"].exclude("test/test_helper.rb")

# A shard carrying more than this many tests is split again. Tuned by
# measurement: with 68 test files, 20 balances process startup (~0.4s each)
# against tail latency better than the 12 that fit when there were fewer.
def tests_per_shard
  Integer(ENV["TESTS_PER_SHARD"] || 20, exception: false)&.clamp(1, 200) || 20
end

def test_workers(count)
  requested = ENV["JOBS"] || ENV["PARALLEL_WORKERS"]
  workers = requested ? Integer(requested, exception: false) || 1 : Etc.nprocessors
  [[workers, 1].max, count].min
end

# [file, nil, n] means "run the whole file"; [file, [names], n] means "run only
# these test methods". Shards are interleaved rather than sliced so a file whose
# expensive tests are clustered does not produce one giant shard.
#
# Methods are matched at any indentation because not every file defines them in
# a plain class body, and duplicates are dropped: a repeated name would be run
# once by minitest but would otherwise inflate the shard count.
def test_methods(file)
  File.read(file).scan(/^\s*def (test_\w+)/).flatten.uniq
end

def work_units(files, per_shard)
  units = []
  files.each do |file|
    methods = test_methods(file)
    shards = (methods.size.to_f / per_shard).ceil
    # Small files tend to be the ones made of slow tests (test_actors.rb has 22
    # tests but takes ~21s serially), so give them more shards than the size
    # alone would suggest.
    shards = [shards, 4].max if methods.size <= 30
    shards = [shards, methods.size].min
    if shards < 2
      units << [file, nil, methods.size]
    else
      buckets = Array.new(shards) { [] }
      methods.each_with_index { |m, i| buckets[i % shards] << m }
      buckets.each { |b| units << [file, b, b.size] unless b.empty? }
    end
  end
  units
end

def run_unit(file, methods, timeout: nil)
  args = ["-Ilib", "-Itest", file]
  args += ["-n", "/^(#{methods.map { |m| Regexp.escape(m) }.join('|')})$/"] if methods
  return Open3.capture2e(RbConfig.ruby, *args) unless timeout

  # Timeout.timeout around Open3.capture2e closes its pipes from another
  # thread, which raises IOError inside Open3's reader threads. Spawn with
  # explicit pipes and kill the child on timeout instead.
  stdout_r, stdout_w = IO.pipe
  stderr_r, stderr_w = IO.pipe
  # Own a process group so a timeout can kill the child *and* anything it
  # spawned (Ractors leave threads that keep the pipes open and burn CPU).
  pid = Process.spawn(RbConfig.ruby, *args, out: stdout_w, err: stderr_w, pgroup: true)
  stdout_w.close
  stderr_w.close
  begin
    # Poll both the pipe and the child. A child that spawns a grandchild can
    # keep the pipe open after it exits, so neither a blocking read nor a
    # blocking waitpid is safe on its own.
    output = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    drained_at = nil
    waited = nil
    loop do
      open_pipes = [ stdout_r, stderr_r ].reject(&:closed?)
      unless open_pipes.empty?
        if IO.select(open_pipes, nil, nil, 0.01)
          open_pipes.each do |io|
            begin
              output << io.read_nonblock(65536)
            rescue IO::WaitReadable
              next
            rescue EOFError
              io.close
            end
          end
        end
      end
      waited ||= Process.waitpid2(pid, Process::WNOHANG)
      if waited
        # Once the child is gone, give any grandchild holding the pipe at most
        # a second to close; otherwise move on instead of burning the timeout.
        drained_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        break if open_pipes.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= drained_at
      end
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    end
    timed_out = waited.nil?
    if timed_out
      Process.kill("KILL", -pid) rescue nil
      waited = Process.waitpid2(pid)
    end
    [ output, waited[1], timed_out ]
  ensure
    stdout_r.close
    stderr_r.close
  end
end

desc "Run the test suite in parallel (one process per shard)"
task :test do
  files = TEST_FILES.to_a.sort
  abort "No test files found" if files.empty?

  units = work_units(files, tests_per_shard)
  # Longest-processing-time first: with a shared queue this keeps the tail short.
  units.sort_by! { |u| -u[2] }
  workers = test_workers(units.size)

  queue = Queue.new
  units.each { |u| queue << u }
  results = Queue.new
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  # A hung shard used to hold every result back until the whole run timed out,
  # leaving no clue which test was stuck. Cap each shard and stream its status
  # as it lands so the slow one is visible immediately.
  shard_timeout = Integer(ENV["SHARD_TIMEOUT"] || 120, exception: false)&.clamp(1, 3600) || 120

  Array.new(workers) do
    Thread.new do
      loop do
        file, methods, = begin
          queue.pop(true)
        rescue ThreadError
          break
        end

        label = methods ? "#{file} (#{methods.size} tests)" : file
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        output, status, timed_out = run_unit(file, methods, timeout: shard_timeout)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        ok = !timed_out && status.success?
        results << [label, ok, output, elapsed]
        printf("%-58s %6.2fs  %s\n", label, elapsed, ok ? "ok" : (timed_out ? "TIMEOUT" : "FAILED"))
        $stdout.flush
      end
    end
  end.each(&:join)

  failures = []
  runs = 0
  assertions = 0
  results.size.times do
    label, ok, output, = results.pop
    summary = output.scan(/(\d+) runs, (\d+) assertions/).last
    runs += summary[0].to_i if summary
    assertions += summary[1].to_i if summary
    failures << [label, output] unless ok
  end

  total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts
  puts "Finished in #{format('%.2f', total)}s " \
       "(#{workers} workers, #{units.size} shards, #{files.size} files), " \
       "#{runs} runs, #{assertions} assertions"

  unless failures.empty?
    failures.each do |label, output|
      puts
      puts "=" * 78
      puts "FAILED: #{label}"
      puts "=" * 78
      puts output
    end
    abort "#{failures.size} of #{units.size} shards failed: " \
          "#{failures.map(&:first).join(', ')}"
  end
end

desc "Run the whole suite in a single process (debugging)"
Rake::TestTask.new(:test_serial) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = TEST_FILES
end

task default: :test
