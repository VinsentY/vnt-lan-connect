---
name: vnt-lan-connect
description: >-
  Use VNT 2 (v2.0.11) on Windows for virtual LAN gaming and intranet connectivity,
  joining the "峡谷模拟联机群" room via the dedicated VPS server (154.23.172.117:29872),
  launching the interactive VNT console monitor, and verifying P2P connectivity while preserving Clash TUN.
---

# VNT 2 峡谷模拟联机群 · 联机管理 (`vnt-lan-connect`)

基于官方 **VNT 2.0.11**（`vnt2_cli.exe` + `vnt2_ctrl.exe`）与自建固定 VPS 节点（`154.23.172.117:29872`），在 Windows 下建立系统级 Wintun（`vnt-tun`）虚拟局域网网卡。支持一键完成 **前置环境自检 → 加入/创建「峡谷模拟联机群」并弹出独立实时监控台窗口 → 查看房间成员列表 → 执行连接稳定性测试**。

## 默认联机配置

配置来源：[config/vnt2.json](./config/vnt2.json)

| 配置项 | 默认值 | 说明 |
| :--- | :--- | :--- |
| **主服务器** | `quic://154.23.172.117:29872` | 自建 VPS（Debian 12，`vnts2 v2.0.9` systemd 常驻服务） |
| **备用协议** | `tcp://154.23.172.117:29872` | 同端口同时支持 QUIC / TLS-TCP / WSS |
| **房间名 (`--network-code`)** | `峡谷模拟联机群` | 服务端已配置白名单保护 |
| **房间密码 (`--password`)** | `200008` | 节点间 ChaCha20-Poly1305 端到端加密 |
| **客户端版本** | 官方 VNT `2.0.11` | Windows x64（`vnt2_cli.exe` + `vnt2_ctrl.exe` + 签名 `wintun.dll`） |

---

## 标准执行流程（Windows）

### 方式一：双击一键启动器（推荐日常使用）

直接双击仓库根目录下的 [一键启动VNT联机.cmd](./一键启动VNT联机.cmd)，自动执行环境检查、入房并弹出独立的 **「🟢 VNT 联机监控台」** 窗口。

### 方式二：PowerShell 命令行调用

```powershell
# 一键自检 + 加入房间 + 弹出独立监控台窗口 + 输出状态与稳定性报告
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>\scripts\vnt2_room.ps1 join

# 仅执行前置环境检查
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>\scripts\vnt2_room.ps1 precheck

# 查看当前房间加入情况与在线队友
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>\scripts\vnt2_room.ps1 status

# 执行连接稳定性与队友 Ping 测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>\scripts\vnt2_room.ps1 test

# 退出房间并卸载虚拟网卡
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <SKILL_DIR>\scripts\vnt2_room.ps1 stop
```

---

## 核心特性说明

1. **完整保留 VNT 1 经典控制台与独立监控窗口体验**：
   - `join` 启动时自动通过 `RunAs` 提权弹出独立的 **「🟢 VNT 联机监控台」** 窗口（内置隐藏托管 `vnt2_cli.exe`，每 2 秒自动刷新房间在线人数、信号格 `▂▄▆█`、P2P/中继模式、队友实时 Ping 延迟及底层路由日志）。
   - **直接点击监控台右上角 `×` 关闭窗口或按 `Q` 键，即自动停止 `vnt2_cli.exe` 并卸载 `vnt-tun` 虚拟网卡**。
2. **无缝兼容 Clash TUN（无需关闭代理，无需配 Fake-IP 规则）**：
   - 服务器直接使用纯公网 IP `154.23.172.117:29872`，不依赖域名解析，彻底规避 Clash `198.18.0.0/15` Fake-IP 劫持；
   - 脚本自动识别本机物理网卡（如 `以太网 5`）并通过 `--outbound-interface` 绑定物理出口直连。
