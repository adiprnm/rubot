# One call may ask several questions, in order, with a confirmation at the end

Supersedes ADR 0002.

`ask_user` takes a `questions` list of up to five entries, put to the reader one at a time — each replacing the one before it in the same place — and then read back as a single confirmation with two choices, send and start over. A decision that needs three facts is one interruption, not three, which is what the old one-question-per-call rule cost.

The sequence lives in the tool, not in each channel: every surface already knows how to put one question in front of a reader, and the next one is the same call again. That is also why the confirmation is expressed as an ordinary question with two options rather than a new kind of screen — every channel renders it without knowing it is special.

A list of one skips the confirmation. Confirming the single choice the reader just made is friction with no question behind it.

The answers come back together, numbered and paired with their questions, or not at all: a reader who walks away mid-list reports a cancellation rather than a half-finished set the model might act on.
