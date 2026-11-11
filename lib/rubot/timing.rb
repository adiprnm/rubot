# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module Rubot
  # Where a provider request spends its time: the wait for the first byte (the
  # prompt being read, the model thinking) and the rest of it (the answer being
  # written). One number cannot explain a slow turn — a five-second round can be
  # a slow provider, a huge prompt, or a long answer — so they are recorded
  # separately.
  #
  # Off unless RUBOT_TIMING is set. A chat that writes a log line for every
  # request it makes is noise, and this is a diagnostic, not telemetry.
  module Timing
    # Frozen on purpose: a provider request runs inside a session Ractor, and a
    # Ractor may only read constants that are shareable. An unfrozen String
    # here raises Ractor::IsolationError inside the actor, where it looks like
    # a swallowed diagnostic instead of a broken path.
    PATH = File.join(Dir.home, ".rubot", "timing.jsonl").freeze

    module_function

    # Where records go. `RUBOT_TIMING_PATH` exists so a test can point it at a
    # file in its own temp directory instead of the real one.
    def path
      override = ENV["RUBOT_TIMING_PATH"].to_s.strip
      override.empty? ? PATH : override
    end

    def enabled?
      value = ENV["RUBOT_TIMING"].to_s.strip.downcase
      !value.empty? && value != "0" && value != "false"
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # `first_byte` is the moment the first content or reasoning chunk arrived —
    # nil when the provider answered all at once.
    def record(model:, prompt_bytes:, total:, first_byte: nil, tool_calls: nil, kind: "stream", usage: nil)
      return unless enabled?

      line = {
        "at" => Time.now.iso8601,
        "model" => model.to_s,
        "kind" => kind,
        "prompt_bytes" => prompt_bytes.to_i,
        "first_byte_s" => first_byte&.round(3),
        "total_s" => total.to_f.round(3),
        "tool_calls" => tool_calls,
        "prompt_tokens" => usage && usage["prompt_tokens"],
        "output_tokens" => usage && usage["completion_tokens"]
      }
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |file| file.puts(JSON.generate(line.compact)) }
    rescue StandardError => e
      # A diagnostic must never be the reason a request fails.
      warn "[timing] #{e.class}: #{e.message}" if Rubot.debug?
    end

    # A summary of what has been recorded: per model, how much of the round trip
    # is the first byte versus the rest of the answer.
    def report(path: nil, limit: 2000)
      path ||= self.path
      return "no timing log at #{path} (rubot with RUBOT_TIMING=1 writes one)" unless File.exist?(path)

      rows = File.readlines(path).last(limit).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
      return "timing log is empty" if rows.empty?

      by_model = rows.group_by { |row| row["model"] }
      lines = []
      by_model.sort_by { |model, group| -group.size }.each do |model, group|
        totals = group.map { |row| row["total_s"].to_f }.sort
        firsts = group.filter_map { |row| row["first_byte_s"] }.sort
        bytes = group.map { |row| row["prompt_bytes"].to_i }.sort
        calls = group.filter_map { |row| row["tool_calls"] }
        lines << format(
          "%-32s n=%4d | total p50 %5.2fs p90 %5.2fs | first-byte p50 %5.2fs | prompt p50 %6dB | tool calls p50 %.0f",
          model, group.size,
          totals[totals.size / 2], totals[(totals.size * 0.9).floor],
          firsts.empty? ? 0 : firsts[firsts.size / 2],
          bytes[bytes.size / 2],
          calls.empty? ? 0 : calls.sort[calls.size / 2]
        )
      end
      lines.join("\n")
    end
  end
end
