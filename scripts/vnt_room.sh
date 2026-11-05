#!/usr/bin/env bash
# ==============================================================================
# VNT-CLI 峡谷模拟联机群 内网穿透管理与稳定性测试脚本（强制系统级 TUN 虚拟网卡模式）
# 用法:
#   ./vnt_room.sh join [-k "峡谷模拟联机群"] [-w "密码"] [-n "设备昵称"] [-s "服务器地址"]
#   ./vnt_room.sh precheck
#   ./vnt_room.sh status
#   ./vnt_room.sh test
#   ./vnt_room.sh stop
#   ./vnt_room.sh auth
#   ./vnt_room.sh install
# ==============================================================================
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

DEFAULT_ROOM="峡谷模拟联机群"
DEFAULT_PASSWORD="200008"
ROOM_TOKEN="$DEFAULT_ROOM"
ROOM_PASSWORD="$DEFAULT_PASSWORD"
DEVICE_NAME=""
SERVER_ADDR=""
LOG_FILE="/tmp/vnt_room_daemon.log"
VNT_VERSION="v1.2.16"
HIGH_LATENCY_THRESHOLD_MS=200

# ------------------------------------------------------------------------------
# 查找或安装 vnt-cli
# ------------------------------------------------------------------------------
find_vnt_bins() {
  VNT_CLI_BIN="$(command -v vnt-cli || true)"
}

install_vnt_cli() {
  find_vnt_bins
  if [[ -n "$VNT_CLI_BIN" ]]; then
    echo "✅ 已检测到 VNT-CLI: $VNT_CLI_BIN"
    return 0
  fi

  echo "📦 正在自动安装 VNT-CLI ($VNT_VERSION)..."
  local os arch tar_name url install_dir
  os="$(uname -s)"
  arch="$(uname -m)"

  if [[ "$os" == "Darwin" ]]; then
    if [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]; then
      tar_name="vnt-aarch64-apple-darwin-${VNT_VERSION}.tar.gz"
    else
      tar_name="vnt-x86_64-apple-darwin-${VNT_VERSION}.tar.gz"
    fi
  elif [[ "$os" == "Linux" ]]; then
    if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
      tar_name="vnt-aarch64-unknown-linux-musl-${VNT_VERSION}.tar.gz"
    else
      tar_name="vnt-x86_64-unknown-linux-musl-${VNT_VERSION}.tar.gz"
    fi
  else
    echo "❌ 当前操作系统 ($os $arch) 暂不支持脚本自动下载，请前往 https://github.com/vnt-dev/vnt/releases 下载 vnt-cli。"
    exit 1
  fi

  url="https://github.com/vnt-dev/vnt/releases/download/${VNT_VERSION}/${tar_name}"
  if [[ -d "/opt/homebrew/bin" && -w "/opt/homebrew/bin" ]]; then
    install_dir="/opt/homebrew/bin"
  else
    install_dir="$HOME/.local/bin"
    mkdir -p "$install_dir"
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  curl -sL "$url" | tar -xz -C "$tmp_dir"
  cp "$tmp_dir/vnt-cli" "$install_dir/"
  chmod +x "$install_dir/vnt-cli"
  rm -rf "$tmp_dir"

  find_vnt_bins
  echo "✅ VNT-CLI 安装完成: $VNT_CLI_BIN"
}

