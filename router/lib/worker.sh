# Worker sandbox resolution and access for the Codex router.
#
# The demux decides which thread goes where; this decides what "there" is --
# claiming a sandbox from the pool, resuming one Crafting suspended, and
# knowing how to reach it. Sourced by bin/codex-worker and bin/codexctl, not
# executed.
#
# The caller is expected to define log(); a no-op stands in if it does not.

declare -F log >/dev/null || log() { :; }

ROUTER_HOME="${CODEX_ROUTER_HOME:-/home/owner/.codex-router}"
ETC_DIR="$ROUTER_HOME/etc"
LOG_DIR="$ROUTER_HOME/log"
RUN_DIR="$ROUTER_HOME/run"
THREADS_DIR="$ROUTER_HOME/threads"

mkdir -p "$LOG_DIR" "$RUN_DIR" "$THREADS_DIR" 2>/dev/null || true

# shellcheck disable=SC1091
[ -f "$ROUTER_HOME/config" ] && . "$ROUTER_HOME/config"

# The config file above is written by the template and is the reliable source
# here: this runs from a daemon and from ssh commands, neither of which is
# guaranteed to keep Crafting's own SANDBOX_* variables.
ORG="${CODEX_ROUTER_ORG:-${SANDBOX_ORG:-}}"
WORKER_TEMPLATE="${CODEX_ROUTER_TEMPLATE:-codex-worker}"
WORKER_WORKSPACE="${CODEX_ROUTER_WORKER_WORKSPACE:-dev}"
NAME_PREFIX="${CODEX_ROUTER_PREFIX:-cx}"
CREATE_TIMEOUT="${CODEX_ROUTER_CREATE_TIMEOUT:-240}"
VERIFY_TTL="${CODEX_ROUTER_VERIFY_TTL:-300}"
CS_BIN="${CS_BIN:-/opt/sandboxd/bin/cs}"
DNS_SUFFIX="${CODEX_ROUTER_DNS_SUFFIX:-${SANDBOX_SYSTEM_DNS_SUFFIX:-}}"

# The port each worker's app-server listens on, always on its own loopback.
# Loopback is what lets it run without --ws-auth: the only way in is the
# router's SSH tunnel.
WORKER_PORT="${CODEX_ROUTER_WORKER_PORT:-8383}"

# `cs login` writes the client keypair under ~/.config/crafting on Linux and
# ~/.crafting on macOS; accept either so this is not tied to one layout.
IDENTITY="${CODEX_ROUTER_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  for candidate in \
    /home/owner/.config/crafting/sandbox/id_client \
    /home/owner/.crafting/sandbox/id_client
  do
    [ -f "$candidate" ] && { IDENTITY="$candidate"; break; }
  done
fi

# ---------------------------------------------------------------------------
# Crafting API
# ---------------------------------------------------------------------------

cs() {
  [ -n "$ORG" ] || { log "FATAL no org configured -- set CODEX_ROUTER_ORG in $ROUTER_HOME/config"; return 1; }
  "$CS_BIN" -O "$ORG" "$@"
}

sandbox_id() {
  cs sandbox show "$1" -o json 2>/dev/null | jq -r '.meta.id // empty'
}

# Crafting reports a sandbox's state in two places: a suspended sandbox only
# has spec.op_state, while a live one reports through its workload's agent.
# Empty output means the sandbox does not exist.
STATE_JQ='
  if (.spec.op_state.state // "") == "SUSPENDED" then "SUSPENDED"
  else (.status.workloads[0].agent.overview.state
        // .status.workloads[0].status.state
        // "UNKNOWN") end'

sandbox_state() {
  cs sandbox show "$1" -o json 2>/dev/null | jq -r "$STATE_JQ"
}

worker_hostname() {
  printf '%s--%s-%s%s' "$WORKER_WORKSPACE" "$1" "$ORG" "$DNS_SUFFIX"
}

# A worker is reusable as long as Crafting still has it in a state we can
# resume into. Anything else means the mapping is stale.
usable_state() {
  case "$1" in
    READY|RUNNING|STANDBY|STARTING|CREATING|SUSPENDED) return 0 ;;
    *) return 1 ;;
  esac
}

# The sandbox name a thread owns.
#
# Codex thread ids are UUIDv7, so their leading hex digits are a timestamp:
# two threads started within the same minute share their first eight
# characters. Taking them the way a v4 id allows would hand both threads the
# same sandbox, so the name is a digest of the whole id instead.
worker_name_for() {
  printf '%s-%s' "$NAME_PREFIX" \
    "$(printf '%s' "$1" | md5sum | cut -c1-10)"
}

