-- Move the render-only `ui_diff` out of the payload and compress it.
--
-- It is 69% of the archive in practice (21.7 MB over 527 messages, 42 KB each)
-- and no model ever sees it, only channels/web.rb and tui/transcript.rb. Kept as
-- zlib here, not deleted: the reader needs it to draw the diff of an old turn.
--
-- Rows written under this schema keep their diff inside the payload and load
-- just fine, so this migration is the column and nothing else — no rewrite of
-- thousands of rows.
ALTER TABLE messages ADD COLUMN diff BLOB;
