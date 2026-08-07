# Crafting `cs` CLI Reference

Use this reference when you need command details beyond the core workflow in `SKILL.md`.

Official docs: https://docs.sandboxes.cloud/

Useful doc areas to check when details are needed:

- Concepts: Sandbox, Template, Secret, Service Account.
- Features: Workspace SSH Access, Environment Variables and Metadata Filesystem, Readiness and Wait For, Workload Remote Exec.
- References: Sandbox Definition.

## Authentication And Scoping

```bash
cs login --status
cs login --if-needed
cs org list
```

Most Crafting sites do not require folder scoping. If a command cannot find `lab/name`, use:

```bash
cs -O ORG --folder lab sb show name
```

Use `-O ORG` when no organization is selected or when the same name exists across orgs.

## Templates

```bash
cs template list
cs template show TEMPLATE
cs template show TEMPLATE --def
cs -O ORG template list
```

Selection heuristic:

- Prefer exact name or description matches.
- For "front-end", look for names such as `frontend`, `front-end`, `ui`, `web`, `react`, `next`, or descriptions mentioning frontend work.
- If exactly one plausible template exists, use it.
- If multiple plausible templates exist, ask the user to choose.

## Sandboxes

These read and control sandboxes that already exist:

```bash
cs sb list
cs sb show SANDBOX
cs sb show SANDBOX --def
cs sb resume SANDBOX --wait
cs sb suspend SANDBOX
cs wait sandbox SANDBOX
```

There is deliberately no create command here. A new Crafting sandbox is a new
thread in the Crafting Sandbox workspace, per the One Rule in `SKILL.md`. The
one case that still creates one by CLI is the old Mac-side setup, and it is
documented there rather than here.

## LLM Tasks And Sessions

```bash
cs llm session run "PROMPT" --task --wait=false -n NAME
cs llm session run @prompt.txt --task --wait=false -n NAME
cs llm session run "PROMPT" --task --wait=false -n NAME -W SANDBOX/WORKSPACE
cs llm session list
cs llm session list --status running
cs llm session list --created-since=-1h
cs llm session print NAME
cs llm session print NAME --backward --print json
cs llm session watch NAME
cs llm session resume NAME "FOLLOW UP"
cs llm session cancel NAME
cs llm session remove NAME -f
```

Flags on `run` worth knowing:

- `--wait` defaults to true and blocks until the task finishes. Always pass `--wait=false` for background work.
- `--task` archives the session when it completes and sets approval to auto. `--interactive` keeps it resumable instead.
- `--resume-if-exist` reuses the named session rather than failing.
- `--agent`, `--allow-template`, `--exclude-template` constrain what the agent may use.
- `--initiator EMAIL` records who asked, useful when the caller is a service account.

There is no `--model` flag. The model comes from the org's LLM configuration by purpose:

```bash
cs llm config models list
cs llm config providers list
```

The model marked `CODING` is what coding tasks use.

Status lives at `content.status.state` (`RUNNING` or `STOPPED`) in `-o json` output:

```bash
cs llm session list -o json | jq -r '.[] | "\(.meta.name) \(.content.status.state)"'
```

## Sandbox Identity From Inside

```bash
cat /run/sandbox/fs/metadata/sandbox.json   # id, name, fullName
ls /run/sandbox/fs/metadata/                # owner.json, template.json, app-domain
```

`$SANDBOX_NAME` and the other `SANDBOX_*` variables are set when the sandbox image is built, so a sandbox claimed from a pool and renamed reports a stale or empty name. The metadata file is live and is the reliable source.

Inside a sandbox, `cs` is authenticated as the sandbox owner and the org is implicit; `-O ORG` is not needed and `cs info` shows which identity it is.

## Commands In Workloads

```bash
cs exec -W SANDBOX/WORKLOAD -- pwd
cs exec -W SANDBOX/WORKLOAD -w REMOTE_PROJECT_DIR -- ls -la
cs exec -W SANDBOX/WORKLOAD -e FOO=bar -- printenv FOO
cs ssh -W SANDBOX/WORKLOAD -- 'whoami; hostname; pwd'
```

Use `cs exec` for deterministic noninteractive command execution. Use `cs ssh` when checking login-shell PATH or testing the same path OpenSSH/Codex App will use.

SSH aliases, the remote setup script, and the rest of the Mac-side wiring live
in `references/one-sandbox.md`.
