#!/bin/bash
#
# What a sandbox runs on create, from its checkout of this repo.
#
#   sandbox-setup.sh router    the router sandbox
#   sandbox-setup.sh worker    a thread's worker sandbox
#
# The templates used to carry every script and skill inline, which made them
# enormous and meant a template rebake for every change. Now they carry a
# checkout of this repo and this one line, and updating a running router is
# `git pull`. The only things left in a template are what has to be there:
# the checkout itself, the `{{secret ...}}` renders, and the org-specific
# config block.
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_HOME="${CODEX_ROUTER_HOME:-/home/owner/.codex-router}"
# node for the npm install, and ~/.local/bin for the codex it produces.
export PATH="$HOME/.local/bin:/usr/local/node/bin:$PATH"

ROLE="${1:?usage: sandbox-setup.sh router|worker}"

# ---------------------------------------------------------------------------
# The Codex CLI, signed in from the org's key when one was rendered.
#
# npm rather than a staged binary: the app-server has to be this sandbox's own
# process, and the base image already has node. A sandbox with no key still
# comes up; the failure then belongs to the first turn, where it is visible.
# ---------------------------------------------------------------------------

install_codex() {
  npm install -g @openai/codex --prefix "$HOME/.local"
}

login_codex() {
  local key_file="$1"
  [ -s "$key_file" ] || return 0
  codex login --with-api-key < "$key_file" || true
}

# ---------------------------------------------------------------------------
# What a Codex running here can reach: the sandbox-safe skills and slash
# commands. Codex reads them from CODEX_HOME on whichever machine runs the
# app-server, which for a routed thread is this sandbox and not the user's Mac.
# ---------------------------------------------------------------------------

install_codex_home() {
  local dest="${CODEX_HOME:-$HOME/.codex}"
  mkdir -p "$dest/prompts" "$dest/skills/crafting-sandbox/references"
  # Named rather than globbed: references/one-sandbox.md documents the Mac-side
  # flow from before the router, which would be a wrong turn for a thread that
  # is already running in a sandbox of its own.
  cp -f "$SRC/skills/crafting-sandbox/SKILL.md" "$dest/skills/crafting-sandbox/"
  cp -f "$SRC/skills/crafting-sandbox/references/cs-cli.md" \
        "$dest/skills/crafting-sandbox/references/"
  cp -f "$SRC"/prompts/anywhere/*.md "$dest/prompts/"
}

# ---------------------------------------------------------------------------

case "$ROLE" in
  worker)
    # Approvals off and full access: the worker is a sandbox with nothing else
    # in it, so the isolation Codex would ask permission to leave already
    # exists one layer up. The demux enforces the same per thread; this covers
    # anything that talks to this app-server directly.
    mkdir -p "$HOME/.codex"
    grep -q '^approval_policy' "$HOME/.codex/config.toml" 2>/dev/null || {
      printf '%s\n' 'approval_policy = "never"' 'sandbox_mode = "danger-full-access"' \
        >> "$HOME/.codex/config.toml"
    }
    install_codex
    install_codex_home
    login_codex /home/owner/.codex-worker/openai-key
    ;;

  router)
    # The router's scripts run from this checkout through symlinks, so every
    # $ROUTER_HOME/bin reference in the demux, the shim, and codexctl keeps
    # working, and `git pull` here is a deploy.
    mkdir -p "$ROUTER_HOME/etc" "$ROUTER_HOME/run" "$ROUTER_HOME/log" \
             "$ROUTER_HOME/threads"
    chmod 700 "$ROUTER_HOME/etc"
    # A real directory here (from an older install, or a deploy that ran
    # first) would make ln create bin/bin inside it instead of replacing it.
    for d in bin lib; do
      [ -d "$ROUTER_HOME/$d" ] && [ ! -L "$ROUTER_HOME/$d" ] && rm -rf "${ROUTER_HOME:?}/$d"
    done
    ln -sfn "$SRC/router/bin" "$ROUTER_HOME/bin"
    ln -sfn "$SRC/router/lib" "$ROUTER_HOME/lib"
    # Left alone when present so an operator's `codexctl mode` choice survives
    # a rebuild; a fresh sandbox comes up routing.
    [ -f "$ROUTER_HOME/mode" ] || printf 'route' > "$ROUTER_HOME/mode"

    install_codex
    "$SRC/router/bin/codex-router-deps"
    install_codex_home
    login_codex "$ROUTER_HOME/etc/openai-key"
    ;;

  *)
    echo "sandbox-setup.sh: unknown role '$ROLE' (router|worker)" >&2
    exit 1
    ;;
esac
