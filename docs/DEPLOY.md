# Meridian 任务服务器部署指南

目标：让一台**局域网里常开的机器**（树莓派 / NAS / 小主机 / VPS）跑起任务下发服务，
iPad 时钟和手机推送页都连它。全程零 npm 依赖，只需要 Node 18+。

- 契约与字段说明见 [`API.md`](./API.md)
- 服务本体：`server/meridian-server.mjs`（单文件，只用 Node 内置模块）
- 数据：一个 `data.json`，原子写，拷走即备份

---

## 0. 30 秒起步（本机试跑）

```bash
cd meridian/server
export MERIDIAN_TOKEN="$(openssl rand -hex 24)"   # 记下来，iPad 上要填
node meridian-server.mjs
```

看到这三行就成功了：

```
[meridian] listening on http://0.0.0.0:8787
[meridian] data file: /.../meridian/server/data.json
[meridian] push page: http://<this-host>:8787/push
```

Windows PowerShell（本仓库开发机即 Windows）：

```powershell
cd meridian\server
$env:MERIDIAN_TOKEN = -join ((1..48) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })
$env:MERIDIAN_PORT = '8787'
node meridian-server.mjs
```

> 生成 token 的等价写法：`openssl rand -hex 24`（48 个 hex 字符，192 bit）。
> 也可以 `node -e "console.log(require('crypto').randomBytes(24).toString('hex'))"`。
> token 只存在服务端环境变量和 iPad 设置里，**不要**写进仓库、不要发在群里。

---

## 1. 环境变量

| 变量 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `MERIDIAN_TOKEN` | **是** | — | Bearer token；未设置或为空时服务**拒绝启动**并退出码 1 |
| `MERIDIAN_DATA` | 否 | 服务文件同目录 `data.json` | 数据文件路径；目录不存在会自动创建 |
| `MERIDIAN_PORT` | 否 | `8787` | 监听端口 |
| `MERIDIAN_HOST` | 否 | `0.0.0.0` | 监听地址；只允许本机访问时用 `127.0.0.1` |

日志每请求一行：`GET /api/v1/snapshot 200 0.8ms`，不打印 token、不打印 query。

---

## 2. 局域网部署

### 2.1 找到这台机器的局域网地址

Linux / 树莓派：

```bash
hostname -I          # 例如 192.168.1.10
ip -4 addr show      # 找不到再看这里
```

macOS：

```bash
ipconfig getifaddr en0
```

Windows：

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  Select-Object InterfaceAlias, IPAddress
```

建议在路由器上给这台机器**固定 DHCP 租约**（或设静态 IP），否则 iPad 里填的地址会在租约变化后失效。
树莓派可以顺便装 `avahi-daemon`，之后 iPad 里能填 `http://raspberrypi.local:8787`（mDNS），
但部分企业 Wi-Fi 会屏蔽 mDNS 广播，IP 更稳。

### 2.2 防火墙

只对局域网放行端口，不要把 8787 映射到公网：

```bash
# ufw（Debian/Ubuntu/树莓派）
sudo ufw allow from 192.168.1.0/24 to any port 8787 proto tcp
```

```powershell
# Windows 防火墙（管理员 PowerShell）
New-NetFirewallRule -DisplayName "Meridian 8787" -Direction Inbound `
  -Protocol TCP -LocalPort 8787 -Action Allow -Profile Private
```

### 2.3 iPad 里填什么

App 的「服务器」设置：

| 项 | 填法 |
| --- | --- |
| Base URL | `http://192.168.1.10:8787`（**不要**带 `/api/v1`，不要带尾斜杠） |
| Token | 与服务端 `MERIDIAN_TOKEN` 完全一致 |

`Info.plist` 已声明 `NSAllowsLocalNetworking`，局域网明文 HTTP 可以直接用；
`NSLocalNetworkUsageDescription` 会在首次连接时弹本地网络权限，选「允许」。
iPad 与服务器必须在**同一个子网**（同一 Wi-Fi / 同一交换机 VLAN）。

验证连通性（在 iPad 浏览器或另一台电脑上）：

```bash
curl http://192.168.1.10:8787/health
# {"ok":true,"name":"meridian","rev":0,"time":"2026-11-15T13:30:00Z"}
curl -H "Authorization: Bearer $MERIDIAN_TOKEN" \
  http://192.168.1.10:8787/api/v1/snapshot
```

