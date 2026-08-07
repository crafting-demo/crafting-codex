---
description: Change the template the Codex router creates worker sandboxes from
argument-hint: "TEMPLATE"
---

Point the Codex router at a different worker template, so every new thread's
sandbox is built from it. The places this name lives and the gotchas are in
the `codex-worker-templates` skill (read its SKILL.md first -- it is installed
under `~/.codex/skills/`, or in the crafting-codex repo under `skills/`).

Arguments given: $ARGUMENTS

- The argument is the template name. If it is missing, run `cs template list`
  and ask which one to use.

Steps, all from the crafting-codex checkout:

1. Verify the template exists (`cs template show TEMPLATE --def`) and that it
   is codex-ready: its workspace installs the Codex CLI and signs it in on
   create. If it is not, suggest `/codexify` and stop.
2. Read the workspace name out of its definition. If there is more than one
   workspace, ask which one threads should run in.
3. Update `codex-cloud.conf`: set `CODEX_ROUTER_TEMPLATE` to the template and
   `CODEX_ROUTER_WORKER_WORKSPACE` to the workspace name. If the template
   checks out a repo, ask whether `CODEX_START_DIR` should be that checkout's
   path and update it too.
4. Apply it to the running router, which takes effect on the next claim with
   no restart: over `ssh codex-cloud`, edit the same keys in
   `~/.codex-router/config`.
5. Make it survive a router rebuild, which re-lays that config file from the
   template: run `python3 build-template.py`, then
   `cs template update codex-router templates/codex-router.yaml`. Do not run
   `./bootstrap.sh` here: it would try to regenerate the worker template the
   conf now names, and that template is not ours to write.
6. Tell the user: existing threads keep the sandboxes they have; only new
   threads use the new template. If the new template has no warm pool, new
   threads build their sandbox from scratch, and `/codexify`'s pool step (or
   `cs sandbox pool create`) fixes that.
