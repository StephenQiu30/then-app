import XCTest

final class ThenAppUITests: XCTestCase {
  private var uiTestStorageID = ""

  override func setUpWithError() throws {
    continueAfterFailure = false
    uiTestStorageID = UUID().uuidString
  }

  @MainActor
  func testInvalidUITestingStorageIDFailsClosed() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--then-ui-testing-storage-id=not-a-uuid"]
    app.launch()

    XCTAssertTrue(app.staticTexts["无法打开本地数据"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["于是没有重建或删除现有数据。请重新启动 App 后再试。"].exists
    )
    XCTAssertFalse(app.tabBars.firstMatch.exists)
    XCTAssertFalse(app.buttons["记一笔"].exists)
    keepScreenshot(of: app, named: "无效测试存储参数闭合失败")
  }

  @MainActor
  func testRootNavigationAndDestructiveConfirmationsCanBeCancelled() throws {
    let app = makeApp()
    app.launch()

    let tabBar = app.tabBars.firstMatch
    XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

    let destinations = [
      (tab: "今天", navigationTitle: "今天"),
      (tab: "账本", navigationTitle: "账本"),
      (tab: "日程", navigationTitle: "日程"),
      (tab: "行程", navigationTitle: "出行计划"),
      (tab: "我的", navigationTitle: "我的"),
    ]
    for destination in destinations {
      let tab = tabBar.buttons[destination.tab]
      XCTAssertTrue(tab.exists, "缺少 \(destination.tab) Tab")
      tab.tap()
      XCTAssertTrue(
        app.navigationBars[destination.navigationTitle].waitForExistence(timeout: 2),
        "无法打开 \(destination.tab)"
      )
    }

    let localMode = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "单设备本地"))
      .firstMatch
    XCTAssertTrue(localMode.waitForExistence(timeout: 2))
    XCTAssertFalse(app.buttons["登录"].exists)
    XCTAssertFalse(app.buttons["云备份"].exists)

    let clearCalendar = app.buttons["清理日历缓存"]
    scrollToHittable(clearCalendar, in: app)
    clearCalendar.tap()
    XCTAssertTrue(app.buttons["清理缓存"].waitForExistence(timeout: 2))
    XCTAssertTrue(
      app.staticTexts[
        "将删除本地日历来源和事件快照，但保留已确认的计划、提醒、行程和账务；系统日历原始事件不会改变。"
      ].exists
    )
    app.swipeDown()
    XCTAssertTrue(app.buttons["清理缓存"].waitForNonExistence(timeout: 2))

    let resetLocalData = app.buttons["删除本机全部数据"]
    scrollToHittable(resetLocalData, in: app)
    resetLocalData.tap()
    let resetAlert = app.alerts["删除本机全部数据？"]
    XCTAssertTrue(resetAlert.waitForExistence(timeout: 2))
    XCTAssertTrue(resetAlert.buttons["永久删除"].exists)
    XCTAssertTrue(
      resetAlert.staticTexts[
        "账务、日历缓存、计划、行程和关系都会被删除；操作成功后会创建新的空本地资料，且无法撤销。"
      ].exists
    )
    resetAlert.buttons["取消"].tap()
    XCTAssertTrue(resetAlert.waitForNonExistence(timeout: 2))
    for _ in 0..<4 where !localMode.exists {
      app.swipeDown()
    }
    XCTAssertTrue(localMode.waitForExistence(timeout: 2))
    let diagnosticsDisabled = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "诊断收集"))
      .matching(NSPredicate(format: "label CONTAINS %@", "未启用"))
      .firstMatch
    scrollToHittable(diagnosticsDisabled, in: app)
    XCTAssertTrue(diagnosticsDisabled.isHittable)
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@", "0.1.0 (1)"))
        .firstMatch.exists
    )
    let diagnosticsNotice = app.staticTexts[
      "P0 不生成或导出日志、崩溃报告、分析事件或诊断包。反馈问题时只需说明版本号，不要附带账务、日历或位置正文。"
    ]
    scrollToFullyVisible(diagnosticsNotice, in: app)
    XCTAssertTrue(diagnosticsNotice.isHittable)
    try app.performAccessibilityAudit(for: requiredAccessibilityAuditTypes)
    try app.performAccessibilityAudit(for: .textClipped)
    keepScreenshot(of: app, named: "五个入口与诊断关于")
  }

  @MainActor
  func testSimplifiedChineseCalendarPermissionPreludeIsComplete() throws {
    let app = makeApp()
    app.launch()

    let tabBar = app.tabBars.firstMatch
    XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    tabBar.buttons["日程"].tap()
    XCTAssertTrue(app.navigationBars["日程"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["连接系统日历"].waitForExistence(timeout: 2))
    XCTAssertTrue(
      app.staticTexts[
        "于是会请求 iOS 的日历完整访问，但只读取你随后明确选择的日历、时间、标题和地点。"
      ].exists
    )
    XCTAssertTrue(app.buttons["继续并请求访问"].exists)
    keepScreenshot(of: app, named: "简体中文日历权限前置说明")
  }

  @MainActor
  func testAllDayCalendarEventCreatesConfirmedLocalTripPlan() throws {
    let app = makeApp()
    app.launchArguments.append("--then-ui-testing-calendar-trip=all-day")
    app.launch()

    let tabBar = app.tabBars.firstMatch
    XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    tabBar.buttons["日程"].tap()
    XCTAssertTrue(app.navigationBars["日程"].waitForExistence(timeout: 2))

    let calendarToggle = app.switches.matching(
      NSPredicate(format: "label CONTAINS %@", "自动化日历")
    ).firstMatch
    XCTAssertTrue(calendarToggle.waitForExistence(timeout: 5))
    XCTAssertEqual(calendarToggle.value as? String, "0")
    calendarToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    let selectedExpectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "1"),
      object: calendarToggle
    )
    XCTAssertEqual(XCTWaiter.wait(for: [selectedExpectation], timeout: 3), .completed)

    let refresh = app.buttons["更新日程"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 2))
    XCTAssertTrue(refresh.isEnabled)
    refresh.tap()

    XCTAssertTrue(app.staticTexts["自动化全天会议"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["自动化会场"].exists)
    let createPlan = app.buttons["创建出行计划"].firstMatch
    XCTAssertTrue(createPlan.exists)
    createPlan.tap()

    XCTAssertTrue(app.navigationBars["出行计划"].waitForExistence(timeout: 2))
    XCTAssertEqual(app.textFields["计划名称（可选）"].value as? String, "自动化全天会议")
    XCTAssertEqual(app.textFields["输入目的地或地址"].value as? String, "自动化会场")
    let save = app.buttons["保存"]
    XCTAssertFalse(save.isEnabled)

    app.buttons["搜索不到，使用当前文字地址"].tap()
    XCTAssertFalse(save.isEnabled)
    let confirmTime = app.buttons["确认具体到达时间"]
    XCTAssertTrue(confirmTime.exists)
    confirmTime.tap()
    XCTAssertTrue(confirmTime.waitForNonExistence(timeout: 2))
    XCTAssertTrue(save.isEnabled)
    save.tap()

    XCTAssertTrue(app.navigationBars["日程"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["自动化全天会议"].exists)
    app.buttons["出行计划"].tap()
    XCTAssertTrue(app.navigationBars["出行计划"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["自动化全天会议"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["未启用提醒"].exists)
    keepScreenshot(of: app, named: "全天日历事件创建本地出行计划")
  }

  @MainActor
  func testCalendarSourceChangeCanBeReviewedAndAdoptedIntoPlan() throws {
    let app = makeApp()
    app.launchArguments.append("--then-ui-testing-calendar-trip=revision")
    app.launch()

    let tabBar = app.tabBars.firstMatch
    XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    tabBar.buttons["日程"].tap()
    let calendarToggle = app.switches.matching(
      NSPredicate(format: "label CONTAINS %@", "自动化日历")
    ).firstMatch
    XCTAssertTrue(calendarToggle.waitForExistence(timeout: 5))
    calendarToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()

    let refresh = app.buttons["更新日程"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 3))
    refresh.tap()
    XCTAssertTrue(app.staticTexts["自动化会议"].waitForExistence(timeout: 5))
    app.buttons["创建出行计划"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["出行计划"].waitForExistence(timeout: 2))
    app.buttons["搜索不到，使用当前文字地址"].tap()
    let save = app.buttons["保存"]
    XCTAssertTrue(save.isEnabled)
    save.tap()

    XCTAssertTrue(app.staticTexts["已关联出行计划"].waitForExistence(timeout: 5))
    refresh.tap()
    XCTAssertTrue(app.staticTexts["自动化改期会议"].waitForExistence(timeout: 5))
    let review = app.buttons["查看来源变化"]
    XCTAssertTrue(review.waitForExistence(timeout: 3))
    review.tap()

    XCTAssertTrue(app.navigationBars["来源变化"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["原值：自动化会议"].exists)
    XCTAssertTrue(app.staticTexts["新值：自动化改期会议"].exists)
    XCTAssertTrue(app.staticTexts["新值：自动化新会场"].exists)
    let adopt = app.buttons["采用到计划"]
    XCTAssertTrue(adopt.isEnabled)
    keepScreenshot(of: app, named: "日历来源变化对比与处置")
    adopt.tap()

    XCTAssertTrue(app.navigationBars["确认来源变化"].waitForExistence(timeout: 2))
    XCTAssertEqual(app.textFields["计划名称（可选）"].value as? String, "自动化改期会议")
    XCTAssertEqual(app.textFields["输入目的地或地址"].value as? String, "自动化新会场")
    let confirmAdopt = app.buttons["采用"]
    XCTAssertFalse(confirmAdopt.isEnabled)
    app.buttons["搜索不到，使用当前文字地址"].tap()
    XCTAssertTrue(confirmAdopt.isEnabled)
    confirmAdopt.tap()

    XCTAssertTrue(app.navigationBars["日程"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["自动化改期会议"].exists)
    XCTAssertTrue(app.staticTexts["已关联出行计划"].exists)
    XCTAssertTrue(app.buttons["查看来源变化"].waitForNonExistence(timeout: 5))
    tabBar.buttons["行程"].tap()
    XCTAssertTrue(app.staticTexts["自动化改期会议"].waitForExistence(timeout: 5))
    keepScreenshot(of: app, named: "采用来源变化后的出行计划")
    let adoptedDestination = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "自动化新会场")
    ).firstMatch
    XCTAssertTrue(adoptedDestination.exists)
  }

  @MainActor
  func testProfileRemainsReachableAtLargestDynamicTypeInDarkAppearance() throws {
    let app = makeApp()
    app.launchArguments += [
      "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXXXL",
      "-AppleInterfaceStyle",
      "Dark",
    ]
    app.launch()

    let tabBar = app.tabBars.firstMatch
    XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    let destinations = [
      (tab: "今天", navigationTitle: "今天"),
      (tab: "账本", navigationTitle: "账本"),
      (tab: "日程", navigationTitle: "日程"),
      (tab: "行程", navigationTitle: "出行计划"),
      (tab: "我的", navigationTitle: "我的"),
    ]
    for destination in destinations {
      let tab = tabBar.buttons[destination.tab]
      XCTAssertTrue(tab.exists, "最大字号下缺少 \(destination.tab) Tab")
      tab.tap()
      XCTAssertTrue(
        app.navigationBars[destination.navigationTitle].waitForExistence(timeout: 2)
      )
      try auditKnownDynamicTypeToolIssues(in: app, page: destination.tab)
    }

    let localMode = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "单设备本地"))
      .firstMatch
    XCTAssertTrue(localMode.waitForExistence(timeout: 2))
    let resetLocalData = app.buttons["删除本机全部数据"]
    scrollToHittable(resetLocalData, in: app)
    XCTAssertTrue(resetLocalData.isHittable)
    let diagnosticsNotice = app.staticTexts[
      "P0 不生成或导出日志、崩溃报告、分析事件或诊断包。反馈问题时只需说明版本号，不要附带账务、日历或位置正文。"
    ]
    scrollToFullyVisible(diagnosticsNotice, in: app)
    XCTAssertTrue(diagnosticsNotice.isHittable)
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@", "0.1.0 (1)"))
        .firstMatch.exists
    )
    keepScreenshot(of: app, named: "最大字号深色模式诊断与关于")

    let todayTab = tabBar.buttons["今天"]
    if !todayTab.exists {
      let collapsedProfileTab = tabBar.buttons["我的"]
      XCTAssertTrue(collapsedProfileTab.exists)
      XCTAssertEqual(collapsedProfileTab.value as? String, "已折叠")
      collapsedProfileTab.tap()
    }
    XCTAssertTrue(todayTab.waitForExistence(timeout: 2))
    todayTab.tap()
    XCTAssertTrue(app.navigationBars["今天"].waitForExistence(timeout: 2))
    app.buttons["记一笔"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["记一笔"].waitForExistence(timeout: 2))
    try auditKnownDynamicTypeToolIssues(in: app, page: "快捷记账")
    keepScreenshot(of: app, named: "最大字号深色模式快捷记账")
  }

  @MainActor
  func testReceiptPrivacyNoticePrecedesImageActionsAtSupportedTextSizes() throws {
    let app = makeApp()
    let configurations: [(name: String, arguments: [String])] = [
      ("标准字号", []),
      (
        "最大辅助字号深色模式",
        [
          "-UIPreferredContentSizeCategoryName",
          "UICTContentSizeCategoryAccessibilityXXXL",
          "-AppleInterfaceStyle",
          "Dark",
        ]
      ),
    ]

    for configuration in configurations {
      app.terminate()
      app.launchArguments = [uiTestStorageArgument] + configuration.arguments
      app.launch()

      let quickEntry = app.buttons["记一笔"].firstMatch
      XCTAssertTrue(quickEntry.waitForExistence(timeout: 5))
      quickEntry.tap()
      XCTAssertTrue(app.navigationBars["记一笔"].waitForExistence(timeout: 2))

      let privacyNotice = app.staticTexts["票据图片仅用于本机本次识别，不保存或上传。"]
      scrollToFullyVisible(privacyNotice, in: app)
      XCTAssertEqual(privacyNotice.label, "票据图片仅用于本机本次识别，不保存或上传。")
      XCTAssertGreaterThan(privacyNotice.frame.height, 0)

      let selectPhoto = app.buttons["选择票据照片"]
      let takePhoto = app.buttons["拍摄票据"]
      try app.performAccessibilityAudit(for: .textClipped)
      keepScreenshot(of: app, named: "\(configuration.name)票据隐私说明")

      if selectPhoto.exists {
        XCTAssertLessThanOrEqual(privacyNotice.frame.maxY, selectPhoto.frame.minY)
      } else {
        XCTAssertFalse(takePhoto.exists)
      }
      scrollToHittable(selectPhoto, in: app)
      scrollToHittable(takePhoto, in: app)
      if selectPhoto.exists {
        XCTAssertLessThan(selectPhoto.frame.minY, takePhoto.frame.minY)
      }
    }
  }

  @MainActor
  func testPrimaryScreensPassNativeAccessibilityAudit() throws {
    let app = makeApp()

    let destinations = [
      (argument: "today", page: "今天", navigationTitle: "今天"),
      (argument: "ledger", page: "账本", navigationTitle: "账本"),
      (argument: "calendar", page: "日程", navigationTitle: "日程"),
      (argument: "travel", page: "行程", navigationTitle: "出行计划"),
      (argument: "profile", page: "我的", navigationTitle: "我的"),
    ]
    for destination in destinations {
      app.terminate()
      app.launchArguments = [
        uiTestStorageArgument,
        "--then-accessibility-audit-destination=\(destination.argument)",
      ]
      app.launch()
      XCTAssertTrue(
        app.navigationBars[destination.navigationTitle].waitForExistence(timeout: 2)
      )
      XCTAssertFalse(app.tabBars.firstMatch.exists)
      try auditRequiredAccessibility(in: app, page: destination.page)
    }

    app.terminate()
    app.launchArguments = [
      uiTestStorageArgument,
      "--then-accessibility-audit-destination=today",
    ]
    app.launch()
    XCTAssertTrue(app.navigationBars["今天"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.tabBars.firstMatch.exists)
    app.buttons["记一笔"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["记一笔"].waitForExistence(timeout: 2))
    try auditRequiredAccessibility(in: app, page: "快捷记账")
    keepScreenshot(of: app, named: "原生无障碍自动审计")
  }

  @MainActor
  func testAppSwitcherSnapshotHidesSensitiveContent() throws {
    let app = makeApp()
    app.launch()
    XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))

    XCUIDevice.shared.press(.home)
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
    let gestureStart = springboard.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)
    )
    let gestureEnd = springboard.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)
    )
    gestureStart.press(forDuration: 0.2, thenDragTo: gestureEnd)
    keepScreenshot(of: springboard, named: "系统任务切换隐私遮罩")

    app.activate()
    XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
  }

  @MainActor
  func testQuickExpenseAndRefundCanBeSavedAndOpenedFromToday() throws {
    let app = makeApp()
    app.launch()

    let quickEntry = app.buttons["记一笔"].firstMatch
    XCTAssertTrue(quickEntry.waitForExistence(timeout: 5))
    quickEntry.tap()
    XCTAssertTrue(app.navigationBars["记一笔"].waitForExistence(timeout: 2))

    let amount = app.textFields["金额"]
    XCTAssertTrue(amount.waitForExistence(timeout: 2))
    amount.tap()
    amount.typeText("12.34")
    let merchant = app.textFields["商户（可选）"]
    merchant.tap()
    merchant.typeText("自动化咖啡")
    app.buttons["保存"].tap()

    let done = app.buttons["完成"]
    XCTAssertTrue(done.waitForExistence(timeout: 5))
    done.tap()
    XCTAssertTrue(app.navigationBars["今天"].waitForExistence(timeout: 2))

    let transaction = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "自动化咖啡")
    ).firstMatch
    XCTAssertTrue(transaction.waitForExistence(timeout: 5))
    XCTAssertTrue(transaction.label.contains("12.34"))
    transaction.tap()
    XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 2))

    let refund = app.buttons["记录退款"]
    scrollToHittable(refund, in: app)
    refund.tap()
    XCTAssertTrue(app.navigationBars["记录退款"].waitForExistence(timeout: 2))
    let refundAmount = app.textFields["金额"]
    refundAmount.tap()
    refundAmount.typeText("2.34")
    app.buttons["保存"].tap()
    XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 5))
    let activeRefund = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "有效退款", "2.34")
    ).firstMatch
    let refundable = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "仍可退款", "10.00")
    ).firstMatch
    XCTAssertTrue(activeRefund.waitForExistence(timeout: 2))
    XCTAssertTrue(refundable.waitForExistence(timeout: 2))
    keepScreenshot(of: app, named: "快速记账与退款交易详情")

    let ledgerTab = app.tabBars.firstMatch.buttons["账本"]
    XCTAssertTrue(ledgerTab.waitForExistence(timeout: 2))
    ledgerTab.tap()
    XCTAssertTrue(app.navigationBars["账本"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["上一个月"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["下一个月"].exists)
    XCTAssertTrue(app.staticTexts["收入"].exists)
    XCTAssertTrue(app.staticTexts["支出"].exists)
    XCTAssertTrue(app.staticTexts["净变化"].exists)
    let reportFooter = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "本位币 CNY")
    ).firstMatch
    scrollToExist(reportFooter, in: app)
    keepScreenshot(of: app, named: "账本月度概览与交易流水")

    let search = app.searchFields["搜索账目"]
    XCTAssertTrue(search.waitForExistence(timeout: 2))
    search.tap()
    search.typeText("自动化咖啡")
    let searchResult = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "自动化咖啡")
    ).firstMatch
    scrollToExist(searchResult, in: app)
    XCTAssertTrue(searchResult.label.contains("12.34"))
    XCTAssertTrue(searchResult.label.contains("含退款"))
    keepScreenshot(of: app, named: "账本本地搜索当前交易根")
  }

  @MainActor
  func testLedgerSearchAndJourneyFilterUpdateReportAndCanBeClearedTogether() throws {
    let app = makeApp()
    app.launch()

    try saveExpense(amount: "12.34", merchant: "筛选自动化咖啡", in: app)
    try saveExpense(amount: "56.78", merchant: "筛选自动化晚餐", in: app)

    let ledgerTab = app.tabBars.firstMatch.buttons["账本"]
    XCTAssertTrue(ledgerTab.waitForExistence(timeout: 2))
    ledgerTab.tap()
    XCTAssertTrue(app.navigationBars["账本"].waitForExistence(timeout: 5))

    let filter = app.buttons.matching(identifier: "ledger.filter.button").firstMatch
    XCTAssertTrue(filter.waitForExistence(timeout: 2))
    filter.tap()
    XCTAssertTrue(app.navigationBars["筛选账目"].waitForExistence(timeout: 2))
    let unlinked = app.buttons["未关联"]
    XCTAssertTrue(unlinked.waitForExistence(timeout: 2))
    unlinked.tap()
    app.buttons.matching(identifier: "ledger.filter.apply").firstMatch.tap()

    let search = app.searchFields["搜索账目"]
    XCTAssertTrue(search.waitForExistence(timeout: 2))
    search.tap()
    search.typeText("筛选自动化咖啡\n")

    let summary = app.descendants(matching: .any)
      .matching(identifier: "ledger.filter.summary").firstMatch
    XCTAssertTrue(summary.waitForExistence(timeout: 5))
    XCTAssertTrue(summary.label.contains("筛选自动化咖啡"))
    XCTAssertTrue(summary.label.contains("未关联"))
    let trend = app.descendants(matching: .any)
      .matching(identifier: "ledger.expense.trend").firstMatch
    scrollToExist(trend, in: app)
    let coffee = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "筛选自动化咖啡")
    ).firstMatch
    scrollToExist(coffee, in: app)
    XCTAssertFalse(
      app.buttons.matching(
        NSPredicate(format: "label CONTAINS %@", "筛选自动化晚餐")
      ).firstMatch.exists
    )
    keepScreenshot(of: app, named: "账本搜索与行程组合筛选")

    let clear = app.buttons.matching(identifier: "ledger.filter.clear").firstMatch
    for _ in 0..<8 where !clear.exists || !clear.isHittable {
      app.swipeDown()
    }
    XCTAssertTrue(clear.exists)
    XCTAssertTrue(clear.isHittable)
    clear.tap()
    XCTAssertTrue(summary.waitForNonExistence(timeout: 5))
    XCTAssertEqual(search.value as? String, "搜索账目")
    let dinner = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "筛选自动化晚餐")
    ).firstMatch
    scrollToExist(dinner, in: app)
    keepScreenshot(of: app, named: "账本组合筛选已清除")
  }

  @MainActor
  func testExpenseCanBeCorrectedAndReversedWithCompleteHistory() throws {
    let app = makeApp()
    app.launch()

    let quickEntry = app.buttons["记一笔"].firstMatch
    XCTAssertTrue(quickEntry.waitForExistence(timeout: 5))
    quickEntry.tap()
    XCTAssertTrue(app.navigationBars["记一笔"].waitForExistence(timeout: 2))

    let amount = app.textFields["金额"]
    XCTAssertTrue(amount.waitForExistence(timeout: 2))
    amount.tap()
    amount.typeText("20.00")
    let merchant = app.textFields["商户（可选）"]
    merchant.tap()
    merchant.typeText("更正前商户")
    app.buttons["保存"].tap()
    XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
    app.buttons["完成"].tap()

    let transaction = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "更正前商户")
    ).firstMatch
    XCTAssertTrue(transaction.waitForExistence(timeout: 5))
    transaction.tap()
    XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 2))

    let correction = app.buttons["更正交易"]
    scrollToHittable(correction, in: app)
    correction.tap()
    XCTAssertTrue(app.navigationBars["更正交易"].waitForExistence(timeout: 2))
    replaceText(in: app.textFields["金额"], with: "18.00")
    replaceText(in: app.textFields["说明（可选）"], with: "更正后商户")
    app.buttons["保存更正"].tap()

    XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 5))
    let correctedMerchant = app.descendants(matching: .any).matching(
      identifier: "ledger-transaction-detail-payee"
    ).firstMatch
    for _ in 0..<4 where !correctedMerchant.exists {
      app.swipeDown()
    }
    XCTAssertTrue(correctedMerchant.exists)
    XCTAssertEqual(correctedMerchant.label, "说明")
    XCTAssertEqual(correctedMerchant.value as? String, "更正后商户")
    let correctedAmount = app.descendants(matching: .any).matching(
      identifier: "ledger-transaction-detail-amount"
    ).firstMatch
    for _ in 0..<4 where !correctedAmount.exists {
      app.swipeDown()
    }
    XCTAssertTrue(correctedAmount.exists)
    XCTAssertTrue(correctedAmount.label.contains("18.00"))
    XCTAssertTrue(correctedAmount.label.contains("人民币"))

    let reversal = app.buttons["撤销交易"]
    scrollToHittable(reversal, in: app)
    reversal.tap()
    XCTAssertTrue(app.navigationBars["撤销交易"].waitForExistence(timeout: 2))
    let reason = app.textFields["撤销原因"]
    XCTAssertTrue(reason.waitForExistence(timeout: 2))
    reason.tap()
    reason.typeText("自动化完整撤销")
    app.buttons["确认撤销"].tap()

    XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 5))
    let reversedCurrentVersion = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "当前版本，已撤销")
    ).firstMatch
    scrollToExist(reversedCurrentVersion, in: app)
    let correctedVersion = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "更正后的版本")
    ).firstMatch
    scrollToExist(correctedVersion, in: app)
    let correctionReversal = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "更正冲销")
    ).firstMatch
    scrollToExist(correctionReversal, in: app)
    XCTAssertFalse(app.buttons["记录退款"].exists)
    XCTAssertFalse(app.buttons["更正交易"].exists)
    XCTAssertFalse(app.buttons["撤销交易"].exists)
    keepScreenshot(of: app, named: "交易更正与完整撤销历史")
  }

  @MainActor
  func testCreditCardRepaymentUsesDedicatedEntryAndPostsAsTransfer() throws {
    let app = makeApp()
    app.launch()

    let quickEntry = app.buttons["记一笔"].firstMatch
    XCTAssertTrue(quickEntry.waitForExistence(timeout: 5))
    quickEntry.tap()
    XCTAssertTrue(app.navigationBars["记一笔"].waitForExistence(timeout: 2))
    let setupAmount = app.textFields["金额"]
    setupAmount.tap()
    setupAmount.typeText("0.01")
    let setupMerchant = app.textFields["商户（可选）"]
    setupMerchant.tap()
    setupMerchant.typeText("还款验收前置")
    app.buttons["保存"].tap()
    XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
    app.buttons["完成"].tap()

    let ledgerTab = app.tabBars.firstMatch.buttons["账本"]
    XCTAssertTrue(ledgerTab.waitForExistence(timeout: 2))
    ledgerTab.tap()
    XCTAssertTrue(app.navigationBars["账本"].waitForExistence(timeout: 5))
    app.buttons["管理账户"].tap()
    XCTAssertTrue(app.navigationBars["账户与分类"].waitForExistence(timeout: 2))
    app.buttons["添加"].tap()
    XCTAssertTrue(app.navigationBars["添加账户或分类"].waitForExistence(timeout: 2))

    let accountTypePicker = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "账户或分类类型")
    ).firstMatch
    XCTAssertTrue(accountTypePicker.waitForExistence(timeout: 2))
    accountTypePicker.tap()
    let creditCardChoice = app.buttons["信用卡"].firstMatch
    XCTAssertTrue(creditCardChoice.waitForExistence(timeout: 2))
    creditCardChoice.tap()

    let cardName = "自动化信用卡 \(Int(Date().timeIntervalSince1970))"
    let accountName = app.textFields["名称"]
    accountName.tap()
    accountName.typeText(cardName)
    app.buttons["保存"].tap()
    XCTAssertTrue(app.navigationBars["添加账户或分类"].waitForNonExistence(timeout: 5))

    let todayTab = app.tabBars.firstMatch.buttons["今天"]
    todayTab.tap()
    XCTAssertTrue(app.navigationBars["今天"].waitForExistence(timeout: 2))
    app.buttons["记一笔"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["记一笔"].waitForExistence(timeout: 2))
    let repaymentType = app.buttons["还款"]
    XCTAssertTrue(repaymentType.waitForExistence(timeout: 2))
    repaymentType.tap()
    XCTAssertTrue(
      app.buttons.matching(
        NSPredicate(format: "label CONTAINS %@", "还款账户")
      ).firstMatch.waitForExistence(timeout: 2))

    let creditCardPicker = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "信用卡账户")
    ).firstMatch
    XCTAssertTrue(creditCardPicker.waitForExistence(timeout: 2))
    creditCardPicker.tap()
    let createdCard = app.buttons[cardName].firstMatch
    XCTAssertTrue(createdCard.waitForExistence(timeout: 2))
    createdCard.tap()

    let repaymentAmount = app.textFields["金额"]
    repaymentAmount.tap()
    repaymentAmount.typeText("30.00")
    let repaymentDescription = app.textFields["还款说明（可选）"]
    repaymentDescription.tap()
    repaymentDescription.typeText("自动化信用卡还款")
    app.buttons["保存"].tap()
    XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
    app.buttons["完成"].tap()

    let repayment = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "自动化信用卡还款")
    ).firstMatch
    XCTAssertTrue(repayment.waitForExistence(timeout: 5))
    XCTAssertTrue(repayment.label.contains("30.00"))
    repayment.tap()
    XCTAssertTrue(app.navigationBars["交易详情"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["转账"].exists)
    XCTAssertTrue(app.staticTexts[cardName].exists)
    keepScreenshot(of: app, named: "信用卡还款保存为受约束转账")
  }

  @MainActor
  func testManualTripPlanCanBeSavedWithoutRouteOrReminder() throws {
    let app = makeApp()
    app.launch()

    let travelTab = app.tabBars.firstMatch.buttons["行程"]
    XCTAssertTrue(travelTab.waitForExistence(timeout: 5))
    travelTab.tap()
    let createPlan = app.buttons["新建计划"]
    XCTAssertTrue(createPlan.waitForExistence(timeout: 2))
    createPlan.tap()
    XCTAssertTrue(app.navigationBars["出行计划"].waitForExistence(timeout: 2))

    let planName = app.textFields["计划名称（可选）"]
    planName.tap()
    planName.typeText("自动化手动计划")
    let destination = app.textFields["输入目的地或地址"]
    destination.tap()
    destination.typeText("上海市人民广场")
    app.buttons["搜索不到，使用当前文字地址"].tap()

    let save = app.buttons["保存"]
    XCTAssertTrue(save.isEnabled)
    save.tap()
    XCTAssertTrue(app.staticTexts["自动化手动计划"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["手动时间"].exists)
    XCTAssertTrue(app.staticTexts["未启用提醒"].exists)
    keepScreenshot(of: app, named: "纯文字地址手动出行计划")
  }

  @MainActor
  func testFailedAppleMapsHandoffOffersExplicitDestinationCopy() throws {
    let app = makeApp()
    app.launchArguments.append("--then-ui-testing-navigation-failure")
    app.launch()

    let tripTab = app.tabBars.firstMatch.buttons["行程"]
    XCTAssertTrue(tripTab.waitForExistence(timeout: 5))
    tripTab.tap()
    XCTAssertTrue(app.navigationBars["出行计划"].waitForExistence(timeout: 2))

    app.buttons["新建计划"].tap()
    XCTAssertTrue(app.navigationBars["出行计划"].waitForExistence(timeout: 2))
    let title = app.textFields["计划名称（可选）"]
    title.tap()
    title.typeText("剪贴板降级计划")
    let destination = app.textFields["输入目的地或地址"]
    destination.tap()
    destination.typeText("上海市人民广场")
    app.buttons["搜索不到，使用当前文字地址"].tap()
    let save = app.buttons["保存"]
    XCTAssertTrue(save.isEnabled)
    save.tap()

    XCTAssertTrue(app.navigationBars["出行计划"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["剪贴板降级计划"].waitForExistence(timeout: 2))
    let openMaps = app.buttons["用 Apple 地图导航"].firstMatch
    XCTAssertTrue(openMaps.waitForExistence(timeout: 2))
    openMaps.tap()

    XCTAssertTrue(app.staticTexts["导航未打开"].waitForExistence(timeout: 2))
    let failureMessage = app.descendants(matching: .any)["trip.navigation.failure-message"]
    XCTAssertTrue(failureMessage.waitForExistence(timeout: 2))
    XCTAssertTrue(failureMessage.label.contains("Apple 地图未能打开"))
    let failedDestination =
      app.descendants(matching: .any)["trip.navigation.failed-destination"]
    XCTAssertTrue(failedDestination.waitForExistence(timeout: 2))
    XCTAssertTrue(failedDestination.label.contains("上海市人民广场"))
    let copy = app.buttons["trip.navigation.copy-destination"]
    XCTAssertTrue(copy.waitForExistence(timeout: 2))
    XCTAssertFalse(app.staticTexts["实际行程"].exists)
    XCTAssertFalse(app.buttons["恢复处理"].exists)
    XCTAssertTrue(
      app.descendants(matching: .any)["trip.navigation.copy-confirmation"]
        .waitForNonExistence(timeout: 1)
    )

    copy.tap()

    let confirmation = app.descendants(matching: .any)["trip.navigation.copy-confirmation"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
    XCTAssertTrue(confirmation.label.contains("目的地已复制"))
    try auditRequiredAccessibility(in: app, page: "导航失败复制降级")
    keepScreenshot(of: app, named: "Apple 地图失败后显式复制目的地")
  }

  @MainActor
  func testJourneyExpenseReviewClosesWithoutLosingLedgerTransaction() throws {
    let app = makeApp()
    app.resetAuthorizationStatus(for: .location)
    addUIInterruptionMonitor(withDescription: "定位权限") { alert in
      for title in ["不允许", "Don’t Allow", "Don't Allow"] where alert.buttons[title].exists {
        alert.buttons[title].tap()
        return true
      }
      return false
    }
    app.launch()

    let travelTab = app.tabBars.firstMatch.buttons["行程"]
    XCTAssertTrue(travelTab.waitForExistence(timeout: 5))
    travelTab.tap()
    app.buttons["新建计划"].tap()
    XCTAssertTrue(app.navigationBars["出行计划"].waitForExistence(timeout: 2))
    let planName = "行程消费闭环"
    app.textFields["计划名称（可选）"].tap()
    app.textFields["计划名称（可选）"].typeText(planName)
    app.textFields["输入目的地或地址"].tap()
    app.textFields["输入目的地或地址"].typeText("上海市人民广场")
    app.buttons["搜索不到，使用当前文字地址"].tap()
    app.buttons["保存"].tap()
    XCTAssertTrue(app.staticTexts[planName].waitForExistence(timeout: 5))

    app.buttons["开始记录此行程"].tap()
    XCTAssertTrue(app.navigationBars["实际行程"].waitForExistence(timeout: 2))
    app.buttons["开始记录"].tap()
    app.tap()
    let endJourney = app.buttons["结束并生成摘要"]
    XCTAssertTrue(endJourney.waitForExistence(timeout: 5))
    endJourney.tap()
    let confirmSummary = app.buttons["确认摘要并删除原始轨迹"]
    XCTAssertTrue(confirmSummary.waitForExistence(timeout: 5))
    confirmSummary.tap()
    XCTAssertTrue(
      app.staticTexts["摘要已保存，原始轨迹已删除。"].waitForExistence(timeout: 5)
    )
    app.buttons["关闭"].tap()

    XCTAssertTrue(app.staticTexts["已完成行程"].waitForExistence(timeout: 5))
    app.buttons["查看行程消费"].tap()
    XCTAssertTrue(app.navigationBars["行程消费"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["尚未完成本次消费复盘。"].exists)
    app.buttons["本次无消费"].tap()
    XCTAssertTrue(app.staticTexts["已确认本次无消费"].waitForExistence(timeout: 5))

    app.buttons["新建支出并关联"].tap()
    XCTAssertTrue(app.navigationBars["记一笔"].waitForExistence(timeout: 2))
    let amount = app.textFields["金额"]
    amount.tap()
    amount.typeText("8.88")
    let merchant = app.textFields["商户（可选）"]
    merchant.tap()
    merchant.typeText("行程自动化消费")
    app.buttons["保存"].tap()
    XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
    app.buttons["完成"].tap()

    let linkedExpense = app.staticTexts["行程自动化消费"]
    XCTAssertTrue(linkedExpense.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["已确认本次无消费"].exists)
    keepScreenshot(of: app, named: "行程消费显式复盘与关联")

    let unlink = app.buttons["解除关联"]
    scrollToHittable(unlink, in: app)
    unlink.tap()
    XCTAssertTrue(app.buttons["本次无消费"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["已确认本次无消费"].exists)

    let relink = app.buttons["关联已有支出"]
    scrollToHittable(relink, in: app)
    relink.tap()
    XCTAssertTrue(linkedExpense.waitForExistence(timeout: 5))

    let deleteJourney = app.buttons["删除此行程"]
    scrollToHittable(deleteJourney, in: app)
    deleteJourney.tap()
    let deleteAlert = app.alerts["删除此行程？"]
    XCTAssertTrue(deleteAlert.waitForExistence(timeout: 2))
    deleteAlert.buttons["删除行程"].tap()
    XCTAssertTrue(app.navigationBars["行程消费"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts[planName].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["已完成行程"].exists)

    let ledgerTab = app.tabBars.firstMatch.buttons["账本"]
    ledgerTab.tap()
    XCTAssertTrue(app.navigationBars["账本"].waitForExistence(timeout: 5))
    let search = app.searchFields["搜索账目"]
    XCTAssertTrue(search.waitForExistence(timeout: 2))
    search.tap()
    search.typeText("行程自动化消费")
    let preservedTransaction = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "行程自动化消费")
    ).firstMatch
    scrollToExist(preservedTransaction, in: app)
    XCTAssertTrue(preservedTransaction.label.contains("8.88"))
    keepScreenshot(of: app, named: "删除行程后账务继续保留")
  }

  @MainActor
  func testStructuredExportCanOpenAndCancelSystemShareSheet() throws {
    let app = makeApp()
    app.launch()

    let profileTab = app.tabBars.firstMatch.buttons["我的"]
    XCTAssertTrue(profileTab.waitForExistence(timeout: 5))
    profileTab.tap()

    let export = app.buttons["导出结构化数据"]
    scrollToHittable(export, in: app)
    export.tap()

    let activityList = app.otherElements["ActivityListView"]
    XCTAssertTrue(activityList.waitForExistence(timeout: 5))
    let close = app.buttons["关闭"]
    XCTAssertTrue(close.waitForExistence(timeout: 2))
    close.tap()
    XCTAssertTrue(activityList.waitForNonExistence(timeout: 5))

    scrollToHittable(export, in: app)
    XCTAssertTrue(export.isHittable)
    export.tap()
    XCTAssertTrue(activityList.waitForExistence(timeout: 5))
    keepScreenshot(of: app, named: "结构化数据系统分享面板")
    app.buttons["关闭"].tap()
    XCTAssertTrue(activityList.waitForNonExistence(timeout: 5))
  }

  private var uiTestStorageArgument: String {
    "--then-ui-testing-storage-id=\(uiTestStorageID)"
  }

  @MainActor
  private func makeApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [uiTestStorageArgument]
    return app
  }

  private var requiredAccessibilityAuditTypes: XCUIAccessibilityAuditType {
    [
      .elementDetection,
      .hitRegion,
      .sufficientElementDescription,
      .trait,
    ]
  }

  @MainActor
  private func auditRequiredAccessibility(
    in app: XCUIApplication,
    page: String
  ) throws {
    try app.performAccessibilityAudit(for: requiredAccessibilityAuditTypes)
    try app.performAccessibilityAudit(for: .contrast)
    try app.performAccessibilityAudit(for: .textClipped) { issue in
      print(
        "ACCESSIBILITY_TEXT_CLIPPED page=\(page) "
          + "compact=\(issue.compactDescription) "
          + "detail=\(issue.detailedDescription) "
          + "element=\(String(describing: issue.element))"
      )
      guard issue.auditType == .textClipped,
        let element = issue.element,
        element.elementType == .searchField,
        element.label == "搜索账目"
      else {
        return false
      }
      print(
        "ACCESSIBILITY_SEARCH_FIELD_TOOL_ISSUE page=\(page) "
          + "compact=\(issue.compactDescription) "
          + "element=\(element)"
      )
      return true
    }
  }

  @MainActor
  private func auditKnownDynamicTypeToolIssues(
    in app: XCUIApplication,
    page: String
  ) throws {
    var filteredCount = 0
    try app.performAccessibilityAudit(for: .dynamicType) { issue in
      guard issue.auditType == .dynamicType else { return false }
      filteredCount += 1
      print(
        "ACCESSIBILITY_DYNAMIC_TYPE_TOOL_ISSUE page=\(page) "
          + "compact=\(issue.compactDescription) "
          + "detail=\(issue.detailedDescription) "
          + "element=\(String(describing: issue.element))"
      )
      return true
    }
    print("ACCESSIBILITY_DYNAMIC_TYPE_TOOL_ISSUE_COUNT page=\(page) count=\(filteredCount)")
  }

  @MainActor
  private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<6 {
      if element.exists, element.isHittable { return }
      app.swipeUp()
    }
    XCTAssertTrue(element.exists)
    XCTAssertTrue(element.isHittable)
  }

  @MainActor
  private func scrollToFullyVisible(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<12 {
      if element.exists {
        let upperBoundary =
          app.navigationBars.firstMatch.exists
          ? app.navigationBars.firstMatch.frame.maxY
          : app.frame.minY
        let lowerBoundary = visibleContentLowerBoundary(in: app)
        let frame = element.frame
        if frame.minY >= upperBoundary, frame.maxY <= lowerBoundary {
          XCTAssertTrue(element.isHittable)
          return
        }
        if frame.maxY > lowerBoundary {
          app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.76))
            .press(
              forDuration: 0.05,
              thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.56)
              )
            )
        } else {
          app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
            .press(
              forDuration: 0.05,
              thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)
              )
            )
        }
      } else {
        app.swipeUp()
      }
    }
    XCTAssertTrue(element.exists)
    XCTAssertGreaterThanOrEqual(element.frame.minY, app.navigationBars.firstMatch.frame.maxY)
    XCTAssertLessThanOrEqual(element.frame.maxY, visibleContentLowerBoundary(in: app))
    XCTAssertTrue(element.isHittable)
  }

  @MainActor
  private func visibleContentLowerBoundary(in app: XCUIApplication) -> CGFloat {
    let tabBar = app.tabBars.firstMatch
    return tabBar.exists ? tabBar.frame.minY - 8 : app.frame.maxY - 8
  }

  @MainActor
  private func scrollToExist(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<6 {
      if element.exists { return }
      app.swipeUp()
    }
    XCTAssertTrue(element.exists)
  }

  @MainActor
  private func replaceText(in field: XCUIElement, with replacement: String) {
    XCTAssertTrue(field.waitForExistence(timeout: 2))
    field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
    field.typeText(replacement)
  }

  @MainActor
  private func saveExpense(
    amount: String,
    merchant: String,
    in app: XCUIApplication
  ) throws {
    let todayTab = app.tabBars.firstMatch.buttons["今天"]
    if todayTab.exists {
      todayTab.tap()
    }
    XCTAssertTrue(app.navigationBars["今天"].waitForExistence(timeout: 2))
    let quickEntry = app.buttons["记一笔"].firstMatch
    XCTAssertTrue(quickEntry.waitForExistence(timeout: 2))
    quickEntry.tap()
    XCTAssertTrue(app.navigationBars["记一笔"].waitForExistence(timeout: 2))
    let amountField = app.textFields["金额"]
    XCTAssertTrue(amountField.waitForExistence(timeout: 2))
    amountField.tap()
    amountField.typeText(amount)
    let merchantField = app.textFields["商户（可选）"]
    merchantField.tap()
    merchantField.typeText(merchant)
    app.buttons["保存"].tap()
    let done = app.buttons["完成"]
    XCTAssertTrue(done.waitForExistence(timeout: 5))
    done.tap()
    XCTAssertTrue(app.navigationBars["今天"].waitForExistence(timeout: 2))
  }

  @MainActor
  private func keepScreenshot(of app: XCUIApplication, named name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
