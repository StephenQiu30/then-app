# iOS

“于是”OOTD 客户端固定使用 Xcode 26.6、Swift 6.3.3 和 SwiftUI，最低支持 iOS 26。App 显示名暂时保留“于是”，内部 Xcode target 和 Swift module 保留 `ThenApp`。

实现原则：

- 所有产品页面使用 SwiftUI，Observation + `@Observable` 管理界面状态。
- UIKit 只封装缺少 SwiftUI 接口的系统控制器，以及已批准的局部 WebKit 图形渲染表面；不承担页面导航、全局状态或业务架构。
- Swift 6 language mode、Complete Strict Concurrency、Approachable Concurrency，UI 默认 Main Actor 隔离。
- 首版只保留一个生产 `ThenApp` Swift module，加 `ThenAppTests` 与 `ThenAppUITests`，不把 Feature 拆成内部 framework 或 Swift Package。
- 采用 feature-first + MVVM + Repository。
- PhotosUI、AVFoundation、Vision、UserNotifications 和网络能力通过服务协议封装。
- 本地数据固定使用 GRDB 7.11.1 + 系统 SQLite 的 DatabasePool/WAL；衣橱、基础推荐和穿搭记录离线可用。
- API 客户端从 `../backend/openapi.yaml` 生成；AI 试穿与动态预览是可失败、可取消的异步增强。
- 禁止 SwiftData、Core Data、Realm、RxSwift、Combine 全局状态、第三方页面/UI 架构和第三方 DI 容器。Three.js 只能作为下述受控 renderer，不属于页面架构例外。

当前工程已经满足 SwiftUI App 入口、Observation、Swift 6 严格并发、GRDB 与 OpenAPI 精确锁版。现有 Ledger、Calendar、Travel、Life、Today 和 Profile 实现属于上一产品方向；在用户数据保留和删除策略确认前停止扩展，后续按功能目录成组移除，不能零散删除导致数据库、工程引用或测试夹具失配。

## 条件 Three.js 动态渲染

- 普通按钮反馈、页面转场、加载状态和离散帧切换优先 SwiftUI。只有透视/深度合成、着色器、粒子或 scene graph 确有价值，并由对应 design 与 `FF-SS` 执行计划批准时，才可使用 Three.js。
- 最低 iOS 26 使用 `UIViewRepresentable` 在 Rendering Service adapter 中封装 `WKWebView`。SwiftUI 继续拥有页面、原生手势/无障碍控件和文案；Observation/ViewModel 继续拥有状态；WebView 只是一块可替换画布。
- 首个候选固定 `three@0.185.1` 和 `WebGLRenderer`/WebGL 2。HTML、JavaScript、shader、解码器与允许的 addon 必须锁版、随 App 离线打包；不得从 CDN、远程页面或后端下载并执行代码。
- Swift Service 负责认证、媒体下载、hash/尺寸校验、缓存和删除；JavaScript 只通过版本化 bridge 与受控 local scheme 使用临时 opaque asset ID，不接收 token、签名 URL、对象 key、用户 ID、真实路径或 base64 媒体。
- WebKit 使用非持久数据存储、严格 CSP 和外联/导航/弹窗/下载阻断。Web Storage 不保存业务数据；Release 不含 sourcemap且关闭 inspector。
- Reduce Motion、VoiceOver 偏好、WebGL 不可用、context lost、WebContent 终止、低电量、热压力或内存告警时停止并释放 renderer，显示 SwiftUI 静态图及原生上一/下一操作。
- 实施前必须通过原生 renderer 与 Three.js 的隔离 POC。验证包含安装包增量、冷启动、触摸到显示、hitch、App + WebContent + GPU 总内存、能耗、热状态、离线、零运行时外联、无障碍、删除和供应链；没有可测增量价值时不引入 Three.js。

完整边界见 [`../docs/design/01-技术选型.md`](../docs/design/01-技术选型.md)、[`../docs/design/08-动态预览设计.md`](../docs/design/08-动态预览设计.md) 与 [`../docs/design/11-OOTD权限隐私与安全设计.md`](../docs/design/11-OOTD权限隐私与安全设计.md)。当前仓库尚未进入 Three.js 实施切片，因此不创建 `package.json`、lockfile、bundle 或占位 renderer。

## Swagger/OpenAPI Client 生成

- 唯一契约是 `../backend/openapi.yaml`。
- `ThenApp/openapi.yaml` 是指向该契约的符号链接，用于让 Xcode 目标直接使用后端契约，不得替换成手工复制文件。
- `ThenApp/openapi-generator-config.yaml` 生成 Swift types 和 client。
- 生成源码由 Xcode Build Tool Plugin 放入 DerivedData，不提交、不手工修改。
- 当前配置已通过 Xcode Build Tool Plugin 实际生成并编译；版本、命令和结果记录在 [`../docs/acceptance/01-技术基线验收.md`](../docs/acceptance/01-技术基线验收.md)。

ThenApp target 已完成以下配置：

