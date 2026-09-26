# 穿见视觉与交互设计标准

版本：2026-09-26。此文件是 Then Web 与 iOS 共同的视觉、组件状态和交互标准；两个仓库根目录文件必须字节一致。产品业务、隐私、数据和发布事实仍以对应 PRD、Design、Plan、Acceptance 为准。穿见是选定的用户可见品牌名；Then 保留为工程代号，原展示名“于是”只用于历史记录与尚未迁移的客户端。

## 设计方向

穿见采用克制的黑白界面：接近白色的页面、纯白内容表面、深墨色主要行动、细分隔线、清楚的文字层级与足够留白。设计参考用户提供的 `vercel-DESIGN.md` 中的视觉规律，将其转成穿搭决策产品的界面；不复制 Vercel 的品牌、营销导航、开发者术语、定价卡或产品插图。真实衣物、Look 与用户确认的记录是内容中心。

一屏只有一个主要行动。色彩优先留给真实衣物和受控媒体；链接用蓝色，错误用红色，状态同时用文字表达。多色网格渐变只可出现在 Web 首页的大面积背景，不能用于按钮、卡片、状态或 iOS 核心操作。无图片的页面保持完整功能，不用装饰图伪造衣物或生成结果。

## 品牌识别

用户选定的 Product Design 方案 3 使用“穿见”字标，宽屏可辅助标注 `CHUANJIAN`。图形由开口的门框、越过门槛的弧线和一个珊瑚色落点组成，表达“从真实衣橱走进今天的场景”。图形要保持完整，不旋转、不拉伸，也不拿来替代真实衣物或推荐结果。

Web 的透明主标识、小尺寸图标和深色方形应用图标分别位于 `frontend/public/brand/chuanjian-mark.png`、`frontend/public/brand/chuanjian-icon.png`、`frontend/public/brand/chuanjian-app-icon.png`。导航使用小尺寸图标加可读的“穿见”文字；浏览器图标使用小尺寸图标，添加到主屏幕时使用深色方形图标。图形中的珊瑚色 `#ff7f66` 仅作为品牌落点，不扩展为按钮、链接、状态或 shadcn 主题色。正式商标、域名及 iOS 用户可见名称／应用图标迁移须按各自验收确认，不能由 Web 预览推断完成。

## 色彩与表面

| 语义 | 浅色值 | 用途 |
| --- | --- | --- |
| 页面 canvas | `#fafafa` | Web body、iOS 主背景 |
| 内容 surface | `#ffffff` | 卡片、表单、弹层 |
| 嵌入 surface | `#f5f5f5` | 缩略图占位、局部弱化区域 |
| ink / primary | `#171717` | 标题、正文主色、主要按钮 |
| body | `#4d4d4d` | 次级正文 |
| muted | `#666666` | 仍需阅读的说明；占位符可用 `#888888` |
| hairline | `#ebebeb` | 列表与卡片边界 |
| input edge | `#a1a1a1` | 输入与可操作控件边界 |
| link / focus | `#0070f3` | 文内链接、2px 键盘焦点；不代替主要按钮 |
| destructive | `#c50000` | 错误、删除及危险确认 |
| on-primary | `#ffffff` | 深色主要行动上的文字 |

Web 将以上值集中映射到现有 `src/app/globals.css` 的 shadcn 语义 token；iOS 使用共同的 `ThenPalette`/资产映射。功能页面不写独立品牌色。默认浅色；暗色必须在同一语义体系有完整设计与对比度验收后才能启用。增强对比度和 Dynamic Type/文字放大不得丢失重要状态。

表面层级为 canvas → surface → inset → 深色重点区域。卡片优先使用 1px hairline 和紧凑的多层轻阴影；不要大面积单层投影或嵌套卡片。圆角：输入/操作控件 6px，内容卡 8–12px，营销级行动 pill；同一页面的同类控件保持一致。iOS 的系统弹层可沿用平台外形，但自有内容遵守上述层级。

## 字体与排版

