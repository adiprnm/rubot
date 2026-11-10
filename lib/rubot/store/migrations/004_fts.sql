-- Full-text search over the transcript.
--
-- Three columns instead of one, because a search hit means something different
-- depending on who said it: the person's own words name the conversation, the
-- assistant's answer is where the substance is, and a tool result is mostly
-- repeated file contents. Ranking weights them 10:5:1 at query time (see
-- Rubot::Store#search), which needs them told apart here.
--
-- `content='messages'` makes this an external-content index: FTS5 stores only
-- the index and reads the text back from the messages table, so the archive is
-- not kept twice. The catch is that the content table must have columns with
-- these names, which is what the three ALTERs below are for — they are the
-- searchable projection of `text`, split by role.
--
-- unicode61 with a prefix index rather than trigram: measured on the real
-- archive, unicode61 + prefix='2 3' costs 3.0 MB and trigram costs 13.2 MB, and
-- prefix search at 2-3 characters is what a person actually types. Indexing
-- 4-character prefixes as well doubled the index for no query we make.
ALTER TABLE messages ADD COLUMN user_text TEXT NOT NULL DEFAULT '';
ALTER TABLE messages ADD COLUMN assistant_text TEXT NOT NULL DEFAULT '';
ALTER TABLE messages ADD COLUMN tool_text TEXT NOT NULL DEFAULT '';

-- Tool output is bounded as it is indexed: a single `cat` of a large file is
-- not more searchable than its first 8 KB, and indexing all of it turned the
-- index into a copy of the repository.
UPDATE messages SET
  user_text = CASE WHEN role = 'user' THEN text ELSE '' END,
  assistant_text = CASE WHEN role = 'assistant' THEN text ELSE '' END,
  tool_text = CASE WHEN role = 'tool' THEN substr(text, 1, 8192) ELSE '' END;

CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
  user_text,
  assistant_text,
  tool_text,
  content = 'messages',
  content_rowid = 'id',
  tokenize = 'unicode61 remove_diacritics 2',
  prefix = '2 3'
);

-- Fill the index from the rows that were just projected. The dedupe of repeated
-- tool output is Ruby's job (it needs to look at a session's history), and it
-- runs once on the first search-capable open — see Store#rebuild_index!.
INSERT INTO fts(fts) VALUES('rebuild');

-- An external-content index does not follow its table on its own: FTS5 stores
-- only the index, so a row written here has to be written there too, or the
-- search answers with the archive as it was when the index was built. These
-- three triggers are the documented pattern for keeping the two in step.
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO fts(rowid, user_text, assistant_text, tool_text)
  VALUES (new.id, new.user_text, new.assistant_text, new.tool_text);
END;

CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
  INSERT INTO fts(fts, rowid, user_text, assistant_text, tool_text)
  VALUES ('delete', old.id, old.user_text, old.assistant_text, old.tool_text);
END;

CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
  INSERT INTO fts(fts, rowid, user_text, assistant_text, tool_text)
  VALUES ('delete', old.id, old.user_text, old.assistant_text, old.tool_text);
  INSERT INTO fts(rowid, user_text, assistant_text, tool_text)
  VALUES (new.id, new.user_text, new.assistant_text, new.tool_text);
END;
