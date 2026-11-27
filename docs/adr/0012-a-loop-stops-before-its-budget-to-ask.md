# A loop that nears its budget commits unverified and asks before spending more

A loop that reaches 90% of its **Loop budget** stops at the next iteration
boundary, commits the iteration it just finished with a subject marked
unverified, buys no verdict for it, and reports that the work is unjudged rather
than unfinished. The reader then chooses between three things: keep the work and
stop, drop the last iteration, or raise the limit and continue.

The alternative — withholding the commit so the work sits dirty while the loop
waits for an answer — follows the letter of "stop without committing" but costs
more than it buys. The commit happens the moment an iteration's turn returns,
well before the budget is consulted, so withholding it means reversing a commit
that was already justified and leaving the worktree dirty for as long as nobody
answers: hours, or days. It also disarms undo, which resets with
`git reset --hard HEAD~1` and would destroy that work without saying so. Keeping
the commit leaves the branch a complete record with a sha on every logged
iteration, and the "unverified" marker is what stops `git log` from implying a
verdict that was never bought.

## Consequences

- The same marker covers the harder stop, where the budget runs out mid-turn and
  the turn is cancelled: both stops read alike in the branch's history.
- Undo stays meaningful and safe, because the worktree is clean when the choice
  is offered.
- One operation raises either ceiling — `max_tokens`, `max_iterations`, or both
  — because a loop stopped at its iteration cap is stuck the same way as one
  stopped for its budget: `resume` refuses the first and only re-stops the
  second.
- When the worktree is clean there is nothing to keep or drop, so only the raise
  is offered. An empty choice is worse than an absent one.
- The warning is a constant fraction (90%), not a per-loop field, so no new fact
  has to stay in sync across every path that writes the file.
- The stop reaches the reader through the loop sheet's existing repaint. A push
  notification stays out of this change and is decided once the flow has shown
  it stops while nobody is watching.
- The default budget stays at 12 million tokens. Three iterations cost at most
  17.4 million measured, so a 20 million default would make the warning
  unreachable code.
