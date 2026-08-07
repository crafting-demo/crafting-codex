#!/usr/bin/env bash
#
# Undo install.sh, and optionally everything bootstrap.sh made in Crafting.
#
#   ./uninstall.sh          this machine: the ssh alias, the skills, the prompts
#   ./uninstall.sh --all    also the router sandbox and every worker
#   ./uninstall.sh --purge  also the templates, pools, secret, service account,
#                           and the saved answers -- a reinstall starts over
#
# Only --all and --purge need `cs`. The plain form works on a machine that was
# never bootstrapped, and on one whose Crafting side is already gone.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib/config.sh"

MODE="${1:-}"
case "$MODE" in
  ''|--all|--purge) ;;
  -h|--help) sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option '$MODE' -- try --all, --purge, or no argument" ;;
esac

resolve_config soft
ALIAS="${CODEX_ALIAS:-codex-cloud}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SSH_CONFIG="$HOME/.ssh/config"

BEGIN_MARK="# >>> codex-cloud >>>"
END_MARK="# <<< codex-cloud <<<"

# ---------------------------------------------------------------------------
# The SSH alias Codex App connects to
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# The skills and slash commands install.sh copied into CODEX_HOME
#
# Named from the repo rather than listed here, so a command added later is
# still removed by this. Only files this repo owns are touched: a prompt of
# your own that happens to sit alongside them is left alone.
# ---------------------------------------------------------------------------

say "Removing slash commands from $CODEX_DIR/prompts"
removed=0
for f in "$ROOT/prompts/local/"*.md "$ROOT/prompts/anywhere/"*.md; do
  [ -f "$f" ] || continue
  target="$CODEX_DIR/prompts/$(basename "$f")"
  [ -f "$target" ] || continue
  rm -f "$target"
  echo "  /$(basename "$f" .md)"
  removed=$((removed + 1))
done
[ "$removed" -gt 0 ] || echo "  none were installed"

say "Removing skills from $CODEX_DIR/skills"
removed=0
for s in codex-worker-templates crafting-sandbox; do
  [ -d "$CODEX_DIR/skills/$s" ] || continue
  rm -rf "${CODEX_DIR:?}/skills/$s"
  echo "  $s"
  removed=$((removed + 1))
done
[ "$removed" -gt 0 ] || echo "  none were installed"

# ---------------------------------------------------------------------------
# The Crafting side
# ---------------------------------------------------------------------------

if [ "$MODE" = "--all" ]; then
  say "Destroying the router sandbox and its workers"
  "$ROOT/bootstrap.sh" --destroy
elif [ "$MODE" = "--purge" ]; then
  say "Destroying everything this repo created in Crafting"
  "$ROOT/bootstrap.sh" --destroy-all

  # The generated templates and the saved answers, so the next bootstrap.sh
  # asks its questions again instead of rebuilding what was just deleted.
  say "Removing the saved answers and the generated templates"
  rm -f "$CONF_FILE" && echo "  $(basename "$CONF_FILE")"
  rm -rf "$ROOT/templates" && echo "  templates/"
fi

cat <<EOF

Done. One thing this cannot do for you: Codex App keeps its own record of the
connection, so remove '$ALIAS' under Settings -> Connections -> SSH.
EOF
