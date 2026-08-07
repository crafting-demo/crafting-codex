#!/usr/bin/env bash
#
# Create the Crafting side: the worker template and its pool, the service
# account the router authenticates as, and the pinned router sandbox.
#
#   ./bootstrap.sh              create or update everything
#   ./bootstrap.sh --recreate   delete and rebuild the router sandbox
#   ./bootstrap.sh --destroy    delete the router sandbox and all workers
#   ./bootstrap.sh --destroy-all  also delete the templates, pool, secret, and
#                                 service account, leaving the org as it was
#
# Idempotent: run it again after changing codex-cloud.conf or anything under
# router/.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib/config.sh"

require_cs
resolve_config
# build-template.py reads the conf file rather than this shell, so the answers
# have to be on disk before it runs.
save_conf

ORG="$CODEX_ROUTER_ORG"
ROUTER_SANDBOX="$CODEX_ROUTER_SANDBOX"
ROUTER_TEMPLATE="$CODEX_ROUTER_ROUTER_TEMPLATE"
WORKER_TEMPLATE="$CODEX_ROUTER_TEMPLATE"
WORKER_POOL="$CODEX_ROUTER_POOL"
SERVICE_ACCOUNT="$CODEX_ROUTER_SERVICE_ACCOUNT"
TOKEN_SECRET="$CODEX_ROUTER_TOKEN_SECRET"
PREFIX="$CODEX_ROUTER_PREFIX"

cs() { "$CS_BIN" -O "$ORG" "$@"; }

