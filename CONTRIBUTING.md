# 贡献指南

开始修改前阅读 [`AGENTS.md`](AGENTS.md)，并在同级 `then-server` 查阅对应 Design、PRD、已批准执行计划与 Acceptance。

提交标题使用 `type(scope): subject`，scope 必填；一个提交只包含一个可独立说明和回滚的变化。接口改动先提交到 `then-server/backend/openapi.yaml`，再在本仓库重新生成并编译 Client。

提交前至少运行：

```bash
xcodebuild -version
swift --version
xcodebuild -project ThenApp.xcodeproj -scheme ThenApp \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation build
```

涉及业务规则、本地 migration、媒体生命周期或 ViewModel 时运行相应 `ThenAppTests`；核心旅程变化增加并运行 XCUITest。测试结果以 xcresult 摘要为准，模拟器证据不替代真机、物理保护、性能或人工视觉验收。
