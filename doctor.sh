#!/usr/bin/env bash
#
# Check that every piece is in place, and say what to do about the ones that
# are not.
#
#   ./doctor.sh          check everything
#   ./doctor.sh --log    tail the router's routing log
#   ./doctor.sh --watch  follow it live while you drive Codex App
#   ./doctor.sh --probe  drive the router the way Codex App does
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib/config.sh"

# Soft, because this has to work before anything exists -- that is the point.
resolve_config soft
ORG="${CODEX_ROUTER_ORG:-}"
TARGET="${CODEX_ROUTER_SANDBOX:-codex-router}/${CODEX_ROUTER_WORKSPACE:-router}"
ALIAS="${CODEX_ALIAS:-codex-cloud}"

cs() { "$CS_BIN" -O "$ORG" "$@"; }
on_router() { cs ssh -W "$TARGET" -- "$1" 2>&1; }

case "${1:-check}" in
  --log)   on_router 'tail -n 60 ~/.codex-router/log/demux.log'; exit 0 ;;
  --watch)
    echo "Following the router. Start a thread in Codex App. Ctrl-C to stop."
    cs ssh -W "$TARGET" -- 'tail -f -n 20 ~/.codex-router/log/demux.log'
    exit 0 ;;
  --probe) exec "$ROOT/bin/probe-router" --alias "$ALIAS" ;;
  -h|--help)
    sed -n '3,9p' "${BASH_SOURCE[0]}" | cut -c 3-
    exit 0 ;;
  check) ;;
  *) echo "doctor.sh: no such option $1" >&2
     sed -n '6,9p' "${BASH_SOURCE[0]}" | cut -c 3- >&2
     exit 2 ;;
esac

fail=0
ok()   { printf '  \033[1;32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; fail=1; }
note() { printf '  \033[1;33mnote\033[0m  %s\n' "$*"; }
hint() { printf '        %s\n' "$*"; }

echo "Local"
if [ -x "$CS_BIN" ]; then ok "cs CLI at $CS_BIN"; else
  bad "no cs CLI"; hint "install it from your Crafting site, or set CS_BIN"
fi
if "$CS_BIN" info >/dev/null 2>&1; then ok "cs is logged in to $CODEX_ROUTER_SERVER_URL"; else
  bad "cs is not logged in"; hint "run: cs login"
fi
if command -v jq >/dev/null 2>&1; then ok "jq is installed"; else
  bad "jq is missing"; hint "run: brew install jq   (or your package manager)"
fi
if [ -f "$CONF_FILE" ]; then ok "answers saved in $(basename "$CONF_FILE") (org $ORG)"; else
  bad "no saved answers"; hint "run: ./bootstrap.sh"
fi
if grep -q "^Host $ALIAS\$" "$HOME/.ssh/config" 2>/dev/null; then
  ok "ssh config has the '$ALIAS' host"
else
  bad "ssh config has no '$ALIAS' host"; hint "run: ./install.sh"
fi
if [ -n "${CODEX_OPENAI_SECRET:-}" ]; then
  ok "OpenAI key secret: $CODEX_OPENAI_SECRET"
else
  bad "no OpenAI API key secret in org '$ORG'"
  hint "sandboxes come up unauthenticated without it; create one with:"
  hint "  cs -O $ORG secret create openai-api-key --shared -f -"
fi

echo
echo "Crafting"
state="$(cs sandbox show "${CODEX_ROUTER_SANDBOX:-codex-router}" -o json 2>/dev/null | jq -r '
  if (.spec.op_state.state // "") == "SUSPENDED" then "SUSPENDED"
  else (.status.workloads[0].agent.overview.state
        // .status.workloads[0].status.state
        // "UNKNOWN") end')"
case "$state" in
  READY|RUNNING) ok "router sandbox ${CODEX_ROUTER_SANDBOX:-codex-router} is $state" ;;
  "")  bad "router sandbox ${CODEX_ROUTER_SANDBOX:-codex-router} does not exist"
       hint "run: ./bootstrap.sh" ;;
  *)   bad "router sandbox is $state -- it should be READY"
       hint "run: cs -O $ORG sandbox resume ${CODEX_ROUTER_SANDBOX:-codex-router}" ;;
esac
# Pinning shows up as the sandbox's operational state, not as a flag of its own.
if cs sandbox show "${CODEX_ROUTER_SANDBOX:-codex-router}" -o json 2>/dev/null \
   | jq -e '(.spec.op_state.state // "") == "ALWAYS_ON"' >/dev/null 2>&1; then
  ok "router sandbox is pinned"
