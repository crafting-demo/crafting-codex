---
name: crafting-sandbox
description: "Use when Codex needs to work with Crafting sandboxes through the `cs` CLI: list or inspect templates, create/resume/show sandboxes, execute commands in sandbox workloads, SSH into workloads, or connect a Crafting sandbox as a local Codex App SSH remote environment for new Codex threads."
---

# Crafting Sandbox

Use the Crafting `cs` CLI to create and manage sandbox workspaces, then connect ready sandboxes to the local Codex App through SSH when the user wants Codex to operate inside that sandbox.

Official docs live at https://docs.sandboxes.cloud/. When CLI behavior, sandbox definition schema, template semantics, secrets, SSH access, remote exec, or lifecycle behavior is uncertain or likely current, check those docs before guessing.

## Core Workflow

1. Confirm `cs` is installed and authenticated:

   ```bash
   cs login --status || cs login --if-needed
   ```

   If `cs` says no organization is selected, use `cs org list` and add `-O ORG` to commands. Folder scopes are uncommon on most Crafting sites; only use `--folder FOLDER` when names like `lab/foo` fail without it or the site requires folder-scoped addressing.

2. Inspect available templates:

   ```bash
   cs template list
   cs template show TEMPLATE
   cs template show TEMPLATE --def
   ```

   When choosing a template from a user phrase such as "front-end template", search template names/descriptions. If exactly one plausible match exists, pick it. If multiple plausible matches exist, ask the user to choose. If none are clear, show the closest options and ask.

3. Create a sandbox:

   ```bash
   cs sb create SANDBOX_NAME -t TEMPLATE --wait
   ```

   For a direct definition instead of a template:

   ```bash
   cs sb create SANDBOX_NAME --from def:path/to/definition.yaml --wait
   ```

   Useful options:

   ```bash
   --if-exists skip
   --access private
   --access shared
   -E KEY=VALUE
   -D 'WORKLOAD/env[KEY]=VALUE'
   -D 'WORKLOAD/checkout[PATH].repo=github:org/repo'
   ```

4. Inspect sandbox state and addresses:

   ```bash
   cs sb list
   cs sb show SANDBOX_NAME
   cs sb show SANDBOX_NAME --def
   cs wait sandbox SANDBOX_NAME
   ```

5. Execute commands in a workload:

   ```bash
   cs exec -W SANDBOX_NAME/app -- pwd
   cs exec -W SANDBOX_NAME/app -w /home/owner -- ls -la
   cs ssh -W SANDBOX_NAME/app -- 'command -v node || true'
   ```

   Prefer `cs exec` for simple noninteractive commands. Use `cs ssh` when you need behavior that matches the login shell or when testing the same SSH route the Codex App will use.

6. Connect the sandbox to the local Codex App when requested:

   ```bash
   scripts/setup-crafting-codex-remote.sh SANDBOX_NAME [SSH_ALIAS]
   ```

   If this repo is installed as a Crafting CLI extension, and the sandbox
   already exists, prefer the friendlier wrapper:

   ```bash
   cs codex SANDBOX_NAME/WORKLOAD [SSH_ALIAS]
   cs codex SANDBOX_NAME/WORKLOAD --install-codex
   ```

   If the org must be explicit:

   ```bash
   CODEX_CRAFTING_ORG=eng scripts/setup-crafting-codex-remote.sh lab/codex-demo codex-demo
   CODEX_CRAFTING_ORG=eng cs codex lab/codex-demo --workload app --alias codex-demo
   ```

   The script creates or updates a concrete `~/.ssh/config` host alias, verifies SSH, verifies or offers to install the remote Codex CLI, logs in from remote auth sources, and runs `codex doctor`.
   Pass `--install-codex` when a fresh workspace does not already have remote `codex` on `PATH`.
   The `cs codex` wrapper then opens Codex Desktop with `codex app`.

## Remote Codex Auth

The setup script checks, in order:

1. Remote `OPENAI_API_KEY`
2. Remote `CODEX_ACCESS_TOKEN`
3. Mounted Crafting secret files:

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

If auth is not found, run device auth manually:

```bash
ssh SSH_ALIAS
codex login --device-auth
```

## Opening A New Codex Thread On A Sandbox

When the user asks for a new Codex thread or local Codex App remote environment:

1. Create or identify the sandbox.
2. Run `cs codex SANDBOX_NAME/WORKLOAD [SSH_ALIAS]` if the extension is installed, or run the remote setup script directly.
3. Tell the user the SSH alias and suggested remote project folder, usually `/home/owner`.
4. Tell the user to open **Codex App -> Settings -> Connections -> SSH**. If the alias is already visible, enable it and choose the remote project folder.
5. If the alias is not visible, tell the user to add it manually:

   ```text
   Settings -> Connections -> SSH -> Add
   Display name: SSH_ALIAS
   Target mode: Alias
   Alias: SSH_ALIAS
   Auth mode: No Auth
   ```

   Then enable the connection and choose the remote project folder.

The script can automate SSH config and remote readiness. The Codex App UI currently owns the final connection registration, enable, and project-folder selection actions. Do not claim the sandbox is visible in the Codex UI unless it has been manually verified.

## References

For detailed command examples and troubleshooting, read `references/cs-cli.md`.
