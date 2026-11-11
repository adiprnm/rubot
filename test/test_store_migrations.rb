# frozen_string_literal: true

require_relative "test_helper"

class TestStoreMigrations < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rubot-migrations")
    @db = SQLite3::Database.new(File.join(@dir, "test.db"))
  end

  def teardown
    @db.close if @db && !@db.closed?
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def test_applies_every_migration_in_order
    write_migration(1, "create_things", "CREATE TABLE things(id INTEGER PRIMARY KEY, name TEXT);")
    write_migration(2, "add_note", "ALTER TABLE things ADD COLUMN note TEXT;")

    applied = migrator.run!

    assert_equal [ 1, 2 ], applied
    assert_equal %w[id name note], columns("things")
  end

  def test_records_what_it_applied
    write_migration(1, "create_things", "CREATE TABLE things(id INTEGER);")

    migrator.run!

    assert_equal [ 1 ], migrator.applied_versions
    assert_equal "create_things", @db.get_first_value("SELECT name FROM schema_migrations WHERE version = 1")
    refute_nil @db.get_first_value("SELECT applied_at FROM schema_migrations WHERE version = 1")
  end

  def test_second_run_does_nothing
    write_migration(1, "create_things", "CREATE TABLE things(id INTEGER);")

    assert_equal [ 1 ], migrator.run!
    assert_equal [], migrator.run!, "a migration must never run twice"
  end

  def test_a_new_migration_is_applied_on_the_next_run
    write_migration(1, "create_things", "CREATE TABLE things(id INTEGER);")
    migrator.run!

    write_migration(2, "add_note", "ALTER TABLE things ADD COLUMN note TEXT;")

    assert_equal [ 2 ], migrator.run!
  end

  def test_user_version_follows_the_last_migration
    write_migration(1, "create_things", "CREATE TABLE things(id INTEGER);")
    write_migration(7, "add_note", "ALTER TABLE things ADD COLUMN note TEXT;")

    migrator.run!

    assert_equal 7, @db.get_first_value("PRAGMA user_version").to_i
  end

  def test_database_from_before_the_table_existed_is_baselined
    # What an archive written by the old hardcoded migration path looks like: a
    # schema in place, user_version set, and no record of how it got there.
    @db.execute("CREATE TABLE things(id INTEGER)")
    @db.execute("PRAGMA user_version = 1")
    write_migration(1, "create_things", "CREATE TABLE things(id INTEGER);")
    write_migration(2, "add_note", "ALTER TABLE things ADD COLUMN note TEXT;")

    applied = migrator.run!

    assert_equal [ 2 ], applied, "only the migration it had not seen runs"
    assert_equal [ 1, 2 ], migrator.applied_versions
    assert_equal %w[id note], columns("things")
  end

  def test_a_failing_migration_is_not_recorded_and_stops_the_run
    write_migration(1, "create_things", "CREATE TABLE things(id INTEGER);")
    write_migration(2, "broken", "ALTER TABLE tidak_ada ADD COLUMN x TEXT;")

    assert_raises(SQLite3::SQLException) { migrator.run! }

    assert_equal [ 1 ], migrator.applied_versions
    assert_equal 1, @db.get_first_value("PRAGMA user_version").to_i
  end

  def test_a_failing_migration_leaves_no_half_applied_schema
    write_migration(1, "create_things", "CREATE TABLE things(id INTEGER);")
    write_migration(
      2, "half_way",
      "CREATE TABLE first_half(id INTEGER);\nTHIS IS NOT SQL;\nCREATE TABLE second_half(id INTEGER);"
    )

    assert_raises(SQLite3::SQLException) { migrator.run! }

    assert_empty table_names.grep(/half/)
  end

  def test_gaps_in_numbering_are_allowed
    write_migration(1, "create_things", "CREATE TABLE things(id INTEGER);")
    write_migration(5, "add_note", "ALTER TABLE things ADD COLUMN note TEXT;")

    assert_equal [ 1, 5 ], migrator.run!
  end

  def test_duplicate_versions_are_refused
    write_migration(1, "satu", "CREATE TABLE a(id INTEGER);")
    write_migration(1, "dua", "CREATE TABLE b(id INTEGER);")

    error = assert_raises(ArgumentError) { migrator.run! }
    assert_match(/duplicate migration version 1/, error.message)
  end

  def test_a_badly_named_file_is_refused
    write_migration(1, "ok", "CREATE TABLE a(id INTEGER);")
    File.write(File.join(migrations_dir, "add_something.sql"), "CREATE TABLE b(id INTEGER);")

    error = assert_raises(ArgumentError) { migrator.run! }
    assert_match(/not NNN_name\.sql/, error.message)
  end

  def test_a_missing_directory_is_refused
    migrator = Rubot::Store::Migrator.new(@db, dir: File.join(@dir, "tidak-ada"))

    error = assert_raises(ArgumentError) { migrator.run! }
    assert_match(/migrations directory not found/, error.message)
  end

  def test_the_shipped_migrations_reach_the_schema_the_store_expects
    FileUtils.rm_rf(migrations_dir)

    store = Rubot::Store.new(File.join(@dir, "sessions.db"))
    db = SQLite3::Database.new(File.join(@dir, "sessions.db"))
    versions = db.execute("SELECT version FROM schema_migrations ORDER BY version").flatten

    assert_equal [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 ], versions
    assert_equal %w[id session_id idx role text created_at payload diff user_text assistant_text tool_text],
                 db.execute("PRAGMA table_info(messages)").map { |r| r[1] }
    assert_equal %w[id title created_at updated_at cwd msg_count bytes meta messages_start pinned_at unread_at],
                 db.execute("PRAGMA table_info(sessions)").map { |r| r[1] }
    assert_equal %w[endpoint p256dh auth persona created_at last_seen_at],
                 db.execute("PRAGMA table_info(push_subscriptions)").map { |r| r[1] },
                 "the notification subscriptions are part of the schema the store expects"
    assert_equal %w[id session_id created_at provider model prompt_tokens cached_tokens
                    cache_creation_tokens epoch tools blocks turns auxiliary fingerprint diverged_at
                    diverged_kind diverged_role summary effort],
                 db.execute("PRAGMA table_info(request_cache)").map { |r| r[1] },
                 "the per-request cache diagnosis is part of the schema the store expects"
    assert_match(/fts5/, db.get_first_value("SELECT sql FROM sqlite_master WHERE name = 'fts'"),
                 "the searchable index is part of the schema the store expects")
  ensure
    store&.close
    db&.close unless db&.closed?
  end

  private

  def migrations_dir
    File.join(@dir, "migrations")
  end

  def migrator
    # A fresh instance each time, like Store does on every open: the migration
    # list and the applied set are read from disk and from the database.
    Rubot::Store::Migrator.new(@db, dir: migrations_dir)
  end

  def write_migration(version, name, sql)
    FileUtils.mkdir_p(migrations_dir)
    File.write(File.join(migrations_dir, format("%03d_%s.sql", version, name)), sql)
  end

  def columns(table)
    @db.execute("PRAGMA table_info(#{table})").map { |row| row[1] }
  end

  def table_names
    @db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten
  end
end
