#!/usr/bin/env bash
set -euo pipefail

default_workload="${CODEX_CRAFTING_WORKLOAD:-app}"
default_remote_user="${CODEX_CRAFTING_REMOTE_USER:-owner}"
default_project_dir="${CODEX_CRAFTING_PROJECT_DIR:-/home/owner}"
default_secret_path="${CODEX_CRAFTING_SECRET_PATH:-/run/sandbox/fs/secrets/shared/shared/openai-key}"
default_org="${CODEX_CRAFTING_ORG:-}"
ssh_config="${HOME}/.ssh/config"

prompt() {
  local label="$1"
  local default_value="$2"
  local value
  if [[ -n "$default_value" ]]; then
    read -r -p "${label} [${default_value}]: " value
    printf '%s' "${value:-$default_value}"
  else
    read -r -p "${label}: " value
    printf '%s' "$value"
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

extract_host() {
  local sandbox_name="$1"
  local workload="$2"
  local org="$3"
  local folder="$4"
  local bare_name="$5"
  local args=()

  if [[ -n "$org" ]]; then
    args+=("-O" "$org")
  fi
  if [[ -n "$folder" ]]; then
    args+=("--folder" "$folder")
  fi

  if [[ "${#args[@]}" -gt 0 ]]; then
    NO_COLOR=1 cs "${args[@]}" sb show "$bare_name" 2>&1
  else
    NO_COLOR=1 cs sb show "$bare_name" 2>&1
  fi | awk -v workload="$workload" '{
    gsub(/\033\[[0-9;]*[[:alpha:]]/, "")
    if ($1 == workload) { print $2; exit }
  }'
}

default_alias_for_sandbox() {
  local sandbox_name="$1"
  local base
  base="${sandbox_name##*/}"
  base="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "$base" ]]; then
    base="codex-remote"
  fi
  printf '%s' "$base"
}

split_sandbox_name() {
  local sandbox_name="$1"
  local __folder_var="$2"
  local __bare_var="$3"
  local parsed_folder=""
  local parsed_bare="$sandbox_name"

  if [[ "$sandbox_name" == */* ]]; then
    parsed_folder="${sandbox_name%/*}"
    parsed_bare="${sandbox_name##*/}"
  fi

  printf -v "$__folder_var" '%s' "$parsed_folder"
  printf -v "$__bare_var" '%s' "$parsed_bare"
}

write_ssh_alias() {
  local alias_name="$1"
  local host_name="$2"
  local remote_user="$3"
  local tmp
  tmp="$(mktemp)"

  mkdir -p "$HOME/.ssh"
  touch "$ssh_config"
  chmod 600 "$ssh_config"

  awk -v alias_name="$alias_name" '
    $0 == "# >>> codex-crafting-remote " alias_name { skip=1; next }
    $0 == "# <<< codex-crafting-remote " alias_name { skip=0; next }
    !skip { print }
  ' "$ssh_config" > "$tmp"

  cat >> "$tmp" <<EOF

# >>> codex-crafting-remote ${alias_name}
Host ${alias_name}
  HostName ${host_name}
  Port 22
  User ${remote_user}
  ProxyCommand ${HOME}/.crafting/sandbox/cli/current/bin/cs ssh-proxy %h:443
  UserKnownHostsFile ${HOME}/.crafting/sandbox/known_hosts
  StrictHostKeyChecking yes
  HashKnownHosts no
  IdentityFile ${HOME}/.crafting/sandbox/id_client
# <<< codex-crafting-remote ${alias_name}
EOF

  mv "$tmp" "$ssh_config"
  chmod 600 "$ssh_config"
}

remote() {
  local alias_name="$1"
  shift
  ssh "$alias_name" -- "$@"
}

install_codex_remote() {
  local alias_name="$1"
  echo "Installing Node.js, npm, and Codex CLI on the remote..."
  remote "$alias_name" 'sudo apt-get update && sudo apt-get install -y nodejs npm && sudo npm install -g @openai/codex'
}

login_remote_codex() {
  local alias_name="$1"
  local preferred_secret_path="$2"
  local detected_secret_path

  if [[ "${CODEX_CRAFTING_SKIP_LOGIN:-}" == "1" ]]; then
    echo "Skipping login because CODEX_CRAFTING_SKIP_LOGIN=1."
    return 0
  fi

  if remote "$alias_name" 'test -n "${OPENAI_API_KEY:-}"'; then
    echo "Logging remote Codex in from remote OPENAI_API_KEY. The key will not be printed."
    remote "$alias_name" 'printenv OPENAI_API_KEY | codex login --with-api-key'
    return 0
  fi

  if remote "$alias_name" 'test -n "${CODEX_ACCESS_TOKEN:-}"'; then
    echo "Logging remote Codex in from remote CODEX_ACCESS_TOKEN. The token will not be printed."
    remote "$alias_name" 'printenv CODEX_ACCESS_TOKEN | codex login --with-access-token'
    return 0
  fi

  detected_secret_path="$(
    remote "$alias_name" "for path in '$preferred_secret_path' /run/sandbox/fs/secrets/shared/shared/openai-key /run/sandbox/fs/secrets/shared/shared/OPENAI-API-KEY /run/sandbox/fs/secrets/shared/shared/openai-api-key /run/sandbox/fs/secrets/shared/openai-key /run/sandbox/fs/secrets/shared/OPENAI-API-KEY /run/sandbox/fs/secrets/shared/openai-api-key /run/sandbox/fs/secrets/openai-key /run/sandbox/fs/secrets/OPENAI-API-KEY /run/sandbox/fs/secrets/openai-api-key; do if [ -r \"\$path\" ]; then printf '%s\n' \"\$path\"; exit 0; fi; done"
  )"

  if [[ -n "$detected_secret_path" ]]; then
    echo "Logging remote Codex in with API key secret at ${detected_secret_path}. The key will not be printed."
    remote "$alias_name" "cat '$detected_secret_path' | codex login --with-api-key"
    return 0
  fi

  echo "No remote Codex auth source found."
  echo "Looked for remote OPENAI_API_KEY, CODEX_ACCESS_TOKEN, and secret files under /run/sandbox/fs/secrets."
  echo "You can still run: ssh ${alias_name} -- 'codex login --device-auth'"
}

main() {
  require_cmd cs
  require_cmd ssh
  require_cmd awk

  echo "Crafting -> Codex App remote setup"
  echo

  local sandbox_name alias_name workload remote_user project_dir secret_path host_name default_alias org folder bare_sandbox_name
  sandbox_name="${1:-}"
  if [[ -z "$sandbox_name" ]]; then
    sandbox_name="$(prompt "Crafting sandbox name, e.g. lab/codex-demo" "")"
  fi

  default_alias="${CODEX_CRAFTING_ALIAS:-$(default_alias_for_sandbox "$sandbox_name")}"
  alias_name="${2:-$default_alias}"

  workload="${CODEX_CRAFTING_WORKLOAD:-$default_workload}"
  remote_user="${CODEX_CRAFTING_REMOTE_USER:-$default_remote_user}"
  project_dir="${CODEX_CRAFTING_PROJECT_DIR:-$default_project_dir}"
  secret_path="${CODEX_CRAFTING_SECRET_PATH:-$default_secret_path}"
  org="${CODEX_CRAFTING_ORG:-$default_org}"
  split_sandbox_name "$sandbox_name" folder bare_sandbox_name

  echo "Sandbox:       ${sandbox_name}"
  if [[ -n "$org" ]]; then
    echo "Org:           ${org}"
  fi
  if [[ -n "$folder" ]]; then
    echo "Folder:        ${folder}"
  fi
  echo "SSH alias:     ${alias_name}"
  echo "Workload:      ${workload}"
  echo "Remote user:   ${remote_user}"
  echo "Project dir:   ${project_dir}"

  echo
  echo "Looking up workload SSH host..."
  host_name="$(extract_host "$sandbox_name" "$workload" "$org" "$folder" "$bare_sandbox_name" || true)"
  if [[ -z "$host_name" ]]; then
    echo "Could not parse host for workload '${workload}' from cs sb show."
    host_name="$(prompt "Paste workload SSH host" "")"
  fi

  if [[ -z "$host_name" ]]; then
    echo "No SSH host provided; stopping." >&2
    exit 1
  fi

  echo "Writing SSH alias '${alias_name}' -> ${host_name}"
  write_ssh_alias "$alias_name" "$host_name" "$remote_user"

  echo "Verifying SSH..."
  remote "$alias_name" 'whoami; hostname; pwd'

  echo "Checking remote Codex CLI..."
  if ! remote "$alias_name" 'command -v codex >/dev/null 2>&1'; then
    echo "Remote codex command was not found."
    read -r -p "Install Node.js, npm, and @openai/codex now? [y/N]: " should_install
    case "$should_install" in
      y|Y|yes|YES) install_codex_remote "$alias_name" ;;
      *) echo "Skipping install. Codex App will not work until remote codex is on PATH." ;;
    esac
  fi

  remote "$alias_name" 'command -v codex && codex --version && codex app-server --help >/dev/null && echo app-server-ok'

  login_remote_codex "$alias_name" "$secret_path"

  echo "Remote login status:"
  remote "$alias_name" 'codex login status || true'

  echo "Running Codex doctor..."
  remote "$alias_name" 'codex doctor --summary --ascii || true'

  echo
  echo "Done. In Codex App, open Settings -> Connections -> SSH, refresh/toggle '${alias_name}',"
  echo "then choose the remote project folder: ${project_dir}"
}

main "$@"
