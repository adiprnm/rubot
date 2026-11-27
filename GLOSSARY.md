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
