#!/usr/bin/env python3
"""Generate the Crafting templates for the router and its workers.

The scripts under router/ are the source of truth on disk; this bakes them into
the router template's system.files so a rebuilt sandbox comes up fully
configured. Everything org- or site-specific is read from codex-cloud.conf,
which setup.sh writes, so the generated templates carry no defaults of ours.
"""

import os
import pathlib
import shlex
import sys

ROOT = pathlib.Path(__file__).resolve().parent
ROUTER = ROOT / "router"
OUT_DIR = ROOT / "templates"
CONF = pathlib.Path(os.environ.get("CODEX_CLOUD_CONF", ROOT / "codex-cloud.conf"))

# What a thread can reach: Codex reads skills and custom prompts from
# CODEX_HOME on whichever machine runs its app-server, which for a routed
# thread is the worker sandbox rather than the user's Mac. So they are baked
# into both sandboxes, and the Mac gets its own copies from install.sh.
CODEX_DIR = "/home/owner/.codex"

# The skill files a thread's own sandbox should carry. Named rather than
# globbed: references/one-sandbox.md documents the flow that predates the
# router, which only applies on the user's Mac and would be a wrong turn for a
# thread that is already running in a sandbox of its own.
SANDBOX_SKILL_FILES = (
    "crafting-sandbox/SKILL.md",
    "crafting-sandbox/references/cs-cli.md",
)

BASE_SNAPSHOT = os.environ.get(
    "CODEX_BASE_SNAPSHOT",
    "oci://us-docker.pkg.dev/crafting-eng/pub/sandbox/workspace/default:latest",
)
ROUTER_HOME = "/home/owner/.codex-router"

DEFAULTS = {
    "CODEX_ROUTER_ORG": "",
    "CODEX_ROUTER_SERVER_URL": "",
    "CODEX_ROUTER_DNS_SUFFIX": "",
    "CODEX_ROUTER_WORKSPACE": "router",
    "CODEX_ROUTER_TEMPLATE": "codex-worker",
    "CODEX_ROUTER_WORKER_WORKSPACE": "dev",
    "CODEX_ROUTER_PREFIX": "cx",
    "CODEX_ROUTER_TOKEN_SECRET": "codex-router-token",
    "CODEX_ROUTER_WORKER_PORT": "8383",
    "CODEX_OPENAI_SECRET": "",
    "CODEX_WORKER_REPO": "",
    "CODEX_WORKER_CHECKOUT": "",
    "CODEX_START_DIR": "/home/owner",
}

# Codex is installed per sandbox rather than staged from the router the way
# claude-cloud stages its CLI: the app-server has to be the worker's own
# process, and npm is a great deal cheaper than copying a binary per thread.
CLI_INSTALL = 'npm install -g @openai/codex --prefix "$HOME/.local"'

# Approvals off and full access by default: each worker is a sandbox with
# nothing else in it, so the isolation Codex would be asking permission to
# leave already exists one layer up. The demux enforces the same thing per
# thread; this covers anything that talks to the worker's app-server directly.
YOLO_CONFIG = (
    "mkdir -p ~/.codex && printf '%s\\n' "
    "'approval_policy = \"never\"' 'sandbox_mode = \"danger-full-access\"' "
    ">> ~/.codex/config.toml"
)


def conf() -> dict:
    """Read codex-cloud.conf, letting the environment override it."""
    values = dict(DEFAULTS)
    if CONF.exists():
        for line in CONF.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, raw = line.split("=", 1)
            if key in values:
                values[key] = shlex.split(raw)[0] if raw else ""
    for key in values:
        if os.environ.get(key):
            values[key] = os.environ[key]
    missing = [k for k in ("CODEX_ROUTER_ORG", "CODEX_ROUTER_SERVER_URL") if not values[k]]
    if missing:
        sys.exit(f"{', '.join(missing)} not set -- run ./setup.sh first")
    return values


def block(text: str, indent: int) -> str:
    """Render text as a YAML literal block scalar body at the given indent."""
    pad = " " * indent
    lines = text.split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(pad + line if line else "" for line in lines)


