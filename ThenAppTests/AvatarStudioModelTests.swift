import Testing
@testable import ThenApp

@Suite("内置服装三维穿搭")
struct AvatarStudioModelTests {
  @Test("首次打开无需照片或用户衣物") @MainActor
  func startsWithBuiltInLook() {
    let model = AvatarStudioModel()

    #expect(model.appliedGarments.count == 3)
    #expect(model.renderConfiguration.top == "ivory-knit")
    #expect(model.renderConfiguration.bottom == "black-skirt")
    #expect(model.renderConfiguration.shoes == "cream-sneakers")
  }

  @Test("同类选择会替换旧单品并更新三维配置") @MainActor
  func replacesGarmentWithinCategory() throws {
    let model = AvatarStudioModel()
    let mintSkirt = try #require(AvatarStudioModel.catalog.first { $0.id == "mint-skirt" })

    model.toggle(mintSkirt)
    model.dressUp()

    #expect(model.renderConfiguration.bottom == "mint-skirt")
    #expect(!model.appliedIDs.contains("black-skirt"))
    #expect(model.screen == .look)
  }

  @Test("上衣与外套共享一个三维上身槽位") @MainActor
  func replacesTopWithOuterwear() throws {
    let model = AvatarStudioModel()
    let blueShirt = try #require(AvatarStudioModel.catalog.first { $0.id == "blue-shirt" })

    model.toggle(blueShirt)
    model.dressUp()

    #expect(model.renderConfiguration.top == "blue-shirt")
    #expect(!model.appliedIDs.contains("ivory-knit"))
  }

  @Test("减少动态效果会同步到三维渲染配置") @MainActor
  func appliesReduceMotionPreference() {
    let model = AvatarStudioModel()
    let originalRevision = model.revision

    model.setReduceMotion(true)

    #expect(model.renderConfiguration.reduceMotion)
    #expect(model.revision == originalRevision + 1)

    model.setReduceMotion(true)
    #expect(model.revision == originalRevision + 1)
  }

  @Test("三维舞台只在前台可见且没有覆盖页时运行")
  func limitsRendererActivityToVisibleStage() {
    #expect(AvatarStageActivity(appIsActive: true, stageIsVisible: true, hasPresentedCover: false).rendererIsActive)
    #expect(!AvatarStageActivity(appIsActive: false, stageIsVisible: true, hasPresentedCover: false).rendererIsActive)
    #expect(!AvatarStageActivity(appIsActive: true, stageIsVisible: false, hasPresentedCover: false).rendererIsActive)
    #expect(!AvatarStageActivity(appIsActive: true, stageIsVisible: true, hasPresentedCover: true).rendererIsActive)
  }
}
