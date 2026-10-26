#!/usr/bin/env bash
# Supervising entrypoint for the Codex remote-control container.
#
# What it supervises, and why THAT process:
#   `codex app-server --remote-control --listen unix://` is the long-lived
#   server that `codex remote-control start` would daemonize. Run directly it
#   never exits, reconnects to ChatGPT forever (sawtooth backoff capped at
#   30s), catches SIGTERM, and binds $CODEX_HOME/app-server-control/, which is
#   the socket `codex remote-control pair` and the healthcheck both speak to.
#   The `codex remote-control` wrapper instead exits 1 in ~300ms whenever the
#   bridge is not already up (crash loop), and hides its socket in /tmp;
#   `codex remote-control start` forks, needs the managed standalone tree
#   under CODEX_HOME, and drags in an hourly self-updater that swaps the
#   binary under a live session. Neither is supervisable.
#
# Consequence for the design: the child staying alive means NOTHING about the
# bridge. A permanently errored server is Codex's characteristic failure, so
# the supervisor actively probes remoteControl/status/read (codex-rc-status)
# and reports connected / connecting / bridge-errored / login-required.
#
# Responsibilities:
#   1. First-boot state setup: CODEX_HOME must exist before any app-server
#      call, and a config.toml must exist or every phone-driven command dies
#      in bubblewrap (no user namespaces in a plain container).
#   2. Headless ChatGPT login: device-code flow, with the URL and one-time
#      code pushed to the log and the notify webhook. Remote control refuses
#      API-key auth outright.
#   3. Supervise the app-server: relaunch with capped backoff, gate on
#      network, never fight a stale control socket.
#   4. Watch the bridge and classify: auth failures -> login-required,
#      managed-policy refusals -> fatal (park, never crash-loop).
#   5. Surface state to the Docker healthcheck via /run/codex/state.
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Logging: one event per line —  <RFC3339> LEVEL [component] message
# Components: supervisor (this script), codex (the app-server's own output).
# ---------------------------------------------------------------------------
_C_DIM='' _C_YEL='' _C_RED='' _C_OFF=''
if [[ -t 1 ]]; then
  _C_DIM=$'\e[2m'; _C_YEL=$'\e[33m'; _C_RED=$'\e[31m'; _C_OFF=$'\e[0m'
fi
_emit() {  # _emit <color> <LEVEL> <component> <message...>
  local c="$1" lvl="$2" comp="$3"; shift 3
  printf '%s %s%-5s%s [%s] %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${c}" "${lvl}" "${c:+${_C_OFF}}" "${comp}" "$*"
}
# Stable handle to PID1 stdout for the launch pipeline's process
# substitutions, so the two relays can never chain into each other.
exec 9>&1
log()   { _emit ''          INFO  supervisor "$@"; }
warn()  { _emit "${_C_YEL}" WARN  supervisor "$@"; }
error() { _emit "${_C_RED}" ERROR supervisor "$@"; }
debug() {
  [[ "${LOG_LEVEL:-info}" == "debug" ]] || return 0
  _emit "${_C_DIM}" DEBUG supervisor "$@"
}

# Optional operator alert: HTTP POST to NOTIFY_URL. Best-effort — an
# unreachable notifier must never worsen an outage.
notify() {  # notify <event-slug> <message...>
  [[ -n "${NOTIFY_URL:-}" ]] || return 0
  local event="$1"; shift
  if [[ "${NOTIFY_FORMAT:-text}" == "json" ]]; then
    jq -cn --arg event "${event}" --arg message "$*" \
       '{source: "codex-host", event: $event, message: $message}' \
      | curl -m 10 -s -o /dev/null -H 'Content-Type: application/json' \
             -d @- "${NOTIFY_URL}" || true
  else
    curl -m 10 -s -o /dev/null -d "[codex-host] $*" "${NOTIFY_URL}" || true
  fi
}

STATE_DIR=/run/codex
STATE_FILE="${STATE_DIR}/state"
PID_FILE="${STATE_DIR}/codex.pid"
STATE_HISTORY_FILE="${STATE_DIR}/state-history"
FAIL_STREAK_FILE="${STATE_DIR}/fail-streak"
BRIDGE_FILE="${STATE_DIR}/bridge-status"      # last status probe payload
AUTH_ERROR_MARKER="${STATE_DIR}/auth-error"   # set by the log classifier
FATAL_MARKER="${STATE_DIR}/fatal"             # set by the log classifier
RESTART_REQUEST_MARKER="${STATE_DIR}/restart-request"
NOTIFY_LOGIN_STAMP="${STATE_DIR}/notify-login-stamp"
CODEX_LOG="${STATE_DIR}/codex.log"            # bounded tail of the child's output
LOGIN_CYCLES_FILE="${STATE_DIR}/login-cycles"      # consecutive unattended device-code flows
mkdir -p "${STATE_DIR}"
# A restart is a deliberate act: it earns a fresh round of automatic codes.
rm -f "${PID_FILE}" "${FAIL_STREAK_FILE}" "${RESTART_REQUEST_MARKER}" \
      "${AUTH_ERROR_MARKER}" "${FATAL_MARKER}" "${LOGIN_CYCLES_FILE}"
