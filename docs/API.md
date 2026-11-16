# Meridian 任务服务器 API 契约

版本 **1.0**。适用于 Meridian iOS 1.0 与 `server/meridian-server.mjs`。

这份文档是 iOS 端的**唯一契约来源**：字段名、大小写、可空性、时间格式都以这里为准，并以
`ios/Meridian/Core/Models.swift` 的 `AgendaTask` / `SnapshotPayload` / `TaskMutation` 为对照。
改服务端字段前先改这两个文件，否则 iPad 会静默丢字段（`Codable` 对未知字段是忽略，不是报错）。

- Base URL：`http://<host>:8787`（局域网树莓派/NAS/VPS 皆可），所有业务路由在 `/api/v1` 下。
- 健康检查：`/health`（公开）。
- 手机推送页：`/push`（网页，口令鉴权）。
- 传输：纯 HTTP/1.1 + JSON；没有 WebSocket，实时用 SSE。

---

## 1. 通用约定

### 1.1 鉴权

除 `/health` 和 `/push` 页面外，所有 `/api/*` 路由都要求：

```
Authorization: Bearer <MERIDIAN_TOKEN>
```

- token 只来自服务端环境变量 `MERIDIAN_TOKEN`，**未配置时服务拒绝启动**（fail closed），生成方式见 `DEPLOY.md`。
- 比较是常量时间的；错误 token 与缺失 token 返回同样的 `401`，不泄露差异。
- `GET /api/v1/stream` 额外接受 `?token=<token>`，因为浏览器 `EventSource` 无法自定义请求头。
  其他端点**不**接受 URL 里的 token（避免 token 进入代理日志）。
- 服务器日志只记录 `方法 路径 状态 耗时`，不记录 query 与 token。

### 1.2 响应与 CORS

所有响应（含错误）都带：

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, PATCH, DELETE, OPTIONS
Access-Control-Allow-Headers: Authorization, Content-Type
Access-Control-Max-Age: 86400
```

`OPTIONS` 预检在任何鉴权之前直接返回 `204`。JSON 响应为 `Content-Type: application/json; charset=utf-8`，
且 `Cache-Control: no-store`。

### 1.3 时间格式

线上所有时间戳都是 **UTC ISO 8601、秒级、无小数秒、以 `Z` 结尾**：

```
2026-11-15T13:30:00Z
```

服务端输出统一用 `new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')` 归一化。请求里的时间
（`due`、`updatedAt`）可以带偏移或小数秒，服务端解析后按上面的格式存回。

> **iOS 注意**：`JSONDecoder.dateDecodingStrategy = .iso8601` 不接受小数秒。客户端解码器必须是
> `.iso8601`，服务端也保证永远不输出 `.123Z` 这种形式；两边都别改成 `.iso8601WithFractionalSeconds`。

`day` 是**本地日历日**，格式严格为 `yyyy-MM-dd`（例如 `2026-11-15`），与时区无关、与 UTC 时间戳无关。
同一个「今天」在不同时区的设备上必须算出同一个 key，因此客户端用 `DayKey`（POSIX locale + 当前时区）生成。

### 1.4 `rev`（修订号）

- 从 `0` 开始，**任意一次实际变更 +1**（创建、合并、真删除），写入 `data.json`，重启后恢复。
- 只读请求、预检、404、删除不存在的任务都**不**改 `rev`。
- 用途：客户端可以只比较 `rev` 判断「有没有变化」，或做乐观并发提示。它**不是** ETag，也不做条件请求。
- 非法/损坏的 `data.json` 会被备份为 `data.corrupt-<ts>.json`，服务以 `rev = 0` 空库启动。

### 1.5 错误格式

所有非 2xx 响应都是 JSON：

```json
{
  "error": "validation_error",
  "code": 400,
  "message": "title is required"
}
```

| HTTP | `error` | 触发条件 | 客户端怎么办 |
| --- | --- | --- | --- |
| 400 | `validation_error` | 字段类型/取值/长度/日期不合法 | 不该重试，修数据；属于客户端 bug |
| 400 | `invalid_json` | body 不是对象、不是合法 JSON、为空 | 同上 |
| 401 | `unauthorized` | 缺 token / token 错 | 提示用户检查设置里的 token，不要无限重试 |
| 404 | `not_found` | 未知路由、PATCH 不存在的 id | PATCH 可重新拉 snapshot；路由错误属实现 bug |
| 405 | `method_not_allowed` | 路径存在但方法不对，带 `Allow` 头 | 实现 bug |
| 413 | `payload_too_large` | 请求体超过 **64 KB** | 实现 bug（正常任务远小于此） |
| 500 | `internal_error` | 磁盘写入失败等 | 可退避重试；连续失败提示用户 |

