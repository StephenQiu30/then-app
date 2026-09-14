# iOS

2026-09-13 当前交付顺序为 Woo 式本人照片与真实衣物生成流程优先，同时保留真实 3D 模型、角色编辑与换装交互；两者分别验收。具体范围见 [PRD 10](../docs/prd/10-OOTD产品需求.md#2026-09-13当前交付目标)，不能以照片结果或 360 视频抵扣实际三维能力。

## OpenAPI请求代码生成

维护顺序为 `backend/openapi.yaml → Swagger UI 展示 / Swift OpenAPI Generator → Types.swift + Client.swift`。Swagger 页面用于阅读，生成器读取 YAML；不从网页 HTML、注解或第二份接口清单生成。

在仓库根目录直接运行 Xcode 构建。ThenTransport 的 Build Tool Plugin 会从唯一 YAML 契约生成并编译 Client；不要求 Docker、Swagger 页面或后端运行。测试必须显式指定模拟器并使用 `-resultBundlePath` 保存独立结果包。Xcode 返回成功后，再用 `xcrun xcresulttool get test-results summary --path <结果包路径>` 核对顶层注册数、通过数、失败、跳过与预期失败；筛选运行只能证明所选范围，物理能力仍单独验收。

生成文件位于 Xcode DerivedData，只供构建使用，不加入源码或 target。正式 App 构建由 ThenTransport target 中的 Build Tool Plugin 从 `ThenApp/openapi.yaml` 符号链接自动生成，使用同一个配置。以后修改契约再构建即可更新，不手写 transport DTO。服务适配器使用生成 Client 并配置实际后端地址，View 通过精确依赖调用服务。

新环境由 Xcode 解析锁定的 Swift Package 依赖并构建生成器插件；生成器不可用时构建直接失败。2026-09-13 用户确认 ThenTransport 技术模块例外后，生成 Client 已改在默认 nonisolated 模块编译，实际 App Debug/Release Simulator 构建通过。生成成功与运行验收仍分别记录，当前证据归 [17-01](../docs/plan/17-01-后端服务启动与健康契约执行计划.md)。当前文档入口由 Go API 内嵌提供，启动见 [后端 README](../backend/README.md#swagger接口文档)；步骤、范围与证据见 [17-09](../docs/plan/17-09-后端内嵌接口文档执行计划.md)。

本地 3D 实现前先读 [角色开发与交付 SOP](../docs/design/04-数字形象与照片采集设计.md#本地三维角色开发与交付sop)、[服装资产交付 SOP](../docs/design/05-数字衣橱与衣物录入设计.md#三维服装资产交付sop) 与 [当前准备审核](../docs/acceptance/10-OOTD产品系统验收.md#2026-09-12三维实施准备审核)。App 已切换为三个 OOTD 原生入口；旧数据保留门禁已由用户开发阶段决定解除，新角色 UI 仍须资产和渲染 POC。

“于是”OOTD 客户端固定使用 Xcode 26.6、Swift 6.3.3 和 SwiftUI，最低支持 iOS 26。App 显示名暂时保留“于是”，内部 Xcode target 和 Swift module 保留 `ThenApp`。

实现原则：

- 所有产品页面使用 SwiftUI，Observation + `@Observable` 管理界面状态。
- UIKit 只封装缺少 SwiftUI 接口的系统控制器，以及已批准的局部 WebKit 图形渲染表面；不承担页面导航、全局状态或业务架构。
- Swift 6 language mode、Complete Strict Concurrency、Approachable Concurrency，UI 默认 Main Actor 隔离。
- 首版保留一个业务 `ThenApp` Swift module；唯一技术模块例外 `ThenTransport` 只编译生成的 public Types/Client，默认 nonisolated，Swift 6 Complete Strict Concurrency。另有 `ThenAppTests` 与 `ThenAppUITests`，不把 Feature 拆成内部 framework 或 Swift Package。
- 采用 feature-first + MVVM + Repository。
- PhotosUI、AVFoundation、Vision、UserNotifications 和网络能力通过服务协议封装。
- 本地数据固定使用 GRDB 7.11.1 + 系统 SQLite 的 DatabasePool/WAL；衣橱、基础推荐和穿搭记录离线可用。
- API 客户端从 `../backend/openapi.yaml` 生成；AI 试穿与动态预览是可失败、可取消的异步增强。
- 禁止 SwiftData、Core Data、Realm、RxSwift、Combine 全局状态、第三方页面/UI 架构和第三方 DI 容器。Three.js 只能作为下述受控 renderer，不属于页面架构例外。

当前工程已经满足 SwiftUI App 入口、Observation、Swift 6 严格并发、GRDB 与 OpenAPI 精确锁版。用户确认旧开发数据无需保留，19-02 已成组移除旧 Feature/Data/Services、migration 与对应测试；当前无旧业务启动副作用，12-01 已启用正式 OOTD 衣物持久化及可恢复异步启动。

无图衣橱支持从今日/衣橱添加、七类分类、四种可用状态、名称搜索、编辑及单件确认删除。只保存用户确认事实；数据库位于 Application Support/OOTD/wardrobe.sqlite，使用完整文件保护、WAL 与 ootd_v1_wardrobe migration，不读旧生活管理库。保存失败保留草稿，过期编辑不覆盖新版本；删除清理失败可重试。完整业务/测试状态见 [12-01](../docs/plan/12-01-无图衣橱与数据库基础执行计划.md)，不把模拟器结果视为真机保护或本地 GA 验收。

12-03 DATA-01 已追加 `ootd_v2_wardrobe_photos` 和 `ootd_v3_unattached_photo_imports`：受保护规范化图/缩略图、替换、删除与重启恢复由同一个 Repository actor 管理。v3 修复新增衣物与照片分开保存留下半成品的问题，同一最终事务发布衣物字段和照片 ready；真实 v2 数据升级保持现有衣物/媒体。存储不负责人物/质量判断。源码、迁移、故障恢复证据见 [12-03](../docs/plan/12-03-单件图片导入与媒体生命周期执行计划.md#原生照片编辑与完整回归检查点)。

12-03 IMAGE-01 已实现独立衣物编码器：显式预算、实际格式/帧数校验、方向/sRGB 规范化与缩略图；输出仍须单件规则和用户复核。已有编码 12 项、文件导入 8 项、系统交接 12 项、复核 8 项、CPU 分析 5 项子集通过证据；人物净化仅共用 PixelOnlyPNG 元数据清理，保持独立会话和目的。

按用户要求继续模拟器开发，原生编辑页已接系统 PhotosPicker、可见预览、单件复核、原子保存与独立确认移除。实际合成衬衫旅程通过保存→重启显示→后台遮罩→移除→重启不复活。当前 512px/CPU 是明确的开发组合；完整身体部位/多人/遮挡/多件安全矩阵、正式图像预算与真机验收仍待完成；Woo 分类网格已接入真实缩略图，已通过本轮模拟器自动回归，继续补齐完整验收，不能将当前页面当作最终 Woo/AI 试穿交付。

此前完整单元 160 注册、156 通过、2 前景诊断失败、2 物理保护跳过。两次原前景方法的失败分别为默认 Vision Code 9 与 CPU unsupportedCPUStage；人物/面部计数通过不证明默认设备选择稳定。完整 UI 首轮发现的两项无障碍布局失败已修复，最终 9 项 UI 全部通过，证据归 [acceptance 12](../docs/acceptance/12-数字衣橱与衣物录入验收.md#2026-09-13模拟器照片编辑验收)，不选择性宣称全绿。

此前已修复读取媒体抛错后丢失删除目标的缺陷：有效照片记录先于字节读取保存，失败清空旧图片缓存，移除/清理可重试。相关数据回归 24 通过、1 物理跳过；编辑与扩展系统选图旅程 8 项通过，覆盖换图重新复核、人物拒绝及取消后原图保留。2026-09-14 已补齐不同像素替换：15 项检测/编辑测试与 1 条系统 UI 旅程通过，取消后蓝图保留、保存后重启恢复红图、移除不复活；完整安全矩阵仍待验，详细证据见 acceptance 12 当前检查点。

照片 XCUITest 仅运行于名称以 `ThenWardrobePhotoUI` 开头的专用模拟器。新建并启动空白设备后，使用 `xcrun simctl addmedia <专用UDID> app/ThenAppTests/Resources/<测试图片>` 逐张导入项目自有合成图，并实际核对图库顺序与截图；不要在含私人照片的设备上运行。普通模拟器会跳过此用例，不等于照片旅程通过。原图只在测试资源与专用图库中，生产 App 不预置衣物或夹具。

2026-09-14 图片内容门禁新增失败证据：只有成人手/前臂的合成衣物图，现有人物/面部分析返回 0，仍依赖人工确认；独立手部请求的尺寸/设备四组对照也返回 0，未接入生产。相关测试 7 注册、5 通过/2 失败，不能据原有完整成人样本通过宣称身体部位安全。详见 [12-03 当前检查点](../docs/plan/12-03-单件图片导入与媒体生命周期执行计划.md)；原有换图/保存/删除开发流程不变，完整图片发布门禁尚未关闭。

## 穿搭计划与分类选衣

已批准的 16-01 使用本地真实衣物保存今日或未来计划，支持日期回看、编辑、取消及永久删除。衣物快照和原始时区独立保存；彻底删除衣物时按明确选择清空历史单品信息或删除相关计划，照片替换不会用新图冒充历史图。

2026-09-14 已修复计划删除冲突后一直使用旧版本的问题：刷新查看最新内容并重新确认后可以删除；响应丢失和已提交清理重试继续使用原幂等命令。相关 22 项状态/数据库/UI 回归通过，范围及重跑命令见 [删除冲突验收](../docs/acceptance/16-穿搭记录与反馈验收.md#2026-09-14删除冲突恢复验收)。

选衣页按类别分组展示网格，过滤不会清空已选项。标准字号显示顶部已选区与逐件移除；最大辅助字号使用单列和页内已选区。当前保存的是计划，Woo 的 AI 结果、真实三维及完整视觉复现仍分别待实现。测试步骤、失败记录与当前状态见 [16-01 执行计划](../docs/plan/16-01-穿搭计划与时间线执行计划.md) 和 [acceptance 16](../docs/acceptance/16-穿搭记录与反馈验收.md)，不能将已实现交互等同于完整无障碍或发布验收。

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
- 2026-09-13 将生成代码移到 ThenTransport 的正确并发隔离边界，App 保持 MainActor；当前构建与测试证据见 [17-01](../docs/plan/17-01-后端服务启动与健康契约执行计划.md)。

工程配置：

1. 使用 Exact requirement 添加 GRDB 7.11.1、`apple/swift-openapi-generator` 1.13.0、`apple/swift-openapi-runtime` 1.12.0 和 `apple/swift-openapi-urlsession` 1.3.1，并提交 `Package.resolved`。
2. 将 `OpenAPIGenerator` 只加入 ThenTransport target 的 **Run Build Tool Plug-ins**。
3. 将 `ThenApp/openapi.yaml` 和 `ThenApp/openapi-generator-config.yaml` 只加入 ThenTransport target 的 **Compile Sources**；配置使用 `accessModifier: public`。不要再加入同一契约的 external file reference，否则插件会识别到多份文档。
4. ThenTransport 静态 framework 链接 OpenAPIRuntime，ThenApp 链接 ThenTransport 并保留 OpenAPIURLSession；业务服务后续通过 `import ThenTransport` 使用生成 Client。测试 target 显式链接生成模块、OpenAPIRuntime 与已锁定 HTTPTypes。当前没有自动健康请求或云账号/上传入口。

## 简体中文本地化

- OOTD 首发源语言固定为 `zh-Hans`。生产界面文案统一进入 `ThenApp/Localizable.xcstrings`，App 名称与系统权限用途说明统一进入 `ThenApp/InfoPlist.xcstrings`；两份目录都属于 ThenApp Resources。
- 不创建手写 `.strings` 或第二份字符串目录。SwiftUI 文案优先使用编译器可提取接口，普通字符串使用 `String(localized:)`，格式参数不得通过手工拼接改写。
- 19-02 已移除旧业务文案和权限说明；新功能按需补充 String Catalog 与用途说明，不预申请照片/云端权限。
- OOTD 首版不声明英文或其他语言受支持；新增语言前必须完成独立翻译与真机验收。

每次 `backend/openapi.yaml` 变更后必须重新构建 iOS target。CI 中的 iOS 编译是客户端生成是否成功的强制检查。

## 构建与测试

构建与测试直接使用 `xcodebuild`。测试显式指定实际模拟器 UDID 和独立 `-resultBundlePath`；完成后用 `xcresulttool` 核对结果摘要。2026-09-13 实际 Debug/Release 构建通过；工程配置通过逐 target 编译检查 MainActor/nonisolated、插件和输入唯一归属及静态链接。具体边界见 [Design 01](../docs/design/01-技术选型.md#2026-09-12生成client编译兼容评估)，App 构建通过不代表 OOTD 发布验收完成。

- 工程：`ThenApp.xcodeproj`
- 共享 Scheme：`ThenApp`
- App target / Swift module：`ThenApp`
- 生成 API 静态 framework / Swift module：`ThenTransport`（没有手写生产源码）
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

命令行首次运行 Package Plugin 时使用 `-skipPackagePluginValidation`；Xcode 图形界面中应确认并信任固定版本的插件。由于两份 YAML 必须成为 target 输入，Xcode 会输出 `no rule to process file` 警告；该资源警告与当前生成 Client 的 actor 隔离编译错误分别处理；禁止通过复制契约或提交生成源码消除警告或绕过编译错误。

签名使用 Automatic，但仓库不提交 `DEVELOPMENT_TEAM`。模拟器构建无需 Team；真机与 Archive 前由维护者在本地选择正确 Apple Developer Team，并单独确认正式 Bundle ID 所有权。完整选型与排除项见 [`../docs/design/01-技术选型.md`](../docs/design/01-技术选型.md)。

## 历史实现

旧生活管理源码、测试与说明已随 19-02 成组退役；历史可从 [原开发基线](https://github.com/StephenQiu30/then/tree/2bc97280796791fa3d20b6407e01b7a8e403b0fa/app) 查看，不再描述为当前 App 行为。

衣橱浏览已改为 SwiftUI 分类网格：常规字号自适应四列、辅助字号单列，保留搜索/类别/状态筛选与原生编辑入口。图片按完整比例显示，未添加或不可读取时显示中性占位；缩略图按 revision 更新，退出/后台清空且拒绝迟到结果，无新增媒体缓存目录或数据库迁移。当前证据与未完成项见 [分类网格验收](../docs/acceptance/12-数字衣橱与衣物录入验收.md#2026-09-13分类网格验收)。

分类网格最终回归：10 项编辑/缩略图 + 11 项 UI，共 21 注册测试通过、无失败或跳过；常规四列、最大辅助字号单列、真实照片缩略图与后台遮罩截图均已检查。此前完整单元的 Vision/物理保护未通过项仍保留，不能把本轮子集写为整个项目全绿。

本轮直接执行的 Xcode Debug/Release 构建通过，Release 未包含照片测试素材；结果为本地模拟器证据，物理发布门禁仍待后续验收。


## 本地穿搭计划开发检查点

16-01 已接今日与穿搭簿的新建入口、真实衣物多选、今天/未来日期、原始时区、快照回看、编辑、取消与永久删除。追加 `ootd_v4_outfit_plans`，继续同一 OOTD 数据库；已有衣物/照片不重置。彻底删除衣物明确选择清除单品历史信息或同时删除关联计划，并在事务中复核影响。

保存计划不产生实际穿着或学习反馈，也不启动云请求。历史缩略图与原有效资产绑定，照片替换/删除不会改成新的图片。计划弹窗有独立后台隐私遮罩。代码/测试/无障碍待办以 [16-01 spec/checklist](../docs/plan/16-01-穿搭计划与时间线执行计划.md) 和 [验收 16](../docs/acceptance/16-穿搭记录与反馈验收.md) 为准；开发实现不等于完整发布验收。
