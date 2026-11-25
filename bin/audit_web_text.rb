# frozen_string_literal: true

# Finds text that reaches a reader from a web template without going through
# the dictionary.
#
# It reads the ERB source, not the rendered page, because a template is the
# place a word gets written in place. Three places a word can hide are checked:
# the text between tags, the attributes a screen reader or a tooltip reads
# (`placeholder`, `title`, `aria-label`, `alt`, including their Alpine
# `x-bind:` forms), and the inline handler attributes whose string argument is
# shown in a browser dialog (`onsubmit="return confirm('…')"`).
#
# Script and style blocks are removed first: their contents are code, and the
# goal is what a reader sees. ERB tags are replaced with a marker before the
# source is split, so an expression inside an attribute cannot look like markup.
# A value that is an Alpine expression (`busy ? 'A' : 'B'`) is opened up and
# only its quoted literals are reported -- those literals *are* shown.
#
# Usage: ruby bin/audit_web_text.rb [paths...]
# Exit status is 1 when anything is left to translate.

VIEWS = File.expand_path("../lib/rubot/web/views", __dir__)
# An attribute a tooltip, a placeholder or a screen reader reads.
ATTRIBUTES = %w[placeholder title aria-label alt].freeze
# An attribute whose quoted argument a browser shows in a dialog.
HANDLERS = %w[onsubmit onclick].freeze
# `esc` is the name of a key on a keyboard, not a word to translate.
KEYCAPS = %w[esc Esc ESC].freeze
# What an ERB tag whatever its contents looks like once removed.
MARK = "\u0000"

# One finding: the file, the line it sits on, and the text that would show.
Finding = Struct.new(:file, :line, :text, :where, keyword_init: true)

def strip_code(source)
  source.gsub(%r{<script\b[^>]*>.*?</script>}m, "")
        .gsub(%r{<style\b[^>]*>.*?</style>}m, "")
        .gsub(/<!--.*?-->/m, "")
end

# A literal is text if it holds a run of letters and is not just a keycap or an
# entity (`&times;` is a character, not a word).
def word?(text)
  stripped = text.strip
  return false if stripped.empty?
  return false if KEYCAPS.include?(stripped)
  return false if stripped.match?(/\A(&\w+;|\s)+\z/)

  stripped.match?(/[A-Za-z]{2,}/)
end

# The quoted literals inside an expression or a handler: `busy ? 'A' : 'B'`
# hides two words, `stopping ? x : y` hides none.
def literals_in(expression)
  expression.scan(/"([^"]*)"|'([^']*)'/).map { |a, b| a || b }
end

def expression?(text)
  text.match?(/[?:]|&&|\|\||=>|\w+\(/)
end

def scan(source)
  findings = []
  flat = strip_code(source).gsub(/<%.*?%>/m, MARK)

  # --- attributes ---------------------------------------------------------
  # Anchored on the attribute name so `x-bind:title` is read too, and on the
  # quoted value so a multi-line expression is taken whole.
  names = (ATTRIBUTES + HANDLERS).join("|")
  flat.scan(/(?:\w[\w-]*:)?(#{names})\s*=\s*(["'])(.*?)\2/m) do |name, _quote, value|
    line = flat[0...Regexp.last_match.begin(0)].count("\n") + 1
    candidates =
      if HANDLERS.include?(name)
        literals_in(value)
      elsif value.include?(MARK) && !expression?(value.delete(MARK))
        # Literal words around an ERB expression: `aria-label="Buka <%= name %>"`
        # is a word the reader hears, and replacing the expression with a marker
        # must not hide it. Each piece between markers is read as text.
        value.split(MARK)
      elsif value.include?(MARK) || expression?(value)
        literals_in(value)
      else
        [ value ]
      end

    candidates.each do |candidate|
      next unless word?(candidate)

      findings << Finding.new(file: nil, line: line, text: candidate, where: name)
    end
  end

  # --- text between tags --------------------------------------------------
  # ERB is a marker by now, so every run outside `<...>` is text a reader sees.
  # A marker on its own carries no word, so it is simply not reported.
  # A tag may hold a quoted value with `>` in it (an Alpine arrow function), so
  # the quoted runs are skipped over rather than the tag ending at the first `>`.
  flat.scan(/<(?:"[^"]*"|'[^']*'|[^<>"'])*>|[^<>]+/m) do |chunk|
    next if chunk.start_with?("<")

    line = flat[0...Regexp.last_match.begin(0)].count("\n") + 1
    [ chunk ].each do |candidate|
      next unless word?(candidate)

      findings << Finding.new(file: nil, line: line, text: candidate, where: "text")
    end
  end

  findings
end

paths = ARGV.empty? ? Dir.glob(File.join(VIEWS, "*.erb")).sort : ARGV
total = 0
by_file = {}

paths.each do |path|
  findings = scan(File.read(path))
  by_file[path] = findings
  total += findings.size
end

by_file.each do |path, findings|
  next if findings.empty?

  puts "\n== #{File.basename(path)} (#{findings.size})"
  findings.each { |f| puts "   #{f.line}: [#{f.where}] #{f.text.inspect}" }
end

puts "\n#{total} candidate(s) across #{by_file.count { |_p, f| f.any? }} file(s)"
exit(total.zero? ? 0 : 1)