else
  note "router sandbox is not pinned; Crafting could suspend it while idle"
  hint "run: cs -O $ORG sandbox pin ${CODEX_ROUTER_SANDBOX:-codex-router}"
fi
for t in "${CODEX_ROUTER_ROUTER_TEMPLATE:-codex-router}" "${CODEX_ROUTER_TEMPLATE:-codex-worker}"; do
  if cs template show "$t" -o json >/dev/null 2>&1; then ok "template $t"; else
    bad "template $t is missing"; hint "run: ./bootstrap.sh"
  fi
done
pool_json="$(cs sandbox pool show "${CODEX_ROUTER_POOL:-codex-worker-pool}" -o json 2>/dev/null)"
if [ -n "$pool_json" ]; then
  # A pooled sandbox is claimable once it is RUNNING, or STANDBY if the
  # template detaches its environment.
  ready="$(printf '%s' "$pool_json" \
    | jq '[.instances[]? | select(.status.state == "RUNNING" or .status.state == "STANDBY")] | length')"
  min="$(printf '%s' "$pool_json" | jq -r '.spec.min // 0')"
  ok "worker pool ${CODEX_ROUTER_POOL:-codex-worker-pool}: $ready warm (min $min)"
  [ "${ready:-0}" = "0" ] \
    && hint "an empty pool means the first thread waits for a full sandbox build"
else
  bad "worker pool ${CODEX_ROUTER_POOL:-codex-worker-pool} is missing"
  hint "run: ./bootstrap.sh"
fi

echo
echo "Router"
if out="$(on_router 'echo ROUTER_OK')" && case "$out" in *ROUTER_OK*) true ;; *) false ;; esac; then
  ok "the router answers"

  if on_router 'head -c 200 ~/.local/bin/codex | grep -q "codex-router shim"' >/dev/null 2>&1; then
    ok "the shim is installed in front of the Codex CLI"
  else
    bad "the shim is not installed"
    hint "check: cs -O $ORG ssh -W $TARGET -- 'tail ~/.codex-router/log/init.log'"
  fi

  real="$(on_router 'cat ~/.codex-router/etc/codex-real 2>/dev/null')"
  version="$(on_router 'PATH=$HOME/.local/bin:$PATH codex --version 2>/dev/null')"
  if [ -n "$version" ]; then ok "Codex CLI $version (real binary: ${real:-unknown})"; else
    bad "the Codex CLI does not answer --version"
  fi

  py="$(on_router 'cat ~/.codex-router/etc/python 2>/dev/null')"
  if [ -n "$py" ] && on_router "$py -c 'import websockets'" >/dev/null 2>&1; then
    ok "the demux can import websockets ($py)"
  else
    bad "no Python on the router can import websockets"
    hint "check: cs -O $ORG ssh -W $TARGET -- '~/.codex-router/bin/codex-router-deps'"
  fi

  auth="$(on_router 'env -u CRAFTING_SESSION_SOCK -u CRAFTING_SESSION_ID /opt/sandboxd/bin/cs info 2>&1 | awk -F": *" "/Email:/ && !seen {print \$2; seen=1}"')"
  case "$auth" in
    *"${CODEX_ROUTER_SERVICE_ACCOUNT:-codex-router}"*) ok "cs on the router is $auth" ;;
    "") bad "cs on the router is not authenticated"
        hint "it cannot claim workers; check ~/.codex-router/log/init.log" ;;
    *)  note "cs on the router is $auth (expected the service account)" ;;
  esac

  mode="$(on_router 'cat ~/.codex-router/mode 2>/dev/null')"
  case "$mode" in
    route) ok "mode is route -- each thread gets its own sandbox" ;;
    local) note "mode is local -- every thread runs on the router itself"
           hint "run: cs -O $ORG ssh -W $TARGET -- '~/.codex-router/bin/codexctl mode route'" ;;
    *)     bad "unknown mode '${mode:-<none>}'" ;;
  esac
else
  bad "the router does not answer: $out"
fi

echo
echo "Threads"
on_router '~/.codex-router/bin/codexctl threads' | sed 's/^/  /'

echo
if [ "$fail" = 0 ]; then
  echo "All good. './doctor.sh --probe' drives the router the way Codex App does."
else
  echo "Fix the items marked FAIL above, then run this again."
fi
exit "$fail"
