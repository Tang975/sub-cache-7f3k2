#!/bin/bash
# ============================================================================
# traffic-report.sh —— 单机流量统计脚本（在 GCP 机器上执行）
#
# 用途：统计本机网卡累计流量（上行/下行/合计），输出为单行 key=value，供
#       GitHub Actions 采集后通过 Server酱 通知到微信。
#
# 数据来源：/proc/net/dev（Linux 内核网卡字节计数，无需安装任何软件）
#   - 下行 rx_bytes：本机收到的字节数（用户下载 → 入站流量）
#   - 上行 tx_bytes：本机发出的字节数（用户上传 → 出站流量）
#
# 统计口径（注意：不是「本月累计」）：
#   - 取主网卡（eth0，若不存在则用第一个非 lo 接口）的累计计数
#   - /proc/net/dev 是内核开机以来的计数：换 IP / 重启 / 网卡重启
#     都会导致计数从 0 重新累计
#   - 所以展示的是「最近一次启动/换 IP 以来的累计」，不是从月初算起
#   - 若你昨天用过流量但今天读数偏小，通常是「重启/换 IP 已清零」所致
#   - 如需精确的「本月」口径，需安装 vnstat（本脚本暂未引入）
#
# 用法：
#   bash traffic-report.sh [iface]
#   可选 iface：指定网卡名（默认自动探测 eth0 / ens* / enp*）
#
# 输出（单行，机器名在 Actions 侧拼接）：
#   IFACE=eth0 RX_BYTES=12345678 TX_BYTES=87654321 RX_GB=0.01 TX_GB=0.00 TOTAL_GB=0.01
# ============================================================================
set -euo pipefail

# ---------- 1. 探测主网卡 ----------
detect_iface() {
  local iface=""
  # 优先常见 GCP 网卡名
  for cand in eth0 ens4 ens5 ens6 enp0s3; do
    if [ -d "/sys/class/net/$cand" ]; then iface="$cand"; break; fi
  done
  # 兜底：第一个非 lo 且非 docker/veth 的接口
  if [ -z "$iface" ]; then
    iface=$(awk -F: '$1 != "lo" && $1 !~ /docker/ && $1 !~ /veth/ { gsub(/[[:space:]]/,"",$1); print $1; exit }' /proc/net/dev)
  fi
  echo "$iface"
}

IFACE="${1:-}"
if [ -z "$IFACE" ]; then
  IFACE=$(detect_iface)
fi
if [ -z "$IFACE" ] || [ ! -d "/sys/class/net/$IFACE" ]; then
  echo "ERROR: 找不到网卡 (IFACE='$IFACE')" >&2
  exit 1
fi

# ---------- 2. 读取 /proc/net/dev 中该网卡的计数 ----------
# 行格式:  iface:  rx_bytes rx_packets ...  tx_bytes tx_packets ...
LINE=$(grep -E "^[[:space:]]*${IFACE}:" /proc/net/dev || true)
if [ -z "$LINE" ]; then
  echo "ERROR: 网卡 $IFACE 不在 /proc/net/dev 中" >&2
  exit 1
fi

# 用 awk 安全提取（处理前后空格与冒号）
# /proc/net/dev 行格式:  iface:  rx_bytes rx_packets ... tx_bytes ...
# 去掉 "iface:" 前缀后：第1列=rx_bytes，第9列=tx_bytes
read -r RX_BYTES TX_BYTES < <(
  echo "$LINE" | awk '{
    sub(/^[[:space:]]*[A-Za-z0-9_]+:[[:space:]]*/, "");
    split($0, a, /[[:space:]]+/);
    print a[1], a[9];
  }'
)

# ---------- 3. 换算成 GB（保留 2 位小数） ----------
calc_gb() {
  awk -v b="$1" 'BEGIN { printf "%.2f", b/1024/1024/1024 }'
}
RX_GB=$(calc_gb "$RX_BYTES")
TX_GB=$(calc_gb "$TX_BYTES")
TOTAL_GB=$(awk -v r="$RX_GB" -v t="$TX_GB" 'BEGIN { printf "%.2f", r+t }')

# ---------- 4. 输出 ----------
echo "IFACE=$IFACE"
echo "RX_BYTES=$RX_BYTES"
echo "TX_BYTES=$TX_BYTES"
echo "RX_GB=$RX_GB"
echo "TX_GB=$TX_GB"
echo "TOTAL_GB=$TOTAL_GB"
