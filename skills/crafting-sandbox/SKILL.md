---
name: crafting-sandbox
description: "Use whenever the user mentions a Crafting sandbox: creating or spinning up a new one, which sandbox the current thread is in, what sandbox templates exist, or starting and checking Crafting LLM tasks that build things in the background. Creating a sandbox means starting a new thread on the codex-cloud connection, never a CLI command."
---

# Crafting Sandbox

## The One Rule

**"Create a new Crafting sandbox" means: create a new thread in the Crafting Sandbox workspace, on the codex-cloud connection.**

"Spin one up", "give me a fresh sandbox", and "new sandbox for this" all mean the same thing. Use your new-chat tool and do it right away -- the request is the go-ahead. Do not ask first, and do not tell the user to press the button themselves.

The workspace and the connection are the whole point. A thread started anywhere else runs on the user's machine and gets no sandbox at all. If that workspace is not available, say so; do not fall back to a local thread.

**Never create a sandbox with the `cs` CLI.** Not `cs sb create`, not `cs sandbox create`, not a template command that makes one as a side effect. A sandbox made that way has no thread attached to it and the router knows nothing about it, so it is not the thing the user asked for.

Say one sentence afterwards: the chat is ready, and their first message in it lands in a fresh sandbox. The sandbox is claimed on that first message, so do not call it ready before then.

## Speaking To The User

Most of this is used by voice. Lead with the answer in one short sentence -- the sandbox name, the task's state, how many templates there are -- and offer detail only if asked. Do not read out IDs, hostnames, or tables.

## Which Sandbox Am I In

```bash
cat /run/sandbox/fs/metadata/sandbox.json
```

`name` is the answer. This file is written live, so it is right even after a sandbox is claimed from the warm pool and renamed. `$SANDBOX_NAME` is baked when the sandbox is built and is stale or empty on a pooled one, and `cs sandbox show` does not report the current sandbox. If the file does not exist, this thread is not running in a sandbox.

## Crafting LLM Tasks

A task is Crafting's own agent working in the background, on its own, separate from this conversation. Use one when the user asks to build or investigate something "as a task", in the background, or while they get on with something else.

```bash
cs llm session run "THE PROMPT" --task --wait=false -n SESSION_NAME
```

- Pick a short, memorable `SESSION_NAME` from the request, like `add-login-page`, and tell the user what it is.
- Never drop `--wait=false`. The default blocks until the whole task finishes.
- `--task` means the task auto-approves its own work and will not stop to ask.
- Pass the request as a prompt that stands on its own without this conversation.
- The model is whichever the org gave the `CODING` purpose; there is no model flag.

Then one sentence: what it is working on, and that you will check when asked.

## Checking On A Task

```bash
cs llm session list --status running    # what is still going
cs llm session print NAME --backward    # newest messages first
cs llm session cancel NAME              # stop it
```

If the user does not name the task, `--status running` usually has exactly one; ask which if there are several. Lead with the state -- working, finished, or failed -- then a sentence on what it has done. Do not read the transcript out.

## Listing Templates

```bash
cs template list
```

Say how many and name them; group them if there are many. `cs template show TEMPLATE --def` has the detail for one.

Templates are what worker sandboxes are built from. If the user wants one of theirs to work with Codex, `/codexify TEMPLATE` copies it and adds what a worker needs, and `/cr-set-template TEMPLATE` points the router at it. Both run on their Mac from the crafting-codex checkout, not from inside a sandbox.

## Notes

`cs` is already authenticated wherever this runs. Inside a sandbox it acts as the sandbox's owner and the org is implicit; on the user's Mac it acts as them, and may need `-O ORG`.

`references/cs-cli.md` has command detail for inspecting sandboxes and running tasks.

`references/one-sandbox.md` covers the older setup, where the user wires one named sandbox to Codex App by hand and every thread shares it. It only ships on the Mac, since it is all Mac-side work, and it is only for a user who asks about that setup by name. It is never a way to answer The One Rule above.
