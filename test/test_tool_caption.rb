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

    def test_every_file_operation_gets_a_verb
      ToolCaption::FILE_VERBS.each do |operation, verb|
        assert_equal "#{verb}notes.md",
                     ToolCaption.caption("file_ops", { "operation" => operation, "path" => "notes.md" })
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

    private

    def command(text)
      ToolCaption.caption("shell_exec", { "command" => text })
    end
  end
end
