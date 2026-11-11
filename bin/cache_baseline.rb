#!/usr/bin/env ruby
# frozen_string_literal: true

# What the prompt cache actually did, read from the session archive.
#
# Item 4 of PROMPT_CACHING_PLAN.md: a baseline recorded before the plan's
# changes, so the changes can be measured instead of assumed. It reads the
# archive read-only — the session meta carries the per-request hit rates of the
# last twelve requests and the token totals of the whole session, which is
# everything that existed before request_cache did.
#
#   bin/cache_baseline.rb [path/to/sessions.db]
#
# A copy is enough and safer: `cp ~/.rubot/sessions.db /tmp/baseline.db`.
require "sqlite3"
require "json"

DB = ARGV[0] || File.expand_path("~/.rubot/sessions.db")

# Model ids in this archive come from a gateway (`deepseek-v4.1-flash`,
# `glm-5.3-flash`), so the provider is inferred from the family name rather than
# from a prefix. An id that matches nothing is reported as `other` instead of
# being guessed at: the point of the table is to know which provider the numbers
# belong to.
def provider_of(model)
  case model
  when /claude/i then "anthropic"
  when /\Agpt/i, /\Ao[134]/i, %r{\Aopenai/}i then "openai"
  when /gemini/i, %r{\Agoogle/}i then "google"
  when /\Adeepseek/i then "deepseek"
  when "" then "(no epoch)"
  else "other"
  end
end

def median(values)
  return nil if values.empty?

  sorted = values.sort
  mid = sorted.size / 2
  sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def pct(value)
  value.nil? ? "  n/a" : format("%5.1f%%", value * 100)
end

def share(part, total)
  total.zero? ? "  n/a" : format("%5.1f%%", part * 100.0 / total)
end

db = SQLite3::Database.new(DB, readonly: true)
rows = db.execute("SELECT id, meta, msg_count, created_at, updated_at FROM sessions WHERE meta IS NOT NULL")

sessions = rows.filter_map do |id, meta_json, msg_count, created, updated|
  meta = JSON.parse(meta_json) rescue nil
  next unless meta

  usage = meta["usage"].is_a?(Hash) ? meta["usage"] : {}
  next if usage["requests"].to_i.zero?

  epoch = meta["system_prompt_epoch"].is_a?(Hash) ? meta["system_prompt_epoch"] : {}
  model = epoch["model"].to_s
  prompt = usage["prompt_tokens"].to_i
  cached = usage["cached_tokens"].to_i
  {
    id: id, model: model, provider: provider_of(model),
    prompt: prompt, cached: cached, uncached: prompt - cached,
    creation: usage["cache_creation_tokens"].to_i,
    requests: usage["requests"].to_i, messages: msg_count.to_i,
    created: created.to_s, updated: updated.to_s,
    rates: Array(meta["cache_history"]).map(&:to_f)
  }
end

total_uncached = sessions.sum { |s| s[:uncached] }
rates = sessions.flat_map { |s| s[:rates] }

puts "== per provider: whole session history =="
printf("%-11s %4s %7s %12s %12s %7s %7s\n", "provider", "ses", "req", "prompt", "cached", "hit", "median")
sessions.group_by { |s| s[:provider] }
        .sort_by { |_, list| -list.sum { |s| s[:prompt] } }
        .each do |provider, list|
  prompt = list.sum { |s| s[:prompt] }
  cached = list.sum { |s| s[:cached] }
  printf("%-11s %4d %7d %12d %12d %7s %7s\n",
         provider, list.size, list.sum { |s| s[:requests] }, prompt, cached,
         pct(prompt.positive? ? cached.to_f / prompt : nil),
         pct(median(list.flat_map { |s| s[:rates] })))
end

all_prompt = sessions.sum { |s| s[:prompt] }
all_cached = sessions.sum { |s| s[:cached] }
puts
puts "== all sessions =="
puts "sessions=#{sessions.size} requests=#{sessions.sum { |s| s[:requests] }}"
puts "prompt=#{all_prompt} cached=#{all_cached} uncached=#{total_uncached} " \
     "hit=#{pct(all_prompt.positive? ? all_cached.to_f / all_prompt : nil)}"
puts "cache_creation_tokens reported: #{sessions.sum { |s| s[:creation] }}"
puts "per-request hit rate (last 12 per session, n=#{rates.size}): " \
     "median=#{pct(median(rates))} mean=#{pct(rates.empty? ? nil : rates.sum / rates.size)}"
buckets = rates.group_by { |r| r.zero? ? "0%" : r < 0.5 ? "<50%" : r < 0.9 ? "50-90%" : ">=90%" }
puts "distribution: " + buckets.sort_by { |_, v| -v.size }.map { |k, v| "#{k} #{v.size}" }.join(" · ")
puts "zero-hit requests: #{rates.count(0.0)} of #{rates.size} " \
     "in #{sessions.count { |s| s[:rates].include?(0.0) }} sessions"

puts
puts "== where the uncached tokens go: top 10 sessions =="
top = sessions.sort_by { |s| -s[:uncached] }.first(10)
top.each do |s|
  printf("%-34s %-22s uncached=%11d hit=%s req=%4d msgs=%4d updated=%s\n",
         s[:id][0, 34], s[:model].empty? ? "(no epoch)" : s[:model], s[:uncached],
         pct(s[:prompt].positive? ? s[:cached].to_f / s[:prompt] : nil),
         s[:requests], s[:messages], s[:updated][0, 10])
end
puts "top 10 share of all uncached tokens: #{share(top.sum { |s| s[:uncached] }, total_uncached)}"

bare = sessions.select { |s| s[:model].empty? }
puts
puts "== sessions without a pinned prompt (pre-pin era) =="
puts "count=#{bare.size} uncached=#{bare.sum { |s| s[:uncached] }} " \
     "share=#{share(bare.sum { |s| s[:uncached] }, total_uncached)}"
puts "updated range: #{bare.map { |s| s[:updated] }.min} .. #{bare.map { |s| s[:updated] }.max}"
