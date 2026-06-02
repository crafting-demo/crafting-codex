#!/usr/bin/env bash
set -euo pipefail

default_workload="${CODEX_CRAFTING_DEFAULT_WORKLOAD:-}"
default_remote_user="${CODEX_CRAFTING_REMOTE_USER:-owner}"
default_project_dir="${CODEX_CRAFTING_PROJECT_DIR:-}"
default_secret_path="${CODEX_CRAFTING_SECRET_PATH:-}"
default_org="${CODEX_CRAFTING_ORG:-}"
ssh_config="${HOME}/.ssh/config"

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

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

debug_log() {
  if [[ "${CODEX_CRAFTING_DEBUG:-}" == "1" ]]; then
    printf 'setup-crafting-codex-remote debug: %s\n' "$*" >&2
  fi
}

ensure_org_selected() {
  local org="$1"
  local host_name="$2"

  if [[ -n "$host_name" || -n "${CODEX_CRAFTING_SSH_HOST:-}" ]]; then
    return 0
  fi
  if [[ -n "$org" || -n "${CODEX_CRAFTING_ORG:-}" || -n "${CRAFTING_SANDBOX_ORG:-}" ]]; then
    return 0
  fi

  # Run a foreground command before any piped lookups so `cs` can prompt for
  # the org once and persist the selected context.
  cs sb list >/dev/null
}

