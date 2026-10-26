#!/usr/bin/env bash
# codex-login — guided ChatGPT sign-in for the container, from the host:
#
#   docker exec -it codex codex-login
#
# Runs the device-code flow and prints the URL and one-time code on their own
# lines (the CLI's own output wraps them in ANSI and a wall of text, which is
# painful to copy out of a terminal). Safe to run while the container is live:
# the app-server reloads auth on every connect attempt, so a completed login
# is picked up within ~30s with no restart and no recreate.
set -uo pipefail

case "${1:-}" in
  -h|--help)
    echo "usage: codex-login [--force]   # guided ChatGPT device-code sign-in"
    echo "  --force   replace a working login instead of reporting it"
    exit 0
    ;;
esac

CODEX_HOME="${CODEX_HOME:-/root/.codex}"
AUTH_FILE="${CODEX_HOME}/auth.json"

auth_ok() {
  jq -e '(.auth_mode == "chatgpt" and ((.tokens.refresh_token // "") | length) > 0)
         or ((.personal_access_token // "") | length) > 0' \
     "${AUTH_FILE}" >/dev/null 2>&1
}

# Refusing on auth_ok alone would refuse in exactly the state this command is
# advertised for: a stored grant that LOOKS fine but that the backend has
# rejected. Only skip when the bridge is actually connected.
bridge_connected() { codex-rc-status >/dev/null 2>&1; }

if auth_ok && bridge_connected && [[ "${1:-}" != "--force" ]]; then
  echo "Already signed in and the bridge is connected ($(codex login status 2>&1 | head -1))."
  echo "Use 'codex-login --force' to replace the login anyway."
  exit 0
fi

if auth_ok; then
  echo "A stored ChatGPT login exists but the bridge is not connected — signing in again."
  echo "(Your current credential is restored automatically if you do not finish.)"
fi

out="$(mktemp)"
trap 'rm -f "${out}"' EXIT

codex login --device-auth </dev/null >"${out}" 2>&1 &
pid=$!

code=""
for _ in $(seq 1 30); do
  code="$(sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "${out}" 2>/dev/null \
          | grep -Eo '[A-Z0-9]{4}-[A-Z0-9]{5}' | head -1 || true)"
  [[ -n "${code}" ]] && break
  kill -0 "${pid}" 2>/dev/null || break
  sleep 1
done

if [[ -z "${code}" ]]; then
  echo "Could not read a device code. Raw output:"
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "${out}"
  wait "${pid}" 2>/dev/null
  exit 1
fi

cat <<EOF_MSG

==============================================
  Sign in to Codex with your ChatGPT account
==============================================

  1. open   https://auth.openai.com/codex/device
  2. enter  ${code}

  (the code expires in 15 minutes)

Waiting for you to finish... Ctrl-C is safe; the container keeps working.

EOF_MSG

# Poll beside the login process: it also releases if the code was completed
# from another attempt.
while kill -0 "${pid}" 2>/dev/null; do
  if auth_ok; then
    sleep 3
    kill "${pid}" 2>/dev/null || true
    break
  fi
  sleep 5
done
wait "${pid}" 2>/dev/null

if auth_ok; then
  echo "Signed in: $(codex login status 2>&1 | head -1)"
  echo "The remote-control bridge picks this up within ~30s — watch it with:"
  echo "  docker exec codex codex-rc-status"
  exit 0
fi

echo "Sign-in did not complete."
sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "${out}" | tail -5
exit 1
