# ==============================================================================
# VNT-CLI 峡谷模拟联机群 内网穿透管理与稳定性测试脚本 - Windows PowerShell 版
# （强制系统级 Wintun 虚拟网卡模式，核心逻辑与 vnt_room.sh 保持一致）
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\vnt_room.ps1 join [-k "峡谷模拟联机群"] [-w "密码"] [-n "设备昵称"] [-s "服务器地址"]
#   powershell -ExecutionPolicy Bypass -File .\vnt_room.ps1 precheck
#   powershell -ExecutionPolicy Bypass -File .\vnt_room.ps1 status
#   powershell -ExecutionPolicy Bypass -File .\vnt_room.ps1 test
#   powershell -ExecutionPolicy Bypass -File .\vnt_room.ps1 stop
#   powershell -ExecutionPolicy Bypass -File .\vnt_room.ps1 auth
#   powershell -ExecutionPolicy Bypass -File .\vnt_room.ps1 install
# ==============================================================================
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$DEFAULT_ROOM = "峡谷模拟联机群"
$DEFAULT_PASSWORD = "200008"
$ROOM_TOKEN = $DEFAULT_ROOM
$ROOM_PASSWORD = $DEFAULT_PASSWORD
$DEVICE_NAME = ""
$SERVER_ADDR = ""
$LOCAL_DEV = ""
$VNT_VERSION = "v1.2.16"
$WINTUN_VERSION = "0.14.1"
$DEFAULT_SERVER_HOST = "vnt.wherewego.top"
$DEFAULT_SERVER_PORT = 29872
$FALLBACK_SERVER_IP = "8.134.66.150"
$HIGH_LATENCY_THRESHOLD_MS = 200
$INSTALL_DIR = Join-Path $env:LOCALAPPDATA "Programs\VNT\$VNT_VERSION"
$LOG_DIR = "C:\Users\Public\VNT_Logs"
$LOG_FILE = Join-Path $LOG_DIR "vnt_room_daemon.log"
$ERR_LOG_FILE = Join-Path $LOG_DIR "vnt_room_daemon.err.log"
$MONITOR_PID_FILE = Join-Path $LOG_DIR "vnt_room_monitor.pid"
$NO_WINDOW = $false

$script:VNT_CLI_BIN = $null
$script:VNT_WORK_DIR = $null

# ------------------------------------------------------------------------------
# 查找或自动安装 vnt-cli.exe 与 wintun.dll
# ------------------------------------------------------------------------------
function Find-VntBins {
    $candidates = @(
        (Join-Path $INSTALL_DIR "vnt-cli.exe"),
        (Join-Path $env:USERPROFILE ".local\bin\vnt-cli.exe")
    )
    $cmd = Get-Command vnt-cli.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        $candidates = @($cmd.Source) + $candidates
    }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $script:VNT_CLI_BIN = $path
            $script:VNT_WORK_DIR = Split-Path -Parent $path
            return
        }
    }
    $script:VNT_CLI_BIN = $null
    $script:VNT_WORK_DIR = $null
}

