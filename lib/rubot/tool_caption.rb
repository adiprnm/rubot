# frozen_string_literal: true

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
  module ToolCaption
    PATH_SEGMENTS = 3
    PATTERN_CHARS = 60
    URL_CHARS = 60

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

    FILE_VERBS = {
      "read" => "Membaca isi ",
      "write" => "Menulis berkas ",
      "edit" => "Mengubah isi ",
      "append" => "Menambahkan isi ke ",
      "delete" => "Menghapus ",
      "list" => "Menampilkan isi direktori ",
      "info" => "Memeriksa "
    }.freeze

    MEMORY_VERBS = {
      "read" => "Mengingat kembali catatan",
      "append" => "Mencatat satu hal ke ingatan",
      "update_section" => "Merapikan satu bagian catatan"
    }.freeze

    CRON_VERBS = {
      "add" => "Menjadwalkan tugas berkala",
      "list" => "Melihat daftar tugas terjadwal",
      "detail" => "Melihat satu tugas terjadwal",
      "remove" => "Membatalkan satu tugas",
      "enable" => "Mengaktifkan satu tugas",
      "disable" => "Menonaktifkan satu tugas"
    }.freeze

    # `start` is missing on purpose: it is the one operation with something to
    # say about the call (see `loop_caption`).
    LOOP_VERBS = {
      "status" => "Melihat keadaan satu loop",
      "list" => "Melihat daftar loop",
      "pause" => "Menghentikan loop sementara",
      "resume" => "Melanjutkan loop yang berhenti",
      "stop" => "Menghentikan loop",
      "undo" => "Membatalkan iterasi terakhir"
    }.freeze

    INSTAGRAM_VERBS = {
      "connect" => "Menyiapkan sambungan Instagram",
      "status" => "Memeriksa akun Instagram",
      "schedule" => "Menjadwalkan unggahan Instagram",
      "publish" => "Mengunggah ke Instagram",
      "posts" => "Melihat daftar unggahan Instagram",
      "cancel" => "Membatalkan unggahan Instagram",
      "link" => "Menautkan akun Instagram",
      "disconnect" => "Melepas akun Instagram"
    }.freeze

    def self.caption(tool_name, args)
      args = {} unless args.is_a?(Hash)
      name = tool_name.to_s

      case name
      when "shell_exec" then command_caption(args)
      when "file_ops" then file_caption(args)
      when "search" then search_caption(args)
      when "web_fetch" then fetch_caption(args)
      when "delegate" then delegate_caption(args)
      when "subagent_results" then "Membaca hasil kerja subagent"
      when "send_files" then send_caption(args)
      when "memory" then operation_caption("Memori", MEMORY_VERBS, args)
      when "cron" then operation_caption("Tugas terjadwal", CRON_VERBS, args)
      when "loop" then loop_caption(args)
      when "instagram" then INSTAGRAM_VERBS.fetch(args["operation"].to_s, "Mengurus Instagram")
      when "notify" then "Bersiap memberi kabar begitu selesai"
      else unknown_caption(name, args)
      end
    end

    # The call as the agent made it, for the one place a reader may still want
    # it: the tooltip on a web row. The name leads, since the row no longer
    # carries it.
    def self.tooltip(tool_name, args)
      name = tool_name.to_s
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
      return "Menjalankan perintah di terminal" if command.empty?

      shell_intent(command) || "Menjalankan perintah di terminal"
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

    def self.intent_for(head, tokens, segment)
      words = positional(tokens)

      case head
      when *DIRECTORY_WORDS then "Menampilkan isi direktori#{where(words.first, fallback: ' ini')}"
      when *READ_WORDS then read_intent(head, tokens, words)
      when *SEARCH_WORDS then search_intent(segment)
      when *PACKAGE_WORDS then package_intent(head, words)
      when "git" then git_intent(words)
      when "find" then "Mencari berkas#{where(words.first)}"
      when "mkdir" then "Membuat direktori#{where(words.first)}"
      when "rm", "rmdir" then "Menghapus #{words.join(' ')}".strip
      when "mv" then "Memindahkan #{words.first}#{where(words[1], prefix: ' ke ')}"
      when "cp" then "Menyalin #{words.first}#{where(words[1], prefix: ' ke ')}"
      when "touch" then "Membuat berkas#{where(words.first)}"
      when "chmod" then "Mengubah izin #{words.last}".strip
      when "wc" then "Menghitung baris#{where(words.last)}"
      when "curl", "wget" then "Mengambil isi halaman #{clip(words.last.to_s, URL_CHARS)}".strip
      when "ps", "top", "htop" then "Melihat proses yang sedang berjalan"
      when "kill", "pkill", "killall" then "Menghentikan proses"
      when "date" then "Menampilkan tanggal dan waktu"
      when "sleep" then sleep_intent(tokens)
      when "which", "type" then "Mencari lokasi perintah #{words.first}".strip
      when "echo", "printf" then "Menuliskan teks pendek"
      when "ssh", "scp" then "Menghubungi server lain"
      when "sqlite3" then "Membuka basis data"
      when "ruby", "ruby3" then ruby_intent(words)
      when "node" then script_intent("Node", words)
      when "python", "python3" then script_intent("Python", words)
      when "rubocop" then "Memeriksa gaya kode"
      when "rspec" then "Menjalankan test"
      when "rake" then rake_intent(words)
      when "go" then go_intent(words)
      when "docker" then "Menjalankan docker#{where(words.first)}"
      when "tar", "zip", "unzip", "gzip" then "Mengemas atau membuka berkas"
      when "systemctl", "launchctl", "service" then "Mengatur layanan sistem"
      end
    end

    def self.read_intent(head, tokens, words)
      return "Melihat log secara langsung" if head == "tail" && tokens.any? { |token| token.start_with?("-f") }

      "Membaca isi#{where(words.last, fallback: ' berkas')}"
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
        return seconds.positive? ? "Menunggu tanpa batas" : "Menunggu sebentar"
      end

      label = wait_label(seconds)
      label ? "Menunggu #{label}" : "Menunggu sebentar"
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
    # one worth putting a number on.
    def self.wait_label(seconds)
      total = seconds.to_f.round
      return nil if total < 1
      return "#{total} detik" if total < 60

      minutes, rest = total.divmod(60)
      if minutes < 60
        return "#{minutes} menit" if rest.zero?

        return "#{minutes} menit #{rest} detik"
      end

      hours, minutes = minutes.divmod(60)
      if hours < 24
        return minutes.zero? ? "#{hours} jam" : "#{hours} jam #{minutes} menit"
      end

      days, hours = hours.divmod(24)
      hours.zero? ? "#{days} hari" : "#{days} hari #{hours} jam"
    end

    # The pattern is read off the line rather than off the split tokens: a
    # pattern with a space in it arrives quoted, and "def caption" split in two
    # would report a search for "def".
    def self.search_intent(segment)
      match = segment.match(/\A\S+\s+(?:-\S+\s+)*("[^"]*"|'[^']*'|\S+)/)
      pattern = match ? match[1].delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'") : ""
      return "Mencari sesuatu di dalam berkas" if pattern.empty?

      "Mencari \"#{clip(pattern, PATTERN_CHARS)}\" di dalam berkas"
    end

    def self.git_intent(words)
      case words.first.to_s
      when "status" then "Memeriksa status git"
      when "diff" then "Melihat perubahan yang belum disimpan"
      when "log" then "Melihat riwayat commit"
      when "add" then "Menandai perubahan untuk di-commit"
      when "commit" then "Menyimpan perubahan ke git"
      when "push" then "Mengirim commit ke remote"
      when "pull", "fetch" then "Mengambil pembaruan dari remote"
      when "checkout", "switch" then "Berpindah branch#{where(words[1])}"
      when "branch" then "Melihat daftar branch"
      when "stash" then "Menyimpan perubahan sementara"
      when "show" then "Melihat rincian satu commit"
      when "clone" then "Mengunduh salinan repositori"
      else "Mengurus repositori git"
      end
    end

    def self.package_intent(head, words)
      case words.first.to_s
      when "install", "i", "add", "ci" then "Memasang dependensi"
      when "test", "t" then "Menjalankan test"
      when "run" then "Menjalankan skrip proyek"
      when "build" then "Membangun proyek"
      else head == "gem" ? "Mengurus gem" : "Mengurus dependensi"
      end
    end

    def self.rake_intent(words)
      return "Menjalankan test" if words.include?("test")
      return "Menjalankan migrasi basis data" if words.any? { |word| word.start_with?("db:") }

      "Menjalankan tugas rake"
    end

    def self.ruby_intent(words)
      return "Menjalankan test" if words.any? { |word| word.match?(/(_test|test_|_spec)\w*\.rb\z/) }

      script_intent("Ruby", words)
    end

    def self.script_intent(language, words)
      script = words.find { |word| word.include?(".rb") || word.include?(".js") || word.include?(".py") }
      return "Menjalankan skrip #{language}#{where(script)}" if script

      "Menjalankan #{language}"
    end

    def self.go_intent(words)
      case words.first.to_s
      when "test" then "Menjalankan test"
      when "build" then "Membangun program"
      when "run" then "Menjalankan program"
      else "Menjalankan perintah go"
      end
    end

    # A shell command's own words, minus the flags and the values glued to them.
    def self.positional(tokens)
      tokens.reject { |token| token.start_with?("-") || token.match?(/\A\d*\z/) }
            .reject { |token| token.include?("=") }
    end

    # Where a call points, as a clause: empty when it points at nothing, " ini"
    # when it points at the current directory, and the last segments otherwise.
    def self.where(target, prefix: " ", fallback: "")
      label = path_label(target.to_s)
      return fallback if label.empty?
      return "#{prefix}ini" if [ ".", "./" ].include?(label)

      "#{prefix}#{label}"
    end

    # --- the other tools --------------------------------------------------

    def self.file_caption(args)
      verb = FILE_VERBS.fetch(args["operation"].to_s, "Membaca isi ")
      path = args["path"].to_s.strip
      return files_phrase(verb, args["paths"]) if path.empty?

      "#{verb}#{path_label(path)}"
    end

    # `paths` is the plural shape of a read, and a row that said "reading" with
    # nothing after it would leave the reader wondering what it read.
    def self.files_phrase(verb, paths)
      list = Array(paths).map(&:to_s).reject(&:empty?)
      return verb.strip if list.empty?
      return "#{verb}#{path_label(list.first)}" if list.size == 1

      "#{verb.sub(/\s+\z/, '')} #{list.size} berkas"
    end

    def self.search_caption(args)
      pattern = args["pattern"].to_s.strip
      files = args["operation"].to_s == "files"
      return files ? "Mencari berkas" : "Mencari di dalam kode" if pattern.empty?

      label = clip(pattern, PATTERN_CHARS)
      files ? "Mencari berkas bernama \"#{label}\"" : "Mencari \"#{label}\" di dalam kode"
    end

    def self.fetch_caption(args)
      url = args["url"].to_s.strip
      return "Membuka sebuah halaman" if url.empty?

      "Membuka halaman #{clip(url, URL_CHARS)}"
    end

    def self.delegate_caption(args)
      agent = args["agent"].to_s.strip
      return "Meminta bantuan subagent" if agent.empty?

      "Meminta bantuan #{agent}"
    end

    def self.send_caption(args)
      count = Array(args["paths"]).map(&:to_s).reject(&:empty?).size
      return "Mengirim berkas" if count.zero?
      return "Mengirim satu berkas" if count == 1

      "Mengirim #{count} berkas"
    end

    # A loop is started for a goal, and the goal is the only part of that call a
    # reader cares about: the worktree, the branch and the iteration cap are all
    # consequences of it. Everything else the tool does is one verb (see
    # LOOP_VERBS), and an operation this map does not know still reads as a
    # sentence rather than as the word the model happened to send.
    def self.loop_caption(args)
      operation = args["operation"].to_s
      return operation_caption("Loop", LOOP_VERBS, args) unless operation == "start"

      goal = args["goal"].to_s.gsub(/\s+/, " ").strip
      return "Memulai loop baru" if goal.empty?

      "Memulai loop: #{clip(goal, PATTERN_CHARS)}"
    end

    def self.operation_caption(prefix, verbs, args)
      operation = args["operation"].to_s
      verb = verbs[operation]
      return verb if verb
      return prefix if operation.empty?

      "#{prefix}: #{operation}"
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

    def self.clip(text, limit)
      text = text.to_s
      return text if text.length <= limit

      "#{text[0, limit - 1]}…"
    end
  end
end
