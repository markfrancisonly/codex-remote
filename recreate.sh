#!/usr/bin/env bash
# recreate.sh — apply staged compose/.env changes to the codex stack.
#
# Safe to run from inside the claude hub (a different container), but NOT from
# a Codex session running inside this container: recreating yourself kills
# compose mid-recreate. When run in-container the `docker compose up -d` is
# handed to a short-lived detached sibling; the paired ChatGPT host drops and
# comes back in ~30-60s.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Derived, never inherited: HOST_STACK_DIR is an unprefixed name that the
# claude hub also exports, so a hub session's environment would otherwise
# retarget this handoff at the wrong stack.
HOST_STACK_DIR="${SCRIPT_DIR}"

# Only the codex container itself must hand off; every other container (the
# claude hub included) can drive compose directly.
in_self() { [[ -f /.dockerenv && "$(cat /etc/hostname 2>/dev/null)" == "$(docker inspect codex --format '{{.Config.Hostname}}' 2>/dev/null)" ]]; }

codex_image() {
  local img
  img="$(docker inspect codex --format '{{.Config.Image}}' 2>/dev/null || true)"
  img="${img//[$'\r\n']/}"
  printf '%s' "${img:-markfrancisonly/codex-remote:local}"
}

if in_self; then
  image="$(codex_image)"
  echo "THIS container will be recreated: the paired ChatGPT host drops and"
  echo "reconnects automatically in ~30-60s."
  # Keep the sibling around after it exits: with --rm a failed recreate
  # deletes its own logs and leaves nothing to look at.
  docker rm -f codex-recreate >/dev/null 2>&1 || true
  docker run -d \
    --name codex-recreate \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${HOST_STACK_DIR}:${HOST_STACK_DIR}" \
    -w "${HOST_STACK_DIR}" \
    --entrypoint bash \
    "${image}" \
    -c "sleep 2 && docker compose up -d --remove-orphans" >/dev/null
  echo "Sibling launched (codex-recreate). If the stack does not come back:"
  echo "  docker logs codex-recreate"
else
  ( cd "${SCRIPT_DIR}" && docker compose up -d --remove-orphans )
fi
