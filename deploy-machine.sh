#!/bin/bash
# ============================================================================
# deploy-machine.sh  —— 一键部署 sing-box 双机 + GitHub 订阅
#
# 在每台 GCP 机器上以 root 执行（先美西 A，再台湾 B）：
#   bash deploy-machine.sh A <用户名/仓库> <GH_TOKEN>
#   bash deploy-machine.sh B <用户名/仓库> <GH_TOKEN>
#
# 参数：
#   $1  ROLE      A（美西 us，含 5 分钟合并推送） 或 B（台湾 tw，只推送）
#   $2  GH_REPO   GitHub 仓库，如 "你的用户名/sub-cache-xxxx"
#   $3  GH_TOKEN  拥有 repo + workflow 权限的 PAT
#
# 本脚本自包含全部组件：sing-box v1.13.16、密钥/证书、config.json、
# gen-links.sh / update-ip.sh / sync-github.sh、systemd 定时器、BBR。
# ============================================================================
set -euo pipefail

ROLE="${1:-}"
GH_REPO="${2:-}"
GH_TOKEN="${3:-}"

usage() {
  echo "用法: bash $0 <A|B> <用户名/仓库> <GH_TOKEN>"
  echo "  例: bash $0 A myname/sub-cache-abc ghp_xxxxxxxx"
}

if [ "$ROLE" != "A" ] && [ "$ROLE" != "B" ]; then
  usage; exit 1
fi
if [ -z "$GH_REPO" ] || [ -z "$GH_TOKEN" ]; then
  usage; exit 1
fi
if [ "$(id -u)" != "0" ]; then
  echo "请以 root 运行（sudo bash $0 ...）"; exit 1
fi

echo "=============================================="
echo "角色: $ROLE   仓库: $GH_REPO"
echo "=============================================="

# ---------- 0. 安装依赖 ----------
export DEBIAN_FRONTEND=noninteractive
echo ">>> 安装依赖"
apt-get update -y
apt-get install -y curl ca-certificates tar openssl python3 git coreutils grep

# ---------- 1. 安装 sing-box v1.13.16 ----------
arch=$(uname -m)
case "$arch" in
  x86_64)    SUFFIX="amd64" ;;
  aarch64|arm64) SUFFIX="arm64" ;;
  *) echo "不支持的架构: $arch"; exit 1 ;;
esac
if ! command -v sing-box >/dev/null 2>&1; then
  echo ">>> 下载 sing-box v1.13.16 (${SUFFIX})"
  curl -fL -o /tmp/sing-box.tar.gz \
    "https://github.com/SagerNet/sing-box/releases/download/v1.13.16/sing-box-1.13.16-linux-${SUFFIX}.tar.gz"
  tar xzf /tmp/sing-box.tar.gz -C /tmp
  cp "/tmp/sing-box-1.13.16-linux-${SUFFIX}/sing-box" /usr/local/bin/sing-box
  chmod +x /usr/local/bin/sing-box
  rm -rf /tmp/sing-box*
fi
sing-box version

# ---------- 2. 生成密钥 / 证书 / 配置 ----------
mkdir -p /usr/local/etc/sing-box
cd /usr/local/etc/sing-box

if [ ! -f reality-keypair.txt ]; then
  echo ">>> 生成 Reality 密钥对"
  sing-box generate reality-keypair | tee reality-keypair.txt
fi
if [ ! -f uuid.txt ]; then
  echo ">>> 生成 UUID"
  sing-box generate uuid | tee uuid.txt
fi
if [ ! -f key.pem ] || [ ! -f cert.pem ]; then
  echo ">>> 生成 Hysteria2 自签证书"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=www.microsoft.com"
fi

