# frozen_string_literal: true

require "time"

module Rubot
  class Store
    # Applies the numbered .sql files in migrations/ in order, once each.
    #
    # The alternative was the version check that used to live in Store: a
    # `case` over PRAGMA user_version with the DDL inlined, which meant every
    # new schema change edited the code that also ran the old ones. Here a change
    # is a file, and what has been applied is a row.
    #
    # Three things it deliberately does not do: roll back (a broken migration
    # should stop the process, not half-undo an archive), rewrite data (that is
    # a migration's own SQL to write), and guess at gaps — a missing number is
    # fine, the order is what matters.
    class Migrator
      FILENAME = /\A(\d+)_([a-z0-9_]+)\.sql\z/i
      TABLE = "schema_migrations"

      Migration = Struct.new(:version, :name, :path, :sql)

      attr_reader :dir

      def initialize(db, dir:)
        @db = db
        @dir = dir
      end

      # Returns the versions applied by this call, in order. Empty when the
      # database is already up to date, which is the normal case on every boot.
      def run!
        ensure_table!
        baseline_existing!
        pending = migrations.reject { |migration| applied_versions.include?(migration.version) }
        applied = pending.map { |migration| apply(migration) }
        applied
      ensure
        # Also on a failure: whatever did get applied is the version this file is
        # at, and a later run must not treat it as untouched.
        sync_user_version!
      end

      def applied_versions
        @applied_versions ||= @db.execute("SELECT version FROM #{TABLE} ORDER BY version").flatten.map(&:to_i)
      end

      def migrations
        @migrations ||= load_migrations
      end

      private

      def ensure_table!
        @db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{TABLE}(
            version    INTEGER PRIMARY KEY,
            name       TEXT NOT NULL,
            applied_at TEXT NOT NULL
          )
        SQL
      end

      # A database created before this table existed carries its version in
      # PRAGMA user_version and has no rows here. Those migrations are its
      # history, not work to do: re-running 001 would fail on the CREATE TABLE,
      # and re-running 002 on the added column would fail too.
      def baseline_existing!
        return unless applied_versions.empty?

        legacy = @db.get_first_value("PRAGMA user_version").to_i
        return if legacy <= 0

        migrations.select { |migration| migration.version <= legacy }.each do |migration|
          record(migration)
        end
        @applied_versions = nil
      end

      def apply(migration)
        @db.transaction do
          @db.execute_batch(migration.sql)
          record(migration)
        end
        @applied_versions = nil
        migration.version
      end

      def record(migration)
        @db.execute(
          "INSERT OR IGNORE INTO #{TABLE}(version, name, applied_at) VALUES(?, ?, ?)",
          [migration.version, migration.name, Time.now.iso8601]
        )
      end

      # Kept in step with the table so anything reading the file without this
      # class (the sqlite3 CLI, a backup script) still sees a version.
      def sync_user_version!
        latest = applied_versions.max.to_i
        return if latest <= 0

        @db.execute("PRAGMA user_version = #{latest}")
      end

      def load_migrations
        unless File.directory?(@dir)
          raise ArgumentError, "migrations directory not found: #{@dir}"
        end

        files = Dir.glob(File.join(@dir, "*.sql")).sort
        raise ArgumentError, "no migrations in #{@dir}" if files.empty?

        seen = {}
        files.filter_map do |path|
          match = FILENAME.match(File.basename(path))
          unless match
            raise ArgumentError, "migration name not NNN_name.sql: #{File.basename(path)}"
          end

          version = match[1].to_i
          if (clash = seen[version])
            raise ArgumentError, "duplicate migration version #{version}: #{clash} and #{path}"
          end

          seen[version] = path
          Migration.new(version, match[2], path, File.read(path))
        end.sort_by(&:version)
      end
    end
  end
end
