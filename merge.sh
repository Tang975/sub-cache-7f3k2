#!/bin/bash
# 合并两台机器的订阅文件（美西机器执行）
# 输入: A/links.txt A/clash-proxies.txt B/links.txt B/clash-proxies.txt
# 输出: links.txt v2ray(base64) clash.yaml
set -e
cd "$(dirname "$0")"

# 1. 合并明文链接
cat A/links.txt B/links.txt 2>/dev/null | grep -v '^$' > links.txt
echo "合并链接数: $(wc -l < links.txt)"

# 2. base64 订阅
base64 -w0 links.txt > v2ray

# 3. clash.yaml
cat > clash.yaml <<'EOF'
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

EOF

echo "proxies:" >> clash.yaml
cat A/clash-proxies.txt 2>/dev/null >> clash.yaml || true
cat B/clash-proxies.txt 2>/dev/null >> clash.yaml || true

NAMES=$(grep -oP '^  - name: \K.*' clash.yaml || true)
GROUP_PROXIES=""
while IFS= read -r n; do
  [ -n "$n" ] && GROUP_PROXIES="${GROUP_PROXIES}      - ${n}"$'\n'
done <<< "$NAMES"

cat >> clash.yaml <<EOF

proxy-groups:
  - name: PROXY
    type: select
    proxies:
${GROUP_PROXIES}      - AUTO
  - name: AUTO
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies:
${GROUP_PROXIES}

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF

echo "生成完成: links.txt v2ray clash.yaml"