def setup_file(path, mode, content=None, template=None, overwrite=True):
    key = "content" if content is not None else "template"
    body = content if content is not None else template
    return (
        f"        - path: {path}\n"
        f"          owner: '1000:1000'\n"
        f"          mode: '{mode}'\n"
        f"          overwrite: {'true' if overwrite else 'false'}\n"
        f"          {key}: |\n"
        f"{block(body, 12)}\n"
    )


def read(rel: str) -> str:
    return (ROUTER / rel).read_text()


def codex_home_files() -> list:
    """The skills and slash commands every thread's sandbox should carry.

    Only text is baked. Anything executable a skill ships stays in the repo:
    those scripts drive the user's Mac, which a sandbox cannot reach.
    """
    files = []
    for rel in SANDBOX_SKILL_FILES:
        files.append(
            setup_file(
                f"{CODEX_DIR}/skills/{rel}",
                "0644",
                content=(ROOT / "skills" / rel).read_text(),
            )
        )
    for path in sorted((ROOT / "prompts" / "anywhere").glob("*.md")):
        files.append(
            setup_file(f"{CODEX_DIR}/prompts/{path.name}", "0644",
                       content=path.read_text())
        )
    return files


def codex_login(key_file: str) -> str:
    """Sign Codex in from the org's API key.

    Written as one shell line so it can be an on_create step. A sandbox with no
    key still comes up: the failure belongs to the first turn, where it is
    visible, rather than to a template that silently never finishes.
    """
    return (
        f'if [ -s {key_file} ]; then '
        f'PATH="$HOME/.local/bin:$PATH"; '
        f'codex login --with-api-key < {key_file} || true; fi'
    )


def router_template(cfg: dict) -> str:
    router_config = "\n".join(
        [
            "# Sourced by lib/worker.sh and everything under bin/.",
            f"CODEX_ROUTER_ORG={cfg['CODEX_ROUTER_ORG']}",
            f"CODEX_ROUTER_TEMPLATE={cfg['CODEX_ROUTER_TEMPLATE']}",
            f"CODEX_ROUTER_WORKER_WORKSPACE={cfg['CODEX_ROUTER_WORKER_WORKSPACE']}",
            f"CODEX_ROUTER_PREFIX={cfg['CODEX_ROUTER_PREFIX']}",
            f"CODEX_ROUTER_SERVER_URL={cfg['CODEX_ROUTER_SERVER_URL']}",
            f"CODEX_ROUTER_DNS_SUFFIX={cfg['CODEX_ROUTER_DNS_SUFFIX']}",
            f"CODEX_ROUTER_WORKER_PORT={cfg['CODEX_ROUTER_WORKER_PORT']}",
            f"CODEX_START_DIR={cfg['CODEX_START_DIR']}",
            "",
        ]
    )

    key_file = f"{ROUTER_HOME}/etc/openai-key"
    files = [
        setup_file(f"{ROUTER_HOME}/lib/worker.sh", "0644", content=read("lib/worker.sh")),
        setup_file(f"{ROUTER_HOME}/bin/codex-shim", "0755", content=read("bin/codex-shim")),
        setup_file(f"{ROUTER_HOME}/bin/codex-demux", "0755", content=read("bin/codex-demux")),
        setup_file(f"{ROUTER_HOME}/bin/codex-worker", "0755", content=read("bin/codex-worker")),
        setup_file(f"{ROUTER_HOME}/bin/codex-router-init", "0755",
                   content=read("bin/codex-router-init")),
        setup_file(f"{ROUTER_HOME}/bin/codex-router-deps", "0755",
                   content=read("bin/codex-router-deps")),
        setup_file(f"{ROUTER_HOME}/bin/codexctl", "0755", content=read("bin/codexctl")),
        setup_file(f"{ROUTER_HOME}/config", "0644", content=router_config),
        # Rendered from org secrets so no credential lives in the template.
        setup_file(
            f"{ROUTER_HOME}/etc/cs-login-token",
            "0600",
            template='{{secret "%s"}}' % cfg["CODEX_ROUTER_TOKEN_SECRET"],
        ),
        # Left alone on restart so an operator's `codexctl mode` choice
        # survives; a fresh sandbox comes up routing.
        setup_file(f"{ROUTER_HOME}/mode", "0644", content="route", overwrite=False),
    ] + codex_home_files()
    if cfg["CODEX_OPENAI_SECRET"]:
        files.append(
            setup_file(
                key_file, "0600", template='{{secret "%s"}}' % cfg["CODEX_OPENAI_SECRET"]
            )
        )

    setup = " && ".join(
        [
            CLI_INSTALL,
            f"{ROUTER_HOME}/bin/codex-router-deps",
            codex_login(key_file),
        ]
    )

    return f"""\
# Generated by build-template.py -- edit the files under router/ instead.
#
# The router sandbox is the concrete SSH host Codex App connects to. It runs no
# threads of its own: the shim takes over the app-server that Codex Desktop
# starts here, and the demux behind it gives every thread its own worker
# sandbox.
workspaces:
  - name: {cfg['CODEX_ROUTER_WORKSPACE']}
    description: Codex app-server router (per-thread sandbox dispatcher).
    base_snapshot: {BASE_SNAPSHOT}
    env:
      - SHELL=/bin/bash
      - PATH=/usr/local/go/bin:/usr/local/node/bin:$HOME/.local/bin:$PATH
    system:
      files:
{"".join(files)}      daemons:
        - name: codex-router-init
          run:
            cmd: {ROUTER_HOME}/bin/codex-router-init
    lifecycle:
      on_create:
        run:
          cmd: {setup}
        max_retries: 2
        timeout: 10m0s
"""


