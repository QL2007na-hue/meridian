# meridian-server

Meridian 的自托管任务服务器：给 iPad 时钟右侧的「今日待办」下发任务，同时提供一个手机网页，
随手往今天塞一条。**零 npm 依赖**，只要 Node 18+，数据存一个 `data.json`。

- 契约（字段/错误码/SSE/时间格式）：[`../docs/API.md`](../docs/API.md)
- 部署（局域网/systemd/pm2/Docker/HTTPS）：[`../docs/DEPLOY.md`](../docs/DEPLOY.md)

## 快速开始

```bash
cd meridian/server
export MERIDIAN_TOKEN="$(openssl rand -hex 24)"   # 记下来，iPad 上要填同一个
node meridian-server.mjs
```

Windows PowerShell：

```powershell
cd meridian\server
$env:MERIDIAN_TOKEN = '换成你自己的 token'
node meridian-server.mjs
```

启动后：

```
[meridian] listening on http://0.0.0.0:8787
[meridian] data file: .../meridian/server/data.json
[meridian] push page: http://<this-host>:8787/push
```

iPad 的「服务器」设置里填 `http://<这台机器的局域网 IP>:8787` + 同一个 token。
手机浏览器打开 `http://<IP>:8787/push?token=<token>` 就能推任务。

`package.json` 里的脚本：

```bash
pnpm start        # 等价 node meridian-server.mjs
pnpm test         # 等价 node --test test/
```

## 环境变量

| 变量 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `MERIDIAN_TOKEN` | **是** | — | Bearer token；没设置会拒绝启动（fail closed） |
| `MERIDIAN_DATA` | 否 | 本目录 `data.json` | 数据文件路径 |
| `MERIDIAN_PORT` | 否 | `8787` | 端口 |
| `MERIDIAN_HOST` | 否 | `0.0.0.0` | 监听地址；只本机用 `127.0.0.1` |

## 端点一览

除 `/health` 与 `/push` 外都需要 `Authorization: Bearer <token>`。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/health` | 公开探活：`ok/name/rev/time` |
| `GET` | `/api/v1/snapshot` | 全量快照（serverTime/rev/tasks/message/weather） |
| `GET` | `/api/v1/tasks?day=2026-11-15` | 按天取任务；省略 `day` 返回全部 |
| `POST` | `/api/v1/tasks` | 创建，`201` + 完整 AgendaTask |
| `PATCH` | `/api/v1/tasks/:id` | 局部更新，`200` + 合并后的 AgendaTask |
| `DELETE` | `/api/v1/tasks/:id` | `204`，不存在也 204（幂等） |
| `GET` | `/api/v1/stream` | SSE：snapshot / task / delete + 25s 心跳 |
| `GET` | `/push` | 手机推送网页（口令或 cookie） |

## curl 示例

```bash
BASE=http://127.0.0.1:8787
TOKEN=your-token

# 快照
curl -H "Authorization: Bearer $TOKEN" $BASE/api/v1/snapshot

# 新建（day 省略时用服务器本地当天）
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"把投影仪还回去","due":"2026-11-15T20:30:00+08:00","priority":2}' \
  $BASE/api/v1/tasks

# 打勾
curl -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"isDone":true}' $BASE/api/v1/tasks/<id>

# 删除（幂等）
curl -i -X DELETE -H "Authorization: Bearer $TOKEN" $BASE/api/v1/tasks/<id>

# SSE（Ctrl-C 退出）
curl -N -H "Authorization: Bearer $TOKEN" $BASE/api/v1/stream
```

Windows PowerShell 里 `curl` 是 `Invoke-WebRequest` 的别名，请显式用 `curl.exe`，
JSON 用 `--data-binary "@body.json"` 从文件读，避免 PowerShell 吃掉引号。

## 测试

```bash
cd meridian/server
node test/api.test.mjs     # 直接运行，无需子进程
# 或
node --test test/
```

16 个用例覆盖：鉴权 401、CRUD、PATCH 合并、DELETE 幂等、`rev` 持久化与重启恢复、
SSE 首帧/task/delete/心跳/`?token=`、坏 JSON、413、未知路由、CORS 预检、
损坏数据文件隔离、`/push` 表单提交。

> 某些受限沙箱禁止命名管道，`node --test test/` 会因测试运行器无法 spawn 子进程而报
> `spawn EPERM`。这是环境限制，不是测试失败；直接 `node test/api.test.mjs` 即可。

## 数据

- 默认文件：`meridian/server/data.json`，可用 `MERIDIAN_DATA` 改。
- 结构：`{ "version": 1, "rev": N, "tasks": [AgendaTask...] }`。
- 每次变更先写临时文件再 `rename` 原子替换；`rev` 单调递增并落盘。
- 文件损坏时自动改名为 `data.corrupt-<ts>.json`，服务以空库启动，不崩。

## 文件结构

```
server/
├── meridian-server.mjs   # 服务本体（http + SSE + 持久化 + /push 页面）
├── package.json          # type: module，start/test 脚本，无 dependencies
├── Dockerfile            # node:22-alpine，非 root，/data 卷
├── README.md
└── test/
    └── api.test.mjs      # node --test 冒烟测试
```

## 安全提示

- token 用 `openssl rand -hex 24` 生成；只放在环境变量里，不要进 git。
- 局域网明文 HTTP 够用；跨公网一定套 HTTPS 反代，并给 SSE 关缓冲。
- `data.json` 权限建议 `600`，里面有你的完整日程。
