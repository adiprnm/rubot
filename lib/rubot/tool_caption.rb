# frozen_string_literal: true

require_relative "i18n"
require_relative "skill_load"

module Rubot
  # What a call is doing, in one sentence a reader who never saw the arguments
  # can follow.
  #
  # The same call is drawn in four places: the live web timeline, the replayed
  # transcript, the Telegram status card and the TUI transcript. A reader
  # comparing two of them must not find two different sentences about one call,
  # so the wording is derived here, from the arguments alone, and every surface
  # asks this module instead of formatting the arguments itself. The row a
  # delegated run leaves in the footer is deliberately not one of them: that row
  # is about an agent and the task it was given, not about the calls it makes
  # (see Web::SubagentLine).
  #
  # The sentence is the whole row, not a tail on the tool's name: `shell_exec`
  # and `file_ops` are the agent's words, not the reader's, and a row that said
  # them first made the reader translate before they could read. What the call
  # actually asked for is still one hover away (see `tooltip`).
  #
  # A shell command gets a sentence of its own where the vocabulary exists: the
  # common verbs of a working directory (`ls`, `grep`, `git status`, a test run)
  # are read as the thing the reader would have said, and only the ones nobody
  # would recognize are left as a plain "ran a command". `raw` is the one place
  # the command survives, for that hover.
  #
  # No sentence is written here: every branch names a key of the dictionary
  # (`tool.…` in lib/rubot/i18n.rb) and fills in what the arguments supply, so
  # the language the reader picked reaches the intent table, the verbs, the
  # durations and the place a call points at alike. The tables below say only
  # which operation has an entry of its own; the words are the dictionary's.
  module ToolCaption
    PATH_SEGMENTS = 3
    PATTERN_CHARS = 60
    URL_CHARS = 60
    # A question is a sentence, not a path: it gets more room than a pattern
    # before the row starts ellipsing.
    QUESTION_CHARS = 90

    DIRECTORY_WORDS = %w[ls ll la dir tree].freeze
    READ_WORDS = %w[cat less more head tail bat].freeze
    SEARCH_WORDS = %w[grep rg ag ack].freeze
    PACKAGE_WORDS = %w[npm pnpm yarn bun gem pip pip3].freeze
    # What says "run this, as the same command": they change who runs it, not
    # what it does, so the sentence is about what follows them.
    WRAPPERS = %w[sudo time nohup exec env command builtin].freeze
    # How a compound line is cut before anything is read out of it: the first
    # command is the one the reader asked for, and the rest is plumbing.
    SEPARATORS = /&&|\|\||;|\|/
    # An argument `sleep` accepts as a duration: everything coreutils takes, so
    # that the forms a runaway waiter actually writes are read rather than
    # ignored. `infinity` is in it because an unbounded wait is the one case
    # where rounding to "sebentar" would be the opposite of the truth.
    SLEEP_ARGUMENT = /\A([+-]?(?:inf(?:inity)?|(?:\d+(?:[.,]\d*)?|[.,]\d+)(?:e[+-]?\d+)?))([smhd])?\z/i

    # The operations each tool names in its arguments, and so the entries the
    # dictionary owes it (`tool.file.read`, `tool.cron.add`, …): a table here
    # and a key in both languages, nothing else. An operation this does not
    # list still reads as a sentence, through `tool.operation_unknown`, rather
    # than as the bare word the model happened to send.
    FILE_OPERATIONS = %w[read write edit append delete list info].freeze
    MEMORY_OPERATIONS = %w[read append update_section].freeze
    CRON_OPERATIONS = %w[add list detail remove enable disable].freeze
    # `start` is absent on purpose: it is the one operation with something to
    # say about the call (see `loop_caption`).
    LOOP_OPERATIONS = %w[status list pause resume raise stop undo].freeze
    INSTAGRAM_OPERATIONS = %w[connect status schedule publish posts cancel link disconnect].freeze
    GIT_OPERATIONS = %w[status diff log add commit push pull checkout branch stash show clone].freeze
    # A shell verb that says the same thing under another name: the sentence is
    # the one its target entry already has.
    GIT_ALIASES = { "fetch" => "pull", "switch" => "checkout" }.freeze
    # `gh` puts the noun before the verb (`gh pr create`), so its table is keyed
    # by the pair the reader typed, with the entries a pair may name alone
    # (`gh api`) keyed by their one word. A pair that is not here falls back to
    # `tool.gh.other` rather than to a guessed sentence.
    GH_OPERATIONS = {
      "pr create" => "pr_create",
      "pr list" => "pr_list",
      "pr view" => "pr_view",
      "pr status" => "pr_status",
      "pr checks" => "pr_checks",
      "pr diff" => "pr_diff",
      "pr checkout" => "pr_checkout",
      "pr merge" => "pr_merge",
      "pr comment" => "pr_comment",
      "pr review" => "pr_review",
      "issue create" => "issue_create",
      "issue list" => "issue_list",
      "issue view" => "issue_view",
      "issue comment" => "issue_comment",
      "run list" => "run_list",
      "run view" => "run_view",
      "run watch" => "run_watch",
      "run rerun" => "run_rerun",
      "run cancel" => "run_cancel",
      "workflow list" => "workflow_list",
      "workflow run" => "workflow_run",
      "repo view" => "repo_view",
      "repo clone" => "repo_clone",
      "release create" => "release_create",
      "release list" => "release_list",
      "auth status" => "auth_status",
      "api" => "api"
    }.freeze
    PACKAGE_OPERATIONS = {
      "install" => "install", "i" => "install", "add" => "install", "ci" => "install",
      "test" => "test", "t" => "test", "run" => "run", "build" => "build"
    }.freeze

    # `skills` is the answer to SkillLoad.names when the caller already asked
    # for it (see Web::Channel#run_turn), so one call does not read the same
    # arguments twice.
    def self.caption(tool_name, args, skills: nil)
      args = {} unless args.is_a?(Hash)
      # A skill load is a read with a meaning of its own, so it gets a sentence
      # of its own instead of the file tool's "reading <path>": the reader is
      # told the agent picked instructions up, not which file it opened.
      skills ||= SkillLoad.names(tool_name.to_s, args)
      loading = skill_caption(skills)
      return loading if loading

      # An entry whose only variable came through empty ("Reading %{target}")
      # ends on the space before it; the row must not.
      row_for(tool_name.to_s, args).rstrip
    end

    # How a call that picked instructions up is read: one skill by name, several
    # as one sentence listing them in the reader's language. nil when it loaded
    # none.
    def self.skill_caption(skills)
      return nil if skills.nil? || skills.empty?
      return I18n.t("tool.skill.load", name: skills.first) if skills.size == 1

      I18n.t("tool.skill.load_many", names: skill_list(skills))
    end

    # The names as a list the reader's language punctuates: a comma between all
    # but the last, and its own word before that one. Two names need no comma,
    # and three need one, so the list is built rather than the joiner repeated.
    def self.skill_list(names)
      list = Array(names).map(&:to_s).reject(&:empty?)
      return "" if list.empty?
      return list.first if list.size == 1

      "#{list[0..-2].join(I18n.t("tool.skill.separator"))}#{I18n.t("tool.skill.joiner")}#{list.last}"
    end

    # Which branch owns this call. Every branch names dictionary keys; none of
    # them writes a sentence.
    def self.row_for(name, args)
      case name
      when "shell_exec" then command_caption(args)
      when "file_ops" then file_caption(args)
      when "search" then search_caption(args)
      when "web_fetch" then fetch_caption(args)
      when "delegate" then delegate_caption(args)
      when "subagent_results" then I18n.t("tool.subagent_results")
      when "send_files" then send_caption(args)
      when "memory" then verb_caption("tool.memory", "tool.name.memory", MEMORY_OPERATIONS, args)
      when "cron" then verb_caption("tool.cron", "tool.name.cron", CRON_OPERATIONS, args)
      when "loop" then loop_caption(args)
      when "ask_user" then ask_caption(args)
      when "instagram"
        verb_caption("tool.instagram", "tool.name.instagram", INSTAGRAM_OPERATIONS, args,
                     other: "tool.instagram.other")
      when "notify" then I18n.t("tool.notify")
      else unknown_caption(name, args)
      end
    end

    # The call as the agent made it, for the one place a reader may still want
    # it: the tooltip on a web row. The name leads, since the row no longer
    # carries it.
    def self.tooltip(tool_name, args)
      name = tool_name.to_s
      # A question is not a hash to read out: the hover carries the whole
      # sentence and the choices it offered.
      if name == "ask_user"
        detail = ask_tooltip(args)
        return detail.empty? ? name : "#{name} · #{detail}"
      end

      snippet = raw(name, args)
      snippet.empty? ? name : "#{name} · #{snippet}"
    end

    # The arguments as they arrived: the first line of whichever one describes
    # the call, cut to a length a tooltip can hold.
    def self.raw(_tool_name, args)
      return "" unless args.is_a?(Hash) && !args.empty?

      key = %w[command path query url pattern title].find { |k| args.key?(k) } || args.keys.first
      value = args[key]
      # A tool that takes a list (send_files, a multi-file read) arrives as an
      # array, and an array inspected into a tooltip reads as punctuation.
      value = value.map(&:to_s).join(", ") if value.is_a?(Array)
      value.to_s.split("\n").first.to_s[0, 100]
    end

    # --- shell ------------------------------------------------------------

    def self.command_caption(args)
      command = args["command"].to_s.split("\n").first.to_s.strip
      return I18n.t("tool.shell.command") if command.empty?

      shell_intent(command) || I18n.t("tool.shell.command")
    end

    # The first command of a line, with the wrappers peeled off: what is left
    # is the verb the sentence is built on.
    def self.shell_intent(command)
      segment = first_segment(command)
      tokens = segment.split(/\s+/).reject(&:empty?)
      tokens = tokens.drop_while { |token| wrapper?(token) }
      head = tokens.shift.to_s
      return nil if head.empty?

      # `bundle exec rake test` is a rake run, and `env FOO=1 ls` is an ls.
      if head == "bundle" && tokens.first == "exec"
        tokens.shift
        head = tokens.shift.to_s
      end
      return nil if head.empty?

      intent_for(head, tokens, segment)
    end

    # The line's first real command: a leading `cd somewhere &&` says where the
    # work happened, not what the work was.
    def self.first_segment(command)
      segments = command.split(SEPARATORS).map(&:strip).reject(&:empty?)
      segments.shift while segments.first.to_s.match?(/\Acd\s/)
      segments.first.to_s
    end

    def self.wrapper?(token)
      WRAPPERS.include?(token) || (token.include?("=") && !token.start_with?("-"))
    end

    # The table the whole shell vocabulary hangs on: one entry per verb the
    # reader would recognize, each built from a key and the arguments. A verb
    # that is not here is not guessed at (see `command_caption`).
    def self.intent_for(head, tokens, segment)
      words = positional(tokens)

      case head
      when *DIRECTORY_WORDS
        I18n.t("tool.shell.directory",
               target: place(words.first, default: "tool.place.here", here: "tool.place.here"))
      when *READ_WORDS then read_intent(head, tokens, words)
      when *SEARCH_WORDS then search_intent(segment)
      when *PACKAGE_WORDS then package_intent(head, words)
      when "git" then git_intent(words)
      when "gh" then gh_intent(tokens)
      when "find" then I18n.t("tool.shell.find", where: where(words.first))
      when "mkdir" then I18n.t("tool.shell.mkdir", where: where(words.first))
      when "rm", "rmdir" then I18n.t("tool.shell.remove", target: words.join(" "))
      when "mv" then I18n.t("tool.shell.move", from: place(words.first), to: toward(words[1]))
      when "cp" then I18n.t("tool.shell.copy", from: place(words.first), to: toward(words[1]))
      when "touch" then I18n.t("tool.shell.touch", where: where(words.first))
      when "chmod" then I18n.t("tool.shell.chmod", where: where(words.last, key: "tool.place.on"))
      when "wc" then I18n.t("tool.shell.count_lines", where: where(words.last))
      when "curl", "wget" then I18n.t("tool.shell.download", url: clip(words.last.to_s, URL_CHARS))
      when "ps", "top", "htop" then I18n.t("tool.shell.processes")
      when "kill", "pkill", "killall" then I18n.t("tool.shell.kill")
      when "date" then I18n.t("tool.shell.date")
      when "sleep" then sleep_intent(tokens)
      when "which", "type" then I18n.t("tool.shell.locate", command: words.first.to_s)
      when "echo", "printf" then I18n.t("tool.shell.echo")
      when "ssh", "scp" then I18n.t("tool.shell.remote")
      when "sqlite3" then I18n.t("tool.shell.database")
      when "ruby", "ruby3" then ruby_intent(words)
      when "node" then script_intent("Node", words)
      when "python", "python3" then script_intent("Python", words)
      when "rubocop" then I18n.t("tool.shell.style")
      when "rspec" then I18n.t("tool.shell.tests")
      when "rake" then rake_intent(words)
      when "go" then go_intent(words)
      when "docker" then I18n.t("tool.shell.docker", command: words.first.to_s)
      when "tar", "zip", "unzip", "gzip" then I18n.t("tool.shell.archive")
      when "systemctl", "launchctl", "service" then I18n.t("tool.shell.service")
      end
    end

    def self.read_intent(head, tokens, words)
      return I18n.t("tool.shell.read_follow") if head == "tail" && tokens.any? { |token| token.start_with?("-f") }

      I18n.t("tool.shell.read", target: place(words.last, default: "tool.place.file"))
    end

    # `sleep 90` is what waiting looks like on the command line, and the generic
    # fallback said nothing about it: a run that waited three times in a row
    # showed the same empty sentence three times. The duration is the whole
    # message, so it is spelled out — and nothing more is claimed, because the
    # command does not say what it is waiting for.
    #
    # Every argument is counted, since `sleep 90 30` waits two minutes: the
    # durations add up, and reading only the first would understate the wait.
    # A word that is not a duration contributes nothing.
    def self.sleep_intent(tokens)
      seconds = Array(tokens).sum { |token| sleep_seconds(token) || 0.0 }
      if seconds.infinite?
        return I18n.t(seconds.positive? ? "tool.shell.sleep_unbounded" : "tool.shell.sleep_brief")
      end

      label = wait_label(seconds)
      label ? I18n.t("tool.shell.sleep", duration: label) : I18n.t("tool.shell.sleep_brief")
    end

    # Everything `sleep` accepts as a duration: `90`, `1.5`, `.5`, `+5`, `1e3`,
    # `infinity`, and the s/m/h/d suffixes. The decimal separator arrives as
    # either a point or a comma depending on who wrote it.
    def self.sleep_seconds(argument)
      match = argument.to_s.strip.match(SLEEP_ARGUMENT)
      return nil unless match

      number = match[1]
      return Float::INFINITY if number.match?(/\A\+?inf/i)
      return -Float::INFINITY if number.match?(/\A-inf/i)

      value = number.tr(",", ".").to_f
      case match[2].to_s.downcase
      when "s" then value
      when "m" then value * 60
      when "h" then value * 3600
      when "d" then value * 86_400
      else value
      end
    end

    # nil when there is nothing a row could count: no argument at all, or one
    # too short to round up to a second. `sleep 0.4` is still a wait, just not
    # one worth putting a number on. The units are the dictionary's, because a
    # wait is the one caption whose whole message is a number and a noun.
    def self.wait_label(seconds)
      total = seconds.to_f.round
      return nil if total < 1
      return I18n.t("tool.wait.seconds", count: total) if total < 60

      minutes, rest = total.divmod(60)
      if minutes < 60
        return I18n.t("tool.wait.minutes", count: minutes) if rest.zero?

        return I18n.t("tool.wait.minutes_seconds", minutes: minutes, seconds: rest)
      end

      hours, minutes = minutes.divmod(60)
      if hours < 24
        return I18n.t("tool.wait.hours", count: hours) if minutes.zero?

        return I18n.t("tool.wait.hours_minutes", hours: hours, minutes: minutes)
      end

      days, hours = hours.divmod(24)
      hours.zero? ? I18n.t("tool.wait.days", count: days) : I18n.t("tool.wait.days_hours", days: days, hours: hours)
    end

    # The pattern is read off the line rather than off the split tokens: a
    # pattern with a space in it arrives quoted, and "def caption" split in two
    # would report a search for "def".
    def self.search_intent(segment)
      match = segment.match(/\A\S+\s+(?:-\S+\s+)*("[^"]*"|'[^']*'|\S+)/)
      pattern = match ? match[1].delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'") : ""
      return I18n.t("tool.shell.grep_bare") if pattern.empty?

      I18n.t("tool.shell.grep", pattern: "\"#{clip(pattern, PATTERN_CHARS)}\"")
    end

    def self.git_intent(words)
      sub = words.first.to_s
      sub = GIT_ALIASES.fetch(sub, sub)
      return I18n.t("tool.git.other") unless GIT_OPERATIONS.include?(sub)

      key = "tool.git.#{sub}"
      return I18n.t(key) unless sub == "checkout"

      I18n.t(key, where: toward(words[1]))
    end

    # The noun and the verb together name the entries the dictionary owes this
    # verb (`tool.gh.pr_create`, …). A pair that is not listed, or a noun sent
    # on its own, still reads as work on GitHub rather than as a bare command.
    def self.gh_intent(tokens)
      words = gh_words(tokens)
      key = GH_OPERATIONS[words.first(2).join(" ")] || GH_OPERATIONS[words.first.to_s]
      key ? I18n.t("tool.gh.#{key}") : I18n.t("tool.gh.other")
    end

    # The words the sentence may be built from. `gh` takes its global flags
    # before the noun (`gh -R owner/repo pr list`), and neither a flag nor the
    # value it swallows is one of them: read as words, they would hide the pair
    # and land the row on the fallback.
    def self.gh_words(tokens)
      words = []
      swallowing = false
      Array(tokens).each do |token|
        if token.start_with?("-")
          swallowing = true
        elsif swallowing
          swallowing = false
        else
          words << token
        end
      end
      words
    end

    def self.package_intent(head, words)
      operation = PACKAGE_OPERATIONS[words.first.to_s]
      return I18n.t("tool.package.#{operation}") if operation

      I18n.t(head == "gem" ? "tool.package.gem" : "tool.package.other")
    end

    def self.rake_intent(words)
      return I18n.t("tool.shell.tests") if words.include?("test")
      return I18n.t("tool.shell.migrate") if words.any? { |word| word.start_with?("db:") }

      I18n.t("tool.shell.rake")
    end

    def self.ruby_intent(words)
      return I18n.t("tool.shell.tests") if words.any? { |word| word.match?(/(_test|test_|_spec)\w*\.rb\z/) }

      script_intent("Ruby", words)
    end

    def self.script_intent(language, words)
      script = words.find { |word| word.include?(".rb") || word.include?(".js") || word.include?(".py") }
      return I18n.t("tool.shell.script", language: language, where: where(script)) if script

      I18n.t("tool.shell.script_bare", language: language)
    end

    def self.go_intent(words)
      case words.first.to_s
      when "test" then I18n.t("tool.shell.tests")
      when "build" then I18n.t("tool.shell.go_build")
      when "run" then I18n.t("tool.shell.go_run")
      else I18n.t("tool.shell.go")
      end
    end

    # A shell command's own words, minus the flags and the values glued to them.
    def self.positional(tokens)
      tokens.reject { |token| token.start_with?("-") || token.match?(/\A\d*\z/) }
            .reject { |token| token.include?("=") }
    end

    # The place a call points at, as a word a sentence can stand on: empty when
    # it points nowhere, the language's own word for the working directory when
    # that is where it points, and the last segments of the path otherwise.
    # `default` is the key to fall back on when there is no argument at all: `ls`
    # with nothing after it is still a listing of where the work happened, and
    # `here` is the word for the directory the command ran in, since a listing
    # puts the noun in its own template.
    def self.place(target, default: nil, here: "tool.place.directory")
      label = path_label(target.to_s)
      return default ? I18n.t(default) : "" if label.empty?
      return I18n.t(here) if [ ".", "./" ].include?(label)

      label
    end

    # The same place as a clause ready to append: empty when it points nowhere,
    # otherwise with the preposition in front, which each language supplies
    # (`tool.place.in`, `.to`, `.on`).
    def self.where(target, key: "tool.place.in")
      word = place(target)
      word.empty? ? "" : I18n.t(key, target: word)
    end

    def self.toward(target)
      where(target, key: "tool.place.to")
    end

    # --- the other tools --------------------------------------------------

    # One entry per operation the tool accepts (see FILE_OPERATIONS), and the
    # path is the variable each of them places: after the verb, or after the
    # noun the language puts first.
    def self.file_caption(args)
      operation = args["operation"].to_s
      operation = "read" unless FILE_OPERATIONS.include?(operation)
      path = args["path"].to_s.strip
      target = path.empty? ? paths_target(args["paths"]) : place(path)

      I18n.t("tool.file.#{operation}", target: target)
    end

    # `paths` is the plural shape of a read, and a row that said "reading" with
    # nothing after it would leave the reader wondering what it read.
    def self.paths_target(paths)
      list = Array(paths).map(&:to_s).reject(&:empty?)
      return "" if list.empty?
      return place(list.first) if list.size == 1

      I18n.t("tool.place.files", count: list.size)
    end

    def self.search_caption(args)
      pattern = args["pattern"].to_s.strip
      files = args["operation"].to_s == "files"
      return I18n.t(files ? "tool.search.files" : "tool.search.code") if pattern.empty?

      I18n.t(files ? "tool.search.files_named" : "tool.search.code_for", pattern: clip(pattern, PATTERN_CHARS))
    end

    def self.fetch_caption(args)
      url = args["url"].to_s.strip
      return I18n.t("tool.fetch") if url.empty?

      I18n.t("tool.fetch_page", url: clip(url, URL_CHARS))
    end

    def self.delegate_caption(args)
      agent = args["agent"].to_s.strip
      return I18n.t("tool.delegate") if agent.empty?

      I18n.t("tool.delegate_named", agent: agent)
    end

    def self.send_caption(args)
      count = Array(args["paths"]).map(&:to_s).reject(&:empty?).size
      return I18n.t("tool.send.none") if count.zero?
      return I18n.t("tool.send.one") if count == 1

      I18n.t("tool.send.many", count: count)
    end

    # A loop is started for a goal, and the goal is the only part of that call a
    # reader cares about: the worktree, the branch and the iteration cap are all
    # consequences of it. Everything else the tool does is one entry per
    # operation (see LOOP_OPERATIONS), and an operation this list does not know
    # still reads as a sentence rather than as the word the model happened to
    # send.
    def self.loop_caption(args)
      operation = args["operation"].to_s
      unless operation == "start"
        return verb_caption("tool.loop", "tool.name.loop", LOOP_OPERATIONS, args)
      end

      goal = args["goal"].to_s.gsub(/\s+/, " ").strip
      return I18n.t("tool.loop.start_bare") if goal.empty?

      I18n.t("tool.loop.start", goal: clip(goal, PATTERN_CHARS))
    end

    # The shape every tool with an `operation` argument takes: the entry for the
    # operation it named, the tool's own name when it named none, and a sentence
    # that still reads when it named one this build has never heard of.
    def self.verb_caption(key_prefix, name_key, operations, args, other: nil)
      operation = args["operation"].to_s
      return I18n.t(name_key) if operation.empty?
      return I18n.t("#{key_prefix}.#{operation}") if operations.include?(operation)
      return I18n.t(other) if other

      I18n.t("tool.operation_unknown", prefix: I18n.t(name_key), operation: operation)
    end

    # The question, not the structure that carries it.
    #
    # This is the one row whose reader is also the person being addressed, so
    # the useful sentence is the question itself: the arguments are a hash of
    # options and printing them told the reader nothing they could answer. The
    # options keep their place in the tooltip, one hover away.
    def self.ask_caption(args)
      args = {} unless args.is_a?(Hash)
      question = args["question"].to_s.strip
      return I18n.t("tool.ask_plain") if question.empty?

      I18n.t("tool.ask", question: clip(question, QUESTION_CHARS))
    end

    # The whole question and the choices it offered, for the hover.
    def self.ask_tooltip(args)
      args = {} unless args.is_a?(Hash)
      question = args["question"].to_s.strip
      return "" if question.empty?

      labels = Array(args["options"]).filter_map do |option|
        option.is_a?(Hash) ? option["label"].to_s.strip : option.to_s.strip
      end.reject(&:empty?)
      return question if labels.empty?

      "#{question} — #{labels.join(', ')}"
    end

    # Long enough for a real question, short enough that the row is still one
    # line on a phone.
    def self.clip(text, limit)
      value = text.to_s.strip
      return value if value.length <= limit

      "#{value[0, limit - 1].rstrip}…"
    end

    def self.unknown_caption(name, args)
      snippet = raw(name, args)
      snippet.empty? ? name : snippet
    end

    # The last few segments of an absolute path, so a row is about the file the
    # reader can name rather than the workspace it happens to live in.
    def self.path_label(path)
      path = path.to_s.strip
      return "" if path.empty?

      segments = path.split("/").reject(&:empty?)
      return path unless path.start_with?("/") && segments.size > PATH_SEGMENTS

      "…/#{segments.last(PATH_SEGMENTS).join("/")}"
    end
  end
end
