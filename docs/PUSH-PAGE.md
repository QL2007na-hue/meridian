# 下发页

> 手机浏览器打开 → 输入口令 → 推一条待办到 iPad。不需要装任何 App，页面是一个纯静态 HTML。

---

## 1. 它是什么

`deploy/portal/push/index.html`，部署后地址是：

```
http(s)://<你的域名或 IP>/meridian/push/
```

页面里只有：通道选择、标题、日期、时间、优先级、口令、提交按钮，以及"今天最近"四条。

提交时直接调服务器 API：

```http
POST /meridian/api/v1/tasks
Authorization: Bearer <MERIDIAN_TOKEN>
Content-Type: application/json

{ "title": "把样机寄给客户", "day": "2026-11-16", "due": "2026-11-16T06:30:00Z", "priority": 1, "note": "通道 02" }
```

iPad 前台时通过 SSE 在 **3 秒内**出现（页面成功提示同理）。

---

## 2. 六个通道

| 序号 | 名称 | 说明 | 预置优先级 |
| --- | --- | --- | --- |
| 01 | 日常 | 今天要做的事 | 普通 |
| 02 | 工作 | 会议 / 交付 | 重要 |
| 03 | 学习 | 阅读 / 练习 | 普通 |
| 04 | 生活 | 采购 / 家务 | 普通 |
| 05 | 提醒 | 别忘的那件 | 紧急 |
| 06 | 临时 | 五分钟内的事 | 重要 |

- 通道只影响**优先级预选**与 `note` 前缀，不改变数据结构；
- URL 参数 `?ch=02` 会直接选中「工作」并预置优先级，适合做成手机桌面快捷方式：

```
http://192.168.1.10:8787/push/?ch=02
```

> 说明：仓库里的下发页使用**相对路径**（`../api`、`../`），因此挂在任意路径下都能用，不需要改 IP。

---

## 3. 口令

- 口令就是服务器环境变量 `MERIDIAN_TOKEN`，部署时生成（`openssl rand -hex 24`）；
- 页面把口令存在浏览器 `localStorage`（键名 `meridian.token`），**不上传、不写 cookie**；
- 页面本身**不含 token**，所以把页面公开也不等于把口令公开；
- 换设备需要重新粘贴一次。

---

## 4. 自定义

页面是单个 HTML，改起来直接：

| 想改什么 | 改哪里 |
| --- | --- |
| 通道名/数量 | `<div class="chips" id="chips">` 里的 `data-ch` 按钮，以及 `applyChannel()` 里的 `pre` 映射表 |
| 默认优先级 | `applyChannel()` 里的 `pre` 对象 |
| 配色 | 顶部 `:root` 变量（`--canvas` / `--ink` / `--ember` / `--hairline`） |
| 默认时间 | `dayInput.value = todayKey(new Date())` 附近 |
| 提交字段 | `send.addEventListener` 里的 `body` 对象（字段以 [docs/API.md](API.md) 为准） |

改完直接替换服务器上的 `/var/www/meridian/push/index.html` 即可，无需重启服务。

---

## 5. 安全建议

1. **公网部署务必用 HTTPS**：口令是明文 Bearer，走 http 等于把口令写在明信片上；
2. 页面与 API 建议同源（本项目默认同源），避免跨域配置；
3. 口令泄露后立刻换：改服务器环境变量并重启 `meridian.service`，旧口令立即失效；
4. 不需要下发能力时，可以直接删掉 `push/` 目录——App 不依赖它。

---

## 6. 与服务端自带 `/push` 的区别

服务器还有一个内置页面 `GET /push?token=...`（见 [docs/API.md](API.md)），区别：

| | 静态下发页（本文件） | 服务端 `/push` |
| --- | --- | --- |
| 位置 | 你自己部署的静态文件 | 服务进程内渲染 |
| 口令 | `localStorage` | `?token=` 查询参数 + cookie |
| 依赖 | 只依赖 API | 依赖服务本身 |
| 适合 | 想改外观、想做快捷方式 | 零配置快速自测 |

两者写的是同一张表，可以都留着。
