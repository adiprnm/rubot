# frozen_string_literal: true

module Rubot
  class Store
    # The key/value settings the web channel keeps (provider, api key, default
    # model, themes), and the cache file the pre-database installs left behind.
    #
    # Moved as it was, comments included: the legacy file is read once, and only
    # when the table has nothing to say.
    module Settings
      # Settings that belong to the install, not to a file.
      #
      # Read as a plain hash of strings, because that is what a form posts and
      # what config.yml already holds: one shape for both sides of the fallback.
      # A key that was never written is simply absent — the caller decides what
      # stands in for it.
      def settings
        @db.execute("SELECT key, value FROM settings ORDER BY key").to_h do |(key, value)|
          [ key.to_s, value ]
        end
      end

      def setting(key)
        row = @db.execute("SELECT value FROM settings WHERE key = ?", [ key.to_s ]).first
        row && row[0]
      end

      # Nil or an empty string clears the key, which is how a value goes back to
      # whatever config.yml says: "set to nothing" and "never set" must not be two
      # different states on a form with an empty text field.
      def set_setting(key, value)
        name = key.to_s
        text = value.nil? ? nil : value.to_s
        if text.nil? || text.strip.empty?
          @db.execute("DELETE FROM settings WHERE key = ?", [ name ])
        else
          @db.execute(<<~SQL, [ name, text, Time.now.utc.iso8601 ])
            INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
          SQL
        end
        text
      end

      # The whole hash at once, in one transaction: a half-saved form is a
      # provider with the previous key, which fails on the next turn in a way
      # nobody attributes to the form.
      def update_settings(values)
        @db.transaction do
          values.each { |key, value| set_setting(key, value) }
        end
        settings
      end
    end
  end
end
