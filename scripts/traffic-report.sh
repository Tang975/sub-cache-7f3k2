#!/bin/bash
# ============================================================================
# traffic-report.sh - 单机流量统计脚本（在 GCP 机器上执行）
#
# 用途：统计本机网卡流量（上行/下行/合计 + 剩余流量 + 近 N 天逐日用量），
#       输出 key=value，供 GitHub Actions 采集后通过 Server酱 通知到微信。
#
# 数据来源：
#   - /proc/net/dev  Linux 内核网卡字节计数（无需安装任何软件）
#   - 自带历史文件   按天记录累计字节数，跨重启自动累加（delta 方式）
#
# 用法：
#   bash traffic-report.sh [iface] [--quota=GB] [--hist=N]
#     --quota 配额（GB），用于计算剩余流量；默认不输出
#     --hist  近 N 天逐日用量（默认 7）
#
# 输出：
#   IFACE=... RX_GB=... TX_GB=... TOTAL_GB=...
#   QUOTA_GB=... USED_GB=... LEFT_GB=... USED_PCT=...
#   DAILY_0=YYYY-MM-DD=GB ... DAILY_N-1=...
# ============================================================================
set -euo pipefail

FROM=""
QUOTA=""
HIST=7
for arg in "$@"; do
  case "$arg" in
    --from=*) FROM="${arg#--from=}" ;;
    --quota=*) QUOTA="${arg#--quota=}" ;;
    --hist=*) HIST="${arg#--hist=}" ;;
  esac
done
[ -n "$HIST" ] || HIST=7

SYS_NET="${SYS_NET:-/sys/class/net}"
PROC_DEV="${PROC_DEV:-/proc/net/dev}"

detect_iface() {
  local iface="" cand
  for cand in eth0 ens4 ens5 ens6 enp0s3; do
    if [ -d "$SYS_NET/$cand" ]; then iface="$cand"; break; fi
  done
  if [ -z "$iface" ]; then
    iface=$(awk -F: '$1 != "lo" && $1 !~ /docker/ && $1 !~ /veth/ { gsub(/[[:space:]]/,"",$1); print $1; exit }' "$PROC_DEV" 2>/dev/null)
  fi
  echo "$iface"
}

IFACE="${1:-}"
case "$IFACE" in
  --*) IFACE="" ;;
esac
[ -n "$IFACE" ] || IFACE=$(detect_iface)
if [ -z "$IFACE" ] || [ ! -d "$SYS_NET/$IFACE" ]; then
  echo "ERROR: 找不到网卡 (IFACE='$IFACE')" >&2
  exit 1
fi

LINE=$(grep -E "^[[:space:]]*${IFACE}:" "$PROC_DEV" 2>/dev/null | tail -n 1 || true)
if [ -z "$LINE" ]; then
  echo "ERROR: 网卡 $IFACE 不在 /proc/net/dev 中" >&2
  exit 1
fi
read -r RX_BYTES TX_BYTES < <(
  echo "$LINE" | awk '{ sub(/^[[:space:]]*[A-Za-z0-9_]+:[[:space:]]*/, ""); split($0, a, /[[:space:]]+/); print a[1], a[9]; }'
)

calc_gb() { awk -v b="$1" 'BEGIN { printf "%.2f", b/1024/1024/1024 }'; }
RX_GB=$(calc_gb "$RX_BYTES")
TX_GB=$(calc_gb "$TX_BYTES")
TOTAL_GB=$(awk -v r="$RX_GB" -v t="$TX_GB" 'BEGIN { printf "%.2f", r+t }')

# ---------- 近 N 天逐日用量（历史文件 delta 累计，跨重启不丢）----------
HIST_FILE="${HIST_FILE:-/var/tmp/traffic-report-$IFACE.history}"
TODAY_EPOCH=$(date +%s)
TODAY_STR=$(date -u +%F)

if [ ! -f "$HIST_FILE" ]; then
  printf '# %s traffic history\n' "$IFACE" > "$HIST_FILE"
fi
# 去重：当天已存在则移除旧记录，保留最新
if grep -q "^d $TODAY_EPOCH $RX_BYTES $TX_BYTES$" "$HIST_FILE" 2>/dev/null; then
  :
