# A sub agent may not ask the user anything

`ask_user` joins `SUBAGENT_FORBIDDEN_TOOLS`, so a delegated run can never raise
a **Question**. A sub agent has no reader on the other end of its own stream:
the question would either be routed through a parent that is not listening, or
rendered to someone who does not know what the run was doing. A run that needs a
decision returns with its work half done and states the decision it needs; the
parent holds that context and asks. The explicit no is the point: without it,
the obvious "just let sub agents ask too" would be added back the first time one
gets stuck.
