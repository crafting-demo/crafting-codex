# Settings shared by every script in this repo, and the one place that knows
# what has to differ between Crafting sites, orgs, and people. Sourced, not run.
#
# Everything is resolved in the same order: an environment variable wins, then
# the answers saved in codex-cloud.conf, then something discovered from the
# `cs` CLI, then a default. Nothing about a particular org or site is baked in.

CX_ROOT="${CX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONF_FILE="${CODEX_CLOUD_CONF:-$CX_ROOT/codex-cloud.conf}"

# The repo a worker checks out when you have not named one of your own.
DEMO_REPO="https://github.com/crafting-test1/hello"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The cs CLI
# ---------------------------------------------------------------------------

if [ -z "${CS_BIN:-}" ]; then
  CS_BIN="$(command -v cs 2>/dev/null || echo /usr/local/bin/cs)"
fi

require_cs() {
  [ -x "$CS_BIN" ] || die "the cs CLI was not found (looked at $CS_BIN; set CS_BIN)"
  "$CS_BIN" info >/dev/null 2>&1 || die "cs is not logged in -- run 'cs login' first"
  # Without jq every cs query here comes back empty, which reads as a missing
  # org or sandbox rather than a missing tool.
  command -v jq >/dev/null 2>&1 || die "jq is not installed -- run 'brew install jq'"
}

# ---------------------------------------------------------------------------
# Where Crafting lives
# ---------------------------------------------------------------------------

org_names() {
  "$CS_BIN" org list -o json 2>/dev/null | jq -r '.[]?.meta.name // empty'
}

# With exactly one org there is nothing to ask; with several, the caller has to
# say, because guessing would put sandboxes in someone else's org.
discover_org() {
  local orgs count
  orgs="$(org_names)"
  count="$(printf '%s\n' "$orgs" | grep -c . || true)"
  if [ "$count" = 1 ]; then
    printf '%s' "$orgs"
    return 0
  fi
  return 1
}

# The site's own URL, and the DNS suffix its sandbox hostnames end in. Both
# come from the local CLI's configuration, so a self-hosted site needs no edits.
discover_server_url() {
  "$CS_BIN" config get server_url 2>/dev/null | tr -d '[:space:]'
}

suffix_from_url() {
  local host="${1#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  [ -n "$host" ] && printf '.%s' "$host"
}