### 2.4 手机推送页

浏览器打开：

```
http://192.168.1.10:8787/push?token=<MERIDIAN_TOKEN>
```

第一次带 `?token=` 后会写一个 30 天的 cookie，之后只记 `http://192.168.1.10:8787/push` 即可。
iOS Safari 可以「添加到主屏幕」，就是一个离线可用的推送小页面（不依赖 CDN、不跑 JS）。
想换 token 时清掉该站点的网站数据。

---

## 3. 常驻运行

### 3.1 systemd（树莓派 / Debian / Ubuntu，推荐）

先建用户与目录：

```bash
sudo useradd --system --home /srv/meridian --shell /usr/sbin/nologin meridian
sudo mkdir -p /srv/meridian/server /var/lib/meridian
sudo cp meridian-server.mjs package.json /srv/meridian/server/
sudo chown -R meridian:meridian /srv/meridian /var/lib/meridian
```

`/etc/meridian.env`（**权限 600**，token 只放在这里）：

```bash
MERIDIAN_TOKEN=换成你自己的48位hex
MERIDIAN_PORT=8787
MERIDIAN_DATA=/var/lib/meridian/data.json
```

```bash
sudo chown root:root /etc/meridian.env
sudo chmod 600 /etc/meridian.env
```

`/etc/systemd/system/meridian.service`：

```ini
[Unit]
Description=Meridian task server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=meridian
Group=meridian
WorkingDirectory=/srv/meridian/server
EnvironmentFile=/etc/meridian.env
ExecStart=/usr/bin/node /srv/meridian/server/meridian-server.mjs
Restart=on-failure
RestartSec=2
# 只读系统 + 可写数据目录
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/meridian
UMask=0077

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now meridian
systemctl status meridian --no-pager
journalctl -u meridian -f          # 看每请求日志
```

`node` 路径用 `command -v node` 确认（nvm 装的 node 不在 systemd 的 PATH 里，
用绝对路径或在 `ExecStart` 前加 `Environment=PATH=/usr/local/bin:/usr/bin`）。

### 3.2 pm2（已有 Node 环境时最省事）

```bash
cd meridian/server
pnpm add -g pm2            # 或 npm i -g pm2
MERIDIAN_TOKEN=<token> MERIDIAN_DATA=/var/lib/meridian/data.json \
  pm2 start meridian-server.mjs --name meridian
pm2 save
pm2 startup                # 按提示执行它打印的那行 sudo 命令
pm2 logs meridian --lines 50
```

### 3.3 Docker

`server/Dockerfile` 已随仓库提供：

```bash
cd meridian/server
docker build -t meridian-server:1.0 .
docker run -d --name meridian --restart unless-stopped \
  -p 8787:8787 \
  -e MERIDIAN_TOKEN=<token> \
  -v meridian-data:/data \
  meridian-server:1.0
docker logs -f meridian
```

`docker-compose.yml` 示例（放在 `server/` 下也可以）：

```yaml
services:
  meridian:
    build: .
    container_name: meridian
    restart: unless-stopped
    ports:
      - "8787:8787"
    environment:
      MERIDIAN_TOKEN: "${MERIDIAN_TOKEN:?set MERIDIAN_TOKEN in .env}"
      MERIDIAN_DATA: /data/data.json
    volumes:
      - meridian-data:/data
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:8787/health').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"]
      interval: 30s
      timeout: 3s
      retries: 3

volumes:
  meridian-data:
```

`.env` 里放 `MERIDIAN_TOKEN=...`，并把 `.env` 加进 `.gitignore`。
容器内以非 root 的 `node` 用户运行，`/data` 已 chown 给该用户；数据卷记得纳入备份。

---

## 4. HTTPS 反向代理

局域网用 http 没问题；一旦要**跨网络**（公网 VPS、咖啡店 Wi-Fi、公司网络），必须上 TLS，
否则 token 和待办内容都是明文。

### 4.1 Caddy（自动证书，最省心）

```caddyfile
clock.example.com {
    reverse_proxy 127.0.0.1:8787 {
        flush_interval -1
    }
}
```

Caddy 会自己申请/续期证书；`flush_interval -1` 让 SSE 立即冲刷（默认也是不缓冲，写上更稳）。
DNS 把 `clock.example.com` 解析到服务器，防火墙只放行 80/443，8787 只监听 `127.0.0.1`：

```bash
MERIDIAN_HOST=127.0.0.1
```