### 1.6 请求体与限制

- 请求体上限 **64 KB**（含 JSON 包装），超限 `413`；`Content-Length` 超限会提前拒绝。
- JSON 解析失败 `400 invalid_json`；PATCH/POST 只接受 JSON 对象（数组/标量拒绝）。
- `title` 最长 500 字符，`note` 最长 4000 字符，`durationMinutes` 取值 `1..1440`。
- 未知 JSON 字段被忽略（向前兼容），不会报错。

---

## 2. 数据结构

### 2.1 `AgendaTask`

| 字段 | 类型 | 可空 | 说明 |
| --- | --- | --- | --- |
| `id` | string | 否 | UUID（服务端 `crypto.randomUUID()`），跨设备稳定，删除后不复用 |
| `title` | string | 否 | 显示文案；POST/PATCH 时去掉首尾空白，空串拒绝 |
| `note` | string | 否 | 备注，默认 `""`；客户端 `note` 为非可选 String |
| `day` | string | 否 | 本地日历日 `yyyy-MM-dd`；决定它出现在哪一天的列表里 |
| `due` | string \| null | 是 | UTC ISO8601；`null` 表示没有具体时间 |
| `priority` | number | 否 | `0` 普通、`1` 重要、`2` 紧急，其他值拒绝 |
| `isDone` | boolean | 否 | 完成后仍保留在列表里（排序沉底） |
| `updatedAt` | string | 否 | 服务端写入时间（见 1.3），秒级精度 |
| `origin` | string | 否 | `"remote"`（服务器下发）或 `"local"`（本机创建）；服务端创建的一律 `"remote"` |
| `durationMinutes` | number \| null | 是 | 预计时长（分钟），`1..1440`，默认 `null` |

```json
{
  "id": "804eb2d4-c5eb-456e-a6c6-70696cb139d6",
  "title": "把投影仪还回去",
  "note": "",
  "day": "2026-11-15",
  "due": "2026-11-15T12:30:00Z",
  "priority": 2,
  "isDone": false,
  "updatedAt": "2026-11-15T13:30:32Z",
  "origin": "remote",
  "durationMinutes": 10
}
```

### 2.2 `SnapshotPayload`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `serverTime` | string | 服务器当前 UTC 时间 |
| `rev` | number | 当前修订号 |
| `tasks` | `AgendaTask[]` | 全部任务，已按 2.3 排序 |
| `message` | string \| null | 预留的全屏留言，当前恒为 `null` |
| `weather` | object \| null | 预留天气，当前恒为 `null`；对象形如 `{ "text": "多云", "celsius": 21 }`（暂不返回） |

### 2.3 排序

服务端返回的 `tasks` 顺序与 iOS `AgendaTask.ordered` 一致：

1. 未完成在前，已完成在后；
2. 有 `due` 的按时间升序，`due == null` 的排在有时间的之后；
3. `priority` 高的在前（`2 > 1 > 0`）；
4. `updatedAt` 新的在前。

客户端可以再排序（`AgendaTask.ordered` 是唯一权威），服务端顺序只是方便直接渲染。
注意 `updatedAt` 只有秒级精度，同一秒内的两次变更比较相等，不要用 `updatedAt` 判断严格先后。

### 2.4 `TaskMutation`（客户端 → PATCH 的字段集合）

```swift
struct TaskMutation {
    var id: String
    var title: String?
    var note: String?
    var day: String?
    var due: Date?
    var priority: Int?
    var isDone: Bool?
    var updatedAt: Date
    var deleted: Bool?
}
```

PATCH 允许只发其中任意子集。服务端语义：

| 字段 | PATCH 行为 |
| --- | --- |
| `id` | 忽略（用 URL 里的 id）；URL 与 body 不一致也以 URL 为准 |
| `title` / `note` / `day` / `priority` / `isDone` / `durationMinutes` | 有则覆盖，无则保持 |
| `due` | 有则覆盖；显式 `null` 清空时间 |
| `updatedAt` | **忽略**，服务端以请求到达时间写入（客户端可发，用于本地记录） |
| `deleted` | 忽略；删除请用 `DELETE` |
| 未知字段 | 忽略 |

---

## 3. 端点

### 3.1 `GET /health`

公开，不鉴权。用于探活、Docker healthcheck、部署自检。

**响应 `200`**

```json
{ "ok": true, "name": "meridian", "rev": 12, "time": "2026-11-15T13:30:00Z" }
```

