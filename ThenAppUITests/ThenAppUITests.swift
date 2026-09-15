import CoreGraphics
import Foundation
import XCTest

final class ThenAppUITests: XCTestCase {
  @MainActor
  func testAvatarPhotoPOCDeclarationAndTemplateExit() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--then-avatar-photo-intake-poc",
      "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryL",
    ]
    app.launch()

    let disclosureTitle = app.staticTexts["用一张照片试试数字形象"]
    XCTAssertTrue(disclosureTitle.waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["avatar.photo.poc.picker"].exists)
    let continueButton = app.buttons["avatar.photo.poc.continue"]
    XCTAssertTrue(continueButton.exists)
    XCTAssertFalse(continueButton.isEnabled)

    app.switches["avatar.photo.poc.declaration"].tap()
    XCTAssertTrue(continueButton.isEnabled)
    continueButton.tap()
    XCTAssertTrue(app.buttons["avatar.photo.poc.picker"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["形象"].exists)

    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(disclosureTitle.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["avatar.photo.poc.picker"].exists)

    app.buttons["avatar.photo.poc.template"].tap()
    XCTAssertTrue(app.staticTexts["已改用风格化形象"].waitForExistence(timeout: 3))
    app.buttons["avatar.photo.poc.restart"].tap()
    XCTAssertTrue(disclosureTitle.waitForExistence(timeout: 3))
  }

  @MainActor
  func testAvatarPhotoPOCAccessibility() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--then-avatar-photo-intake-poc",
      "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()

    XCTAssertTrue(app.staticTexts["用一张照片试试数字形象"].waitForExistence(timeout: 8))
    let continueButton = app.buttons["avatar.photo.poc.continue"]
    XCTAssertTrue(continueButton.exists)
    XCTAssertFalse(continueButton.isEnabled)
    try app.performAccessibilityAudit(for: [.contrast, .textClipped])
    attachScreenshot(named: "avatar-photo-poc-accessibility")
  }

  @MainActor
  func testAvatarPhotoPOCSyntheticSelectionCancellationAndReasons() throws {
    let cancelling = launchAvatarPhotoPOC(scenario: "delayed-multiple-people")
    try selectAvatarPhoto(in: cancelling)
    let analyzingTitle = cancelling.staticTexts["正在检查画面质量…"]
    XCTAssertTrue(analyzingTitle.waitForExistence(timeout: 15))
    cancelling.buttons["avatar.photo.poc.cancel"].tap()
    XCTAssertTrue(cancelling.buttons["avatar.photo.poc.picker"].waitForExistence(timeout: 5))
    XCTAssertFalse(cancelling.descendants(matching: .any)
      .matching(identifier: "avatar.photo.poc.processing").firstMatch.exists)
    cancelling.terminate()

    let replacement = launchAvatarPhotoPOC(scenario: "multiple-people")
    try selectAvatarPhoto(in: replacement)
    XCTAssertTrue(replacement.staticTexts["换一张全身照"].waitForExistence(timeout: 15))
    let replacementReason = replacement.staticTexts["avatar.photo.poc.reason"]
    XCTAssertTrue(replacementReason.exists)
    XCTAssertEqual(replacementReason.label, "画面中出现了多个人，请选择只有你本人的照片。")
    XCTAssertEqual(replacement.staticTexts.matching(identifier: "avatar.photo.poc.reason").count, 1)
    replacement.terminate()

    let unsupported = launchAvatarPhotoPOC(scenario: "device-unavailable")
    try selectAvatarPhoto(in: unsupported)
    XCTAssertTrue(unsupported.staticTexts["这张照片暂时无法使用"].waitForExistence(timeout: 15))
    let unsupportedReason = unsupported.staticTexts["avatar.photo.poc.reason"]
    XCTAssertTrue(unsupportedReason.exists)
    XCTAssertEqual(unsupportedReason.label, "当前设备暂时无法完成本机画面检查。")
    XCTAssertEqual(unsupported.staticTexts.matching(identifier: "avatar.photo.poc.reason").count, 1)
    try unsupported.performAccessibilityAudit(for: [.contrast, .textClipped])
    attachScreenshot(named: "avatar-photo-poc-unsupported")
  }

  @MainActor
  func testAvatarCompatibilityVisualMatrix() throws {
    let app = launchApp()
    let renderer = app.descendants(matching: .any).matching(identifier: "avatar.renderer").firstMatch
    guard renderer.waitForExistence(timeout: 8) else {
      let fallback = app.descendants(matching: .any).matching(identifier: "avatar.renderer.fallback").firstMatch
      XCTFail("三维画布未进入可访问性层级；降级原因：\(fallback.value ?? "unknown")")
      return
    }
    waitForRenderer(app, renderer: renderer)

    let parameters: [(name: String, position: CGFloat)] = [
      ("minus", 0),
      ("neutral", 0.5),
      ("plus", 1),
    ]
    let angles: [(name: String, button: String)] = [
      ("front", "正面"),
      ("side", "侧面"),
      ("back", "背面"),
    ]
    let tops = ["ivory-knit", "blue-shirt"]

    for top in tops {
      if top == "blue-shirt" {
        app.buttons["内置衣橱"].tap()
        XCTAssertTrue(app.buttons["OUTERWEAR"].waitForExistence(timeout: 3))
        app.buttons["OUTERWEAR"].tap()
        XCTAssertTrue(app.buttons["雾蓝宽松衬衫"].waitForExistence(timeout: 3))
        app.buttons["雾蓝宽松衬衫"].tap()
        app.buttons["Dress up"].tap()
        XCTAssertTrue(renderer.waitForExistence(timeout: 5))
        waitForRenderer(app, renderer: renderer)
      }

      for shoulder in parameters {
        for torso in parameters {
          app.buttons["形象"].tap()
          let shoulderSlider = app.sliders["肩部宽度"]
          let torsoSlider = app.sliders["躯干厚度"]
          XCTAssertTrue(shoulderSlider.waitForExistence(timeout: 3))
          shoulderSlider.adjust(toNormalizedSliderPosition: shoulder.position)
          torsoSlider.adjust(toNormalizedSliderPosition: torso.position)
          app.buttons["完成"].tap()
          waitForRenderer(app, renderer: renderer)

          for angle in angles {
            app.buttons[angle.button].tap()
            waitForRenderer(app, renderer: renderer)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "\(top)-shoulder-\(shoulder.name)-torso-\(torso.name)-\(angle.name).png"
            attachment.lifetime = .keepAlways
            add(attachment)
          }
        }
      }
    }
  }

  @MainActor
  func testWooStudioAndBuiltInWardrobe() throws {
    let app = launchApp()
    let renderer = app.descendants(matching: .any).matching(identifier: "avatar.renderer").firstMatch
    waitForRenderer(app, renderer: renderer)

    XCTAssertTrue(app.buttons["形象"].exists)
    XCTAssertTrue(app.buttons["可选照片穿搭"].exists)
    XCTAssertTrue(app.buttons["内置衣橱"].exists)
    XCTAssertTrue(app.buttons["向左转动"].exists)
    XCTAssertTrue(app.buttons["向右转动"].exists)
    XCTAssertTrue(app.buttons["打开穿搭日历"].exists)
    XCTAssertTrue(app.buttons["打开个人衣橱"].exists)
    XCTAssertFalse(app.buttons["账本"].exists)
    XCTAssertFalse(app.buttons["日程"].exists)

    let dragStart = renderer.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
    let dragEnd = renderer.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45))
    dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
    waitForRenderer(app, renderer: renderer)

    app.buttons["侧面"].tap()
    app.buttons["内置衣橱"].tap()
    for title in ["TOPS", "OUTERWEAR", "BOTTOMS", "SHOES", "Dress up"] {
      XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3))
    }
    app.buttons["OUTERWEAR"].tap()
    XCTAssertTrue(app.buttons["雾蓝宽松衬衫"].waitForExistence(timeout: 3))
    app.buttons["雾蓝宽松衬衫"].tap()
    app.buttons["Dress up"].tap()
    XCTAssertTrue(app.buttons["形象"].waitForExistence(timeout: 3))
    waitForRenderer(app, renderer: renderer)
    XCTAssertTrue(app.images["雾蓝宽松衬衫"].waitForExistence(timeout: 3))
  }

  @MainActor
  func testPersonalWardrobeCreateRestartAndDelete() throws {
    let name = "验收上装" + UUID().uuidString.prefix(6)
    let app = launchApp()
    openWardrobe(app)
    addGarment(app, name: String(name))
    XCTAssertTrue(app.staticTexts[String(name)].waitForExistence(timeout: 5))

    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["形象"].waitForExistence(timeout: 8))
    openWardrobe(app)
    XCTAssertTrue(app.staticTexts[String(name)].waitForExistence(timeout: 5))
    app.staticTexts[String(name)].tap()
    XCTAssertTrue(app.buttons["删除衣物"].waitForExistence(timeout: 3))
    app.buttons["删除衣物"].tap()
    XCTAssertTrue(app.buttons["确认删除"].waitForExistence(timeout: 3))
    app.buttons["确认删除"].tap()
    XCTAssertFalse(app.staticTexts[String(name)].waitForExistence(timeout: 3))
  }

  @MainActor
  func testWardrobeAttributesSaveCancelClearRestartAndHistoricalSnapshot() throws {
    let suffix = UUID().uuidString.prefix(6)
    let garment = "属性外套" + suffix
    let scene = "属性快照" + suffix
    let app = launchApp()
    openWardrobe(app)
    app.buttons["添加衣物"].tap()
    let field = app.textFields["wardrobe.name"]
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    field.tap()
    field.typeText(String(garment))
    app.buttons["wardrobe.category"].tap()
    app.buttons["外套"].tap()
    selectPicker("wardrobe.attribute.formality", option: "正式", in: app)
    selectPicker("wardrobe.attribute.warmth", option: "偏暖", in: app)
    selectPicker("wardrobe.attribute.rain", option: "适合", in: app)
    selectPicker("wardrobe.attribute.walking", option: "不适合", in: app)
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "wardrobe.attribute.source")
      .firstMatch.waitForExistence(timeout: 3))
    reveal(app.buttons["保存"], in: app)
    app.buttons["保存"].tap()
    XCTAssertTrue(app.staticTexts[String(garment)].waitForExistence(timeout: 5))
    app.buttons["关闭"].tap()

    openOutfits(app)
    app.buttons["新建计划"].tap()
    let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", String(garment))).firstMatch
    XCTAssertTrue(choice.waitForExistence(timeout: 5))
    choice.tap()
    let summary = app.textFields["outfit.summary"]
    summary.tap()
    summary.typeText(String(scene))
    app.buttons["保存"].tap()
    XCTAssertTrue(app.staticTexts[String(scene)].waitForExistence(timeout: 5))
    app.staticTexts[String(scene)].tap()
    XCTAssertTrue(app.staticTexts["保存时由你确认"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "雨天：适合")).firstMatch.exists)
    app.navigationBars["穿搭计划"].buttons["关闭"].tap()
    app.navigationBars["穿搭簿"].buttons["关闭"].tap()

    openWardrobe(app)
    app.staticTexts[String(garment)].tap()
    XCTAssertTrue(app.buttons["wardrobe.attribute.rain"].label.contains("适合"))
    selectPicker("wardrobe.attribute.rain", option: "未知", in: app)
    app.buttons["取消"].tap()
    app.staticTexts[String(garment)].tap()
    XCTAssertTrue(app.buttons["wardrobe.attribute.rain"].label.contains("适合"))
    selectPicker("wardrobe.attribute.rain", option: "未知", in: app)
    reveal(app.buttons["保存"], in: app)
    app.buttons["保存"].tap()

    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["形象"].waitForExistence(timeout: 8))
    openWardrobe(app)
    app.staticTexts[String(garment)].tap()
    XCTAssertTrue(app.buttons["wardrobe.attribute.formality"].label.contains("正式"))
    XCTAssertTrue(app.buttons["wardrobe.attribute.warmth"].label.contains("偏暖"))
    XCTAssertTrue(app.buttons["wardrobe.attribute.rain"].label.contains("未知"))
    XCTAssertTrue(app.buttons["wardrobe.attribute.walking"].label.contains("不适合"))
    app.buttons["取消"].tap()
    app.navigationBars["衣橱"].buttons["关闭"].tap()

    openOutfits(app)
    app.staticTexts[String(scene)].tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "雨天：适合")).firstMatch.exists)
    app.buttons["删除计划"].tap()
    app.buttons["确认删除计划"].tap()
    XCTAssertTrue(app.staticTexts[String(scene)].waitForNonExistence(timeout: 5))
    let closeOutfits = app.navigationBars["穿搭簿"].buttons["关闭"]
    XCTAssertTrue(closeOutfits.waitForExistence(timeout: 5))
    tapWhenHittable(closeOutfits)
    openWardrobe(app)
    app.staticTexts[String(garment)].tap()
    reveal(app.buttons["删除衣物"], in: app)
    app.buttons["删除衣物"].tap()
    app.buttons["确认删除"].tap()
  }

  @MainActor
  func testWardrobeAttributesInAccessibilityEnvironment() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      "-UIAccessibilityReduceMotionEnabled", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.buttons["形象"].waitForExistence(timeout: 8))
    openWardrobe(app)
    app.buttons["添加衣物"].tap()
    let formality = app.buttons["wardrobe.attribute.formality"]
    for _ in 0..<8 where !formality.exists {
      app.swipeUp()
    }
    XCTAssertTrue(formality.waitForExistence(timeout: 3))
    XCTAssertTrue(formality.label.contains("未知"))
    let walking = app.buttons["wardrobe.attribute.walking"]
    for _ in 0..<8 where !walking.exists {
      app.swipeUp()
    }
    XCTAssertTrue(walking.waitForExistence(timeout: 3))
    reveal(walking, in: app)
    XCTAssertTrue(walking.label.contains("未知"))
    try app.performAccessibilityAudit(for: [.contrast, .textClipped])
    app.buttons["取消"].tap()
  }

  @MainActor
  func testWardrobePhotoCreateRestartRemoveAndDelete() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["THEN_WARDROBE_PHOTO_FIXTURE"] == "1",
      "Requires one current synthetic garment image in the booted simulator photo library")
    let name = "照片上装" + UUID().uuidString.prefix(6)
    let app = launchApp()
    openWardrobe(app)
    app.buttons["添加衣物"].tap()
    let field = app.textFields["wardrobe.name"]
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    field.tap()
    field.typeText(String(name))
    app.buttons["wardrobe.category"].tap()
    app.buttons["上装"].tap()

    app.buttons["wardrobe.photo.pick"].tap()
    selectFirstSystemPhoto(in: app)
    XCTAssertTrue(app.images["wardrobe.photo.preview"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["wardrobe.photo.subject"].waitForExistence(timeout: 3))
    app.buttons["wardrobe.photo.subject"].tap()
    app.buttons["一件衣物或配件"].tap()
    for identifier in ["wardrobe.photo.owned", "wardrobe.photo.no-person", "wardrobe.photo.complete"] {
      let toggle = app.switches[identifier]
      XCTAssertTrue(toggle.waitForExistence(timeout: 3))
      XCTAssertEqual(toggle.value as? String, "0")
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
      XCTAssertEqual(toggle.value as? String, "1")
    }
    app.buttons["wardrobe.photo.confirm"].tap()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "wardrobe.photo.confirmed").firstMatch.waitForExistence(timeout: 3))
    try app.performAccessibilityAudit(for: [.contrast, .textClipped])
    app.buttons["保存"].tap()
    XCTAssertTrue(app.staticTexts[String(name)].waitForExistence(timeout: 5))

    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["形象"].waitForExistence(timeout: 8))
    openWardrobe(app)
    app.staticTexts[String(name)].tap()
    XCTAssertTrue(app.images["wardrobe.photo.preview"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["wardrobe.photo.remove"].waitForExistence(timeout: 3))
    app.buttons["wardrobe.photo.remove"].tap()
    app.buttons["确认移除照片"].tap()
    XCTAssertTrue(app.images["wardrobe.photo.preview"].waitForNonExistence(timeout: 5))
    app.buttons["取消"].tap()

    app.staticTexts[String(name)].tap()
    XCTAssertTrue(app.images["wardrobe.photo.preview"].waitForNonExistence(timeout: 3))
    app.buttons["删除衣物"].tap()
    app.buttons["确认删除"].tap()
    XCTAssertFalse(app.staticTexts[String(name)].waitForExistence(timeout: 3))
  }

  @MainActor
  func testOwnedGarmentCanCreateAndDeleteOutfitPlan() throws {
    let garment = "计划上装" + UUID().uuidString.prefix(6)
    let scene = "通勤" + UUID().uuidString.prefix(6)
    let app = launchApp()

    openWardrobe(app)
    addGarment(app, name: String(garment))
    XCTAssertTrue(app.staticTexts[String(garment)].waitForExistence(timeout: 5))
    app.buttons["关闭"].tap()

    openOutfits(app)
    app.buttons["新建计划"].tap()
    let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", String(garment))).firstMatch
    XCTAssertTrue(choice.waitForExistence(timeout: 5))
    choice.tap()
    let summary = app.textFields["outfit.summary"]
    summary.tap()
    summary.typeText(String(scene))
    app.buttons["保存"].tap()
    XCTAssertTrue(app.staticTexts[String(scene)].waitForExistence(timeout: 5))
    app.staticTexts[String(scene)].tap()
    XCTAssertTrue(app.buttons["删除计划"].waitForExistence(timeout: 5))
    app.buttons["删除计划"].tap()
    app.buttons["确认删除计划"].tap()
    XCTAssertFalse(app.staticTexts[String(scene)].waitForExistence(timeout: 4))

    app.buttons["关闭"].tap()
    openWardrobe(app)
    app.staticTexts[String(garment)].tap()
    app.buttons["删除衣物"].tap()
    app.buttons["确认删除"].tap()
  }

  @MainActor
  func testOutfitPlanAtLargestAccessibilityText() throws {
    let garment = "辅助字号上装" + UUID().uuidString.prefix(6)
    let app = launchApp(contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL")

    openWardrobe(app)
    addGarment(app, name: String(garment))
    XCTAssertTrue(app.staticTexts[String(garment)].waitForExistence(timeout: 5))
    app.buttons["关闭"].tap()

    openOutfits(app)
    app.buttons["新建计划"].tap()

    let datePicker = app.datePickers["穿搭日期"].firstMatch
    XCTAssertTrue(datePicker.waitForExistence(timeout: 5))
    XCTAssertTrue(app.frame.contains(datePicker.frame), "最大字号日期控件超出页面：\(datePicker.frame)")
    let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: Date()))
    select(tomorrow, in: datePicker)
    try app.performAccessibilityAudit(for: [.contrast, .textClipped])

    let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", String(garment))).firstMatch
    reveal(choice, in: app)
    choice.tap()
    app.buttons["保存"].tap()

    let dayHeader = app.staticTexts[isoDay(tomorrow)]
    XCTAssertTrue(dayHeader.waitForExistence(timeout: 5), "未来日期未出现在穿搭簿")
    attachScreenshot(named: "outfit-future-date-largest-text")
    let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", String(garment))).firstMatch
    XCTAssertTrue(saved.waitForExistence(timeout: 5))
    saved.tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "原始时区：")).firstMatch.waitForExistence(timeout: 5))
    try app.performAccessibilityAudit(for: [.contrast, .textClipped])

    let cancel = app.buttons["取消计划"]
    reveal(cancel, in: app)
    cancel.tap()
    XCTAssertTrue(app.buttons["确认取消计划"].waitForExistence(timeout: 3))
    app.buttons["确认取消计划"].tap()
    XCTAssertTrue(app.staticTexts["已取消"].waitForExistence(timeout: 5))
    try app.performAccessibilityAudit(for: [.contrast, .textClipped])
    attachScreenshot(named: "outfit-cancelled-detail-largest-text")

    let delete = app.buttons["删除计划"]
    reveal(delete, in: app)
    delete.tap()
    XCTAssertTrue(app.buttons["确认删除计划"].waitForExistence(timeout: 3))
    app.buttons["确认删除计划"].tap()
    XCTAssertTrue(saved.waitForNonExistence(timeout: 5))

    app.buttons["关闭"].tap()
    openWardrobe(app)
    let garmentRow = app.staticTexts[String(garment)]
    reveal(garmentRow, in: app)
    garmentRow.tap()
    let deleteGarment = app.buttons["删除衣物"]
    reveal(deleteGarment, in: app)
    deleteGarment.tap()
    XCTAssertTrue(app.buttons["确认删除"].waitForExistence(timeout: 3))
    app.buttons["确认删除"].tap()
  }

  @MainActor
  func testBackgroundHidesSensitiveContentAndRestoresStudio() throws {
    let app = launchApp()
    let renderer = app.descendants(matching: .any).matching(identifier: "avatar.renderer").firstMatch
    waitForRenderer(app, renderer: renderer)

    app.buttons["打开穿搭日历"].tap()
    XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
    app.buttons["关闭"].tap()
    waitForRenderer(app, renderer: renderer)

    XCUIDevice.shared.press(.home)
    sleep(30)
    app.activate()
    XCTAssertTrue(app.buttons["形象"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["打开个人衣橱"].exists)
    waitForRenderer(app, renderer: renderer)
  }

  @MainActor
  func testInterruptedAvatarDragRestoresRenderer() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["THEN_INTERRUPT_AVATAR_DRAG"] == "1",
      "Requires the host to foreground another simulator app during the five-second drag"
    )
    let app = launchApp()
    let renderer = app.descendants(matching: .any).matching(identifier: "avatar.renderer").firstMatch
    waitForRenderer(app, renderer: renderer)

    let dragStart = renderer.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
    let dragEnd = renderer.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45))
    dragStart.press(
      forDuration: 0.1,
      thenDragTo: dragEnd,
      withVelocity: .slow,
      thenHoldForDuration: 5
    )

    app.activate()
    XCTAssertTrue(app.buttons["形象"].waitForExistence(timeout: 8))
    waitForRenderer(app, renderer: renderer)
  }

  @MainActor
  func testWooStudioAtLargestAccessibilityText() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    app.launch()
    XCTAssertTrue(app.buttons["形象"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["可选照片穿搭"].exists)
    XCTAssertTrue(app.buttons["内置衣橱"].exists)
    XCTAssertTrue(app.buttons["观察角度"].exists)
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "拖动形象查看")).firstMatch.exists)
    try app.performAccessibilityAudit(for: [.contrast])
  }

  @MainActor
  private func launchApp() -> XCUIApplication {
    launchApp(contentSizeCategory: "UICTContentSizeCategoryL")
  }

  @MainActor
  private func launchApp(contentSizeCategory: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
    app.launch()
    XCTAssertTrue(app.buttons["形象"].waitForExistence(timeout: 8))
    return app
  }

  @MainActor
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<10 where !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable, "无法滚动到元素：\(element)")
  }

  @MainActor
  private func select(_ date: Date, in datePicker: XCUIElement) {
    let calendar = Calendar.current
    if !calendar.isDate(date, equalTo: Date(), toGranularity: .month) {
      datePicker.buttons["DatePicker.NextMonth"].tap()
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "M月d日 EEEE"
    let day = datePicker.buttons[formatter.string(from: date)]
    XCTAssertTrue(day.waitForExistence(timeout: 3), "日期选择器中找不到明天：\(formatter.string(from: date))")
    day.tap()
    XCTAssertTrue(day.isSelected, "日期选择器未选中明天")
  }

  private func isoDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = Calendar.current.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  @MainActor
  private func attachScreenshot(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + ".png"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private func waitForRenderer(
    _ app: XCUIApplication,
    renderer: XCUIElement,
    timeout: TimeInterval = 8
  ) {
    XCTAssertTrue(renderer.waitForExistence(timeout: timeout))
    let loading = app.descendants(matching: .any).matching(identifier: "avatar.renderer.loading").firstMatch
    XCTAssertTrue(loading.waitForNonExistence(timeout: timeout), "三维画布未在时限内完成渲染")
    let fallback = app.descendants(matching: .any).matching(identifier: "avatar.renderer.fallback").firstMatch
    XCTAssertFalse(fallback.exists, "三维画布进入静态降级：\(fallback.value ?? "unknown")")
    XCTAssertTrue(renderer.exists)
  }

  @MainActor
  private func openWardrobe(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["打开个人衣橱"].waitForExistence(timeout: 5))
    app.buttons["打开个人衣橱"].tap()
    XCTAssertTrue(app.buttons["添加衣物"].waitForExistence(timeout: 5))
  }

  @MainActor
  private func openOutfits(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["打开穿搭日历"].waitForExistence(timeout: 5))
    app.buttons["打开穿搭日历"].tap()
    XCTAssertTrue(app.buttons["新建计划"].waitForExistence(timeout: 5))
  }

  @MainActor
  private func addGarment(_ app: XCUIApplication, name: String) {
    app.buttons["添加衣物"].tap()
    let field = app.textFields["wardrobe.name"]
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    field.tap()
    field.typeText(name)
    app.buttons["wardrobe.category"].tap()
    app.buttons["上装"].tap()
    app.buttons["保存"].tap()
  }

  @MainActor
  private func selectPicker(_ identifier: String, option: String, in app: XCUIApplication) {
    let picker = app.buttons[identifier]
    XCTAssertTrue(picker.waitForExistence(timeout: 3))
    reveal(picker, in: app)
    picker.tap()
    let value = app.buttons[option]
    XCTAssertTrue(value.waitForExistence(timeout: 3))
    value.tap()
    XCTAssertTrue(picker.label.contains(option))
  }

  @MainActor
  private func tapWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 5) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == true"),
      object: element
    )
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    element.tap()
  }

  @MainActor
  private func selectFirstSystemPhoto(in app: XCUIApplication) {
    let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
    XCTAssertTrue(photo.waitForExistence(timeout: 8), "系统照片选择器没有可选图片；请先导入当前合成衣物夹具")
    photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
  }

  @MainActor
  private func launchAvatarPhotoPOC(scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--then-avatar-photo-intake-poc",
      "--then-avatar-photo-poc-scenario=\(scenario)",
      "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryL",
    ]
    app.launch()
    XCTAssertTrue(app.staticTexts["用一张照片试试数字形象"].waitForExistence(timeout: 8))
    return app
  }

  @MainActor
  private func selectAvatarPhoto(in app: XCUIApplication) throws {
    app.switches["avatar.photo.poc.declaration"].tap()
    app.buttons["avatar.photo.poc.continue"].tap()
    XCTAssertTrue(app.buttons["avatar.photo.poc.picker"].waitForExistence(timeout: 3))
    app.buttons["avatar.photo.poc.picker"].tap()
    let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
    try XCTSkipUnless(
      photo.waitForExistence(timeout: 8),
      "Requires one approved synthetic adult fixture in the booted simulator photo library"
    )
    photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
  }
}
