#!/usr/bin/env bash
#
# Configure this machine so Codex App can connect to the router, and every
# thread lands in its own Crafting sandbox.
#
# Writes one thing: the `Host codex-cloud` stanza in ~/.ssh/config.
#
# Codex App only accepts concrete SSH aliases -- there is no wildcard and no
# settings file we can write the connection into -- so enabling it under
# Settings -> Connections -> SSH stays a one-time manual step. Everything after
# that is automatic.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib/config.sh"

require_cs
resolve_config

ORG="$CODEX_ROUTER_ORG"
ROUTER_SANDBOX="$CODEX_ROUTER_SANDBOX"
ROUTER_WORKSPACE="$CODEX_ROUTER_WORKSPACE"
ALIAS="$CODEX_ALIAS"
START_DIR="$CODEX_START_DIR"

SSH_CONFIG="$HOME/.ssh/config"
IDENTITY="$CODEX_IDENTITY"
[ -n "$IDENTITY" ] && [ -f "$IDENTITY" ] \
  || die "no Crafting client key found -- run 'cs login' first"
KNOWN_HOSTS="$(dirname "$IDENTITY")/known_hosts"
[ -e "$KNOWN_HOSTS" ] || KNOWN_HOSTS="$HOME/.ssh/known_hosts"

BEGIN_MARK="# >>> codex-cloud >>>"
END_MARK="# <<< codex-cloud <<<"

# ---------------------------------------------------------------------------
# Check the router is there
# ---------------------------------------------------------------------------

say "Checking the router sandbox"
state="$("$CS_BIN" -O "$ORG" sandbox show "$ROUTER_SANDBOX" -o json 2>/dev/null | jq -r '
  if (.spec.op_state.state // "") == "SUSPENDED" then "SUSPENDED"
  else (.status.workloads[0].agent.overview.state
        // .status.workloads[0].status.state
        // "UNKNOWN") end')"
[ -n "$state" ] || die "sandbox '$ROUTER_SANDBOX' not found in org '$ORG' -- run ./bootstrap.sh first"
case "$state" in
  READY|RUNNING) ;;
  *) warn "the router sandbox is in state $state; it should be READY" ;;
esac

ROUTER_HOST="$ROUTER_WORKSPACE--$ROUTER_SANDBOX-$ORG$CODEX_ROUTER_DNS_SUFFIX"
say "Router host: $ROUTER_HOST"

# ---------------------------------------------------------------------------
# ~/.ssh/config
# ---------------------------------------------------------------------------

say "Updating $SSH_CONFIG"
mkdir -p "$HOME/.ssh"
touch "$SSH_CONFIG"
cp "$SSH_CONFIG" "$SSH_CONFIG.codex-cloud.bak"

strip_block() {
  local begin="$1" end="$2" src="$3"
  awk -v b="$begin" -v e="$end" '
    $0 == b { skip = 1 }
    !skip   { print }
    $0 == e { skip = 0 }
  ' "$src"
}

strip_block "$BEGIN_MARK" "$END_MARK" "$SSH_CONFIG.codex-cloud.bak" > "$SSH_CONFIG.tmp"

# An alias the older single-sandbox setup wrote under its own markers would
# shadow this one, since ssh takes the first match for a host.
if grep -q "^# >>> codex-crafting-remote $ALIAS\$" "$SSH_CONFIG.tmp" 2>/dev/null; then
  warn "removing the older 'codex-crafting-remote $ALIAS' block, which would shadow this one"
  strip_block "# >>> codex-crafting-remote $ALIAS" "# <<< codex-crafting-remote $ALIAS" \
    "$SSH_CONFIG.tmp" > "$SSH_CONFIG.tmp2"
  mv "$SSH_CONFIG.tmp2" "$SSH_CONFIG.tmp"
fi