| 字段 | 说明 |
| --- | --- |
| `ok` | 恒为 `true` |
| `name` | 恒为 `"meridian"`，用于确认连对了服务 |
| `rev` | 当前修订号 |
| `time` | 服务器 UTC 时间 |

```bash
curl http://127.0.0.1:8787/health
```

### 3.2 `GET /api/v1/snapshot`

一次拿到全量状态。App 冷启动、轮询、SSE 重连后都用它。

**请求头**：`Authorization: Bearer <token>`

**响应 `200`**

```json
{
  "serverTime": "2026-11-15T13:30:32Z",
  "rev": 2,
  "tasks": [
    {
      "id": "804eb2d4-c5eb-456e-a6c6-70696cb139d6",
      "title": "把投影仪还回去",
      "note": "放前台",
      "day": "2026-11-15",
      "due": "2026-11-15T12:30:00Z",
      "priority": 2,
      "isDone": true,
      "updatedAt": "2026-11-15T13:30:32Z",
      "origin": "remote",
      "durationMinutes": 10
    }
  ],
  "message": null,
  "weather": null
}
```

```bash
curl -H "Authorization: Bearer $MERIDIAN_TOKEN" \
  http://127.0.0.1:8787/api/v1/snapshot
```

### 3.3 `GET /api/v1/tasks?day=yyyy-MM-dd`

按天取任务。`day` 省略时返回全部。

**响应 `200`**

```json
{
  "rev": 2,
  "tasks": [ { "...": "AgendaTask" } ]
}
```

- `day` 格式非法 → `400 validation_error`。
- `day` 合法但没有任务 → `200`，`tasks: []`（不是 404）。
- `rev` 是全局修订号，不是该天的修订号。

```bash
curl -H "Authorization: Bearer $MERIDIAN_TOKEN" \
  "http://127.0.0.1:8787/api/v1/tasks?day=2026-11-15"
```

### 3.4 `POST /api/v1/tasks`

创建一条任务。服务端负责生成 `id` / `origin` / `updatedAt` / `isDone`。

**请求头**：`Authorization`、`Content-Type: application/json`

**请求体**

| 字段 | 必填 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `title` | 是 | string | — | 1..500 字符，首尾空白会被去掉，空串 `400` |
| `note` | 否 | string | `""` | 0..4000 字符 |
| `day` | 否 | string | 服务器本地当天 | `yyyy-MM-dd` |
| `due` | 否 | string \| null | `null` | ISO8601，可带时区偏移 |
| `priority` | 否 | number | `0` | `0` / `1` / `2` |
| `durationMinutes` | 否 | number \| null | `null` | `1..1440` |

```json
{
  "title": "把投影仪还回去",
  "note": "放前台",
  "day": "2026-11-15",
  "due": "2026-11-15T20:30:00+08:00",
  "priority": 2,
  "durationMinutes": 10
}
```

**响应 `201`**：完整的 `AgendaTask`（字段见 2.1）：

```json
{
  "id": "804eb2d4-c5eb-456e-a6c6-70696cb139d6",
  "title": "把投影仪还回去",
  "note": "放前台",
  "day": "2026-11-15",
  "due": "2026-11-15T12:30:00Z",
  "priority": 2,
  "isDone": false,
  "updatedAt": "2026-11-15T13:30:32Z",
  "origin": "remote",
  "durationMinutes": 10
}
```

- `id` 由服务端生成（UUID v4），客户端**不要**在 body 里指定 id；指定了也会被忽略。
- `day` 省略时按服务器本地时区取当天；手机在别的时区推送时，建议客户端显式传 `day`。
- `due` 传 `+08:00` 偏移也会被归一化为 `Z` 结尾的 UTC 时间；`day` 不会因此被自动改写。
- **非幂等**：同一次点击重试两次会得到两条任务。客户端不要对 POST 做自动重试（除非先按返回的 id 去重）。

```bash
curl -X POST \
  -H "Authorization: Bearer $MERIDIAN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"把投影仪还回去","due":"2026-11-15T20:30:00+08:00","priority":2}' \
  http://127.0.0.1:8787/api/v1/tasks
```

### 3.5 `PATCH /api/v1/tasks/:id`

局部更新。只覆盖 body 里出现的字段，其余保持不变。

**请求体**：`TaskMutation` 的子集，例如

```json
{ "isDone": true, "note": "放前台" }
```

也可以只改一个字段：

```json
{ "due": null }
```

**响应 `200`**：合并后的完整 `AgendaTask`