if [[ -f "${STATE_HISTORY_FILE}" ]]; then
  tail -n 500 "${STATE_HISTORY_FILE}" > "${STATE_HISTORY_FILE}.tmp" 2>/dev/null \
    && mv "${STATE_HISTORY_FILE}.tmp" "${STATE_HISTORY_FILE}" || true
fi

# Every numeric knob comes from .env, and a stray character in one of them
# used to abort a background loop mid-expansion (bash longjmps out of the
# subshell) — silently removing the bridge watcher, which the entire health
# design rests on.
require_num() {  # require_num <VAR_NAME> <default> [minimum]
  local name="$1" def="$2" min="${3:-0}" val="${!1:-}"
  if [[ ! "${val}" =~ ^[0-9]+$ ]]; then
    [[ -n "${val}" ]] && warn "${name}='${val}' is not a whole number; using ${def}."
    val="${def}"
  fi
  (( val < min )) && { warn "${name}=${val} is below the ${min} floor; using ${min}."; val="${min}"; }
  printf -v "${name}" '%s' "${val}"
  export "${name?}"
}
require_num CODEX_PROBE_INTERVAL 30 5
require_num CODEX_BRIDGE_GRACE 300 30
require_num CODEX_BRIDGE_RESTART_MINUTES 30 0
require_num CODEX_UPDATE_INTERVAL_HOURS 12 0
require_num RECONNECT_BACKOFF_MIN 5 1
require_num RECONNECT_BACKOFF_MAX 180 5
require_num CODEX_RESTART_KILL_TIMEOUT 90 10
require_num CODEX_DEVICE_LOGIN_CYCLES 4 0

export CODEX_HOME="${CODEX_HOME:-/root/.codex}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/docker}"
AUTH_FILE="${CODEX_HOME}/auth.json"
CONFIG_FILE="${CODEX_HOME}/config.toml"
CONTROL_SOCK="${CODEX_HOME}/app-server-control/app-server-control.sock"

# Interruptible sleep: plain `sleep` defers the TERM trap until it finishes.
zzz() {
  sleep "$1" &
  wait $! 2>/dev/null || true
}

set_state() {
  local previous
  previous="$(cat "${STATE_FILE}" 2>/dev/null || true)"
  # Always rewrite: the healthcheck reads this file's mtime as its freshness
  # signal. Only APPEND to the trail on a real transition — the watcher calls
  # this every probe, and a per-probe line buries the transitions it exists to
  # record.
  printf '%s' "$1" > "${STATE_FILE}"
  if [[ "${previous}" != "$1" ]]; then
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "${STATE_HISTORY_FILE}" 2>/dev/null || true
    debug "state -> $1"
  fi
}

