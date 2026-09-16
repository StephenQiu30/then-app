# 于是 iOS

`Then/then-app` 是独立 SwiftUI 仓库，Xcode project/target/scheme 为 `ThenApp`。App 与 Web 的唯一视觉和交互标准是根目录 [DESIGN.md](DESIGN.md)，其镜像位于 `../then-server/DESIGN.md`；产品能力文档位于同级 [then-server](../then-server/docs/README.md)，实施前再读 [当前执行计划](../then-server/docs/plan/10-OOTD产品实施计划.md)。

## 当前状态

- 已实现无图/单件图片衣橱、本地穿搭计划、快照/编辑/取消/删除与重启恢复；图片和最大字号计划的模拟器开发检查已完成，人工与真机发布仍待验。
- Three.js 工程舞台已有离线 GLB、换装/观察和轻微待机/交互反馈。正式可爱资产、穿模、眨眼/轻微视线及完整动态/设备验收尚未完成。
- 三套人物/内置衣物的正式多视角发布、推荐、实际穿着/反馈、本人 AI、360° 和同步仍按独立切片推进。当前没有云端 API Client，默认功能不要求注册或上传衣物。

## 固定边界

SwiftUI + Observation 拥有全部页面和业务状态，GRDB + SQLite 保存本地事实。Three.js/标准 GLB 是固定三维路径，经隔离 WKWebView 加载锁版随包资源；禁止运行时 CDN/远程脚本和任意用户模型，不使用 Blender。

WebKit 使用非持久存储、受控 local scheme、导航白名单及 CSP；Swift 负责资源验证与生命周期。装饰性动效遵循 Reduce Motion，进入后台停止。工程夹具与生产资产分开验收，详见 [Three.js 研究](../then-server/docs/design/threejs-avatar-research.md)。

服务端由 Gin/Huma 运行时提供 OpenAPI。实际账号或云功能接入前先固定 spec/checklist，不保留空 transport target、物化契约或跨仓符号链接。

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

签名使用 Automatic，但仓库不提交 `DEVELOPMENT_TEAM`。模拟器构建无需 Team；真机与 Archive 前由维护者在本地选择正确 Apple Developer Team，并单独确认正式 Bundle ID 所有权。完整选型与排除项见 [Design 01](https://github.com/StephenQiu30/then-server/blob/main/docs/design/01-技术选型.md)。



## 验收边界

开发使用 Xcode 与现有模拟器，不自动新建/删除/重置设备。每次测试保存独立 xcresult 并核对实际通过/失败/跳过。标准 CI 不覆盖图库预置的完整 UI、真机保护或人工视觉；详细结果统一写入中央 Acceptance，不在 README 追加实验日志。
