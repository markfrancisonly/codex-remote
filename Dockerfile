# OpenAI Codex remote-control agent for a Docker host.
#
# Design notes (sibling of /docker/claude's Dockerfile, with one deliberate
# inversion):
# - The Codex binary lives in the IMAGE, not in the persisted volume. The
#   managed standalone tree is ~324MB per release and the installer never
#   prunes old ones, and the process this container supervises
#   (`codex app-server --remote-control`) does not need the tree under
#   CODEX_HOME at all — only `codex remote-control start` does. So CODEX_HOME
#   stays pure state (auth.json, installation_id, state_5.sqlite, config.toml)
#   and updates arrive by rebuilding this image. `CODEX_AUTO_UPDATE=1` opts
#   into volume-side self-updates instead; entrypoint.sh re-points the shim.
# - No bubblewrap package: it cannot create user namespaces in a normal
#   container, so installing it only changes the wording of the error. The
#   seeded config.toml uses danger-full-access, which skips bwrap entirely.
# - Runs as root by design: it drives the host Docker daemon via the mounted
#   socket and works in /docker (root-owned on the host).
FROM ubuntu:24.04

# Pins the release baked into the image. `latest` is resolved at build time.
ARG CODEX_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      curl \
      dnsutils \
      git \
      iproute2 \
      iputils-ping \
      jq \
      less \
      nano \
      netcat-openbsd \
      openssh-client \
      procps \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      rsync \
      sqlite3 \
      tree \
      util-linux \
      zsh \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

ENV HOME=/root
# Runtime state (auth, sqlite, config.toml) — bind-mounted from ./data/codex.
ENV CODEX_HOME=/root/.codex
# A volume-side install (CODEX_AUTO_UPDATE=1) shadows the image one; the
# entrypoint creates/removes that shim on every boot.
ENV PATH="/root/.local/bin:${PATH}"

RUN mkdir -p /root/.ssh \
    && ssh-keyscan -t ed25519,rsa github.com >> /root/.ssh/known_hosts 2>/dev/null \
    && chmod 700 /root/.ssh \
    && chmod 644 /root/.ssh/known_hosts

# /docker holds many independent git repos (one per container stack), all
# root-owned host bind mounts — trust them globally.
RUN mkdir -p /root/.codex /docker \
    && git config --system --add safe.directory '*'

# Managed standalone install, into an image path that the CODEX_HOME volume
# can never shadow. CODEX_INSTALL_DIR is already on PATH, so the installer
# skips its shell-rc edit.
RUN CODEX_HOME=/opt/codex-seed \
    CODEX_INSTALL_DIR=/usr/local/bin \
    CODEX_NON_INTERACTIVE=true \
    CODEX_RELEASE="${CODEX_VERSION}" \
    bash -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh' \
    && codex --version

# Build-time assertion: the whole remote-control surface is flagged
# [experimental] and `--remote-control` is a hidden flag, so a version bump can
# rename the method the healthcheck depends on. Fail the build here rather
# than ship a container whose health probe silently reports 'protocol error'.
RUN codex app-server generate-json-schema --experimental --out /tmp/schema \
    && jq -e '[.oneOf[] | .properties.method.enum[0]] | index("remoteControl/status/read")' \
         /tmp/schema/ClientRequest.json >/dev/null \
    && jq -e '.definitions.RemoteControlConnectionStatus.enum | index("connected")' \
         /tmp/schema/v2/RemoteControlStatusReadResponse.json >/dev/null \
    && rm -rf /tmp/schema

COPY entrypoint.sh healthcheck.sh /usr/local/bin/
COPY codex-login.sh /usr/local/bin/codex-login
COPY codex-pair.sh /usr/local/bin/codex-pair
COPY codex-rc-status.py /usr/local/bin/codex-rc-status
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
      /usr/local/bin/codex-login /usr/local/bin/codex-pair /usr/local/bin/codex-rc-status

WORKDIR /docker

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
