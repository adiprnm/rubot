# A question does not expire

Supersedes the deadline part of the ask primitive for questions only.

A confirmation keeps its deadline and still fails closed: the action it guards could destroy something, so silence has to mean no. A question is different — silence means the reader has not read it yet, which is not an answer and not a refusal.

So the turn waits, with no deadline of its own, until the question is answered or the turn is stopped. Stopping is the way out, and it releases the wait explicitly, so a question can never hold a session hostage by accident: the reader who wants out presses stop and gets a cancellation, not an expiry they did not ask for.

A channel that has its own deadline (Telegram's confirmation wait) keeps it for confirmations and drops it for questions.
