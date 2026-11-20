# vnt-lan-connect — Windows VNT 2 一键虚拟局域网联机工具 & Agent Skill

基于官方 **[VNT 2.0.11](https://github.com/vnt-dev/vnt)** 与系统级 **Wintun（`vnt-tun`）** 驱动的 Windows 一键虚拟局域网联机方案，同时也是一个开箱即用的 **AI Agent Skill**（兼容 Antigravity / Claude Code / Codex / Cursor 等支持 `SKILL.md` 的客户端）。

专为解决 Windows 局域网游戏联机中的高频痛点而设计：**自动下载并校验官方 VNT 2 + 签名 Wintun、无需关闭 Clash TUN 代理、一键弹出独立实时联机状态监控台（关窗即自动卸载虚拟网卡）**。

---

## ✨ 核心特性

- **开箱即用，自动校验安装**：自动下载官方 `vnt2_cli.exe`、`vnt2_ctrl.exe`（SHA-256 校验）与官方签名 `wintun.dll`。
- **无缝兼容 Clash TUN（无需关代理 / 无需改 Fake-IP 规则）**：
  - 支持直接通过纯公网 IP 连接服务器，彻底规避 Clash `198.18.0.0/15` Fake-IP 劫持；
  - 自动识别本机真实物理网卡并通过 `--outbound-interface` 绑定物理出口直连。
- **独立实时联机监控台 UI**：
  - 自动 UAC 提权弹出独立的 **「🟢 VNT 联机监控台」** 窗口；
  - 每 2 秒实时刷新房间在线人数、信号格（`▂▄▆█`）、P2P/中继模式、队友实时 Ping 延迟与底层日志；
  - **直接点击窗口右上角 `×` 或按 `Q` 键，即自动退出联机并清理 `vnt-tun` 虚拟网卡**。
- **支持作为 AI Agent Skill 调用**：提供标准 [SKILL.md](./SKILL.md)，让 AI 助手直接帮你完成环境自检、加入房间、查看在线队友、Ping 稳定性测试与退出清理。

---

## 🌐 默认公益体验节点与配置

配置文件：[config/vnt2.json](./config/vnt2.json)

| 项目 | 默认值 | 说明 |
| :--- | :--- | :--- |
| **服务器地址** | `quic://154.23.172.117:29872` | 备用协议：`tcp://154.23.172.117:29872` |
| **房间名称** | `峡谷模拟联机群` | 服务端已开启单房间白名单 |
| **房间密码** | `200008` | 节点间 ChaCha20-Poly1305 端到端加密 |
| **客户端版本** | 官方 VNT `2.0.11` | Windows x64 |

> [!NOTE]
> **公益体验房说明与安全提示**
> - 内置服务器与 `峡谷模拟联机群` 为作者无偿提供的**免费公共体验房**，随缘维护、不保证 SLA。当前服务端仅放行该默认房间名；如有自定义房间或长期稳定开黑需求，建议修改 `config/vnt2.json` 指向自建 `vnts2` 服务端（或提 Issue 交流）。
> - 加入公共虚拟局域网房间时，**请保持 Windows 防火墙开启，且不要将 `vnt-tun` 虚拟网卡修改为「专用网络（Private）」**（保持系统默认的「公用网络」配置即可拦截绝大多数非预期入站连接）。

---

## 🚀 快速开始（Windows）

### 方式一：双击一键启动（推荐）

克隆或下载解压本仓库后，直接双击根目录下的 **[一键启动VNT联机.cmd](./一键启动VNT联机.cmd)**：
1. 自动检测并安装 `vnt2_cli.exe`、`vnt2_ctrl.exe` 与签名 `wintun.dll`；
2. 自动绑定物理网卡出口绕过 Clash TUN；
3. 自动弹出 **「🟢 VNT 联机监控台」** 窗口；
4. 联机结束时直接关闭监控台窗口（`×` 或 `Q`）即自动断开并卸载虚拟网卡。

### 方式二：PowerShell 命令速查

```powershell
# 一键自检 + 加入房间并弹出实时监控台
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 join

# 仅执行前置环境检查（管理员权限、驱动、网络出口等）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 precheck

# 查看房间状态与在线队友
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 status

# 运行连接稳定性与队友 Ping 测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 test

# 停止联机并卸载虚拟网卡
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 stop
```

也可以通过命令行参数临时覆盖房间、密码或自建服务器地址：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 join `
  -k "你的房间名" -w "你的密码" -s "quic://<你的服务器IP>:29872"
```

### 方式三：作为 AI Agent Skill 挂载

将本仓库克隆到你的 Agent Skills 目录（例如 `~/.gemini/config/skills/vnt-lan-connect`、`~/.codex/skills/vnt-lan-connect` 或项目 `.agents/skills/vnt-lan-connect`），即可直接用自然语言让 AI 帮你联机、查状态或测延迟。

---

## 📚 更多文档

- [SKILL.md](./SKILL.md)：Agent Skill 调用规范与核心特性说明
- [references/vnt2.md](./references/vnt2.md)：`vnts2` 服务端部署参数、客户端原生命令与排查说明

## 📄 License

[MIT](./LICENSE)