# `cs login` writes the client keypair under ~/.crafting on macOS and
# ~/.config/crafting on Linux.
discover_identity() {
  local c
  for c in "$HOME/.crafting/sandbox/id_client" "$HOME/.config/crafting/sandbox/id_client"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# The org secret holding the key Codex logs in with on every sandbox. Named
# rather than guessed at render time so a site that calls it something else
# only has to say so once.
discover_openai_secret() {
  local names c
  names="$("$CS_BIN" -O "${CODEX_ROUTER_ORG:-}" secret list -o json 2>/dev/null \
           | jq -r '.[]?.meta.name // empty')"
  for c in openai-api-key openai-key OPENAI-API-KEY openai_api_key; do
    printf '%s\n' "$names" | grep -qx "$c" && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# Resolving and remembering the settings
# ---------------------------------------------------------------------------

# Read the saved answers without overwriting anything the environment or a
# command-line flag has already decided. Sourcing the file directly would give
# the saved answer the last word, which is backwards.
#
# CX_IGNORE_CONF lists keys the caller wants re-derived, so a stale saved value
# cannot survive a change it depends on.
load_conf() {
  [ -f "$CONF_FILE" ] || return 0
  local line key val
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    [ -n "${!key-}" ] && continue
    case " ${CX_IGNORE_CONF:-} " in *" $key "*) continue ;; esac
    eval "$key=$val"
  done < "$CONF_FILE"
  return 0
}

# `resolve_config soft` fills in what it can and leaves the rest empty instead
# of giving up, which is what a checker wants: it has to run before anything is
# set up, precisely to report that.
resolve_config() {
  local soft=0
  [ "${1:-}" = soft ] && soft=1

  load_conf

  CODEX_ROUTER_ORG="${CODEX_ROUTER_ORG:-}"
  if [ -z "$CODEX_ROUTER_ORG" ]; then
    CODEX_ROUTER_ORG="$(discover_org || true)"
    [ -n "$CODEX_ROUTER_ORG" ] || [ "$soft" = 1 ] \
      || die "more than one Crafting org -- pass --org NAME (yours: $(org_names | paste -sd, -))"
  fi

  CODEX_ROUTER_SERVER_URL="${CODEX_ROUTER_SERVER_URL:-$(discover_server_url)}"
  [ -n "$CODEX_ROUTER_SERVER_URL" ] || [ "$soft" = 1 ] \
    || die "could not read the Crafting server URL from cs"
  CODEX_ROUTER_DNS_SUFFIX="${CODEX_ROUTER_DNS_SUFFIX:-$(suffix_from_url "$CODEX_ROUTER_SERVER_URL")}"

  CODEX_ROUTER_SANDBOX="${CODEX_ROUTER_SANDBOX:-codex-router}"
  CODEX_ROUTER_WORKSPACE="${CODEX_ROUTER_WORKSPACE:-router}"
  CODEX_ROUTER_ROUTER_TEMPLATE="${CODEX_ROUTER_ROUTER_TEMPLATE:-codex-router}"
  CODEX_ROUTER_TEMPLATE="${CODEX_ROUTER_TEMPLATE:-codex-worker}"
  CODEX_ROUTER_WORKER_WORKSPACE="${CODEX_ROUTER_WORKER_WORKSPACE:-dev}"
  CODEX_ROUTER_POOL="${CODEX_ROUTER_POOL:-codex-worker-pool}"
  CODEX_ROUTER_POOL_MIN="${CODEX_ROUTER_POOL_MIN:-2}"
  CODEX_ROUTER_POOL_MAX="${CODEX_ROUTER_POOL_MAX:-6}"
  CODEX_ROUTER_PREFIX="${CODEX_ROUTER_PREFIX:-cx}"
  CODEX_ROUTER_SERVICE_ACCOUNT="${CODEX_ROUTER_SERVICE_ACCOUNT:-codex-router}"
  CODEX_ROUTER_TOKEN_SECRET="${CODEX_ROUTER_TOKEN_SECRET:-codex-router-token}"
  CODEX_ROUTER_WORKER_PORT="${CODEX_ROUTER_WORKER_PORT:-8383}"

  # Codex signs in on every sandbox, router and worker alike, so the key has to
  # be readable inside them.
  CODEX_OPENAI_SECRET="${CODEX_OPENAI_SECRET:-$(discover_openai_secret || true)}"

  # What the worker checks out, and where a thread starts. An empty repo is
  # allowed: the thread then starts in the worker's home directory.
  CODEX_WORKER_REPO="${CODEX_WORKER_REPO-$DEMO_REPO}"
  if [ -n "$CODEX_WORKER_REPO" ]; then
    local base="${CODEX_WORKER_REPO##*/}"
    CODEX_WORKER_CHECKOUT="${CODEX_WORKER_CHECKOUT:-${base%.git}}"
    CODEX_START_DIR="${CODEX_START_DIR:-/home/owner/$CODEX_WORKER_CHECKOUT}"
  else
    CODEX_WORKER_CHECKOUT="${CODEX_WORKER_CHECKOUT:-}"
    CODEX_START_DIR="${CODEX_START_DIR:-/home/owner}"
  fi

  # The worker template version this repo last wrote, so a later run can tell
  # whether the one in the org is still ours to regenerate.
  CODEX_WORKER_TEMPLATE_VERSION="${CODEX_WORKER_TEMPLATE_VERSION:-}"

  # Codex App connects to a concrete SSH alias, so this is the name that ends
  # up in ~/.ssh/config and in the app's Settings -> Connections -> SSH list.
  CODEX_ALIAS="${CODEX_ALIAS:-codex-cloud}"

  CODEX_IDENTITY="${CODEX_IDENTITY:-$(discover_identity || true)}"
}

CONF_KEYS="
CODEX_ROUTER_ORG
CODEX_ROUTER_SERVER_URL
CODEX_ROUTER_DNS_SUFFIX
CODEX_ROUTER_SANDBOX
CODEX_ROUTER_WORKSPACE
CODEX_ROUTER_ROUTER_TEMPLATE
CODEX_ROUTER_TEMPLATE
CODEX_ROUTER_WORKER_WORKSPACE
CODEX_ROUTER_POOL
CODEX_ROUTER_POOL_MIN
CODEX_ROUTER_POOL_MAX
CODEX_ROUTER_PREFIX
CODEX_ROUTER_SERVICE_ACCOUNT
CODEX_ROUTER_TOKEN_SECRET
CODEX_ROUTER_WORKER_PORT
CODEX_OPENAI_SECRET
CODEX_WORKER_REPO
CODEX_WORKER_CHECKOUT
CODEX_WORKER_TEMPLATE_VERSION
CODEX_START_DIR
CODEX_ALIAS
"

save_conf() {
  local k v
  {
    echo "# Written by setup.sh. Every value can be overridden by the same name"
    echo "# in the environment. Delete this file to start the questions over."
    for k in $CONF_KEYS; do
      v="${!k-}"
      printf '%s=%q\n' "$k" "$v"
    done
  } > "$CONF_FILE"
}

print_config() {
  local k
  for k in $CONF_KEYS; do
    printf '  %-32s %s\n' "$k" "${!k-}"
  done
}
