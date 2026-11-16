#!/bin/bash
# Meridian — server-side installer.
#
# What it does (and nothing else):
#   1. publishes the static portal + push page to $WEBROOT
#   2. installs the task server as a systemd unit on 127.0.0.1:$PORT
#   3. prints the token and the exact URL to put in the app
#
# What it deliberately does NOT do: touch your nginx configuration. Every host
# already has one, and an installer that edits it is an installer that breaks it.
# Copy deploy/nginx-meridian.conf.example into your own config instead.
#
# Usage:
#   sudo bash install.sh
#   sudo WEBROOT=/var/www/clock PORT=8791 bash install.sh
#
# Re-running is safe: the token and the data file survive.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
WEBROOT="${WEBROOT:-/var/www/meridian}"
PREFIX="${PREFIX:-/opt/meridian}"
PORT="${PORT:-8791}"
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"

if [ -z "$NODE_BIN" ]; then
  echo "找不到 node。先安装 Node 18+（例如 apt install nodejs 或用 nvm）。" >&2
  exit 1
fi

echo "== 1/4 目录"
mkdir -p "$WEBROOT/files" "$PREFIX/data"

echo "== 2/4 站点文件"
cp -r "$SRC/portal/." "$WEBROOT/"
chmod -R 755 "$WEBROOT"
find "$WEBROOT" -type f -exec chmod 644 {} +

if [ -f "$SRC/Meridian-unsigned.ipa" ]; then
  cp "$SRC/Meridian-unsigned.ipa" "$WEBROOT/files/Meridian-unsigned.ipa"
  echo "   IPA: $(du -h "$WEBROOT/files/Meridian-unsigned.ipa" | cut -f1)"
else
  echo "   ! 没有 IPA，下载按钮会 404（把构建产物放到 $WEBROOT/files/ 即可）"
fi

echo "== 3/4 口令"
if [ ! -f "$PREFIX/token" ]; then
  openssl rand -hex 24 > "$PREFIX/token"
  chmod 600 "$PREFIX/token"
  echo "   已生成新口令"
else
  echo "   沿用已有口令"
fi
TOKEN="$(cat "$PREFIX/token")"

echo "== 4/4 任务服务器"
cp "$SRC/../server/meridian-server.mjs" "$PREFIX/server.mjs"

cat > /etc/systemd/system/meridian.service <<UNIT
[Unit]
Description=Meridian task server (clock agenda)
After=network.target

[Service]
Type=simple
WorkingDirectory=$PREFIX
Environment=MERIDIAN_TOKEN=$TOKEN
Environment=MERIDIAN_PORT=$PORT
Environment=MERIDIAN_HOST=127.0.0.1
Environment=MERIDIAN_DATA=$PREFIX/data/data.json
ExecStart=$NODE_BIN $PREFIX/server.mjs
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable meridian >/dev/null 2>&1 || true
systemctl restart meridian
sleep 1.2
if systemctl is-active --quiet meridian; then
  echo "   meridian.service 运行中（127.0.0.1:$PORT）"
else
  echo "   ! 服务未启动，最近日志：" >&2
  journalctl -u meridian -n 25 --no-pager >&2 || true
  exit 1
fi

echo
echo "===== 自测（本机回环，不经过 nginx）====="
printf '%-30s ' "GET /health"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' -m 8 "http://127.0.0.1:$PORT/health"
printf '%-30s ' "GET /api/v1/snapshot"
curl -s -H "Authorization: Bearer $TOKEN" -m 8 "http://127.0.0.1:$PORT/api/v1/snapshot" | head -c 80
echo

echo
echo "===== 接下来 ====="
echo "1) 把 deploy/nginx-meridian.conf.example 抄进你的 nginx 配置，改 server_name 与路径，然后："
echo "     nginx -t && systemctl reload nginx"
echo "2) App 设置里填：   http(s)://<你的域名或 IP>/meridian"
echo "3) App 设置里填口令（就是下面这串）："
echo
echo "$TOKEN"
echo
echo "门户：   http(s)://<你的域名或 IP>/meridian/"
echo "下发页： http(s)://<你的域名或 IP>/meridian/push/"
