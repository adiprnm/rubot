# frozen_string_literal: true

require "test_helper"
require "rubot"

module Rubot
  # One call, one sentence, every surface.
  #
  # The row a call leaves is drawn in five places: the live web timeline, the
  # replayed transcript, the row a delegated run keeps, the Telegram status card
  # and the TUI transcript. The sentence itself is therefore derived once, from
  # the arguments, rather than written by each of them. These tests pin the
  # table, and then check that the surfaces which can be built here agree with
  # it.
  class TestToolCaption < Minitest::Test
    LONG_PATH = "/home/adipurnm/Projects/oss/rubot/lib/rubot/web/turn.rb"

    # These tests pin the Indonesian table, the language this module was
    # written in before the dictionary existed. The default (en) is covered in
    # test_i18n.rb, where the same call is read in both languages.
    def setup
      Rubot::I18n.locale = "id"
    end

    def teardown
      Rubot::I18n.locale = Rubot::I18n::DEFAULT_LOCALE
    end

    # --- the sentence ----------------------------------------------------

    # The row reads as something that happened, not as a command line: the
    # reader is told what `ls` is for, not what was typed.
    def test_a_directory_listing_reads_as_showing_what_is_there
      assert_equal "Menampilkan isi direktori ini", command("ls")
      assert_equal "Menampilkan isi direktori ini", command("ls -la")
      assert_equal "Menampilkan isi direktori lib", command("ls lib")
    end

    def test_a_file_read_names_the_file
      assert_equal "Membaca isi lib/a.rb", command("cat lib/a.rb")
      assert_equal "Membaca isi …/rubot/web/turn.rb", command("head -n 20 #{LONG_PATH}")
    end

    def test_a_search_says_what_it_looked_for
      assert_equal "Mencari \"Turn\" di dalam berkas", command("grep -rn Turn lib")
      assert_equal "Mencari \"def caption\" di dalam berkas", command("rg 'def caption'")
    end

    def test_common_git_commands_get_their_own_sentence
      assert_equal "Memeriksa status git", command("git status")
      assert_equal "Melihat riwayat commit", command("git log --oneline -3")
      assert_equal "Menyimpan perubahan ke git", command("git commit -m 'x'")
      assert_equal "Mengirim commit ke remote", command("git push origin main")
    end

    def test_a_test_run_is_called_a_test_run
      assert_equal "Menjalankan test", command("bundle exec rake test")
      assert_equal "Menjalankan test", command("bundle exec rspec test/foo_test.rb")
      assert_equal "Menjalankan test", command("ruby -Ilib -Itest test/test_agent.rb")
      assert_equal "Memeriksa gaya kode", command("bundle exec rubocop")
    end

    def test_a_compound_line_is_read_by_the_command_it_was_asked_for
      assert_equal "Menjalankan test", command("bundle exec rake test 2>&1 | tail -5")
      assert_equal "Memeriksa status git", command("cd repo && git status")
    end

    def test_a_wrapper_does_not_become_the_verb
      assert_equal "Menampilkan isi direktori lib", command("sudo ls lib")
      assert_equal "Menampilkan isi direktori lib", command("env FOO=1 ls lib")
    end

    # Nothing here recognizes the verb, so the row says only what it can say
    # without guessing: the command waits in the tooltip.
    def test_a_command_it_does_not_recognize_is_a_plain_sentence
      assert_equal "Menjalankan perintah di terminal", command("ffmpeg -i a.mp4 b.webm")
      assert_equal "Menjalankan perintah di terminal", command("")
    end

    # Waiting is a command too, and the duration is the whole message: an agent
    # that slept three times while a sub agent worked showed the same empty
    # sentence three times.
    def test_a_wait_says_how_long_it_waited
      assert_equal "Menunggu 45 detik", command("sleep 45")
      assert_equal "Menunggu 1 menit 30 detik", command("sleep 90; echo waited")
      assert_equal "Menunggu 2 menit", command("sleep 2m")
      assert_equal "Menunggu 1 jam", command("sleep 1h")
      assert_equal "Menunggu 1 jam 5 menit", command("sleep 65m")
      assert_equal "Menunggu 1 hari", command("sleep 1d")
      assert_equal "Menunggu sebentar", command("sleep")
    end

    # The durations of a `sleep` add up, so reading only the first would report
    # two thirds of a two-minute wait; and something too short to round to a
    # second is still a wait, just not a countable one.
    def test_a_wait_counts_every_duration_and_never_rounds_down_to_zero
      assert_equal "Menunggu 2 menit", command("sleep 90 30")
      assert_equal "Menunggu 1 menit 1 detik", command("sleep 1m 1")
      assert_equal "Menunggu sebentar", command("sleep 0.4")
      assert_equal "Menunggu sebentar", command("sleep 0")
      assert_equal "Menunggu sebentar", command("sleep abc")
    end

    # Everything `sleep` accepts: the forms a script actually writes, and the
    # one that never ends, which must not read as the shortest wait of all.
    def test_a_wait_reads_the_forms_sleep_itself_accepts
      assert_equal "Menunggu 16 menit 40 detik", command("sleep 1e3")
      assert_equal "Menunggu 5 detik", command("sleep +5")
      assert_equal "Menunggu 1 detik", command("sleep .5")
      assert_equal "Menunggu tanpa batas", command("sleep infinity")
      assert_equal "Menunggu tanpa batas", command("sleep inf")
    end

    def test_a_tooltip_still_carries_the_command
      assert_equal "shell_exec · ls -la", ToolCaption.tooltip("shell_exec", { "command" => "ls -la" })
      assert_equal "shell_exec", ToolCaption.tooltip("shell_exec", {})
    end

    # --- the other tools -------------------------------------------------

    def test_a_file_row_names_the_file_rather_than_the_workspace
      assert_equal "Membaca isi …/rubot/web/turn.rb",
                   ToolCaption.caption("file_ops", { "operation" => "read", "path" => LONG_PATH })
      assert_equal "Mengubah isi lib/rubot/web/turn.rb",
                   ToolCaption.caption("file_ops", { "operation" => "edit",
                                                     "path" => "lib/rubot/web/turn.rb" }),
                   "a path the reader can already place is left alone"
    end

    # Every operation the tool accepts has an entry of its own, and each entry
    # puts the path where that language puts it.
    FILE_ROWS = {
      "read" => "Membaca isi notes.md",
      "write" => "Menulis berkas notes.md",
      "edit" => "Mengubah isi notes.md",
      "append" => "Menambahkan isi ke notes.md",
      "delete" => "Menghapus notes.md",
      "list" => "Menampilkan isi direktori notes.md",
      "info" => "Memeriksa notes.md"
    }.freeze

    def test_every_file_operation_gets_a_sentence
      assert_equal ToolCaption::FILE_OPERATIONS.sort, FILE_ROWS.keys.sort,
                   "the operations the tool takes and the rows they draw are one list"

      FILE_ROWS.each do |operation, sentence|
        assert_equal sentence, ToolCaption.caption("file_ops", { "operation" => operation, "path" => "notes.md" })
      end
    end

    # The other half of the dictionary's bargain: whatever operation a tool can
    # name, both languages have a sentence for it. An operation added to one of
    # these tables and not to the dictionary is a row that raises on screen.
    def test_every_operation_a_tool_accepts_has_a_sentence_in_both_languages
      {
        "tool.file" => ToolCaption::FILE_OPERATIONS,
        "tool.memory" => ToolCaption::MEMORY_OPERATIONS,
        "tool.cron" => ToolCaption::CRON_OPERATIONS,
        "tool.loop" => ToolCaption::LOOP_OPERATIONS,
        "tool.instagram" => ToolCaption::INSTAGRAM_OPERATIONS,
        "tool.git" => ToolCaption::GIT_OPERATIONS,
        "tool.package" => ToolCaption::PACKAGE_OPERATIONS.values.uniq
      }.each do |prefix, operations|
        operations.each do |operation|
          Rubot::I18n::LOCALES.each do |locale|
            refute_empty Rubot::I18n.t("#{prefix}.#{operation}", locale: locale),
                         "#{prefix}.#{operation} has no sentence in #{locale}"
          end
        end
      end
    end

    def test_a_file_row_without_an_operation_reads_like_a_read
      assert_equal "Membaca isi notes.md", ToolCaption.caption("file_ops", { "path" => "notes.md" })
    end

    def test_a_multi_file_read_counts_the_files
      assert_equal "Membaca isi 3 berkas",
                   ToolCaption.caption("file_ops", { "operation" => "read", "paths" => %w[a b c] })
      assert_equal "Membaca isi a.md",
                   ToolCaption.caption("file_ops", { "operation" => "read", "paths" => [ "a.md" ] })
      assert_equal "Membaca isi",
                   ToolCaption.caption("file_ops", { "operation" => "read", "paths" => [] })
    end

    def test_search_says_what_it_is_looking_for
      assert_equal "Mencari \"def tool_started\" di dalam kode",
                   ToolCaption.caption("search", { "operation" => "content",
                                                   "pattern" => "def tool_started" })
      assert_equal "Mencari berkas bernama \"**/*.rb\"",
                   ToolCaption.caption("search", { "operation" => "files", "pattern" => "**/*.rb" })
      assert_equal "Mencari di dalam kode", ToolCaption.caption("search", { "pattern" => "" })
    end

    def test_a_fetch_names_the_page
      assert_equal "Membuka halaman https://example.com/docs",
                   ToolCaption.caption("web_fetch", { "url" => "https://example.com/docs" })
      assert_equal "Membuka sebuah halaman", ToolCaption.caption("web_fetch", {})
    end

    def test_a_delegation_names_the_persona
      assert_equal "Meminta bantuan planner", ToolCaption.caption("delegate", { "agent" => "planner" })
      assert_equal "Meminta bantuan subagent", ToolCaption.caption("delegate", {})
    end

    def test_files_sent_are_counted_not_listed
      assert_equal "Mengirim 2 berkas",
                   ToolCaption.caption("send_files", { "paths" => [ "a.png", "b.png" ] })
      assert_equal "Mengirim satu berkas", ToolCaption.caption("send_files", { "paths" => [ "a.png" ] })
      assert_equal "Mengirim berkas", ToolCaption.caption("send_files", {})
    end

    def test_operations_read_as_the_thing_they_do
      assert_equal "Mengingat kembali catatan", ToolCaption.caption("memory", { "operation" => "read" })
      assert_equal "Mencatat satu hal ke ingatan", ToolCaption.caption("memory", { "operation" => "append" })
      assert_equal "Menjadwalkan tugas berkala", ToolCaption.caption("cron", { "operation" => "add" })
      assert_equal "Melihat daftar tugas terjadwal", ToolCaption.caption("cron", { "operation" => "list" })
      assert_equal "Menyiapkan sambungan Instagram",
                   ToolCaption.caption("instagram", { "operation" => "connect" })
      assert_equal "Bersiap memberi kabar begitu selesai", ToolCaption.caption("notify", {})
    end

    def test_an_unknown_operation_falls_back_to_the_prefix_it_came_from
      assert_equal "Tugas terjadwal: explode", ToolCaption.caption("cron", { "operation" => "explode" })
      assert_equal "Memori", ToolCaption.caption("memory", {})
    end

    # Starting a loop is the one call whose argument matters to the reader: the
    # worktree and the branch follow from the goal, so the goal is the sentence.
    # The rest of the tool is one verb each, and an operation nobody recognises
    # must still read as a sentence rather than as the bare word "start".
    def test_a_loop_says_what_it_is_started_for
      assert_equal "Memulai loop: stop the paging jump",
                   ToolCaption.caption("loop", { "operation" => "start", "goal" => "stop the paging jump" })
      assert_equal "Memulai loop baru", ToolCaption.caption("loop", { "operation" => "start" })
      long = ToolCaption.caption("loop", { "operation" => "start",
                                           "goal" => "one long goal cut before it fills the row " + ("x" * 80) })
      assert long.start_with?("Memulai loop: one long goal"), long
      assert long.end_with?("…"), "a goal is cut, not spilled into the row: #{long.inspect}"
      assert_operator long.length, :<=, "Memulai loop: ".length + Rubot::ToolCaption::PATTERN_CHARS
      assert_equal "Melihat daftar loop", ToolCaption.caption("loop", { "operation" => "list" })
      assert_equal "Membatalkan iterasi terakhir", ToolCaption.caption("loop", { "operation" => "undo" })
      assert_equal "Loop: detach", ToolCaption.caption("loop", { "operation" => "detach" })
      assert_equal "Loop", ToolCaption.caption("loop", {})
    end

    def test_an_unknown_tool_keeps_the_arguments_it_arrived_with
      assert_equal "list", ToolCaption.caption("todo_tool", { "action" => "list" })
      assert_equal "mystery", ToolCaption.caption("mystery", {})
    end

    def test_arguments_that_are_not_a_hash_never_raise
      assert_equal "Menjalankan perintah di terminal", ToolCaption.caption("shell_exec", nil)
      assert_equal "Membaca isi", ToolCaption.caption("file_ops", "nope")
      assert_equal "Mengirim berkas", ToolCaption.caption("send_files", {})
      assert_equal "", ToolCaption.raw("shell_exec", nil)
      assert_equal "", ToolCaption.raw("shell_exec", {})
    end

    # A tooltip is one line, so a list arrives as a list and not as an array
    # inspected into punctuation.
    def test_raw_flattens_a_list_and_keeps_one_line
      assert_equal "a.png, b.png", ToolCaption.raw("send_files", { "paths" => [ "a.png", "b.png" ] })
      assert_equal "ls -la", ToolCaption.raw("shell_exec", { "command" => "ls -la\ngit status" })
    end

    # --- the surfaces ----------------------------------------------------

    # The row is the sentence and the mark: the name of the tool is the agent's
    # word for it, and the tooltip is where the command itself still lives.
    def test_the_live_web_row_draws_the_sentence_and_hovers_the_call
      turn = Web::Turn.new(id: "t1", session_id: "s1")
      args = { "operation" => "read", "path" => LONG_PATH }
      turn.tool_started("file_ops", ToolCaption.caption("file_ops", args),
                        op: "read", title: ToolCaption.tooltip("file_ops", args))

      html = Web::View.turn_body(turn)

      assert_includes html, "Membaca isi …/rubot/web/turn.rb"
      refute_includes html, "tool-name", "the tool's own name is not the reader's word for it"
      assert_includes html, %(title="file_ops · #{LONG_PATH}"), "the call stays reachable on hover"
    end

    # A row with nothing to show carries no tooltip at all: an empty title
    # attribute is a promise of something to read.
    def test_no_tooltip_when_there_is_nothing_to_hover
      turn = Web::Turn.new(id: "t1", session_id: "s1")
      turn.tool_started("shell_exec", "Menjalankan perintah di terminal")

      refute_includes Web::View.turn_body(turn), '<span class="tool-detail" title='
    end

    # A refreshed page replays the calls from the session, and must say exactly
    # what the live turn said.
    def test_the_replayed_transcript_says_the_same_thing_as_the_live_row
      args = { "operation" => "read", "path" => LONG_PATH }
      call = { "id" => "c1", "function" => { "name" => "file_ops", "arguments" => args.to_json } }
      view = Object.new.extend(Web::HistoryView)
      view.define_singleton_method(:sent_attachments) { |*_args| [] }

      row = view.history_tool_items(call, {}, {}, "s1").first

      assert_equal ToolCaption.caption("file_ops", args), row[:detail]
      assert_equal ToolCaption.tooltip("file_ops", args), row[:title]
    end

    def test_the_tui_row_wears_the_same_sentence_inside_its_cell_budget
      args = { "operation" => "read", "path" => LONG_PATH }

      assert_equal ToolCaption.caption("file_ops", args), TUI::Transcript.tool_summary("file_ops", args)
      long = TUI::Transcript.tool_summary("search", { "pattern" => "x" * 200 })
      assert long.end_with?("…"), "the cut is marked"
      assert_operator long.length, :<=, 64
    end

    # The row itself no longer starts with the tool's name, in either renderer.
    def test_the_tui_row_draws_the_sentence_without_the_tool_name
      segments = TUI::Transcript.tool_done("file_ops", "Membaca isi a.rb")
      text = segments.map(&:first).join

      assert_equal "✓ Membaca isi a.rb", text
    end

    def test_the_telegram_card_says_the_same_thing
      assert_equal "Menjalankan test",
                   ToolCaption.caption("shell_exec", { "command" => "bundle exec rake test" })
      assert_equal "Membaca isi lib/rubot/agent.rb",
                   ToolCaption.caption("file_ops", { "operation" => "read", "path" => "lib/rubot/agent.rb" })
    end

    # --- loading a skill -------------------------------------------------

    # A call that reads a SKILL.md is the agent picking instructions up, and
    # that is what the row says: the file it opened is the tooltip's business.
    def test_loading_a_skill_reads_as_loading_that_skill
      assert_equal "Memuat skill brain",
                   ToolCaption.caption("file_ops", { "operation" => "read",
                                                     "path" => "/home/adipurnm/.rubot/skills/brain/SKILL.md" })
      assert_equal "Memuat skill grill",
                   ToolCaption.caption("shell_exec",
                                       { "command" => "cat /home/adipurnm/.rubot/skills/grill/SKILL.md" })
    end

    # The sentence is the dictionary's, in whichever language the reader picked.
    def test_loading_a_skill_is_said_in_the_readers_language
      args = { "operation" => "read", "path" => "/home/adipurnm/.rubot/skills/brain/SKILL.md" }

      english = I18n.with_locale("en") { ToolCaption.caption("file_ops", args) }

      assert_equal "Loading the brain skill", english
    end

    # The file tool reads when it is told no operation, so a bare path is a read
    # and the row must not fall back to "reading <path>".
    def test_a_read_without_an_operation_reads_as_loading_the_skill
      assert_equal "Memuat skill brain",
                   ToolCaption.caption("file_ops", { "path" => "/home/adipurnm/.rubot/skills/brain/SKILL.md" })
    end

    # Several skills in one call are one sentence, joined the way the reader's
    # language joins two names.
    def test_loading_several_skills_names_them_all
      args = { "paths" => [ "/home/adipurnm/.rubot/skills/brain/SKILL.md",
                            "/home/adipurnm/.rubot/skills/grill/SKILL.md" ] }

      assert_equal "Memuat skill brain dan grill", ToolCaption.caption("file_ops", args)
      assert_equal "Loading the brain and grill skills",
                   I18n.with_locale("en") { ToolCaption.caption("file_ops", args) }
    end

    # Three of them need the comma the two of them do not: the list is built
    # rather than the joiner repeated ("brain dan grill dan pr").
    def test_loading_three_skills_commas_all_but_the_last
      args = { "paths" => [ "/home/adipurnm/.rubot/skills/brain/SKILL.md",
                            "/home/adipurnm/.rubot/skills/grill/SKILL.md",
                            "/home/adipurnm/.rubot/skills/pr/SKILL.md" ] }

      assert_equal "Memuat skill brain, grill dan pr", ToolCaption.caption("file_ops", args)
      assert_equal "Loading the brain, grill and pr skills",
                   I18n.with_locale("en") { ToolCaption.caption("file_ops", args) }
    end

    # The TUI row is the same fact in its shorter shape: the mark, the word the
    # dictionary gives it, and the names.
    def test_the_tui_skill_row_takes_its_word_from_the_dictionary
      args = { "paths" => [ "/home/adipurnm/.rubot/skills/brain/SKILL.md",
                            "/home/adipurnm/.rubot/skills/grill/SKILL.md" ] }
      names = TUI::Transcript.skill_load("file_ops", args)
      row = TUI::Transcript.tool_done("file_ops", names, names).map(&:first).join

      assert_equal "brain dan grill", names
      assert_equal "✓ skill brain dan grill", row
    end

    def test_writing_a_skill_file_does_not_read_as_loading_it
      caption = ToolCaption.caption("file_ops", { "operation" => "write",
                                                  "path" => "/home/adipurnm/.rubot/skills/brain/SKILL.md" })

      refute_includes caption, "Memuat skill"
      assert_includes caption, "SKILL.md"
    end

    # A refreshed page replays the skill load as the same row the live turn
    # drew: the sentence and the mark it wears.
    def test_the_replayed_transcript_marks_a_skill_load_the_same_way
      args = { "operation" => "read", "path" => "/home/adipurnm/.rubot/skills/brain/SKILL.md" }
      call = { "id" => "c1", "function" => { "name" => "file_ops", "arguments" => args.to_json } }
      view = Object.new.extend(Web::HistoryView)
      view.define_singleton_method(:sent_attachments) { |*_args| [] }

      row = view.history_tool_items(call, {}, {}, "s1").first

      assert_equal [ "brain" ], row[:skills]
      assert_equal "Memuat skill brain", row[:detail]
    end

    private

    def command(text)
      ToolCaption.caption("shell_exec", { "command" => text })
    end
  end
end
