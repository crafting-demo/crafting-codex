---
description: List the Crafting templates available in this org
---

List the Crafting templates the user can build sandboxes from.

```bash
cs template list
```

Lead with the count, then the names. Group them if there are many, and keep
descriptions to a few words each. Do not paste the raw table.

Say which one the Codex router currently builds worker sandboxes from
(`codex-worker` unless it was changed; `~/.codex-router/config` on the router
has `CODEX_ROUTER_TEMPLATE` if you can reach it).

If the user is looking for one to use with Codex, note that `/codexify NAME`
copies a template and adds what a Codex worker needs, and `/cr-set-template
NAME` points the router at it -- both run on their Mac from the crafting-codex
checkout, not from inside a sandbox.
