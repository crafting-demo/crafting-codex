#!/usr/bin/env bash
#
# Push the local working copy into the running router sandbox.
#
# The router runs this repo from a checkout at ~/crafting-codex, so a committed
# change deploys with `git pull` over there. This is for the change you have
# not committed yet: it copies the working copy straight into that checkout
# and restarts the demux.
#
#   ./deploy.sh              copy and restart the demux
#   ./deploy.sh --no-restart copy only
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT/lib/config.sh"

resolve_config soft
ALIAS="${CODEX_ALIAS:-codex-cloud}"
SRC="/home/owner/crafting-codex"

grep -q "^Host $ALIAS\$" "$HOME/.ssh/config" 2>/dev/null \
  || die "no '$ALIAS' host in ~/.ssh/config -- run ./install.sh first"

say "Copying the working copy to $ALIAS:$SRC"
for rel in sandbox-setup.sh \
           router/lib/worker.sh router/bin/codex-shim router/bin/codex-demux \
           router/bin/codex-worker router/bin/codex-router-init \
           router/bin/codex-router-deps router/bin/codexctl \
           skills/crafting-sandbox/SKILL.md \
           skills/crafting-sandbox/references/cs-cli.md \
           prompts/anywhere/cs-new.md prompts/anywhere/cs-task.md \
           prompts/anywhere/cs-status.md prompts/anywhere/cs-sandbox.md \
           prompts/anywhere/cs-templates.md; do
  mode=0644
  case "$rel" in *.sh|*/bin/*) mode=0755 ;; esac
  case "$rel" in router/lib/*) mode=0644 ;; esac
  ssh -o BatchMode=yes "$ALIAS" \
    "mkdir -p $SRC/$(dirname "$rel") && cat > $SRC/$rel.new \
     && chmod $mode $SRC/$rel.new && mv -f $SRC/$rel.new $SRC/$rel" \
    < "$ROOT/$rel"
  echo "  $rel"
done

# The copies Codex actually reads on the router: skills and prompts live in
# ~/.codex, and the shim lives on PATH. sandbox-setup laid them down at create;
# this refreshes just those, without rerunning the npm install a full setup does.
say "Refreshing ~/.codex and the shim on PATH"
ssh -o BatchMode=yes "$ALIAS" \
  "mkdir -p ~/.codex/prompts ~/.codex/skills/crafting-sandbox/references \
   && cp -f $SRC/skills/crafting-sandbox/SKILL.md ~/.codex/skills/crafting-sandbox/ \
   && cp -f $SRC/skills/crafting-sandbox/references/cs-cli.md ~/.codex/skills/crafting-sandbox/references/ \
   && cp -f $SRC/prompts/anywhere/*.md ~/.codex/prompts/"
ssh -o BatchMode=yes "$ALIAS" \
  "test -x ~/.local/bin/codex && head -c 200 ~/.local/bin/codex | grep -q 'codex-router shim' \
   && cp -f $SRC/router/bin/codex-shim ~/.local/bin/codex && chmod 755 ~/.local/bin/codex \
   && echo '  ~/.local/bin/codex' || echo '  (not shimmed yet; codex-router-init will do it)'"

if [ "${1:-}" != "--no-restart" ]; then
  say "Restarting the demux"
  ssh -o BatchMode=yes "$ALIAS" "~/.codex-router/bin/codexctl restart"
fi

say "Done. The router's checkout now differs from git; a later 'git pull' there may conflict."
