# 于是 iOS

`Then/then-app` 是独立 SwiftUI 仓库，Xcode project/target/scheme 为 `ThenApp`。App 与 Web 的共享视觉标准是根目录 [DESIGN.md](DESIGN.md)，工程规范见 [AGENTS.md](AGENTS.md) 与服务端 [PROJECT.md](../then-server/PROJECT.md)。

## 当前状态

已有本地衣橱、单件图片导入、穿搭推荐、计划、实际穿着与反馈，使用 SwiftUI + Observation、GRDB + SQLite；离线 Three.js 工程舞台仍由受控 WKWebView 加载随包 GLB。调试专用人物照片 POC 已移除。

个人首版目标为本人参考/风格 → 完整 Look 图 → 确认后按需静态 GLB → 查看、本地保存与日期复用。先验一套满意结果，再扩五套。真实效果、费用、生产资产、个人 API、存储适配和设备验收尚未完成。

Three.js 使用离线锁版资源。WebKit 使用非持久存储、受控 local scheme、导航白名单及 CSP；Swift 负责资源验证与生命周期。禁止运行时 CDN、远程脚本和任意用户模型；动效遵循 Reduce Motion，后台停止。

## 资源与本地化

随包资源在 `ThenApp/Resources` 和 Asset Catalog；命名语义化，来源与 hash 可追溯。生产用户素材不进仓库，照片/生成媒体为受保护私有文件。

首发 `zh-Hans`。用户文案使用 `Localizable.xcstrings`，App 名称与权限使用 `InfoPlist.xcstrings`；Dynamic Type、VoiceOver、语义颜色和 Reduce Motion 是交付要求。

## 构建与测试

构建与测试直接使用 `xcodebuild`。测试显式指定实际模拟器 UDID 和独立 `-resultBundlePath`；完成后用 `xcresulttool` 核对结果摘要。App 构建通过不代表 OOTD 发布验收完成。

- 工程：`ThenApp.xcodeproj`
- 共享 Scheme：`ThenApp`
- App target / Swift module：`ThenApp`
- 单元/集成测试 target：`ThenAppTests`
- UI 测试 target：`ThenAppUITests`
- 开发 Bundle ID：`com.stephenqiu.then`（正式签名启用前确认所有权）

在仓库根目录执行：

```bash
xcodebuild -resolvePackageDependencies \
  -project ThenApp.xcodeproj \
  -scheme ThenApp

xcodebuild -project ThenApp.xcodeproj \
  -scheme ThenApp \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  clean build

xcodebuild -project ThenApp.xcodeproj \
  -scheme ThenApp \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  test
```

签名使用 Automatic，但仓库不提交 `DEVELOPMENT_TEAM`。模拟器构建无需 Team；真机与 Archive 前由维护者在本地选择正确 Apple Developer Team，并单独确认正式 Bundle ID 所有权。依赖版本以 Xcode 工程与 Package.resolved 为准。



## 验收边界

开发使用 Xcode 与现有模拟器，不自动新建/删除/重置设备。每次测试保存独立 xcresult 并核对实际通过/失败/跳过。标准 CI 不覆盖图库预置的完整 UI、真机保护或人工视觉；验证结果记录在当次交付中，不在 README 追加实验日志。
