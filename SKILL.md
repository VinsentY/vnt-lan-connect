---
name: vnt-lan-connect
description: >-
  Use this skill when the user wants to use VNT-CLI for intranet penetration (内网穿透) or virtual LAN
  gaming (虚拟局域网联机), especially to join or create the "峡谷模拟联机群" room, set a room password,
  check room join status and online peers, or test connection stability.
---

# VNT-CLI 内网穿透与「峡谷模拟联机群」联机管理 (`vnt-lan-connect`)

基于 **VNT-CLI**（Virtual Network Tool）快速组建加密虚拟局域网，实现跨地域异地联机与内网穿透。支持一键完成**前置环境检查（防火墙 / 蒲公英冲突检测）** → **加入/创建「峡谷模拟联机群」房间并设置密码** → **返回本机虚拟 IP 与房间成员列表** → **执行连接稳定性与打洞质量测试**。

### 默认联机配置与跨平台脚本入口

- **默认房间名（`-k`）**：`峡谷模拟联机群`
- **默认房间密码（`-w`）**：`200008`（脚本未传 `-w` 时默认使用 `200008`；如需无密码模式可传 `--no-password` 或 `-w ""`）

| 操作系统 | 脚本路径 | 调用方式示例 |
| :--- | :--- | :--- |
| **macOS / Linux** | [scripts/vnt_room.sh](./scripts/vnt_room.sh) | `bash <SKILL_DIR>/scripts/vnt_room.sh <action> [参数]` |
| **Windows** | [scripts/vnt_room.ps1](./scripts/vnt_room.ps1) | `powershell -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>/scripts/vnt_room.ps1 <action> [参数]` |

---

## 一、前置环境（Prerequisites）

1. **安装 `VNT-CLI`（强制系统级 TUN 虚拟网卡模式）**
   - 必须安装官方 `vnt-cli`，并**强制使用系统级 `TUN` 虚拟网卡模式**（macOS 下自动创建 `utunX` 虚拟网卡，Windows 下为 `wintun` / `vnt-tun`，Linux 下为 `vnt-tun`），将虚拟局域网 IP（如 `10.26.0.x/24`）直接挂载到系统网络层，确保所有游戏和系统应用无需端口映射即可直接通过虚拟局域网互通。
   - **一键检测与自动安装命令**（将 `<SKILL_DIR>` 替换为当前 Skill 所在目录，如 `.agents/skills/vnt-lan-connect`）：
     ```bash
     # macOS / Linux
     bash <SKILL_DIR>/scripts/vnt_room.sh install
     ```
     ```powershell
     # Windows (自动下载 vnt-cli.exe 与同目录匹配架构的 wintun.dll)
     powershell -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>/scripts/vnt_room.ps1 install
     ```
   - 脚本会自动识别当前系统架构（macOS `arm64`/`x86_64`、Linux `aarch64`/`x86_64`、Windows `AMD64`/`ARM64`/`x86`），从 GitHub Releases（`vnt-dev/vnt`）下载对应 `vnt-cli` 二进制包（Windows 同时自动下载并校验官方 `wintun.dll` 驱动至 `%LOCALAPPDATA%\Programs\VNT\v1.2.16`）。
   - **系统级 `TUN` 虚拟网卡权限授权（强制要求）**：
     - **macOS / Linux**：创建系统级 `utun` 虚拟网卡需要 `root (UID=0)` 权限。[vnt_room.sh](./scripts/vnt_room.sh) 在首次执行时会自动调用 macOS 原生系统权限弹窗（支持 Touch ID / 开机密码）配置 `/etc/sudoers.d/vnt-cli` 免密权限，也可单独执行授权或手动在终端执行：
       ```bash
       # 方式 A：调用脚本触发 macOS 系统授权弹窗
       bash <SKILL_DIR>/scripts/vnt_room.sh auth
       # 方式 B：在终端手动配置一次免密 sudoers
       echo "$USER ALL=(ALL) NOPASSWD: $(which vnt-cli)" | sudo tee /etc/sudoers.d/vnt-cli && sudo chmod 0440 /etc/sudoers.d/vnt-cli
       ```
     - **Windows**：创建 Wintun（`vnt-tun`）虚拟网卡需要管理员权限。[vnt_room.ps1](./scripts/vnt_room.ps1) 在 `join` 启动时会通过 WMI + `RunAs` 自动弹出独立的**「VNT 实时联机状态监控台」**窗口（内置隐藏托管 `vnt-cli.exe`，每 2 秒实时刷新房间在线人数、信号格、P2P/中继状态与底层路由日志，**直接关闭该窗口或按 `Q`/`Ctrl+C` 即自动断开联机并卸载虚拟网卡**；如需纯无窗口后台运行可附加 `--no-window`）。

---

## 二、注意事项（联机前必检项 Pre-flight Checks）

每次启动组网或排查联机不通、延迟高、频繁掉线时，**必须优先检查以下必检项**：