# ------------------------------------------------------------------------------
# 授权配置免密 TUN 虚拟网卡权限 (macOS 原生弹窗 / sudoers)
# ------------------------------------------------------------------------------
ensure_tun_privilege() {
  find_vnt_bins
  if [[ "$EUID" -eq 0 ]]; then
    return 0
  fi
  if sudo -n "$VNT_CLI_BIN" -h >/dev/null 2>&1; then
    return 0
  fi

  echo "🔐 检测到尚未授予 vnt-cli 创建系统级 TUN (utun) 虚拟网卡的免密权限。"
  if [[ "$(uname -s)" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
    echo "   正在弹出 macOS 系统权限授权窗口（请输入开机密码或验证 Touch ID）..."
    osascript -e "do shell script \"echo '$USER ALL=(ALL) NOPASSWD: $VNT_CLI_BIN, $HOME/.local/bin/vnt-cli' > /etc/sudoers.d/vnt-cli && chmod 0440 /etc/sudoers.d/vnt-cli\" with administrator privileges"
    if sudo -n "$VNT_CLI_BIN" -h >/dev/null 2>&1; then
      echo "✅ TUN 虚拟网卡免密权限授权成功！"
      return 0
    fi
  fi

  echo "❌ 未能获取 Root 权限，无法强制创建系统级 TUN 虚拟网卡。"
  echo "👉 请在终端手动执行一次："
  echo "   echo \"\$USER ALL=(ALL) NOPASSWD: $VNT_CLI_BIN\" | sudo tee /etc/sudoers.d/vnt-cli && sudo chmod 0440 /etc/sudoers.d/vnt-cli"
  exit 1
}

# ------------------------------------------------------------------------------
# 检查其他 VPN / 代理软件 TUN 路由抢占
# ------------------------------------------------------------------------------
check_vpn_tun_conflict() {
  local route_if vpn_procs has_conflict=0
  route_if="$(route -n get 8.134.66.150 2>/dev/null | awk '/interface:/ {print $2}' || true)"
  vpn_procs="$(ps aux | grep -iE 'corplink|clash|mihomo|verge|surge|sing-box|shadowrocket|tailscaled|anyconnect' | grep -v grep | grep -v 'vnt_room.sh' | awk '{print $11}' | awk -F'/' '{print $NF}' | sort -u | tr '\n' ' ' || true)"

  if [[ -n "$route_if" && "$route_if" == utun* ]]; then
    echo "⚠️ [注意事项 3 - VPN/代理 TUN 抢占检查] 检测到服务器路由被其他虚拟网卡 ($route_if) 劫持！"
    [[ -n "$vpn_procs" ]] && echo "   - 运行中的 VPN/代理进程: $vpn_procs"
    echo "   👉 影响: 流量可能被绕行至海外或企业网关，导致无法 P2P 直连且延迟飙升至 300~500ms+。"
    echo "   👉 建议: 关闭代理软件的 TUN 模式 / 全局 VPN，或在代理规则中将 8.134.66.150 (vnt.wherewego.top) 设为直连 (DIRECT)。"
    has_conflict=1
  elif [[ -n "$vpn_procs" ]]; then
    echo "⚠️ [注意事项 3 - VPN/代理 TUN 抢占检查] 检测到后台运行 VPN/代理软件 ($vpn_procs)，当前出口网卡为 ${route_if:-默认}（如遇高延迟请检查其 TUN 模式是否开启）。"
  else
    echo "✅ [注意事项 3 - VPN/代理 TUN 抢占检查] 未检测到其他 VPN/代理 TUN 抢占路由 (当前出口网卡: ${route_if:-en0})"
  fi
  return $has_conflict
}

# ------------------------------------------------------------------------------
# 1. 前置环境与注意事项自检 (Pre-flight Checks)
# ------------------------------------------------------------------------------
run_precheck() {
  echo "=================================================================="
  echo "🔍 [1/4] 前置环境与注意事项检查 (Pre-flight Check)"
  echo "=================================================================="

  # 1) 检查 VNT-CLI 安装情况
  find_vnt_bins
  if [[ -z "$VNT_CLI_BIN" ]]; then
    echo "⚠️ 未检测到 vnt-cli，正在自动安装..."
    install_vnt_cli
  else
    local ver
    ver="$("$VNT_CLI_BIN" -h 2>&1 | grep -i '^version:' | head -n 1 || echo 'unknown')"
    echo "✅ [前置环境 1 - VNT-CLI] 已安装: $VNT_CLI_BIN ($ver)"
  fi

  # 2) 强制检查系统级 TUN 虚拟网卡权限
  ensure_tun_privilege
  echo "✅ [前置环境 2 - TUN 网卡权限] 已具备系统级 TUN (utun) 虚拟网卡创建权限"

  # 3) 检查系统防火墙是否已关闭
  local os fw_state
  os="$(uname -s)"
  if [[ "$os" == "Darwin" ]]; then
    if [[ -x "/usr/libexec/ApplicationFirewall/socketfilterfw" ]]; then
      fw_state="$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || true)"
      if echo "$fw_state" | grep -qi "disabled"; then
        echo "✅ [注意事项 1 - 防火墙检查] macOS 系统防火墙已关闭 ($fw_state)"
      else
        echo "⚠️ [注意事项 1 - 防火墙检查] macOS 系统防火墙当前处于开启状态: $fw_state"
        echo "   👉 建议前往「系统设置 -> 网络 -> 防火墙」将其关闭，或执行:"
        echo "      sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off"
      fi
    fi
  elif [[ "$os" == "Linux" ]]; then
    if command -v ufw >/dev/null 2>&1; then
      fw_state="$(ufw status 2>/dev/null || true)"
      if echo "$fw_state" | grep -qi "inactive"; then
        echo "✅ [注意事项 1 - 防火墙检查] Linux UFW 防火墙已关闭"
      else
        echo "⚠️ [注意事项 1 - 防火墙检查] UFW 状态: $fw_state (建议执行 sudo ufw disable)"
      fi
    fi
  fi

  # 4) 检查蒲公英 (Oray PgyVPN / 蒲公英联机平台) 是否已关闭
  local pgy_procs
  pgy_procs="$(ps aux | grep -iE 'pgyvpn|pgyvisitor|oray|蒲公英' | grep -v grep | grep -v 'vnt_room.sh' || true)"
  if [[ -z "$pgy_procs" ]]; then
    echo "✅ [注意事项 2 - 蒲公英检查] 未检测到运行中的蒲公英 (PgyVPN/Oray) 进程，无虚拟网卡冲突"
  else
    echo "⚠️ [注意事项 2 - 蒲公英检查] 检测到蒲公英相关进程正在运行！可能导致虚拟网卡路由冲突或打洞失败："
    echo "$pgy_procs" | awk '{print "   - PID " $2 ": " $11}'
    echo "   👉 请先退出蒲公英客户端，或执行 kill 终止上述进程后再进行组网。"
  fi

  # 5) 检查其他 VPN / 代理软件 TUN 模式路由抢占 (CorpLink / Clash TUN 等)
  check_vpn_tun_conflict || true
  echo ""
}

# ------------------------------------------------------------------------------
# 停止已有 VNT 实例
# ------------------------------------------------------------------------------
stop_vnt() {
  find_vnt_bins
  if [[ -n "$VNT_CLI_BIN" ]]; then
    "$VNT_CLI_BIN" --stop >/dev/null 2>&1 || true
    sudo -n "$VNT_CLI_BIN" --stop >/dev/null 2>&1 || true
  fi
  pkill -f "vn-link-cli" >/dev/null 2>&1 || true
  pkill -f "vnt-cli -k" >/dev/null 2>&1 || true
  sleep 1
}

# ------------------------------------------------------------------------------
# 2. 加入/创建房间（强制 TUN 虚拟网卡模式）
# ------------------------------------------------------------------------------
join_room() {
  run_precheck

  echo "=================================================================="
  echo "🚀 [2/4] 加入/创建虚拟局域网房间 (强制 TUN 模式)"
  echo "=================================================================="
  echo "🏠 房间名称 (Token) : $ROOM_TOKEN"
  if [[ -n "$ROOM_PASSWORD" ]]; then
    echo "🔐 房间密码 (-w)    : 已设置 (端到端加密已启用)"
  else
    echo "🔓 房间密码 (-w)    : 未设置 (公开房间/无密码模式)"
  fi

  # 清理同一机器上的旧实例，防止同 machine_uid 互踢
  stop_vnt

  local cmd_args=("-k" "$ROOM_TOKEN")
  if [[ -n "$ROOM_PASSWORD" ]]; then
    cmd_args+=("-w" "$ROOM_PASSWORD")
  fi
  if [[ -n "$DEVICE_NAME" ]]; then
    cmd_args+=("-n" "$DEVICE_NAME")
  fi
  if [[ -n "$SERVER_ADDR" ]]; then
    cmd_args+=("-s" "$SERVER_ADDR")
  fi

  local runner_bin
  if [[ "$EUID" -eq 0 ]]; then
    runner_bin="$VNT_CLI_BIN"
  else
    runner_bin="sudo -n $VNT_CLI_BIN"
  fi

  echo "⚙️  启动模式        : 强制系统级 TUN 虚拟网卡模式 ($runner_bin)"
  : > "$LOG_FILE"
  # shellcheck disable=SC2086
  nohup $runner_bin "${cmd_args[@]}" > "$LOG_FILE" 2>&1 < /dev/null &
  local bg_pid=$!
  echo "⏳ 正在连接服务器并挂载系统虚拟网卡 (PID: $bg_pid)..."

  # 等待 Connected 状态 (最多等待 8 秒)
  local connected=0
  for _ in {1..16}; do
    sleep 0.5
    if sudo -n "$VNT_CLI_BIN" --info 2>/dev/null | grep -q "Connection status: Connected"; then
      connected=1
      break
    fi
  done

  if [[ "$connected" -eq 1 ]]; then
    echo "✅ 成功加入/创建「${ROOM_TOKEN}」房间并挂载系统级 TUN 虚拟网卡！"
  else
    echo "❌ 连接超时或虚拟网卡创建失败，运行日志如下："
    cat "$LOG_FILE" || true
    exit 1
  fi
  echo ""

  show_status
  test_stability
}

# ------------------------------------------------------------------------------
# 3. 查看加入情况与房间成员列表
# ------------------------------------------------------------------------------
show_status() {
  find_vnt_bins
  echo "=================================================================="
  echo "📊 [3/4] 房间加入情况与系统虚拟网卡状态"
  echo "=================================================================="

  local info_out all_out route_out vip tun_info
  if ! info_out="$(sudo -n "$VNT_CLI_BIN" --info 2>/dev/null || "$VNT_CLI_BIN" --info 2>&1)"; then
    echo "❌ 当前没有正在运行的 VNT 联机进程。"
    return 1
  fi

  vip="$(echo "$info_out" | awk -F': ' '/^Virtual ip:/ {print $2}' | tr -d '\r')"

  echo "【系统级 TUN 虚拟网卡挂载验证 (ifconfig)】"
  tun_info="$(ifconfig 2>/dev/null | grep -B 2 -A 1 "inet ${vip} " || true)"
  if [[ -n "$tun_info" ]]; then
    echo "$tun_info"
    echo "✅ 系统级 TUN 虚拟网卡已成功挂载并生效！"
  else
    echo "⚠️ 未在 ifconfig 中检测到绑定 ${vip} 的系统级 TUN 虚拟网卡！"
  fi
  echo ""

  echo "【本机节点信息 (vnt-cli --info)】"
  echo "$info_out"
  echo ""

  echo "【房间内其他成员完整列表 (vnt-cli --all)】"
  all_out="$(sudo -n "$VNT_CLI_BIN" --all 2>/dev/null || "$VNT_CLI_BIN" --all 2>&1 || true)"
  echo "$all_out"
  if echo "$all_out" | grep -qi "No other devices found"; then
    echo "💡 状态说明: 当前房间「${ROOM_TOKEN}」内暂无其他队友，本机已作为房主成功建房，等待队友使用相同房间名与密码加入。"
  else
    local peer_count
    peer_count="$(echo "$all_out" | awk 'NR>1 && NF>0 {count++} END {print count+0}')"
    echo "💡 状态说明: 当前房间内共有 ${peer_count} 位其他队友！"
  fi
  echo ""

  echo "【数据转发路由表 (vnt-cli --route)】"
  route_out="$(sudo -n "$VNT_CLI_BIN" --route 2>/dev/null || "$VNT_CLI_BIN" --route 2>&1 || true)"
  echo "$route_out"
  echo ""
}

# ------------------------------------------------------------------------------
# 4. 测试连接情况稳定（含高延迟 >= 200ms 异常判定与排查）
# ------------------------------------------------------------------------------
test_stability() {
  find_vnt_bins
  echo "=================================================================="
  echo "🩺 [4/4] 连接稳定性测试报告 (Stability Test - TUN Mode)"
  echo "=================================================================="

  local info_out
  if ! info_out="$(sudo -n "$VNT_CLI_BIN" --info 2>/dev/null || "$VNT_CLI_BIN" --info 2>/dev/null)"; then
    echo "❌ 未检测到运行中的 VNT 节点，无法执行稳定性测试。"
    return 1
  fi

  local vip vgw nat_type relay_srv pub_ip
  vip="$(echo "$info_out" | awk -F': ' '/^Virtual ip:/ {print $2}' | tr -d '\r')"
  vgw="$(echo "$info_out" | awk -F': ' '/^Virtual gateway:/ {print $2}' | tr -d '\r')"
  nat_type="$(echo "$info_out" | awk -F': ' '/^NAT type:/ {print $2}' | tr -d '\r')"
  relay_srv="$(echo "$info_out" | awk -F': ' '/^Relay server:/ {print $2}' | tr -d '\r')"
  pub_ip="$(echo "$info_out" | awk -F': ' '/^Public ips:/ {print $2}' | tr -d '\r')"
  local relay_ip="${relay_srv%%:*}"

  local high_latency_detected=0
  local max_observed_rtt=0
  local relay_mode_peers=""

  # 1) 验证本地 TUN 虚拟网卡 IP 可达性
  echo "1️⃣  本地系统 TUN 虚拟网卡 (${vip}) 连通性自检 (4 个 ICMP 包):"
  if ping -c 4 -i 0.2 -W 1000 "$vip" > /tmp/vnt_tun_ping.out 2>&1; then
    tail -n 2 /tmp/vnt_tun_ping.out | sed 's/^/   /'
  else
    echo "   ❌ 本地虚拟网卡 IP (${vip}) Ping 失败，请检查 TUN 网卡是否正确挂载！"
  fi
  echo ""

  # 2) 连续 5 次采样检查控制面连接状态是否掉线或闪断
  echo "2️⃣  VNT 房间会话心跳连续采样 (5 次 / 间隔 0.5s):"
  local ok_samples=0
  for i in {1..5}; do
    local cur_status
    cur_status="$((sudo -n "$VNT_CLI_BIN" --info 2>/dev/null || "$VNT_CLI_BIN" --info 2>/dev/null) | awk -F': ' '/^Connection status:/ {print $2}' | tr -d '\r')"
    if [[ "$cur_status" == "Connected" ]]; then
      ok_samples=$((ok_samples + 1))
      echo "   - 采样 #${i}: Connected (虚拟IP: ${vip}, NAT类型: ${nat_type})"
    else
      echo "   - 采样 #${i}: 异常 (${cur_status:-Disconnected})"
    fi
    [[ $i -lt 5 ]] && sleep 0.5
  done
  echo "   👉 会话保持率: $((ok_samples * 20))% (${ok_samples}/5)"
  echo ""

  # 3) 测试中继/注册服务器网络延迟与丢包率
  if [[ -n "$relay_ip" ]]; then
    echo "3️⃣  注册/中继服务器 (${relay_ip}) 链路稳定性测试 (10 个 ICMP 包):"
    local ping_out relay_avg
    if ping_out="$(ping -c 10 -i 0.2 -W 1000 "$relay_ip" 2>&1)"; then
      echo "$ping_out" | tail -n 2 | sed 's/^/   /'
      relay_avg="$(echo "$ping_out" | awk -F'=' '/round-trip/ {split($2,a,"/"); printf "%.0f", a[2]}')"
      if [[ -n "$relay_avg" && "$relay_avg" -ge "$HIGH_LATENCY_THRESHOLD_MS" ]]; then
        high_latency_detected=1
        [[ "$relay_avg" -gt "$max_observed_rtt" ]] && max_observed_rtt="$relay_avg"
        echo "   ⚠️ 告警: 到中继服务器平均延迟高达 ${relay_avg} ms (>= ${HIGH_LATENCY_THRESHOLD_MS} ms 阈值)！"
      fi
    else
      echo "   ⚠️ 服务器禁 Ping 或存在丢包："
      echo "$ping_out" | tail -n 2 | sed 's/^/   /'
    fi
    echo ""
  fi

  # 4) 测试房间内在线队友节点连通性与 P2P/Relay 状态
  echo "4️⃣  房间内队友节点连通性与打洞分析 (TUN 虚拟局域网直连 Ping):"
  local all_out
  all_out="$(sudo -n "$VNT_CLI_BIN" --all 2>/dev/null || "$VNT_CLI_BIN" --all 2>/dev/null || true)"
  if echo "$all_out" | grep -qi "No other devices found"; then
    echo "   ℹ️ 当前房间内暂无其他队友在线，跳过队友节点 Ping 测速（队友加入后可直接 ping 10.26.0.x）。"
  else
    echo "$all_out" | sed 's/^/   /'
    if echo "$all_out" | awk 'NR>1' | grep -qi "relay"; then
      relay_mode_peers="yes"
    fi
    local peer_ips
    peer_ips="$(echo "$all_out" | awk 'NR>1 && /Online/ {for(i=1;i<=NF;i++) if ($i ~ /^10\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i}')"
    for pip in $peer_ips; do
      echo "   📡 正在通过 TUN 虚拟网卡 Ping 队友虚拟 IP ($pip):"
      local peer_ping peer_avg
      if peer_ping="$(ping -c 6 -i 0.3 -W 1000 "$pip" 2>&1)"; then
        echo "$peer_ping" | tail -n 2 | sed 's/^/      /'
        peer_avg="$(echo "$peer_ping" | awk -F'=' '/round-trip/ {split($2,a,"/"); printf "%.0f", a[2]}')"
        if [[ -n "$peer_avg" && "$peer_avg" -ge "$HIGH_LATENCY_THRESHOLD_MS" ]]; then
          high_latency_detected=1
          [[ "$peer_avg" -gt "$max_observed_rtt" ]] && max_observed_rtt="$peer_avg"
          echo "      🚨 异常告警: 队友 ($pip) 平均延迟高达 ${peer_avg} ms (远超正常局域网/P2P 阈值)！"
        fi
      else
        echo "$peer_ping" | tail -n 2 | sed 's/^/      /'
        high_latency_detected=1
      fi
    done
  fi
  echo ""

  # 5) 综合联机质量评估与高延迟异常排查
  echo "5️⃣  综合联机质量评估:"
  if [[ "$ok_samples" -lt 5 ]]; then
    echo "   🔴 【异常 - 会话闪断】检测到连接状态不稳定 (${ok_samples}/5)，请检查是否同机开启了多个相同房间实例，或防火墙拦截。"
  elif [[ "$high_latency_detected" -eq 1 ]]; then
    echo "   🔴 【异常 - 高延迟告警 (实测延迟约 ${max_observed_rtt} ms >= ${HIGH_LATENCY_THRESHOLD_MS} ms，需立即排查)】"
    echo "   🛠️  自动根因排查报告 (Root-Cause Diagnosis):"
    local route_if vpn_procs
    route_if="$(route -n get "$relay_ip" 2>/dev/null | awk '/interface:/ {print $2}' || true)"
    vpn_procs="$(ps aux | grep -iE 'corplink|clash|mihomo|verge|surge|sing-box|shadowrocket|tailscaled|anyconnect' | grep -v grep | grep -v 'vnt_room.sh' | awk '{print $11}' | awk -F'/' '{print $NF}' | sort -u | tr '\n' ' ' || true)"
    if [[ -n "$route_if" && "$route_if" == utun* ]]; then
      echo "      1. [命中] 本机 VPN / 代理软件 TUN 路由抢占：发往服务器 (${relay_ip}) 的流量被虚拟网卡 [${route_if}] 劫持（检测到进程: ${vpn_procs:-VPN}，本机公网出口 IP 变为: ${pub_ip}），导致流量绕行海外或企业网关，单程增加 300ms+ 延迟！"
      echo "         👉 解决：关闭代理软件的 TUN 模式 / 企业 VPN，或将 ${relay_ip} (vnt.wherewego.top) 加入代理软件直连 (DIRECT) 规则。"
    fi
    if [[ -n "$relay_mode_peers" ]]; then
      echo "      2. [命中] 节点未建立 P2P 直连（当前为 server-relay 中继转发）：若对端使用 5G 移动流量（Symmetric 对称型 NAT）或本机挂有 VPN 代理，会导致 UDP 打洞失败而被迫走服务器中继。"
      echo "         👉 解决：将手机/队友切换至普通宽带 Wi-Fi（Cone NAT），并关闭本机代理 TUN 后重连，即可恢复 10~30ms 的 P2P 直连。"
    fi
  elif [[ "$nat_type" == "Cone" ]]; then
    echo "   🟢 【极佳 (TUN 模式 + 低延迟 < ${HIGH_LATENCY_THRESHOLD_MS}ms + Cone NAT)】系统级 utun 虚拟网卡已就绪，连接稳定且延迟正常，非常适合「峡谷模拟联机群」稳定联机！"
  else
    echo "   🟡 【良好 (TUN 模式 + 低延迟 < ${HIGH_LATENCY_THRESHOLD_MS}ms + $nat_type NAT)】系统级 utun 虚拟网卡已就绪，延迟正常。"
  fi
  echo "=================================================================="
}

# ------------------------------------------------------------------------------
# CLI 参数解析
# ------------------------------------------------------------------------------
ACTION="${1:-join}"
if [[ $# -gt 0 ]]; then
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--room|--token)
      ROOM_TOKEN="${2:-$DEFAULT_ROOM}"
      shift 2
      ;;
    -w|--password|-p)
      ROOM_PASSWORD="${2:-}"
      shift 2
      ;;
    --no-password)
      ROOM_PASSWORD=""
      shift 1
      ;;
    -n|--name)
      DEVICE_NAME="${2:-}"
      shift 2
      ;;
    -s|--server)
      SERVER_ADDR="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "用法: $0 [join|precheck|status|test|stop|auth|install] [-k 房间名] [-w 密码] [-n 设备昵称] [-s 服务器地址]"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

case "$ACTION" in
  install)
    install_vnt_cli
    ;;
  auth|grant)
    ensure_tun_privilege
    ;;
  precheck|check)
    run_precheck
    ;;
  join|create|start)
    join_room
    ;;
  status|info|list)
    show_status
    ;;
  test|ping)
    test_stability
    ;;
  stop|leave|exit)
    stop_vnt
    echo "🛑 已退出「${ROOM_TOKEN}」虚拟局域网房间并卸载系统级 TUN 虚拟网卡。"
    ;;
  *)
    echo "未知操作: $ACTION (支持: join | precheck | status | test | stop | auth | install)"
    exit 1
    ;;
esac
