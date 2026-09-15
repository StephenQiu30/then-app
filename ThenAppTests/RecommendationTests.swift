import Foundation
import Testing
@testable import ThenApp

@Suite("本地硬约束推荐")
struct RecommendationTests {
  private let engine = LocalRecommendationEngine()

  @Test("候选只保留真实身份并支持两条完整路径")
  func preservesIdentityAcrossCompletePaths() throws {
    let dress = try item("连体衣", .onePiece)
    let top = try item("上装", .top)
    let bottom = try item("下装", .bottom)
    let shoes = try item("鞋", .shoes)
    let result = engine.generate(context: try context(), wardrobe: [top, bottom, dress, shoes])
    guard case .candidates(let candidates) = result else { Issue.record("expected candidates"); return }
    #expect(candidates.count == 2)
    #expect(candidates[0].items.map(\.id) == [dress.id, shoes.id])
    #expect(Set(candidates[1].items.map(\.id)) == Set([top.id, bottom.id, shoes.id]))
  }

  @Test("待洗借出始终排除且已打包只在显式场景进入")
  func filtersAvailabilityAndPackedContext() throws {
    let top = try item("已打包上装", .top, availability: .packed)
    let bottom = try item("下装", .bottom)
    let shoes = try item("鞋", .shoes)
    let laundry = try item("待洗连体衣", .onePiece, availability: .laundry)
    let lent = try item("借出连体衣", .onePiece, availability: .lentOut)

    #expect(engine.generate(context: try context(), wardrobe: [top, bottom, shoes, laundry, lent])
      == .noSolution(.missingTopOrOnePiece))
    let admitted = engine.generate(context: try context(includesPackedItems: true),
                                    wardrobe: [top, bottom, shoes, laundry, lent])
    guard case .candidates(let candidates) = admitted else { Issue.record("expected packed candidate"); return }
    #expect(candidates.count == 1)
    #expect(candidates[0].items.contains { $0.id == top.id })
    #expect(!candidates[0].items.contains { $0.id == laundry.id || $0.id == lent.id })
  }

  @Test("未知确认属性不能冒充满足硬约束")
  func unknownCannotSatisfyConfirmedConstraints() throws {
    let confirmed = WardrobeAttributes(formalityBand: .formal, warmthBand: .warm,
      rainUse: .suitable, walkingUse: .suitable)
    let unknownTop = try item("未知上装", .top)
    let bottom = try item("正式下装", .bottom, attributes: confirmed)
    let shoes = try item("正式鞋", .shoes, attributes: confirmed)
    let result = engine.generate(
      context: try context(formality: .formal, warmth: .warm, rain: true, walking: true),
      wardrobe: [unknownTop, bottom, shoes]
    )
    #expect(result == .noSolution(.confirmedConstraintsConflict))
  }

  @Test("雨天与步行要求只由已确认适合的鞋履满足")
  func requiresConfirmedShoeSuitability() throws {
    let core = WardrobeAttributes(formalityBand: .casual, warmthBand: .medium)
    let top = try item("上装", .top, attributes: core)
    let bottom = try item("下装", .bottom, attributes: core)
    let unsuitable = try item("不适合的鞋", .shoes,
      attributes: .init(formalityBand: .casual, warmthBand: .medium,
                        rainUse: .unsuitable, walkingUse: .unsuitable))
    let suitable = try item("适合的鞋", .shoes,
      attributes: .init(formalityBand: .casual, warmthBand: .medium,
                        rainUse: .suitable, walkingUse: .suitable))
    let result = engine.generate(context: try context(rain: true, walking: true),
                                 wardrobe: [top, bottom, unsuitable, suitable])
    guard case .candidates(let candidates) = result else { Issue.record("expected candidate"); return }
    #expect(candidates.count == 1)
    #expect(candidates[0].items.contains { $0.id == suitable.id })
    #expect(!candidates[0].items.contains { $0.id == unsuitable.id })
  }

  @Test("未指定字段保留未知说明而不补造事实")
  func reportsUnknownFacts() throws {
    let result = engine.generate(context: try context(), wardrobe: [
      try item("上装", .top), try item("下装", .bottom), try item("鞋", .shoes)
    ])
    guard case .candidates(let candidates) = result else { Issue.record("expected candidate"); return }
    #expect(candidates[0].uncertainties == [
      .someFormalityUnknown, .someWarmthUnknown, .someRainSuitabilityUnknown,
      .someWalkingSuitabilityUnknown,
    ])
  }

  @Test("候选稳定去重且最多三套")
  func isStableAndBounded() throws {
    let items = [try item("上装 A", .top), try item("上装 B", .top),
                 try item("下装 A", .bottom), try item("下装 B", .bottom),
                 try item("鞋 A", .shoes), try item("鞋 B", .shoes)]
    let forward = engine.generate(context: try context(), wardrobe: items)
    let reversed = engine.generate(context: try context(), wardrobe: Array(items.reversed()))
    #expect(forward == reversed)
    guard case .candidates(let candidates) = forward else { Issue.record("expected candidates"); return }
    #expect(candidates.count == 3)
    #expect(Set(candidates.map(\.id)).count == 3)
  }

  @Test("500件衣橱在本地预算内完成")
  func handlesLargeWardrobeWithinBudget() throws {
    var items: [WardrobeItem] = []
    for index in 0..<498 {
      items.append(try item("单品 \(index)", index.isMultiple(of: 2) ? .top : .bottom))
    }
    items.append(try item("鞋 A", .shoes))
    items.append(try item("鞋 B", .shoes))
    let clock = ContinuousClock()
    let start = clock.now
    let result = engine.generate(context: try context(), wardrobe: items)
    #expect(clock.now - start < .seconds(2))
    guard case .candidates(let candidates) = result else { Issue.record("expected candidates"); return }
    #expect(candidates.count == 3)
  }

  @Test("ViewModel读取真实仓储并在退出时清理会话") @MainActor
  func viewModelGeneratesAndClearsSession() async throws {
    let repository = RecommendationWardrobeRepositoryStub(items: [
      try item("上装", .top), try item("下装", .bottom), try item("鞋", .shoes)
    ])
    let model = RecommendationViewModel(repository: repository)
    model.requiresWalkingSuitability = false
    await model.generate(now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: "UTC")
    guard case .candidates(let candidates) = model.phase else { Issue.record("expected candidates"); return }
    #expect(candidates.count == 1)
    model.formality = .formal
    model.includesPackedItems = true
    model.clearSession()
    #expect(model.phase == .idle)
    #expect(model.formality == nil)
    #expect(!model.includesPackedItems)
  }

  @Test("迟到的旧请求不能覆盖新的推荐结果") @MainActor
  func newestRequestWins() async throws {
    let complete = [try item("上装", .top), try item("下装", .bottom), try item("鞋", .shoes)]
    let repository = RecommendationWardrobeRepositoryStub(
      items: complete, firstItems: [], firstDelay: .milliseconds(120)
    )
    let model = RecommendationViewModel(repository: repository)
    let oldRequest = Task { await model.generate(now: .now, timeZone: "UTC") }
    await repository.waitUntilFirstListStarts()
    await model.generate(now: .now, timeZone: "UTC")
    await oldRequest.value
    guard case .candidates(let candidates) = model.phase else {
      Issue.record("late empty result replaced the newer candidates")
      return
    }
    #expect(candidates.count == 1)
  }

  private func context(formality: WardrobeFormalityBand? = nil, warmth: WardrobeWarmthBand? = nil,
                       rain: Bool = false, walking: Bool = false,
                       includesPackedItems: Bool = false) throws -> RecommendationContext {
    try RecommendationContext(localDate: OutfitLocalDate("2026-09-16"), timeZone: "Asia/Shanghai",
      formality: formality, warmth: warmth, requiresRainSuitability: rain,
      requiresWalkingSuitability: walking, includesPackedItems: includesPackedItems)
  }

  private func item(_ name: String, _ category: WardrobeCategory,
                    availability: WardrobeAvailability = .wearable,
                    attributes: WardrobeAttributes = .init()) throws -> WardrobeItem {
    WardrobeItem(id: UUID(), input: try WardrobeInput(name: name, category: category,
      availability: availability, attributes: attributes), source: .wardrobe, revision: 1,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
  }
}

