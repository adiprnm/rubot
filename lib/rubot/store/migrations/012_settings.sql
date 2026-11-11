-- Settings that belong to the install rather than to a file.
--
-- Provider, the API key and the default model used to live in config.yml, which
-- is fine until the thing that edits them is a web page: a form that writes YAML
-- on the way past, in whatever key order YAML.load_file happened to leave it,
-- is a file nobody can review. The database is where the rest of the install's
-- state already is.
--
-- A key/value table rather than a column per setting: these are fields on one
-- form today, and a new field should not be a migration. `value` is TEXT and
-- NULL means "not set here", which is what lets config.yml keep working as the
-- fallback for every key this table has never heard of.
CREATE TABLE settings(
  key        TEXT PRIMARY KEY,
  value      TEXT,
  updated_at TEXT
);
