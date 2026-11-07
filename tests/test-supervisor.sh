#!/usr/bin/env bash
# Run the real supervisor loop with a fake CLI; never touch live state or Docker.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
supervisor_pid=""
cleanup() {
  if [[ -n "${supervisor_pid}" ]]; then
    kill -TERM "${supervisor_pid}" 2>/dev/null || true
    wait "${supervisor_pid}" 2>/dev/null || true
  fi
  rm -rf "${work}"
}
trap cleanup EXIT

# Skip first-boot setup; leave the entire production supervision loop intact.
python3 - "${repo_dir}/entrypoint.sh" "${work}/supervisor.sh" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
anchor = 'CHILD_PID=""\nWATCH_PID=""\n'
assert source.count(anchor) == 1
loop = anchor + source.split(anchor, 1)[1]
for unsafe in ('${HOME}', '${CODEX_HOME}', '/root/', '/run/codex'):
    assert unsafe not in loop, 'Supervisor now accesses real state: ' + unsafe
Path(sys.argv[2]).write_text(loop)
PY

cat > "${work}/cli-stub.sh" <<'STUB'
set -euo pipefail
n=$(cat "${TEST_SUPERVISOR_WORK}/launch-count" 2>/dev/null || echo 0)
n=$(( n + 1 ))
printf '%s' "${n}" > "${TEST_SUPERVISOR_WORK}/launch-count"
printf '%s\n' "$@" > "${TEST_SUPERVISOR_WORK}/args-${n}"
[[ ! -f "${TEST_SUPERVISOR_WORK}/state/auth-error" ]] || {
  touch "${TEST_SUPERVISOR_WORK}/stale-auth-seen"
  exit 99
}
case "${TEST_SUPERVISOR_CASE}:${n}" in
  crashes:[1-5]) exit 17 ;;
  fatal:1)
    printf 'fixture config failure' > "${TEST_SUPERVISOR_WORK}/state/fatal"
    exit 17
    ;;
  requested:1)
    touch "${TEST_SUPERVISOR_WORK}/state/restart-request"
    exit 0
    ;;
esac
trap 'printf TERM > "${TEST_SUPERVISOR_WORK}/cli-signal"; exit 0' TERM
: > "${TEST_SUPERVISOR_WORK}/cli-ready"
while true; do
  sleep 0.02 &
  wait $! || true
done
STUB

run_supervisor() {
  STATE_DIR="${TEST_SUPERVISOR_WORK}/state"
  PID_FILE="${STATE_DIR}/codex.pid"
  AUTH_ERROR_MARKER="${STATE_DIR}/auth-error"
  FATAL_MARKER="${STATE_DIR}/fatal"
  RESTART_REQUEST_MARKER="${STATE_DIR}/restart-request"
  FAIL_STREAK_FILE="${STATE_DIR}/fail-streak"
  CODEX_LOG="${STATE_DIR}/codex.log"
  RECONNECT_BACKOFF_MIN=1
  RECONNECT_BACKOFF_MAX=4
  log() { printf '%s\n' "$*"; }
  warn() { log "$@"; }
  error() { log "$@"; }
  notify() { :; }
  ensure_auth() { :; }
  wait_for_network() { :; }
  wait_for_socket_free() { :; }
  ensure_shim() { :; }
  updater_loop() { :; }
  bridge_watch_loop() {
    local n
    n=$(cat "${TEST_SUPERVISOR_WORK}/watcher-count" 2>/dev/null || echo 0)
    n=$(( n + 1 ))
    printf '%s' "${n}" > "${TEST_SUPERVISOR_WORK}/watcher-count"
    # The first watcher dies; the supervisor must replace it on a later launch.
    (( n == 1 )) && return 0
    while true; do sleep 0.02 & wait $! || true; done
  }
  set_state() {
    printf '%s' "$1" > "${STATE_DIR}/state"
    printf '%s\n' "$1" >> "${STATE_DIR}/history"
  }
  zzz() { sleep 0.02 & wait $! || true; }
  relay() { cat; }
  codex() { exec bash "${work}/cli-stub.sh" "$@"; }
  exec 9>&1
  source "${work}/supervisor.sh"
}

