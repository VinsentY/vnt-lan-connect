# VNT 2 启动、服务端配置与排查说明

## 1. 自建 VPS 服务端信息 (`vnts2`)

- **服务器地址**：`154.23.172.117`
- **服务端口**：`29872`（同时监听 `UDP/QUIC`、`TCP-TLS`、`WSS`）
- **版本与进程管理**：`vnts2 v2.0.9`，由 `systemd`（`vnts.service`）托管开机自启
- **服务端路径**：
  - 二进制：`/opt/vnts/vnts2`
  - 配置文件：`/var/lib/vnts/config.toml`
  - 证书指纹：`ac0babf9bc7796144912d0d48d495b915276ad72acc924a64829c63ffcf5d579`
- **常用运维命令**：
  ```bash
  systemctl status vnts
  journalctl -u vnts -n 50 --no-pager
  systemctl restart vnts
  ```

## 2. Windows 客户端使用 (`vnt2_room.ps1`)

默认安装路径为 `%LOCALAPPDATA%\Programs\VNT\v2.0.11`，包含：
- `vnt2_cli.exe`：核心组网客户端
- `vnt2_ctrl.exe`：状态查询控制器（支持 `info`、`clients`、`route`）
- `wintun.dll`：官方签名 Wintun 驱动

原生启动命令参考：
```powershell
vnt2_cli.exe --network-code "峡谷模拟联机群" --password "200008" --outbound-interface "<物理网卡名>" --server "quic://154.23.172.117:29872" --device-mode tun --tun-name vnt-tun
```
