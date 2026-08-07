# Crafting sandboxes for Codex

Every thread you start in Codex App gets its own Crafting sandbox.

Codex App connects to one SSH alias, `codex-cloud`, a small router sandbox that
runs no work itself. It reads the `threadId` on the app-server traffic and hands
each thread a worker sandbox of its own, claimed from a warm pool on the
thread's first message.

## Install

You need `cs` installed and logged in, Codex App, and org admin rights once.
Paste this into a local Codex chat:

```text
Set up per-thread Crafting sandboxes for Codex from
https://github.com/crafting-demo/crafting-codex

Clone it, then run ./bootstrap.sh, ./install.sh, and ./doctor.sh, and show me
anything that needs my input. If my org has no openai-api-key secret, ask me
for a key and create it. When you are done, tell me the remote project folder
and what is left for me to do in Codex App.
```

## Finish it in Codex App

Two steps the app owns, so they have to be done by hand.

```text
Settings -> Connections -> SSH -> Add
  Display name: codex-cloud
  Target mode:  Alias
  Alias:        codex-cloud
  Auth mode:    No Auth
```

Enable it, open the remote project folder the install printed, and **name the
project `Crafting Sandbox`**. That name is what "create a new Crafting sandbox"
resolves to, so the skills only work if it matches.

Now start a thread and send a message. It claims a sandbox named `cx-` plus a
digest of the thread id. If anything looks wrong, `./doctor.sh`.

## What you can say

The `crafting-sandbox` skill is written for voice: "spin up a new Crafting
sandbox", "what sandbox am I in", "build X as a task", "how's that task going".
The same things have slash commands — `/cs-new`, `/cs-sandbox`, `/cs-task`,
`/cs-status`, `/cs-templates` — and two that run only on your Mac, `/codexify`
to make one of your templates worker-ready and `/cr-set-template` to point the
router at it.

## Teardown

```bash
./uninstall.sh           # this machine: the ssh alias, the skills, the prompts
./uninstall.sh --all     # and the router sandbox and every worker
./uninstall.sh --purge   # and the templates, pools, secret, service account
```

`--purge` also forgets your saved answers, so a reinstall starts over. Removing
`codex-cloud` from **Settings → Connections → SSH** is yours to do either way.

[DETAILS.md](DETAILS.md) covers how the routing works, what it does not route,
operating the router, billing, and the repo layout. Crafting's own docs are at
[docs.sandboxes.cloud](https://docs.sandboxes.cloud/).
