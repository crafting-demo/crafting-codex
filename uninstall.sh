#!/usr/bin/env bash
#
# Undo install.sh on this machine. The Crafting side is left alone: run
# ./bootstrap.sh --destroy for that.
#
#   ./uninstall.sh          remove the ssh config block
#   ./uninstall.sh --all    also destroy the router sandbox and its workers
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib/config.sh"

resolve_config soft
ALIAS="${CODEX_ALIAS:-codex-cloud}"
SSH_CONFIG="$HOME/.ssh/config"

BEGIN_MARK="# >>> codex-cloud >>>"
END_MARK="# <<< codex-cloud <<<"

if [ -f "$SSH_CONFIG" ] && grep -qF "$BEGIN_MARK" "$SSH_CONFIG"; then
  say "Removing the '$ALIAS' block from $SSH_CONFIG"
  cp "$SSH_CONFIG" "$SSH_CONFIG.codex-cloud.bak"
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1 }
    !skip   { print }
    $0 == e { skip = 0 }
  ' "$SSH_CONFIG.codex-cloud.bak" > "$SSH_CONFIG.tmp"
  mv "$SSH_CONFIG.tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
else
  say "No '$ALIAS' block in $SSH_CONFIG"
fi

if [ "${1:-}" = "--all" ]; then
  say "Destroying the Crafting side"
  "$ROOT/bootstrap.sh" --destroy
fi

cat <<EOF

Done. Codex App keeps its own record of the connection: remove '$ALIAS' under
Settings -> Connections -> SSH if you do not want it in the list.
EOF
