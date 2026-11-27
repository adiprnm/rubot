# Rubot

The language of rubot's own code and conversation: the words the agent, the
channels and the people using them all depend on. It grows one term at a time,
when a term is settled in conversation and the code starts using it.

## Language

**Question**:
An interruption the agent raises to the reader, published into the **Turn**
timeline and answered there, carrying 2 to 4 **Options** or none at all. One
call may carry several, asked in order and read back as a final confirmation.
_Avoid_: Prompt, dialog, modal, clarification request

**Option**:
One suggested **Answer** offered inside a **Question**, labelled short and
described in one line of consequence.
_Avoid_: Choice, recommendation, suggestion

**Custom answer**:
The free text a reader types instead of picking an **Option**; it is offered as
the last choice of every **Question** that has **Options**.
_Avoid_: Other, free text, manual input

**Answer**:
What the reader returns to a **Question**: an **Option** label, or a **Custom
answer**. Silence and cancellation are not **Answers**, they are recorded as
what they were.
_Avoid_: Response, reply, result

**Ask**:
The one blocking primitive inside a **Turn** that publishes a **Question** or a
dangerous-action confirmation, waits for the reader with a deadline, and folds
the outcome back into the turn.
_Avoid_: Confirmation flow, pending prompt

**Loop budget**:
The hard ceiling on billed tokens one loop may spend, kept in the loop's own
file so a resume, a cron retry or a second process cannot hand a spent loop a
fresh one. It counts what the loop is billed, including the conversation every
request re-sends, and it is enforced twice: a turn is cancelled the moment its
spend reaches the ceiling, and the boundary refuses to buy another iteration.
_Avoid_: Task budget, allowance, quota

**Budget warning**:
The point at which a loop stops on purpose *before* its **Loop budget** is
spent: the iteration it just finished is committed with a subject marked
unverified, no verdict is bought for it, and the reader chooses between keeping
that work, dropping it, and raising the limit. It is checked at the boundary, so
no turn is cancelled for it.
_Avoid_: Soft limit, threshold, nearly out

**Unverified iteration**:
An iteration whose work is committed but whose **Verdict** was never bought,
because the **Budget warning** stopped the loop before the judging turn. It is
recorded in the commit subject, not only in the log, so the branch itself says
the work was never judged.
_Avoid_: Unfinished, incomplete, pending review

**Budget stop**:
The stop that ends an iteration because the **Loop budget** itself ran out,
distinct from a **Budget warning**: the turn was cancelled mid-flight and no
verdict was bought for it.
_Avoid_: Hard stop, cutoff

**Loop limit**:
Either ceiling a loop carries in its own file — its **Loop budget** in tokens,
or its iteration cap. Reaching one stops the loop and leaves it paused, and only
an explicit raise operation moves either.
_Avoid_: Threshold, quota
