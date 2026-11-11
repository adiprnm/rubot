#!/usr/bin/env ruby
# frozen_string_literal: true

# The weekly reading of the prompt cache: did the prefix hold, and what did the
# requests that missed cost?
#
# Item 20 of PROMPT_CACHING_PLAN.md, second half. `bin/cache_baseline.rb` takes
# the measure of the whole archive once; this takes one window of it, per
# provider and model, and puts it next to the numbers recorded in
# PROMPT_CACHING_BASELINE.md so the drift is a subtraction instead of a
# question.
#
#   bin/cache_weekly.rb [path/to/sessions.db] [--days 7]
#
#   cp ~/.rubot/sessions.db /tmp/weekly.db
#   bin/cache_weekly.rb /tmp/weekly.db --days 7
#
# A cron line, if a weekly mail is wanted:
#
#   0 8 * * 1 cp ~/.rubot/sessions.db /tmp/weekly.db && cd ~/Projects/oss/rubot \
#     && bin/cache_weekly.rb /tmp/weekly.db --days 7
#
# Everything here comes from `request_cache`, which records one row per
# request. Sessions live before that table existed have no rows and cannot be
# measured this way — use the baseline script for those.
require "sqlite3"

# `--days 7` and `--days=7` both work: a report a human types by hand gets the
# spacing it expects, and a cron line can keep the compact form.
ARGV_CLEAN = ARGV.dup
days_after = ARGV_CLEAN.index("--days")
days_value = days_after ? ARGV_CLEAN.delete_at(days_after + 1) : nil
ARGV_CLEAN.delete_at(days_after) if days_after
days_flag = ARGV_CLEAN.find { |arg| arg.start_with?("--days=") }
ARGV_CLEAN.delete(days_flag)
DAYS = (days_value || days_flag&.split("=")&.last || 7).to_i
DB = ARGV_CLEAN[0] || File.expand_path("~/.rubot/sessions.db")

# The baseline, from PROMPT_CACHING_BASELINE.md (recorded 2026-11-11 from
# 9,174 requests across the whole archive). Kept as constants because a
# report that silently redefines its own yardstick measures nothing.
BASELINE = {
  weighted: 0.871,
  median: 0.992,
  zero_share: 22.0 / 371,
  requests: 9_174
}.freeze

def median(values)
  return nil if values.empty?

  sorted = values.sort
  mid = sorted.size / 2
  sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def pct(value)
  value.nil? ? "  n/a" : format("%5.1f%%", value * 100)
end

# A delta that says which way is good, so a reader does not have to remember
# whether more cache is better than less.
def delta(now, was, unit: "pt")
  return "  n/a" if now.nil?

  diff = (now - was) * 100
  arrow = diff.abs < 0.05 ? "=" : diff.positive? ? "+" : "-"
  format("%s%5.1f%s", arrow, diff.abs, unit)
end

def re_read(row)
  [ row["prompt_tokens"].to_i - row["cached_tokens"].to_i - row["cache_creation_tokens"].to_i, 0 ].max
end

db = SQLite3::Database.new(DB, readonly: true)
db.results_as_hash = true
rows = db.execute(
  "SELECT * FROM request_cache WHERE created_at >= ? ORDER BY id", [ (Time.now.utc - (DAYS * 86_400)).strftime("%Y-%m-%dT%H:%M:%SZ") ]
)

if rows.empty?
  puts "tidak ada request dalam #{DAYS} hari terakhir (#{DB})"
  exit 0
end

puts "== #{DAYS} hari terakhir: #{rows.size} request, #{rows.map { |r| r['session_id'] }.uniq.size} sesi =="
puts "rentang: #{rows.first['created_at']} .. #{rows.last['created_at']}"

# The headline is weighted: a session with a million tokens counts more than
# one with a hundred, because that is what the invoice does.
prompt = rows.sum { |r| r["prompt_tokens"].to_i }
cached = rows.sum { |r| r["cached_tokens"].to_i }
rates = rows.map { |r| r["prompt_tokens"].to_i.zero? ? 0.0 : r["cached_tokens"].to_f / r["prompt_tokens"].to_i }
weighted = prompt.zero? ? nil : cached.to_f / prompt
zero = rates.count(0.0)

puts
puts "hit rate (weighted)  #{pct(weighted)}   vs baseline #{pct(BASELINE[:weighted])}  #{delta(weighted, BASELINE[:weighted])}"
puts "hit rate (median)    #{pct(median(rates))}   vs baseline #{pct(BASELINE[:median])}  #{delta(median(rates), BASELINE[:median])}"
puts "request 0% cache     #{zero} dari #{rates.size} (#{pct(rates.empty? ? nil : zero.to_f / rates.size)})" \
     "   vs baseline #{pct(BASELINE[:zero_share])}  #{delta(rates.empty? ? nil : zero.to_f / rates.size, BASELINE[:zero_share])}"
puts "token dibaca ulang   #{rows.sum { |r| re_read(r) }} dari #{prompt} (#{pct(prompt.zero? ? nil : rows.sum { |r| re_read(r) }.to_f / prompt)})"

puts
puts "== per model =="
printf("%-24s %-9s %6s %8s %8s %8s %13s\n", "model", "provider", "req", "hit", "median", "0%", "re-read")
rows.group_by { |r| [ r["model"].to_s, r["provider"].to_s ] }
    .sort_by { |_, list| -list.sum { |r| r["prompt_tokens"].to_i } }
    .each do |(model, provider), list|
  prompt = list.sum { |r| r["prompt_tokens"].to_i }
  cached = list.sum { |r| r["cached_tokens"].to_i }
  rates = list.map { |r| r["prompt_tokens"].to_i.zero? ? 0.0 : r["cached_tokens"].to_f / r["prompt_tokens"].to_i }
  printf("%-24s %-9s %6d %8s %8s %8d %13d\n",
         model.empty? ? "(kosong)" : model, provider.empty? ? "-" : provider, list.size,
         pct(prompt.zero? ? nil : cached.to_f / prompt), pct(median(rates)),
         rates.count(0.0), list.sum { |r| re_read(r) })
end

# Two kinds of miss: one where our own payload moved (explained — a trim, a
# rewrite) and one where it did not (the provider read nothing from a prefix
# that never changed). Only the second is a mystery worth a look.
moved = rows.reject { |r| r["diverged_at"].nil? || r["diverged_at"].to_i.negative? }
if moved.any?
  puts
  puts "== prefix bergeser (miss yang bisa dijelaskan): #{moved.size} =="
  moved.sort_by { |r| -re_read(r) }.first(5).each do |r|
    printf("  %s  %-18s blok %-4s div@%-4s %-9s re-read %8d\n",
           r["created_at"][5, 11], r["model"].to_s[0, 18], r["blocks"], r["diverged_at"],
           r["diverged_role"].to_s.empty? ? "-" : r["diverged_role"], re_read(r))
  end
end

# The streak the runtime guardrail warns about, read back: three or more zero
# reads in a row on a prefix that did not move.
streaks = rows.group_by { |r| r["session_id"] }.filter_map do |session_id, list|
  longest = 0
  run = 0
  list.each do |row|
    intact = row["diverged_at"].nil? || row["diverged_at"].to_i.negative?
    run = row["cached_tokens"].to_i.zero? && intact ? run + 1 : 0
    longest = run if run > longest
  end
  [ session_id, longest ] if longest >= 3
end
if streaks.any?
  puts
  puts "== rentetan 0% pada prefix utuh (dugaan sisi provider) =="
  streaks.sort_by { |_, longest| -longest }.each { |session_id, longest| puts "  #{session_id}: #{longest} request berurutan" }
end