```json
{
  "id": "804eb2d4-c5eb-456e-a6c6-70696cb139d6",
  "title": "把投影仪还回去",
  "note": "放前台",
  "day": "2026-11-15",
  "due": "2026-11-15T12:30:00Z",
  "priority": 2,
  "isDone": true,
  "updatedAt": "2026-11-15T13:31:05Z",
  "origin": "remote",
  "durationMinutes": 10
}
```

语义细节：

- `updatedAt` **总是**由服务端写成请求到达时间；客户端传的旧时间被忽略，`rev +1`。
- body 里没有任何可识别字段（例如只发 `{"updatedAt": "..."}`）时：`200` 返回原任务，**不改 rev**。
- `id` 不存在 → `404 not_found`（不会隐式创建）。
- 字段校验失败 → `400 validation_error`，且**不会**部分写入（先整体校验，再写入）。
- `title` / `day` / `priority` / `isDone` 不接受 `null`；`note: null` 等价于清空为 `""`；
  `due: null` / `durationMinutes: null` 为清空。
- 对同一 id 并发 PATCH 是 last-write-wins（后到者覆盖），服务端不报冲突；客户端的冲突提示靠比较 `updatedAt`。

```bash
curl -X PATCH \
  -H "Authorization: Bearer $MERIDIAN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"isDone":true,"note":"放前台"}' \
  http://127.0.0.1:8787/api/v1/tasks/804eb2d4-c5eb-456e-a6c6-70696cb139d6
```

### 3.6 `DELETE /api/v1/tasks/:id`

**响应 `204`**，无响应体。

- **幂等**：任务不存在也返回 `204`，客户端可以安全重试。
- 只有真正删掉了一条任务才会 `rev +1` 并推送 SSE `delete` 事件。

```bash
curl -i -X DELETE \
  -H "Authorization: Bearer $MERIDIAN_TOKEN" \
  http://127.0.0.1:8787/api/v1/tasks/804eb2d4-c5eb-456e-a6c6-70696cb139d6
```

### 3.7 `GET /api/v1/stream`（SSE）

实时通道。App 在前台时保持一条，断线由客户端重连；90 秒一次的 `/snapshot` 轮询作为兜底。

**鉴权**：`Authorization: Bearer <token>`，或 `?token=<token>`（给浏览器 `EventSource` 用）。

**响应头**

```
HTTP/1.1 200 OK
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-cache, no-transform
Connection: keep-alive
X-Accel-Buffering: no
Access-Control-Allow-Origin: *
```

**帧序列**（`\n` 换行，空行分隔事件）：

```
retry: 3000

event: snapshot
data: {"serverTime":"2026-11-15T13:30:32Z","rev":2,"tasks":[...],"message":null,"weather":null}

event: task
data: {"id":"804eb2d4-...","title":"把投影仪还回去", ... }

event: delete
data: {"id":"804eb2d4-c5eb-456e-a6c6-70696cb139d6"}

: ping

```

| 帧 | 时机 | data |
| --- | --- | --- |
| `retry: 3000` | 连接建立后第一帧 | 无（重连间隔提示，毫秒） |
| `event: snapshot` | 连接建立后立即 | 完整 `SnapshotPayload`，客户端应整体替换本地状态 |
| `event: task` | POST 创建、PATCH 更新成功后 | 完整 `AgendaTask`（新增或更新后的版本） |
| `event: delete` | DELETE 真正删除后 | `{"id":"<被删任务 id>"}` |
| `: ping` | 每 **25 秒** | 无（注释行，保活，客户端忽略） |

约定：

- 每个事件行尾都是 `\n`，事件之间空一行；不要假设一个 TCP 包等于一个事件，按空行缓冲切帧。
- 连接断开后客户端按 `retry: 3000` 或自己的退避重连；**重连后先应用新的 `snapshot`**，不要依赖漏掉的事件。
- 服务器不发送事件 id，不支持 `Last-Event-ID` 补发；快照本身就是补偿机制。
- 反向代理必须关闭响应缓冲（Nginx `proxy_buffering off`，Caddy 默认不缓冲），否则事件会成批到达。
- 服务端在 `SIGINT`/`SIGTERM` 时会结束所有 SSE 连接再关闭 HTTP server。

```bash
curl -N -H "Authorization: Bearer $MERIDIAN_TOKEN" \
  http://127.0.0.1:8787/api/v1/stream
# 浏览器 / EventSource：
# new EventSource("http://192.168.1.10:8787/api/v1/stream?token=<token>")
```

### 3.8 `GET /push`（手机推送页）

