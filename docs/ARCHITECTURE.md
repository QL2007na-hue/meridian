# 架构

```
┌──────────────────────────────────────────────┐        ┌──────────────────────────────────┐
│              iPad App (SwiftUI)              │        │        Node 任务服务              │
│                                              │        │  server/meridian-server.mjs      │
│  App/       RootView · PanelStrip · Status   │ Bearer │  127.0.0.1:8787                  │
│  Clock/     ClockStage · TimeReadout · 秒环  │  JSON  │  · REST 快照 / CRUD              │
│  Agenda/    AgendaPanel · 提醒 · 窥视条      │ ◀────▶ │  · SSE 广播                      │
│  Sync/      SyncEngine · SSE · WireCodec     │  SSE   │  · data.json（临时文件+rename）   │
│  Core/      模型 · 存储 · 皮肤 · 传感器       │        └───────────────┬──────────────────┘
│  Settings/  设置页                            │                        │ proxy
│  Design/    Theme · 基础组件                  │        ┌───────────────┴──────────────────┐
└──────────────────────────────────────────────┘        │  nginx（可选）                     │
                                                        │  /meridian/        静态门户        │
                                                        │  /meridian/push/   下发页          │
                                                        │  /meridian/api/    → 127.0.0.1:8787│
                                                        │  /meridian/files/  IPA 下载        │
                                                        └──────────────────────────────────┘
```

---

## 1. App 分层

| 目录 | 职责 | 依赖方向 |
| --- | --- | --- |
| `Design/` | `Theme`（颜色/字号/间距/弧度/动效 token）+ 基础组件 | 不依赖任何业务 |
| `Core/` | `Models`（数据契约）、`AppModel`（唯一 store）、`Skin`/`Background`、`LightSensor`、`Diagnostics`、`UpdateInfo` | 只依赖 Design |
| `Sync/` | `SyncEngine`（轮询/SSE/outbox）、`SSEClient`、`WireCodec`、`TrustingSession` | 依赖 Core |
| `Clock/` | 时间舞台与它的原子视图（秒环、日期、背景、专注/世界时钟） | 依赖 Core + Design |
| `Agenda/` | 今日/接下来/服务器面板、任务行、快速添加、提醒、窥视条 | 依赖 Core + Design |
| `Settings/` | 设置页（外观/背景/显示/服务器/关于） | 依赖 Core + Design |
| `App/` | `MeridianApp`、`RootView`、`PanelStrip`、`StatusStrip` | 组合以上全部 |

约定：**视图不写状态**，所有变更走 `AppModel` 的方法（`addTask`/`toggle`/`resolveAlert`/`applyPreset`…），这样持久化与同步只有一处入口。

---

## 2. 同步状态机

```
bootstrapSync()
   ├─ config 未配置 / 自动同步关闭 → cancelAll，phase = .idle
   └─ 已配置
        ├─ pollLoop   每 max(15, syncInterval) × 2^backoff 秒
        │     ├─ flush(outbox)     先把本地改动发出去
        │     └─ pullSnapshot()    再拉全量，按 updatedAt 合并
        └─ streamLoop   SSE，断线指数退避（1→2→4→8→16→30s）
              └─ 收到 snapshot / task / delete 事件就地合并
```

**合并规则**（`applySnapshot`）：

1. 在 outbox 里的任务，**本地优先**（用户的点击还没到服务器，不能被覆盖）；
2. 其余按 `updatedAt` last-write-wins；
3. `origin == .local` 且服务器快照里没有的，保留（服务器还没见过它）；
4. `origin == .remote` 且快照里没有的，视为别处已删，移除。

**错误分类**：

| 情况 | 行为 |
| --- | --- |
| `URLError`（非取消） | `.offline` + 指数退避 |
| 401/403 | `.failed("鉴权失败")`，停止轮询（改口令或回前台会重启） |
| 429 / 5xx | `.offline` + 退避 |
| 解码失败 | `.failed("数据格式不符")` |
| 404/410（删除） | 视为成功（幂等） |

**outbox**：按 task id 合并（后来的覆盖先前的；已排队的删除不会被后续编辑复活），串行发送，失败留队。出队前比对 `updatedAt`，防止把飞行期间的点击吞掉。

