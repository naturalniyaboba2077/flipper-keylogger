# Windows TCP receiver (same protocol as server/receiver.py)
# Run on 89.22.229.54 if the host is Windows:
#   powershell -Ep Bypass -File receiver.ps1

$ErrorActionPreference = 'Stop'
$Port = 4444
$OutDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Live = Join-Path $OutDir 'live.log'

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $Port)
$listener.Start()
Write-Host "listening 0.0.0.0:$Port out=$OutDir"

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $peer = $client.Client.RemoteEndPoint.ToString()
        $stream = $client.GetStream()
        $stream.ReadTimeout = 30000
        $ms = New-Object IO.MemoryStream
        $buf = New-Object byte[] 8192
        try {
            while ($true) {
                $n = 0
                try { $n = $stream.Read($buf, 0, $buf.Length) } catch { break }
                if ($n -le 0) { break }
                $ms.Write($buf, 0, $n)
                if ($ms.Length -gt 1000000) { break }
            }
        } finally {
            try { $stream.Close() } catch {}
            try { $client.Close() } catch {}
        }
        $data = $ms.ToArray()
        if ($data.Length -eq 0) { continue }
        $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
        $safe = ($peer -replace '[:\\]', '_')
        $chunk = Join-Path $OutDir "${ts}_${safe}.txt"
        [IO.File]::WriteAllBytes($chunk, $data)
        $hdr = "`n--- $ts utc from $peer ($($data.Length) bytes) ---`n"
        [IO.File]::AppendAllText($Live, $hdr + [Text.Encoding]::UTF8.GetString($data))
        Write-Host "ok $peer $($data.Length)B"
    }
} finally {
    $listener.Stop()
}
