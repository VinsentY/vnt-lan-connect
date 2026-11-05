# 🎮 vnt-lan-connect — VNT 虚拟局域网一键联机 Skill

基于 **VNT-CLI** 的跨平台（Windows / macOS / Linux）加密虚拟局域网一键联机 Agent Skill，专为**「峡谷模拟联机群」**打造。

## ✨ 核心特性

- **零配置开箱即用**：默认内置房间名 `峡谷模拟联机群` 与房间密码 `200008`，自动下载并配置官方 `vnt-cli` 与系统级虚拟网卡驱动（Windows `wintun.dll` / macOS `utun` / Linux `vnt-tun`）。
- **防冲突与代理绕过**：
  - 自动检查系统防火墙与蒲公英（Oray PgyVPN）虚拟网卡冲突。
  - **动态适配不同电脑网卡**：自动识别每台电脑真实的物理网卡（如 `以太网`、`WLAN`、`en0`），并通过阿里 DoH 解析真实服务器 IP + `--local-dev` 绑定物理出口，彻底规避 **Clash / Surge / Mihomo 的 Fake-IP DNS 劫持与 TUN 虚拟网卡路由抢占**。
- **独立「VNT 实时联机状态监控台」窗口（Windows）**：
  - 联机后自动弹出彩色监控台窗口，每 2 秒刷新**房间在线人数**、**队友信号格（P2P 直连/服务器中继延迟）**与**底层路由日志**。
  - **关窗即停**：即使关闭了 Agent IDE，联机依然保持；**直接点击监控台右上角 `×`（或按 `Q` / `Ctrl+C`）即可自动断开联机并卸载虚拟网卡**。

---

## 🚀 给朋友的一键复制提示词（Prompt）

把下面这段话直接发给朋友，让朋友粘贴到自己的 AI Agent（Antigravity / Cursor / Claude Code / Codex / Trae 等）对话框里即可一键安装并建立联机：

```text
请帮我安装我朋友写的 VNT 联机 Skill（https://github.com/VinsentY/vnt-lan-connect）并立即按默认配置建立联机：

1. 直接执行 git clone https://github.com/VinsentY/vnt-lan-connect "$HOME/.gemini/config/skills/vnt-lan-connect"（若已存在则 git pull 更新；若使用其他 Agent 则克隆到对应的 skills/vnt-lan-connect 目录）。
2. 克隆完成后直接执行其中的 join 脚本（已内置默认房间名「峡谷模拟联机群」与默认密码「200008」，且包含状态查询与稳定性测试全流程，无需再单独跑 status/test）：
   - Windows: powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME/.gemini/config/skills/vnt-lan-connect/scripts/vnt_room.ps1" join
   - macOS / Linux: bash "$HOME/.gemini/config/skills/vnt-lan-connect/scripts/vnt_room.sh" join
3. 完成后告诉我本机分配到的虚拟 IP、房间内在线队友及延迟，并提醒我关闭弹出的「VNT 实时联机状态监控台」窗口即可自动断开联机。
```

---

## 🛠️ 手动命令行用法

### Windows (PowerShell)
```powershell
# 一键加入/创建默认房间（弹出实时状态监控台）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt_room.ps1 join

# 查看当前联机状态与队友列表
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt_room.ps1 status

# 停止联机并卸载虚拟网卡
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt_room.ps1 stop
```

### macOS / Linux (Bash)
```bash
# 一键加入/创建默认房间
bash ./scripts/vnt_room.sh join

# 查看当前联机状态与队友列表
bash ./scripts/vnt_room.sh status

# 停止联机
bash ./scripts/vnt_room.sh stop
```