echo ">>> 写入 config.json"
cat > /usr/local/etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        { "uuid": "$(cat uuid.txt)", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "dl.google.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "dl.google.com", "server_port": 443 },
          "private_key": "$(grep -oP 'PrivateKey: \K.*' reality-keypair.txt)",
          "short_id": [""]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": 443,
      "up_mbps": 1000,
      "down_mbps": 1000,
      "users": [ { "password": "$(cat uuid.txt)" } ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "certificate_path": "/usr/local/etc/sing-box/cert.pem",
        "key_path": "/usr/local/etc/sing-box/key.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

echo ">>> 校验配置"
sing-box check -c /usr/local/etc/sing-box/config.json

# ---------- 3. sing-box systemd 服务 ----------
echo ">>> 安装 sing-box.service"
cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/etc/sing-box
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box
systemctl restart sing-box
systemctl status sing-box --no-pager || true

# ---------- 4. 订阅相关脚本 ----------
mkdir -p /var/www/sub /var/www/github-sync

echo ">>> 安装 gen-links.sh"
cat > /usr/local/bin/gen-links.sh <<'GENLINKS_EOF'
#!/bin/bash
# 从本机 sing-box 配置生成单机订阅链接（节点名按机器：A→us，B→tw）
# 输出: /var/www/sub/links.txt、/var/www/sub/clash-proxies.txt
set -e

CFG="/usr/local/etc/sing-box/config.json"
KP="/usr/local/etc/sing-box/reality-keypair.txt"
OUT="/var/www/sub"
mkdir -p "$OUT"

# 节点名前缀：GH_PREFIX=A → us，GH_PREFIX=B → tw
PREFIX="us"
if [ -f /usr/local/etc/sing-box/github-sync.conf ]; then
  source /usr/local/etc/sing-box/github-sync.conf
  [ "$GH_PREFIX" = "B" ] && PREFIX="tw"
fi

[ -f "$CFG" ] || { echo "ERROR: 缺少 $CFG"; exit 1; }
PBK=$(grep -oP 'PublicKey: \K.*' "$KP" 2>/dev/null || true)
[ -z "$PBK" ] && { echo "ERROR: 无法获取 Reality 公钥"; exit 1; }

read -r PORT UUID VLESS_SNI HY2_SNI HY2_PASS <<< $(python3 -c "
import json
cfg=json.load(open('$CFG'))
v=next(i for i in cfg['inbounds'] if i['type']=='vless')
h=next(i for i in cfg['inbounds'] if i['type']=='hysteria2')
print(v['listen_port'], v['users'][0]['uuid'], v['tls']['server_name'], h['tls']['server_name'], h['users'][0]['password'])
")

SERVER=$(curl -s --max-time 5 -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" || true)
[ -z "$SERVER" ] && { echo "ERROR: 无法获取外部 IP"; exit 1; }
echo "本机 IP: $SERVER, 节点前缀: $PREFIX"

VLESS_LINK="vless://${UUID}@${SERVER}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${VLESS_SNI}&fp=chrome&pbk=${PBK}&sid=&type=tcp&headerType=none#${PREFIX}-vless"
HY2_LINK="hysteria2://${HY2_PASS}@${SERVER}:${PORT}?sni=${HY2_SNI}&insecure=1#${PREFIX}-hysteria2"

printf '%s\n%s\n' "$VLESS_LINK" "$HY2_LINK" > "$OUT/links.txt"

cat > "$OUT/clash-proxies.txt" <<EOF
  - name: ${PREFIX}-vless
    type: vless
    server: ${SERVER}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${VLESS_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PBK}
  - name: ${PREFIX}-hysteria2
    type: hysteria2
    server: ${SERVER}
    port: ${PORT}
    password: ${HY2_PASS}
    sni: ${HY2_SNI}
    skip-cert-verify: true
EOF

echo "生成完成: $OUT/links.txt"
GENLINKS_EOF
chmod +x /usr/local/bin/gen-links.sh

echo ">>> 安装 update-ip.sh"
cat > /usr/local/bin/update-ip.sh <<'UPDATEIP_EOF'
#!/bin/bash
# 30 秒周期：检测本机外部 IP，变化则重新生成链接并推送 GitHub
STATE="/var/www/sub/.last-ip"

IP=$(curl -s --max-time 5 -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" || true)
[ -z "$IP" ] && exit 1

if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "$IP" ]; then
  exit 0  # IP 未变化
fi

echo "IP 变化 -> $IP"
echo "$IP" > "$STATE"
/usr/local/bin/gen-links.sh || true
/usr/local/bin/sync-github.sh || true
UPDATEIP_EOF
chmod +x /usr/local/bin/update-ip.sh

echo ">>> 安装 sync-github.sh（${ROLE} 版本）"
if [ "$ROLE" = "A" ]; then
  cat > /usr/local/bin/sync-github.sh <<'SYNC_EOF'
#!/bin/bash
# 美西机器（A）版本：推送 A/ 目录 + 合并 A+B → 推送合并产物到仓库根目录
set -e

CONF="/usr/local/etc/sing-box/github-sync.conf"
[ -f "$CONF" ] || { echo "未配置 github-sync.conf"; exit 0; }
source "$CONF"
[ -n "$GH_REPO" ] && [ -n "$GH_TOKEN" ] || { echo "配置不完整"; exit 0; }

SYNC_DIR="/var/www/github-sync"
mkdir -p "$SYNC_DIR"

/usr/local/bin/gen-links.sh > /dev/null

if [ ! -d "$SYNC_DIR/.git" ]; then
  git clone --quiet "https://github.com/${GH_REPO}" "$SYNC_DIR" 2>/dev/null || \
    { echo "ERROR: clone 失败"; exit 1; }
fi

cd "$SYNC_DIR"
# 确保 git 身份（新机器首次提交必需）
git config user.name "sub-merge"
git config user.email "sub-merge@users.noreply.github.com"

git fetch --quiet origin 2>/dev/null || true
git reset --quiet --hard "origin/${GH_BRANCH:-main}" 2>/dev/null || true

# 更新本机文件
mkdir -p "$GH_PREFIX"
cp /var/www/sub/links.txt "$GH_PREFIX/links.txt"
cp /var/www/sub/clash-proxies.txt "$GH_PREFIX/clash-proxies.txt"

# 合并（A + B → links.txt / v2ray / clash.yaml）
if [ -f merge.sh ]; then
  bash merge.sh
else
  cat A/links.txt B/links.txt 2>/dev/null | grep -v '^$' > links.txt
  base64 -w0 links.txt > v2ray
fi

# 有变化才提交推送（首次也把根目录合并产物一起提交）
git add "$GH_PREFIX/" links.txt v2ray clash.yaml 2>/dev/null || true
if [ ! -e links.txt ] && [ ! -e "$GH_PREFIX/links.txt" ]; then
  echo "没有任何可提交文件"
  exit 0
fi
if git diff --quiet --cached; then
  echo "无变化，跳过推送"
  exit 0
fi

git commit --quiet -m "update subscription $(date -u +%Y%m%d%H%M%S)"
git push --quiet "https://x-access-token:${GH_TOKEN}@github.com/${GH_REPO}.git" \
  "HEAD:${GH_BRANCH:-main}"
echo "✅ 已推送到 GitHub（A + 合并产物）"
SYNC_EOF
else
  cat > /usr/local/bin/sync-github.sh <<'SYNC_EOF'
#!/bin/bash
# 台湾机器（B）版本：只推送 B/ 目录（合并由美西机器负责）
set -e

CONF="/usr/local/etc/sing-box/github-sync.conf"
[ -f "$CONF" ] || { echo "未配置 github-sync.conf"; exit 0; }
source "$CONF"
[ -n "$GH_REPO" ] && [ -n "$GH_TOKEN" ] || { echo "配置不完整"; exit 0; }

SYNC_DIR="/var/www/github-sync"
mkdir -p "$SYNC_DIR"

/usr/local/bin/gen-links.sh > /dev/null

if [ ! -d "$SYNC_DIR/.git" ]; then
  git clone --quiet "https://github.com/${GH_REPO}" "$SYNC_DIR" 2>/dev/null || \
    { echo "ERROR: clone 失败"; exit 1; }
fi

cd "$SYNC_DIR"
# 确保 git 身份（新机器首次提交必需）
git config user.name "sub-merge"
git config user.email "sub-merge@users.noreply.github.com"

git fetch --quiet origin 2>/dev/null || true
git reset --quiet --hard "origin/${GH_BRANCH:-main}" 2>/dev/null || true

# 更新本机文件
mkdir -p "$GH_PREFIX"
cp /var/www/sub/links.txt "$GH_PREFIX/links.txt"
cp /var/www/sub/clash-proxies.txt "$GH_PREFIX/clash-proxies.txt"

git add "$GH_PREFIX/"
if git diff --quiet --cached; then
  echo "无变化，跳过推送"
  exit 0
fi

git commit --quiet -m "update ${GH_PREFIX} subscription $(date -u +%Y%m%d%H%M%S)"
git push --quiet "https://x-access-token:${GH_TOKEN}@github.com/${GH_REPO}.git" \
  "HEAD:${GH_BRANCH:-main}"
echo "✅ 已推送到 GitHub（${GH_PREFIX}）"
SYNC_EOF
fi
chmod +x /usr/local/bin/sync-github.sh

# ---------- 5. GitHub 推送配置 ----------
echo ">>> 写入 github-sync.conf"
cat > /usr/local/etc/sing-box/github-sync.conf <<EOF
GH_REPO="$GH_REPO"
GH_TOKEN="$GH_TOKEN"
GH_BRANCH="main"
GH_PREFIX="$ROLE"
EOF
chmod 600 /usr/local/etc/sing-box/github-sync.conf

# ---------- 6. systemd 定时器 ----------
echo ">>> 安装 gen-peer 定时器（30 秒 IP 检测，两台都要）"
cat > /etc/systemd/system/gen-peer.service <<'PEERSVC_EOF'
[Unit]
Description=Check external IP, regenerate links and push on change

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-ip.sh
PEERSVC_EOF
cat > /etc/systemd/system/gen-peer.timer <<'PEERTIMER_EOF'
[Unit]
Description=Check external IP every 30s

[Timer]
OnBootSec=30s
OnCalendar=*-*-* *:*:00/30
AccuracySec=1s

[Install]
WantedBy=timers.target
PEERTIMER_EOF

if [ "$ROLE" = "A" ]; then
  echo ">>> 安装 gen-sync 定时器（5 分钟合并推送，仅美西 A）"
  cat > /etc/systemd/system/gen-sync.service <<'SYNCSVC_EOF'
[Unit]
Description=Sync subscription to GitHub (merge A+B)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-github.sh
SYNCSVC_EOF
  cat > /etc/systemd/system/gen-sync.timer <<'SYNCTIMER_EOF'
[Unit]
Description=Sync to GitHub every 5 minutes

[Timer]
OnBootSec=1min
OnCalendar=*-*-* *:0/5
AccuracySec=30s

[Install]
WantedBy=timers.target
SYNCTIMER_EOF
fi

systemctl daemon-reload
systemctl enable --now gen-peer.timer
if [ "$ROLE" = "A" ]; then
  systemctl enable --now gen-sync.timer
fi

# ---------- 7. BBR 优化 ----------
echo ">>> 启用 BBR"
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
modprobe tcp_bbr 2>/dev/null || true
sysctl -w net.core.default_qdisc=fq >/dev/null
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null || true
echo "BBR: $(cat /proc/sys/net/ipv4/tcp_congestion_control)"

# ---------- 8. 首次生成 + 推送 ----------
echo ">>> 首次生成链接"
/usr/local/bin/gen-links.sh
echo ">>> 首次推送 GitHub（若仓库未就绪会报错，定时器会稍后自动重试）"
if /usr/local/bin/sync-github.sh; then
  echo "首次推送成功"
else
  echo "注意: 首次推送失败。请确认仓库已创建且为公开、PAT 有 repo+workflow 权限；"
  echo "      gen-peer(30s) / gen-sync(A,5min) 定时器会自动重试。"
fi

# ---------- 9. 验证 ----------
echo ""
echo "========== 部署完成（$ROLE） =========="
ss -tlnup | grep :443 || true
echo "Reality 握手验证:"
echo "Q" | timeout 15 openssl s_client -connect 127.0.0.1:443 -servername dl.google.com 2>&1 | grep subject || true
echo "订阅文件: /var/www/sub/links.txt"
echo "========================================"