1. 使用 Exact requirement 添加 GRDB 7.11.1、`apple/swift-openapi-generator` 1.13.0、`apple/swift-openapi-runtime` 1.12.0 和 `apple/swift-openapi-urlsession` 1.3.1，并提交 `Package.resolved`。
2. 将 `OpenAPIGenerator` 加入 target 的 **Run Build Tool Plug-ins**。
3. 将 `ThenApp/openapi.yaml` 和 `ThenApp/openapi-generator-config.yaml` 都加入 ThenApp target 的 **Compile Sources**。不要再加入同一契约的 external file reference，否则插件会识别到多份文档。
4. 使用 `OpenAPIRuntime` 和 `OpenAPIURLSession` 创建底层 Client，再由手写 Service/Repository 封装鉴权、重试、错误映射和领域模型转换。

## 简体中文本地化

- OOTD 首发源语言固定为 `zh-Hans`。生产界面文案统一进入 `ThenApp/Localizable.xcstrings`，App 名称与系统权限用途说明统一进入 `ThenApp/InfoPlist.xcstrings`；两份目录都属于 ThenApp Resources。
- 不创建手写 `.strings` 或第二份字符串目录。SwiftUI 文案优先使用编译器可提取接口，普通字符串使用 `String(localized:)`，格式参数不得通过手工拼接改写。
- 当前字符串目录仍包含旧生活管理界面文案，只用于旧代码可构建。OOTD 页面落地时必须同步删除失效 key、加入照片与 AI 用途文案并重新建立本地化验收。
- OOTD 首版不声明英文或其他语言受支持；新增语言前必须完成独立翻译与真机验收。

每次 `backend/openapi.yaml` 变更后必须重新构建 iOS target。CI 中的 iOS 编译是客户端生成是否成功的强制检查。

## 构建与测试

- 工程：`ThenApp.xcodeproj`
- 共享 Scheme：`ThenApp`
- App target / Swift module：`ThenApp`
- 单元/集成测试 target：`ThenAppTests`
- UI 测试 target：`ThenAppUITests`
- 开发 Bundle ID：`com.stephenqiu.then`（正式签名启用前确认所有权）

在仓库根目录执行：

```bash
xcodebuild -resolvePackageDependencies \
  -project app/ThenApp.xcodeproj \
  -scheme ThenApp

xcodebuild -project app/ThenApp.xcodeproj \
  -scheme ThenApp \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation \
  clean build

xcodebuild -project app/ThenApp.xcodeproj \
  -scheme ThenApp \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -skipPackagePluginValidation \
  test
```

命令行首次运行 Package Plugin 时使用 `-skipPackagePluginValidation`；Xcode 图形界面中应确认并信任固定版本的插件。由于两份 YAML 必须成为 target 输入，Xcode 会输出 `no rule to process file` 警告；插件仍会正常生成并编译 Client/Types，禁止通过复制契约或提交生成源码消除该警告。

签名使用 Automatic，但仓库不提交 `DEVELOPMENT_TEAM`。模拟器构建无需 Team；真机与 Archive 前由维护者在本地选择正确 Apple Developer Team，并单独确认正式 Bundle ID 所有权。完整选型与排除项见 [`../docs/design/01-技术选型.md`](../docs/design/01-技术选型.md)。

## 历史生活管理实现参考（待迁移）

以下记录描述当前工作区中的旧生活管理实现，用于保护未提交代码和数据库升级夹具，不再是 OOTD 产品设计事实源。新功能必须遵循 [`../docs/design/01-技术选型.md`](../docs/design/01-技术选型.md) 与 03–12 号 OOTD 设计；完成数据保留决策后，旧 Feature、Data、Services、migration 和测试应在同一迁移中成组移除。

