# Crafting Sandbox Skill for Codex

This repo packages a Codex skill for working with Crafting sandboxes through the `cs` CLI.

Official Crafting Sandbox docs are at [docs.sandboxes.cloud](https://docs.sandboxes.cloud/). The skill tells Codex to consult those docs whenever CLI behavior, sandbox definitions, templates, secrets, SSH access, or remote execution details are unclear.

It teaches Codex how to:

- List and inspect Crafting templates.
- Create, show, wait for, resume, and inspect sandboxes.
- Execute commands inside sandbox workloads.
- Connect a Crafting sandbox as a Codex App SSH remote environment.

## Install

Copy or symlink the skill directory into your Codex skills folder:

```bash
mkdir -p ~/.codex/skills
cp -R skills/crafting-sandbox ~/.codex/skills/
```

Then start a new Codex thread. Codex should discover the skill from:

```text
~/.codex/skills/crafting-sandbox/SKILL.md
```

## Prerequisites

- `cs` is installed on the local machine.
- `cs login --status` succeeds, or `cs login --if-needed` can be completed.
- The local machine has OpenSSH.
- The local Codex App is installed if you want to connect sandboxes as remote Codex environments.
- Remote sandboxes expose an OpenAI API key or Codex token, or you can use `codex login --device-auth` inside the sandbox.

## Example Prompts

```text
Use Crafting to list available templates and tell me which one looks like the front-end template.
```

```text
Create a Crafting sandbox from the front-end template, then connect it as a Codex remote environment.
```

```text
Open a Codex thread on my local machine and create a sandbox for my front-end template.
```

For ambiguous template matches, the skill instructs Codex to ask before choosing. If there is only one plausible match, it should pick it.

## Remote Setup Script

The skill includes:

```text
skills/crafting-sandbox/scripts/setup-crafting-codex-remote.sh
```

Run it from the Mac where Codex App is installed:

```bash
skills/crafting-sandbox/scripts/setup-crafting-codex-remote.sh SANDBOX_NAME [SSH_ALIAS]
```

Examples:

```bash
skills/crafting-sandbox/scripts/setup-crafting-codex-remote.sh codex-demo
CODEX_CRAFTING_ORG=eng skills/crafting-sandbox/scripts/setup-crafting-codex-remote.sh lab/codex-demo codex-demo
```

Folder-scoped names like `lab/codex-demo` are supported, but most Crafting sites do not require folder scoping.

The script:

1. Uses `cs sb show` to discover the workload SSH host.
2. Writes a concrete SSH alias to `~/.ssh/config`.
3. Verifies `ssh ALIAS`.
4. Checks whether remote `codex` is installed.
5. Offers to install Node.js, npm, and `@openai/codex` when missing.
6. Logs remote Codex in from `OPENAI_API_KEY`, `CODEX_ACCESS_TOKEN`, or common Crafting secret paths.
7. Runs `codex doctor --summary --ascii`.

## API Key Secret Paths

The setup script checks these Crafting-mounted secret paths:

```text
/run/sandbox/fs/secrets/shared/shared/openai-key
/run/sandbox/fs/secrets/shared/shared/openai-api-key
/run/sandbox/fs/secrets/shared/shared/OPENAI-API-KEY
/run/sandbox/fs/secrets/shared/openai-key
/run/sandbox/fs/secrets/shared/openai-api-key
/run/sandbox/fs/secrets/shared/OPENAI-API-KEY
/run/sandbox/fs/secrets/openai-key
/run/sandbox/fs/secrets/openai-api-key
/run/sandbox/fs/secrets/OPENAI-API-KEY
```

## Repo Layout

```text
skills/crafting-sandbox/
  SKILL.md
  agents/openai.yaml
  references/cs-cli.md
  scripts/setup-crafting-codex-remote.sh
```

## Development

Validate the skill:

```bash
python3 ~/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/crafting-sandbox
```

Or, from this Codex environment:

```bash
python3 /Users/rickykirkendall/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/crafting-sandbox
```
