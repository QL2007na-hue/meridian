# 构建、签名与侧载

这份文档解决四件事：在 Mac 上把工程跑起来、在没有 Mac 的情况下用 GitHub Actions 产出 IPA、把 IPA 装进 iPad、以及构建失败时从哪里开始查。

Meridian 的源文件只有 Swift、YAML、Python 和 Node —— 没有任何需要 CocoaPods / SPM 拉取的依赖，所以构建的变量只有两个：Xcode 版本和 XcodeGen。

---

## 1. 前置环境

| 场景 | 需要 |
| --- | --- |
| 本地构建 | macOS 14+，Xcode 15 或 16，XcodeGen |
| 云端构建 | 一个 GitHub 仓库；Actions 会提供 macOS 14 runner 和 Xcode |
| 只改图标 / 跑静态检查 | 任意系统，Python 3 + Pillow，Node 18+ |

```bash
brew install xcodegen
xcodegen --version
```

`xcodegen` 只在生成工程时需要；工程文件（`Meridian.xcodeproj`）**不提交**，每次构建都从 `project.yml` 重新生成，这样目录结构和配置不会和磁盘上的源码漂移。

---

## 2. 本地构建（有 Mac）

```bash
cd meridian
xcodegen generate          # 读 project.yml，产出 Meridian.xcodeproj
open Meridian.xcodeproj
```

然后：

- **模拟器**：Scheme 选 `Meridian`，设备选任意 iPad（横屏），Run。模拟器不需要签名。
- **真机**：Xcode → target Meridian → Signing & Capabilities → 勾选 Automatically manage signing → 选你的 Team。免费 Apple ID 也能签，只是 7 天过期。

命令行构建真机包：

```bash
xcodebuild \
  -project Meridian.xcodeproj \
  -scheme Meridian \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build
```

产物：`build/Build/Products/Release-iphoneos/Meridian.app`。

### 为什么关掉签名也能构建

`CODE_SIGNING_ALLOWED=NO` 只是告诉构建系统「不要为签名阶段索取证书」。Swift 照样编译、链接、打包资源、生成 `.app`，只是最后不执行 `codesign`。所以：

- 编译错误、Info.plist 错误、资源错误，unsigned 构建全都能暴露 —— CI 的验证价值不受影响。
- 但产物 **不能直接安装**：iOS 要求每个可执行文件有有效签名。它只是「待签名」的完整 App，交给侧载工具用你的证书重签。

---

## 3. 云端构建（没有 Mac）

`.github/workflows/build.yml` 的步骤：

1. checkout
2. 选 runner 上最新安装的 Xcode（`ls -d /Applications/Xcode*.app | sort -V | tail -1` + `xcode-select -s`）
3. `brew install xcodegen`
4. `xcodegen generate`（仓库根，`project.yml` 在根目录）
5. **断言源 Info.plist**：`UILaunchScreen`、`UIRequiresFullScreen`、`UISupportedInterfaceOrientations~ipad`、`NSLocalNetworkUsageDescription`、`NSAppTransportSecurity`、`UILaunchScreen.UIColorName = LaunchBackground`
6. `xcodebuild ... build`（unsigned，日志 tee 到 `build/xcodebuild.log`）
7. **断言构建产物里的 Info.plist** 也有这些键
8. `mkdir -p out/Payload && cp -R .../Meridian.app out/Payload/ && (cd out && zip -qry Meridian-unsigned.ipa Payload)`
9. `upload-artifact@v4`：artifact 名 `Meridian-unsigned-ipa`，保留 14 天
10. `workflow_dispatch` 或 tag 触发时，用 `softprops/action-gh-release@v2` 把 IPA 挂到 `build-<run_number>` Release
11. 任何步骤失败时，xcodebuild 日志尾部 200 行写进 run summary

### 触发方式

| 方式 | 结果 |
| --- | --- |
| push 到 `main` | 构建 + artifact（不建 Release） |
| Pull Request | 构建 + artifact，用于验证，不发布 |
| Actions 页面 → Build IPA → Run workflow | 构建 + artifact + **Release** |

### 下载产物的两种方式

- **Artifacts**：Actions run 页面底部，下载的是 zip，里面才是 `.ipa`，需要解压。
- **Releases**：右侧 Releases → `build-<N>` → 直接下载 `Meridian-unsigned.ipa`，无需解压。发布脚本走的就是这条路（GitHub API 的 release asset，不经过 artifact zip）。

### 仓库设置（必须）

Release 步骤需要写权限：

> 仓库 → Settings → Actions → General → Workflow permissions → **Read and write permissions** → Save

否则日志里会出现 `Resource not accessible by integration`，构建本身成功但没有 Release，`publish-to-github.mjs` 会等不到 asset。

---

## 4. 未签名 IPA 的结构与侧载

```
Meridian-unsigned.ipa
└── Payload/
    └── Meridian.app/
        ├── Meridian              # 可执行文件（未签名，或 ad-hoc 签名）
        ├── Info.plist
        ├── Assets.car            # 图标与颜色
        ├── PkgInfo
        └── _CodeSignature/       # 关闭签名时可能不存在
```

IPA 本质就是一个 zip；只要 `Payload/Meridian.app` 层级正确，侧载工具就认。App 的 Bundle ID 由 `project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER` 决定（`app.meridian.clock`）。

侧载工具：

| 工具 | 平台 | 有效期 | 说明 |
| --- | --- | --- | --- |
| AltStore | Windows/macOS + iOS | 7 天（免费 ID） | 需要 AltServer 在电脑上常驻，自动续签 |
| Sideloadly | Windows/macOS | 7 天（免费 ID） | 一次性重签，到期手动重签 |
| TrollStore | iOS 设备 | 永久 | 仅限 CoreTrust 漏洞版本（约 14.0–16.6.1 / 17.0） |
| Xcode | macOS | 7 天 / 1 年 | 直接 Run 到已注册设备 |

