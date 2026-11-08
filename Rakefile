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
# measurement: 12 balances process startup (~0.4s each) against tail latency
# better than 8 or 16.
def tests_per_shard
  Integer(ENV["TESTS_PER_SHARD"] || 12, exception: false)&.clamp(1, 200) || 12
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

def run_unit(file, methods)
  args = ["-Ilib", "-Itest", file]
  args += ["-n", "/^(#{methods.map { |m| Regexp.escape(m) }.join('|')})$/"] if methods
  Open3.capture2e(RbConfig.ruby, *args)
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

  Array.new(workers) do
    Thread.new do
      loop do
        file, methods, = begin
          queue.pop(true)
        rescue ThreadError
          break
        end

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        output, status = run_unit(file, methods)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        results << [file, methods, status.success?, output, elapsed]
      end
    end
  end.each(&:join)

  failures = []
  runs = 0
  assertions = 0
  results.size.times do
    file, methods, ok, output, elapsed = results.pop
    summary = output.scan(/(\d+) runs, (\d+) assertions/).last
    runs += summary[0].to_i if summary
    assertions += summary[1].to_i if summary
    label = methods ? "#{file} (#{methods.size} tests)" : file
    if ok
      printf("%-58s %6.2fs  ok\n", label, elapsed)
    else
      failures << [label, output]
      printf("%-58s %6.2fs  FAILED\n", label, elapsed)
    end
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
