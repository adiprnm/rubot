# frozen_string_literal: true

module Rubot
  # Every piece of text Rubot shows a person, in the languages it can be shown.
  #
  # One dictionary, two languages, one function. A channel never writes a
  # reader-facing sentence in place: it names a key here. That is what makes a
  # language switch a single assignment instead of a sweep through the TUI, the
  # web templates and the Telegram card, and what lets a test compare the two
  # dictionaries key by key (see test/test_i18n.rb).
  #
  # The key space is dotted and nested: `I18n.t("tool.shell.command")` reads
  # DICTIONARY["en"]["tool"]["shell"]["command"]. Values are frozen strings,
  # with `%{name}` for the parts a caller fills in; a value may not use Ruby's
  # `format` verbs, since `%` shows up in real labels ("100%").
  #
  # The locale is a process-wide setting, not an argument threaded through every
  # call: a channel sets it once from config (`Config#bahasa`), and a settings
  # change sets it again, so a new language is live on the next row drawn
  # instead of on the next launch. A Ractor that needs it passes the plain
  # string across its boundary like any other message.
  module I18n
    LOCALES = %w[en id].freeze
    DEFAULT_LOCALE = "en"
    # The config key this dictionary is chosen by: `bahasa: id` in config.yml.
    CONFIG_KEY = "bahasa"

    # A config or a caller named a language this build does not speak. Raised
    # instead of quietly falling back: a typo in `bahasa:` should be reported
    # where it is made, not discovered as a half-English interface.
    class UnknownLocale < ArgumentError; end

    # A key with no entry in any language. Raised in every environment: a
    # missing label is a blank row on someone's screen, and the parity test is
    # what keeps this from ever firing in production.
    class MissingTranslation < KeyError; end

    # `%{name}` and nothing else is a placeholder. Braces are literal.
    PLACEHOLDER = /%\{(\w+)\}/

    DICTIONARY = {
      "en" => {
        "thinking" => {
          "live" => "Thinking…",
          "done" => "Thought for %{duration}"
        },
        "compaction" => {
          "running" => "Summarizing the conversation…",
          "failed" => "Compaction failed",
          "done" => "Summarized %{count} messages · ~%{before} → ~%{after} tokens",
          "empty" => "Nothing to compact yet",
          "note" => "Conversation summarized. Its seam is marked below, where the compaction happened.",
          "complete" => "Compaction complete.",
          "summarized" => "Summarized: %{count} messages",
          "kept" => "Kept: %{count} messages",
          "context" => "Context: ~%{before} → ~%{after} tokens (estimated)"
        },
        "footer" => {
          "turn" => "Turn took %{duration} (Total time %{total} · %{count} %{turns})",
          "turn_one" => "turn",
          "turn_other" => "turns"
        },
        "status" => {
          "working" => "working",
          "cancels" => "esc cancels",
          "empty_message" => "Nothing to send.",
          "stop_requested" => "Stop requested."
        },
        "tool" => {
          "operation_unknown" => "%{prefix}: %{operation}",
          "name" => {
            "memory" => "Memory",
            "cron" => "Scheduled tasks",
            "loop" => "Loop",
            "instagram" => "Instagram"
          },
          "place" => {
            "here" => "this",
            "directory" => "this directory",
            "file" => "a file",
            "files" => "%{count} files",
            "in" => " in %{target}",
            "to" => " to %{target}",
            "on" => " on %{target}"
          },
          "wait" => {
            "seconds" => "%{count}s",
            "minutes" => "%{count}m",
            "minutes_seconds" => "%{minutes}m %{seconds}s",
            "hours" => "%{count}h",
            "hours_minutes" => "%{hours}h %{minutes}m",
            "days" => "%{count}d",
            "days_hours" => "%{days}d %{hours}h"
          },
          "shell" => {
            "command" => "Ran a command in the terminal",
            "directory" => "Showing what is inside %{target} directory",
            "read" => "Reading %{target}",
            "read_follow" => "Following the log live",
            "grep" => "Searching for %{pattern} in the files",
            "grep_bare" => "Searching for something in the files",
            "find" => "Looking for files%{where}",
            "mkdir" => "Creating a directory%{where}",
            "remove" => "Deleting %{target}",
            "move" => "Moving %{from}%{to}",
            "copy" => "Copying %{from}%{to}",
            "touch" => "Creating a file%{where}",
            "chmod" => "Changing the permissions%{where}",
            "count_lines" => "Counting the lines%{where}",
            "download" => "Fetching the page %{url}",
            "processes" => "Looking at the running processes",
            "kill" => "Stopping a process",
            "date" => "Showing the date and time",
            "sleep" => "Waiting %{duration}",
            "sleep_brief" => "Waiting a moment",
            "sleep_unbounded" => "Waiting without end",
            "locate" => "Finding where %{command} lives",
            "echo" => "Writing a short piece of text",
            "remote" => "Reaching another server",
            "database" => "Opening a database",
            "tests" => "Running the tests",
            "style" => "Checking the code style",
            "script" => "Running the %{language} script%{where}",
            "script_bare" => "Running %{language}",
            "rake" => "Running a rake task",
            "migrate" => "Running the database migrations",
            "go" => "Running a go command",
            "go_build" => "Building the program",
            "go_run" => "Running the program",
            "docker" => "Running docker %{command}",
            "archive" => "Packing or unpacking files",
            "service" => "Managing a system service"
          },
          "git" => {
            "status" => "Checking the git status",
            "diff" => "Reading the changes not saved yet",
            "log" => "Reading the commit history",
            "add" => "Marking the changes to commit",
            "commit" => "Saving the changes to git",
            "push" => "Sending the commits to the remote",
            "pull" => "Fetching the updates from the remote",
            "checkout" => "Switching branch%{where}",
            "branch" => "Reading the list of branches",
            "stash" => "Setting the changes aside",
            "show" => "Reading one commit in detail",
            "clone" => "Downloading a copy of the repository",
            "other" => "Looking after the git repository"
          },
          "package" => {
            "install" => "Installing the dependencies",
            "test" => "Running the tests",
            "run" => "Running a project script",
            "build" => "Building the project",
            "gem" => "Looking after the gems",
            "other" => "Looking after the dependencies"
          },
          "file" => {
            "read" => "Reading %{target}",
            "write" => "Writing %{target}",
            "edit" => "Editing %{target}",
            "append" => "Adding to %{target}",
            "delete" => "Deleting %{target}",
            "list" => "Showing what is in %{target}",
            "info" => "Looking at %{target}"
          },
          "memory" => {
            "read" => "Recalling what it wrote down",
            "append" => "Writing one thing down in memory",
            "update_section" => "Tidying one section of the notes"
          },
          "cron" => {
            "add" => "Scheduling a recurring task",
            "list" => "Reading the list of scheduled tasks",
            "detail" => "Reading one scheduled task",
            "remove" => "Cancelling a task",
            "enable" => "Turning a task on",
            "disable" => "Turning a task off"
          },
          "loop" => {
            "status" => "Reading where a loop stands",
            "list" => "Reading the list of loops",
            "pause" => "Pausing a loop",
            "resume" => "Resuming a stopped loop",
            "stop" => "Stopping a loop",
            "undo" => "Dropping the last iteration",
            "start" => "Starting a loop: %{goal}",
            "start_bare" => "Starting a new loop"
          },
          "instagram" => {
            "connect" => "Setting up the Instagram connection",
            "status" => "Checking the Instagram account",
            "schedule" => "Scheduling an Instagram post",
            "publish" => "Posting to Instagram",
            "posts" => "Reading the list of Instagram posts",
            "cancel" => "Cancelling an Instagram post",
            "link" => "Linking an Instagram account",
            "disconnect" => "Unlinking an Instagram account",
            "other" => "Looking after Instagram"
          },
          "subagent_results" => "Reading a sub agent's result",
          "notify" => "Getting ready to tell you when it is done",
          "send" => {
            "none" => "Sending files",
            "one" => "Sending a file",
            "many" => "Sending %{count} files"
          },
          "search" => {
            "files" => "Looking for files",
            "code" => "Searching the code",
            "files_named" => "Looking for files named \"%{pattern}\"",
            "code_for" => "Searching the code for \"%{pattern}\""
          },
          "fetch" => "Opening a page",
          "fetch_page" => "Opening %{url}",
          "delegate" => "Asking a sub agent for help",
          "delegate_named" => "Asking %{agent} for help"
        }
      },
      "id" => {
        "thinking" => {
          "live" => "Berpikir…",
          "done" => "Berpikir %{duration}"
        },
        "compaction" => {
          "running" => "Merangkum percakapan…",
          "failed" => "Pemadatan gagal",
          "done" => "Meringkas %{count} pesan · ~%{before} → ~%{after} token",
          "empty" => "Belum ada yang perlu dipadatkan",
          "note" => "Percakapan berhasil diringkas. Baris penandanya ada di bawah, di tempat compaction terjadi.",
          "complete" => "Compact selesai.",
          "summarized" => "Pesan diringkas: %{count}",
          "kept" => "Pesan dipertahankan: %{count}",
          "context" => "Perkiraan konteks: ~%{before} → ~%{after} token"
        },
        "footer" => {
          "turn" => "%{duration} giliran (total waktu %{total} · %{count} %{turns})",
          "turn_one" => "giliran",
          "turn_other" => "giliran"
        },
        "status" => {
          "working" => "bekerja",
          "cancels" => "esc membatalkan",
          "empty_message" => "Tidak ada yang dikirim.",
          "stop_requested" => "Permintaan berhenti dikirim."
        },
        "tool" => {
          "operation_unknown" => "%{prefix}: %{operation}",
          "name" => {
            "memory" => "Memori",
            "cron" => "Tugas terjadwal",
            "loop" => "Loop",
            "instagram" => "Instagram"
          },
          "place" => {
            "here" => "ini",
            "directory" => "direktori ini",
            "file" => "berkas",
            "files" => "%{count} berkas",
            "in" => " di %{target}",
            "to" => " ke %{target}",
            "on" => " pada %{target}"
          },
          "wait" => {
            "seconds" => "%{count} detik",
            "minutes" => "%{count} menit",
            "minutes_seconds" => "%{minutes} menit %{seconds} detik",
            "hours" => "%{count} jam",
            "hours_minutes" => "%{hours} jam %{minutes} menit",
            "days" => "%{count} hari",
            "days_hours" => "%{days} hari %{hours} jam"
          },
          "shell" => {
            "command" => "Menjalankan perintah di terminal",
            "directory" => "Menampilkan isi direktori %{target}",
            "read" => "Membaca isi %{target}",
            "read_follow" => "Melihat log secara langsung",
            "grep" => "Mencari %{pattern} di dalam berkas",
            "grep_bare" => "Mencari sesuatu di dalam berkas",
            "find" => "Mencari berkas%{where}",
            "mkdir" => "Membuat direktori%{where}",
            "remove" => "Menghapus %{target}",
            "move" => "Memindahkan %{from}%{to}",
            "copy" => "Menyalin %{from}%{to}",
            "touch" => "Membuat berkas%{where}",
            "chmod" => "Mengubah izin%{where}",
            "count_lines" => "Menghitung baris%{where}",
            "download" => "Mengambil isi halaman %{url}",
            "processes" => "Melihat proses yang sedang berjalan",
            "kill" => "Menghentikan proses",
            "date" => "Menampilkan tanggal dan waktu",
            "sleep" => "Menunggu %{duration}",
            "sleep_brief" => "Menunggu sebentar",
            "sleep_unbounded" => "Menunggu tanpa batas",
            "locate" => "Mencari lokasi perintah %{command}",
            "echo" => "Menuliskan teks pendek",
            "remote" => "Menghubungi server lain",
            "database" => "Membuka basis data",
            "tests" => "Menjalankan test",
            "style" => "Memeriksa gaya kode",
            "script" => "Menjalankan skrip %{language}%{where}",
            "script_bare" => "Menjalankan %{language}",
            "rake" => "Menjalankan tugas rake",
            "migrate" => "Menjalankan migrasi basis data",
            "go" => "Menjalankan perintah go",
            "go_build" => "Membangun program",
            "go_run" => "Menjalankan program",
            "docker" => "Menjalankan docker %{command}",
            "archive" => "Mengemas atau membuka berkas",
            "service" => "Mengatur layanan sistem"
          },
          "git" => {
            "status" => "Memeriksa status git",
            "diff" => "Melihat perubahan yang belum disimpan",
            "log" => "Melihat riwayat commit",
            "add" => "Menandai perubahan untuk di-commit",
            "commit" => "Menyimpan perubahan ke git",
            "push" => "Mengirim commit ke remote",
            "pull" => "Mengambil pembaruan dari remote",
            "checkout" => "Berpindah branch%{where}",
            "branch" => "Melihat daftar branch",
            "stash" => "Menyimpan perubahan sementara",
            "show" => "Melihat rincian satu commit",
            "clone" => "Mengunduh salinan repositori",
            "other" => "Mengurus repositori git"
          },
          "package" => {
            "install" => "Memasang dependensi",
            "test" => "Menjalankan test",
            "run" => "Menjalankan skrip proyek",
            "build" => "Membangun proyek",
            "gem" => "Mengurus gem",
            "other" => "Mengurus dependensi"
          },
          "file" => {
            "read" => "Membaca isi %{target}",
            "write" => "Menulis berkas %{target}",
            "edit" => "Mengubah isi %{target}",
            "append" => "Menambahkan isi ke %{target}",
            "delete" => "Menghapus %{target}",
            "list" => "Menampilkan isi direktori %{target}",
            "info" => "Memeriksa %{target}"
          },
          "memory" => {
            "read" => "Mengingat kembali catatan",
            "append" => "Mencatat satu hal ke ingatan",
            "update_section" => "Merapikan satu bagian catatan"
          },
          "cron" => {
            "add" => "Menjadwalkan tugas berkala",
            "list" => "Melihat daftar tugas terjadwal",
            "detail" => "Melihat satu tugas terjadwal",
            "remove" => "Membatalkan satu tugas",
            "enable" => "Mengaktifkan satu tugas",
            "disable" => "Menonaktifkan satu tugas"
          },
          "loop" => {
            "status" => "Melihat keadaan satu loop",
            "list" => "Melihat daftar loop",
            "pause" => "Menghentikan loop sementara",
            "resume" => "Melanjutkan loop yang berhenti",
            "stop" => "Menghentikan loop",
            "undo" => "Membatalkan iterasi terakhir",
            "start" => "Memulai loop: %{goal}",
            "start_bare" => "Memulai loop baru"
          },
          "instagram" => {
            "connect" => "Menyiapkan sambungan Instagram",
            "status" => "Memeriksa akun Instagram",
            "schedule" => "Menjadwalkan unggahan Instagram",
            "publish" => "Mengunggah ke Instagram",
            "posts" => "Melihat daftar unggahan Instagram",
            "cancel" => "Membatalkan unggahan Instagram",
            "link" => "Menautkan akun Instagram",
            "disconnect" => "Melepas akun Instagram",
            "other" => "Mengurus Instagram"
          },
          "subagent_results" => "Membaca hasil kerja subagent",
          "notify" => "Bersiap memberi kabar begitu selesai",
          "send" => {
            "none" => "Mengirim berkas",
            "one" => "Mengirim satu berkas",
            "many" => "Mengirim %{count} berkas"
          },
          "search" => {
            "files" => "Mencari berkas",
            "code" => "Mencari di dalam kode",
            "files_named" => "Mencari berkas bernama \"%{pattern}\"",
            "code_for" => "Mencari \"%{pattern}\" di dalam kode"
          },
          "fetch" => "Membuka sebuah halaman",
          "fetch_page" => "Membuka halaman %{url}",
          "delegate" => "Meminta bantuan subagent",
          "delegate_named" => "Meminta bantuan %{agent}"
        }
      }
    }.freeze

    class << self
      # The language everything drawn from here on is written in.
      def locale
        @locale || DEFAULT_LOCALE
      end

      def locale=(value)
        @locale = normalize!(value)
      end

      # Run a block in another language and put the old one back, even when the
      # block raises. The seam a test uses, and the way a page that speaks one
      # language while the install speaks another stays honest.
      def with_locale(value)
        previous = locale
        self.locale = value
        yield
      ensure
        @locale = previous
      end

      # The one translation function. `%{name}` in the entry is filled from the
      # keyword arguments; an unknown key raises rather than returning the key,
      # because a dotted key on screen is not a label.
      def t(key, locale: nil, **vars)
        target = locale ? normalize!(locale) : self.locale
        entry = lookup(target, key) || lookup(DEFAULT_LOCALE, key)
        raise MissingTranslation, "no translation for #{key.inspect} in #{LOCALES.join('/')}" if entry.nil?

        interpolate(entry, vars)
      end

      alias translate t

      # The locale a config asks for, or nil when it asks for nothing (so the
      # caller keeps the default). A value that is not a language raises; see
      # Config#bahasa, which is the only caller that faces a config file.
      def normalize(value)
        text = value.to_s.strip.downcase
        return nil if text.empty?

        LOCALES.include?(text) ? text : nil
      end

      def normalize!(value)
        normalized = normalize(value)
        return normalized if normalized

        raise UnknownLocale,
              "unknown language #{value.to_s.inspect} for `#{CONFIG_KEY}`: use one of #{LOCALES.join(', ')}"
      end

      def valid_locale?(value)
        !normalize(value).nil?
      end

      # Every leaf key of one language, dotted, sorted. The parity check and the
      # settings form both read the dictionary through this.
      def keys(locale: DEFAULT_LOCALE)
        flatten(DICTIONARY.fetch(normalize!(locale).to_s, {}))
      end

      # Keys one language has and another does not, in either direction. Empty
      # for a dictionary whose two halves agree.
      def missing_keys(left: "en", right: "id")
        (keys(locale: left) - keys(locale: right)) | (keys(locale: right) - keys(locale: left))
      end

      private

      def lookup(locale_name, key)
        key.to_s.split(".").reduce(DICTIONARY[locale_name]) do |node, part|
          return nil unless node.is_a?(Hash)

          node[part]
        end
      end

      def interpolate(entry, vars)
        return entry unless entry.is_a?(String) && !vars.empty?

        entry.gsub(PLACEHOLDER) { vars.fetch(Regexp.last_match(1).to_sym, "").to_s }
      end

      def flatten(node, prefix = "")
        return [ prefix ] unless node.is_a?(Hash)

        node.flat_map do |part, value|
          flatten(value, prefix.empty? ? part.to_s : "#{prefix}.#{part}")
        end
      end
    end
  end
end