- 生产数据库位于 App 的 Application Support/ThenApp 目录，使用 `DatabasePool`、WAL、外键和 5 秒 busy timeout。
- 数据库目录、主文件、WAL 与 SHM 使用 `completeUntilFirstUserAuthentication` 文件保护，以兼顾锁屏后的主动行程恢复写入；生产和 Debug UI 测试路径每次打开都复用同一保护修复实现。
- 自动化记录器已证明数据库目录、主文件/WAL/SHM 和结构化导出目录/JSON 分别收到批准的保护操作；Simulator 不作为实际属性或锁屏语义证据，最低 iOS 18 真机验收仍是发布门槛。
- 所有 schema 只通过 `Data/Database/DatabaseMigrations.swift` 的有序 migration 演进，禁止 Feature 建表、启动时自动重建或 `eraseDatabaseOnSchemaChange`。
- 当前 `v1_create_local_ledger` 包含 LocalProfile、账务账户、交易与分录，`v2_create_calendar_cache` 集中加入日历来源、扫描、系列、实例和来源 revision，`v3_create_trip_planning` 加入地点快照、出行计划、路线快照、提醒状态、导航交接和本地事件关系，`v4_create_journey_recording` 只加入 Journey、TrackSegment 和临时 TrackPoint，`v5_create_life_links` 只加入用户确认的交易根—行程关系，`v6_relax_manual_location_coordinates` 兼容旧版地点三列非空约束，`v7_add_journey_expense_review_state` 追加 Journey 消费复盘三态，`v8_add_trip_plan_revision_review` 追加计划乐观版本、标题来源与 revision 解决时间约束。端侧 OCR 候选严格停留在记账表单会话，不建立候选或附件表。
- App 启动在一个 SQLite 事务内幂等创建唯一 LocalProfile、期初权益、未分类收入/支出、内置分类和默认现金账户。本币只采用系统地区建议，保持未确认状态，不得据此发布正式交易；确认后冷启动按 ready 状态复核内置账户并保留全部现有数据。
- `ConfirmBaseCurrencyUseCase` 原子确认本位币并解除初始账户的待配置状态；已确认币种不能在记账流程中静默变更。
- `LedgerPostingPlan` 使用纯领域类型构造支出、收入和同币种转账分录；`GRDBLedgerRepository` 是当前正式交易的唯一 SQLite 写入口，并在单事务中验证账户上下文后写入交易及全部分录。
- 手动支出、收入和转账界面使用稳定 transaction ID 防止重复点击产生重复数据；金额按币种小数位精确转换为 `Int64`，保存后从数据库重新读取最近账目和账户余额。
- 账户与分类管理支持现金、银行卡、电子钱包、信用卡、自定义收入/支出分类、一级父子分类以及可恢复归档；内部权益账户不出现在管理界面，归档数据不进入新交易选择器但继续参与历史余额。
- 当前 88 项 Swift Testing 与 16 项真实 XCUITest 在共享 Scheme 中 104/104 通过；只读诊断与关于已显示 App 名称、版本/构建号、单设备本地和诊断收集未启用，且缺失发布字段安全降级为“未知”。除账务、OCR、日历和出行计划外，已验证来源事件重扫不覆盖已确认计划、来源变化对比及保留/采用的原子版本语义、历史 v5 地点表、历史 v6 Journey 消费状态与历史 v7 计划来源字段无损升级、Journey 每设备唯一未收口状态、样本先落盘、新 segment 恢复、SHA-256 manifest、Today 自然日与局部降级、固定五 Tab、本地权限状态、行程列表过滤、canonical root 关联净额与消费复盘三态、账本月份切换/月报/本地搜索、六个月趋势补零、资金账户/分类/行程关系组合筛选、陈旧查询结果防覆盖、VoiceOver 货币全称、信用卡还款账户约束/正式转账/月报口径、结构化导出白名单、异常导出目录清扫、容量不足部分文件清理与普通写盘故障、日历缓存清理、Journey 删除、全量删除回滚、定位/提醒协调、scene phase 隐私遮罩策略、系统任务切换卡片无敏感正文、五 Tab/破坏性确认的真实 UI 取消路径、最大辅助字号深色模式、五个一级页面与快速记账的原生无障碍审计、票据隐私说明在标准和最大辅助字号下的完整可读与零裁切、无效测试存储参数闭合失败、结构化 JSON 系统分享取消后再次导出、快速支出到部分退款再到账本月报/搜索、信用卡还款、支出更正到完整撤销审计历史、纯文字地址计划、来源变化显式采用、Apple 地图失败后显式复制目的地且不误启动 Journey，以及 Journey 无消费确认、消费关联、解除、重关联和删除后账务保留的真实 UI 旅程。每个 XCUITest 使用独立 UUID 对应的真实 GRDB 文件目录，最新结果包为 `/tmp/then-p0-diagnostics-full.29ghCZ/Result.xcresult`。
- P0 简体中文基线现包含 457 个生产界面键与 5 个系统 Info.plist 键，两份目录都已编译进入 Release App 的 `zh-Hans.lproj`。共享 Scheme 在 `zh-Hans` 环境下 104/104 通过，日历完整访问前置说明专项另以 1/1 通过；最新结果分别为 `/tmp/then-p0-localization-tests.ssaANh/Result.xcresult` 与 `/tmp/then-p0-localization-permission-ui.xPEk59/Result.xcresult`，Release build/analyze/archive 位于 `/tmp/then-p0-localization-release.I7GGUy`。
- App target 已打包唯一根部 `PrivacyInfo.xcprivacy`，声明 P0 无追踪、无离机数据收集和 App 自有源码无 Required Reason API。运行 `../scripts/validate-ios-privacy.sh` 校验源文件、零生产日志与静态边界；传入构建后的 `ThenApp.app` 路径会递归枚举并逐份验证 App 与全部嵌入依赖的清单。
- P0 只使用系统 NavigationStack、sheet、List 与 TabView 转场，不实现自定义动画。运行 `../scripts/validate-ios-motion.sh` 阻断生产 SwiftUI、UIKit 和 Core Animation 动画入口；最终仍需在最低 iOS 18 真机开启“减少动态效果”完成核心旅程。
