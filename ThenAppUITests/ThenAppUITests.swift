import CoreGraphics
import XCTest

final class ThenAppUITests: XCTestCase {
  @MainActor
  func testWooStudioAndBuiltInWardrobe() throws {
    let app = launchApp()

    XCTAssertTrue(app.buttons["形象"].exists)
    XCTAssertTrue(app.buttons["可选照片穿搭"].exists)
    XCTAssertTrue(app.buttons["内置衣橱"].exists)
    XCTAssertTrue(app.buttons["向左转动"].exists)
    XCTAssertTrue(app.buttons["向右转动"].exists)
    XCTAssertTrue(app.buttons["打开穿搭日历"].exists)
    XCTAssertTrue(app.buttons["打开个人衣橱"].exists)
    XCTAssertFalse(app.buttons["账本"].exists)
    XCTAssertFalse(app.buttons["日程"].exists)

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
  func testBackgroundHidesSensitiveContentAndRestoresStudio() throws {
    let app = launchApp()
    let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
    let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
    bottom.press(forDuration: 0.1, thenDragTo: middle, withVelocity: .slow, thenHoldForDuration: 1)
    app.activate()
    XCTAssertTrue(app.buttons["形象"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["打开个人衣橱"].exists)
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
    let app = XCUIApplication()
    app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
    app.launch()
    XCTAssertTrue(app.buttons["形象"].waitForExistence(timeout: 8))
    return app
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
}