免费 Apple ID：签名 7 天、最多 3 个 App、不能推送。重签不会清掉 App 沙盒数据（`Application Support/Meridian/state.json` 保留），未同步的改动会在下次启动时回放。

---

## 5. 可选：CI 内签名

未配置任何 secret 时，签名相关步骤整段跳过，**不会让 fork 构建失败**。配置以下 secrets 后，workflow 会额外产出签名 IPA（archive → export，`method: ad-hoc`）：

| Secret | 内容 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | `.p12` 的 base64（`base64 -i cert.p12 \| pbcopy`） |
| `P12_PASSWORD` | 导出 `.p12` 时设的密码 |
| `BUILD_PROVISION_PROFILE_BASE64` | `.mobileprovision` 的 base64 |
| `KEYCHAIN_PASSWORD` | 任意临时密码，runner 上用一次就销毁 |
| `APPLE_TEAM_ID` | 10 位 Team ID（开发者账号页面可查） |

说明：ad-hoc 导出要求 `mobileprovision` 里包含目标设备 UDID（或使用 Development 描述文件）；免费账号没有分发证书，通常在本地用 Xcode / Sideloadly 签，而不是在 CI 里签。没有付费账号时，忽略这一节，用 unsigned IPA + 侧载工具即可。

---

## 6. 失败排查

### 先看哪里

1. Actions run 页面 → 红色步骤名；
2. 页面底部的 **Summary**：workflow 会把 `build/xcodebuild.log` 尾部 200 行贴进去；
3. 仍不够时，展开失败步骤的完整日志，搜索第一个 `error:`（不是最后一个，编译错误会级联）。

本地先跑一遍静态检查，能挡掉大部分「CI 才发现」的问题：

```bash
node Tools/swiftcheck.mjs
```

### 三条最常见错误

**① `xcodegen: command not found` / `brew install xcodegen` 失败**

runner 上没有预装 XcodeGen（macOS 镜像不保证）。workflow 已有 `brew install xcodegen`；若 Homebrew 更新步骤偶发失败，重跑一次即可。本地等价：`brew install xcodegen`。也要注意 `project.yml` 必须在仓库根，`xcodegen generate` 默认读当前目录。

**② Info.plist 键丢失（`::error::UILaunchScreen is missing`）**

原因几乎总是有人把 `INFOPLIST_FILE` 改成了 XcodeGen 的 `info:` 键。`info:` 会「生成」plist，并丢弃没有在 `info.properties` 里重述的所有键。后果：`UILaunchScreen` 丢失 → App 被 letterbox（黑边、非全屏）；`NSLocalNetworkUsageDescription` 丢失 → 访问局域网服务器时被系统直接终止。workflow 在源文件和构建产物两处断言，`swiftcheck.mjs` 也会报警。

**③ Swift 编译错误（`error: cannot find 'XxxPanel' in scope` 等）**

说明某文件没进 target 或没提交。检查：

```bash
xcodegen generate
grep -n "path:" project.yml          # sources 应为 ios/Meridian
node Tools/swiftcheck.mjs            # 括号平衡、必需视图、Theme 成员
```

常见具体原因：新增的 `.swift` 在 `ios/Meridian/` 之外（不会被 target 收录）；`struct` 名字拼错；两个文件都定义了同名类型；用了 iOS 18 API（如 `.scrollTargetBehavior`、`@Entry`、新 `Tab`）—— `swiftcheck.mjs` 的黑名单会直接拦下。

### 其他

- **"future Xcode project file format"**：runner 默认 Xcode 太旧，workflow 已选最新；本地 `sudo xcode-select -s /Applications/Xcode.app` 后重新 `xcodegen generate`。
- **`Resource not accessible by integration`**：见第 3 节的 Workflow permissions。
- **Release 步骤没跑**：只在 `workflow_dispatch` 或 tag 上执行；push/PR 只有 artifact。
- **`actool` 报 app icon 相关错误**：`AppIcon.appiconset` 里只能有 `Contents.json` 引用到的 PNG；换过图标命名后重跑 `python Tools/make-icon.py`，脚本会清掉旧文件。若某个 Xcode 版本不接受「全尺寸集 + 单尺寸 1024」并存，删掉 `Contents.json` 里 `"idiom": "universal", "platform": "ios"` 那一条（保留完整尺寸集）即可，构建与安装不受影响。
- **zip 里没有 Payload**：检查 `cp -R` 的源路径是否为 `Release-iphoneos/Meridian.app`（不是 `Meridian.app.dSYM`）。

---

## 7. 本地工具

```bash
# 静态检查（括号、禁用 API、必需视图、Theme 成员、project.yml/Info.plist/Assets）
node Tools/swiftcheck.mjs

# 重新生成图标（幂等覆盖，输出全 RGB、无 alpha）
python Tools/make-icon.py
python Tools/make-icon.py --out ios/Meridian/Assets.xcassets

# 无 git 一键发布（建仓 → 提交 → 触发 → 轮询 → 下载 IPA）
GITHUB_TOKEN=ghp_xxx node Tools/publish-to-github.mjs
node Tools/publish-to-github.mjs --dry-run     # 只列文件，不联网
```

`publish-to-github.mjs` 的环境变量：`GITHUB_TOKEN`（必填，classic，`repo` + `workflow`）、`GITHUB_OWNER`（默认取 token 的 `/user`）、`GITHUB_REPO`（默认 `meridian`）、`GITHUB_PRIVATE=1`（私有仓库）。轮询 8s 一次、最长 35 分钟；失败时打印失败 job 的日志尾部。