else
  grep -v "^d $TODAY_EPOCH " "$HIST_FILE" > "$HIST_FILE.tmp" || true
  printf 'd %s %s %s\n' "$TODAY_EPOCH" "$RX_BYTES" "$TX_BYTES" >> "$HIST_FILE.tmp"
  mv "$HIST_FILE.tmp" "$HIST_FILE"
fi
# 只保留近 180 行，避免无限增长
tail -n 180 "$HIST_FILE" > "$HIST_FILE.tmp" 2>/dev/null && mv "$HIST_FILE.tmp" "$HIST_FILE" || true

# 计算有效累计（跨重启自动累加）
eff=$(grep '^d ' "$HIST_FILE" | awk '
  BEGIN { prev=-1; acc=0 }
  {
    v=$3+$4;
    if (prev<0) acc+=v;
    else if (v>=prev) acc+=v-prev;
    else acc+=v;
    prev=v;
    print $1, acc;
  }')

eff_before() { # $1 = epoch 边界，取严格小于该边界的最近一条有效累计
  echo "$eff" | awk -v b="$1" 'BEGIN{m=0} { if ($1 < b && $2 > m) m=$2 } END{printf "%.0f", m}'
}
eff_now=$(echo "$eff" | awk 'END{print $2}')  # 最后一条 = 本次读数

day_start() { date -u -d "$1" +%s; }   # $1=YYYY-MM-DD

DAILY_KEYS=""
DAILY_VALS=""
START_DAYS_AGO=$((HIST - 1))
if [ -n "$FROM" ]; then
  fs=$(day_start "$FROM" 2>/dev/null || echo 0)
  if [ "$fs" -gt 0 ] 2>/dev/null; then
    ts=$(( $(date +%s) / 86400 * 86400 ))
    START_DAYS_AGO=$(( (ts - fs) / 86400 ))
  fi
fi
for i in $(seq "$START_DAYS_AGO" -1 0); do
  d=$(date -u -d "$i days ago" +%F)
  s=$(day_start "$d")
  if [ "$i" -eq 0 ]; then
    # 今天 = 本次累计 - 今天开始前的累计
    base=$(eff_before "$s")
    g=$(calc_gb $(( eff_now - base )))
  else
    e=$(day_start "$d")
    nxt=$(( e + 86400 ))
    b=$(eff_before "$e")
    a=$(eff_before "$nxt")
    g=$(awk -v a="$a" -v b="$b" 'BEGIN { x=a-b; if(x<0)x=0; printf "%.2f", x/1024/1024/1024 }')
  fi
  DAILY_KEYS="${DAILY_KEYS} $d"
  DAILY_VALS="${DAILY_VALS} $g"
done

# ---------- 剩余流量（累计口径 = 跨重启累加后的有效用量）----------
USED_GB=$(calc_gb "$eff_now")
LEFT_GB=""
USED_PCT=""
if [ -n "$QUOTA" ]; then
  LEFT_GB=$(awk -v q="$QUOTA" -v u="$USED_GB" 'BEGIN { x=q-u; if(x<0)x=0; printf "%.2f", x }')
  USED_PCT=$(awk -v q="$QUOTA" -v u="$USED_GB" 'BEGIN { p=u/q*100; if(p>100)p=100; printf "%.1f", p }')
fi

# ---------- 输出 ----------
echo "IFACE=$IFACE"
echo "RX_BYTES=$RX_BYTES"
echo "TX_BYTES=$TX_BYTES"
echo "RX_GB=$RX_GB"
echo "TX_GB=$TX_GB"
echo "TOTAL_GB=$TOTAL_GB"
if [ -n "$QUOTA" ]; then
  echo "QUOTA_GB=$QUOTA"
  echo "USED_GB=$USED_GB"
  echo "LEFT_GB=$LEFT_GB"
  echo "USED_PCT=$USED_PCT"
fi
i=0
for d in $DAILY_KEYS; do
  v=$(echo "$DAILY_VALS" | awk -v n=$((i+1)) '{print $n}')
  [ -n "$v" ] || v="0.00"
  echo "DAILY_$i=$d=$v"
  i=$((i+1))
done