---

## 3. 刷新率分层（省电的关键）

| 内容 | 驱动 | 频率 |
| --- | --- | --- |
| 大数字 HH:MM、顶部日期、底部进度 | `TimelineView(.everyMinute)` | 1/分钟 |
| 秒数字、秒环 | 各自独立的 `TimelineView(.periodic(by: 1))` | 1 Hz，**只作用于两个 glyph 级视图** |
| 防烧屏位移 | `TimelineView(.periodic(by: 1800))` | 1/30 分钟 |
| 世界时钟 | `.everyMinute` | 1/分钟 |
| 提醒心跳 | `Timer.publish(every: 1)` | 1 Hz，只做一次过滤 |
| 背景 | 静态层；仅 `aurora` 有 14s 呼吸（reduce motion 关闭） | — |

也就是说：**屏幕每秒只重绘两个小视图**，不是整块时钟。

---

## 4. 三条支线

### 4.1 到期提醒

`Timer` 每秒调 `AppModel.announceDueTasks()` → 找最早到点且未提醒过的任务 → `alertTask` 非空 → `TaskAlertHost` 渲染小窗。

- 一次只弹一条（`guard alertTask == nil`）；
- 同一任务只提醒一次（`alertedTaskIDs`）；
- 抖动是时间的纯函数（SplitMix 哈希三个八度混成噪声），重绘不会重新掷骰子；
- 震动由 `AlertHaptics` 独占，`AppModel` 不再发 success/tap，避免两个生成器打架；
- 关闭只由用户点击触发，视图里没有任何自动消失定时器。

### 4.2 环境光

两条路径共用 `ambientLevel`（0…1）与 `ClockStage.stageOpacity`（`0.55 + level × 0.45`，下限 55% 保证可读）：

- **屏幕背光**（默认）：`UIScreen.brightness` + 变化通知，1 秒节流，零硬件唤醒；
- **摄像头脉冲**（可选）：每 30 秒开 0.35 秒，读 Y 平面均值，与屏幕读数 0.7:0.3 融合，其余时间 `stopRunning()`。

后台一律停止；权限被拒静默退回屏幕模式。

### 4.3 在线更新

`<server>/meridian/files/version.json` → 比较 `CFBundleVersion` → 只在新版严格更大时把 `availableUpdate` 设上 → 设置页出现「安装 rXX」→ `UIApplication.open(ipaURL)`，安装器接手。

详见 [UPDATE.md](UPDATE.md)。

---

## 5. 为什么这些选择

| 选择 | 理由 |
| --- | --- |
| 零第三方依赖 | 一个要挂一周的时钟不该有依赖升级风险；也让 CI 不需要解析 SPM |
| XcodeGen 而非提交 pbxproj | 工程可读、可 review、不会和源码漂移；合并冲突从"几千行 XML"变成"几十行 YAML" |
| 服务器零 npm 依赖 | 单文件 `node server.mjs` 就能跑，部署到任意一台有 Node 的机器 |
| JSON 文件而非数据库 | 一天几十条待办，数据库是负担；原子写 + 损坏隔离已经够 |
| `ObservableObject` 而非 `@Observable` | 与 iOS 17 之前的思维模型一致，避免宏在 CI 里的边缘问题 |
| 一个 store | 视图层没有第二条数据通路，同步/持久化只有一处入口 |

---

## 6. 已知取舍

- **SSE 断线不补发**：服务端不发 `Last-Event-ID` 历史，重连后靠全量快照对齐。简单、够用，代价是重连瞬间多一次全量。
- **合并依赖"快照是全量"**：如果后端改成分页/只返当天，`origin == .remote` 的清理逻辑会误删。改后端前先看 `SyncEngine.applySnapshot` 的注释。
- **提醒不排队**：一次只弹一条，其余等到下一条被处理后再弹（同一分钟两条到期会依次出现，不会叠加）。
- **证书信任是"接受该 host 的任意证书"**：不防中间人替换服务器。要更严可改指纹固定（`TrustingSession` 里预留了位置）。
