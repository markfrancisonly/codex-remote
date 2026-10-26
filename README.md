# codex — OpenAI Codex remote control, containerized

A permanent Codex host for this Docker host: one container that runs 24/7,
connects outbound to ChatGPT, and shows up in the ChatGPT mobile app as a
device you can drive. It is the Codex counterpart to `/docker/claude`
([claude-code-remote](https://github.com/markfrancisonly/claude-code-remote)),
and deliberately mirrors its shape — supervisor
entrypoint, state file, healthcheck, sibling-handoff recreate — while
differing everywhere Codex actually behaves differently.

The container runs as root and mounts the Docker socket, which is
root-equivalent on the host. Same trust posture as the claude hub.

```
codex/
├── compose.yaml          # the container
├── compose.override.yaml # optional, gitignored: this host's extra mounts/labels
├── Dockerfile            # ubuntu + docker CLI + the managed standalone Codex
├── entrypoint.sh         # supervisor: auth, launch, bridge watch, classify
├── healthcheck.sh        # docker healthcheck (state machine aware)
├── codex-rc-status.py    # bridge status probe (installed as codex-rc-status)
├── codex-login.sh        # guided device-code sign-in (installed as codex-login)
├── codex-pair.sh         # mint a pairing code + wait for the claim (installed as codex-pair)
├── recreate.sh           # apply compose/.env changes via sibling handoff
├── build.sh              # build against a RESOLVED release (see Updating)
├── .env / .env.example   # configuration
├── .github/workflows/    # CI: checks, image build, publish to GHCR
└── data/codex/           # $CODEX_HOME — auth, config.toml, sqlite state
```

## First deployment

```bash
cd /docker/codex
docker compose up -d          # pulls the published image (./build.sh builds it)
docker logs -f codex          # prints the sign-in URL + one-time code
```

Sign in with a **ChatGPT account** (Plus/Pro/Business/Edu/Enterprise). Open
<https://auth.openai.com/codex/device>, enter the code, done — the container
picks the login up within ~30s with no restart. Each code dies after 15
minutes; a fresh one is minted automatically for the first
`CODEX_DEVICE_LOGIN_CYCLES` (default 4, i.e. one hour), and every new code is
pushed to `CODEX_NOTIFY_URL` if you set it. After that the container parks
with an hourly reminder rather than polling OpenAI forever — `codex-login`
mints a code on demand at any time.

To get a code on demand:

```bash
docker exec -it codex codex-login
```

Then pair your phone. The bridge must already be **connected** (pairing talks
to the enrolled server and fails with *"pairing is unavailable until
enrollment completes"* while the host is signing in or offline):

```bash
docker exec -it codex codex-pair
```

That prints a code like `T8JT-BAC2` (valid ~10 minutes) and then **waits until
a client actually claims it**, polling `remoteControl/pairing/status` — so a
failed attempt is diagnosed on the host instead of by staring at the phone.

On the phone: ChatGPT app → **Remote** (that is the entry's name — there is no
"Codex" item) → add / pair a device → **Pair manually** → enter the code.
If **Remote** is not in the app at all, update ChatGPT from the App Store
first; the docs are explicit that the entry is absent on older builds.

The Mac/Windows ChatGPT desktop app can also be a *client* of this host via
`Settings > Connections > Control other devices` where that feature has rolled
out; a host never appears in any client's list until that client has paired.

OpenAI's documented path is scanning a QR from the **desktop app**, which
this host is not; the manual code is the CLI's equivalent and is what the
`codex remote-control pair` command exists for. See *Known limits*.

Auth and device identity persist in `./data/codex` across restarts,
recreations and image rebuilds.

**Auth gotchas:**

- **Device-code sign-in is off by default on the ChatGPT account.** The first
  attempt lands on *"Enable device code authorization for Codex in ChatGPT
  Security Settings, then run `codex login --device-auth` again."* Flip that
  toggle once (ChatGPT → Settings → Security), then take a fresh code — the
  one that hit the wall is dead. `docker exec codex pkill -f device-auth`
  makes the supervisor mint a new one within seconds.

- **API keys do not work.** Remote control is ChatGPT-product infrastructure
  (`wss://chatgpt.com/backend-api/wham/remote/control/server`), and the
  transport refuses anything else: *"remote control requires ChatGPT
  authentication; API key auth is not supported"*. The app-server even builds
  its auth manager with the API-key env path disabled.
- Never add `CODEX_API_KEY`, `OPENAI_API_KEY` or `CODEX_ACCESS_TOKEN` to the
  `environment:` block. (`.env` alone is harmless — compose.yaml forwards an
  explicit allow-list, not the whole file.) The first two are ignored on the
  remote-control path but poison other `codex` invocations; `CODEX_ACCESS_TOKEN`
  with a non-token value breaks the CLI outright (`invalid agent identity JWT
  format`).
- `codex login status` exits **0 for an API-key login too**, so it is not a
  valid readiness gate. The supervisor checks the content of
  `auth.json` instead (`auth_mode == "chatgpt"` with a refresh token, or a
  personal access token).
- `codex login --with-api-key` **destroys an existing ChatGPT login** silently
  and with no network validation — it rewrites `auth.json` and drops the
  tokens. Don't run it in this container.
- There is no hard grant lifetime to warn about (unlike claude.ai's ~30-day
  `refreshTokenExpiresAt`): the access-token JWT is refreshed 5 minutes before
  its `exp`, the refresh token rotates, and `auth.json` carries no expiry
  field at all. If the grant is ever revoked, the bridge starts failing and
  the supervisor escalates to `login-required` on its own.

## What it supervises, and why (design)

`codex app-server --remote-control --listen unix://` — the same server
`codex remote-control start` would daemonize, run in the foreground as the
supervisor's only child.

| Alternative | Why not |
|---|---|
| `codex remote-control` (the wrapper) | Exits 1 in ~300ms whenever the bridge is not already up (`ensure_remote_control_startable` bails on `Errored`), so a naive restart loop spins at ~3Hz. It also hides its socket in `/tmp/codex-rc-*/`, where `codex remote-control pair` and the healthcheck can't reach it. |
| `codex remote-control start` (daemon) | Forks and returns an exit code that lies in both directions (exit 1 with a healthy daemon; exit 0 with `"timedOut":true`). Requires the managed standalone tree inside `CODEX_HOME`, and spawns `pid-update-loop`, an hourly updater that re-runs the installer and swaps the binary under a live session. |

The consequence that shapes everything else: **the child staying alive tells
you nothing about the bridge.** Codex's characteristic failure is a server
that runs happily for days while permanently disconnected. So the supervisor
actively probes and reports:

| State | Meaning | Health |
|---|---|---|
| `connected` | `remoteControl/status/read` says connected | healthy |
| `connecting` | retrying (or inside the grace window) | healthy |
| `running` | process up, not yet probed | healthy |
| `starting` / `auth-check` / `network-wait` / `backoff` | transitional, healthy while fresh (<300s) | healthy |
| `bridge-errored` | disconnected past `CODEX_BRIDGE_GRACE`, auth is fine | **unhealthy** |
| `login-required` | no usable ChatGPT grant (or the backend rejected it) | **unhealthy** |
| `probe-failed` | the status probe itself stopped working (socket gone, or the experimental method moved) — health is *unknown*, so it is reported, never restarted on | **unhealthy** |
| `fatal` | managed policy forbids remote control, or config won't load | **unhealthy** |

Independently, ≥5 consecutive fast exits report `crash-looping`.

### The health probe

The app-server's control socket is a **WebSocket server on an AF_UNIX
socket**, not line-delimited JSON-RPC: raw newline JSON gets the connection
closed with zero bytes, and `codex app-server proxy` — the one command that
advertises exactly this job — relays bytes without framing (broken in
0.154.0). So `codex-rc-status` does the HTTP/1.1 Upgrade by hand and sends
masked text frames:

```bash
docker exec codex codex-rc-status          # connected (server=codex-docker ...)
docker exec codex codex-rc-status --json   # the raw payload
```

Exit codes: `0` connected, `3` connecting, `4` errored, `5` disabled, `2` no
socket, `1` protocol error. `remoteControl/status/read` is gated behind the
`experimentalApi` capability, and the whole surface is flagged experimental —
so the **image build asserts** that the method and its status enum still exist
before shipping. That assertion is the reason to prefer rebuilding over
`CODEX_AUTO_UPDATE=1`.

`codex doctor` is deliberately not used: it is seconds-slow, and its auth
check goes green on the mere presence of a bogus `OPENAI_API_KEY`.

### Sandboxing

Codex sandboxes commands with bubblewrap, which needs unprivileged user
namespaces — a normal Docker container has none. Measured: `read-only` and
`workspace-write` fail **every** command with `bwrap: No permissions to create
a new namespace`, and cannot reach the Docker socket even with
`writable_roots` set. Only `danger-full-access` works, because it skips bwrap
entirely.

So first boot seeds `data/codex/config.toml` with
`sandbox_mode = "danger-full-access"`, `approval_policy = "on-request"`
(Codex asks; your phone approves), `cli_auth_credentials_store = "file"` (no
OS keyring exists in a container) and `[projects."/docker"] trust_level =
"trusted"` so project-local Codex config loads without a TUI trust prompt.
That is the honest description of this container anyway: root, with the host
Docker socket.

Only `on-request`, `on-failure` and `never` are valid approval policies. The
other names Codex's own error message lists (`untrusted`, `granular`) fail to
load as bare strings — and since the file is seeded once, a bad value wedges a
fresh volume in the login loop until you edit it by hand.

The file is **never rewritten** afterwards — Codex appends its own
`[projects."…"]` trust entries, and a connected client can rewrite keys via
`config/value/write`. If you want a policy the phone cannot override, put it
in a root-owned `/etc/codex/requirements.toml` baked into the image — but note
that an over-strict or malformed one makes *every* codex invocation fail at
startup (the supervisor classifies that as `fatal` and parks instead of
crash-looping).

## Persistence: what the phone remembers

`./data/codex` must survive, or every paired client has to re-pair:

- `auth.json` — the login itself (mode 0600)
- `installation_id` — the device identity sent on every connect; regenerated
  if deleted
- `state_5.sqlite` (+`-wal`/`-shm`) — holds `remote_control_enrollments`
  (`websocket_url`, `account_id`, `server_id`, `environment_id`, …). The
  hostname is **not** part of the primary key, so renaming the container does
  not orphan the enrollment
- `config.toml`, `skills/`

The supervisor logs the device name and `installation_id` at every boot — a
changed installation id is the signal that pairing is about to break.

## Operations cheat-sheet

```bash
docker logs -f codex                          # supervisor + app-server logs
docker ps                                     # unhealthy = needs you (see the state table)
docker exec codex codex-rc-status             # bridge status, ~20ms
docker exec -it codex codex-login             # sign in / re-sign in, live
docker exec -it codex codex-login --force     # replace a working login
docker exec -it codex codex-pair              # pairing code for a new client, waits for the claim
docker exec codex cat /run/codex/state        # supervisor state
docker exec codex cat /run/codex/state-history
docker exec codex cat /run/codex/bridge-status
docker exec codex tail -50 /run/codex/codex.log
docker exec -it codex bash                    # a shell next to the agent
docker exec codex sqlite3 /root/.codex/logs_2.sqlite \
  "select datetime(ts,'unixepoch'), level, feedback_log_body from logs \
   where target like '%remote_control%' order by id desc limit 20"
```

`bridge-status`, `codex.log`, `codex-rc-status` and `codex-pair` all
need a running app-server, so they are absent or fail while the supervisor is
parked in `login-required` or `fatal`. `state`, `state-history` and the sqlite
log survive everything.

## Recovery playbook

**`login-required`** — the supervisor has no usable ChatGPT grant, so there is
**no app-server running at all**: `codex-rc-status` and `codex remote-control
pair` both fail until this clears, which is expected. Read the code from
`docker logs codex` (or your webhook) and use it, or run
`docker exec -it codex codex-login` for a fresh one. Nothing needs restarting.

If the supervisor escalated here from a *working* login it thought was
rejected, it restores the previous credential automatically when nobody signs
in, and retries with it — so a false alarm heals itself rather than leaving
you locked out.

**`bridge-errored`** — the login is fine but the host cannot reach ChatGPT.
The app-server is already retrying on its own (30s-capped sawtooth), so the
supervisor deliberately does **not** restart it; it bounces it once after
`CODEX_BRIDGE_RESTART_MINUTES`. Check `docker exec codex codex-rc-status
--json`, then egress to `chatgpt.com`, then OpenAI status. Nothing to do
locally in most cases.

**`probe-failed`** — the container cannot read its own status. Usually the
experimental JSON-RPC method moved in a Codex release. Rebuild (`./build.sh`)
— the build asserts the method exists and will fail loudly instead.

**Re-pairing a phone** — pairing survives recreation as long as
`./data/codex` does. If `installation_id` changes (it is regenerated when
deleted), every client must pair again: `docker exec -it codex codex-pair`.

## Updating

```bash
cd /docker/codex
docker compose pull && ./recreate.sh    # the published image
./build.sh && ./recreate.sh             # or build it here
```

`build.sh` resolves the newest Codex release and passes it as a build arg.
Plain `docker compose build --pull` is **not** enough on its own: with
`CODEX_VERSION=latest` the install layer has a constant cache key, so the
build is a no-op and the image keeps shipping the release it was first built
with.

The supervisor checks the release channel every `CODEX_UPDATE_INTERVAL_HOURS`
and logs (and pushes) when a newer release exists. `CODEX_AUTO_UPDATE=1`
installs into `./data/codex` instead and bounces the app-server — convenient,
but it skips the build-time schema assertion and each release is ~324MB (old
ones are pruned).

## The image

CI publishes the image to the GitHub Container Registry for linux/amd64 and
linux/arm64, built against the newest Codex release, once the script checks,
the build-time schema assertion and a smoke test of the built image pass:

| Tag | Points at |
|---|---|
| `latest` | the newest build of `main` or of a stable release, rebuilt every Monday against the newest Codex release |
| `sha-<commit>` | one exact commit; it never moves |
| `1.2.3`, `1.2`, `1` | the release tag `v1.2.3` |

`compose.yaml` pulls `ghcr.io/markfrancisonly/codex-remote`, tagged by
`DOCKER_CODEX_IMAGE_TAG` in `.env` (default `latest`).

## Applying config changes from inside a session

Recreating this container from a Codex session running *inside* it would kill
compose mid-recreate, so `./recreate.sh` hands `docker compose up -d` to a
sibling container. Run from anywhere else (including the claude hub) it just
runs compose directly. The sibling is kept after it exits, so a failed
recreate can be read with `docker logs codex-recreate`.

Note that every `CODEX_`-prefixed knob in `.env` is prefixed on purpose:
compose interpolates from the environment of whatever *invokes* it, and the
claude hub exports `HOST_STACK_DIR`, `NETWORK_PROBE_URL` and
`RECONNECT_BACKOFF_*` into its own container — deploying this stack from a hub
session originally pointed the network probe at `api.anthropic.com` and the
recreate handoff at `/docker/claude`.

## Known limits

- **`codex remote-control` is experimental** and `--remote-control` is a
  hidden flag; OpenAI's published docs describe Remote hosts as the macOS and
  Windows desktop apps, with Linux reached over SSH *from* such a host. A
  Linux CLI host is not a documented configuration, so a release can change
  or withdraw it. The build-time schema assertion is the tripwire.
- Pairing a phone to this host relies on `codex remote-control pair`'s manual
  code and the app's **Pair manually** entry. Verified working from the
  ChatGPT iOS app on 2026-09-15 (claimed in seconds, the phone was listing
  models through the host moments later) — but it is undocumented by OpenAI
  and lives on an experimental surface, so a release could withdraw it.
- Codex's sandbox is off (see above). Anything the phone approves runs as root
  with the host Docker socket.
- Codex's own `logs_2.sqlite` under `./data/codex` grows with use and has no
  documented cap; the supervisor bounds only its own `/run/codex/codex.log`.
  Worth a glance if the stack directory ever looks large.

## License

MIT — see [LICENSE](LICENSE).
