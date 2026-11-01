#!/usr/bin/env bash
# suoha.sh —— 固定域名版（改写版）
#
# 与原版“梭哈模式”（Cloudflare 临时隧道 trycloudflare.com）的区别：
#   1. 不用临时隧道，改用你在 Cloudflare 控制台事先建好的 Named Tunnel，
#      机器端用 Token 装成 cloudflared systemd 服务（重启自动恢复）。
#   2. 节点和订阅直接用固定域名，不再随每次运行变化。
#   3. xray 和订阅服务都装成 systemd 服务，重启后自动恢复，不用重跑脚本。
#
# 使用前必须先在 Cloudflare 控制台做完（脚本做不了这部分）：
#   - 建一个 Named Tunnel，记下它的 Token（Token 只在运行本脚本时输入，
#     不会写进本仓库，也不要发到聊天记录里）。
#   - 给该隧道加 Public Hostname 路由（路径是正则表达式）：
#       <固定域名>/^/vl-.*  -> http://localhost:21407   （VLESS）
#       <固定域名>/^/tr-.*  -> http://localhost:21408   （Trojan）
#       <固定域名>/^/sub.txt$    -> http://localhost:32390 （订阅）
#       <固定域名>/^/clash.yaml$ -> http://localhost:32390 （Clash 订阅）
#
# 用法（需要 root）：
#   sudo bash suoha.sh
#   脚本会依次问：固定域名、隧道 Token；其余全部自动生成。
#   跑完后订阅链接为：https://<固定域名>/sub.txt
#                        https://<固定域名>/clash.yaml
#
# 注意：
#   - UUID、Trojan 密码、WS 路径每次运行现场生成，存在机器本地，不进仓库。
#   - 本脚本不改动 DNS、不付费、不升级、不删除已有隧道。
#   - 如需换域名或换隧道，重新跑一次本脚本即可（会覆盖旧配置）。

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行：sudo bash suoha.sh" >&2
  exit 1
fi

# ---------- 输入 ----------
read -r -p "固定域名（如 instabox.woods.indevs.in）: " FIXED_DOMAIN
if [ -z "${FIXED_DOMAIN}" ]; then
  echo "固定域名不能为空" >&2
  exit 1
fi
read -r -s -p "Cloudflare 隧道 Token（输入时不回显）: " TUNNEL_TOKEN
echo
if [ -z "${TUNNEL_TOKEN}" ]; then
  echo "Token 不能为空" >&2
  exit 1
fi

VLESS_PORT=21407
TROJAN_PORT=21408
SUB_PORT=32390
SUB_DIR=/var/www/suoha_sub
XRAY_DIR=/usr/local/etc/xray
XRAY_BIN=/usr/local/bin/xray
CLOUDFLARED_BIN=/usr/local/bin/cloudflared

# ---------- 生成凭证（现场生成，不进仓库） ----------
UUID="$(cat /proc/sys/kernel/random/uuid)"
SHORT="${UUID%%-*}"

# ---------- 下载 xray / cloudflared ----------
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64) XRAY_ARCH="64"; CF_ARCH="amd64" ;;
  aarch64|arm64) XRAY_ARCH="arm64-v8a"; CF_ARCH="arm64" ;;
  *) echo "不支持的架构：${ARCH}" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
cd "${TMP}"

echo "[1/6] 下载 xray ..."
XRAY_URL="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
  | grep browser_download_url | grep "Xray-linux-${XRAY_ARCH}.zip" | head -n 1 | cut -d'"' -f4)"
curl -fsSL "${XRAY_URL}" -o xray.zip
unzip -o -q xray.zip xray
install -m 755 xray "${XRAY_BIN}"

echo "[2/6] 下载 cloudflared ..."
curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
  -o cloudflared
install -m 755 cloudflared "${CLOUDFLARED_BIN}"

# ---------- xray 配置 ----------
echo "[3/6] 写 xray 配置 ..."
mkdir -p "${XRAY_DIR}"
cat > "${XRAY_DIR}/config.json" <<EOF
{
  "inbounds": [
    {
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vl-${SHORT}" } }
    },
    {
      "port": ${TROJAN_PORT},
      "protocol": "trojan",
      "settings": { "clients": [{ "password": "${UUID}" }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/tr-${SHORT}" } }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

cat > /etc/systemd/system/xray-fixed.service <<EOF
[Unit]
Description=Xray (fixed-domain suoha)
After=network.target
[Service]
ExecStart=${XRAY_BIN} run -c ${XRAY_DIR}/config.json
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now xray-fixed.service

# ---------- cloudflared 固定隧道服务 ----------
echo "[4/6] 安装 cloudflared 固定隧道服务 ..."
# service install 会把 Token 存到机器本地 /etc/cloudflared/token，
# 并生成 systemd 服务，重启后自动连接已建好的 Named Tunnel。
"${CLOUDFLARED_BIN}" service install "${TUNNEL_TOKEN}"

# ---------- 生成固定域名节点与订阅 ----------
echo "[5/6] 生成固定域名订阅 ..."
mkdir -p "${SUB_DIR}"
VLESS_LINK="vless://${UUID}@${FIXED_DOMAIN}:443?encryption=none&security=tls&sni=${FIXED_DOMAIN}&type=ws&host=${FIXED_DOMAIN}&path=%2Fvl-${SHORT}#Fixed-VLESS"
TROJAN_LINK="trojan://${UUID}@${FIXED_DOMAIN}:443?security=tls&sni=${FIXED_DOMAIN}&type=ws&host=${FIXED_DOMAIN}&path=%2Ftr-${SHORT}#Fixed-Trojan"
printf '%s\n%s\n' "${VLESS_LINK}" "${TROJAN_LINK}" > "${SUB_DIR}/nodes.txt"
base64 -w 0 "${SUB_DIR}/nodes.txt" > "${SUB_DIR}/sub.txt"

cat > "${SUB_DIR}/clash.yaml" <<EOF
proxies:
  - name: "Fixed-VLESS"
    type: vless
    server: ${FIXED_DOMAIN}
    port: 443
    uuid: ${UUID}
    tls: true
    servername: ${FIXED_DOMAIN}
    network: ws
    ws-opts:
      path: /vl-${SHORT}
      headers:
        Host: ${FIXED_DOMAIN}
  - name: "Fixed-Trojan"
    type: trojan
    server: ${FIXED_DOMAIN}
    port: 443
    password: ${UUID}
    tls: true
    sni: ${FIXED_DOMAIN}
    network: ws
    ws-opts:
      path: /tr-${SHORT}
      headers:
        Host: ${FIXED_DOMAIN}
EOF

cat > /etc/systemd/system/suoha-sub.service <<EOF
[Unit]
Description=suoha subscription server (fixed-domain)
After=network.target
[Service]
ExecStart=/usr/bin/python3 -m http.server ${SUB_PORT} --directory ${SUB_DIR}
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now suoha-sub.service

# ---------- 核实 ----------
echo "[6/6] 核实 ..."
systemctl is-active xray-fixed.service
systemctl is-active cloudflared.service
systemctl is-active suoha-sub.service
curl -fsS "http://127.0.0.1:${SUB_PORT}/sub.txt" -o /dev/null

echo
echo "完成。固定域名订阅："
echo "  https://${FIXED_DOMAIN}/sub.txt"
echo "  https://${FIXED_DOMAIN}/clash.yaml"
echo "请确认 Cloudflare 侧的 4 条路径路由已按脚本头部的说明建好，否则节点和订阅走不通。"
