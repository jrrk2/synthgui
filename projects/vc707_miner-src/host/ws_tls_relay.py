#!/usr/bin/env python3
"""ws_tls_relay.py [listen_port] [upstream_host] -- let mine_daemon (plain ws://,
no TLS) talk to a public kaspad wRPC JSON node that is only reachable as wss://.

Listens on 127.0.0.1:<listen_port> (18210), rewrites the HTTP Host header of
each WebSocket handshake to <upstream_host>, opens TLS to <upstream_host>:443
and relays bytes both ways.  Point mine_daemon at
  ws://127.0.0.1:18210/kaspa/testnet-10/wrpc/json
for upstream vector-10.kaspa.green (any node the public resolver lists for
testnet-10: https://eric.kaspa.stream/v2/kaspa/testnet-10/tls/wrpc/borsh gives
one; the same node serves /wrpc/json).
"""
import socket
import ssl
import sys
import threading

port = int(sys.argv[1]) if len(sys.argv) > 1 else 18210
upstream = sys.argv[2] if len(sys.argv) > 2 else "vector-10.kaspa.green"
ctx = ssl.create_default_context()


def pump(src, dst):
    try:
        while True:
            b = src.recv(65536)
            if not b:
                break
            dst.sendall(b)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(c):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = c.recv(4096)
        if not chunk:
            c.close()
            return
        buf += chunk
    head, rest = buf.split(b"\r\n\r\n", 1)
    lines = [l for l in head.split(b"\r\n") if not l.lower().startswith(b"host:")]
    lines.insert(1, b"Host: " + upstream.encode())
    u = ctx.wrap_socket(socket.create_connection((upstream, 443), timeout=30), server_hostname=upstream)
    u.settimeout(None)
    u.sendall(b"\r\n".join(lines) + b"\r\n\r\n" + rest)
    print(f"relay: {lines[0].decode(errors='replace')} -> {upstream}", flush=True)
    threading.Thread(target=pump, args=(u, c), daemon=True).start()
    pump(c, u)


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(8)
print(f"relay: ws://127.0.0.1:{port} -> wss://{upstream}", flush=True)
while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
