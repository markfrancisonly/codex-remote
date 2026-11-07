#!/usr/bin/env bash
# Run the real healthcheck against isolated state and this test's process.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
export TEST_HEALTH_STATE="${work}/state"
export CODEX_PROBE_INTERVAL=30
mkdir -p "${TEST_HEALTH_STATE}"
python3 - "${repo_dir}/healthcheck.sh" "${work}/healthcheck.sh" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
assert source.count('STATE_DIR=/run/codex') == 1
Path(sys.argv[2]).write_text(source.replace(
    'STATE_DIR=/run/codex', 'STATE_DIR="${TEST_HEALTH_STATE}"'))
PY

check() {
  local expected="$1" message="$2" actual=0
  bash "${work}/healthcheck.sh" > "${work}/result" 2>&1 || actual=$?
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL: %s (exit %s, expected %s)\n' "${message}" "${actual}" "${expected}" >&2
    cat "${work}/result" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "${message}"
}
state() { printf '%s' "$1" > "${TEST_HEALTH_STATE}/state"; }
check 1 'missing supervisor state is unhealthy'
printf '%s' "$$" > "${TEST_HEALTH_STATE}/codex.pid"
printf '{"serverName":"test-host"}\n' > "${TEST_HEALTH_STATE}/bridge-status"
state connected
check 0 'fresh connected state with a live child is healthy'
touch -d '5 minutes ago' "${TEST_HEALTH_STATE}/state"
check 1 'a stale connected state detects a stopped bridge watcher'
CODEX_PROBE_INTERVAL=120
check 0 'freshness follows the configured probe interval'
CODEX_PROBE_INTERVAL=30
state connected
: > "${TEST_HEALTH_STATE}/codex.pid"
check 1 'connected state cannot hide a missing child'
printf '%s' "$$" > "${TEST_HEALTH_STATE}/codex.pid"
state backoff
printf '4' > "${TEST_HEALTH_STATE}/fail-streak"
check 0 'a short recovery interval remains healthy'
printf '5' > "${TEST_HEALTH_STATE}/fail-streak"
check 1 'repeated fast crashes are unhealthy despite fresh state'
printf '0' > "${TEST_HEALTH_STATE}/fail-streak"
state connecting
touch -d '6 minutes ago' "${TEST_HEALTH_STATE}/state"
check 1 'a stale transitional state is unhealthy'
for value in login-required fatal probe-failed bridge-errored unknown; do
  state "${value}"
  check 1 "${value} is unhealthy"
done
