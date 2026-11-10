# frozen_string_literal: true

require_relative "test_helper"

class TestStore < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rubot-store")
    @sessions = File.join(@dir, "sessions")
    FileUtils.mkdir_p(@sessions)
    @db_path = Rubot::Store.path_for(@sessions)
    @store = Rubot::Store.new(@db_path)
  end

  def teardown
    @store&.close
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def build_message(role, content, extra = {})
    { "role" => role, "content" => content, "timestamp" => "2026-11-10T03:06:00Z" }.merge(extra)
  end

  def test_path_for_sits_next_to_the_sessions_directory
    assert_equal File.join(@dir, "sessions.db"), @db_path
  end

  def test_append_and_load_round_trips_a_tool_call
    tool_call = {
      "role" => "assistant",
      "content" => "",
      "reasoning_content" => "pikir dulu",
      "tool_calls" => [{ "id" => "call_1", "function" => { "name" => "shell", "arguments" => "{}" } }],
      "timestamp" => "2026-11-10T03:07:00Z"
    }
    @store.append_messages("web_rubot", [build_message("user", "halo"), tool_call])

    loaded = @store.load_session("web_rubot")[:messages]

    assert_equal 2, loaded.size
    assert_equal "halo", loaded[0]["content"]
    assert_equal "pikir dulu", loaded[1]["reasoning_content"]
    assert_equal "call_1", loaded[1]["tool_calls"][0]["id"]
  end

  def test_append_is_idempotent
    @store.append_messages("s1", [build_message("user", "satu"), build_message("assistant", "dua")])
    again = @store.append_messages("s1", [build_message("user", "satu"), build_message("assistant", "dua")])

    assert_equal 0, again
    assert_equal 2, @store.message_count("s1")
  end

  def test_start_index_places_messages_at_their_position
    @store.append_messages("s1", [build_message("user", "satu")], start_index: 0)
    @store.append_messages("s1", [build_message("assistant", "dua")], start_index: 1)

    assert_equal 1, @store.last_index("s1")
    assert_equal %w[satu dua], @store.load_session("s1")[:messages].map { |m| m["content"] }
  end

  def test_sidebar_returns_metadata_newest_first
    @store.append_messages("lama", [build_message("user", "lama")])
    @store.upsert_session(id: "lama", title: "Percakapan lama", updated_at: "2026-11-09T10:00:00Z")
    @store.append_messages("baru", [build_message("user", "baru")])
    @store.upsert_session(id: "baru", title: "Percakapan baru", updated_at: "2026-11-10T10:00:00Z")

    rows = @store.sidebar(limit: 10)

    assert_equal %w[baru lama], rows.map { |row| row[:id] }
    assert_equal "Percakapan baru", rows[0][:title]
  end

  def test_sidebar_limit
    5.times do |i|
      @store.append_messages("s#{i}", [build_message("user", "pesan #{i}")])
      @store.upsert_session(id: "s#{i}", title: "s#{i}", updated_at: "2026-11-0#{i + 1}T10:00:00Z")
    end

    assert_equal 3, @store.sidebar(limit: 3).size
  end

  def test_upsert_session_counts_messages
    @store.append_messages("s1", [build_message("user", "a"), build_message("assistant", "b")])
    @store.upsert_session(id: "s1", title: "judul")

    assert_equal 2, @store.sidebar.first[:messages]
  end

  def test_messages_are_never_deleted
    @store.append_messages("s1", [build_message("user", "a"), build_message("assistant", "b")])
    # Re-adding a title, then appending nothing, must not clear the transcript.
    @store.upsert_session(id: "s1", title: "judul baru")

    assert_equal 2, @store.message_count("s1")
  end

  def test_import_directory_skips_empty_sessions_and_is_idempotent
    write_session("s1", [build_message("user", "halo"), build_message("assistant", "hai")])
    write_session("kosong", [])

    stats = @store.import_directory(@sessions)

    assert_equal 2, stats[:files]
    assert_equal 1, stats[:sessions]
    assert_equal 1, stats[:skipped]
    assert_equal 2, @store.message_count("s1")
    assert_equal 1, @store.sidebar.size

    again = @store.import_directory(@sessions)

    assert_equal 2, again[:files]
    assert_equal 2, @store.message_count("s1"), "import does not duplicate history"
  end

  def test_import_keeps_the_title_the_sidebar_shows
    write_session("s1", [build_message("user", "cara pasang tailscale"), build_message("assistant", "begini")], title: nil)

    @store.import_directory(@sessions)

    assert_equal "cara pasang tailscale", @store.sidebar.first[:title]
  end

  def test_load_session_returns_nil_when_unknown
    assert_nil @store.load_session("tidak-ada")
  end

  def test_store_reopens_without_losing_rows
    @store.append_messages("s1", [build_message("user", "a")])
    @store.close
    @store = Rubot::Store.new(@db_path)

    assert_equal 1, @store.message_count("s1")
  end

  def test_append_creates_the_sidebar_row
    # A conversation with messages but no row would be invisible in the sidebar.
    @store.append_messages("s1", [build_message("user", "halo")])

    rows = @store.sidebar

    assert_equal 1, rows.size
    assert_equal "s1", rows[0][:id]
    assert_equal 1, rows[0][:messages]
  end

  def test_append_moves_the_session_forward_and_never_back
    @store.append_messages("s1", [build_message("user", "satu", "timestamp" => "2026-11-10T03:00:00Z")])
    @store.append_messages("s1", [build_message("assistant", "dua", "timestamp" => "2026-11-10T05:00:00Z")], start_index: 1)

    assert_equal "2026-11-10T05:00:00Z", @store.sidebar.first[:updated_at]

    # An append carrying an older timestamp (a replayed turn) must not drag the
    # conversation down the list.
    @store.append_messages("s1", [build_message("user", "tiga", "timestamp" => "2026-11-10T01:00:00Z")], start_index: 2)

    assert_equal "2026-11-10T05:00:00Z", @store.sidebar.first[:updated_at]
  end

  def test_ui_diff_round_trips_through_its_own_column
    diff = { "path" => "lib/rubot/store.rb", "before" => "a\nb\n", "after" => "a\nc\n" }
    tool_message = build_message("tool", "[ok] edit", "ui_diff" => diff)
    @store.append_messages("s1", [tool_message])

    loaded = @store.load_session("s1")[:messages].first

    assert_equal diff, loaded["ui_diff"]
    assert_equal "[ok] edit", loaded["content"]
  end

  def test_payload_does_not_contain_the_diff
    diff = { "path" => "x.rb", "before" => "y" * 500, "after" => "z" * 500 }
    @store.append_messages("s1", [build_message("tool", "hasil", "ui_diff" => diff)])

    payload = @store.instance_variable_get(:@db).get_first_value("SELECT payload FROM messages")
    blob = @store.instance_variable_get(:@db).get_first_value("SELECT diff FROM messages")

    refute_includes payload, "ui_diff", "the render-only field is not in the payload"
    refute_includes payload, "y" * 100
    assert blob.bytesize < JSON.generate(diff).bytesize, "the diff is stored compressed"
  end

  def test_message_without_diff_stores_no_blob
    @store.append_messages("s1", [build_message("user", "biasa saja")])

    blob = @store.instance_variable_get(:@db).get_first_value("SELECT diff FROM messages")

    assert_nil blob
  end

  def test_row_from_schema_one_still_loads_its_diff
    # A row written before schema 2: the diff is still inside the payload and the
    # diff column is empty. Load must return it either way.
    diff = { "path" => "lama.rb", "before" => "1", "after" => "2" }
    legacy = JSON.generate(build_message("tool", "hasil lama", "ui_diff" => diff))
    db = @store.instance_variable_get(:@db)
    db.execute(
      "INSERT INTO messages(session_id, idx, role, text, created_at, payload) VALUES(?,?,?,?,?,?)",
      ["s1", 0, "tool", "hasil lama", "2026-11-10T03:00:00Z", legacy]
    )

    loaded = @store.load_session("s1")[:messages].first

    assert_equal diff, loaded["ui_diff"]
  end

  def test_corrupt_diff_blob_does_not_stop_the_transcript
    @store.append_messages("s1", [build_message("tool", "hasil")])
    @store.instance_variable_get(:@db).execute("UPDATE messages SET diff = ?", ["bukan zlib"])

    loaded = @store.load_session("s1")[:messages].first

    assert_equal "hasil", loaded["content"]
    refute loaded.key?("ui_diff")
  end

  def test_session_meta_round_trips
    @store.append_messages("s1", [build_message("user", "halo")])
    meta = {
      "summary" => "ringkasan",
      "system_prompt" => "PROMPT",
      "system_prompt_epoch" => { "model" => "m" },
      "task" => "tugas"
    }

    @store.upsert_session(id: "s1", title: "judul", meta: meta)

    assert_equal meta, @store.load_session("s1")[:meta]
  end

  def test_messages_start_moves_the_window
    @store.append_messages("s1", [
      build_message("user", "lama"),
      build_message("assistant", "juga lama"),
      build_message("user", "baru")
    ])
    @store.upsert_session(id: "s1", messages_start: 2)

    loaded = @store.load_session("s1")

    assert_equal [ "baru" ], loaded[:messages].map { |m| m["content"] }
    assert_equal 2, loaded[:start]
    assert_equal 3, @store.message_count("s1"), "the archive keeps what the window dropped"
  end

  def test_upsert_without_meta_does_not_clear_it
    @store.upsert_session(id: "s1", meta: { "summary" => "penting" }, messages_start: 5)
    @store.upsert_session(id: "s1", title: "judul baru")

    loaded = @store.load_session("s1")

    assert_equal "penting", loaded[:meta]["summary"]
    assert_equal 5, loaded[:start]
  end

  def test_import_can_skip_sessions_already_archived
    write_session("s1", [build_message("user", "lama")])
    @store.import_directory(@sessions)

    # Unchanged file: skipped without parsing.
    stats = @store.import_directory(@sessions, skip_existing: true)

    assert_equal 1, stats[:skipped]
    assert_equal 1, @store.message_count("s1")
  end

  def test_import_tops_up_a_session_whose_file_grew
    write_session("s1", [build_message("user", "lama")])
    @store.import_directory(@sessions)

    # What a still-running old process does: the file keeps growing after the
    # import. The extra messages must land, not be skipped forever.
    write_session("s1", [ build_message("user", "lama"), build_message("assistant", "baru") ])
    @store.import_directory(@sessions, skip_existing: true)

    assert_equal 2, @store.message_count("s1")
  end

  def test_import_carries_the_session_summary
    data = {
      "id" => "s1",
      "created_at" => "2026-11-10T03:00:00Z",
      "updated_at" => "2026-11-10T03:05:00Z",
      "summary" => "ringkasan yang sudah memadatkan 300 pesan",
      "system_prompt" => "PROMPT TERPIN",
      "system_prompt_epoch" => { "model" => "m" },
      "forced_skill" => "todotxt",
      "messages" => [ build_message("user", "halo") ]
    }
    File.write(File.join(@sessions, "s1.json"), JSON.generate(data))

    @store.import_directory(@sessions)

    meta = @store.load_session("s1")[:meta]
    assert_equal "ringkasan yang sudah memadatkan 300 pesan", meta["summary"],
                 "a compacted session must keep the summary it was compressed into"
    assert_equal "PROMPT TERPIN", meta["system_prompt"]
    assert_equal "todotxt", meta["forced_skill"]
  end

  # WEBrick hands over request paths as ASCII-8BIT, and sqlite3 binds such a
  # string as a BLOB. A BLOB is not the TEXT row of the same bytes, so the
  # conversation would land in a second row that no lookup by id finds — this
  # is the shape of the bug that left sessions without a name or a timestamp.
  def test_a_binary_session_id_writes_to_the_text_row
    binary = "web_rubot~20261110-030626".dup.force_encoding(Encoding::ASCII_8BIT)

    @store.append_messages(binary, [build_message("user", "halo")])
    @store.upsert_session(id: binary, title: "Konsumsi memori rubot web", updated_at: "2026-11-10T03:06:00Z")

    assert_equal 1, @store.message_count("web_rubot~20261110-030626")
    assert @store.session?("web_rubot~20261110-030626"), "a lookup by the text id must find it"
    assert_equal [ "web_rubot~20261110-030626" ], @store.session_ids
    assert_equal "Konsumsi memori rubot web", @store.sidebar.first[:title]
    assert_equal "text", @store.instance_variable_get(:@db)
                              .execute("SELECT typeof(id) FROM sessions").first.first
  end

  def test_a_session_is_written_once_under_either_encoding
    @store.append_messages("web_rubot", [build_message("user", "halo")])
    binary = "web_rubot".dup.force_encoding(Encoding::ASCII_8BIT)
    @store.append_messages(binary, [build_message("assistant", "hai")], start_index: 1)

    assert_equal 1, @store.session_ids.length, "one conversation, one row"
    assert_equal 2, @store.message_count("web_rubot")
  end

  # /resume printed an empty name and "unknown" for every conversation once the
  # archive answered instead of the files: the sidebar row had the timestamp and
  # the title, but the entry handed to the channels dropped them.
  def test_index_entries_carry_the_name_and_the_timestamp
    @store.append_messages("web_rubot~1", [build_message("user", "halo")])
    @store.upsert_session(id: "web_rubot~1", title: "Konsumsi memori rubot web",
                          updated_at: "2026-11-10T03:06:00Z")
    Rubot::Session.store = @store

    entry = Rubot::Session.index(nil, cwd: :all, dir: @sessions).first

    assert_equal "2026-11-10T03:06:00Z", entry[:updated_at]
    assert_equal "Konsumsi memori rubot web", Rubot::Session.label(entry)
  ensure
    Rubot::Session.store = nil
  end

  def test_label_falls_back_from_name_to_prompt_to_id
    assert_equal "Nama dari model", Rubot::Session.label(title: "Nama dari model", last_prompt: "prompt", id: "s1")
    assert_equal "prompt", Rubot::Session.label(title: "  ", last_prompt: "prompt", id: "s1")
    assert_equal "s1", Rubot::Session.label(title: nil, last_prompt: nil, id: "s1")
  end

  def test_saving_without_a_field_does_not_clear_it
    @store.append_messages("s1", [build_message("user", "halo")])
    @store.upsert_session(id: "s1", title: "nama", updated_at: "2026-11-10T03:00:00Z",
                          cwd: "/tmp/x", bytes: 1234)

    # Every turn saves the session with only what it knows. A blank must mean
    # "not told", or the name, the sort key and the byte count are erased once
    # per turn.
    @store.upsert_session(id: "s1", title: "", updated_at: nil, cwd: nil, bytes: 0)

    row = @store.sidebar.first
    assert_equal "nama", row[:title]
    assert_equal "2026-11-10T03:00:00Z", row[:updated_at]
    assert_equal "/tmp/x", row[:cwd]
    assert_equal 1234, @store.session_sizes["s1"]
  end

  def test_a_saved_session_keeps_its_updated_at
    @store.append_messages("s1", [build_message("user", "halo")])
    first = @store.sidebar.first[:updated_at]

    refute_nil first, "a session that was appended to must have a timestamp"
    @store.upsert_session(id: "s1", title: "judul")
    assert_equal first, @store.sidebar.first[:updated_at]
  end

  private

  def write_session(id, messages, title: nil)
    data = {
      "id" => id,
      "created_at" => "2026-11-10T03:00:00Z",
      "updated_at" => "2026-11-10T03:05:00Z",
      "messages" => messages
    }
    data["title"] = title if title
    File.write(File.join(@sessions, "#{id}.json"), JSON.generate(data))
  end
end
