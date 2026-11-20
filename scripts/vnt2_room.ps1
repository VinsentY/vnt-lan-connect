# ==============================================================================
# VNT2-CLI 峡谷模拟联机群 内网穿透管理与稳定性测试脚本 - Windows 专享版
# （强制系统级 Wintun 虚拟网卡模式，完整复刻 VNT1 控制台与实时联机监控台 UI）
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\vnt2_room.ps1 join [-k "峡谷模拟联机群"] [-w "密码"] [-n "设备昵称"] [-s "服务器地址"]
#   powershell -ExecutionPolicy Bypass -File .\vnt2_room.ps1 precheck
#   powershell -ExecutionPolicy Bypass -File .\vnt2_room.ps1 status
#   powershell -ExecutionPolicy Bypass -File .\vnt2_room.ps1 test
#   powershell -ExecutionPolicy Bypass -File .\vnt2_room.ps1 stop
#   powershell -ExecutionPolicy Bypass -File .\vnt2_room.ps1 install
# ==============================================================================
#requires -Version 5.1
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$CONFIG_PATH = Join-Path $PSScriptRoot "..\config\vnt2.json"
$DEFAULT_ROOM = "峡谷模拟联机群"
$DEFAULT_PASSWORD = "200008"
$DEFAULT_SERVER = "quic://154.23.172.117:29872"
$FALLBACK_SERVER = "tcp://154.23.172.117:29872"
$DEFAULT_SERVER_IP = "154.23.172.117"
$DEFAULT_SERVER_PORT = 29872

if (Test-Path -LiteralPath $CONFIG_PATH) {
    try {
        $cfgObj = Get-Content -LiteralPath $CONFIG_PATH -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfgObj.room)            { $DEFAULT_ROOM = $cfgObj.room }
        if ($cfgObj.password)        { $DEFAULT_PASSWORD = $cfgObj.password }
        if ($cfgObj.server)          { $DEFAULT_SERVER = $cfgObj.server }
        if ($cfgObj.fallback_server) { $FALLBACK_SERVER = $cfgObj.fallback_server }
        if ($cfgObj.server_ip)       { $DEFAULT_SERVER_IP = $cfgObj.server_ip }
        if ($cfgObj.server_port)     { $DEFAULT_SERVER_PORT = [int]$cfgObj.server_port }
    } catch {}
}

$ROOM_TOKEN = $DEFAULT_ROOM
$ROOM_PASSWORD = $DEFAULT_PASSWORD
$DEVICE_NAME = ""
$SERVER_ADDR = ""
$LOCAL_DEV = ""
$VNT2_VERSION = "v2.0.11"
$HIGH_LATENCY_THRESHOLD_MS = 200
$INSTALL_DIR = Join-Path $env:LOCALAPPDATA "Programs\VNT\$VNT2_VERSION"
$LOG_DIR = "C:\Users\Public\VNT_Logs"
$LOG_FILE = Join-Path $LOG_DIR "vnt2_room_daemon.log"
$ERR_LOG_FILE = Join-Path $LOG_DIR "vnt2_room_daemon.err.log"
$MONITOR_PID_FILE = Join-Path $LOG_DIR "vnt2_room_monitor.pid"
$DAEMON_PID_FILE  = Join-Path $LOG_DIR "vnt2_room_daemon.pid"
$NO_WINDOW = $false

$script:VNT2_CLI_BIN  = Join-Path $INSTALL_DIR "vnt2_cli.exe"
$script:VNT2_CTRL_BIN = Join-Path $INSTALL_DIR "vnt2_ctrl.exe"
$script:VNT2_WORK_DIR = $INSTALL_DIR

# ------------------------------------------------------------------------------
# 查找或自动安装 vnt2_cli.exe / vnt2_ctrl.exe 与 wintun.dll
# ------------------------------------------------------------------------------
function Find-Vnt2Bins {
    if ((Test-Path -LiteralPath $script:VNT2_CLI_BIN -PathType Leaf) -and (Test-Path -LiteralPath $script:VNT2_CTRL_BIN -PathType Leaf)) {
        return $true
    }
    return $false
}

function Install-Vnt2Cli {
    $installer = Join-Path $PSScriptRoot "install_vnt2.ps1"
    if (Test-Path -LiteralPath $installer) {
        Write-Host "📦 正在调用 install_vnt2.ps1 检查并安装官方 VNT 2.0.11 与 Wintun 驱动..."
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
        if ($LASTEXITCODE -ne 0) {
            throw "VNT 2.0.11 安装失败。"
        }
    } else {
        throw "未找到安装脚本: $installer"
    }
}