1. **检查是否关闭系统防火墙**
   - **原因**：系统防火墙常会拦截 UDP 打洞探测包（导致无法建立 P2P 直连而退化为服务器中继）以及拦截虚拟局域网内的 ICMP Ping 和游戏联机广播包。
   - **macOS 检查与关闭**：
     ```bash
     # 查看状态（输出 State = 0 表示已关闭）
     /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
     # 关闭防火墙
     sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off
     ```
   - **Windows 检查与关闭**：`Get-NetFirewallProfile` 或 `netsh advfirewall show allprofiles state` / `netsh advfirewall set allprofiles state off`
   - **Linux 检查与关闭**：`sudo ufw status` / `sudo ufw disable`

2. **检查是否关闭蒲公英（Oray PgyVPN / 蒲公英联机平台）**
   - **原因**：蒲公英客户端会创建独立的虚拟网卡并劫持 `10.x.x.x` / `172.x.x.x` 私有网段路由表，还会抢占本地 UDP 打洞端口，与 VNT 同时运行极易引发虚拟网段冲突或 P2P 打洞失败。
   - **macOS / Linux 检查命令**：
     ```bash
     ps aux | grep -iE "pgyvpn|pgyvisitor|oray|蒲公英" | grep -v grep
     ```
   - **Windows 检查命令**：
     ```powershell
     Get-CimInstance Win32_Process | Where-Object { $_.Name -match "pgyvpn|pgyvisitor|oray|aweseed|蒲公英" }
     ```
   - 若检测到相关进程，请先完全退出蒲公英客户端并断开其虚拟网卡连接，再启动 VNT-CLI。

3. **检查是否开启了其他 VPN / 代理软件 TUN 模式（如 CorpLink / Clash TUN / Surge 等虚拟网卡抢占路由）**
   - **原因**：当本机开启了企业 VPN（如 `CorpLink` `utunX`）或科学上网代理软件的 `TUN` / 增强模式（如 `Clash`、`mihomo`、`Meta`、`Surge`、`sing-box`、`Shadowrocket` 等）时，VNT 服务器（如 `8.134.66.150`）和 UDP 打洞流量会被劫持绕行至海外节点或企业网关，导致无法 P2P 直连、被迫走服务器中继（`server-relay`），且**往返延迟飙升至 `300ms ~ 500ms+`**。
   - **macOS / Linux 检查命令**：
     ```bash
     # 检查去往 VNT 服务器的路由是否被非物理网卡（如 utun4）劫持
     route -n get 8.134.66.150
     # 检查运行中的 VPN / 代理进程
     ps aux | grep -iE "corplink|clash|mihomo|verge|surge|sing-box|shadowrocket|tailscaled|anyconnect" | grep -v grep
     ```
   - **Windows 检查与自动规避**：
     - `vnt_room.ps1` 会自动通过 `Find-NetRoute -RemoteIPAddress 8.134.66.150` 检测出口网卡，当检测到 Clash `Fake-IP` (`198.18.0.0/15`) 或 `Meta` TUN 抢占默认路由时，自动通过阿里 DoH 解析服务器真实 IP 并添加 `--local-dev "<物理网卡名>"` 绑定物理网卡直连。
   - **通用解决方式**：关闭代理软件的 TUN 模式 / 全局 VPN，或在代理规则中将 `8.134.66.150`（`vnt.wherewego.top`）设为 `DIRECT`（直连）。

4. **避免同机多开相同房间实例**
   - 同一台设备（相同 `machine_uid`）在同一房间（相同 `-k` Token）只能运行一个客户端实例（切勿同时开启 VNT 桌面端与 `vnt-cli` 连接同一房间），否则服务端会因设备 ID 冲突反复互踢重连。

---

## 三、标准执行流程（Step-by-Step Workflow）

### 步骤 1：一键加入/创建「峡谷模拟联机群」房间并完成稳定性测试

优先使用封装好的一体化脚本（macOS/Linux 使用 [vnt_room.sh](./scripts/vnt_room.sh)，Windows 使用 [vnt_room.ps1](./scripts/vnt_room.ps1)），它会依次执行：**前置环境与防火墙/蒲公英检查 → 加入/创建房间 → 返回加入情况与房间成员列表 → 测试连接稳定性**：

```bash
# macOS / Linux：加入/创建默认的「峡谷模拟联机群」房间（默认密码：200008）
bash <SKILL_DIR>/scripts/vnt_room.sh join \
  -k "峡谷模拟联机群" \
  -w "200008" \
  -n "<可选：设备昵称>"
```

```powershell
# Windows PowerShell：加入/创建默认的「峡谷模拟联机群」房间（默认密码：200008）
powershell -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>/scripts/vnt_room.ps1 join `
  -k "峡谷模拟联机群" `
  -w "200008" `
  -n "<可选：设备昵称>"
