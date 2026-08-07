#!/usr/bin/env bash
#
# Push the working copy of router/ into the running router sandbox.
#
# bootstrap.sh bakes these files into the template, which is what a rebuilt
# sandbox comes up with -- but rebuilding takes minutes and loses the thread
# bindings. This copies them straight in, which is what you want while working
# on the router itself.
#
#   ./deploy.sh            copy router/ and restart the demux
#   ./deploy.sh --no-restart   copy only
#
# The template is not updated: run ./bootstrap.sh for that.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib/config.sh"

require_cs
resolve_config

ALIAS="$CODEX_ALIAS"
ROUTER_HOME="/home/owner/.codex-router"

grep -q "^Host $ALIAS\$" "$HOME/.ssh/config" 2>/dev/null \
  || die "no '$ALIAS' host in ~/.ssh/config -- run ./install.sh first"

say "Copying router/ to $ALIAS:$ROUTER_HOME"
for rel in lib/worker.sh bin/codex-shim bin/codex-demux bin/codex-worker \
           bin/codex-router-init bin/codex-router-deps bin/codexctl; do
  mode=0755
  case "$rel" in lib/*) mode=0644 ;; esac
  ssh -o BatchMode=yes "$ALIAS" \
    "mkdir -p $ROUTER_HOME/$(dirname "$rel") && cat > $ROUTER_HOME/$rel.new \
     && chmod $mode $ROUTER_HOME/$rel.new && mv -f $ROUTER_HOME/$rel.new $ROUTER_HOME/$rel" \
    < "$ROOT/router/$rel"
  echo "  $rel"
done

# The skills and slash commands a thread sees. The template lays these down on
# a rebuild; this is the same shortcut as above for a router already running.
say "Copying skills and slash commands to $ALIAS:/home/owner/.codex"
for rel in skills/crafting-sandbox/SKILL.md \
           skills/crafting-sandbox/references/cs-cli.md \
           prompts/anywhere/cs-task.md prompts/anywhere/cs-status.md \
           prompts/anywhere/cs-sandbox.md prompts/anywhere/cs-templates.md \
           prompts/anywhere/cs-new.md; do
  case "$rel" in
    prompts/anywhere/*) dest="prompts/$(basename "$rel")" ;;
    *)                  dest="$rel" ;;
  esac
  ssh -o BatchMode=yes "$ALIAS" \
    "mkdir -p /home/owner/.codex/$(dirname "$dest") && cat > /home/owner/.codex/$dest" \
    < "$ROOT/$rel"
  echo "  $dest"
done

# The shim is what the app runs, and it lives on PATH rather than under
# ROUTER_HOME. codex-router-init refreshes it within a few seconds, but waiting
# for that turns every deploy into a guessing game about which copy just ran.
say "Refreshing the shim on PATH"
ssh -o BatchMode=yes "$ALIAS" \
  "test -x ~/.local/bin/codex && head -c 200 ~/.local/bin/codex | grep -q 'codex-router shim' \
   && cp -f $ROUTER_HOME/bin/codex-shim ~/.local/bin/codex && chmod 755 ~/.local/bin/codex \
   && echo '  ~/.local/bin/codex' || echo '  (not shimmed yet; codex-router-init will do it)'"

if [ "${1:-}" != "--no-restart" ]; then
  say "Restarting the demux"
  ssh -o BatchMode=yes "$ALIAS" "$ROUTER_HOME/bin/codexctl restart"
fi

say "Done."
