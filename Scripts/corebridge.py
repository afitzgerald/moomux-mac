#!/usr/bin/env python3
"""Expose a unix-socket core on localhost TCP, for the iPhone simulator.

    python3 Scripts/corebridge.py /tmp/mmx2.sock 8765
    xcrun simctl launch booted app.moomux.Moomux -coreHost 127.0.0.1 -corePort 8765

The core only listens on TCP at the machine's tailnet address, which the real
core already holds, so a scratch core needs this to reach the simulator.
"""
import socket
import sys
import threading

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mmx.sock"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8765


def pipe(src, dst):
    try:
        while data := src.recv(65536):
            dst.sendall(data)
    except OSError:
        # A reset on either side: close both, or the other direction's recv
        # waits forever on a peer that is gone.
        for sock in (src, dst):
            sock.close()
        return
    finally:
        # Half-close only: the client shuts its write side after each request
        # and still reads the reply. Closing both ways drops every response.
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen()
print(f"127.0.0.1:{port} -> {path}", flush=True)
while True:
    client, _ = srv.accept()
    core = socket.socket(socket.AF_UNIX)
    try:
        core.connect(path)
    except OSError as e:
        print(f"can't reach {path}: {e}", flush=True)
        client.close()
        continue
    pair = [threading.Thread(target=pipe, args=(client, core), daemon=True),
            threading.Thread(target=pipe, args=(core, client), daemon=True)]
    for t in pair:
        t.start()

    def close_when_done(pair=pair, socks=(client, core)):
        for t in pair:
            t.join()
        for sock in socks:
            sock.close()

    threading.Thread(target=close_when_done, daemon=True).start()
