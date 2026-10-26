#!/usr/bin/env bash
# build.sh — build the image against a RESOLVED Codex release.
#
# Why this exists: with CODEX_VERSION=latest the install layer has a constant
# cache key, so `docker compose build --pull` rebuilds nothing and the image
# keeps shipping whatever release it was FIRST built with — including the
# build-time schema assertion, which then never re-runs. Resolving the version
# here moves the layer key whenever upstream does.
#
#   ./build.sh              # newest release
#   ./build.sh 0.154.0      # a specific one (also: CODEX_VERSION=0.154.0)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
version="${1:-${CODEX_VERSION:-latest}}"

if [[ "${version}" == "latest" ]]; then
  version="$(curl -fsSL https://releases.openai.com/codex/channels/latest \
             | jq -r '.tag_name // empty' \
             | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?' | head -1 || true)"
fi

if [[ -z "${version}" ]]; then
  echo "Could not resolve the latest Codex release; pass one explicitly." >&2
  exit 1
fi

echo "Building codex-remote against Codex ${version}"
cd "${SCRIPT_DIR}"
docker compose build --pull --build-arg "CODEX_VERSION=${version}"
echo
echo "Built. Apply it with:  ./recreate.sh"