sandbox_exists()  { cs sandbox show "$1" -o json >/dev/null 2>&1; }
template_exists() { cs template show "$1" -o json >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

# `cs sandbox remove` waits for a sandbox to settle before deleting it, so one
# stuck mid-create blocks every removal queued behind it -- and a teardown that
# appears to hang is worse than one that says what it left running. These go out
# at once, and waiting stops after a while: the deletions are server-side and
# finish without us.
REMOVE_TIMEOUT="${CODEX_ROUTER_REMOVE_TIMEOUT:-120}"

remove_sandboxes() {
  [ $# -gt 0 ] || return 0
  local n pids="" pid left deadline
  for n in "$@"; do
    echo "  removing $n"
    cs sandbox remove "$n" -f --skip-non-exist >/dev/null 2>&1 &
    pids="$pids $!"
  done
  deadline=$(( $(date +%s) + REMOVE_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    left=""
    for pid in $pids; do
      kill -0 "$pid" 2>/dev/null && left="$left $pid"
    done
    [ -n "$left" ] || return 0
    sleep 2
  done
  warn "some sandboxes were still deleting after ${REMOVE_TIMEOUT}s.
  Crafting finishes those on its own; one wedged in CREATING is the usual cause.
  'cs -O $ORG sandbox list' will show whether any survived."
}

if [ "${1:-}" = "--destroy" ] || [ "${1:-}" = "--destroy-all" ]; then
  say "Deleting worker sandboxes"
  # shellcheck disable=SC2046
  remove_sandboxes $(cs sandbox list -o json 2>/dev/null \
    | jq -r ".[]? | select(.meta.name | startswith(\"$PREFIX-\")) | .meta.name")
  say "Deleting the router sandbox"
  remove_sandboxes "$ROUTER_SANDBOX"

  if [ "${1:-}" = "--destroy" ]; then
    say "Done. The templates, pool, and service account were left in place."
    exit 0
  fi

  # The conf names one worker template and pool, but /cr-set-template can point
  # it at a template of yours, which orphans the pair this repo made under their
  # default names. Both sets go, or a reinstall inherits the leftovers.
  say "Deleting the worker pools"
  for p in "$WORKER_POOL" codex-worker-pool; do
    [ -n "$p" ] || continue
    # The pool holds instances built from the worker template, so it has to go
    # before the template it is built from.
    cs sandbox pool remove "$p" -f >/dev/null 2>&1 && echo "  $p" || true
  done
  say "Deleting the templates"
  for t in "$WORKER_TEMPLATE" codex-worker "$ROUTER_TEMPLATE"; do
    [ -n "$t" ] || continue
    cs template remove "$t" -f >/dev/null 2>&1 && echo "  $t" || true
  done
  say "Deleting the login token secret and the service account"
  cs secret remove "$TOKEN_SECRET" -f >/dev/null 2>&1 || true
  cs org service-account delete "$SERVICE_ACCOUNT" >/dev/null 2>&1 \
    || warn "could not delete the service account $SERVICE_ACCOUNT (needs org admin rights)"
  # Nothing this repo created is left, so a saved template version would be a
  # lie the next run would act on.
  CODEX_WORKER_TEMPLATE_VERSION=""
  save_conf
  say "Done. Nothing this repo created is left in org '$ORG'."
  exit 0
fi

# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------

[ -n "$CODEX_OPENAI_SECRET" ] || warn "no OpenAI API key secret found in org '$ORG';
  sandboxes will come up unauthenticated. Create one and re-run:
    cs -O $ORG secret create openai-api-key --shared -f -"

say "Generating templates for org '$ORG' at $CODEX_ROUTER_SERVER_URL"
python3 "$ROOT/build-template.py"

template_version() {
  cs template show "$1" -o json 2>/dev/null | jq -r '.meta.version // empty'
}

# `protect` is for the worker template: it is meant to be customized with the
# services and dependencies a team needs, so regenerating it over their edits
# would be destructive. Crafting bumps the version on every edit and strips
# comments from the stored definition, so the version we last wrote is the only
# reliable way to tell our own output from someone's changes.
apply_template() {
  local name="$1" file="$2" description="$3" protect="${4:-0}" live
  cs template validate "$file" >/dev/null
  if template_exists "$name"; then
    live="$(template_version "$name")"
    if [ "$protect" = 1 ] && [ -n "$CODEX_WORKER_TEMPLATE_VERSION" ] \
       && [ "$live" != "$CODEX_WORKER_TEMPLATE_VERSION" ]; then
      warn "template $name has been edited since setup last wrote it; leaving it as it is"
      warn "  (to pick up a repo change, edit its checkout in the Crafting UI)"
      return 0
    fi
    say "Updating template $name"
    cs template update "$name" "$file" | tail -1
  else
    say "Creating template $name"
    cs template create "$name" "$file" --description "$description" | tail -1
  fi
  if [ "$protect" = 1 ]; then
    CODEX_WORKER_TEMPLATE_VERSION="$(template_version "$name")"
    save_conf
  fi
}

apply_template "$WORKER_TEMPLATE" "$ROOT/templates/codex-worker.yaml" \
  "Codex worker sandbox (pool-backed)" 1
apply_template "$ROUTER_TEMPLATE" "$ROOT/templates/codex-router.yaml" \
  "Codex app-server router: gives each thread its own worker sandbox"

# ---------------------------------------------------------------------------
# The identity the router runs as
#
# `cs` inside a sandbox is only authenticated when a human forwards their
# session socket, and the router has to claim workers unattended. So it logs in
# as a service account using a non-expiring LoginToken, kept as an org secret
# that the template renders into the sandbox at startup.
# ---------------------------------------------------------------------------

ensure_service_account() {
  if cs org service-account list -o json 2>/dev/null \
     | jq -e --arg sa "$SERVICE_ACCOUNT@" '.[]? | select(.email | startswith($sa))' >/dev/null; then
    say "Service account $SERVICE_ACCOUNT@org.sandbox already exists"
    return 0
  fi
  say "Creating the service account $SERVICE_ACCOUNT@org.sandbox"
  cs org service-account create "$SERVICE_ACCOUNT" --display-name "Codex Router" >/dev/null \
    || die "could not create the service account -- this step needs org admin rights.
  Ask an admin to run:
    cs -O $ORG org service-account create $SERVICE_ACCOUNT --display-name 'Codex Router'"
}

ensure_token_secret() {
  if cs secret show "$TOKEN_SECRET" -o json >/dev/null 2>&1; then
    say "Login token secret $TOKEN_SECRET already exists"
    return 0
  fi
  say "Minting a non-expiring login token and storing it as the secret $TOKEN_SECRET"
  local token
  token="$(cs org login-token create "$SERVICE_ACCOUNT" -E Never 2>/dev/null \
           | tr -d '[:space:]')"
  case "$token" in
    "" | *[!A-Za-z0-9+/=]*) die "unexpected login token output -- create it by hand:
    cs -O $ORG org login-token create $SERVICE_ACCOUNT -E Never
    printf '%s' '<token>' | cs -O $ORG secret create $TOKEN_SECRET --shared -f -" ;;
  esac
  # Shared, because the template renders it for a sandbox the service account
  # owns rather than for the person who ran this script.
  printf '%s' "$token" | cs secret create "$TOKEN_SECRET" --shared -f - | tail -1
}

ensure_service_account
ensure_token_secret

# ---------------------------------------------------------------------------
# The router sandbox
# ---------------------------------------------------------------------------

if [ "${1:-}" = "--recreate" ] && sandbox_exists "$ROUTER_SANDBOX"; then
  say "Removing the existing router sandbox"
  cs sandbox remove "$ROUTER_SANDBOX" -f --skip-non-exist >/dev/null 2>&1 || true
  sleep 5
fi

if sandbox_exists "$ROUTER_SANDBOX"; then
  say "Router sandbox already exists"
else
  say "Creating the router sandbox (a few minutes: it installs the Codex CLI)"
  cs sandbox create "$ROUTER_SANDBOX" -t "$ROUTER_TEMPLATE" >/dev/null
fi

# Codex App reconnects to a concrete host and expects it to answer. A router
# that Crafting suspended while nobody was using it would look like a broken
# environment rather than an idle one.
say "Pinning the router sandbox so it is never auto-suspended"
cs sandbox pin "$ROUTER_SANDBOX" | tail -1

# ---------------------------------------------------------------------------
# The worker pool
#
# This is what makes a new thread instant: workers are pre-warmed with the
# Codex CLI already installed and signed in, so claiming one takes about a
# second instead of a full sandbox build inside the thread/start the app is
# waiting on.
# ---------------------------------------------------------------------------

say "Configuring the worker pool $WORKER_POOL"
if cs sandbox pool show "$WORKER_POOL" -o json >/dev/null 2>&1; then
  cs sandbox pool update "$WORKER_POOL" \
    "min=$CODEX_ROUTER_POOL_MIN" "max=$CODEX_ROUTER_POOL_MAX" | tail -1
else
  # create takes flags where update takes PARAM=VALUE arguments; passing
  # update's form here is silently ignored and leaves the pool at min=1.
  cs sandbox pool create "$WORKER_POOL" -t "$WORKER_TEMPLATE" \
    --min "$CODEX_ROUTER_POOL_MIN" --max "$CODEX_ROUTER_POOL_MAX" | tail -1
fi
cs sandbox pool enable "$WORKER_POOL" | tail -1

# ---------------------------------------------------------------------------
# Wait for the router to be ready to shim
# ---------------------------------------------------------------------------

say "Waiting for the router's Codex CLI and shim"
shimmed=0
for _ in $(seq 1 60); do
  if cs ssh -W "$ROUTER_SANDBOX/$CODEX_ROUTER_WORKSPACE" -- \
       'head -c 200 ~/.local/bin/codex 2>/dev/null | grep -q "codex-router shim"' >/dev/null 2>&1; then
    shimmed=1
    break
  fi
  sleep 5
done
[ "$shimmed" = 1 ] || warn "the shim is not installed yet; check 'codexctl status' on the router"

say "Router status"
cs ssh -W "$ROUTER_SANDBOX/$CODEX_ROUTER_WORKSPACE" -- \
  '~/.codex-router/bin/codexctl status' || true

echo
say "Crafting side is ready. Run ./install.sh to wire up this machine."