# Trim trailing blank lines so repeated installs do not accumulate them.
awk 'BEGIN{n=0} {lines[NR]=$0} END{for(i=NR;i>0&&lines[i]=="";i--) n++; for(i=1;i<=NR-n;i++) print lines[i]}' \
  "$SSH_CONFIG.tmp" > "$SSH_CONFIG.tmp2" && mv "$SSH_CONFIG.tmp2" "$SSH_CONFIG.tmp"

cat >> "$SSH_CONFIG.tmp" <<EOF

$BEGIN_MARK
# Managed by crafting-codex/install.sh. Do not edit between these markers.
#
# The pinned router sandbox, reached through Crafting's SSH gateway. This is
# the host Codex App connects to; it runs no threads of its own. The shim on
# its PATH takes over the app-server the app starts here, and the demux behind
# it hands each thread its own worker sandbox.
Host $ALIAS
  HostName $ROUTER_HOST
  Port 22
  User owner
  ProxyCommand $CS_BIN ssh-proxy %h:443
  IdentityFile $IDENTITY
  IdentitiesOnly yes
  UserKnownHostsFile $KNOWN_HOSTS
  StrictHostKeyChecking accept-new
  HashKnownHosts no
  ServerAliveInterval 30
  ServerAliveCountMax 10
$END_MARK
EOF

mv "$SSH_CONFIG.tmp" "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# ---------------------------------------------------------------------------
# Slash commands
#
# Codex reads custom prompts from $CODEX_HOME/prompts, one file per command.
# These run against the local checkout and the human's cs login, which is why
# they are installed here and not baked into the sandboxes.
# ---------------------------------------------------------------------------

# prompts/local needs this checkout and a human's cs login, so it is installed
# here only. prompts/anywhere also works inside a sandbox, and build-template.py
# bakes those same files into the router and worker templates.
PROMPTS_DIR="${CODEX_HOME:-$HOME/.codex}/prompts"
say "Installing slash commands into $PROMPTS_DIR"
mkdir -p "$PROMPTS_DIR"
for f in "$ROOT/prompts/local/"*.md "$ROOT/prompts/anywhere/"*.md; do
  [ -f "$f" ] || continue
  cp -f "$f" "$PROMPTS_DIR/"
  echo "  /$(basename "$f" .md)"
done

# The skills those commands lean on, so a local Codex can read them without a
# checkout of this repo in front of it.
SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"
say "Installing skills into $SKILLS_DIR"
mkdir -p "$SKILLS_DIR"
for s in codex-worker-templates crafting-sandbox; do
  [ -d "$ROOT/skills/$s" ] || continue
  rm -rf "${SKILLS_DIR:?}/$s"
  cp -R "$ROOT/skills/$s" "$SKILLS_DIR/"
  echo "  $s"
done

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

say "Verifying the route"
if out="$(ssh -o BatchMode=yes -o ConnectTimeout=30 "$ALIAS" 'echo ROUTER_OK; command -v codex' 2>&1)"; then
  case "$out" in
    *ROUTER_OK*) say "Connected to the router." ;;
    *) warn "unexpected response: $out" ;;
  esac
else
  warn "could not reach the router: $out"
fi

cat <<EOF

Done. In Codex App:

  Settings -> Connections -> SSH -> Add
    Display name: $ALIAS
    Target mode:  Alias
    Alias:        $ALIAS
    Auth mode:    No Auth

  Then enable it and choose the remote project folder: $START_DIR

Codex App reads ~/.ssh/config at launch, so restart it first if it is running.
Each new thread claims its own sandbox from the '$CODEX_ROUTER_POOL' pool;
'./doctor.sh' shows which thread is on which.

In a local Codex session, /codexify makes one of your templates codex-ready,
and /cr-set-template points the router at it.

In any session, local or in a thread's sandbox: /cs-task hands work to a
Crafting LLM task, /cs-status checks on it, /cs-sandbox says which sandbox you
are in, and /cs-templates lists what you can build from.
EOF
