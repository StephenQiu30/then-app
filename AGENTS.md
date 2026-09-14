# 于是 iOS 项目协作规范

## 项目边界

本仓库名为 `then-app`，只保存 SwiftUI 客户端、本地 GRDB 数据、随包资源与 iOS 测试。用户可见名称是“于是”，Xcode project、target 与主 Swift module 为 `ThenApp`；生成 transport module 为 `ThenTransport`。

产品级 Design、PRD、Plan、Acceptance 和唯一 OpenAPI 位于同级 `then-server`，远程地址为 `https://github.com/StephenQiu30/then-server`。开始功能实现前先阅读服务端仓库中的对应文档和已批准 FF-SS 执行计划；状态、产品范围、隐私、技术版本或接口发生变化时先更新中央事实源。

## OpenAPI

- `ThenApp/openapi.yaml` 必须是指向 `../../then-server/backend/openapi.yaml` 的符号链接；不得复制契约、从 Swagger HTML 生成、使用第二份接口清单或手写 transport DTO。
- ThenTransport 的锁定 Build Tool Plugin 在 DerivedData 生成 public Types/Client；生成源码不提交、不手改，不放入 ThenApp 业务模块。
- 服务端契约先修改并校验，再构建本仓库；CI 必须同级检出固定版本的 `then-server` 后验证链接、生成与编译。

## SwiftUI与本地数据

- 所有产品页面使用 SwiftUI + Observation；UI 默认 Main Actor，异步代码使用结构化 Swift Concurrency。
- 采用 feature-first + MVVM + Repository。View 不直接访问 GRDB、文件、Photos、Vision、网络或供应商 SDK；依赖通过初始化器精确注入。
- 本地数据库固定 GRDB 7.11.1 + SQLite、DatabasePool/WAL 与集中 migration；媒体字节保存在受保护文件中，不存 SQLite BLOB。
- 用户文本进入 String Catalog；使用语义颜色、Dynamic Type、VoiceOver 与足够点击区域，动效支持 Reduce Motion。
- UIKit/WebKit 只封装批准的系统控制器或局部三维渲染表面，不承担页面、导航或业务状态。Three.js 必须离线锁版并经过相应 POC；静态图不能抵扣真实三维验收。
- 人物/衣物照片、生成结果和穿着规律按敏感数据处理；不在日志、测试夹具或仓库中放入真实用户数据。

## 构建与测试

- 固定 Xcode 26.6、Swift 6.3.3、最低 iOS 26、Swift 6 Complete Strict Concurrency。
- 修改至少执行相关 Debug 模拟器构建与测试。测试必须保存独立 xcresult，并用 `xcresulttool get test-results summary` 核对通过、失败和跳过数量。
- GitHub Actions 使用官方 `macos-26` runner，执行工具链/契约检查、Debug 构建和非 UI 自动测试。需要图库、真机、人工视觉、三维性能或 Data Protection 的场景继续按中央 acceptance 单独验证。
- 已知 Vision 诊断套件在 simulator 平台不可用时必须明确跳过并保留 acceptance 阻断，不得把跳过写成能力通过。
- 不新增脚本目录或兼容入口；CI 与 README 直接保存必要命令。

## Git

提交标题使用 `type(scope): subject`，scope 必填。允许 type 为 `feat`、`fix`、`docs`、`refactor`、`perf`、`test`、`build`、`ci`、`chore`、`style`、`revert`；iOS 变更优先使用 `ios` 或明确业务域。每个提交保持单一可说明变化，不提交 DerivedData、xcresult、缓存、密钥、生成代码或私人素材。
