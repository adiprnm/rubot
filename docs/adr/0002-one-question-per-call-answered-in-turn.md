# One question per `ask_user` call, answered inside the same turn

Superseded by ADR 0010: a call may now carry several questions, asked in order
and confirmed at the end.

`ask_user` carries a single **Question** with up to four **Options**, and the
**Answer** comes back as the tool result so the model keeps working in the turn
that asked. A batch of questions in one call was rejected: it multiplies the
wait for every reader, and the second question of a confused agent usually only
makes sense once the first is answered. Ending the turn on the answer and
starting a new one was rejected too: it costs a second request and drops the
reason the question was asked.