private actor RecommendationWardrobeRepositoryStub: WardrobeRepository {
  let items: [WardrobeItem]
  let firstItems: [WardrobeItem]?
  let firstDelay: Duration
  private var listCalls = 0
  private var firstListWaiters: [CheckedContinuation<Void, Never>] = []

  init(items: [WardrobeItem], firstItems: [WardrobeItem]? = nil, firstDelay: Duration = .zero) {
    self.items = items
    self.firstItems = firstItems
    self.firstDelay = firstDelay
  }

  func prepare() {}
  func list(_ filter: WardrobeFilter) async throws -> [WardrobeItem] {
    let call = listCalls
    listCalls += 1
    if call == 0 {
      firstListWaiters.forEach { $0.resume() }
      firstListWaiters.removeAll()
      if firstDelay > .zero { try await Task.sleep(for: firstDelay) }
      return firstItems ?? items
    }
    return items
  }

  func waitUntilFirstListStarts() async {
    if listCalls > 0 { return }
    await withCheckedContinuation { continuation in firstListWaiters.append(continuation) }
  }
  func create(id: UUID, input: WardrobeInput, source: WardrobeSource) throws -> WardrobeItem {
    throw WardrobeError.storageUnavailable
  }
  func update(id: UUID, expectedRevision: Int, input: WardrobeInput) throws -> WardrobeItem {
    throw WardrobeError.storageUnavailable
  }
  func deletionImpact(id: UUID) throws -> WardrobeDeletionImpact { throw WardrobeError.storageUnavailable }
  func delete(id: UUID, expectedRevision: Int, impact: WardrobeDeletionImpact,
              policy: WardrobeHistoryDeletionPolicy) throws { throw WardrobeError.storageUnavailable }
}
