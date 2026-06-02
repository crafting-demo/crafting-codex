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

```bash
cs sb list
cs sb show SANDBOX
cs sb show SANDBOX --def
cs sb create SANDBOX -t TEMPLATE --wait
cs sb create SANDBOX --from def:definition.yaml --wait
cs sb create SANDBOX --from scratch
cs sb resume SANDBOX --wait
cs sb suspend SANDBOX
cs wait sandbox SANDBOX
```

Common create options:

```bash
--if-exists skip
--access shared
--access private
--access collaborated:users=user@example.com
-E KEY=VALUE
-D 'app/env[KEY]=VALUE'
-D 'app/checkout[src].repo=github:org/repo'
-D 'app/checkout[src].version=main'
```

Minimal direct definition with one workspace:

```yaml
workspaces:
  - name: app
```

## Commands In Workloads

```bash
cs exec -W SANDBOX/WORKLOAD -- pwd
cs exec -W SANDBOX/WORKLOAD -w REMOTE_PROJECT_DIR -- ls -la
cs exec -W SANDBOX/WORKLOAD -e FOO=bar -- printenv FOO
cs ssh -W SANDBOX/WORKLOAD -- 'whoami; hostname; pwd'
```

Use `cs exec` for deterministic noninteractive command execution. Use `cs ssh` when checking login-shell PATH or testing the same path OpenSSH/Codex App will use.

## OpenSSH And Codex App

Codex App discovers concrete aliases from `~/.ssh/config`; pattern-only Crafting host entries are not enough. A working alias looks like:

```sshconfig
Host SSH_ALIAS
  HostName WORKLOAD_SSH_HOST
  Port 22
  User owner
  ProxyCommand ~/.crafting/sandbox/cli/current/bin/cs ssh-proxy %h:443
  UserKnownHostsFile ~/.crafting/sandbox/known_hosts
  StrictHostKeyChecking yes
  HashKnownHosts no
  IdentityFile ~/.crafting/sandbox/id_client
```

Verify:

```bash
ssh SSH_ALIAS -- 'whoami; hostname; command -v codex; codex --version'
ssh SSH_ALIAS -- 'codex doctor --summary --ascii'
```

## Remote Setup Script

Run from the Mac where Codex App is installed:

```bash
skills/crafting-sandbox/scripts/setup-crafting-codex-remote.sh SANDBOX_NAME [SSH_ALIAS]
```

Useful environment variables:

```bash
CODEX_CRAFTING_ORG=eng
CODEX_CRAFTING_WORKLOAD=WORKLOAD
CODEX_CRAFTING_REMOTE_USER=owner
CODEX_CRAFTING_PROJECT_DIR=REMOTE_PROJECT_DIR
CODEX_CRAFTING_SECRET_PATH=/run/sandbox/fs/secrets/shared/shared/openai-key
CODEX_CRAFTING_SKIP_LOGIN=1
```

The script may prompt to install Node.js, npm, and `@openai/codex` if remote `codex` is not on PATH.