function Invoke-VntCmd {
    param([string[]]$Arguments)
    Find-VntBins
    if (-not $script:VNT_CLI_BIN) {
        throw "未找到 vnt-cli.exe，请先执行 install。"
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:VNT_CLI_BIN
    $psi.Arguments = ($Arguments -join ' ')
    $psi.WorkingDirectory = $script:VNT_WORK_DIR
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
        if (-not $proc.WaitForExit(10000)) {
            try { $proc.Kill() } catch {}
            throw "vnt-cli 命令执行超时: $($Arguments -join ' ')"
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

function Install-VntCli {
    Find-VntBins
    if ($script:VNT_CLI_BIN) {
        $wintunPath = Join-Path $script:VNT_WORK_DIR "wintun.dll"
        if (Test-Path -LiteralPath $wintunPath -PathType Leaf) {
            Write-Host "✅ 已检测到 VNT-CLI: $($script:VNT_CLI_BIN) (含 wintun.dll)"
            return
        }
    }

    Write-Host "📦 正在自动安装 Windows 版 VNT-CLI ($VNT_VERSION) 与 Wintun 驱动 ($WINTUN_VERSION)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq "ARM64") {
        $tarName = "vnt-aarch64-pc-windows-msvc-$VNT_VERSION.tar.gz"
        $wintunSubDir = "arm64"
    } elseif ($arch -eq "AMD64") {
        $tarName = "vnt-x86_64-pc-windows-msvc-$VNT_VERSION.tar.gz"
        $wintunSubDir = "amd64"
    } else {
        $tarName = "vnt-i686-pc-windows-msvc-$VNT_VERSION.tar.gz"
        $wintunSubDir = "x86"
    }

    New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
    $tmpDir = Join-Path $env:TEMP ("vnt_install_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    try {
        $vntUrl = "https://github.com/vnt-dev/vnt/releases/download/$VNT_VERSION/$tarName"
        $tarFile = Join-Path $tmpDir $tarName
        Write-Host "   ⬇️ 正在下载 $vntUrl ..."
        Invoke-WebRequest -Uri $vntUrl -OutFile $tarFile -UseBasicParsing

        & tar.exe -xzf $tarFile -C $INSTALL_DIR
        if ($LASTEXITCODE -ne 0) {
            throw "解压 $tarName 失败。"
        }

        $wintunDllDest = Join-Path $INSTALL_DIR "wintun.dll"
        if (-not (Test-Path -LiteralPath $wintunDllDest -PathType Leaf)) {
            $wintunUrl = "https://www.wintun.net/builds/wintun-$WINTUN_VERSION.zip"
            $wintunZip = Join-Path $tmpDir "wintun.zip"
            Write-Host "   ⬇️ 正在下载 Wintun 虚拟网卡驱动 $wintunUrl ..."
            Invoke-WebRequest -Uri $wintunUrl -OutFile $wintunZip -UseBasicParsing
            Expand-Archive -LiteralPath $wintunZip -DestinationPath (Join-Path $tmpDir "wintun") -Force
            $wintunDllSrc = Join-Path $tmpDir "wintun\wintun\bin\$wintunSubDir\wintun.dll"
            Copy-Item -LiteralPath $wintunDllSrc -Destination $wintunDllDest -Force
        }
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Find-VntBins
    if (-not $script:VNT_CLI_BIN) {
        throw "❌ VNT-CLI 安装失败，未在 $INSTALL_DIR 找到 vnt-cli.exe"
    }
    Write-Host "✅ VNT-CLI 安装完成: $($script:VNT_CLI_BIN)"
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
    Find-VntBins
    if (-not $script:VNT_CLI_BIN) {
        Install-VntCli
    }
    $wintunPath = Join-Path $script:VNT_WORK_DIR "wintun.dll"
    if (-not (Test-Path -LiteralPath $wintunPath -PathType Leaf)) {
        Write-Host "⚠️ 未检测到同目录 wintun.dll，正在补齐驱动..."
        Install-VntCli
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
        Write-Host "ℹ️ [前置环境 2 - TUN 网卡权限] 当前为普通用户会话，启动 vnt-cli 时将通过 RunAs 自动提权挂载 vnt-tun 网卡"
    }
}

# ------------------------------------------------------------------------------
# 自动选择物理网卡与真实服务器 IP（规避 Clash Fake-IP 与代理 TUN 路由抢占）
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

function Resolve-RealServerAddress {
    param([string]$RequestedServer)
    if ($RequestedServer) {
        if ($RequestedServer -notmatch '^([a-zA-Z0-9.-]+):(\d+)$') {
            return $RequestedServer
        }
        $hostPart = $matches[1]
        $portPart = $matches[2]
    } else {
        $hostPart = $DEFAULT_SERVER_HOST
        $portPart = $DEFAULT_SERVER_PORT
    }

    $parsedIp = $null
    if ([Net.IPAddress]::TryParse($hostPart, [ref]$parsedIp)) {
        return "${hostPart}:${portPart}"
    }

    # 检查系统 DNS 是否返回 Clash Fake-IP (198.18.0.0/15)
    $dnsIps = @(Resolve-DnsName -Name $hostPart -Type A -DnsOnly -ErrorAction SilentlyContinue |
        Where-Object Type -eq 'A' | Select-Object -ExpandProperty IPAddress)
    $realIps = @($dnsIps | Where-Object { $_ -notmatch '^198\.(18|19)\.' })
    if ($realIps.Count -gt 0) {
        return "$($realIps[0]):${portPart}"
    }

    # 使用阿里 DoH 解析真实 IP，规避 Fake-IP 劫持
    try {
        $dohUrl = "https://dns.alidns.com/resolve?name=$([Uri]::EscapeDataString($hostPart))&type=A"
        $resp = Invoke-RestMethod -Uri $dohUrl -TimeoutSec 5 -ErrorAction Stop
        $dohIps = @($resp.Answer | Where-Object { $_.type -eq 1 -and $_.data -match '^\d+\.\d+\.\d+\.\d+$' -and $_.data -notmatch '^198\.(18|19)\.' } | Select-Object -ExpandProperty data)
        if ($dohIps.Count -gt 0) {
            return "$($dohIps[0]):${portPart}"
        }
    } catch {}

    return "${FALLBACK_SERVER_IP}:${portPart}"
}

function Test-VpnTunConflict {
    $routeInfo = Find-NetRoute -RemoteIPAddress $FALLBACK_SERVER_IP -ErrorAction SilentlyContinue | Select-Object -First 1
    $routeIf = if ($routeInfo) { $routeInfo.InterfaceAlias } else { $null }
    $vpnProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'corplink|clash|mihomo|verge|surge|sing-box|shadowrocket|tailscale|anyconnect' } |
        Select-Object -ExpandProperty Name -Unique)
    $physDev = Get-PreferredPhysicalAdapter

    if ($routeIf -and $routeIf -match 'Meta|Clash|utun|tun|tap|CorpLink|wintun') {
        Write-Host "⚠️ [注意事项 3 - VPN/代理 TUN 抢占检查] 检测到系统去往服务器的默认路由经过虚拟网卡 ($routeIf)！"
        if ($vpnProcs.Count -gt 0) {
            Write-Host "   - 运行中的 VPN/代理进程: $($vpnProcs -join ', ')"
        }
        if ($physDev) {
            Write-Host "   👉 自动规避: 启动时将通过 --local-dev `"$physDev`" 绑定物理网卡并解析真实服务器 IP，绕过代理 TUN 劫持。"
        } else {
            Write-Host "   👉 建议: 关闭代理软件的 TUN 模式 / 全局 VPN，或将 $FALLBACK_SERVER_IP ($DEFAULT_SERVER_HOST) 设为直连 (DIRECT)。"
        }
        return $true
    } elseif ($vpnProcs.Count -gt 0) {
        Write-Host "⚠️ [注意事项 3 - VPN/代理 TUN 抢占检查] 检测到后台运行 VPN/代理软件 ($($vpnProcs -join ', '))，当前出口网卡为 $($routeIf)（将绑定物理网卡 ${physDev} 直连）。"
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
    Write-Host "🔍 [1/4] 前置环境与注意事项检查 (Pre-flight Check - Windows)"
    Write-Host "=================================================================="

    # 1) 检查 VNT-CLI 安装情况
    Find-VntBins
    if (-not $script:VNT_CLI_BIN) {
        Write-Host "⚠️ 未检测到 vnt-cli.exe，正在自动安装..."
        Install-VntCli
    } else {
        $helpRes = Invoke-VntCmd @("-h")
        $verLine = ($helpRes.Output -split '\r?\n' | Where-Object { $_ -match '^version:' } | Select-Object -First 1)
        if (-not $verLine) { $verLine = "unknown" }
        Write-Host "✅ [前置环境 1 - VNT-CLI] 已安装: $($script:VNT_CLI_BIN) ($verLine)"
    }

    # 2) 检查 Wintun 驱动与权限
    Ensure-TunPrivilege

    # 3) 检查 Windows 系统防火墙状态
    $fwProfiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    $enabledProfiles = @($fwProfiles | Where-Object Enabled -eq $true | Select-Object -ExpandProperty Name)
    if ($enabledProfiles.Count -eq 0) {
        Write-Host "✅ [注意事项 1 - 防火墙检查] Windows 系统防火墙已全部关闭 (Domain/Private/Public 均为 Off)"
    } else {
        Write-Host "⚠️ [注意事项 1 - 防火墙检查] Windows 防火墙以下配置处于开启状态: $($enabledProfiles -join ', ')"
        Write-Host "   👉 建议在管理员终端执行关闭命令以避免拦截 UDP 打洞与局域网联机广播:"
        Write-Host "      netsh advfirewall set allprofiles state off"
    }

    # 4) 检查蒲公英 (Oray PgyVPN) 与向日葵冲突进程
    $pgyProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'pgyvpn|pgyvisitor|oray|aweseed|蒲公英' -or $_.ExecutablePath -match 'pgy|oray|蒲公英' })
    if ($pgyProcs.Count -eq 0) {
        Write-Host "✅ [注意事项 2 - 蒲公英检查] 未检测到运行中的蒲公英 (PgyVPN/Oray) 进程，无虚拟网卡冲突"
    } else {
        Write-Host "⚠️ [注意事项 2 - 蒲公英检查] 检测到蒲公英相关进程正在运行！可能导致虚拟网卡路由冲突或打洞失败："
        foreach ($p in $pgyProcs) {
            Write-Host "   - PID $($p.ProcessId): $($p.Name) ($($p.ExecutablePath))"
        }
        Write-Host "   👉 请先退出蒲公英客户端并断开其虚拟网卡后再进行组网。"
    }

    # 5) 检查其他 VPN / 代理软件 TUN 模式路由抢占
    [void](Test-VpnTunConflict)
    Write-Host ""
}

# ------------------------------------------------------------------------------
# 停止已有 VNT 实例与状态监控窗口
# ------------------------------------------------------------------------------
function Stop-Vnt {
    Find-VntBins
    if ($script:VNT_CLI_BIN) {
        try { [void](Invoke-VntCmd @("--stop")) } catch {}
    }
    if (Test-Path -LiteralPath $MONITOR_PID_FILE) {
        try {
            $monPid = [int](Get-Content -LiteralPath $MONITOR_PID_FILE -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($monPid) {
                try {
                    Stop-Process -Id $monPid -Force -ErrorAction Stop
                } catch {
                    Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID $monPid /F" -Verb RunAs -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
                }
            }
        } catch {}
        Remove-Item -LiteralPath $MONITOR_PID_FILE -Force -ErrorAction SilentlyContinue
    }
    $procs = @(Get-Process -Name "vnt-cli", "vn-link-cli" -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
        } catch {
            try {
                Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID $($p.Id) /F" -Verb RunAs -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
            } catch {}
        }
    }
    Start-Sleep -Milliseconds 600
}

# ------------------------------------------------------------------------------
# 独立可视化监控与日志窗口（关闭窗口即自动停止 VNT 并卸载虚拟网卡）
# ------------------------------------------------------------------------------
function Disable-ConsoleQuickEdit {
    try {
        $code = @"
using System;
using System.Runtime.InteropServices;
public static class ConsoleHelper {
    private const int STD_INPUT_HANDLE = -10;
    private const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    private const uint ENABLE_EXTENDED_FLAGS = 0x0080;
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    public static void DisableQuickEdit() {
        IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
        uint mode;
        if (GetConsoleMode(handle, out mode)) {
            mode &= ~ENABLE_QUICK_EDIT_MODE;
            mode |= ENABLE_EXTENDED_FLAGS;
            SetConsoleMode(handle, mode);
        }
    }
}
"@
        Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
        [ConsoleHelper]::DisableQuickEdit()
    } catch {}
}

function Start-VntMonitor {
    $ErrorActionPreference = 'Continue'
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Find-VntBins
    if (-not $script:VNT_CLI_BIN) {
        Write-Host "❌ 未找到 vnt-cli.exe"
        Start-Sleep -Seconds 3
        exit 1
    }

    New-Item -ItemType Directory -Force -Path $LOG_DIR -ErrorAction SilentlyContinue | Out-Null
    Disable-ConsoleQuickEdit
    try {
        $Host.UI.RawUI.WindowTitle = "🟢 VNT 联机监控台 - $ROOM_TOKEN [关闭本窗口即自动断开联机]"
    } catch {}

    $PID | Set-Content -LiteralPath $MONITOR_PID_FILE -Encoding ASCII -Force
    "" | Set-Content -LiteralPath $LOG_FILE -Encoding UTF8 -Force
    "" | Set-Content -LiteralPath $ERR_LOG_FILE -Encoding UTF8 -Force

    # 在监控台内部以隐藏模式启动 vnt-cli.exe，将日志重定向到文件统一展示，避免弹出简陋的原生黑框
    $cmdArgs = @("-k", "`"$ROOM_TOKEN`"")
    if ($ROOM_PASSWORD) { $cmdArgs += @("-w", "`"$ROOM_PASSWORD`"") }
    if ($DEVICE_NAME)   { $cmdArgs += @("-n", "`"$DEVICE_NAME`"") }
    if ($LOCAL_DEV)     { $cmdArgs += @("--local-dev", "`"$LOCAL_DEV`"") }
    if ($SERVER_ADDR)   { $cmdArgs += @("-s", "`"$SERVER_ADDR`"") }
    $argString = $cmdArgs -join ' '

    $vntProc = Start-Process -FilePath $script:VNT_CLI_BIN `
        -ArgumentList $argString `
        -WorkingDirectory $script:VNT_WORK_DIR `
        -WindowStyle Hidden `
        -RedirectStandardOutput $LOG_FILE `
        -RedirectStandardError $ERR_LOG_FILE `
        -PassThru

    # 启动轻量级守护观察器：一旦用户点击右上角 × 关闭本监控窗口，立即自动执行 vnt-cli --stop 并清理进程
    $escapedBin = $script:VNT_CLI_BIN.Replace("'", "''")
    $escapedWork = $script:VNT_WORK_DIR.Replace("'", "''")
    $watcherScript = "Wait-Process -Id $PID -ErrorAction SilentlyContinue; Set-Location -LiteralPath '$escapedWork'; & '$escapedBin' --stop *> `$null; Stop-Process -Id $($vntProc.Id) -Force -ErrorAction SilentlyContinue"
    $watcherB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($watcherScript))
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList "-NoProfile -WindowStyle Hidden -EncodedCommand $watcherB64" -WindowStyle Hidden | Out-Null

    try {
        while (-not $vntProc.HasExited) {
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq [ConsoleKey]::Q) {
                        break
                    }
                }
            } catch {}

            $infoRes = try { Invoke-VntCmd @("--info") } catch { $null }
            $listRes = try { Invoke-VntCmd @("--list") } catch { $null }
            $allRes  = try { Invoke-VntCmd @("--all") } catch { $null }
            $routeRes = try { Invoke-VntCmd @("--route") } catch { $null }

            $infoOut = if ($infoRes) { $infoRes.Output } else { "" }
            $devName = if ($infoOut -match '(?m)^Name:\s*(.+)') { $matches[1].Trim() } else { $env:COMPUTERNAME }
            $vip = if ($infoOut -match '(?m)^Virtual ip:\s*(\S+)') { $matches[1].Trim() } else { "正在分配..." }
            $connStatus = if ($infoOut -match '(?m)^Connection status:\s*(\S+)') { $matches[1].Trim() } else { "Connecting" }
            $natType = if ($infoOut -match '(?m)^NAT type:\s*(\S+)') { $matches[1].Trim() } else { "探测中" }
            $localAddr = if ($infoOut -match '(?m)^Local addr:\s*(\S+)') { $matches[1].Trim() } else { "-" }
            $relaySrv = if ($infoOut -match '(?m)^Relay server:\s*(\S+)') { $matches[1].Trim() } else { $SERVER_ADDR }

            # 解析队友数量、在线人数与信号质量
            $allLines = @()
            if ($allRes -and $allRes.Output -and $allRes.Output -notmatch 'No other devices found') {
                $allLines = @($allRes.Output -split '\r?\n' | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne '' })
            }
            $onlinePeers = @($allLines | Where-Object { $_ -match '\bOnline\b' })
            $totalPeople = 1 + $allLines.Count
            $onlinePeople = 1 + $onlinePeers.Count

            # 解析服务器延迟作为基准信号
            $srvRt = "-"
            if ($routeRes -and $routeRes.Output -match '(?m)^10\.\d+\.\d+\.1\s+\S+\s+\d+\s+(\d+)') {
                $srvRt = $matches[1]
            }

            try {
                $Host.UI.RawUI.WindowTitle = "🟢 VNT 联机中 [$vip | 在线 ${onlinePeople}人] - $ROOM_TOKEN (关闭本窗口即自动断开联机)"
            } catch {}

            try { [Console]::Clear() } catch {}
            Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
            Write-Host "║  🎮  VNT 峡谷模拟联机群 · 实时联机监控台                                     ║" -ForegroundColor Yellow
            Write-Host "║  🛑  【重要提示】直接关闭本窗口 (点击右上角 × 或按 Q / Ctrl+C)               ║" -ForegroundColor Red
            Write-Host "║      即可【自动断开联机】并卸载虚拟网卡！联机期间请保持本窗口开启(可最小化)  ║" -ForegroundColor Yellow
            Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
            Write-Host ""
            $connBadge = if ($connStatus -eq 'Connected') { "🟢 已连接 (Connected)" } else { "🟡 连接中 ($connStatus)" }
            $srvSignal = if ($srvRt -match '^\d+$' -and [int]$srvRt -lt 80) { "▂▄▆█ 极佳 (${srvRt}ms)" } elseif ($srvRt -match '^\d+$' -and [int]$srvRt -lt 200) { "▂▄▆_ 良好 (${srvRt}ms)" } else { "▂▄__ (${srvRt}ms)" }
            Write-Host "  🏠 房间名称 : $ROOM_TOKEN      🔐 房间密码 : $(if($ROOM_PASSWORD){$ROOM_PASSWORD}else{'无密码'})" -ForegroundColor Cyan
            Write-Host "  👥 房间人数 : 当前在线 $onlinePeople 人 / 房间共 $totalPeople 人 (本机 + $($onlinePeers.Count) 位在线队友)" -ForegroundColor Green
            Write-Host "  📶 本机状态 : $connBadge   |   主干信号: $srvSignal" -ForegroundColor White
            Write-Host "  🖥️ 本机虚拟IP: $vip ($devName)   |   NAT类型: $natType   |   出口网卡: $(if($LOCAL_DEV){$LOCAL_DEV}else{'自动'}) ($localAddr)" -ForegroundColor Gray
            Write-Host "────────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
            Write-Host "  📡 【房间队友状态与信号质量】" -ForegroundColor Cyan
            if ($allLines.Count -eq 0) {
                Write-Host "     ⏳ 当前房间暂无其他队友，等待队友使用房间名「$ROOM_TOKEN」与密码「$ROOM_PASSWORD」加入..." -ForegroundColor Yellow
            } else {
                foreach ($line in $allLines) {
                    if ($line -match '^\s*(.+?)\s+(10\.\d+\.\d+\.\d+)\s+(Online|Offline)(?:\s+(\S+))?(?:\s+(\d+))?') {
                        $pName = $matches[1].Trim()
                        $pIp   = $matches[2].Trim()
                        $pStat = $matches[3].Trim()
                        $pMode = if ($matches[4]) { $matches[4].Trim() } else { "-" }
                        $pRt   = if ($matches[5]) { $matches[5].Trim() } else { "-" }
                        if ($pStat -eq 'Online') {
                            $modeStr = if ($pMode -match '(?i)p2p') { "⚡ P2P直连" } else { "🔄 服务器中继($pMode)" }
                            $sigStr = if ($pRt -match '^\d+$') {
                                $rtVal = [int]$pRt
                                if ($rtVal -ge 9000) { "🟢 ▂▄▆█ 测速中..." }
                                elseif ($rtVal -lt 60) { "🟢 ▂▄▆█ 极佳 (${rtVal}ms)" }
                                elseif ($rtVal -lt 130) { "🟢 ▂▄▆_ 良好 (${rtVal}ms)" }
                                elseif ($rtVal -lt 200) { "🟡 ▂▄__ 一般 (${rtVal}ms)" }
                                else { "🔴 ▂___ 高延迟 (${rtVal}ms)" }
                            } else { "探测中..." }
                            Write-Host ("     🟢 [在线] {0,-14} 虚拟IP: {1,-12} 模式: {2,-12} 信号: {3}" -f $pName, $pIp, $modeStr, $sigStr) -ForegroundColor Green
                        } else {
                            Write-Host ("     ⚪ [离线] {0,-14} 虚拟IP: {1,-12} 状态: 离线" -f $pName, $pIp) -ForegroundColor DarkGray
                        }
                    } else {
                        Write-Host "     $line"
                    }
                }
            }
            if ($listRes -and $listRes.Output -match 'Mismatch') {
                Write-Host "     🚨 [加密告警] 检测到密码不一致 (Mismatch)！请提醒队友将密码设为: $ROOM_PASSWORD" -ForegroundColor Red
            }
            Write-Host "────────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
            Write-Host "  📜 【VNT-CLI 底层连接日志】" -ForegroundColor Cyan
            if (Test-Path -LiteralPath $LOG_FILE) {
                $logs = @(Get-Content -LiteralPath $LOG_FILE -Tail 6 -ErrorAction SilentlyContinue)
                foreach ($l in $logs) {
                    Write-Host "     $l" -ForegroundColor DarkGray
                }
            }
            Write-Host "════════════════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
            Write-Host "  ⏱️ 实时监控刷新: $(Get-Date -Format 'HH:mm:ss') (每 2 秒自动更新)  |  👉 按 [Q] 键或关闭右上角 [×] 立即断开联机" -ForegroundColor Yellow

            Start-Sleep -Seconds 2
            $vntProc.Refresh()
        }
    } finally {
        try { [void](Invoke-VntCmd @("--stop")) } catch {}
        try { Stop-Process -Id $vntProc.Id -Force -ErrorAction SilentlyContinue } catch {}
        Remove-Item -LiteralPath $MONITOR_PID_FILE -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------------------
# 2. 加入/创建房间（强制系统级 Wintun 虚拟网卡模式）
# ------------------------------------------------------------------------------
function Join-VntRoom {
    Invoke-Precheck

    $physDev = Get-PreferredPhysicalAdapter
    $resolvedServer = Resolve-RealServerAddress $SERVER_ADDR

    Write-Host "=================================================================="
    Write-Host "🚀 [2/4] 加入/创建虚拟局域网房间 (强制 Wintun 模式)"
    Write-Host "=================================================================="
    Write-Host "🏠 房间名称 (Token) : $ROOM_TOKEN"
    if ($ROOM_PASSWORD) {
        Write-Host "🔐 房间密码 (-w)    : 已设置 (端到端加密已启用)"
    } else {
        Write-Host "🔓 房间密码 (-w)    : 未设置 (公开房间/无密码模式)"
    }
    if ($physDev) {
        Write-Host "🌐 绑定物理网卡     : $physDev"
    }
    Write-Host "🖥️ 注册/中继服务器  : $resolvedServer"

    # 若已有实例正在运行且已 Connected，先检查是否需要重启；遵循 vnt_room.sh 逻辑清理旧实例防互踢
    Stop-Vnt

    $cmdArgs = @("-k", "`"$ROOM_TOKEN`"")
    if ($ROOM_PASSWORD) {
        $cmdArgs += @("-w", "`"$ROOM_PASSWORD`"")
    }
    if ($DEVICE_NAME) {
        $cmdArgs += @("-n", "`"$DEVICE_NAME`"")
    }
    if ($physDev) {
        $cmdArgs += @("--local-dev", "`"$physDev`"")
    }
    if ($resolvedServer) {
        $cmdArgs += @("-s", "`"$resolvedServer`"")
    }

    $argString = $cmdArgs -join ' '
    Write-Host "⚙️  启动模式        : 强制系统级 Wintun (vnt-tun) 虚拟网卡模式 + 独立实时监控日志窗口"
    Write-Host "   执行参数        : vnt-cli.exe $argString"

    # 通过 WMI + RunAs + 内存 Base64 启动独立的「VNT 实时联机监控台」窗口（内部托管隐藏的 vnt-cli.exe，展示在线人数、信号、日志，且关窗口即断开联机）
    $psFullExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $escapedPsExe = $psFullExe.Replace("'", "''")
    $escapedWorkDir = $script:VNT_WORK_DIR.Replace("'", "''")
    $escapedBin = $script:VNT_CLI_BIN.Replace("'", "''")
    $escapedRoom = $ROOM_TOKEN.Replace("'", "''")
    $escapedPwd = $ROOM_PASSWORD.Replace("'", "''")
    $escapedDev = if ($physDev) { $physDev.Replace("'", "''") } else { "" }
    $escapedSrv = if ($resolvedServer) { $resolvedServer.Replace("'", "''") } else { "" }
    $escapedArgStr = $argString.Replace("'", "''")

    $dashScript = @"
`$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try {
    `$code = @'
using System;
using System.Runtime.InteropServices;
public static class VntConsoleHelper {
    [DllImport("kernel32.dll")] private static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] private static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] private static extern bool SetConsoleMode(IntPtr h, uint m);
    public static void DisableQuickEdit() {
        IntPtr h = GetStdHandle(-10); uint m;
        if (GetConsoleMode(h, out m)) { SetConsoleMode(h, (m & ~0x0040u) | 0x0080u); }
    }
}
'@
    Add-Type -TypeDefinition `$code -ErrorAction SilentlyContinue
    [VntConsoleHelper]::DisableQuickEdit()
} catch {}

`$vntBin = '$escapedBin'
`$vntWork = '$escapedWorkDir'
`$roomToken = '$escapedRoom'
`$roomPwd = '$escapedPwd'
`$localDev = '$escapedDev'
`$srvAddr = '$escapedSrv'
`$logDir = '$LOG_DIR'
`$logFile = '$LOG_FILE'
`$errFile = '$ERR_LOG_FILE'
`$pidFile = '$MONITOR_PID_FILE'

New-Item -ItemType Directory -Force -Path `$logDir -ErrorAction SilentlyContinue | Out-Null
`$PID | Set-Content -LiteralPath `$pidFile -Encoding ASCII -Force
'' | Set-Content -LiteralPath `$logFile -Encoding UTF8 -Force
'' | Set-Content -LiteralPath `$errFile -Encoding UTF8 -Force
Set-Location -LiteralPath `$vntWork

try {
    `$Host.UI.RawUI.WindowTitle = "🟢 VNT 联机监控台 - `$roomToken [关闭本窗口即自动断开联机]"
    `$b = `$Host.UI.RawUI.BufferSize
    if (`$b.Width -lt 94) { `$b.Width = 94; `$Host.UI.RawUI.BufferSize = `$b }
    `$w = `$Host.UI.RawUI.WindowSize
    `$w.Width = 94; `$w.Height = 30
    `$Host.UI.RawUI.WindowSize = `$w
} catch {}

`$vntProc = Start-Process -FilePath `$vntBin -ArgumentList '$escapedArgStr' -WorkingDirectory `$vntWork -WindowStyle Hidden -RedirectStandardOutput `$logFile -RedirectStandardError `$errFile -PassThru

`$watchCode = "Wait-Process -Id `$PID -ErrorAction SilentlyContinue; Set-Location -LiteralPath '`$vntWork'; & '`$vntBin' --stop *> ```$null; Stop-Process -Id `$(`$vntProc.Id) -Force -ErrorAction SilentlyContinue"
`$watchB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(`$watchCode))
Start-Process -FilePath '$escapedPsExe' -ArgumentList "-NoProfile -WindowStyle Hidden -EncodedCommand `$watchB64" -WindowStyle Hidden | Out-Null

function Invoke-QuickVnt([string]`$flag) {
    `$psi = New-Object System.Diagnostics.ProcessStartInfo
    `$psi.FileName = `$vntBin; `$psi.Arguments = `$flag; `$psi.WorkingDirectory = `$vntWork
    `$psi.UseShellExecute = `$false; `$psi.CreateNoWindow = `$true
    `$psi.RedirectStandardOutput = `$true; `$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    `$p = [System.Diagnostics.Process]::Start(`$psi)
    `$out = `$p.StandardOutput.ReadToEnd()
    `$p.WaitForExit(3000) | Out-Null
    return (`$out -replace '\x1b\[[0-?]*[ -/]*[@-~]', '').Trim()
}

try {
    while (-not `$vntProc.HasExited) {
        try {
            if ([Console]::KeyAvailable) {
                `$k = [Console]::ReadKey(`$true)
                if (`$k.Key -eq [ConsoleKey]::Q) { break }
            }
        } catch {}

        `$infoOut = try { Invoke-QuickVnt '--info' } catch { '' }
        `$listOut = try { Invoke-QuickVnt '--list' } catch { '' }
        `$allOut  = try { Invoke-QuickVnt '--all' } catch { '' }
        `$routeOut = try { Invoke-QuickVnt '--route' } catch { '' }

        `$devName = if (`$infoOut -match '(?m)^Name:\s*(.+)') { `$matches[1].Trim() } else { `$env:COMPUTERNAME }
        `$vip = if (`$infoOut -match '(?m)^Virtual ip:\s*(\S+)') { `$matches[1].Trim() } else { '分配中...' }
        `$connStatus = if (`$infoOut -match '(?m)^Connection status:\s*(\S+)') { `$matches[1].Trim() } else { 'Connecting' }
        `$natType = if (`$infoOut -match '(?m)^NAT type:\s*(\S+)') { `$matches[1].Trim() } else { '探测中' }
        `$localAddr = if (`$infoOut -match '(?m)^Local addr:\s*(\S+)') { `$matches[1].Trim() } else { '-' }

        `$allLines = @()
        if (`$allOut -and `$allOut -notmatch 'No other devices found') {
            `$allLines = @(`$allOut -split '\r?\n' | Select-Object -Skip 1 | Where-Object { `$_.Trim() -ne '' })
        }
        `$onlinePeers = @(`$allLines | Where-Object { `$_ -match '\bOnline\b' })
        `$totalPeople = 1 + `$allLines.Count
        `$onlinePeople = 1 + `$onlinePeers.Count

        `$srvRt = '-'
        if (`$routeOut -match '(?m)^10\.\d+\.\d+\.1\s+\S+\s+\d+\s+(\d+)') { `$srvRt = `$matches[1] }

        try { `$Host.UI.RawUI.WindowTitle = "🟢 VNT 联机中 [`$vip | 在线 `${onlinePeople}人] - `$roomToken (关闭本窗口即自动断开联机)" } catch {}

        try { [Console]::Clear() } catch {}
        Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "║  🎮  VNT 峡谷模拟联机群 · 实时联机状态监控台                                 ║" -ForegroundColor Yellow
        Write-Host "║  🛑  【重要提示】直接关闭本窗口 (点击右上角 × 或按 Q / Ctrl+C)               ║" -ForegroundColor Red
        Write-Host "║      即可【自动断开联机】并卸载虚拟网卡！联机期间请保持本窗口开启(可最小化)  ║" -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
        Write-Host ""
        `$connBadge = if (`$connStatus -eq 'Connected') { "🟢 已连接 (Connected)" } else { "🟡 连接中 (`$connStatus)" }
        `$srvSignal = if (`$srvRt -match '^\d+$' -and [int]`$srvRt -lt 80) { "▂▄▆█ 极佳 (`${srvRt}ms)" } elseif (`$srvRt -match '^\d+$' -and [int]`$srvRt -lt 200) { "▂▄▆_ 良好 (`${srvRt}ms)" } else { "▂▄__ (`${srvRt}ms)" }
        Write-Host "  🏠 房间名称 : `$roomToken      🔐 房间密码 : `$(if(`$roomPwd){`$roomPwd}else{'无密码'})" -ForegroundColor Cyan
        Write-Host "  👥 房间人数 : 当前在线 `$onlinePeople 人 / 房间共 `$totalPeople 人 (本机 + `$(`$onlinePeers.Count) 位在线队友)" -ForegroundColor Green
        Write-Host "  📶 本机状态 : `$connBadge   |   主干信号 : `$srvSignal" -ForegroundColor White
        Write-Host "  🖥️ 本机节点 : `$vip (`$devName)   |   NAT类型 : `$natType   |   物理出口 : `$localDev (`$localAddr)" -ForegroundColor Gray
        Write-Host "────────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  📡 【房间队友状态与信号质量】" -ForegroundColor Cyan
        if (`$allLines.Count -eq 0) {
            Write-Host "     ⏳ 当前房间暂无其他队友，等待队友使用房间名「`$roomToken」与密码「`$roomPwd」加入..." -ForegroundColor Yellow
        } else {
            foreach (`$line in `$allLines) {
                if (`$line -match '^\s*(.+?)\s+(10\.\d+\.\d+\.\d+)\s+(Online|Offline)(?:\s+(\S+))?(?:\s+(\d+))?') {
                    `$pName = `$matches[1].Trim()
                    `$pIp   = `$matches[2].Trim()
                    `$pStat = `$matches[3].Trim()
                    `$pMode = if (`$matches[4]) { `$matches[4].Trim() } else { '-' }
                    `$pRt   = if (`$matches[5]) { `$matches[5].Trim() } else { '-' }
                    if (`$pStat -eq 'Online') {
                        `$modeStr = if (`$pMode -match '(?i)p2p') { '⚡ P2P直连' } else { "🔄 服务器中继(`$pMode)" }
                        `$sigStr = if (`$pRt -match '^\d+$') {
                            `$rtVal = [int]`$pRt
                            if (`$rtVal -ge 9000) { '🟢 ▂▄▆█ 测速中...' }
                            elseif (`$rtVal -lt 60) { "🟢 ▂▄▆█ 极佳 (`${rtVal}ms)" }
                            elseif (`$rtVal -lt 130) { "🟢 ▂▄▆_ 良好 (`${rtVal}ms)" }
                            elseif (`$rtVal -lt 200) { "🟡 ▂▄__ 一般 (`${rtVal}ms)" }
                            else { "🔴 ▂___ 高延迟 (`${rtVal}ms)" }
                        } else { '探测中...' }
                        Write-Host ("     🟢 [在线] {0,-12} 虚拟IP: {1,-11} 模式: {2,-12} 信号: {3}" -f `$pName, `$pIp, `$modeStr, `$sigStr) -ForegroundColor Green
                    } else {
                        Write-Host ("     ⚪ [离线] {0,-12} 虚拟IP: {1,-11} 状态: 离线" -f `$pName, `$pIp) -ForegroundColor DarkGray
                    }
                } else {
                    Write-Host "     `$line"
                }
            }
        }
        if (`$listOut -match 'Mismatch') {
            Write-Host "     🚨 [加密告警] 检测到密码不一致 (Mismatch)！请提醒队友将密码设为: `$roomPwd" -ForegroundColor Red
        }
        Write-Host "────────────────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  📜 【VNT-CLI 底层连接与路由日志】" -ForegroundColor Cyan
        `$hasFileLogs = `$false
        if (Test-Path -LiteralPath `$logFile) {
            `$logs = @(Get-Content -LiteralPath `$logFile -Tail 5 -ErrorAction SilentlyContinue | Where-Object { `$_.Trim() -ne '' })
            if (`$logs.Count -gt 0) {
                `$hasFileLogs = `$true
                foreach (`$l in `$logs) {
                    `$cleanLine = (`$l -replace '\x1b\[[0-?]*[ -/]*[@-~]', '').Trim()
                    if (`$cleanLine -match 'Connect Successfully|register ip') {
                        Write-Host "     `$cleanLine" -ForegroundColor Green
                    } else {
                        Write-Host "     `$cleanLine" -ForegroundColor DarkGray
                    }
                }
            }
        }
        if (-not `$hasFileLogs) {
            Write-Host "     connect address=`$srvAddr | tun=vnt-tun | virtual_ip=`$vip" -ForegroundColor DarkGray
            if (`$connStatus -eq 'Connected') {
                Write-Host "     register ip=`$vip, netmask=255.255.255.0, gateway=10.26.0.1  ====== Connect Successfully ======" -ForegroundColor Green
            }
            if (`$routeOut) {
                foreach (`$rl in (`$routeOut -split '\r?\n' | Select-Object -First 4)) {
                    if (`$rl.Trim()) { Write-Host "     [Route] `$(`$rl.Trim())" -ForegroundColor DarkGray }
                }
            }
        }
        Write-Host "════════════════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        Write-Host "  ⏱️ 实时刷新: `$(Get-Date -Format 'HH:mm:ss') (每 2 秒自动更新)  |  👉 按 [Q] 键或关闭右上角 [×] 立即断开联机" -ForegroundColor Yellow

        Start-Sleep -Seconds 2
        `$vntProc.Refresh()
    }
} finally {
    try { [void](Invoke-QuickVnt '--stop') } catch {}
    try { Stop-Process -Id `$vntProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    Remove-Item -LiteralPath `$pidFile -Force -ErrorAction SilentlyContinue
}
"@

    $dashB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dashScript))
    $winStyle = if ($NO_WINDOW) { "Hidden" } else { "Normal" }
    if (Test-IsAdmin) {
        $wmiVntCmd = "powershell.exe -NoProfile -WindowStyle Hidden -Command `"Start-Process -FilePath '$escapedPsExe' -ArgumentList '-NoProfile -Command \`"Invoke-Expression ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''$dashB64'')))\`"' -WorkingDirectory '$escapedWorkDir' -WindowStyle $winStyle`""
    } else {
        $wmiVntCmd = "powershell.exe -NoProfile -WindowStyle Hidden -Command `"Start-Process -FilePath '$escapedPsExe' -ArgumentList '-NoProfile -Command \`"Invoke-Expression ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''$dashB64'')))\`"' -WorkingDirectory '$escapedWorkDir' -Verb RunAs -WindowStyle $winStyle`""
    }
    $wmiRes = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine      = $wmiVntCmd
        CurrentDirectory = $script:VNT_WORK_DIR
    }

    Write-Host "⏳ 正在弹出「VNT 实时联机监控台」窗口并挂载系统虚拟网卡 (Launcher PID: $($wmiRes.ProcessId))..."

    $connected = $false
    $vip = ""
    for ($i = 1; $i -le 45; $i++) {
        Start-Sleep -Milliseconds 300
        try {
            $infoRes = Invoke-VntCmd @("--info")
            if ($infoRes.ExitCode -eq 0 -and $infoRes.Output -match 'Connection status:\s*Connected') {
                if ($infoRes.Output -match '(?m)^Virtual ip:\s*(\S+)') {
                    $vip = $matches[1].Trim()
                }
                # 等待 Windows Wintun 网卡完成 IPv4 DAD (AddressState 变为 Preferred)，避免首次自检 Ping 失败
                $tunIpObj = if ($vip) { Get-NetIPAddress -IPAddress $vip -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object AddressState -eq 'Preferred' } else { $null }
                if ($tunIpObj) {
                    $connected = $true
                    break
                }
            }
        } catch {}
    }

    if ($connected) {
        $vntRunning = Get-Process -Name "vnt-cli" -ErrorAction SilentlyContinue | Select-Object -First 1
        $monPid = if (Test-Path -LiteralPath $MONITOR_PID_FILE) { (Get-Content -LiteralPath $MONITOR_PID_FILE -ErrorAction SilentlyContinue | Select-Object -First 1) } else { "-" }
        Write-Host "✅ 成功加入/创建「${ROOM_TOKEN}」房间并挂载系统级 vnt-tun 虚拟网卡 (VNT PID: $($vntRunning.Id), 监控台 PID: $monPid)！"
        if (-not $NO_WINDOW) {
            Write-Host "🖥️ 已弹出「VNT 实时联机状态监控台」独立窗口（实时展示在线人数、信号质量、底层日志，关闭窗口或按 Q/Ctrl+C 即自动断开联机）！"
        }
    } else {
        Write-Host "❌ 连接超时或虚拟网卡创建失败。"
        if (Test-Path -LiteralPath $LOG_FILE) { Get-Content -LiteralPath $LOG_FILE -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $ERR_LOG_FILE) { Get-Content -LiteralPath $ERR_LOG_FILE -ErrorAction SilentlyContinue }
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
    Find-VntBins
    Write-Host "=================================================================="
    Write-Host "📊 [3/4] 房间加入情况与系统虚拟网卡状态"
    Write-Host "=================================================================="

    $infoRes = $null
    try {
        $infoRes = Invoke-VntCmd @("--info")
    } catch {}

    if (-not $infoRes -or $infoRes.ExitCode -ne 0 -or $infoRes.Output -notmatch 'Connection status:') {
        Write-Host "❌ 当前没有正在运行的 VNT 联机进程。"
        exit 1
    }

    $infoOut = $infoRes.Output
    $vip = ""
    if ($infoOut -match '(?m)^Virtual ip:\s*(\S+)') {
        $vip = $matches[1].Trim()
    }

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

    Write-Host "【本机节点信息 (vnt-cli --info)】"
    Write-Host $infoOut
    Write-Host ""

    Write-Host "【房间内成员列表与加密状态校验 (vnt-cli --list & --all)】"
    $listRes = Invoke-VntCmd @("--list")
    $allRes = Invoke-VntCmd @("--all")
    Write-Host $allRes.Output
    if ($listRes.Output -match 'Mismatch') {
        Write-Host "🚨 告警: 检测到 Mismatch！说明本机与房间内队友设置的密码 (-w) 不一致，请确保全员使用相同密码重连！"
    }
    if ($allRes.Output -match 'No other devices found') {
        Write-Host "💡 状态说明: 当前房间「${ROOM_TOKEN}」内暂无其他队友，本机已作为房主成功建房，等待队友使用相同房间名与密码加入。"
    } else {
        $lines = @($allRes.Output -split '\r?\n' | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne '' })
        $onlineLines = @($lines | Where-Object { $_ -match '\bOnline\b' })
        Write-Host "💡 状态说明: 当前房间内共记录 $($lines.Count) 位队友（其中在线 Online: $($onlineLines.Count) 位）！"
    }
    Write-Host ""

    Write-Host "【数据转发路由表 (vnt-cli --route)】"
    $routeRes = Invoke-VntCmd @("--route")
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
        [int]$IntervalMs = 200,
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
        $minMs = $null
        $avgMs = $null
        $maxMs = $null
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
# 4. 测试连接稳定性（含高延迟 >= 200ms 异常判定与排查）
# ------------------------------------------------------------------------------
function Test-Stability {
    Find-VntBins
    Write-Host "=================================================================="
    Write-Host "🩺 [4/4] 连接稳定性测试报告 (Stability Test - TUN Mode)"
    Write-Host "=================================================================="

    $infoRes = $null
    try { $infoRes = Invoke-VntCmd @("--info") } catch {}
    if (-not $infoRes -or $infoRes.ExitCode -ne 0 -or $infoRes.Output -notmatch 'Connection status:') {
        Write-Host "❌ 未检测到运行中的 VNT 节点，无法执行稳定性测试。"
        exit 1
    }

    $infoOut = $infoRes.Output
    $vip = if ($infoOut -match '(?m)^Virtual ip:\s*(\S+)') { $matches[1].Trim() } else { "" }
    $natType = if ($infoOut -match '(?m)^NAT type:\s*(\S+)') { $matches[1].Trim() } else { "" }
    $relaySrv = if ($infoOut -match '(?m)^Relay server:\s*(\S+)') { $matches[1].Trim() } else { "" }
    $pubIp = if ($infoOut -match '(?m)^Public ips:\s*(\S+)') { $matches[1].Trim() } else { "" }
    $relayIp = ($relaySrv -split ':')[0]

    $highLatencyDetected = $false
    $maxObservedRtt = 0
    $relayModePeers = $false

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
    Write-Host "2️⃣  VNT 房间会话心跳连续采样 (5 次 / 间隔 0.2s):"
    $okSamples = 0
    for ($i = 1; $i -le 5; $i++) {
        $sampleRes = Invoke-VntCmd @("--info")
        $curStatus = if ($sampleRes.Output -match '(?m)^Connection status:\s*(\S+)') { $matches[1].Trim() } else { "Disconnected" }
        if ($curStatus -eq "Connected") {
            $okSamples++
            Write-Host "   - 采样 #${i}: Connected (虚拟IP: ${vip}, NAT类型: ${natType})"
        } else {
            Write-Host "   - 采样 #${i}: 异常 ($curStatus)"
        }
        if ($i -lt 5) { Start-Sleep -Milliseconds 200 }
    }
    Write-Host "   👉 会话保持率: $($okSamples * 20)% (${okSamples}/5)"
    Write-Host ""

    # 3) 测试中继/注册服务器网络延迟与丢包率
    if ($relayIp) {
        Write-Host "3️⃣  注册/中继服务器 (${relayIp}) 链路稳定性测试 (10 个 ICMP 包):"
        $srvPing = Invoke-PingStats -TargetIp $relayIp -Count 10 -IntervalMs 50 -TimeoutMs 1000
        if ($srvPing.Received -gt 0) {
            Write-Host "   Packets: Sent = $($srvPing.Sent), Received = $($srvPing.Received), Lost = $($srvPing.Sent - $srvPing.Received) ($($srvPing.LossPercent)% loss)"
            Write-Host "   round-trip min/avg/max = $($srvPing.MinMs)/$($srvPing.AvgMs)/$($srvPing.MaxMs) ms"
            if ($srvPing.AvgMs -ge $HIGH_LATENCY_THRESHOLD_MS) {
                $highLatencyDetected = $true
                if ($srvPing.AvgMs -gt $maxObservedRtt) { $maxObservedRtt = $srvPing.AvgMs }
                Write-Host "   ⚠️ 告警: 到中继服务器平均延迟高达 $($srvPing.AvgMs) ms (>= $HIGH_LATENCY_THRESHOLD_MS ms 阈值)！"
            }
        } else {
            Write-Host "   ⚠️ 服务器禁 Ping 或存在丢包 (Lost = $($srvPing.LossPercent)%)"
        }
        Write-Host ""
    }

    # 4) 测试房间内在线队友节点连通性与 P2P/Relay 状态
    Write-Host "4️⃣  房间内队友节点连通性与打洞分析 (TUN 虚拟局域网直连 Ping):"
    $allRes = Invoke-VntCmd @("--all")
    $allOut = $allRes.Output
    if ($allOut -match 'No other devices found') {
        Write-Host "   ℹ️ 当前房间内暂无其他队友在线，跳过队友节点 Ping 测速（队友加入后可直接 ping 10.26.0.x）。"
    } else {
        foreach ($line in ($allOut -split '\r?\n')) {
            Write-Host "   $line"
        }
        $peerLines = @($allOut -split '\r?\n' | Select-Object -Skip 1 | Where-Object { $_ -match '\bOnline\b' })
        if ($peerLines.Count -eq 0) {
            Write-Host "   ℹ️ 当前房间内记录的历史队友均处于 Offline 状态，等待队友上线后即可直接测试 P2P 连通性。"
        } else {
            foreach ($pLine in $peerLines) {
                if ($pLine -match '(?i)relay') {
                    $relayModePeers = $true
                }
                if ($pLine -match '\b(10\.\d+\.\d+\.\d+)\b') {
                    $pip = $matches[1]
                    Write-Host "   📡 正在通过 vnt-tun 虚拟网卡 Ping 在线队友虚拟 IP ($pip):"
                    $peerPing = Invoke-PingStats -TargetIp $pip -Count 6 -IntervalMs 100 -TimeoutMs 1000
                    if ($peerPing.Received -gt 0) {
                        Write-Host "      Packets: Sent = $($peerPing.Sent), Received = $($peerPing.Received), Lost = $($peerPing.Sent - $peerPing.Received) ($($peerPing.LossPercent)% loss)"
                        Write-Host "      round-trip min/avg/max = $($peerPing.MinMs)/$($peerPing.AvgMs)/$($peerPing.MaxMs) ms"
                        if ($peerPing.AvgMs -ge $HIGH_LATENCY_THRESHOLD_MS) {
                            $highLatencyDetected = $true
                            if ($peerPing.AvgMs -gt $maxObservedRtt) { $maxObservedRtt = $peerPing.AvgMs }
                            Write-Host "      🚨 异常告警: 队友 ($pip) 平均延迟高达 $($peerPing.AvgMs) ms (远超正常局域网/P2P 阈值)！"
                        }
                    } else {
                        Write-Host "      ❌ Ping 队友 ($pip) 100% 丢包！请检查双方密码 (-w) 是否一致（是否 Mismatch）或防火墙是否拦截 ICMP。"
                        $highLatencyDetected = $true
                    }
                }
            }
        }
    }
    Write-Host ""

    # 5) 综合联机质量评估与高延迟异常排查
    Write-Host "5️⃣  综合联机质量评估:"
    if ($okSamples -lt 5) {
        Write-Host "   🔴 【异常 - 会话闪断】检测到连接状态不稳定 (${okSamples}/5)，请检查是否同机开启了多个相同房间实例，或防火墙拦截。"
    } elseif ($highLatencyDetected) {
        Write-Host "   🔴 【异常 - 高延迟或丢包告警 (实测延迟约 ${maxObservedRtt} ms >= ${HIGH_LATENCY_THRESHOLD_MS} ms，需立即排查)】"
        Write-Host "   🛠️  自动根因排查报告 (Root-Cause Diagnosis):"
        $routeInfo = Find-NetRoute -RemoteIPAddress $relayIp -ErrorAction SilentlyContinue | Select-Object -First 1
        $routeIf = if ($routeInfo) { $routeInfo.InterfaceAlias } else { "" }
        $vpnProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'corplink|clash|mihomo|verge|surge|sing-box|shadowrocket|tailscale|anyconnect' } |
            Select-Object -ExpandProperty Name -Unique)
        if ($routeIf -match 'Meta|Clash|utun|tun|tap|CorpLink') {
            Write-Host "      1. [命中] 本机 VPN / 代理软件 TUN 路由抢占：系统默认路由被虚拟网卡 [$routeIf] 劫持（检测到进程: $($vpnProcs -join ', ')，公网出口 IP: $pubIp），可能导致流量绕行海外或企业网关，单程增加 300ms+ 延迟！"
            Write-Host "         👉 解决：使用本脚本 join 自动绑定 --local-dev 物理网卡，或关闭代理软件 TUN 模式 / 将 $relayIp ($DEFAULT_SERVER_HOST) 设为直连 (DIRECT)。"
        }
        if ($relayModePeers) {
            Write-Host "      2. [命中] 节点未建立 P2P 直连（当前为 relay 中继转发）：若对端使用 5G 移动流量（Symmetric 对称型 NAT）或挂有 VPN 代理，会导致 UDP 打洞失败而被迫走服务器中继。"
            Write-Host "         👉 解决：将手机/队友切换至普通宽带 Wi-Fi（Cone NAT），并关闭代理 TUN 后重连，即可恢复 10~50ms 的 P2P 直连。"
        }
    } elseif ($natType -eq "Cone") {
        Write-Host "   🟢 【极佳 (Wintun 模式 + 低延迟 < ${HIGH_LATENCY_THRESHOLD_MS}ms + Cone NAT)】系统级 vnt-tun 虚拟网卡已就绪，连接稳定且延迟正常，非常适合「峡谷模拟联机群」稳定联机！"
    } else {
        Write-Host "   🟡 【良好 (Wintun 模式 + 低延迟 < ${HIGH_LATENCY_THRESHOLD_MS}ms + $natType NAT)】系统级 vnt-tun 虚拟网卡已就绪，延迟正常。"
    }
    Write-Host "=================================================================="
}

