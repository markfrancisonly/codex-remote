#!/usr/bin/env python3
"""Report the Codex remote-control bridge status.

The app-server's control socket is a WebSocket server on an AF_UNIX socket
(tokio-tungstenite `accept_hdr_async`), NOT line-delimited JSON-RPC: raw
newline JSON gets the connection closed with zero bytes, and
`codex app-server proxy` relays bytes without framing (broken in 0.154.0).
So do the HTTP/1.1 Upgrade by hand, then send masked text frames.

Exit codes (the healthcheck and the supervisor both branch on these):
  0 connected   3 connecting   4 errored   5 disabled
  2 socket absent / not listening      1 protocol error or timeout
"""
import base64
import json
import os
import socket
import sys
import time

CODEX_HOME = os.environ.get("CODEX_HOME", "/root/.codex")
SOCK = os.environ.get("CODEX_RC_SOCK") or os.path.join(
    CODEX_HOME, "app-server-control", "app-server-control.sock"
)
try:
    TIMEOUT = float(os.environ.get("CODEX_RC_TIMEOUT", "10"))
except ValueError:
    TIMEOUT = 10.0
# A frame length is attacker-or-bug controlled; cap it rather than buffering
# whatever the header claims.
MAX_FRAME = 8 * 1024 * 1024

STATUS_EXIT = {"connected": 0, "connecting": 3, "errored": 4, "disabled": 5}


class Conn:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(TIMEOUT)
        self.sock.connect(path)
        self.buf = b""
        # settimeout() is per-operation and is reset by every byte that
        # arrives, so a server that chatters without ever answering could
        # block the probe indefinitely — and the probe runs inside the
        # supervisor's only state-refreshing loop. Bound the whole exchange.
        self.deadline = time.monotonic() + TIMEOUT

    def _fill(self):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("probe deadline exceeded")
        self.sock.settimeout(left)
        chunk = self.sock.recv(65536)
        if not chunk:
            raise EOFError("server closed the connection")
        self.buf += chunk

    def handshake(self):
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            "GET / HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n".encode()
        )
        while b"\r\n\r\n" not in self.buf:
            self._fill()
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        if b"101" not in head.split(b"\r\n")[0]:
            raise IOError("no websocket upgrade: %s" % head.split(b"\r\n")[0])

    def send(self, obj):
        self.send_frame(0x1, json.dumps(obj).encode())

    def send_frame(self, opcode, payload):
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        n = len(payload)
        first = 0x80 | opcode
        if n < 126:
            header = bytes([first, 0x80 | n])
        elif n < 65536:
            header = bytes([first, 0xFE]) + n.to_bytes(2, "big")
        else:
            header = bytes([first, 0xFF]) + n.to_bytes(8, "big")
        self.sock.sendall(header + mask + masked)

    def _take(self, n):
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv_frame(self):
        """Return (opcode, payload, fin) for one frame."""
        b0, b1 = self._take(2)
        fin = bool(b0 & 0x80)
        opcode = b0 & 0x0F
        length = b1 & 0x7F
        if length == 126:
            length = int.from_bytes(self._take(2), "big")
        elif length == 127:
            length = int.from_bytes(self._take(8), "big")
        if length > MAX_FRAME:
            raise IOError("frame too large: %d bytes" % length)
        mask = self._take(4) if b1 & 0x80 else None
        data = self._take(length)
        if mask:
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        return opcode, data, fin

    def recv_message(self):
        """Reassemble one complete message, answering control frames."""
        opcode, data, fin = self.recv_frame()
        while opcode == 0x9:  # ping -> pong, or the peer may drop us mid-probe
            self.send_frame(0xA, data)
            opcode, data, fin = self.recv_frame()
        if opcode == 0x8:
            raise IOError("server closed before answering")
        if opcode == 0xA:
            return None
        while not fin:
            cont_op, cont_data, fin = self.recv_frame()
            if cont_op == 0x9:
                self.send_frame(0xA, cont_data)
                fin = False
                continue
            if cont_op not in (0x0,):
                raise IOError("unexpected opcode %d mid-message" % cont_op)
            data += cont_data
        return data if opcode in (0x1, 0x2) else None

    def close(self):
        # Without a close frame the server logs "websocket receive error:
        # Connection reset by peer" on every single healthcheck.
        try:
            mask = os.urandom(4)
            self.sock.sendall(bytes([0x88, 0x80]) + mask)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


def read_status(conn):
    """Return the RemoteControlStatusReadResponse payload."""
    conn.send(
        {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {"name": "codex-rc-status", "version": "1"},
                # remoteControl/status/read is gated on this capability;
                # without it the server answers -32600.
                "capabilities": {"experimentalApi": True},
            },
        }
    )
    conn.send({"method": "initialized", "params": {}})
    conn.send({"id": 2, "method": "remoteControl/status/read"})

    fallback = None
    while True:
        data = conn.recv_message()
        if data is None:
            continue
        text = data.decode("utf-8", "replace")
        # The transport frames one JSON object per line, but a frame may carry
        # several (or a pretty-printed one) — try the whole payload first.
        chunks = []
        try:
            chunks = [json.loads(text)]
        except ValueError:
            for line in text.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    chunks.append(json.loads(line))
                except ValueError:
                    continue
        for msg in chunks:
            if not isinstance(msg, dict):
                continue
            if msg.get("id") == 2:
                result = msg.get("result")
                if isinstance(result, dict):
                    return result
                if "result" in msg:
                    raise IOError("unexpected result shape: %r" % (result,))
                if fallback:
                    return fallback
                raise IOError(json.dumps(msg.get("error", msg)))
            # Pushed unsolicited right after initialize with the same payload —
            # a usable fallback if the experimental method is ever renamed.
            if msg.get("method") == "remoteControl/status/changed":
                params = msg.get("params")
                if isinstance(params, dict):
                    fallback = params


def main():
    want_json = "--json" in sys.argv
    try:
        conn = Conn(SOCK)
    except (FileNotFoundError, ConnectionRefusedError, PermissionError) as exc:
        out = {"status": "no-daemon", "error": str(exc), "socket": SOCK}
        print(json.dumps(out) if want_json else "no-daemon (%s)" % exc)
        return 2
    except OSError as exc:
        print(json.dumps({"status": "error", "error": str(exc)}) if want_json else str(exc))
        return 1

    try:
        conn.handshake()
        payload = read_status(conn)
    except (OSError, EOFError, ValueError, TimeoutError) as exc:
        print(json.dumps({"status": "error", "error": str(exc)}) if want_json else "probe failed: %s" % exc)
        return 1
    finally:
        conn.close()

    status = payload.get("status", "unknown")
    if want_json:
        print(json.dumps(payload))
    else:
        print(
            "%s (server=%s installation=%s environment=%s)"
            % (
                status,
                payload.get("serverName"),
                payload.get("installationId"),
                payload.get("environmentId") or "none",
            )
        )
    return STATUS_EXIT.get(status, 1)


if __name__ == "__main__":
    sys.exit(main())
