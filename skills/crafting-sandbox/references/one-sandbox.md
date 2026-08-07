# The One-Sandbox Setup (legacy)

This is the older flow, from before the per-thread router: one Crafting sandbox
is wired to Codex App as an SSH remote, and every thread runs in it.

**This is not how to answer "create a new Crafting sandbox."** That means a new
thread in the Crafting Sandbox workspace on the codex-cloud connection, as the
skill says. Read this only when the user explicitly asks about the
single-sandbox setup or the remote setup script.

Everything here runs on the user's Mac. It cannot be done from inside a
sandbox: it edits `~/.ssh/config` and drives Codex App.

## Set up a sandbox as a Codex remote

1. Confirm `cs` is authenticated:

   ```bash
   cs login --status || cs login --if-needed
   ```

   With no org selected, use `cs org list` and add `-O ORG`. Only use
   `--folder FOLDER` when folder-scoped names fail without it.

2. Pick a template:

   ```bash
   cs template list
   cs template show TEMPLATE --def
   ```

   For a phrase like "front-end template", search names and descriptions. One
   plausible match, use it; several, ask; none, show the closest and ask.

3. Create the sandbox:

   ```bash
   cs sb create SANDBOX_NAME -t TEMPLATE --wait
   cs sb create SANDBOX_NAME --from def:path/to/definition.yaml --wait
   ```

   Options that come up: `--if-exists skip`, `--access private|shared`,
   `-E KEY=VALUE`, `-D 'WORKLOAD/env[KEY]=VALUE'`,
   `-D 'WORKLOAD/checkout[PATH].repo=github:org/repo'`.

4. Wire it to Codex App:

   ```bash
   scripts/setup-crafting-codex-remote.sh SANDBOX_NAME [SSH_ALIAS]
   ```

   With an explicit org:

   ```bash
   CODEX_CRAFTING_ORG=ORG scripts/setup-crafting-codex-remote.sh FOLDER/SANDBOX SSH_ALIAS
   ```

   The script writes a concrete `~/.ssh/config` host alias, verifies SSH,
   installs the remote Codex CLI if it is missing, signs it in from remote auth
   sources, and runs `codex doctor`. It cannot add or enable the connection in
   Codex App settings.

5. Tell the user to finish it by hand, and do not claim the sandbox is
   connected until they confirm:

   ```text
   Settings -> Connections -> SSH -> Add
     Display name: SSH_ALIAS
     Target mode:  Alias
     Alias:        SSH_ALIAS
     Auth mode:    No Auth
   ```

   Then enable it and choose the remote project folder the setup printed.

## What a working SSH alias looks like

Codex App only discovers concrete aliases in `~/.ssh/config`; a pattern-only
Crafting host entry is not enough.

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

Verify it:

```bash
ssh SSH_ALIAS -- 'whoami; hostname; command -v codex; codex --version'
ssh SSH_ALIAS -- 'codex doctor --summary --ascii'
```

The setup script reads these:

```bash
CODEX_CRAFTING_ORG=eng
CODEX_CRAFTING_WORKLOAD=WORKLOAD
CODEX_CRAFTING_REMOTE_USER=owner
CODEX_CRAFTING_PROJECT_DIR=REMOTE_PROJECT_DIR
CODEX_CRAFTING_SECRET_PATH=/run/sandbox/fs/secrets/shared/shared/openai-key
CODEX_CRAFTING_SKIP_LOGIN=1
```

It may prompt to install Node.js, npm, and `@openai/codex` when remote `codex`
is not on PATH.

## Remote Codex auth

The setup script looks, in order, at remote `OPENAI_API_KEY`, remote
`CODEX_ACCESS_TOKEN`, then mounted Crafting secret files:

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

If none are found:

```bash
ssh SSH_ALIAS
codex login --device-auth
```

## The per-thread router instead

The router gives each thread its own sandbox behind a single SSH alias, which
is what the skill's One Rule relies on. From a checkout of this repo:

```bash
./bootstrap.sh   # templates, worker pool, service account, router sandbox
./install.sh     # the ~/.ssh/config entry and the skills and slash commands
./doctor.sh      # check all of it
```

`bootstrap.sh` needs org admin rights once, for the service account the router
claims workers as, and an org secret named `openai-api-key`. Codex App
registration is the same manual step as above, with the alias `codex-cloud`.

To answer questions about it afterwards:

```bash
./doctor.sh                                            # every piece, with fixes
ssh codex-cloud '~/.codex-router/bin/codexctl threads' # thread -> sandbox
ssh codex-cloud '~/.codex-router/bin/codexctl status'
```

Two limits worth stating plainly: calls that carry no thread id, such as the
file pane and the terminal, follow the last thread the connection touched; and
a thread that predates the router runs on the router's own app-server rather
than in a sandbox that would not have its history.

If the routing itself is broken, `codexctl mode local` turns it off and the
router behaves as an ordinary single sandbox.
