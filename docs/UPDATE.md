# 更新机制

> 先说结论：**iOS 不允许 App 替换自己的二进制**，没有"应用内更新"这种能力（越狱插件除外）。所以"更新"这件事，本质是"用户侧覆盖安装"。本项目把这条路的代价压到了"点一下"。

---

## 1. 为什么不能自更新

- App 运行在沙盒里，写不到自己的 `.app` 目录；
- 即使能写，iOS 也会校验代码签名，改过的二进制无法启动；
- 企业签名 / 侧载工具（TrollStore、AltStore、Sideloadly）之所以能装，是因为它们**在系统层面**替换了签名或绕过了校验，这属于安装器，不是 App 的权限。

所以正确的心智模型是：**App 只负责"发现有新版"和"把安装链接给你"，安装交给安装器。**

---

## 2. 三层方案

### 第 1 层：App 内版本检查（已内置）

- 启动时静默请求 `<你的服务器>/meridian/files/version.json`；
- 与本机 `CFBundleVersion` 比较，**严格更大**才提示；
- 设置 → 关于 → 更新行显示「有新版本 r22（b22）· 数据会保留」+「安装 r22」按钮；
- 点按钮只是 `UIApplication.open(url)`：打开 IPA 链接，TrollStore / AltStore 接手。

`version.json` 格式（放在 `deploy/portal/version.json.example`）：

```json
{
  "tag": "r22",
  "builtAt": "2026-11-16 20:30",
  "file": "Meridian-unsigned.ipa",
  "bytes": 933917,
  "bundleVersion": "22",
  "md5": "46abc924b87a692ff4a7284d00b0a0c0",
  "url": "http://YOUR_HOST/meridian/files/Meridian-unsigned.ipa",
  "notes": "可选说明"
}
```

### 第 2 层：AltStore / SideStore 源（最接近无缝）

把 `meridian-source.json.example` 改成你自己的地址，放到

```
<你的服务器>/meridian/files/meridian-source.json
```

然后在 AltStore 里添加这个源。之后：

- AltStore 自动检查版本、一键更新；
- 免费 Apple ID 的 7 天签名会**自动续签**（这才是侧载最大的痛点）。

### 第 3 层：TrollStore 覆盖安装

TrollStore 无签名期限，但没有自动更新机制。流程是：下载新 IPA → 拖入 TrollStore → 覆盖安装。**同 bundle id 覆盖，App 容器保留**，配置与待办都在。

---

## 3. 版本号语义（这里踩过坑）

两个号必须区分：

| 号 | 来源 | 作用 |
| --- | --- | --- |
| `CFBundleVersion` | CI 注入 `github.run_number` | **iOS 判断"是不是新版本"的唯一依据** |
| `BuildTag.build`（`r22`） | 手改，给人看 | 设置页里那串 `1.0.0 · r22 · b22` |

> 踩过的坑：早期 `project.yml` 里把 `CURRENT_PROJECT_VERSION` 写死成 `"1"`，于是 r8–r15 所有包的 `CFBundleVersion` 都是 1。iOS 认为它们是同一个版本，覆盖安装被当成"没有变化"，旧二进制留在设备上——表现就是"装了新版但设置里还是旧版本号"。
>
> 现在 `build.yml` 里是：
> ```yaml
> CURRENT_PROJECT_VERSION="${{ github.run_number }}"
> ```
> 每次构建都不同。

---

## 4. 健壮性（`AppModel+Update.swift`）

| 风险 | 处理 |
| --- | --- |
| 服务器不可达 | 8 秒超时、单次请求、失败**静默**，不误报"已是最新" |
| 旧版本文件未删 | 只在新 build 严格大于当前时提示（按数值比较，不是字符串） |
| 恶意链接 | 只接受 `http` / `https`，其他 scheme 直接忽略 |
| 装错包 | 界面显示构建时间 + **md5 前 8 位**，可核对 |
| 误触 | 不自动下载、不自动安装，必须用户点 |
| 数据丢失 | 覆盖安装保留容器；README 与设置页都写明 |
| 频繁请求 | 60 秒内重复调用被合并（`force` 可强制） |

实现只有 90 行，位于 `ios/Meridian/Core/AppModel+Update.swift`。

---

## 5. 发布流程（本项目的实际做法）

```
改 BuildTag.build → push main
   → GitHub Actions: xcodegen → xcodebuild → Payload/*.ipa → Release asset
   → 上传 IPA 到服务器 files/
   → 生成/更新 files/version.json（含 md5 与 url）
   → 设备下次启动看到「有新版本」
```

`Tools/publish-to-github.mjs` 负责前半段（无 git 环境也能用：Git Data API 一次性提交、触发 workflow、轮询、从 Release asset 下载 IPA）。