codex_version() { codex --version 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# One-time state setup.
#
# CODEX_HOME must exist before the first app-server call: `--listen unix://`
# hard-fails with "failed to resolve CODEX_HOME: ... that path does not exist"
# (only `codex --version` is lenient about it).
#
# config.toml: bubblewrap cannot create user namespaces in a non-privileged
# container, so read-only/workspace-write sandboxes fail EVERY command with
# "bwrap: No permissions to create a new namespace". danger-full-access skips
# bwrap entirely and is the only mode that works here — which is also the
# honest description of this container: it is already root with the host
# Docker socket. Written only when absent: Codex appends its own
# [projects."<dir>"] trust entries, and a connected client can rewrite keys
# via config/value/write. Never regenerate it on boot.
# ---------------------------------------------------------------------------
seed_state_dirs() {
  mkdir -p "${CODEX_HOME}"
  chmod 700 "${CODEX_HOME}" 2>/dev/null || true
}

seed_config() {
  if [[ -e "${CONFIG_FILE}" ]]; then
    debug "config.toml exists; leaving it alone."
    return 0
  fi
  cat > "${CONFIG_FILE}" <<EOF_CONFIG
# Seeded once by the container entrypoint; edit freely, it is never rewritten.
#
# danger-full-access is not bravado: bubblewrap needs unprivileged user
# namespaces, which a normal Docker container does not have, so every other
# sandbox_mode fails every command (including reaching the Docker socket).
sandbox_mode = "${CODEX_SANDBOX_MODE:-danger-full-access}"

# on-request lets Codex ask, and the ChatGPT app shows the approval prompt on
# your phone. "never" makes it fully autonomous.
approval_policy = "${CODEX_APPROVAL_POLICY:-on-request}"

# Keep credentials in \$CODEX_HOME/auth.json (the persisted volume) rather
# than an OS keyring that does not exist in a container.
cli_auth_credentials_store = "file"

[projects."${WORKSPACE_DIR}"]
trust_level = "trusted"
EOF_CONFIG
  chmod 600 "${CONFIG_FILE}"
  log "Seeded ${CONFIG_FILE} (sandbox_mode=${CODEX_SANDBOX_MODE:-danger-full-access}, approval_policy=${CODEX_APPROVAL_POLICY:-on-request})."
}

# A codex installed into the persisted volume by the updater wins over the
# image-baked one (PATH puts /root/.local/bin first); the shim itself lives
# outside the volume, so re-point it on every boot.
ensure_shim() {
  local volume_bin="${CODEX_HOME}/packages/standalone/current/bin/codex"
  local image_bin=/usr/local/bin/codex
  local vv iv newest
  rm -f /root/.local/bin/codex
  hash -r
  [[ -x "${volume_bin}" ]] || return 0
  vv="$("${volume_bin}" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  iv="$("${image_bin}" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  # A single CODEX_AUTO_UPDATE=1 experiment used to pin the volume binary
  # ahead of every future image rebuild, because /root/.local/bin comes first
  # on PATH. Only prefer it when it is genuinely newer.
  newest="$(printf '%s\n%s\n' "${vv:-0.0.0}" "${iv:-0.0.0}" | sort -V | tail -1)"
  if [[ -n "${vv}" && "${newest}" == "${vv}" && "${vv}" != "${iv}" ]]; then
    mkdir -p /root/.local/bin
    ln -sf "${volume_bin}" /root/.local/bin/codex
    hash -r
    log "Using the volume install ${vv} (image ships ${iv:-unknown})."
  fi
}

# ---------------------------------------------------------------------------
# Auth.
#
# Remote control is ChatGPT-product infrastructure, not the API: the transport
# refuses anything that is not a ChatGPT-backed grant ("remote control requires
# ChatGPT authentication; API key auth is not supported"), and the app-server
# builds its AuthManager with the api-key env path disabled outright.
#
# So the gate is the CONTENT of auth.json, not the exit code of
# `codex login status` — that command exits 0 for an api-key login too, which
# would let the supervisor launch a server that can never connect.
# ---------------------------------------------------------------------------
auth_ok() {
  jq -e '(.auth_mode == "chatgpt" and ((.tokens.refresh_token // "") | length) > 0)
         or ((.personal_access_token // "") | length) > 0' \
     "${AUTH_FILE}" >/dev/null 2>&1
}

auth_describe() {
  if [[ ! -s "${AUTH_FILE}" ]]; then
    printf 'no auth.json'
  else
    printf '%s' "$(jq -r '.auth_mode // (if (.personal_access_token // "") != "" then "personalAccessToken" else "unknown" end)' "${AUTH_FILE}" 2>/dev/null || echo unreadable)"
  fi
}

# Device-code login, headless. Prints a constant URL plus a 10-character code
# that expires in 15 minutes, then polls every 5s. Works against a LIVE
# app-server: auth is reloaded on every connect attempt, so a completed login
# is picked up within ~30s with no restart.
fresh_login() {  # fresh_login <epoch> — auth.json must be usable AND newer
  auth_ok && [[ "$(stat -c %Y "${AUTH_FILE}" 2>/dev/null || echo 0)" -ge "$1" ]]
}

run_device_login() {
  local out rc code since
  since="$(date +%s)"
  out="$(mktemp)"
  set_state login-required

  # `codex login --device-auth` unlinks auth.json the moment it starts. An
  # unattended escalation must never be able to destroy a grant that might
  # still be good, so keep a copy and put it back if nobody signs in.
  # The device flow needs the network, and consuming a credential during a
  # WAN outage would take the host offline for a 15-minute login window it
  # cannot possibly complete.
  wait_for_network
  set_state login-required

  local backup="${CODEX_HOME}/.auth.json.prev"
  rm -f "${backup}"
  [[ -s "${AUTH_FILE}" ]] && cp -p "${AUTH_FILE}" "${backup}" 2>/dev/null || true

  local now_ts last_ts
  now_ts="$(date +%s)"
  last_ts="$(cat "${NOTIFY_LOGIN_STAMP}" 2>/dev/null || echo 0)"
  [[ "${last_ts}" =~ ^[0-9]+$ ]] || last_ts=0

  # Each unattended device-code flow polls OpenAI every 5s for 15 minutes.
  # Fine for the first hour after boot; not fine for a week of nobody being
  # home. Past the cap, park and wait for `codex-login` instead.
  local cycles
  cycles="$(cat "${LOGIN_CYCLES_FILE}" 2>/dev/null || echo 0)"
  [[ "${cycles}" =~ ^[0-9]+$ ]] || cycles=0
  local parked_reason=""
  if [[ "${CODEX_DEVICE_LOGIN:-1}" != "1" ]]; then
    parked_reason="CODEX_DEVICE_LOGIN=0"
  elif (( CODEX_DEVICE_LOGIN_CYCLES > 0 && cycles >= CODEX_DEVICE_LOGIN_CYCLES )); then
    parked_reason="${cycles} device codes went unused"
  fi

  if [[ -n "${parked_reason}" ]]; then
    log "Login required (auth: $(auth_describe)); ${parked_reason} — waiting for: docker exec -it codex codex-login"
    if (( now_ts - last_ts >= 3600 )); then
      notify login-required "Codex login required. Run: docker exec -it codex codex-login"
      last_ts="${now_ts}"
      printf '%s' "${now_ts}" > "${NOTIFY_LOGIN_STAMP}"
    fi
    while ! fresh_login "${since}"; do
      zzz 10
      now_ts="$(date +%s)"
      if (( now_ts - last_ts >= 3600 )); then
        notify login-required "Codex login still required. Run: docker exec -it codex codex-login"
        last_ts="${now_ts}"
        printf '%s' "${now_ts}" > "${NOTIFY_LOGIN_STAMP}"
      fi
    done
    log "Login complete (auth: $(auth_describe))."
    rm -f "${out}" "${AUTH_ERROR_MARKER}" "${LOGIN_CYCLES_FILE}"
    return 0
  fi

  log "Login required (auth: $(auth_describe)); starting the device-code flow."
  # stdout is unbuffered enough to read live; the code appears immediately.
  codex login --device-auth </dev/null >"${out}" 2>&1 &
  local login_pid=$!

  # The code lands within a second or two; poll briefly for it.
  code=""
  for _ in $(seq 1 30); do
    code="$(sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "${out}" 2>/dev/null \
            | grep -Eo '[A-Z0-9]{4}-[A-Z0-9]{5}' | head -1 || true)"
    [[ -n "${code}" ]] && break
    kill -0 "${login_pid}" 2>/dev/null || break
    zzz 1
  done

  if [[ -n "${code}" ]]; then
    # Each pass mints a code that dies in 15 minutes, so an hourly throttle
    # would deliver one live code and three dead ones. Push every new code.
    cat <<EOF_LOGIN

==============================================
  Codex sign-in required (ChatGPT account)
==============================================

  1. open   https://auth.openai.com/codex/device
  2. enter  ${code}          (expires in 15 minutes)

Nothing else to do here — this container picks the login up on its own,
with no restart. A fresh code is minted automatically every 15 minutes for
the first ${CODEX_DEVICE_LOGIN_CYCLES} codes; after that (or at any time):

  docker exec -it codex codex-login

==============================================

EOF_LOGIN
    notify login-required "Codex sign-in: open https://auth.openai.com/codex/device and enter ${code} (expires in 15 min)"
    printf '%s' "${now_ts}" > "${NOTIFY_LOGIN_STAMP}"
  else
    warn "device-code flow produced no code; output follows."
    sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "${out}" | while IFS= read -r l; do
      [[ -n "${l// /}" ]] && _emit '' INFO codex "${l}"
    done
  fi

  # Poll beside the login process so a login completed EXTERNALLY
  # (docker exec ... codex-login, or a code entered from an earlier attempt)
  # also releases this state.
  while kill -0 "${login_pid}" 2>/dev/null; do
    if fresh_login "${since}"; then
      zzz 3
      kill "${login_pid}" 2>/dev/null || true
      break
    fi
    zzz 5
  done
  rc=0
  wait "${login_pid}" 2>/dev/null || rc=$?
  rm -f "${out}"

  if fresh_login "${since}"; then
    log "Login complete (auth: $(auth_describe))."
    rm -f "${AUTH_ERROR_MARKER}" "${backup}" "${LOGIN_CYCLES_FILE}"
    return 0
  fi
  printf '%s' "$(( cycles + 1 ))" > "${LOGIN_CYCLES_FILE}"

  if [[ -s "${backup}" ]] && ! auth_ok; then
    # Nobody signed in, and the flow consumed the old credential. Put it back
    # and let the supervisor try it again: if it really is dead the bridge
    # fails once more and we come straight back here with a fresh code, and
    # if this was a false escalation the host simply reconnects.
    warn "device login did not complete; restoring the previous credential and retrying with it."
    mv "${backup}" "${AUTH_FILE}"
    chmod 600 "${AUTH_FILE}" 2>/dev/null || true
    rm -f "${AUTH_ERROR_MARKER}"
    return 0
  fi
  rm -f "${backup}"
  warn "device login did not complete (rc ${rc}); will retry."
  return 1
}

ensure_auth() {
  set_state auth-check
  if auth_ok && [[ ! -f "${AUTH_ERROR_MARKER}" ]]; then
    debug "auth check passed (auth: $(auth_describe))."
    return 0
  fi
  if auth_ok && [[ -f "${AUTH_ERROR_MARKER}" ]]; then
    # auth.json still looks like a ChatGPT grant, but the server rejected it
    # (revoked or expired refresh token). Only a new login fixes that.
    warn "stored ChatGPT grant was rejected by the remote-control backend; re-login needed."
    rm -f "${AUTH_ERROR_MARKER}"
  fi
  until run_device_login; do
    zzz 5
  done
  rm -f "${AUTH_ERROR_MARKER}"
}

# ---------------------------------------------------------------------------
# Network gate: any HTTP response (including 4xx) counts as reachable.
# ---------------------------------------------------------------------------
wait_for_network() {
  local url="${NETWORK_PROBE_URL:-https://chatgpt.com}"
  local waited=0
  until curl -m 8 -s -o /dev/null "${url}"; do
    set_state network-wait
    if (( waited % 60 == 0 )); then
      warn "Network unreachable (${url}); waiting..."
    fi
    zzz 15
    waited=$(( waited + 15 ))
  done
  if (( waited > 0 )); then
    log "Network is back after ~${waited}s."
  fi
}

# A second app-server on the same CODEX_HOME exits 1 instantly with
# "app-server control socket is already in use", which reads as a crash loop
# caused by codex when it was really caused by us. Wait the old one out, then
# clear a socket nobody is listening on.
wait_for_socket_free() {
  local waited=0
  while [[ -S "${CONTROL_SOCK}" ]]; do
    if ! python3 -c "
import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect('${CONTROL_SOCK}')
except OSError:
    sys.exit(1)
finally:
    s.close()
" 2>/dev/null; then
      warn "Removing stale control socket ${CONTROL_SOCK}."
      rm -f "${CONTROL_SOCK}"
      break
    fi
    (( waited >= 60 )) && { warn "control socket still in use after ${waited}s; launching anyway."; break; }
    debug "control socket still in use; waiting."
    zzz 5
    waited=$(( waited + 5 ))
  done
}

# ---------------------------------------------------------------------------
# Child output relay.
#
# The app-server writes ANSI-coloured `tracing` lines to stderr (only with
# RUST_LOG set — the default ERROR filter hides every reconnect). This strips
# ANSI, re-emits in the standard log shape, keeps a bounded tail on disk for
# post-mortems, and classifies the two failure families the supervisor must
# act on. Classification happens HERE because the child never exits: there is
# no exit-status moment to inspect, unlike the claude hub.
# ---------------------------------------------------------------------------
relay() {
  python3 -u -c '
import os, re, sys, time
ansi = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
log_path, auth_marker, fatal_marker = sys.argv[1], sys.argv[2], sys.argv[3]
# Only a new login can fix these. Deliberately narrow: bare tokens like
# "unauthorized_unknown" and "401" also appear in ordinary per-request
# telemetry at INFO level, and matching those made routine noise escalate
# into a forced re-login.
AUTH = re.compile(r"remote control requires ChatGPT authentication"
                  r"|remote control auth recovery failed"
                  r"|Failed to refresh token: 40"
                  r"|Your access token could not be refreshed"
                  r"|Could not parse your authentication token")
# Restarting makes these worse: park instead.
FATAL = re.compile(r"remote control is disabled by managed requirements"
                   r"|failed to resolve CODEX_HOME"
                   r"|error loading default config")
written = 0
out = open(log_path, "a", buffering=1)
for raw in sys.stdin:
    line = ansi.sub("", raw).rstrip()
    if not line.strip():
        continue
    level = "INFO"
    for token in ("ERROR", "WARN", "DEBUG", "TRACE"):
        if (" " + token + " ") in line[:80]:
            level = token if token != "TRACE" else "DEBUG"
            break
    if AUTH.search(line):
        open(auth_marker, "w").close()
    if FATAL.search(line):
        open(fatal_marker, "w").write(line[:500])
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    print("%s %-5s [codex] %s" % (ts, level, line), flush=True)
    out.write(line + "\n")
    written += 1
    if written % 500 == 0 and os.path.getsize(log_path) > 4_000_000:
        out.close()
        os.replace(log_path, log_path + ".1")
        out = open(log_path, "a", buffering=1)
' "$1" "${AUTH_ERROR_MARKER}" "${FATAL_MARKER}"
}

# ---------------------------------------------------------------------------
# Bridge watcher (background).
#
# The child survives a permanently broken bridge, so process liveness is not
# health. Probe remoteControl/status/read and translate:
#   connected            -> connected        (healthy)
#   connecting           -> connecting       (healthy; it retries on its own)
#   errored/disabled     -> connecting until CODEX_BRIDGE_GRACE has passed,
#                           then bridge-errored (unhealthy, and visible in
#                           `docker ps`) — but never an automatic relaunch:
#                           the server is already retrying on a 30s-capped
#                           sawtooth and a restart only resets that.
# An auth-flavoured failure escalates to a re-login instead; a long errored
# streak can optionally bounce the child once (CODEX_BRIDGE_RESTART_MINUTES).
# ---------------------------------------------------------------------------
# Escalate to a re-login only when the auth failure belongs to THIS outage.
# Scoping is done by CLEARING the marker in two places rather than by
# comparing timestamps: every launch (so a marker always belongs to the
# current app-server) and every connected probe (so a transient 401 during a
# healthy run cannot reclassify a later network outage as a dead login).
# An mtime gate would be wrong here — the auth error is logged seconds BEFORE
# the probe first observes the outage it explains.
auth_escalation_due() {
  auth_ok || return 0
  [[ -f "${AUTH_ERROR_MARKER}" ]]
}

bridge_watch_loop() {
  local interval="${CODEX_PROBE_INTERVAL}"
  local grace="${CODEX_BRIDGE_GRACE}"
  local restart_after=$(( CODEX_BRIDGE_RESTART_MINUTES * 60 ))
  # down_since drives the grace window (any non-connected status);
  # errored_since drives the bounce timer, so a long 'connecting' spell cannot
  # pre-age it and make the first errored probe trigger an instant restart.
  local down_since=0 errored_since=0 announced=0 last="" rc payload now status
  while true; do
    zzz "${interval}"
    [[ -f "${PID_FILE}" ]] || continue
    set +e
    payload="$(codex-rc-status --json 2>/dev/null)"
    rc=$?
    set -e
    [[ -n "${payload}" ]] || payload='{}'
    printf '%s\n' "${payload}" > "${BRIDGE_FILE}" 2>/dev/null || true
    now="$(date +%s)"
    case "${rc}" in
      0) status=connected ;;
      3) status=connecting ;;
      4) status=errored ;;
      5) status=disabled ;;
      2) status=no-socket ;;
      *) status=probe-failed ;;
    esac
    [[ "${status}" != "${last}" ]] && debug "bridge status: ${status} ${payload}"

    case "${status}" in
      connected)
        if [[ "${last}" != "connected" ]]; then
          log "Remote control CONNECTED as '$(jq -r '.serverName // "?"' <<< "${payload}" 2>/dev/null)' (environment $(jq -r '.environmentId // "none"' <<< "${payload}" 2>/dev/null))."
          [[ -n "${last}" ]] && notify bridge-connected "Codex remote control reconnected."
        fi
        down_since=0
        errored_since=0
        announced=0
        # A connected bridge retires both escalation inputs: the latched auth
        # marker and the crash-loop streak the healthcheck reads.
        rm -f "${AUTH_ERROR_MARKER}"
        printf '0' > "${FAIL_STREAK_FILE}" 2>/dev/null || true
        set_state connected
        ;;

      connecting)
        (( down_since == 0 )) && down_since="${now}"
        errored_since=0
        set_state connecting
        ;;

      errored|disabled)
        (( down_since == 0 )) && down_since="${now}"
        (( errored_since == 0 )) && errored_since="${now}"
        if (( now - down_since < grace )); then
          set_state connecting
        elif auth_escalation_due; then
          error "Bridge is ${status} and the login is not usable (auth: $(auth_describe)); re-login required."
          request_restart "auth failure — re-login"
          down_since=0; errored_since=0; announced=0
        else
          set_state bridge-errored
          if (( announced == 0 )); then
            warn "Bridge is ${status} (auth looks fine) — the app-server keeps retrying; not restarting it."
            notify bridge-errored "Codex remote control is ${status}; this host is offline for the ChatGPT app."
            announced=1
          fi
          if (( restart_after > 0 && now - errored_since >= restart_after )); then
            warn "Bridge has been ${status} for $(( (now - errored_since) / 60 ))m; bouncing the app-server once."
            request_restart "bridge stuck ${status}"
            errored_since="${now}"
            announced=0
          fi
        fi
        ;;

      no-socket|probe-failed)
        # The probe could not READ a status, which is not evidence that the
        # bridge is down: a renamed experimental method breaks the probe, not
        # the server. Flag it so it is visible, never restart on it.
        (( down_since == 0 )) && down_since="${now}"
        errored_since=0
        if (( now - down_since >= grace )); then
          set_state probe-failed
          if (( announced == 0 )); then
            warn "Cannot read the bridge status (${status}) — the app-server may be fine but this container cannot tell."
            warn "  check: docker exec codex codex-rc-status --json"
            notify probe-failed "Codex host: the bridge status probe is failing (${status}); health is unknown."
            announced=1
          fi
        else
          set_state connecting
        fi
        ;;
    esac
    last="${status}"
  done
}

