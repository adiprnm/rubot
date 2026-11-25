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
          "empty" => "Nothing to compact yet (the conversation is short or summarizing failed).",
          "note" => "Conversation summarized. Its seam is marked below, where the compaction happened.",
          "complete" => "Compaction complete.",
          "title" => "Compaction complete",
          "busy" => "A turn is still running. Summarize once it finishes: a conversation in flight must not be summarized.",
          "error" => "Summarizing failed. Try again in a moment.",
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
          "shell" => {
            "command" => "Ran a command in the terminal"
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
            "code" => "Searching the code"
          },
          "fetch" => "Opening a page",
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
          "empty" => "Belum ada yang perlu diringkas: percakapan masih terlalu pendek atau ringkasan gagal dibuat.",
          "note" => "Percakapan berhasil diringkas. Baris penandanya ada di bawah, di tempat compaction terjadi.",
          "complete" => "Compact selesai.",
          "title" => "Compact selesai",
          "busy" => "Turn masih berjalan. Ringkas setelah selesai: percakapan yang sedang berjalan tidak boleh ikut diringkas.",
          "error" => "Ringkasan gagal. Coba lagi sebentar.",
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
          "shell" => {
            "command" => "Menjalankan perintah di terminal"
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
            "code" => "Mencari di dalam kode"
          },
          "fetch" => "Membuka sebuah halaman",
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