一个移动端优先的单页 HTML，表单直接 POST 一条任务。**不使用 JavaScript、不引用任何 CDN**，
离线局域网可用。深色页面，`#08090B` 底、暖白文字、单一琥珀强调色 `#E0A662`，系统字体。

**鉴权**（三选一）：

1. URL 口令：`GET /push?token=<token>` —— 成功后写入 `Set-Cookie: meridian_token=...`（HttpOnly、SameSite=Lax、30 天），后续访问自动带上；
2. 已登录 cookie；
3. 口令页：无口令访问返回一个输入框，POST 口令后 `303` 回 `/push`。

**表单字段**

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `title` | 是 | 待办内容（≤500 字） |
| `due` | 否 | `datetime-local`，如 `2026-11-15T20:30`；按**服务器本地时区**解释，同时决定 `day` |
| `priority` | 否 | `0` / `1` / `2`，默认 `0` |
| `token` | 是（隐藏域） | 口令 |

提交成功返回 `200` + 同一页面（顶部「已加入」提示，下方列出最近 5 条任务）。
提交失败（口令错 `401`、内容为空/时间格式错 `400`）返回口令页或表单页并内联显示错误。

```bash
# 打开页面（在手机浏览器里换成局域网地址）
open "http://192.168.1.10:8787/push?token=$MERIDIAN_TOKEN"

# 纯命令行模拟表单提交
curl -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "token=$MERIDIAN_TOKEN" \
  --data-urlencode "title=晚上浇花" \
  --data-urlencode "due=2026-11-15T20:30" \
  --data-urlencode "priority=1" \
  http://192.168.1.10:8787/push
```

---

## 4. 数据文件

默认路径 `server/data.json`（CLI 同目录），可用 `MERIDIAN_DATA` 覆盖。格式仅供排障/备份参考，
客户端不要直接读写：

```json
{
  "version": 1,
  "rev": 3,
  "tasks": [
    { "...": "AgendaTask（同上）" }
  ]
}
```

- 写入方式：同目录临时文件 `data.json.tmp-<pid>-<rand>` → `fs.rename` 原子替换，不会出现半截文件。
- 启动时文件损坏或结构不对：原文件重命名为 `data.corrupt-<UTC 时间戳>.json`，服务以空库（`rev = 0`）启动。
- 备份就是拷走 `data.json`；恢复就是停服务、覆盖文件、再启动（`rev` 会随文件恢复）。

---

## 5. iOS 端接入清单（照着写不会错）

1. **Base URL**：设置里填 `http://192.168.1.10:8787`，不要带尾斜杠、不要带 `/api/v1`
   （`ServerConfig.endpoint` 直接用用户输入，请求时拼 `/api/v1/...`）。
2. **明文 HTTP**：`Info.plist` 已开 `NSAllowsLocalNetworking`；局域网 IP 可直连。公网部署请上 HTTPS（见 `DEPLOY.md`）。
3. **JSON 编解码**：`JSONDecoder`/`JSONEncoder` 都用 `.iso8601`；不要用默认的 `.deferredToDate`。
4. **SSE**：`URLSession` 拿 `bytes` 流后手动按空行切帧；若用 `EventSource` 则必须把 token 放
   `?token=`（浏览器 API 不能加 header）。重连后以 `snapshot` 为准。
5. **轮询兜底**：`ServerConfig.syncInterval` 默认 90 秒拉一次 `/snapshot`，SSE 只负责即时性。
6. **PATCH 不要回传整条任务再改**：只发改动的字段，避免把旧值覆盖回去。
7. **错误处理**：`401` 不要重试（token 错），`5xx` 可以指数退避；`POST` 不自动重试（非幂等）。
8. **`updatedAt` 精度**：秒级。同一秒内的本地修改与服务端时间相等时，排序回落到 `due`/`priority`。
9. **`note` 非可选**：服务端永远返回字符串；`due`、`durationMinutes` 可能为 `null`，Swift 侧是 `Date?` / `Int?`。
10. **删除**：本地先乐观移除，再 `DELETE`；失败可静默重试（幂等），重新拉快照会纠正。

---

## 6. 兼容性与版本

- 服务端与客户端字段是**加性**演进：新增字段服务端会返回、旧客户端忽略；删除/改名字段视为破坏性变更，
  需要同时改 `Models.swift`、本文档和 `server/meridian-server.mjs`。
- `version` 目前固定 `1`；路由带 `/api/v1` 前缀，破坏性变更走 `/api/v2`。
- `message` / `weather` 已预留在 `SnapshotPayload` 里，当前恒为 `null`，客户端可先渲染占位。
