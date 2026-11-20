#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$HostDaemon,
    [string]$RoomToken = "",
    [string]$RoomPassword = "",
    [string]$DeviceName = "",
    [string]$ServerAddr = "",
    [string]$LocalDev = "",
    [string]$ConfigPath = "",
    [string]$ExePath = (Join-Path $env:LOCALAPPDATA "Programs\VNT\v2.0.11\vnt2_cli.exe"),
    [string]$CtrlPath = (Join-Path $env:LOCALAPPDATA "Programs\VNT\v2.0.11\vnt2_ctrl.exe"),
    [string]$LogDir = "C:\Users\Public\VNT_Logs",
    [switch]$Once
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "..\config\vnt2.json" }

if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $RoomToken)    { $RoomToken = $cfg.room }
        if (-not $RoomPassword) { $RoomPassword = $cfg.password }
        if (-not $ServerAddr)   { $ServerAddr = $cfg.server }
    } catch {}
}
if (-not $RoomToken)  { $RoomToken = "峡谷模拟联机群" }
if (-not $ServerAddr) { $ServerAddr = "quic://154.23.172.117:29872" }

$LOG_FILE         = Join-Path $LogDir "vnt2_room_daemon.log"
$ERR_LOG_FILE     = Join-Path $LogDir "vnt2_room_daemon.err.log"
$MONITOR_PID_FILE = Join-Path $LogDir "vnt2_room_monitor.pid"
$DAEMON_PID_FILE  = Join-Path $LogDir "vnt2_room_daemon.pid"
$STATE_FILE       = Join-Path $LogDir "vnt2_monitor_state.json"

function Disable-ConsoleQuickEdit {
    try {
        $code = @"
using System;
using System.Runtime.InteropServices;
public static class Vnt2ConsoleHelper {
    [DllImport("kernel32.dll")] private static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] private static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] private static extern bool SetConsoleMode(IntPtr h, uint m);
    public static void DisableQuickEdit() {
        IntPtr h = GetStdHandle(-10); uint m;
        if (GetConsoleMode(h, out m)) { SetConsoleMode(h, (m & ~0x0040u) | 0x0080u); }
    }
}
"@
        Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
        [Vnt2ConsoleHelper]::DisableQuickEdit()
    } catch {}
}

function Invoke-QuickVnt2Ctrl([string]$SubCmd) {
    if (-not (Test-Path -LiteralPath $CtrlPath)) { return "" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $CtrlPath
    $psi.Arguments = $SubCmd
    $psi.WorkingDirectory = (Split-Path -Parent $CtrlPath)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start()
        $out = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(3000)) {
            try { $p.Kill() } catch {}
            return ""
        }
        return ($out -replace '\x1b\[[0-?]*[ -/]*[@-~]', '').Trim()
    } catch {
        return ""
    } finally {
        $p.Dispose()
    }
}

function Parse-MarkdownTable([string]$TableText, [int]$MinCols) {
    $rows = @()
    if (-not $TableText) { return $rows }
    foreach ($line in ($TableText -split '\r?\n')) {
        $cols = @(($line -split '\|') | ForEach-Object { $_.Trim() })
        if ($cols.Count -ge $MinCols -and $cols[1] -match '^\d+\.\d+\.\d+\.\d+$') {
            $rows += ,$cols
        }
    }
    return $rows
}

New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction SilentlyContinue | Out-Null

if (-not $Once) {
    Disable-ConsoleQuickEdit
    try {
        $Host.UI.RawUI.WindowTitle = "🟢 VNT 联机监控台 - $RoomToken [关闭本窗口即自动断开联机]"
        $b = $Host.UI.RawUI.BufferSize
        if ($b.Width -lt 96) { $b.Width = 96; $Host.UI.RawUI.BufferSize = $b }
        $w = $Host.UI.RawUI.WindowSize
        if ($w.Width -lt 96) { $w.Width = 96 }
        if ($w.Height -lt 32) { $w.Height = 32 }
        $Host.UI.RawUI.WindowSize = $w
    } catch {}
    $PID | Set-Content -LiteralPath $MONITOR_PID_FILE -Encoding ASCII -Force
}

