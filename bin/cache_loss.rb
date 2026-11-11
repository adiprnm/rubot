#!/usr/bin/env ruby
# frozen_string_literal: true

# Where the cache tokens actually go: every request that did not read the whole
# prefix back, what it cost, and which of the two shapes it was.
#
# `bin/cache_weekly.rb` answers "how well did the prefix hold". This answers the
# next question -- "what did the misses cost, and can any of them be avoided" --
# by accounting for the re-read instead of the hit rate. A 92% hit rate can hide
# a single 100k-token miss, and a 99% rate over one big prompt can still be the
# most expensive way to send it.
#
#   bin/cache_loss.rb [path/to/sessions.db] [--session ID] [--min-tokens N]
#
# Two kinds of miss, because the fix is different:
#
#   boundary  A message in the middle changed: `diverged_at` points at it, and
#             everything after it is read again. Produced by the block-aligned
#             tool-result trim (`tool_result_keep`) and its argument redaction.
#             It is one event per block of results, by design -- the number to
#             watch is the cost per event against the tokens the trim saves.
#
#   intact    The prefix did not move and the provider still reported little or
#             no cache read. Nothing in the request explains it: provider-side,
#             either a different machine, a write that had not landed, or an
#             expired entry.
#
# Requests that are explained by state (first request, model switch, epoch
# change, tool catalog change, a trim that moved the window) are counted
# separately: they are the price of doing the work, not a defect.
require "sqlite3"

ARGV_CLEAN = ARGV.dup
session_flag = ARGV_CLEAN.index("--session")
SESSION = session_flag ? ARGV_CLEAN.delete_at(session_flag + 1) : nil
ARGV_CLEAN.delete_at(session_flag) if session_flag
min_flag = ARGV_CLEAN.index("--min-tokens")
MIN_TOKENS = min_flag ? ARGV_CLEAN.delete_at(min_flag + 1).to_i : 0
ARGV_CLEAN.delete_at(min_flag) if min_flag
DB = ARGV_CLEAN[0] || File.expand_path("~/.rubot/sessions.db")

db = SQLite3::Database.new(DB, readonly: true)
db.results_as_hash = true
rows = db.execute(<<~SQL)
  SELECT session_id, created_at, model, prompt_tokens, cached_tokens, blocks,
         diverged_at, diverged_kind, diverged_role, turns, epoch, tools, summary, auxiliary
  FROM request_cache
  #{SESSION ? "WHERE session_id = #{db.quote(SESSION)}" : ""}
  ORDER BY id
SQL

# One entry per request that read less than the whole prefix. `reason` is the
# reading a human needs, not a label the code already prints: state, boundary,
# intact.
events = []
by_session = rows.group_by { |row| row["session_id"] }

by_session.each do |session_id, session_rows|
  session_rows.each_with_index do |row, index|
    prompt = row["prompt_tokens"].to_i
    cached = row["cached_tokens"].to_i
    next if prompt.zero?
    next if cached >= prompt

    previous = session_rows[0...index].reverse.find { |r| r["auxiliary"] == row["auxiliary"] }
    reason =
      if previous.nil?
        "cold"
      elsif row["model"].to_s != previous["model"].to_s
        "model"
      elsif row["summary"].to_s != previous["summary"].to_s
        "compaction"
      elsif row["epoch"].to_s != previous["epoch"].to_s
        "epoch"
      elsif row["tools"].to_s != previous["tools"].to_s
        "tools"
      elsif row["turns"].to_i < previous["turns"].to_i
        "window"
      elsif row["diverged_at"].nil?
        "partial"
      elsif row["diverged_at"].to_i.negative?
        cached.zero? ? "intact" : "partial"
      else
        "boundary"
      end

    events << {
      session: session_id,
      at: row["created_at"],
      reason: reason,
      role: row["diverged_role"].to_s,
      at_block: row["diverged_at"],
      blocks: row["blocks"].to_i,
      prompt: prompt,
      cached: cached,
      reread: prompt - cached,
      index: index
    }
  end
end

def pct(value)
  format("%5.1f%%", value * 100)
end

def n(value)
  value.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end

puts "sumber: #{DB}"
puts "sesi: #{by_session.size}, request: #{rows.size}"

total_prompt = rows.sum { |r| r["prompt_tokens"].to_i }
total_reread = events.sum { |e| e[:reread] }
puts "prompt token total: #{n(total_prompt)}"
puts "token dibaca ulang: #{n(total_reread)} (#{pct(total_prompt.zero? ? 0 : total_reread.to_f / total_prompt)})"
puts

puts "== per sebab =="
puts format("%-10s %5s %14s %8s", "sebab", "n", "token ulang", "share")
events.group_by { |e| e[:reason] }.sort_by { |_, list| -list.sum { |e| e[:reread] } }.each do |reason, list|
  cost = list.sum { |e| e[:reread] }
  puts format("%-10s %5d %14s %8s", reason, list.size, n(cost),
              pct(total_reread.zero? ? 0 : cost.to_f / total_reread))
end
puts

EXPLAINED = %w[cold model compaction epoch tools window].freeze
suspicious = events.reject { |e| EXPLAINED.include?(e[:reason]) }
puts "== miss yang bisa dijelaskan: #{events.count { |e| EXPLAINED.include?(e[:reason]) }} event, " \
     "#{n(events.select { |e| EXPLAINED.include?(e[:reason]) }.sum { |e| e[:reread] })} token =="
puts "== miss yang perlu dilihat: #{suspicious.size} event, #{n(suspicious.sum { |e| e[:reread] })} token =="
puts

# The concern from item 22: two separate rewrites landing on consecutive
# requests means the prefix was broken twice instead of once.
consecutive = suspicious.each_cons(2).select { |a, b| a[:session] == b[:session] && b[:index] == a[:index] + 1 }
puts "== berurutan (dua re-read berturut-turut) = #{consecutive.size} pasang =="
consecutive.first(12).each do |a, b|
  puts format("  %s %-9s %7s token  ->  %s %-9s %7s token",
              a[:at][5, 14], a[:reason], n(a[:reread]),
              b[:at][5, 14], b[:reason], n(b[:reread]))
end
puts

boundary = events.select { |e| e[:reason] == "boundary" }
unless boundary.empty?
  cost = boundary.sum { |e| e[:reread] }
  distances = boundary.map { |e| e[:blocks] - e[:at_block].to_i }.sort
  puts "== batas bergeser =="
  puts "  #{boundary.size} event, rata-rata #{n(cost / boundary.size)} token, median #{n(distances[distances.size / 2])} blok"
  puts "  jarak blok yang berubah dari ujung: #{distances.join(", ")}"
  puts "  per sesi: #{(boundary.size.to_f / by_session.size).round(1)} event"
  puts
end

puts "== 12 event termahal =="
events.sort_by { |e| -e[:reread] }.first(12).each do |e|
  next if e[:reread] < MIN_TOKENS

  puts format("  %s %s %-15s %-9s p=%7s c=%7s ulang=%7s blok=%d d=%s",
              e[:session][-12..], e[:at][11, 8], e[:reason], e[:role].empty? ? "-" : e[:role],
              n(e[:prompt]), n(e[:cached]), n(e[:reread]), e[:blocks], e[:at_block].inspect)
end