function Invoke-Vnt2Ctrl {
    param([string]$SubCmd)
    if (-not (Find-Vnt2Bins)) {
        throw "未找到 vnt2_ctrl.exe，请先执行 install。"
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:VNT2_CTRL_BIN
    $psi.Arguments = $SubCmd
    $psi.WorkingDirectory = $script:VNT2_WORK_DIR
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        if (-not $proc.WaitForExit(5000)) {
            try { $proc.Kill() } catch {}
            throw "vnt2_ctrl 命令执行超时: $SubCmd"
        }
        $cleanOut = ($stdout -replace '\x1b\[[0-?]*[ -/]*[@-~]', '').Trim()
        $cleanErr = ($stderr -replace '\x1b\[[0-?]*[ -/]*[@-~]', '').Trim()
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Output   = if ($cleanOut) { $cleanOut } else { $cleanErr }
            StdOut   = $cleanOut
            StdErr   = $cleanErr
        }
    } finally {
        $proc.Dispose()
    }
}

# ------------------------------------------------------------------------------
# 检查 Windows 管理员权限与 Wintun 驱动签名
# ------------------------------------------------------------------------------
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-TunPrivilege {
    if (-not (Find-Vnt2Bins)) {
        Install-Vnt2Cli
    }
    $wintunPath = Join-Path $script:VNT2_WORK_DIR "wintun.dll"
    if (-not (Test-Path -LiteralPath $wintunPath -PathType Leaf)) {
        Write-Host "⚠️ 未检测到同目录 wintun.dll，正在补齐驱动..."
        Install-Vnt2Cli
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $wintunPath -ErrorAction SilentlyContinue
    if ($sig -and $sig.Status -eq 'Valid') {
        Write-Host "✅ [前置环境 2 - TUN 网卡驱动] wintun.dll 数字签名校验通过 (Valid)"
    } else {
        Write-Host "⚠️ [前置环境 2 - TUN 网卡驱动] wintun.dll 签名状态: $($sig.Status)"
    }
    if (Test-IsAdmin) {
        Write-Host "✅ [前置环境 2 - TUN 网卡权限] 当前会话已具备管理员权限 (Administrator)"
    } else {
        Write-Host "ℹ️ [前置环境 2 - TUN 网卡权限] 当前为普通用户会话，启动 vnt2_cli 时将通过 RunAs 自动提权挂载 vnt-tun 网卡"
    }
}

# ------------------------------------------------------------------------------
# 自动选择物理网卡与规范化 VNT2 服务器地址
# ------------------------------------------------------------------------------
function Get-PreferredPhysicalAdapter {
    if ($LOCAL_DEV) { return $LOCAL_DEV }
    $physAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    $candidates = @()
    foreach ($adapter in $physAdapters) {
        $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
        foreach ($r in $routes) {
            $ipIf = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $metric = [int]$r.RouteMetric + [int]($ipIf.InterfaceMetric)
            $candidates += [pscustomobject]@{ Name = $adapter.Name; Metric = $metric }
        }
    }
    if ($candidates.Count -gt 0) {
        return ($candidates | Sort-Object Metric | Select-Object -First 1).Name
    }
    if ($physAdapters.Count -gt 0) {
        return $physAdapters[0].Name
    }
    return $null
}

function Resolve-Vnt2ServerAddress {
    param([string]$RequestedServer)
    $srv = if ($RequestedServer) { $RequestedServer.Trim() } else { $DEFAULT_SERVER }
    if ($srv -notmatch '^(quic|tcp|wss|dynamic)://') {
        $srv = "quic://$srv"
    }
    if ($srv -notmatch ':\d+$') {
        if ($srv -match '^wss://') {
            $srv = "${srv}:443"
        } else {
            $srv = "${srv}:${DEFAULT_SERVER_PORT}"
        }
    }
    return $srv
}

function Extract-ServerHostIp([string]$ServerUrl) {
    if ($ServerUrl -match '^(?:quic|tcp|wss)://([^:/]+)') {
        return $matches[1]
    }
    return $DEFAULT_SERVER_IP
}

function Test-VpnTunConflict {
    $routeInfo = Find-NetRoute -RemoteIPAddress $DEFAULT_SERVER_IP -ErrorAction SilentlyContinue | Select-Object -First 1
    $routeIf = if ($routeInfo) { $routeInfo.InterfaceAlias } else { $null }
    $vpnProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'corplink|clash|mihomo|verge|surge|sing-box|shadowrocket|tailscale|anyconnect' } |
        Select-Object -ExpandProperty Name -Unique)
    $physDev = Get-PreferredPhysicalAdapter

    if ($routeIf -and $routeIf -match 'Meta|Clash|utun|tun|tap|CorpLink|wintun') {
        Write-Host "⚠️ [注意事项 3 - VPN/代理 TUN 抢占检查] 检测到系统默认路由经过虚拟网卡 ($routeIf)！"
        if ($vpnProcs.Count -gt 0) {
            Write-Host "   - 运行中的 VPN/代理进程: $($vpnProcs -join ', ')"
        }
        if ($physDev) {
            Write-Host "   👉 自动规避: 保留 Clash TUN 开启，启动时自动通过 --outbound-interface `"$physDev`" 绑定物理网卡直连自建 VPS (${DEFAULT_SERVER_IP}:${DEFAULT_SERVER_PORT})。"
        }
        return $true
    } elseif ($vpnProcs.Count -gt 0) {
        Write-Host "⚠️ [注意事项 3 - VPN/代理 TUN 抢占检查] 检测到后台运行 VPN/代理软件 ($($vpnProcs -join ', '))，将绑定物理网卡 ${physDev} 直连。"
        return $false
    } else {
        Write-Host "✅ [注意事项 3 - VPN/代理 TUN 抢占检查] 未检测到其他 VPN/代理 TUN 抢占路由 (当前出口网卡: $($routeIf))"
        return $false
    }
}

# ------------------------------------------------------------------------------
# 1. 前置环境与注意事项自检 (Pre-flight Checks)
# ------------------------------------------------------------------------------
function Invoke-Precheck {
    Write-Host "=================================================================="
    Write-Host "🔍 [1/4] 前置环境与注意事项检查 (Pre-flight Check - Windows VNT2)"
    Write-Host "=================================================================="

    if (-not (Find-Vnt2Bins)) {
        Write-Host "⚠️ 未检测到 vnt2_cli.exe，正在自动安装..."
        Install-Vnt2Cli
    }
    $verOut = (& $script:VNT2_CLI_BIN --version 2>&1 | Out-String).Trim()
    Write-Host "✅ [前置环境 1 - VNT2-CLI] 已安装: $($script:VNT2_CLI_BIN) ($verOut)"

    Ensure-TunPrivilege

    $fwProfiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    $enabledProfiles = @($fwProfiles | Where-Object Enabled -eq $true | Select-Object -ExpandProperty Name)
    if ($enabledProfiles.Count -eq 0) {
        Write-Host "✅ [注意事项 1 - 防火墙检查] Windows 系统防火墙已全部关闭 (Domain/Private/Public 均为 Off)"
    } else {
        Write-Host "⚠️ [注意事项 1 - 防火墙检查] Windows 防火墙以下配置处于开启状态: $($enabledProfiles -join ', ')"
        Write-Host "   👉 若队友无法 Ping 通你，可在管理员终端执行: netsh advfirewall set allprofiles state off"
    }

    $pgyProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'pgyvpn|pgyvisitor|oray|aweseed|蒲公英' -or $_.ExecutablePath -match 'pgy|oray|蒲公英' })
    if ($pgyProcs.Count -eq 0) {
        Write-Host "✅ [注意事项 2 - 蒲公英检查] 未检测到运行中的蒲公英 (PgyVPN/Oray) 进程，无虚拟网卡冲突"
    } else {
        Write-Host "⚠️ [注意事项 2 - 蒲公英检查] 检测到蒲公英相关进程正在运行！可能导致虚拟网卡路由冲突或打洞失败："
        foreach ($p in $pgyProcs) {
            Write-Host "   - PID $($p.ProcessId): $($p.Name)"
        }
    }

    [void](Test-VpnTunConflict)
    Write-Host ""
}

# ------------------------------------------------------------------------------
# 停止已有 VNT 实例与状态监控窗口
# ------------------------------------------------------------------------------
function Stop-Vnt2 {
    foreach ($pf in @($MONITOR_PID_FILE, $DAEMON_PID_FILE)) {
        if (Test-Path -LiteralPath $pf) {
            try {
                $targetPid = [int](Get-Content -LiteralPath $pf -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($targetPid) {
                    try {
                        Stop-Process -Id $targetPid -Force -ErrorAction Stop
                    } catch {
                        Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID $targetPid /F" -Verb RunAs -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
                    }
                }
            } catch {}
            Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
        }
    }

    $procs = @(Get-Process -Name "vnt2_cli", "vnt-cli", "vn-link-cli", "vnts2", "cloudflared" -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $needElevatedKill = $false
        foreach ($p in $procs) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
            } catch {
                $needElevatedKill = $true
            }
        }
        if ($needElevatedKill) {
            try {
                Start-Process -FilePath "taskkill.exe" -ArgumentList "/F /IM vnt2_cli.exe /IM vnt-cli.exe" -Verb RunAs -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
            } catch {}
        }
        Start-Sleep -Milliseconds 600
    }
}

# ------------------------------------------------------------------------------
# 2. 加入/创建房间（强制系统级 Wintun 虚拟网卡模式 + 弹出独立监控台）
# ------------------------------------------------------------------------------
function Join-Vnt2Room {
    Invoke-Precheck

    $physDev = Get-PreferredPhysicalAdapter
    $resolvedServer = Resolve-Vnt2ServerAddress $SERVER_ADDR

    Write-Host "=================================================================="
    Write-Host "🚀 [2/4] 加入/创建虚拟局域网房间 (强制 Wintun 模式 - VNT 2.0)"
    Write-Host "=================================================================="
    Write-Host "🏠 房间名称 (--network-code) : $ROOM_TOKEN"
    if ($ROOM_PASSWORD) {
        Write-Host "🔐 房间密码 (--password)     : 已设置 (ChaCha20-Poly1305 端到端加密已启用)"
    } else {
        Write-Host "🔓 房间密码 (--password)     : 未设置 (公开房间/无密码模式)"
    }
    if ($physDev) {
        Write-Host "🌐 绑定物理网卡              : $physDev"
    }
    Write-Host "🖥️ 注册/打洞服务器           : $resolvedServer"

    Stop-Vnt2
    New-Item -ItemType Directory -Force -Path $LOG_DIR -ErrorAction SilentlyContinue | Out-Null

    $menuScript = Join-Path $PSScriptRoot "vnt2_menu.ps1"
    $psFullExe  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    $escapedPsExe      = $psFullExe.Replace("'", "''")
    $escapedWorkDir    = $script:VNT2_WORK_DIR.Replace("'", "''")
    $escapedMenuScript = $menuScript.Replace("'", "''")
    $escapedRoom       = $ROOM_TOKEN.Replace("'", "''")
    $escapedPwd        = $ROOM_PASSWORD.Replace("'", "''")
    $escapedSrv        = $resolvedServer.Replace("'", "''")
    $escapedDev        = if ($physDev) { $physDev.Replace("'", "''") } else { "" }
    $escapedDevName    = if ($DEVICE_NAME) { $DEVICE_NAME.Replace("'", "''") } else { "" }

    $launchCode = "& '$escapedMenuScript' -HostDaemon -RoomToken '$escapedRoom' -RoomPassword '$escapedPwd' -ServerAddr '$escapedSrv' -LocalDev '$escapedDev' -DeviceName '$escapedDevName'"
    $launchB64  = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($launchCode))
    $winStyle   = if ($NO_WINDOW) { "Hidden" } else { "Normal" }

    Write-Host "⚙️  启动模式                 : 强制系统级 Wintun (vnt-tun) 虚拟网卡模式 + 独立实时监控日志窗口"
    Write-Host "⏳ 正在弹出「VNT 实时联机状态监控台」窗口并挂载系统虚拟网卡..."

    if (Test-IsAdmin) {
        $wmiCmd = "powershell.exe -NoProfile -WindowStyle Hidden -Command `"Start-Process -FilePath '$escapedPsExe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -EncodedCommand $launchB64' -WorkingDirectory '$escapedWorkDir' -WindowStyle $winStyle`""
    } else {
        $wmiCmd = "powershell.exe -NoProfile -WindowStyle Hidden -Command `"Start-Process -FilePath '$escapedPsExe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -EncodedCommand $launchB64' -WorkingDirectory '$escapedWorkDir' -Verb RunAs -WindowStyle $winStyle`""
    }
    $wmiRes = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine      = $wmiCmd
        CurrentDirectory = $script:VNT2_WORK_DIR
    }

    $connected = $false
    $vip = ""
    for ($i = 1; $i -le 45; $i++) {
        Start-Sleep -Milliseconds 350
        try {
            $infoRes = Invoke-Vnt2Ctrl "info"
            if ($infoRes.ExitCode -eq 0 -and $infoRes.Output -match 'Server:\s*.+\(Online') {
                if ($infoRes.Output -match '(?m)^IP:\s*(\S+)') {
                    $vip = $matches[1].Trim()
                }
                $tunIpObj = if ($vip) {
                    Get-NetIPAddress -IPAddress $vip -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object AddressState -eq 'Preferred'
                } else { $null }
                if ($tunIpObj) {
                    $connected = $true
                    break
                }
            }
        } catch {}
    }

    if ($connected) {
        $vntRunning = Get-Process -Name "vnt2_cli" -ErrorAction SilentlyContinue | Select-Object -First 1
        $monPid = if (Test-Path -LiteralPath $MONITOR_PID_FILE) { (Get-Content -LiteralPath $MONITOR_PID_FILE -ErrorAction SilentlyContinue | Select-Object -First 1) } else { $wmiRes.ProcessId }
        Write-Host "✅ 成功加入/创建「${ROOM_TOKEN}」房间并挂载系统级 vnt-tun 虚拟网卡 (VNT2 PID: $($vntRunning.Id), 监控台 PID: $monPid)！"
        if (-not $NO_WINDOW) {
            Write-Host "🖥️ 已弹出「VNT 实时联机状态监控台」独立窗口（实时展示在线人数、信号质量、底层日志，关闭窗口或按 Q/Ctrl+C 即自动断开联机）！"
        }
    } else {
        Write-Host "❌ 连接超时或虚拟网卡创建失败。"
        if (Test-Path -LiteralPath $LOG_FILE) { Get-Content -LiteralPath $LOG_FILE -Tail 20 -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $ERR_LOG_FILE) { Get-Content -LiteralPath $ERR_LOG_FILE -Tail 20 -ErrorAction SilentlyContinue }
        exit 1
    }
    Write-Host ""

    Show-Status
    Test-Stability
}

# ------------------------------------------------------------------------------
# 3. 查看加入情况与房间成员列表
# ------------------------------------------------------------------------------
function Show-Status {
    Write-Host "=================================================================="
    Write-Host "📊 [3/4] 房间加入情况与系统虚拟网卡状态"
    Write-Host "=================================================================="

    $infoRes = $null
    try { $infoRes = Invoke-Vnt2Ctrl "info" } catch {}

    if (-not $infoRes -or $infoRes.ExitCode -ne 0 -or $infoRes.Output -notmatch '(?m)^IP:\s*\S+') {
        Write-Host "❌ 当前没有正在运行的 VNT2 联机进程。"
        exit 1
    }

    $infoOut = $infoRes.Output
    $vip = if ($infoOut -match '(?m)^IP:\s*(\S+)') { $matches[1].Trim() } else { "" }

    Write-Host "【系统级 Wintun (vnt-tun) 虚拟网卡挂载验证】"
    $tunAdapter = Get-NetAdapter -Name "vnt-tun" -ErrorAction SilentlyContinue
    $tunIp = if ($vip) { Get-NetIPAddress -IPAddress $vip -AddressFamily IPv4 -ErrorAction SilentlyContinue } else { $null }
    if ($tunAdapter -and $tunAdapter.Status -eq 'Up' -and $tunIp) {
        Write-Host "   Adapter : $($tunAdapter.Name) ($($tunAdapter.InterfaceDescription)) [Status: $($tunAdapter.Status)]"
        Write-Host "   IPv4    : $($tunIp.IPAddress)/$($tunIp.PrefixLength) [State: $($tunIp.AddressState)]"
        Write-Host "✅ 系统级 Wintun (vnt-tun) 虚拟网卡已成功挂载并生效！"
    } else {
        Write-Host "⚠️ 未在系统网卡列表中检测到绑定 $vip 的 vnt-tun 虚拟网卡！"
    }
    Write-Host ""

    Write-Host "【本机节点信息 (vnt2_ctrl info)】"
    Write-Host $infoOut
    Write-Host ""

    Write-Host "【房间内成员列表与打洞状态 (vnt2_ctrl clients)】"
    $clientsRes = Invoke-Vnt2Ctrl "clients"
    Write-Host $clientsRes.Output
    $onlinePeers = if ($infoOut -match '(?m)^Online Clients:\s*(\d+)') { [int]$matches[1] } else { 0 }
    $totalPeers  = if ($infoOut -match '(?m)^Total Clients:\s*(\d+)')  { [int]$matches[1] } else { 0 }
    if ($totalPeers -eq 0) {
        Write-Host "💡 状态说明: 当前房间「${ROOM_TOKEN}」内暂无其他队友，本机已成功进房，等待队友使用相同房间名与密码加入。"
    } else {
        Write-Host "💡 状态说明: 当前房间内共记录 $totalPeers 位队友（其中在线 Online: $onlinePeers 位）！"
    }
    Write-Host ""

    Write-Host "【数据转发路由表 (vnt2_ctrl route)】"
    $routeRes = Invoke-Vnt2Ctrl "route"
    Write-Host $routeRes.Output
    Write-Host ""
}

# ------------------------------------------------------------------------------
# 辅助：执行 Windows ICMP Ping 并统计 min/avg/max 与丢包率
# ------------------------------------------------------------------------------
function Invoke-PingStats {
    param(
        [string]$TargetIp,
        [int]$Count = 4,
        [int]$IntervalMs = 100,
        [int]$TimeoutMs = 1000
    )
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $rtts = New-Object System.Collections.Generic.List[double]
    $sent = 0
    $received = 0
    try {
        for ($i = 1; $i -le $Count; $i++) {
            $sent++
            try {
                $reply = $pinger.Send($TargetIp, $TimeoutMs)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $received++
                    $rtts.Add([double]$reply.RoundtripTime)
                }
            } catch {}
            if ($i -lt $Count -and $IntervalMs -gt 0) {
                Start-Sleep -Milliseconds $IntervalMs
            }
        }
    } finally {
        $pinger.Dispose()
    }

    $lossPct = if ($sent -gt 0) { [math]::Round((($sent - $received) * 100.0) / $sent, 1) } else { 100.0 }
    if ($received -gt 0) {
        $measure = $rtts | Measure-Object -Minimum -Maximum -Average
        $minMs = [math]::Round($measure.Minimum, 1)
        $avgMs = [math]::Round($measure.Average, 0)
        $maxMs = [math]::Round($measure.Maximum, 1)
    } else {
        $minMs = $null; $avgMs = $null; $maxMs = $null
    }

    return [pscustomobject]@{
        Target      = $TargetIp
        Sent        = $sent
        Received    = $received
        LossPercent = $lossPct
        MinMs       = $minMs
        AvgMs       = $avgMs
        MaxMs       = $maxMs
    }
}

# ------------------------------------------------------------------------------
# 4. 测试连接稳定性（含本地虚拟网卡、会话心跳、VPS 链路与队友 P2P Ping）
# ------------------------------------------------------------------------------
function Test-Stability {
    Write-Host "=================================================================="
    Write-Host "🩺 [4/4] 连接稳定性测试报告 (Stability Test - TUN Mode)"
    Write-Host "=================================================================="

    $infoRes = $null
    try { $infoRes = Invoke-Vnt2Ctrl "info" } catch {}
    if (-not $infoRes -or $infoRes.ExitCode -ne 0 -or $infoRes.Output -notmatch '(?m)^IP:\s*\S+') {
        Write-Host "❌ 未检测到运行中的 VNT2 节点，无法执行稳定性测试。"
        exit 1
    }

    $infoOut = $infoRes.Output
    $vip     = if ($infoOut -match '(?m)^IP:\s*(\S+)') { $matches[1].Trim() } else { "" }
    $natType = if ($infoOut -match '(?m)^Nat Type:\s*(\S+)') { $matches[1].Trim() } else { "Unknown" }
    $srvLine = if ($infoOut -match '(?m)^Server:\s*(.+)') { $matches[1].Trim() } else { "" }
    $srvHost = Extract-ServerHostIp $srvLine

    $highLatencyDetected = $false
    $maxObservedRtt = 0

    # 1) 验证本地 TUN 虚拟网卡 IP 可达性
    Write-Host "1️⃣  本地系统 TUN 虚拟网卡 (${vip}) 连通性自检 (4 个 ICMP 包):"
    if ($vip) {
        $selfPing = Invoke-PingStats -TargetIp $vip -Count 4 -IntervalMs 50 -TimeoutMs 1000
        if ($selfPing.Received -gt 0) {
            Write-Host "   Packets: Sent = $($selfPing.Sent), Received = $($selfPing.Received), Lost = $($selfPing.Sent - $selfPing.Received) ($($selfPing.LossPercent)% loss)"
            Write-Host "   round-trip min/avg/max = $($selfPing.MinMs)/$($selfPing.AvgMs)/$($selfPing.MaxMs) ms"
        } else {
            Write-Host "   ❌ 本地虚拟网卡 IP (${vip}) Ping 失败，请检查 vnt-tun 网卡是否正确挂载！"
        }
    }
    Write-Host ""

    # 2) 连续 5 次采样检查控制面连接状态是否掉线或闪断
    Write-Host "2️⃣  VNT2 房间会话心跳连续采样 (5 次 / 间隔 0.2s):"
    $okSamples = 0
    for ($i = 1; $i -le 5; $i++) {
        $sampleRes = Invoke-Vnt2Ctrl "info"
        $isOnline  = ($sampleRes.Output -match 'Server:\s*.+\(Online')
        $curNat    = if ($sampleRes.Output -match '(?m)^Nat Type:\s*(\S+)') { $matches[1].Trim() } else { $natType }
        if ($curNat -and $curNat -ne 'Unknown') { $natType = $curNat }
        if ($isOnline) {
            $okSamples++
            Write-Host "   - 采样 #${i}: Connected (虚拟IP: ${vip}, NAT类型: ${natType})"
        } else {
            Write-Host "   - 采样 #${i}: 异常 (Connecting/Disconnected)"
        }
        if ($i -lt 5) { Start-Sleep -Milliseconds 200 }
    }
    Write-Host "   👉 会话保持率: $($okSamples * 20)% (${okSamples}/5)"
    Write-Host ""

    # 3) 测试注册服务器网络延迟与丢包率
    if ($srvHost) {
        Write-Host "3️⃣  自建 VPS 注册服务器 (${srvHost}) 链路稳定性测试 (10 个 ICMP 包):"
        $srvPing = Invoke-PingStats -TargetIp $srvHost -Count 10 -IntervalMs 50 -TimeoutMs 1000
        if ($srvPing.Received -gt 0) {
            Write-Host "   Packets: Sent = $($srvPing.Sent), Received = $($srvPing.Received), Lost = $($srvPing.Sent - $srvPing.Received) ($($srvPing.LossPercent)% loss)"
            Write-Host "   round-trip min/avg/max = $($srvPing.MinMs)/$($srvPing.AvgMs)/$($srvPing.MaxMs) ms"
        } else {
            Write-Host "   ⚠️ 服务器禁 Ping 或存在丢包 (Lost = $($srvPing.LossPercent)%)"
        }
        Write-Host ""
    }

    # 4) 测试房间内在线队友节点连通性与 P2P/Relay 状态
    Write-Host "4️⃣  房间内队友节点连通性与打洞分析 (TUN 虚拟局域网直连 Ping):"
    $clientsRes = Invoke-Vnt2Ctrl "clients"
    $clientsOut = $clientsRes.Output
    $peerLines  = @($clientsOut -split '\r?\n' | Where-Object { $_ -match '^\|\s*10\.\d+\.\d+\.\d+\s*\|' })
    if ($peerLines.Count -eq 0) {
        Write-Host "   ℹ️ 当前房间内暂无其他队友在线，跳过队友节点 Ping 测速（队友加入后可直接 ping 10.26.0.x）。"
    } else {
        Write-Host $clientsOut
        foreach ($pLine in $peerLines) {
            $cols = @(($pLine -split '\|') | ForEach-Object { $_.Trim() })
            if ($cols.Count -ge 8 -and $cols[5] -eq 'true') {
                $pip = $cols[1]
                $pname = $cols[2]
                $isP2p = ($cols[6] -eq 'true')
                $modeText = if ($isP2p) { "P2P直连" } else { "Relay中继" }
                Write-Host "   📡 正在通过 vnt-tun 虚拟网卡 Ping 在线队友 $pname ($pip, 模式: $modeText):"
                $peerPing = Invoke-PingStats -TargetIp $pip -Count 6 -IntervalMs 100 -TimeoutMs 1000
                if ($peerPing.Received -gt 0) {
                    Write-Host "      Packets: Sent = $($peerPing.Sent), Received = $($peerPing.Received), Lost = $($peerPing.Sent - $peerPing.Received) ($($peerPing.LossPercent)% loss)"
                    Write-Host "      round-trip min/avg/max = $($peerPing.MinMs)/$($peerPing.AvgMs)/$($peerPing.MaxMs) ms"
                    if ($peerPing.AvgMs -ge $HIGH_LATENCY_THRESHOLD_MS) {
                        $highLatencyDetected = $true
                        if ($peerPing.AvgMs -gt $maxObservedRtt) { $maxObservedRtt = $peerPing.AvgMs }
                        Write-Host "      🚨 异常告警: 队友 ($pip) 平均延迟高达 $($peerPing.AvgMs) ms！"
                    }
                } else {
                    Write-Host "      ⚠️ Ping 队友 ($pip) 未收到 ICMP 回包，请检查对端系统防火墙是否放行 ICMP 或密码是否一致。"
                }
            }
        }
    }
    Write-Host ""

    # 5) 综合联机质量评估
    Write-Host "5️⃣  综合联机质量评估:"
    if ($okSamples -lt 5) {
        Write-Host "   🔴 【异常 - 会话闪断】检测到连接状态不稳定 (${okSamples}/5)，请检查是否同机开启了多个相同房间实例。"
    } elseif ($highLatencyDetected) {
        Write-Host "   🔴 【异常 - 队友延迟偏高 (实测约 ${maxObservedRtt} ms >= ${HIGH_LATENCY_THRESHOLD_MS} ms)】请检查双方是否成功建立 P2P 直连。"
    } else {
        Write-Host "   🟢 【极佳 (Wintun 模式 + 自建 VPS 稳定在线 + $natType NAT)】系统级 vnt-tun 虚拟网卡已就绪，非常适合「${ROOM_TOKEN}」稳定联机！"
    }
    Write-Host "=================================================================="
}

# ------------------------------------------------------------------------------
# CLI 参数解析
# ------------------------------------------------------------------------------
$ACTION = "join"
$idx = 0
if ($args.Count -gt 0 -and $args[0] -notmatch '^-') {
    $ACTION = ([string]$args[0]).ToLower()
    $idx = 1
}

while ($idx -lt $args.Count) {
    $arg = [string]$args[$idx]
    switch -Regex ($arg) {
        '^(-Action|--action)$' {
            if ($idx + 1 -lt $args.Count) { $ACTION = ([string]$args[$idx + 1]).ToLower(); $idx += 2 } else { $idx++ }
        }
        '^(-k|--room|--token|--network-code|-Room)$' {
            if ($idx + 1 -lt $args.Count) { $ROOM_TOKEN = [string]$args[$idx + 1]; $idx += 2 } else { $idx++ }
        }
        '^(-w|--password|-p|-Password)$' {
            if ($idx + 1 -lt $args.Count) { $ROOM_PASSWORD = [string]$args[$idx + 1]; $idx += 2 } else { $idx++ }
        }
        '^(--no-password|-NoPassword)$' {
            $ROOM_PASSWORD = ""
            $idx++
        }
        '^(-n|--name|-Name)$' {
            if ($idx + 1 -lt $args.Count) { $DEVICE_NAME = [string]$args[$idx + 1]; $idx += 2 } else { $idx++ }
        }
        '^(-s|--server|-Server)$' {
            if ($idx + 1 -lt $args.Count) { $SERVER_ADDR = [string]$args[$idx + 1]; $idx += 2 } else { $idx++ }
        }
        '^(--local-dev|--outbound-interface|-LocalDevice)$' {
            if ($idx + 1 -lt $args.Count) { $LOCAL_DEV = [string]$args[$idx + 1]; $idx += 2 } else { $idx++ }
        }
        '^(--no-window|-NoWindow)$' {
            $NO_WINDOW = $true
            $idx++
        }
        '^(-h|--help|-Help)$' {
            Write-Host "用法: powershell -ExecutionPolicy Bypass -File .\vnt2_room.ps1 [join|precheck|status|test|stop|install|monitor] [-k 房间名] [-w 密码] [-n 设备昵称] [-s 服务器地址] [--local-dev 物理网卡名]"
            exit 0
        }
        default {
            $idx++
        }
    }
}

switch -Regex ($ACTION) {
    '^install$' {
        Install-Vnt2Cli
    }
    '^(auth|grant)$' {
        Ensure-TunPrivilege
    }
    '^(precheck|check)$' {
        Invoke-Precheck
    }
    '^(join|create|start)$' {
        Join-Vnt2Room
    }
    '^monitor$' {
        $menuScript = Join-Path $PSScriptRoot "vnt2_menu.ps1"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $menuScript
    }
    '^(status|info|list)$' {
        Show-Status
    }
    '^(test|ping|observe)$' {
        Test-Stability
    }
    '^(stop|leave|exit)$' {
        Stop-Vnt2
        Write-Host "🛑 已退出「${ROOM_TOKEN}」虚拟局域网房间并卸载系统级 vnt-tun 虚拟网卡。"
    }
    default {
        Write-Host "未知操作: $ACTION (支持: join | precheck | status | test | stop | install | monitor)"
        exit 1
    }
}
