# A question and a dangerous-action confirmation share one blocking primitive

Rubot already blocks a turn for a confirmation before an irreversible action:
a ConditionVariable inside `Turn` for web, a chip prompt in the TUI, inline
buttons on Telegram, each with its own timeout. A question with suggested
answers needs the same wait and a richer answer, so the two are built as one
**Ask** primitive inside `Turn` with two renderings (boolean confirmation,
question with options), rather than a second blocking path with its own
endpoint, deadline and cancellation. Two paths would have to be cancelled,
reconnected and timed out in exactly the same way, and would drift.