wait_for() {
  local file="$1" expected="${2:-}"
  for _ in {1..500}; do
    if [[ -e "${file}" ]] && { [[ -z "${expected}" ]] || [[ "$(cat "${file}")" == "${expected}" ]]; }; then
      return 0
    fi
    kill -0 "${supervisor_pid}" 2>/dev/null || break
    sleep 0.02
  done
  cat "${TEST_SUPERVISOR_WORK}/supervisor.log" >&2
  echo "Timed out waiting for ${file}" >&2
  return 1
}

for scenario in crashes fatal requested; do
  export TEST_SUPERVISOR_CASE="${scenario}"
  export TEST_SUPERVISOR_WORK="${work}/${scenario}"
  mkdir -p "${TEST_SUPERVISOR_WORK}/state" "${TEST_SUPERVISOR_WORK}/data"
  printf 'fixture identity\n' > "${TEST_SUPERVISOR_WORK}/data/installation_id"
  printf 'fixture enrollment state\n' > "${TEST_SUPERVISOR_WORK}/data/state.sqlite"
  sha256sum "${TEST_SUPERVISOR_WORK}/data/"* > "${TEST_SUPERVISOR_WORK}/before.sha256"
  touch "${TEST_SUPERVISOR_WORK}/state/auth-error"
  run_supervisor > "${TEST_SUPERVISOR_WORK}/supervisor.log" 2>&1 &
  supervisor_pid=$!
  if [[ "${scenario}" == fatal ]]; then
    wait_for "${TEST_SUPERVISOR_WORK}/state/state" fatal
    [[ "$(cat "${TEST_SUPERVISOR_WORK}/launch-count")" == 1 ]]
    sleep 0.1
    [[ "$(cat "${TEST_SUPERVISOR_WORK}/launch-count")" == 1 ]]
    rm "${TEST_SUPERVISOR_WORK}/state/fatal"
  fi
  wait_for "${TEST_SUPERVISOR_WORK}/cli-ready"
  kill -TERM "${supervisor_pid}"
  status=0
  wait "${supervisor_pid}" || status=$?
  supervisor_pid=""
  [[ "${status}" == 143 ]]
  [[ "$(cat "${TEST_SUPERVISOR_WORK}/cli-signal")" == TERM ]]
  [[ ! -e "${TEST_SUPERVISOR_WORK}/stale-auth-seen" ]]
  [[ "$(cat "${TEST_SUPERVISOR_WORK}/watcher-count")" -ge 2 ]]
  printf '%s\n' app-server --remote-control --listen unix:// > "${work}/expected-args"
  for args in "${TEST_SUPERVISOR_WORK}"/args-*; do diff -u "${work}/expected-args" "${args}"; done
  sha256sum -c "${TEST_SUPERVISOR_WORK}/before.sha256" > /dev/null
  case "${scenario}" in
    crashes)
      [[ "$(cat "${TEST_SUPERVISOR_WORK}/launch-count")" == 6 ]]
      [[ "$(cat "${TEST_SUPERVISOR_WORK}/state/fail-streak")" == 5 ]]
      printf '%s\n' 'Restarting in 1s...' 'Restarting in 2s...' \
        'Restarting in 4s...' 'Restarting in 4s...' 'Restarting in 4s...' > "${work}/expected-backoff"
      grep '^Restarting in ' "${TEST_SUPERVISOR_WORK}/supervisor.log" > "${work}/actual-backoff"
      diff -u "${work}/expected-backoff" "${work}/actual-backoff"
      printf 'PASS: crashes back off to the cap and preserve server arguments and state\n'
      ;;
    fatal)
      [[ "$(cat "${TEST_SUPERVISOR_WORK}/launch-count")" == 2 ]]
      printf 'PASS: fatal errors park until cleared, then recover\n'
      ;;
    requested)
      [[ "$(cat "${TEST_SUPERVISOR_WORK}/launch-count")" == 2 ]]
      ! grep -q '^Restarting in ' "${TEST_SUPERVISOR_WORK}/supervisor.log"
      grep -q '^Supervisor-initiated restart;' "${TEST_SUPERVISOR_WORK}/supervisor.log"
      printf 'PASS: intentional restarts relaunch without crash backoff\n'
      ;;
  esac
  printf 'PASS: %s restores a dead watcher, clears stale auth errors, and forwards SIGTERM\n' "${scenario}"
done
