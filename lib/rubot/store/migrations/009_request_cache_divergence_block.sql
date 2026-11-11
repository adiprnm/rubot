-- Which block the fingerprint broke on, named instead of numbered.
--
-- `diverged_at` says an index; these two say what is at that index, recorded
-- while the request is still in hand rather than derived later from `blocks`
-- and `turns` (which cannot tell a tool definition from a message when the
-- window was trimmed in the same request).
--
-- `diverged_kind` is `s` (system prompt), `t` (tool definition) or `m`
-- (message). `diverged_role` is the role of a message block — `tool` is a
-- shortened tool result, `assistant` is a dropped reasoning block — and NULL
-- for anything else.
ALTER TABLE request_cache ADD COLUMN diverged_kind TEXT;
ALTER TABLE request_cache ADD COLUMN diverged_role TEXT;