def worker_template(cfg: dict) -> str:
    """The sandbox a thread actually runs in.

    Plain by design: whatever you would want in a dev sandbox belongs here. The
    only thing the router requires of it is a `codex` on PATH that is already
    signed in, because the router starts an app-server here and talks to it.
    """
    checkout = ""
    if cfg["CODEX_WORKER_REPO"]:
        checkout = f"""\
    checkouts:
      - path: {cfg['CODEX_WORKER_CHECKOUT']}
        repo:
          git: {cfg['CODEX_WORKER_REPO']}
"""

    key_file = "/home/owner/.codex-worker/openai-key"
    entries = codex_home_files()
    setup = f"{CLI_INSTALL} && {YOLO_CONFIG}"
    if cfg["CODEX_OPENAI_SECRET"]:
        entries.insert(
            0,
            setup_file(key_file, "0600",
                       template='{{secret "%s"}}' % cfg["CODEX_OPENAI_SECRET"]),
        )
        setup = f"{CLI_INSTALL} && {YOLO_CONFIG} && {codex_login(key_file)}"
    files = f"""\
    system:
      files:
{"".join(entries)}\
"""

    return f"""\
# Generated by build-template.py -- run ./setup.sh to change the checkout.
#
# This template is yours to change: add services, containers, or dependencies
# the way you would to any Crafting template, and every Codex thread gets them.
# Once you edit it, setup notices and stops regenerating it over your changes.
#
# Workers are claimed from a pool so a new thread gets a sandbox in about a
# second rather than a full build.
workspaces:
  - name: {cfg['CODEX_ROUTER_WORKER_WORKSPACE']}
    description: Codex worker workspace.
{checkout}\
    base_snapshot: {BASE_SNAPSHOT}
    env:
      - SHELL=/bin/bash
      - PATH=/usr/local/go/bin:/usr/local/node/bin:$HOME/.local/bin:$PATH
{files}\
    lifecycle:
      on_create:
        run:
          cmd: {setup}
        max_retries: 2
        timeout: 10m0s
customizations:
  - detach_env:
      enabled: true
"""


def main() -> int:
    cfg = conf()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, text in (
        ("codex-router.yaml", router_template(cfg)),
        ("codex-worker.yaml", worker_template(cfg)),
    ):
        out = OUT_DIR / name
        out.write_text(text)
        print(f"wrote {out} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
