# Crafting Sandbox Skill for Codex

This repo packages a Codex skill for working with Crafting sandboxes through the `cs` CLI.

Official Crafting Sandbox docs are at [docs.sandboxes.cloud](https://docs.sandboxes.cloud/). The skill tells Codex to consult those docs whenever CLI behavior, sandbox definitions, templates, secrets, SSH access, or remote execution details are unclear.

It teaches Codex how to:

- List and inspect Crafting templates.
- Create, show, wait for, resume, and inspect sandboxes.
- Execute commands inside sandbox workloads.
- Connect a Crafting sandbox as a Codex App SSH remote environment.
- Install a `cs codex-open` extension for opening manually-created sandboxes in Codex.

## Install / Use With Codex

Open Codex and type:

```text
Use this repo to set up a new sandbox called codex-sandbox with an empty workspace:
https://github.com/crafting-demo/crafting-codex
```

Codex should fetch this repo, read `skills/crafting-sandbox/SKILL.md`, use the bundled setup script, create the Crafting sandbox, and prepare it for use as a Codex App SSH remote environment.

The setup script writes a working SSH alias and verifies the remote Codex CLI, but Codex App may not automatically show newly written SSH aliases. If the connection does not appear in **Settings -> Connections -> SSH**, add it manually:

```text
Settings -> Connections -> SSH -> Add
Display name: codex-sandbox
Target mode: Alias
Alias: codex-sandbox
Auth mode: No Auth
```

Then enable the connection and choose `/home/owner` as the project folder.

For a manual local install, copy or symlink the skill directory into your Codex skills folder:

```bash
mkdir -p ~/.codex/skills
cp -R skills/crafting-sandbox ~/.codex/skills/
```

## Install As A `cs` Extension

Crafting's CLI can install git repositories that contain executables named `cs-FOO`.
This repo includes `cs-codex-open`, so after installing it you can run `cs codex-open ...`.

```bash
cs extensions install https://github.com/crafting-demo/crafting-codex
```

To refresh an existing install:

```bash
cs extensions uninstall https://github.com/crafting-demo/crafting-codex || true
cs extensions install https://github.com/crafting-demo/crafting-codex
```

Then open a manually-created sandbox/workspace in Codex. Folder-scoped sandbox names
such as `lab/ricky5` are resolved before treating a slash as `SANDBOX/WORKLOAD`.

```bash
cs codex-open SANDBOX/WORKLOAD
cs codex-open SANDBOX/WORKLOAD SSH_ALIAS
cs codex-open SANDBOX --workload WORKLOAD --project-dir /home/owner
cs codex-open SANDBOX/WORKLOAD --no-install-codex
```

Examples:

```bash
cs codex-open codex-demo/app
cs codex-open codex-demo/app codex-demo
CODEX_CRAFTING_ORG=eng cs codex-open lab/codex-demo --workload app --alias codex-demo
```

The extension:

1. Reuses `skills/crafting-sandbox/scripts/setup-crafting-codex-remote.sh`.
2. Creates or updates a concrete SSH alias in `~/.ssh/config`.
3. Verifies SSH and remote `codex app-server` readiness.
4. Uses an existing remote `codex` command, or installs Node.js, npm, and `@openai/codex` by default when `codex` is missing.
5. Removes the previous `cs codex` shim if it was created by an older version of this extension.
6. Opens Codex Desktop with `codex app`.

Codex Desktop still owns the supported final registration step. The extension writes the SSH alias so it appears in the app's **Add SSH Connection** list, but the app must add/enable the connection and choose the remote project folder from **Settings -> Connections -> SSH**.

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

The script does not write Codex App's private local UI storage. The final connection registration, enable toggle, and project-folder selection happen in Codex App.

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

## Which OpenAI Account Pays For Usage?

There are two separate pieces of auth to keep straight:

1. The local Codex App uses your locally signed-in Codex/ChatGPT account while it is doing local work, such as helping you create a sandbox with the `cs` CLI.
2. Once the Codex App connects to a sandbox over SSH, it starts the Codex app server on the remote sandbox. Threads running inside that remote environment use the remote sandbox's Codex authentication.

So if the sandbox runs:

```bash
cat /run/sandbox/fs/secrets/shared/shared/openai-key | codex login --with-api-key
```

then Codex work in that sandbox uses the OpenAI API key. That means usage is billed through the OpenAI Platform project/organization for that key, not through your ChatGPT subscription credits.

If you want Codex in the sandbox to use your ChatGPT/Codex account instead, use one of these options:

### Option 1: Device auth in the sandbox

```bash
ssh codex-demo
codex login --device-auth
```

Then open the printed link in your browser and sign in with the same ChatGPT account you use locally.

### Option 2: Copy your local Codex auth cache

If your local machine has `~/.codex/auth.json`, copy it to the sandbox:

```bash
ssh codex-demo 'mkdir -p ~/.codex && cat > ~/.codex/auth.json' < ~/.codex/auth.json
```

Treat `~/.codex/auth.json` like a password. It contains access tokens. Do not commit it, paste it into chat, or share it.

Your local Codex App may store credentials in the macOS keychain instead of `~/.codex/auth.json`; in that case this option may not be available unless you configure file-based credential storage and log in again.

### Option 3: Use a Codex access token

If your ChatGPT workspace supports Codex access tokens, pipe one into the remote login:

```bash
printenv CODEX_ACCESS_TOKEN | ssh codex-demo 'codex login --with-access-token'
```

This is useful for trusted automation that should use ChatGPT workspace access rather than an OpenAI API key.

## Repo Layout

```text
cs-codex-open
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
