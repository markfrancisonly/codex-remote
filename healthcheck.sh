#!/usr/bin/env bash
# Container healthcheck for the Codex remote-control supervisor.
#
# The supervisor (entrypoint.sh) records its state in /run/codex/state and the
# app-server's pid in /run/codex/codex.pid.
#
#   healthy   - the bridge is connected, or the supervisor is in a
#               short-lived transitional state that has been refreshed
#               recently (starting/auth-check/network-wait/backoff/
#               running/connecting).
#   unhealthy - login required, bridge errored past its grace window, a
#               status probe that stopped working, a fatal config error, a
#               crash loop, or a stale/missing state.
#
# Deliberately NOT built on `codex doctor` (seconds-slow, and its auth check
# goes green on a bogus env var) and not on `kill -0` alone: a SIGTERM'd
# app-server reparented to a non-reaping PID 1 lingers as a zombie, and
# `kill -0` keeps reporting success for it.
set -uo pipefail

STATE_DIR=/run/codex
STATE_FILE="${STATE_DIR}/state"
PID_FILE="${STATE_DIR}/codex.pid"

MAX_TRANSIENT_AGE=300
# `connected` is written by the bridge watcher on every probe, so a stale one
# means the watcher itself stopped — the healthcheck is the only thing that
# can notice that.
probe_interval="${CODEX_PROBE_INTERVAL:-30}"
[[ "${probe_interval}" =~ ^[0-9]+$ ]] || probe_interval=30
MAX_CONNECTED_AGE=$(( probe_interval * 4 ))
(( MAX_CONNECTED_AGE < 120 )) && MAX_CONNECTED_AGE=120

[[ -f "${STATE_FILE}" ]] || { echo "no state file"; exit 1; }
state="$(cat "${STATE_FILE}" 2>/dev/null || true)"

child_alive() {
  local pid
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] || return 1
  [[ -r "/proc/${pid}/stat" ]] || return 1
  # Field 3 is the process state; Z means it exited and only the supervisor's
  # `wait` has not reaped it yet.
  [[ "$(awk '{print $3}' "/proc/${pid}/stat" 2>/dev/null)" != "Z" ]]
}

crash_looping() {
  local streak
  streak="$(cat "${STATE_DIR}/fail-streak" 2>/dev/null || echo 0)"
  [[ "${streak}" =~ ^[0-9]+$ ]] && (( streak >= 5 ))
}

case "${state}" in
  connected)
    if ! child_alive; then
      echo "state=connected but the app-server process is gone"
      exit 1
    fi
    now="$(date +%s)"
    mtime="$(stat -c %Y "${STATE_FILE}" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    if (( age >= MAX_CONNECTED_AGE )); then
      echo "state=connected but not refreshed for ${age}s (bridge watcher stalled)"
      exit 1
    fi
    echo "connected ($(jq -r '.serverName // "?"' "${STATE_DIR}/bridge-status" 2>/dev/null || echo '?'))"
    exit 0
    ;;
  running|connecting|starting|auth-check|network-wait|backoff)
    if crash_looping; then
      echo "crash-looping: $(cat "${STATE_DIR}/fail-streak") consecutive fast exits (state: ${state})"
      exit 1
    fi
    now="$(date +%s)"
    mtime="$(stat -c %Y "${STATE_FILE}" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    if (( age < MAX_TRANSIENT_AGE )); then
      echo "${state} (${age}s)"
      exit 0
    fi
    echo "stale transitional state: ${state} (${age}s)"
    exit 1
    ;;
  probe-failed)
    echo "cannot read the bridge status: $(cat "${STATE_DIR}/bridge-status" 2>/dev/null || echo unknown)"
    exit 1
    ;;
  bridge-errored)
    echo "remote control is not connected: $(cat "${STATE_DIR}/bridge-status" 2>/dev/null || echo unknown)"
    exit 1
    ;;
  login-required)
    echo "login required: docker exec -it codex codex-login"
    exit 1
    ;;
  fatal)
    echo "parked on a fatal config error: $(head -c 200 "${STATE_DIR}/fatal" 2>/dev/null)"
    exit 1
    ;;
  *)
    echo "unknown state: ${state}"
    exit 1
    ;;
esac