extract_host() {
  local sandbox_name="$1"
  local workload="$2"
  local org="$3"
  local folder="$4"
  local bare_name="$5"
  local args=()
  local output

  if [[ -n "$org" ]]; then
    args+=("-O" "$org")
  fi

  if [[ -n "$folder" ]]; then
    debug_log "running: cs ${args[*]} --folder ${folder} sb show ${bare_name}"
    debug_log "running: cs ${args[*]} sb show ${folder}/${bare_name}"
    output="$(
      NO_COLOR=1 CLICOLOR=0 cs "${args[@]}" --folder "$folder" sb show "$bare_name" 2>&1 || true
      NO_COLOR=1 CLICOLOR=0 cs "${args[@]}" sb show "${folder}/${bare_name}" 2>&1 || true
    )"
  else
    debug_log "running: cs ${args[*]} sb show ${bare_name}"
    output="$(NO_COLOR=1 CLICOLOR=0 cs "${args[@]}" sb show "$bare_name" 2>&1 || true)"
  fi
  if [[ "${CODEX_CRAFTING_DEBUG:-}" == "1" ]]; then
    {
      echo "setup-crafting-codex-remote debug: cs sb show output begin"
      printf '%s\n' "$output"
      echo "setup-crafting-codex-remote debug: cs sb show output end"
    } >&2
  fi

  printf '%s\n' "$output" | awk -v workload="$workload" '
    {
      gsub(/\033\[[0-9;]*[[:alpha:]]/, "")
      gsub(/[^A-Za-z0-9._@-]+/, " ")
      for (i = 1; i <= NF; i++) {
        token = $i
        sub(/^.*@/, "", token)
        sub(/^[<(]+/, "", token)
        sub(/[>.)]+$/, "", token)
        if (token !~ /^[A-Za-z0-9][A-Za-z0-9._-]*--[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+$/) {
          continue
        }
        token_workload = token
        sub(/--.*/, "", token_workload)
        if (workload != "" && token_workload == workload) {
          print token
          exit
        }
        if (fallback == "") {
          fallback = token
        }
      }
    }
    END {
      if (workload == "" && fallback != "") {
        print fallback
      }
    }
  '
}

infer_workload_from_host() {
  local host="$1"
  if [[ "$host" == *--* ]]; then
    printf '%s' "${host%%--*}"
  fi
}

normalize_host() {
  local host="$1"
  local half
  local len

  host="$(printf '%s' "$host" | tr -d '\r' | awk 'NF { print $1; exit }')"
  len="${#host}"
  if (( len > 0 && len % 2 == 0 )); then
    half="${host:0:len/2}"
    if [[ "$host" == "${half}${half}" ]]; then
      host="$half"
    fi
  fi

  printf '%s' "$host"
}

resolve_crafting_state_dir() {
  local candidates=(
    "${CRAFTING_SANDBOX_STATE_DIR:-}"
    "${XDG_CONFIG_HOME:-$HOME/.config}/crafting/sandbox"
    "$HOME/.crafting/sandbox"
  )
  local candidate

  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -r "${candidate}/id_client" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  printf '%s' "${candidates[1]}"
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
  local tmp cs_bin state_dir identity_file known_hosts_file proxy_command
  tmp="$(mktemp)"
  cs_bin="${CODEX_CRAFTING_CS_BIN:-$(command -v cs)}"
  state_dir="$(resolve_crafting_state_dir)"
  identity_file="${CODEX_CRAFTING_IDENTITY_FILE:-${state_dir}/id_client}"
  known_hosts_file="${CODEX_CRAFTING_KNOWN_HOSTS_FILE:-${state_dir}/known_hosts}"
  proxy_command="$(shell_quote "$cs_bin") ssh-proxy %h:443"

  if [[ ! -r "$identity_file" ]]; then
    echo "Could not find Crafting SSH identity file at ${identity_file}." >&2
    echo "Run 'cs info' or connect to a workspace once so Crafting can create it." >&2
    exit 1
  fi

  if [[ ! -e "$known_hosts_file" ]]; then
    known_hosts_file="${HOME}/.ssh/known_hosts"
  fi

  mkdir -p "$HOME/.ssh"
  touch "$ssh_config"
  chmod 600 "$ssh_config"

  awk -v alias_name="$alias_name" -v host_name="$host_name" '
    /^# >>> codex-crafting-remote / {
      in_block = 1
      block = $0 ORS
      block_alias = substr($0, length("# >>> codex-crafting-remote ") + 1)
      next
    }
    in_block {
      block = block $0 ORS
      if ($0 == "# <<< codex-crafting-remote " block_alias) {
        if (block_alias != alias_name && index(block, "HostName " host_name) == 0) {
          printf "%s", block
        }
        in_block = 0
        block = ""
        block_alias = ""
      }
      next
    }
    { print }
    END {
      if (in_block) {
        printf "%s", block
      }
    }
  ' "$ssh_config" > "$tmp"

  cat >> "$tmp" <<EOF

# >>> codex-crafting-remote ${alias_name}
Host ${alias_name}
  HostName ${host_name}
  Port 22
  User ${remote_user}
  ProxyCommand ${proxy_command}
  UserKnownHostsFile ${known_hosts_file}
  StrictHostKeyChecking accept-new
  HashKnownHosts no
  IdentityFile ${identity_file}
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
    remote "$alias_name" 'PATH="$HOME/.local/bin:$PATH"; printenv OPENAI_API_KEY | codex login --with-api-key'
    return 0
  fi

  if remote "$alias_name" 'test -n "${CODEX_ACCESS_TOKEN:-}"'; then
    echo "Logging remote Codex in from remote CODEX_ACCESS_TOKEN. The token will not be printed."
    remote "$alias_name" 'PATH="$HOME/.local/bin:$PATH"; printenv CODEX_ACCESS_TOKEN | codex login --with-access-token'
    return 0
  fi

  detected_secret_path="$(
    remote "$alias_name" "for path in '$preferred_secret_path' /run/sandbox/fs/secrets/shared/shared/openai-key /run/sandbox/fs/secrets/shared/shared/OPENAI-API-KEY /run/sandbox/fs/secrets/shared/shared/openai-api-key /run/sandbox/fs/secrets/shared/openai-key /run/sandbox/fs/secrets/shared/OPENAI-API-KEY /run/sandbox/fs/secrets/shared/openai-api-key /run/sandbox/fs/secrets/openai-key /run/sandbox/fs/secrets/OPENAI-API-KEY /run/sandbox/fs/secrets/openai-api-key; do if [ -r \"\$path\" ]; then printf '%s\n' \"\$path\"; exit 0; fi; done"
  )"

  if [[ -n "$detected_secret_path" ]]; then
    echo "Logging remote Codex in with API key secret at ${detected_secret_path}. The key will not be printed."
    remote "$alias_name" "PATH=\"\$HOME/.local/bin:\$PATH\"; cat '$detected_secret_path' | codex login --with-api-key"
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

  local sandbox_name alias_name workload remote_user project_dir secret_path host_name default_alias org folder bare_sandbox_name alias_was_default
  sandbox_name="${1:-}"
  if [[ -z "$sandbox_name" ]]; then
    sandbox_name="$(prompt "Crafting sandbox name, e.g. FOLDER/SANDBOX" "")"
  fi

  default_alias="${CODEX_CRAFTING_ALIAS:-$(default_alias_for_sandbox "$sandbox_name")}"
  alias_name="${2:-$default_alias}"
  alias_was_default=0
  if [[ -z "${2:-}" ]]; then
    alias_was_default=1
  fi

  workload="${CODEX_CRAFTING_WORKLOAD:-$default_workload}"
  remote_user="${CODEX_CRAFTING_REMOTE_USER:-$default_remote_user}"
  project_dir="${CODEX_CRAFTING_PROJECT_DIR:-$default_project_dir}"
  secret_path="${CODEX_CRAFTING_SECRET_PATH:-$default_secret_path}"
  host_name="${CODEX_CRAFTING_SSH_HOST:-}"
  org="${CODEX_CRAFTING_ORG:-$default_org}"
  ensure_org_selected "$org" "$host_name"
  split_sandbox_name "$sandbox_name" folder bare_sandbox_name

  echo "Sandbox:       ${sandbox_name}"
  if [[ -n "$org" ]]; then
    echo "Org:           ${org}"
  fi
  if [[ -n "$folder" ]]; then
    echo "Folder:        ${folder}"
  fi
  echo "SSH alias:     ${alias_name}"
  if [[ -n "$workload" ]]; then
    echo "Workload:      ${workload}"
  else
    echo "Workload:      (auto-detect)"
  fi
  echo "Remote user:   ${remote_user}"
  if [[ -n "$project_dir" ]]; then
    echo "Project dir:   ${project_dir}"
  else
    echo "Project dir:   (remote default)"
  fi

  echo
  if [[ -n "$host_name" ]]; then
    echo "Using provided workload SSH host."
  else
    echo "Looking up workload SSH host..."
    host_name="$(extract_host "$sandbox_name" "$workload" "$org" "$folder" "$bare_sandbox_name" || true)"
  fi
  if [[ -z "$host_name" && "$sandbox_name" != */* && -n "$workload" && "$workload" != "$default_workload" ]]; then
    echo "No host found for sandbox '${sandbox_name}' workload '${workload}'."
    echo "Trying folder-scoped sandbox '${sandbox_name}/${workload}' with auto-detected workload..."
    host_name="$(extract_host "${sandbox_name}/${workload}" "$default_workload" "$org" "$sandbox_name" "$workload" || true)"
    if [[ -n "$host_name" ]]; then
      folder="$sandbox_name"
      bare_sandbox_name="$workload"
      sandbox_name="${folder}/${bare_sandbox_name}"
      workload="$default_workload"
      if [[ "$alias_was_default" == "1" ]]; then
        alias_name="$(default_alias_for_sandbox "$sandbox_name")"
      fi
      echo "Resolved as sandbox '${sandbox_name}'."
      echo "SSH alias:     ${alias_name}"
    fi
  fi
  host_name="$(normalize_host "$host_name")"
  debug_log "normalized host: ${host_name:-<empty>}"
  if [[ -z "$workload" ]]; then
    workload="$(infer_workload_from_host "$host_name")"
    if [[ -n "$workload" ]]; then
      echo "Detected workload '${workload}'."
    fi
  fi

  if [[ -z "$host_name" ]]; then
    echo "Could not determine the workload SSH host from 'cs sb show'." >&2
    echo "Check that the sandbox is running and that the requested workload exposes an SSH address." >&2
    echo "If needed, rerun with CODEX_CRAFTING_SSH_HOST or --ssh-host to provide an explicit override." >&2
    exit 1
  fi

  echo "Writing SSH alias '${alias_name}' -> ${host_name}"
  write_ssh_alias "$alias_name" "$host_name" "$remote_user"

  echo "Verifying SSH..."
  remote "$alias_name" 'whoami; hostname; pwd'
  if [[ -z "$project_dir" ]]; then
    project_dir="$(remote "$alias_name" 'pwd' | awk 'NF { print $1; exit }')"
    echo "Detected project dir: ${project_dir}"
  fi

  echo "Checking remote Codex CLI..."
  remote "$alias_name" 'if [ -f "$HOME/.local/bin/codex" ] && grep -q "exec cs codex" "$HOME/.local/bin/codex"; then rm -f "$HOME/.local/bin/codex"; fi'
  if ! remote "$alias_name" 'PATH="$HOME/.local/bin:$PATH"; command -v codex >/dev/null 2>&1'; then
    echo "No working remote Codex entrypoint was found."
    if [[ "${CODEX_CRAFTING_INSTALL_CODEX:-1}" == "1" ]]; then
      install_codex_remote "$alias_name"
    elif [[ -t 0 ]]; then
      read -r -p "Install Node.js, npm, and @openai/codex now? [y/N]: " should_install
      case "$should_install" in
        y|Y|yes|YES) install_codex_remote "$alias_name" ;;
        *)
          echo "Skipping install. Codex App will not work until remote codex is on PATH."
          exit 1
          ;;
      esac
    else
      echo "Remote Codex install was disabled by CODEX_CRAFTING_INSTALL_CODEX=0."
      exit 1
    fi
  fi

  remote "$alias_name" 'PATH="$HOME/.local/bin:$PATH"; command -v codex && codex --version && codex app-server --help >/dev/null && echo app-server-ok'

  login_remote_codex "$alias_name" "$secret_path"

  echo "Remote login status:"
  remote "$alias_name" 'PATH="$HOME/.local/bin:$PATH"; codex login status || true'

  echo "Running Codex doctor..."
  remote "$alias_name" 'PATH="$HOME/.local/bin:$PATH"; codex doctor --summary --ascii || true'

  echo
  echo "Done. SSH and remote Codex are ready."
  echo
  echo "Codex App owns the final connection registration."
  echo "Open Settings -> Connections -> SSH, select or add '${alias_name}', enable it, and choose the remote project folder: ${project_dir}"
  echo
  echo "If '${alias_name}' is not visible in the Add SSH Connection list, add it manually:"
  echo
  echo "  Settings -> Connections -> SSH -> Add"
  echo "  Display name: ${alias_name}"
  echo "  Target mode:  Alias"
  echo "  Alias:        ${alias_name}"
  echo "  Auth mode:    No Auth"
}

main "$@"
