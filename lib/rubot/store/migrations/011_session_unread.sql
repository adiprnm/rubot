-- A conversation that finished a turn while nobody was looking at it.
--
-- An answer can arrive from a cron job, from another device, or from a turn
-- that outlived the browser tab that started it. The list is the only place it
-- shows up, and a list of forty identically-shaped rows is exactly where it
-- gets missed. NULL means "nothing new since it was last opened"; the timestamp
-- is what the row carries, and the request that opens the session clears it.
ALTER TABLE sessions ADD COLUMN unread_at TEXT;