```

- **说明**：
  - 在 VNT 中，**加入房间**与**创建房间**使用同一命令（`-k "峡谷模拟联机群"`）：当房间内尚无其他设备时，第一个连接的节点即自动创建该虚拟局域网房间；后续使用相同 `-k` 和相同密码 `-w` 的队友会自动加入同一局域网。
  - **重要**：同一房间内的所有队友**必须设置完全相同的密码（`-w`）**（或均不设密码），否则节点间因端到端加密密钥不一致（`--list` 显示 `Mismatch`）将无法互通。

### 步骤 2：单独查看房间加入情况与在线成员（`status`）

当房间已在后台运行时，随时查看本机虚拟 IP、连接状态及房间内队友列表：

```bash
# macOS / Linux
bash <SKILL_DIR>/scripts/vnt_room.sh status
```

```powershell
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>/scripts/vnt_room.ps1 status
```

或者直接调用原生 `vnt-cli` 命令：
- **查看本机加入详情**：`vnt-cli --info`
  - 核心关注字段：
    - `Connection status`: `Connected` 表示已成功接入房间
    - `Virtual ip`: 本机分配到的局域网虚拟 IP（如 `10.26.0.2`）
    - `NAT type`: `Cone`（锥形 NAT，极易成功打洞 P2P 直连）或 `Symmetric`（对称型 NAT）
    - `Relay server`: 当前注册与中继服务器地址
- **查看房间内其他成员列表**：`vnt-cli --list`（或 `vnt-cli --all` 查看完整信息）
  - 核心关注字段：
    - `Name`: 队友设备名称
    - `Virtual Ip`: 队友虚拟 IP
    - `P2P/Relay`: `p2p` 表示已建立点对点直连（延迟最低），`relay` 表示通过服务器中继转发（若显示 `Mismatch` 则表示双方 `-w` 密码不一致）
    - `Rt`: 节点间往返延迟（单位 ms）
    - `Status`: `Online` / `Offline`
- **查看数据转发路径**：`vnt-cli --route`

### 步骤 3：单独测试连接稳定性（`test`）

```bash
# macOS / Linux
bash <SKILL_DIR>/scripts/vnt_room.sh test
```

```powershell
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>/scripts/vnt_room.ps1 test
```

稳定性测试包含 4 个维度：
1. **房间会话心跳连续采样**：每隔 0.5 秒采样一次 `vnt-cli --info`，连续 5 次，确认 `Connection status` 保持 `100% Connected` 无闪断（排除同机多开互踢或网络阻断）。
2. **中继服务器 ICMP 稳定性测试**：对当前 `Relay server` 发送 10 个高速探测包，统计丢包率（`packet loss`）与最小/平均/最大延迟（`min/avg/max`）。
3. **队友节点连通性与打洞通道检测**：检查房间内所有 `Online` 队友的 `P2P/Relay` 模式与 `Rt` 延迟；并通过系统 `TUN` 虚拟网卡对队友 `Virtual Ip` 执行 `ping` 测试。
4. **综合联机质量评级与高延迟异常判定（延迟 `>= 200ms` / `400ms` 左右直接判为异常）**：
   - **🟢 极佳**：`TUN` 虚拟网卡生效、会话 100% 在线、延迟 `< 200ms`（P2P 直连通常 `< 50ms`）。
   - **🔴 异常（高延迟告警）**：**一旦发现服务器或队友 Ping 延迟达到 `200ms` 以上（如 `400ms` 左右）**，脚本立即判定为 **`🔴 异常 - 高延迟告警`**，并自动输出根因排查报告：
     1. 检查本机是否被 `CorpLink` / `Clash TUN` 等其他虚拟网卡抢占路由导致绕行海外；
     2. 检查对端是否处于 `server-relay` 中继模式或移动 5G 网络（`Symmetric` 对称型 NAT）导致 P2P 打洞未成功。

### 步骤 4：退出房间并停止后台服务（`stop`）

联机结束后，一键停止后台进程并清理虚拟网络会话：

```bash
# macOS / Linux
bash <SKILL_DIR>/scripts/vnt_room.sh stop
```

```powershell
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>/scripts/vnt_room.ps1 stop
```

---

## 四、原生 `vnt-cli` 常用命令速查表

| 场景 | 命令示例 | 说明 |
| :--- | :--- | :--- |
| **加入/创建「峡谷模拟联机群」并设密码** | `sudo vnt-cli -k "峡谷模拟联机群" -w "200008"` | 相同 `-k` 和 `-w` 的设备自动组成加密虚拟局域网（Windows 使用管理员权限运行 `vnt-cli.exe`） |
| **指定设备昵称加入房间** | `sudo vnt-cli -k "峡谷模拟联机群" -w "200008" -n "我的设备"` | 方便队友在 `--list` 中识别你的设备 |
| **查看本机加入状态与虚拟 IP** | `vnt-cli --info` | 查看 `Virtual ip`、`Connection status`、`NAT type` |
| **查看房间内在线队友及延迟** | `vnt-cli --list` | 查看队友虚拟 IP、`p2p`/`relay` 模式、延迟 `Rt` |
| **查看房间内所有成员完整详情** | `vnt-cli --all` | 包含队友版本、公网/内网地址及状态详情 |
| **查看当前数据包路由路径** | `vnt-cli --route` | 查看通往各虚拟 IP 的下一跳与接口 |
| **退出房间并停止服务** | `vnt-cli --stop` | 停止后台运行的 VNT 进程 |