request_restart() {
  local reason="$1" pid
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  # Only claim a restart when there is something to restart: a marker left
  # behind with no child would make the NEXT real crash look intentional and
  # skip its backoff.
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    touch "${RESTART_REQUEST_MARKER}"
    log "Restarting the app-server (${reason})."
    kill -TERM "${pid}" 2>/dev/null || true
    # SIGTERM is a graceful DRAIN that waits for running assistant turns; a
    # turn wedged by the phone would otherwise block the main loop's `wait`
    # forever. Escalate in the background.
    (
      local waited=0
      while (( waited < CODEX_RESTART_KILL_TIMEOUT )); do
        kill -0 "${pid}" 2>/dev/null || exit 0
        sleep 5
        waited=$(( waited + 5 ))
      done
      if kill -0 "${pid}" 2>/dev/null; then
        printf '%s WARN  [supervisor] drain exceeded %ss; killing pid %s\n' \
          "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${CODEX_RESTART_KILL_TIMEOUT}" "${pid}" >&9
        kill -KILL "${pid}" 2>/dev/null || true
      fi
    ) &
  else
    debug "restart requested (${reason}) with no running app-server; ignoring."
  fi
}

# ---------------------------------------------------------------------------
# Update check (background).
#
# Running the app-server directly means there is NO self-updater (that is a
# `remote-control start` daemon feature, and one that swaps the binary under a
# live session). The image is the normal update path:
#     docker compose build --pull && docker compose up -d
# With CODEX_AUTO_UPDATE=1 the supervisor instead installs new releases into
# the persisted volume and bounces the server. Old releases are pruned: each
# one is ~324MB and the installer never cleans up.
# ---------------------------------------------------------------------------
updater_loop() {
  local interval_h="${CODEX_UPDATE_INTERVAL_HOURS:-12}"
  [[ "${interval_h}" == "0" ]] && { log "Update checks disabled."; return 0; }
  local interval_s=$(( interval_h * 3600 ))
  local latest installed
  while true; do
    zzz "${interval_s}"
    latest="$(curl -m 20 -fsSL https://releases.openai.com/codex/channels/latest 2>/dev/null \
              | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    installed="$(codex_version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    [[ -z "${latest}" || -z "${installed}" || "${latest}" == "${installed}" ]] && continue
    if [[ "${CODEX_AUTO_UPDATE:-0}" != "1" ]]; then
      log "Codex ${latest} is available (running ${installed}); rebuild to take it:"
      log "  cd ${HOST_STACK_DIR:-/docker/codex} && docker compose build --pull && ./recreate.sh"
      notify update-available "Codex ${latest} available (running ${installed})."
      continue
    fi
    log "Installing Codex ${latest} into ${CODEX_HOME} (auto-update)."
    # NOTE: ensure_shim/hash -r below only affect THIS subshell; the main
    # loop re-runs both before every launch, which is what actually makes the
    # new binary take effect.
    if CODEX_NON_INTERACTIVE=true CODEX_INSTALL_DIR=/root/.local/bin \
       CODEX_RELEASE="${latest}" bash -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh' >/dev/null 2>&1; then
      ensure_shim
      # The installer keeps every release it ever downloaded (~324MB each).
      # Keep the two newest so a broken release can be rolled back by
      # re-pointing `current`, rather than re-downloading blind.
      local stale
      stale="$(ls -1dt "${CODEX_HOME}"/packages/standalone/releases/*/ 2>/dev/null | tail -n +3 || true)"
      [[ -n "${stale}" ]] && rm -rf ${stale} 2>/dev/null || true
      log "Updated to $(codex_version); restarting the app-server."
      request_restart "codex ${latest}"
    else
      warn "auto-update to ${latest} failed; staying on ${installed}."
    fi
  done
}

# ---------------------------------------------------------------------------
# One-time setup
# ---------------------------------------------------------------------------
set_state starting
log "Starting Codex remote-control container (uid $(id -u), host '$(hostname)')."

seed_state_dirs
ensure_shim
seed_config
cd "${WORKSPACE_DIR}" 2>/dev/null || cd /

[[ -n "${GIT_USER_NAME:-}"  ]] && git config --global user.name  "${GIT_USER_NAME}"
[[ -n "${GIT_USER_EMAIL:-}" ]] && git config --global user.email "${GIT_USER_EMAIL}"

if docker version >/dev/null 2>&1; then
  log "Host Docker socket is reachable."
else
  warn "host Docker socket is not reachable."
fi

log "Codex version: $(codex_version)"
# The phone identifies this host by name; the name is the container hostname,
# and there is no flag or env var to override it. installation_id is the
# device identity that must survive recreation — a new one means re-pairing.
log "Device name: $(hostname)  installation_id: $(cat "${CODEX_HOME}/installation_id" 2>/dev/null || echo '<none yet>')"

# ---------------------------------------------------------------------------
# Supervisor
# ---------------------------------------------------------------------------
CHILD_PID=""
WATCH_PID=""
UPDATER_PID=""
SHUTTING_DOWN=0

on_shutdown() {
  SHUTTING_DOWN=1
  log "Shutdown signal received; stopping the app-server..."
  [[ -n "${WATCH_PID}"   ]] && kill "${WATCH_PID}"   2>/dev/null || true
  [[ -n "${UPDATER_PID}" ]] && kill "${UPDATER_PID}" 2>/dev/null || true
  if [[ -n "${CHILD_PID}" ]] && kill -0 "${CHILD_PID}" 2>/dev/null; then
    # The app-server handles SIGTERM (SigCgt includes 15) and drains.
    kill -TERM "${CHILD_PID}" 2>/dev/null || true
    for _ in $(seq 1 60); do
      kill -0 "${CHILD_PID}" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "${CHILD_PID}" 2>/dev/null || true
  fi
  exit 143
}
trap on_shutdown TERM INT

bridge_watch_loop &
WATCH_PID=$!
updater_loop &
UPDATER_PID=$!

BACKOFF_MIN="${RECONNECT_BACKOFF_MIN:-5}"
BACKOFF_MAX="${RECONNECT_BACKOFF_MAX:-180}"
backoff="${BACKOFF_MIN}"
fail_streak=0

while true; do
  if [[ -f "${FATAL_MARKER}" ]]; then
    # e.g. /etc/codex/requirements.toml forbids remote control, or the config
    # fails to load: every relaunch would exit in under a second forever.
    set_state fatal
    error "Fatal configuration error — parked, not restarting:"
    error "  $(head -c 300 "${FATAL_MARKER}")"
    notify fatal "Codex host parked on a fatal config error: $(head -c 200 "${FATAL_MARKER}")"
    while [[ -f "${FATAL_MARKER}" ]]; do zzz 60; done
    log "Fatal marker cleared; resuming."
  fi

  ensure_auth
  wait_for_network
  wait_for_socket_free

  # Pick up a binary the updater may have installed since the last launch
  # (its own `hash -r` ran in a subshell), and make sure the component the
  # whole health design rests on is still alive.
  ensure_shim
  hash -r
  if [[ -z "${WATCH_PID}" ]] || ! kill -0 "${WATCH_PID}" 2>/dev/null; then
    [[ -n "${WATCH_PID}" ]] && warn "bridge watcher died; restarting it."
    bridge_watch_loop &
    WATCH_PID=$!
  fi

  # Scope the auth classifier to this child: anything the previous one logged
  # has already been acted on.
  rm -f "${AUTH_ERROR_MARKER}"
  started_at="$(date +%s)"
  set +e
  codex app-server --remote-control --listen unix:// \
    > >(relay "${CODEX_LOG}.out" >&9) 2> >(relay "${CODEX_LOG}" >&9) &
  CHILD_PID=$!
  set -e
  echo "${CHILD_PID}" > "${PID_FILE}"
  set_state running
  log "app-server started (pid ${CHILD_PID}); probing the bridge every ${CODEX_PROBE_INTERVAL:-30}s."

  set +e
  wait "${CHILD_PID}"
  status=$?
  set -e
  CHILD_PID=""
  rm -f "${PID_FILE}"
  duration=$(( $(date +%s) - started_at ))

  [[ "${SHUTTING_DOWN}" == "1" ]] && exit 143

  zzz 1   # let the relays flush

  if [[ -f "${RESTART_REQUEST_MARKER}" ]]; then
    rm -f "${RESTART_REQUEST_MARKER}"
    log "Supervisor-initiated restart; relaunching immediately."
    backoff="${BACKOFF_MIN}"
    continue
  fi

  if [[ "${status}" != "0" ]]; then
    warn "app-server exited (status ${status}) after ${duration}s."
  else
    log "app-server exited cleanly after ${duration}s."
  fi

  # Consecutive fast crashes are what the healthcheck escalates on: every
  # backoff cycle refreshes the state file, so staleness alone never catches
  # a crash loop.
  if [[ "${status}" != "0" ]] && (( duration < 60 )); then
    fail_streak=$(( fail_streak + 1 ))
  else
    fail_streak=0
  fi
  printf '%s' "${fail_streak}" > "${FAIL_STREAK_FILE}"

  (( duration >= 300 )) && backoff="${BACKOFF_MIN}"

  set_state backoff
  log "Restarting in ${backoff}s..."
  zzz "${backoff}"
  backoff=$(( backoff * 2 ))
  (( backoff > BACKOFF_MAX )) && backoff="${BACKOFF_MAX}"
done
