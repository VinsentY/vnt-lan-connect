# vnt-lan-connect

Windows 下的 **[VNT 2.0.11](https://github.com/vnt-dev/vnt)** 虚拟局域网联机 **AI Agent Skill** 与一键启动脚本，支持自动安装签名 Wintun 驱动、绕过 Clash TUN 劫持、独立实时监控台以及 AI 辅助排查网络连通性问题。

兼容 **Antigravity** / **Claude Code** / **Codex** / **Cursor** 等支持 `SKILL.md` 规范的 Agent 客户端。

---

## 快速开始

### 1. 作为 AI Agent Skill 安装（推荐）

```bash
npx skills add VinsentY/vnt-lan-connect
```

或手动克隆到你的 Agent Skills 目录（如 `~/.gemini/config/skills/vnt-lan-connect`、`~/.codex/skills/vnt-lan-connect` 或项目 `.agents/skills/vnt-lan-connect`），安装后可直接用自然语言让 AI 执行环境自检、加入房间、查看在线队友、测试 Ping 稳定性或排查断连问题。

### 2. 双击一键启动（Windows）

克隆或下载本仓库后，直接双击根目录下的 **[一键启动VNT联机.cmd](./一键启动VNT联机.cmd)**，会自动完成环境检测、入房并弹出 **「🟢 VNT 联机监控台」**；关闭监控台窗口（`×` 或按 `Q`）即自动退出并卸载 `vnt-tun` 虚拟网卡。

### 3. PowerShell 命令行

```powershell
# 一键自检 + 加入房间 + 弹出实时监控台
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 join

# 仅执行前置环境检查（管理员权限、驱动、物理网卡出口）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 precheck

# 查看房间状态与在线队友
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 status

# 执行连接稳定性与队友 Ping 测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 test

# 停止联机并卸载虚拟网卡
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 stop
```

如需连接自建 `vnts2` 服务端或自定义房间，可通过参数覆盖或直接修改 [config/vnt2.json](./config/vnt2.json)：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\vnt2_room.ps1 join `
  -k "你的房间名" -w "你的密码" -s "quic://<服务器IP>:29872"
```

---

## 核心特性

- **自动校验安装**：自动拉取官方 `vnt2_cli.exe`、`vnt2_ctrl.exe`（SHA-256 校验）与官方签名 `wintun.dll`。
- **无缝兼容 Clash TUN**：支持纯 IP 直连并自动识别本机物理网卡（`--outbound-interface`），无需关闭代理或配置 Fake-IP 规则。
- **独立实时监控台**：自动 UAC 提权弹窗，每 2 秒刷新在线人数、信号格（`▂▄▆█`）、P2P/中继状态、队友 Ping 延迟与底层日志，关窗即自动清理网卡。
- **AI 友好排障**：内置 `precheck / status / test / stop` 子命令与标准 [SKILL.md](./SKILL.md)，方便 Agent 直接读取状态与日志定位联机异常。

---

## 默认配置

配置文件：[config/vnt2.json](./config/vnt2.json)

| 配置项 | 默认值 | 说明 |
| :--- | :--- | :--- |
| **服务器地址** | `quic://154.23.172.117:29872` | 备用 `tcp://154.23.172.117:29872` |
| **房间名称** | `峡谷模拟联机群` | 默认服务端已配置单房间白名单 |
| **房间密码** | `200008` | ChaCha20-Poly1305 端到端加密 |
| **客户端版本** | 官方 VNT `2.0.11` | Windows x64 |

---

## 相关文档

- [SKILL.md](./SKILL.md) — Agent Skill 定义与调用规范
- [references/vnt2.md](./references/vnt2.md) — `vnts2` 服务端配置与原生客户端命令参考

## License

[MIT](./LICENSE)
