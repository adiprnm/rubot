# The user's answer is a tool result, never a user message

When a **Question** is answered, the **Answer** is written into the session as
the result of the `ask_user` call and nothing else. It is not also appended as a
user message, the way a real keystroke would be. A second copy would make the
transcript claim the user typed something they picked from buttons, which breaks
replay, unbalances the message history providers are charged for, and invites a
later "fix" that sends the same answer twice. The turn's timeline row shows the
question and the answer wherever a tool result is shown.