Web 使用 Vercel 发布的 OFL 授权 Geist Sans，技术编号/代码才使用 Geist Mono；中文由系统 CJK 字体回退。iOS 在可用时使用同一授权字体资源，中文与系统控件可回退系统字体，保留 Dynamic Type 缩放。不得只把 `Geist` 写进 CSS 而不加载字体。

| 层级 | Web 基准 | 字重 | 用途 |
| --- | --- | --- | --- |
| Hero | 48px / 1.05，窄屏缩至 32px | 600 | 首页主标题 |
| 页面标题 | 32px / 1.2，窄屏 28px | 600 | 业务页标题 |
| 区块标题 | 24px / 1.33 | 600 | 主内容区 |
| 正文 | 16px / 1.5 | 400 | 表单、列表、说明 |
| 次要文字 | 14px / 1.43 | 400 | 元信息、辅助说明 |
| 按钮 | 14–16px / 1.4 | 500 | 操作 |
| 技术标签 | 12px / 1.33 | 400 Mono | ID、版本、技术性时间信息；不用于叙事正文 |

标题用自然大小写和适度负字距，不全大写；显示字体不超过 600 字重。中文文案保持明确、简短，不为了模仿英文品牌文案添加句号或技术术语。字号与间距使用 rem/系统相对字号承接缩放，不固定整行高度。

## 布局与组件

以 4px 为间距基础：8、12、16、24、32、48、64px 是常用节奏。小屏两侧至少 16px，桌面至少 24px；业务内容限制可读宽度，首页的营销背景可铺满但文字内容仍居中。宽屏双栏在约 900px 才启用，移动端单栏，不用隐藏横向溢出来掩盖错误。

Web 基础组件使用已固定的 shadcn/ui `radix-nova` + Radix Primitives + Tailwind v4。先用现有 `variant`/`size`，必要的品牌变化写回 `components/ui`，页面只管布局；交互与无障碍由 Radix 管理。表单使用 `Field`，危险确认用 `AlertDialog`。短暂完成反馈用全局 Sonner；字段错误就地显示，持续失败与可恢复操作用 Alert，删除回执保持在页面上。`Tabs` 只用于同一路径内互斥内容面板，必须包含 `TabsList`/`TabsTrigger`/`TabsContent` 并检查方向键、Home/End 与焦点。跨 URL 入口仍为链接。

iOS 使用 SwiftUI 原生导航、表单、Picker、系统权限和进度控制；自有卡片、按钮、背景、提示与字体映射共同 token。系统语义与 VoiceOver 优先于复制 Web 的 DOM 形状；不要在 iOS 引入 Web 组件或 Sonner。短暂提示不能承载唯一的错误恢复入口，后台/锁屏时继续隐藏敏感内容。

## 状态、可访问性与验收

每页需有正常、空态、首次加载、刷新、提交中、成功、可恢复失败、未认证及适用的删除状态。成功只在服务端/本地事务已确认后出现；计划、实际穿着、照片和推荐不能互相推断成功事实。失败保留草稿与重试上下文。未确认的照片或真实衣物不得进入装饰性展示。

操作命中区至少 44×44px。键盘/VoiceOver 应读出名称、状态、错误关联和可执行动作；焦点完整可见。状态不只靠颜色；正文、边界、焦点需在浅色表面有足够对比。减少动态效果时关闭非必要转场。Web 检查 320/390、768/834、1024/1440px 与 200% 字号，iOS 检查标准/最大辅助字号、浅色/提高对比度、VoiceOver 和 Reduce Motion。构建、自动扫描、模拟器与真实设备分别记录证据，不相互替代。

## 来源与使用边界

- 视觉参考：用户提供的 `/Users/stephenqiu/Desktop/Markdown/Typora/常用的设计文件/vercel-DESIGN.md`，用于配色、排版、表面与间距；它的品牌叙述和示例流程不是 Then 产品需求。
- 字体：[Vercel Geist](https://vercel.com/font)，按 OFL 授权使用。
- Web 组件：[shadcn Sonner](https://ui.shadcn.com/docs/components/radix/sonner)、[shadcn Tabs](https://ui.shadcn.com/docs/components/radix/tabs)、[Radix Tabs](https://www.radix-ui.com/primitives/docs/components/tabs)。
