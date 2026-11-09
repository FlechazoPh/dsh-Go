# dsh-Go iOS 版（remote-only）

> English version below.

这个分支是 [dsh-Go](https://github.com/ccch1mneyyy/dsh-Go)（DeepSeek Harness 手机客户端）的 **iOS 精简移植**，只保留远程模式。上游是纯 Android 应用、没有 iOS 端；这个分支补了一个最小的 iOS Runner 和必要的 Dart 侧改造（文件里标有 `iOS remote-only build` 的地方），其余代码全部跟随上游。

当前跟随的上游版本：**1.0.14**（见 `.github/ios-upstream-sync.json`；每次上游发新版，`upstream-sync` workflow 会自动同步、构建并发 release）。

## 保留 / 砍掉

保留：

- 聊天（与远程 DSH 引擎对话）
- SSH 远程主机（直连你电脑上的 DSH）
- DSH Remote 中继直连（WebRTC DataChannel）
- 网页版（WebView 打开 DSH Web）
- 分享、主题、插件界面
- 离线缓存：无连接时显示上次的会话列表与消息（列表 24 小时过期、消息 7 天过期）
- 本地通知（4 种提醒）与实时活动 / 灵动岛（需 iOS 16.2+）

砍掉（iOS 上没有对应实现）：

- 本机引擎（PRoot + Ubuntu）
- 手机操控（无障碍 / Shizuku）
- 桌宠悬浮窗
- 桌面图标切换 / 快捷方式
- 动态取色、应用内更新

## 安装（从 Release 装 IPA）

1. 打开本仓库的 **Releases**，下载最新的 `dsh-go-ios-remote-only-<版本>-b<构建号>.ipa`（例如 `dsh-go-ios-remote-only-1.0.14-b15.ipa`）。
2. 用你常用的侧载工具安装（SideStore / AltStore / Sideloadly 等）。IPA 是**未签名**的，需要你自己签名。
3. 免费 Apple ID 证书有效期 7 天，到期后重新签名安装即可；App 数据不受影响。
4. 最低 iOS 15.0；实时活动 / 灵动岛需要 iOS 16.2+。

## 本地构建

需要 macOS + Xcode 27 + Flutter 3.47.7（与 `.github/workflows/ios-unsigned.yml` 用的版本一致）：

```bash
cd app
flutter pub get
flutter analyze
flutter build ipa --no-codesign --build-name "$(grep '^version:' pubspec.yaml | sed 's/^version: *//; s/+.*//')" --build-number 1
```

`--no-codesign` 只会产出 archive，不会导出 IPA，需要手工打包：

```bash
APP="build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app"
mkdir -p /tmp/dsh-ipa/Payload
cp -r "$APP" /tmp/dsh-ipa/Payload/
(cd /tmp/dsh-ipa && zip -r -y dsh-go-ios-remote-only.ipa Payload)
```

也可以直接推分支触发 `.github/workflows/ios-unsigned.yml`，产物在 workflow 的 artifact 里（保留 30 天）。

## 自动跟随上游

`.github/workflows/upstream-sync.yml` 每天 01:00 UTC（北京时间 09:00）检查上游最新 release tag，也支持手动触发（可指定 tag）：

- 有新 tag → 把该 tag 合并进 `ios-remote-only` → 更新 `.github/ios-upstream-sync.json` 与 `app/pubspec.yaml` 的版本号 → 构建 IPA → 发公开 release（tag `ios-vX.Y.Z`，标题 `dsh-Go iOS remote-only X.Y.Z (b<构建号>)`，附件为 IPA，更新日志为上游 `docs/changelog.md` 的新条目 + iOS 说明）。
- 同步目标永远是上游的 **release tag**，不跟上游 `main` 的未发布提交。
- 合并冲突或构建失败时**停手**：不 push、不发 release，并在仓库里开一个 issue 等人工处理。
- `ios-unsigned.yml` 本身不发 release，只在 push / 手动触发时出 artifact。

## 已知限制

- **通知只在 App 活着时发出**。iOS 把 App 挂起后，电脑端回完消息也发不出通知（需要推送服务器 + 付费开发者账号的 APNs，这个分支做不了）。需要离线提醒的话，可以另搭 Telegram 中继订阅引擎事件。
- **切后台会断开**：回到前台时重连并重新加载对话数据（iOS 挂起进程 + socket 失效；对话数据在引擎主机上，重连后重新拉取是上游原版的设计）。
- 实时活动最长 8 小时；App 挂起后实时活动冻住。点实时活动只打开 App，不跳到对应对话。
- 侧载重签名时要覆盖 `.appex`（Live Activity 扩展）。
- 上游版本在真机上没有逐一验证过（上游自己也这么说）；遇到问题请开 issue。

## 授权说明

- 代码部分遵循上游的 **AGPL-3.0**。
- 按上游 `ASSETS.md`：**DSH Go 名称与鲸鱼娘（Deepy）形象不在开源授权范围内**。其中鲸鱼娘模型由 B 站「Mao绒绒家园」创作、经作者授权随 DSH Go 分发（上游 1.0.14 起随包内置）。
- 本 iOS 构建仅供个人学习与自用；使用风险自担，与上游作者无关。
- 上游正在做自己的 iOS 基础支持（`feat/ios-foundation` 分支）；这个移植是过渡方案，上游官方 iOS 版发布后以官方为准。

---

# dsh-Go for iOS (remote-only)

This branch is a **slim iOS port** of [dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) (a DeepSeek Harness mobile client), keeping remote mode only. Upstream is Android-only with no iOS target; this branch adds a minimal iOS Runner plus the necessary Dart-side changes (marked `iOS remote-only build` in the touched files). Everything else tracks upstream.

Currently tracking upstream **1.0.14** (see `.github/ios-upstream-sync.json`; the `upstream-sync` workflow syncs, builds and releases automatically whenever upstream ships a new version).

## Kept / removed

Kept:

- Chat (talking to a remote DSH engine)
- SSH remote hosts (direct connection to DSH on your computer)
- DSH Remote relay (WebRTC DataChannel)
- Web version (DSH Web in a WebView)
- Sharing, themes, plugin UI
- Offline cache: shows the last session list and messages while offline (list expires after 24h, messages after 7 days)
- Local notifications (4 kinds) and Live Activities / Dynamic Island (iOS 16.2+)

Removed (no iOS equivalent):

- Local engine (PRoot + Ubuntu)
- Phone control (accessibility / Shizuku)
- Desktop pet floating window
- App icon switching / shortcuts
- Dynamic color, in-app updates

## Install (IPA from Releases)

1. Open this repo's **Releases** and download the latest `dsh-go-ios-remote-only-<version>-b<build>.ipa` (e.g. `dsh-go-ios-remote-only-1.0.14-b15.ipa`).
2. Sideload it with your usual tool (SideStore / AltStore / Sideloadly, etc.). The IPA is **unsigned**; sign it yourself.
3. A free Apple ID certificate lasts 7 days; re-sign and reinstall when it expires. App data is kept.
4. Minimum iOS 15.0; Live Activities / Dynamic Island need iOS 16.2+.

## Build locally

Requires macOS + Xcode 27 + Flutter 3.47.7 (same versions as `.github/workflows/ios-unsigned.yml`):

```bash
cd app
flutter pub get
flutter analyze
flutter build ipa --no-codesign --build-name "$(grep '^version:' pubspec.yaml | sed 's/^version: *//; s/+.*//')" --build-number 1
```

`--no-codesign` only produces an archive, not an IPA; package it by hand:

```bash
APP="build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app"
mkdir -p /tmp/dsh-ipa/Payload
cp -r "$APP" /tmp/dsh-ipa/Payload/
(cd /tmp/dsh-ipa && zip -r -y dsh-go-ios-remote-only.ipa Payload)
```

Or push to the branch and let `.github/workflows/ios-unsigned.yml` build it; the IPA is in the workflow artifacts (kept 30 days).

## Automatic upstream tracking

`.github/workflows/upstream-sync.yml` checks upstream's latest release tag daily at 01:00 UTC (09:00 CST), and can also be triggered manually (with an optional tag):

- New tag → merge it into `ios-remote-only` → update `.github/ios-upstream-sync.json` and the version in `app/pubspec.yaml` → build the IPA → publish a public release (tag `ios-vX.Y.Z`, title `dsh-Go iOS remote-only X.Y.Z (b<build>)`, IPA attached, release notes from upstream `docs/changelog.md` plus iOS notes).
- The sync target is always an upstream **release tag**, never upstream `main` HEAD.
- On a merge conflict or build failure it **stops**: nothing is pushed, no release is created, and an issue is opened in this repo for manual handling.
- `ios-unsigned.yml` itself never creates releases; it only produces artifacts on push / manual trigger.

## Known limitations

- **Notifications only fire while the app is alive.** Once iOS suspends the app, no notification can be delivered when the computer replies (that needs a push server + paid Apple Developer Program APNs, which this fork cannot do). For offline alerts, a Telegram relay subscribing to engine events can be set up separately.
- **Backgrounding disconnects**: returning to the foreground reconnects and reloads the conversation data (iOS suspends the process and the socket drops; the data lives on the engine host, and re-fetching on reconnect is upstream's design).
- Live Activities last at most 8 hours and freeze once the app is suspended. Tapping one only opens the app; it does not jump to the conversation.
- When re-signing a sideload, cover the `.appex` (Live Activity extension) too.
- Upstream versions are not all verified on real phones (upstream says so itself); please open an issue if you hit a problem.

## Licensing

- Code is under upstream's **AGPL-3.0**.
- Per upstream `ASSETS.md`, the **DSH Go name and the whale-girl (Deepy) artwork are NOT covered by the open-source license**. The whale-girl model is by Mao绒绒家园 on Bilibili and is distributed with DSH Go with the author's permission (bundled since upstream 1.0.14).
- This iOS build is for personal learning and use only; use at your own risk; not affiliated with the upstream author.
- Upstream is working on its own iOS support (`feat/ios-foundation` branch); this port is a stopgap until an official iOS version ships.
