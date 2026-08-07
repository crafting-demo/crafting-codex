---
description: Check how a Crafting LLM task is going
argument-hint: "[session name]"
---

Report on a Crafting LLM task, following the `crafting-sandbox` skill's
"Checking On A Task" section.

Session: $ARGUMENTS

If no session was named, run `cs llm session list --status running`. With
exactly one running, use it. With several, ask which. With none, look at the
most recent finished ones (`cs llm session list --limit 5`) and report on that
instead.

Then:

```bash
cs llm session print SESSION_NAME --backward
```

Lead with the state in one short sentence -- still working, finished, or
stopped -- and then a sentence or two on what it has actually done. Do not
read the transcript out or paste long output. If it finished, say what came of
it. If it failed, say why.

Mention `cs llm session cancel SESSION_NAME` only if the task looks stuck or
the user sounds like they want it stopped.
