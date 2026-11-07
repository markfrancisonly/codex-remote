#!/usr/bin/env bash
# Exercise both recreation paths with Docker fully mocked.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/stack with spaces"
: > "${work}/stack with spaces/compose.yaml"

# Change only self-detection so either path runs on hosts and in containers.
python3 - "${repo_dir}/recreate.sh" "${work}/stack with spaces" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
probes = [line for line in source.splitlines() if line.startswith('in_self() {')]
assert len(probes) == 1
for name, status in [('self', 0), ('other', 1)]:
    Path(sys.argv[2], name + '.sh').write_text(source.replace(
        probes[0], 'in_self() { return ' + str(status) + '; }'))
PY

export TEST_RECREATE_CAPTURE="${work}/calls"
export HOST_STACK_DIR=/srv/unrelated-stack
docker() {
  case "$1" in
    inspect)
      [[ "$2" == codex && "$4" == '{{.Config.Image}}' ]] || return 90
      printf 'codex-image:test\n'
      ;;
    rm)
      [[ "$*" == 'rm -f codex-recreate' ]] || return 91
      printf '%s\n' "$*" >> "${TEST_RECREATE_CAPTURE}.cleanup"
      ;;
    run|compose)
      printf '%s\0' "$@" > "${TEST_RECREATE_CAPTURE}"
      printf '%s' "$PWD" > "${TEST_RECREATE_CAPTURE}.cwd"
      ;;
    *) return 92 ;;
  esac
}
export -f docker
bash "${work}/stack with spaces/self.sh" > "${work}/output"
python3 - "${TEST_RECREATE_CAPTURE}" "${work}/stack with spaces" <<'PY'
from pathlib import Path
import sys
capture, stack = sys.argv[1:]
args = Path(capture).read_bytes().rstrip(b'\0').decode().split('\0')
assert args[:2] == ['run', '-d'], args
assert args[args.index('--name') + 1] == 'codex-recreate', args
assert args[args.index('-w') + 1] == stack, args
assert stack + ':' + stack in args, args
assert '/var/run/docker.sock:/var/run/docker.sock' in args, args
assert 'codex-image:test' in args and '--rm' not in args, args
assert args[-1] == 'sleep 2 && docker compose up -d --remove-orphans', args
assert '/srv/unrelated-stack' not in repr(args), args
assert Path(capture + '.cleanup').read_text() == 'rm -f codex-recreate\n'
PY
printf 'PASS: self-recreation uses the correct stack and keeps sibling logs\n'

rm "${TEST_RECREATE_CAPTURE}.cleanup"
bash "${work}/stack with spaces/other.sh" > "${work}/output"
[[ "$(cat "${TEST_RECREATE_CAPTURE}.cwd")" == "${work}/stack with spaces" ]]
[[ "$(tr '\0' ' ' < "${TEST_RECREATE_CAPTURE}")" == 'compose up -d --remove-orphans ' ]]
[[ ! -e "${TEST_RECREATE_CAPTURE}.cleanup" ]]
printf 'PASS: callers outside Codex use direct Compose and ignore inherited stack paths\n'