$vntProc = $null
if ($HostDaemon) {
    "" | Set-Content -LiteralPath $LOG_FILE -Encoding UTF8 -Force
    "" | Set-Content -LiteralPath $ERR_LOG_FILE -Encoding UTF8 -Force

    $argList = @("--network-code", "`"$RoomToken`"")
    if ($RoomPassword) { $argList += @("--password", "`"$RoomPassword`"") }
    if ($DeviceName)   { $argList += @("--name", "`"$DeviceName`"") }
    if ($LocalDev)     { $argList += @("--outbound-interface", "`"$LocalDev`"") }
    if ($ServerAddr)   { $argList += @("--server", "`"$ServerAddr`"") }
    $argList += @("--device-mode", "tun", "--tun-name", "vnt-tun")
    $argString = $argList -join ' '

    $vntWork = Split-Path -Parent $ExePath
    $vntProc = Start-Process -FilePath $ExePath `
        -ArgumentList $argString `
        -WorkingDirectory $vntWork `
        -WindowStyle Hidden `
        -RedirectStandardOutput $LOG_FILE `
        -RedirectStandardError $ERR_LOG_FILE `
        -PassThru

    $vntProc.Id | Set-Content -LiteralPath $DAEMON_PID_FILE -Encoding ASCII -Force

    $psFullExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $watchCode = "Wait-Process -Id $PID -ErrorAction SilentlyContinue; Stop-Process -Id $($vntProc.Id) -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath '$MONITOR_PID_FILE','$DAEMON_PID_FILE' -Force -ErrorAction SilentlyContinue"
    $watchB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($watchCode))
    Start-Process -FilePath $psFullExe -ArgumentList "-NoProfile -WindowStyle Hidden -EncodedCommand $watchB64" -WindowStyle Hidden | Out-Null
} else {
    $vntProc = Get-Process -Name "vnt2_cli" -ErrorAction SilentlyContinue | Select-Object -First 1
}

$pinger = New-Object System.Net.NetworkInformation.Ping

try {
    while ($true) {
        if ($HostDaemon -and $vntProc -and $vntProc.HasExited) { break }
        if (-not $Once) {
            try {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq [ConsoleKey]::Q) { break }
                }
            } catch {}
        }

        $infoOut    = Invoke-QuickVnt2Ctrl "info"
        $clientsOut = Invoke-QuickVnt2Ctrl "clients"
        $routeOut   = Invoke-QuickVnt2Ctrl "route"

        $devName   = if ($infoOut -match '(?m)^Name:[ \t]*([^\r\n]+)') { $matches[1].Trim() } else { $env:COMPUTERNAME }
        $vip       = if ($infoOut -match '(?m)^IP:[ \t]*([^\r\n]+)') { $matches[1].Trim() } else { "分配中..." }
        $srvLine   = if ($infoOut -match '(?m)^Server:[ \t]*([^\r\n]+)') { $matches[1].Trim() } else { $ServerAddr }
        $natType   = if ($infoOut -match '(?m)^Nat Type:[ \t]*([^\r\n]+)' -and $matches[1].Trim() -notin @('Unknown','')) { $matches[1].Trim() } else { "探测中" }
        $pubIp     = if ($infoOut -match '(?m)^Public Ipv4:[ \t]*([^\r\n]+)' -and $matches[1].Trim() -ne '') { $matches[1].Trim() } else { "探测中" }
        $isOnline  = ($srvLine -match '\(Online')
        $connStatus = if ($isOnline) { "Connected" } else { "Connecting" }
        $srvRt     = if ($srvLine -match '\(Online\s+(\d+)\s*ms\)') { $matches[1] } else { "-" }

        $peerRows  = @(Parse-MarkdownTable $clientsOut 10)
        $routeRows = @(Parse-MarkdownTable $routeOut 5)

        $onlinePeersCount = @($peerRows | Where-Object { $_[5] -eq 'true' }).Count
        $totalPeople  = 1 + $peerRows.Count
        $onlinePeople = 1 + $onlinePeersCount

        if (-not $Once) {
            try {
                $Host.UI.RawUI.WindowTitle = "🟢 VNT 联机中 [$vip | 在线 ${onlinePeople}人] - $RoomToken (关闭本窗口即自动断开联机)"
            } catch {}
            try { [Console]::Clear() } catch {}
        }

        Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "║  🎮  VNT 峡谷模拟联机群 · 实时联机状态监控台 (VNT 2.0)                       ║" -ForegroundColor Yellow
        Write-Host "║  🛑  【重要提示】直接关闭本窗口 (点击右上角 × 或按 Q / Ctrl+C)               ║" -ForegroundColor Red
        Write-Host "║      即可【自动断开联机】并卸载虚拟网卡！联机期间请保持本窗口开启(可最小化)  ║" -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
        Write-Host ""

        $connBadge = if ($connStatus -eq 'Connected') { "🟢 已连接 (Connected)" } else { "🟡 连接中 ($connStatus)" }
        $srvSignal = if ($srvRt -match '^\d+$' -and [int]$srvRt -lt 80) {
            "▂▄▆█ 极佳 (${srvRt}ms)"
        } elseif ($srvRt -match '^\d+$' -and [int]$srvRt -lt 200) {
            "▂▄▆_ 良好 (${srvRt}ms)"
        } elseif ($srvRt -match '^\d+$') {
            "▂▄__ 一般 (${srvRt}ms)"
        } else {
            "▂▄__ (${srvRt})"
        }

        Write-Host "  🏠 房间名称 : $RoomToken      🔐 房间密码 : $(if($RoomPassword){$RoomPassword}else{'无密码'})" -ForegroundColor Cyan
        Write-Host "  👥 房间人数 : 当前在线 $onlinePeople 人 / 房间共 $totalPeople 人 (本机 + $onlinePeersCount 位在线队友)" -ForegroundColor Green
        Write-Host "  📶 本机状态 : $connBadge   |   主干信号 : $srvSignal" -ForegroundColor White
        Write-Host "  🖥️ 本机节点 : $vip ($devName)   |   NAT类型 : $natType   |   物理出口 : $(if($LocalDev){$LocalDev}else{'自动'}) ($pubIp)" -ForegroundColor Gray
        Write-Host "  🌐 联机服务 : $srvLine" -ForegroundColor Gray
        Write-Host "────────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  📡 【房间队友状态与信号质量】" -ForegroundColor Cyan

        if ($peerRows.Count -eq 0) {
            Write-Host "     ⏳ 当前房间暂无其他队友，等待队友使用房间名「$RoomToken」与密码「$RoomPassword」加入..." -ForegroundColor Yellow
        } else {
            foreach ($row in $peerRows) {
                $pIp     = $row[1]
                $pName   = $row[2]
                $pVer    = $row[4]
                $pOnline = ($row[5] -eq 'true')
                $pP2p    = ($row[6] -eq 'true')
                $pRt     = $row[7]
                $pLoss   = $row[8]

                $rMatch = @($routeRows | Where-Object { $_[1] -eq $pIp } | Select-Object -First 1)
                $rEndpoint = if ($rMatch.Count -gt 0) { $rMatch[0][4] } else { "" }

                if ($pOnline) {
                    $modeStr = if ($pP2p) { "⚡ P2P直连" } else { "🔄 服务器中继" }
                    $pingStr = ""
                    try {
                        $pr = $pinger.Send($pIp, 400)
                        if ($pr.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                            $pingStr = " | Ping: $($pr.RoundtripTime)ms"
                        }
                    } catch {}

                    $sigStr = if ($pRt -match '^\d+$') {
                        $rtVal = [int]$pRt
                        if ($rtVal -ge 9000) { "🟢 ▂▄▆█ 测速中..." }
                        elseif ($rtVal -lt 60) { "🟢 ▂▄▆█ 极佳 (${rtVal}ms${pingStr})" }
                        elseif ($rtVal -lt 130) { "🟢 ▂▄▆_ 良好 (${rtVal}ms${pingStr})" }
                        elseif ($rtVal -lt 200) { "🟡 ▂▄__ 一般 (${rtVal}ms${pingStr})" }
                        else { "🔴 ▂___ 高延迟 (${rtVal}ms${pingStr})" }
                    } else {
                        "探测中...${pingStr}"
                    }
                    Write-Host ("     🟢 [在线] {0,-15} 虚拟IP: {1,-11} 模式: {2,-10} 信号: {3}" -f $pName, $pIp, $modeStr, $sigStr) -ForegroundColor Green
                    if ($rEndpoint) {
                        Write-Host ("               └─ 物理通道: {0} (版本 {1}, 丢包 {2})" -f $rEndpoint, $pVer, $pLoss) -ForegroundColor DarkGray
                    }
                } else {
                    Write-Host ("     ⚪ [离线] {0,-15} 虚拟IP: {1,-11} 状态: 离线 (最后在线: {2})" -f $pName, $pIp, $row[9]) -ForegroundColor DarkGray
                }
            }
        }

        Write-Host "────────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  📜 【VNT2-CLI 底层连接与路由日志】" -ForegroundColor Cyan
        $hasFileLogs = $false
        if (Test-Path -LiteralPath $LOG_FILE) {
            $logs = @(Get-Content -LiteralPath $LOG_FILE -Encoding UTF8 -Tail 80 -ErrorAction SilentlyContinue |
                Where-Object { $_.Trim() -ne '' -and $_ -notmatch 'IPC Connection from 127\.0\.0\.1' } |
                Select-Object -Last 5)
            if ($logs.Count -gt 0) {
                $hasFileLogs = $true
                foreach ($l in $logs) {
                    $cleanLine = ($l -replace '\x1b\[[0-?]*[ -/]*[@-~]', '').Trim()
                    if ($cleanLine -match 'Connected|Registration|succeeded|nat_type|Online') {
                        Write-Host "     $cleanLine" -ForegroundColor Green
                    } elseif ($cleanLine -match 'WARN|ERROR|failed') {
                        Write-Host "     $cleanLine" -ForegroundColor Yellow
                    } else {
                        Write-Host "     $cleanLine" -ForegroundColor DarkGray
                    }
                }
            }
        }
        if (-not $hasFileLogs) {
            Write-Host "     connect server=$ServerAddr | tun=vnt-tun | virtual_ip=$vip" -ForegroundColor DarkGray
            if ($connStatus -eq 'Connected') {
                Write-Host "     register ip=$vip, netmask=255.255.255.0, gateway=10.26.0.1  ====== Connect Successfully ======" -ForegroundColor Green
            }
        }
        if ($routeRows.Count -gt 0) {
            foreach ($rr in ($routeRows | Select-Object -First 3)) {
                Write-Host ("     [Route] 目标: {0} | 跳数(Metric): {1} | RTT: {2}ms | 端点: {3}" -f $rr[1], $rr[2], $rr[3], $rr[4]) -ForegroundColor DarkGray
            }
        }

        Write-Host "════════════════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        Write-Host "  ⏱️ 实时刷新: $(Get-Date -Format 'HH:mm:ss') (每 2 秒自动更新)  |  👉 按 [Q] 键或关闭右上角 [×] 立即断开联机" -ForegroundColor Yellow

        [pscustomobject]@{
            process_id  = $PID
            daemon_pid  = if ($vntProc) { $vntProc.Id } else { $null }
            connected   = $isOnline
            virtual_ip  = $vip
            server      = $srvLine
            online_peers = $onlinePeersCount
            updated_at  = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $STATE_FILE -Encoding UTF8 -Force

        if ($Once) { break }
        Start-Sleep -Seconds 2
        if ($vntProc) { $vntProc.Refresh() }
    }
} finally {
    $pinger.Dispose()
    if (-not $Once) {
        if ($vntProc -and -not $vntProc.HasExited) {
            try { Stop-Process -Id $vntProc.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
        Get-Process -Name "vnt2_cli" -ErrorAction SilentlyContinue | ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
        Remove-Item -LiteralPath $MONITOR_PID_FILE, $DAEMON_PID_FILE -Force -ErrorAction SilentlyContinue
    }
}
