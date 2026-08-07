---
description: Hand a prompt to a Crafting LLM task and let it run in the background
argument-hint: "what you want built"
---

Start a Crafting LLM task that works on this in the background, following the
`crafting-sandbox` skill's "Crafting LLM Tasks" section.

What to build: $ARGUMENTS

If nothing was given, ask what the task should do before starting anything.

1. Pick a short, memorable session name from the request, like
   `add-login-page`. If a session by that name already exists
   (`cs llm session list`), add a suffix rather than reusing it.
2. Start it detached, and do not drop `--wait=false` -- the default blocks
   until the whole task is done:

   ```bash
   cs llm session run "THE PROMPT" --task --wait=false -n SESSION_NAME
   ```

   Pass the user's request as the prompt, expanded just enough to stand on its
   own without this conversation. If the work belongs in a sandbox that
   already exists, add `-W SANDBOX/WORKSPACE`.
3. Confirm it started (`cs llm session list --status running`).

Then reply in one or two sentences: what it is working on and the session
name, plus that `/cs-status` checks on it. The model is whichever the org
assigned the `CODING` purpose; there is no model flag to set.
