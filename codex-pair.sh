#!/usr/bin/env bash
# codex-pair — mint a pairing code for a phone (or another ChatGPT client) and
# WAIT until that client actually claims it, from the host:
#
#   docker exec -it codex codex-pair
#
# `codex remote-control pair` only prints the code; whether the phone's
# "Pair manually" entry worked is otherwise invisible from the host. This
# polls remoteControl/pairing/status until the session is claimed or expires,
# so a failed attempt is diagnosed here instead of by staring at the phone.
set -uo pipefail

case "${1:-}" in
  -h|--help) echo "usage: codex-pair   # mint a pairing code, wait for a client to claim it"; exit 0 ;;
esac

if ! codex-rc-status >/dev/null 2>&1; then
  echo "The bridge is not connected — pairing needs an enrolled, connected host:"
  codex-rc-status
  exit 1
fi

resp="$(codex remote-control pair --json 2>&1)" || { echo "${resp}"; exit 1; }
manual="$(jq -r '.manualPairingCode // empty' <<< "${resp}")"
code="$(jq -r '.pairingCode // empty' <<< "${resp}")"
expires="$(jq -r '.expiresAt // 0' <<< "${resp}")"
[[ -n "${manual}" && -n "${code}" ]] || { echo "unexpected response: ${resp}"; exit 1; }

cat <<EOF_MSG

==============================================
  Pair a device with this host ($(hostname))
==============================================

  ChatGPT app  ->  Remote  ->  add / pair a device  ->  Pair manually

  enter  ${manual}        (valid ~$(( (expires - $(date +%s)) / 60 )) min)

Waiting for a client to claim it... (Ctrl-C is safe)

EOF_MSG

# remoteControl/pairing/status over the control socket, reusing the probe's
# WebSocket client (installed without a .py suffix, hence the loader).
export PAIR_CODE="${code}" PAIR_MANUAL="${manual}"
while (( $(date +%s) < expires )); do
  claimed="$(python3 - <<'PY'
import importlib.machinery, importlib.util, json, os, sys
loader = importlib.machinery.SourceFileLoader("rc", "/usr/local/bin/codex-rc-status")
spec = importlib.util.spec_from_loader("rc", loader)
rc = importlib.util.module_from_spec(spec); loader.exec_module(rc)
try:
    conn = rc.Conn(rc.SOCK); conn.handshake()
    conn.send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "codex-pair", "version": "1"},
                                                          "capabilities": {"experimentalApi": True}}})
    conn.send({"method": "initialized", "params": {}})
    conn.send({"id": 2, "method": "remoteControl/pairing/status",
               # the server accepts ONE of the two identifiers, not both
               "params": {"pairingCode": os.environ["PAIR_CODE"]}})
    while True:
        data = conn.recv_message()
        if data is None: continue
        for line in data.decode("utf-8", "replace").splitlines():
            try: msg = json.loads(line)
            except ValueError: continue
            if msg.get("id") == 2:
                if "result" in msg: print("yes" if msg["result"].get("claimed") else "no")
                else: print("error " + json.dumps(msg.get("error")))
                sys.exit(0)
finally:
    try: conn.close()
    except Exception: pass
PY
)"
  case "${claimed}" in
    yes)
      echo "Claimed — the device is paired with this host."
      exit 0 ;;
    error*)
      echo "Status check failed: ${claimed#error }"
      exit 1 ;;
  esac
  sleep 3
done
echo "The code expired without being claimed. Run codex-pair again for a fresh one."
exit 1
