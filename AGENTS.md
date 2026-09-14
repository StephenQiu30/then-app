# 于是 iOS 项目协作规范

## 项目边界

本仓库名为 `then-app`，只保存 SwiftUI 客户端、本地 GRDB 数据、随包资源与 iOS 测试。用户可见名称是“于是”，Xcode project、target 与主 Swift module 均为 `ThenApp`。

产品级 Design、PRD、Plan、Acceptance 和服务端接口定义位于同级 `then-server`。开始功能实现前先阅读对应文档和已批准的执行计划；范围、隐私、技术版本或接口发生变化时，先更新中央事实源。

## 服务端接入

- 当前 App 没有已启用的云端 API Client，也不保留 OpenAPI 文件副本、跨仓库符号链接、代码生成插件或空 transport target。
- 服务端以 Gin + Huma 的类型和路由声明为接口事实源，运行时提供 `/openapi.json`、`/openapi.yaml` 与 `/docs`。
- 账号或云端业务真正接入 App 时，先建立独立 spec/checklist，再从服务端运行时 OpenAPI 生成或封装实际使用的请求代码；View 不直接发送网络请求。
- 不创建第二份接口清单，不手写一套与服务端重复的 DTO，不为了尚未接入的功能预装依赖。

## SwiftUI 与本地数据

- 所有产品页面使用 SwiftUI + Observation；UI 默认 Main Actor，异步代码使用结构化 Swift Concurrency。
- 采用 feature-first + MVVM + Repository。View 不直接访问 GRDB、文件、Photos、Vision、网络或供应商 SDK；依赖通过初始化器精确注入。
- 本地数据库固定 GRDB 7.11.1 + SQLite、DatabasePool/WAL 与集中 migration；媒体字节保存在受保护文件中，不存 SQLite BLOB。
- 用户文本进入 String Catalog；使用语义颜色、Dynamic Type、VoiceOver 与足够点击区域，动效支持 Reduce Motion。
- UIKit/WebKit 只封装批准的系统控制器或局部三维渲染表面，不承担页面、导航或业务状态。Three.js 必须离线锁版并经过相应 POC；静态图不能抵扣真实三维验收。
- 人物/衣物照片、生成结果和穿着规律按敏感数据处理；不在日志、测试夹具或仓库中放入真实用户数据。

## 构建与测试

- 固定 Xcode 26.6、Swift 6.3.3、最低 iOS 26、Swift 6 Complete Strict Concurrency。
- 修改至少执行相关 Debug 模拟器构建与测试。测试必须保存独立 xcresult，并用 `xcresulttool get test-results summary` 核对通过、失败和跳过数量。
- GitHub Actions 使用官方 `macos-26` runner，执行工具链检查、Debug 构建和非 UI 自动测试。需要图库、真机、人工视觉、三维性能或 Data Protection 的场景继续按中央 acceptance 单独验证。
- 已知 Vision 诊断套件在 simulator 平台不可用时必须明确跳过并保留 acceptance 阻断，不得把跳过写成能力通过。
- 不新增脚本目录或兼容入口；CI 与 README 直接保存必要命令。

## Git

提交标题使用 `type(scope): subject`，scope 必填。允许 type 为 `feat`、`fix`、`docs`、`refactor`、`perf`、`test`、`build`、`ci`、`chore`、`style`、`revert`；iOS 变更优先使用 `ios` 或明确业务域。每个提交保持单一可说明变化，不提交 DerivedData、xcresult、缓存、密钥、生成代码或私人素材。