# Claiming from the pool is serialised across all threads.
#
# Crafting hands out a pooled instance by renaming it, so two claims racing on
# the same instant can both be given the same one: the first thread's worker
# then vanishes out from under it while the second believes it owns a fresh
# sandbox. A per-thread lock cannot prevent that, because the threads are
# different -- the claim itself is what has to be serialised.
create_worker() {
  local key="$1" name="$2"
  log "CREATE key=$key name=$name template=$WORKER_TEMPLATE"
  local start out rc
  start=$(date +%s)

  exec 8>"$RUN_DIR/lock.create"
  flock 8
  out=$(cs sandbox create "$name" -t "$WORKER_TEMPLATE" 2>&1)
  rc=$?
  # Only release once the claim is visible by name, so the next thread cannot
  # be handed the same instance while this one is still being renamed.
  [ $rc -eq 0 ] && sandbox_id "$name" >/dev/null 2>&1
  flock -u 8

  if [ $rc -ne 0 ]; then
    log "CREATE FAILED key=$key name=$name rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ')"
    return 1
  fi
  # Only the first line: the rest is a progress table hundreds of lines long
  # that buries every other decision in the log.
  log "CREATE ok key=$key name=$name secs=$(( $(date +%s) - start )) out=$(printf '%s' "$out" | head -1)"
  return 0
}

# Block until the worker can actually accept SSH.
ensure_running() {
  local name="$1" state deadline
  deadline=$(( $(date +%s) + CREATE_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state="$(sandbox_state "$name")"
    case "$state" in
      READY|RUNNING) return 0 ;;
      ''|ERROR|FAILED|DELETED) log "ENSURE bad state name=$name state=${state:-gone}"; return 1 ;;
    esac
    sleep 2
  done
  log "ENSURE timeout name=$name state=$state"
  return 1
}

