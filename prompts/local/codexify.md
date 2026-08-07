---
description: Duplicate a Crafting template and make it work as a Codex worker
argument-hint: "SOURCE_TEMPLATE [NEW_NAME]"
---

Make a copy of an existing Crafting template that the Codex router can use as
a worker template, following the recipe in the `codex-worker-templates` skill
(read its SKILL.md first -- it is installed under `~/.codex/skills/`, or in
the crafting-codex repo under `skills/`; it has the exact YAML to add and the
reasons behind it).

Arguments given: $ARGUMENTS

- The first argument is the source template. If it is missing, run
  `cs template list` and ask which one to codexify.
- The second argument is the name for the new template. If it is missing,
  default to `<source>-codex`.

Steps:

1. Work from the crafting-codex checkout, and read its `codex-cloud.conf` for
   `CODEX_ROUTER_ORG` (pass it as `cs -O ORG ...`) and `CODEX_OPENAI_SECRET`.
2. Dump the source: `cs template show SOURCE --def`. Save it to a temp file.
3. Apply the worker additions from the skill to every workspace the user wants
   Codex on (ask if the template has more than one workspace): the OpenAI key
   file, the `on_create` Codex install and login (chained after any existing
   `on_create` command), `$HOME/.local/bin` on PATH, and the `detach_env`
   customization.
4. Validate with `cs template validate`, then create the new template with a
   description saying it was codexified from SOURCE. If a template by that
   name already exists, show the diff and ask before updating it.
5. Ask the user whether they also want a warm pool for it. If yes:
   `cs sandbox pool create NEW_NAME-pool -t NEW_NAME --min 2 --max 6` and
   `cs sandbox pool enable NEW_NAME-pool`. If no, say that new threads will
   build a sandbox from scratch instead of claiming a warm one, which is
   slower but otherwise identical.
6. Finish by telling the user the new template's name and that
   `/cr-set-template NEW_NAME` makes the router create workers from it.

Do not edit the source template itself, and do not set the router's default
template unless the user asks.