# ------------------------------------------------------------------------------
# CLI 参数解析（兼容 vnt_room.sh 的位置参数与 -k/-w/-n/-s 选项）
# ------------------------------------------------------------------------------
$ACTION = "join"
$idx = 0
if ($args.Count -gt 0 -and $args[0] -notmatch '^-') {
    $ACTION = $args[0].ToLower()
    $idx = 1
}

while ($idx -lt $args.Count) {
    $arg = [string]$args[$idx]
    switch -Regex ($arg) {
        '^(-Action|--action)$' {
            if ($idx + 1 -lt $args.Count) { $ACTION = ([string]$args[$idx + 1]).ToLower(); $idx += 2 } else { $idx++ }
        }
        '^(-k|--room|--token|-Room)$' {
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
        '^(--local-dev|-LocalDevice)$' {
            if ($idx + 1 -lt $args.Count) { $LOCAL_DEV = [string]$args[$idx + 1]; $idx += 2 } else { $idx++ }
        }
        '^(--no-window|-NoWindow)$' {
            $NO_WINDOW = $true
            $idx++
        }
        '^(-h|--help|-Help)$' {
            Write-Host "用法: powershell -ExecutionPolicy Bypass -File .\vnt_room.ps1 [join|precheck|status|test|stop|auth|install] [-k 房间名] [-w 密码] [-n 设备昵称] [-s 服务器地址] [--local-dev 物理网卡名]"
            exit 0
        }
        default {
            $idx++
        }
    }
}

switch -Regex ($ACTION) {
    '^install$' {
        Install-VntCli
    }
    '^(auth|grant)$' {
        Ensure-TunPrivilege
    }
    '^(precheck|check)$' {
        Invoke-Precheck
    }
    '^(join|create|start)$' {
        Join-VntRoom
    }
    '^monitor$' {
        Start-VntMonitor
    }
    '^(status|info|list)$' {
        Show-Status
    }
    '^(test|ping)$' {
        Test-Stability
    }
    '^(stop|leave|exit)$' {
        Stop-Vnt
        Write-Host "🛑 已退出「${ROOM_TOKEN}」虚拟局域网房间并卸载系统级 vnt-tun 虚拟网卡。"
    }
    default {
        Write-Host "未知操作: $ACTION (支持: join | precheck | status | test | stop | auth | install)"
        exit 1
    }
}