iPad 里 Base URL 填 `https://clock.example.com`，token 不变。

### 4.2 Nginx

```nginx
server {
    listen 443 ssl http2;
    server_name clock.example.com;

    ssl_certificate     /etc/letsencrypt/live/clock.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/clock.example.com/privkey.pem;

    client_max_body_size 64k;

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # SSE 必须关掉缓冲和超时切割
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
```

要点：

- `proxy_buffering off;` —— 不关的话 `event:` 帧会被 Nginx 攒着，iPad 上表现为「任务延迟半分钟才出现」。
- `proxy_read_timeout` 必须大于心跳间隔（25 秒），否则连接会被周期性掐断。
- 只反代到 `127.0.0.1:8787`，不要让 8787 对公网监听。
- Cloudflare 等 CDN 代理长连接可能超时，SSE 路径建议直连或关代理。

### 4.3 口令与地址小结

| 场景 | Base URL | 说明 |
| --- | --- | --- |
| 家里局域网 | `http://192.168.1.10:8787` | 明文，仅限内网 |
| NAS + 域名 + 证书 | `https://clock.example.com` | 走反代，注意 SSE 不缓冲 |
| 公网 VPS | `https://clock.example.com` | 必须 HTTPS；建议再加一层 VPN/防火墙白名单 |

---

## 5. 备份与恢复

```bash
# 备份（服务运行中也可以，原子写保证文件完整）
cp /var/lib/meridian/data.json ~/meridian-backup-$(date +%F).json

# 恢复
sudo systemctl stop meridian
sudo cp ~/meridian-backup-2026-11-15.json /var/lib/meridian/data.json
sudo chown meridian:meridian /var/lib/meridian/data.json
sudo systemctl start meridian
```

`rev` 会随文件一起恢复；iPad 下次快照会看到同一个 `rev`，不会重复拉取。
如果文件坏了，服务会把它改名成 `data.corrupt-<UTC 时间>.json` 并以空库启动——**先别删这个文件**，
里面通常还能手工捞出任务文本。

---

## 6. 排障

| 现象 | 原因 / 处理 |
| --- | --- |
| 启动即退出，提示 `MERIDIAN_TOKEN is not set` | fail closed 设计；按第 1 节设环境变量 |
| `EADDRINUSE` | 端口被占；换 `MERIDIAN_PORT` 或停掉旧进程 |
| iPad 显示「异常 / 401」 | token 不一致（注意首尾空格、复制时多带了引号） |
| iPad 一直「离线」，浏览器也打不开 `/health` | 不同子网 / 防火墙 / IP 变了；先在同一台电脑上 curl |
| iPad 第一次连接弹「本地网络」权限 | 选允许；拒绝过的话去 设置 → 隐私 → 本地网络 重新打开 |
| 任务在手机上提交成功，iPad 几十秒后才出现 | 反向代理缓冲了 SSE；按 4.2 关 `proxy_buffering`，或先靠 90 秒轮询兜底 |
| SSE 每隔一阵断开重连 | 代理 `proxy_read_timeout` 小于心跳间隔；调到 1h |
| 手机推送页打不开表单，只出口令页 | 用 `?token=` 打开一次，或清 cookie 后重来 |
| 时间显示差 8 小时 | `due` 是 UTC，客户端展示时用本地时区格式化；`day` 才是本地日历日 |
| 数据文件变成 `data.corrupt-*.json` | 文件被外部改坏；服务已自动空库启动，手工恢复备份即可 |
| Docker 容器里数据重启就没了 | 没挂卷；`-v meridian-data:/data` 且 `MERIDIAN_DATA=/data/data.json` |

健康检查（不需要 token）：

```bash
curl -fsS http://127.0.0.1:8787/health && echo OK
```

---

## 7. 安全清单

- [ ] `MERIDIAN_TOKEN` 是随机 48 位 hex，只放在环境变量/`/etc/meridian.env`（600）
- [ ] 8787 只对局域网开放，或干脆只监听 `127.0.0.1` + 反代
- [ ] 跨公网必须 HTTPS；不要把明文 8787 映射出去
- [ ] 数据文件权限 `600`，备份加密或放在可信位置（里面有你的日程）
- [ ] 定期升级 Node（18 LTS 起，建议 20/22）
- [ ] 换 token 时：改环境变量 → 重启服务 → 在 iPad 与手机页同步更新