# Resolve a routing key's worker, creating it on first sight, and print
# "<name> <hostname>".
#
# Each `cs` round trip is about 0.6s and this sits inside the thread/start the
# app is waiting on, so a validated answer is cached and re-checked only every
# VERIFY_TTL seconds. That revalidation is what catches a worker Crafting
# suspended while the thread sat idle.
resolve_worker() {
  local key="$1"
  local map="$THREADS_DIR/$key"
  local host_cache="$THREADS_DIR/$key.host"
  local ok_stamp="$THREADS_DIR/$key.ok"
  local name
  name="$(worker_name_for "$key")"
  local lock="$RUN_DIR/lock.$(printf '%s' "$key" | md5sum | cut -c1-16)"

  exec 9>"$lock"
  flock 9

  if [ -f "$map" ] && [ -f "$host_cache" ] && [ -f "$ok_stamp" ]; then
    local age
    age=$(( $(date +%s) - $(stat -c %Y "$ok_stamp" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$VERIFY_TTL" ]; then
      flock -u 9
      printf '%s %s' "$(cat "$map")" "$(cat "$host_cache")"
      return 0
    fi
  fi

  local existing state
  existing="$(cat "$map" 2>/dev/null)"
  [ -n "$existing" ] && name="$existing"

  state="$(sandbox_state "$name")"
  if ! usable_state "$state"; then
    [ -n "$existing" ] && log "STALE key=$key name=$existing state=${state:-gone} -- rebinding"
    name="$(worker_name_for "$key")"
    if ! create_worker "$key" "$name"; then
      flock -u 9
      return 1
    fi
  elif [ "$state" = "SUSPENDED" ]; then
    log "RESUME key=$key name=$name"
    cs sandbox resume "$name" >/dev/null 2>&1
  fi

  if ! ensure_running "$name"; then
    flock -u 9
    return 1
  fi

  local id host
  id="$(sandbox_id "$name")"
  if [ -z "$id" ]; then
    log "RESOLVE no id for name=$name"
    flock -u 9
    return 1
  fi
  host="$(worker_hostname "$id")"

  printf '%s' "$name" > "$map"
  printf '%s' "$host" > "$host_cache"
  : > "$ok_stamp"
  [ -n "$existing" ] || \
    printf '%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$key" "$name" "$host" \
      >> "$ROUTER_HOME/threads.index"

  flock -u 9
  printf '%s %s' "$name" "$host"
}

# Record that a key owns a worker that was claimed under a different key.
#
# A thread's id does not exist until the app-server mints it in the response to
# thread/start, so its worker has to be claimed before there is anything to
# name it after. This is what closes that gap: the binding is written after the
# fact, and every later resolve of that thread finds the sandbox it already has.
bind_worker() {
  local key="$1" name="$2" host="$3" claimed_under="${4:-}"
  printf '%s' "$name" > "$THREADS_DIR/$key"
  printf '%s' "$host" > "$THREADS_DIR/$key.host"
  : > "$THREADS_DIR/$key.ok"
  printf '%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$key" "$name" "$host" \
    >> "$ROUTER_HOME/threads.index"

  # The placeholder the sandbox was claimed under has served its purpose. Left
  # behind it would show up as a second thread owning the same worker.
  if [ -n "$claimed_under" ] && [ "$claimed_under" != "$key" ]; then
    rm -f "$THREADS_DIR/$claimed_under" \
          "$THREADS_DIR/$claimed_under.host" \
          "$THREADS_DIR/$claimed_under.ok"
  fi
}

# Force the next resolve_worker for this key onto the slow path.
#
# The cache answers from a file, so it cannot tell that the sandbox it names
# has since been suspended or deleted -- only something that actually talks to
# the worker can. Callers that discover this drop the stamp and resolve again,
# which re-checks Crafting and resumes or rebinds as needed. The map is left
# alone: the thread still owns that sandbox.
invalidate_worker() {
  rm -f "$THREADS_DIR/$1.ok" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Reaching the worker
# ---------------------------------------------------------------------------

# The demux opens one long-lived tunnel per worker and a handful of short
# housekeeping calls alongside it. Sharing a single connection turns each of
# those into a local socket connect rather than a fresh gateway TLS handshake.
worker_ssh_args() {
  WORKER_SSH_ARGS=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$ETC_DIR/worker_known_hosts"
    -o LogLevel=ERROR
    -o ConnectTimeout=30
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=10
    -o ExitOnForwardFailure=yes
    -o ProxyCommand="$CS_BIN ssh-proxy %h:443"
    -i "$IDENTITY"
  )
  # `own` for a connection that has to outlive the command that started it.
  # A client that shares the master hands its forward over and exits, which
  # leaves the forward alive but owned by nobody the demux can watch or kill --
  # so the demux reads that exit as the tunnel dying and gives up on a worker
  # it is in fact connected to.
  if [ "${1:-shared}" = own ]; then
    WORKER_SSH_ARGS+=( -o ControlMaster=no -o ControlPath=none )
  else
    WORKER_SSH_ARGS+=(
      -o ControlMaster=auto
      -o ControlPath="$RUN_DIR/cm-%C"
      -o ControlPersist=600
    )
  fi
}

# Housekeeping calls: probes, app-server starts, kills.
#
# -n matters: ssh forwards its stdin to the remote command, and these are
# called from processes whose stdin is someone else's protocol stream.
worker_ssh() {
  local host="$1"; shift
  worker_ssh_args
  ssh "${WORKER_SSH_ARGS[@]}" -n "owner@$host" "$@"
}

# ---------------------------------------------------------------------------
# The worker's app-server
# ---------------------------------------------------------------------------

# Start the worker's app-server if it is not already up.
#
# ws:// rather than the unix socket Desktop would use, because the router
# reaches it through a TCP port forward -- a real socket the demux's websocket
# client can dial without having to speak the protocol over a pipe. Binding
# loopback keeps it unauthenticated but unreachable from anywhere except the
# tunnel.
worker_app_server() {
  local host="$1"
  # Whether the port answers, not whether a process matches: this script's own
  # command line contains the command it would search for, so every process
  # check finds itself and reports an app-server that was never started. The
  # port cannot lie about it.
  worker_ssh "$host" -- "
    set -u
    if (exec 3<>/dev/tcp/127.0.0.1/$WORKER_PORT) 2>/dev/null; then exit 0; fi
    command -v codex >/dev/null 2>&1 || exit 3
    mkdir -p ~/.codex-router
    nohup codex app-server --listen ws://127.0.0.1:$WORKER_PORT \
      >> ~/.codex-router/app-server.log 2>&1 &
    for _ in \$(seq 1 60); do
      if (exec 3<>/dev/tcp/127.0.0.1/$WORKER_PORT) 2>/dev/null; then exit 0; fi
      sleep 0.5
    done
    exit 4
  "
}
