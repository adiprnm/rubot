# A takeover is a deliberate restart, counted and capped at three

The spec asked for one thing: a loop left `active` by a process that died must be
distinguishable from a loop a live process is iterating, so that a resume knows
which of the two it is looking at. The lease answers that. It does not answer
what a resume should then do, and this note records the part nobody asked for:
the takeover is counted in the file's frontmatter, a run may be taken over three
times without finishing an iteration, and the fourth wake stalls the loop
instead of starting it.

The count exists because the failure it guards against is not an accident. A
loop whose process dies mid-iteration comes back as `active`, counted, and
unheld — exactly the shape a resume treats as "somebody died, pick it up". If a
resume simply ran again, a loop that reliably kills its process would be
restarted forever: one iteration charged per death, no verdict bought, and a
budget drained by a loop that never reaches the point where its own stop
conditions are consulted. Three deaths in a row is not bad luck about a process
restart; it is a statement about the work or the run, and continuing to spend on
it is the one thing a cap on cost is for.

What empties the count is the fact that separates a hard luck story from a
broken loop: an iteration that reached a verdict. `NOT_YET` counts too — a
verdict is a judgement, not a pass, and a loop whose work keeps being judged
unfinished is being worked, not being killed. The count is deliberately not
cleared when `iterations` rises, which is the obvious-looking choice and the
wrong one: an iteration is charged before its turn begins, so a loop that dies
in the middle would clear its own count on the way to dying and the cap would
never fire. `LoopStore` says so where `charge` lives, and `LoopRun` clears the
count at the one point a verdict is reached.

Three is a number, not a measurement: large enough that one unlucky restart is
not read as a loop that kills processes, small enough that a genuinely broken
loop stops before it has cost much. It is a constant rather than a per-loop
field, because it is a judgement about the run and not a knob the reader tunes;
the two numbers a reader does tune are the iteration cap and the token budget,
and both already have a place to live.

The tool writes the cap and the budget. The status and the count belong to the
runner: only the runner can tell a deliberate wake from a process that died,
because only the runner arrives with a lease in hand and an answer about who
held it. The lease file is opened `close_on_exec` for the same reason it exists
at all — rubot forks for tool execution, and an inherited open file description
is an inherited lock, which would make a child that outlives its parent look
like a loop nobody is working. Asking whether the lease is held opens that same
file without creating it, so a question about a loop nobody has run leaves no
directory and no lock file behind, and the answer comes from the open that would
have taken the lock rather than from a separate look at whether the path exists.

## Consequences

- The ceiling is reported, not restarted blindly: at three takeovers the loop
  becomes `stalled` and writes one entry saying how many pickups it took, that
  the run is now the suspect, and that a deliberate resume clears the count and
  runs it again. Nothing offers a silent restart.
- The count cannot be reached by honest failures. A failed iteration pauses the
  loop, and the resume of a paused loop is a deliberate wake that clears the
  count, so only crashes accumulate it. That is why the test seeds the count
  rather than failing three iterations in a row, and why the increment is proved
  one takeover at a time.
- Two wakes that both decide to take a loop over cannot both write the count:
  the number and the log line are written inside the store's own write, after
  the lease is held, so a loser writes nothing for a run that never happened.
- `MAX_TAKEOVERS` is one constant read by the runner that enforces it, so the
  number in the file and the number in the message cannot disagree.
