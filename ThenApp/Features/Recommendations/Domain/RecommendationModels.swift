import Foundation

nonisolated struct RecommendationContext: Equatable, Sendable {
  let localDate: OutfitLocalDate
  let timeZone: String
  let formality: WardrobeFormalityBand?
  let warmth: WardrobeWarmthBand?
  let requiresRainSuitability: Bool
  let requiresWalkingSuitability: Bool
  let includesPackedItems: Bool

  init(localDate: OutfitLocalDate, timeZone: String, formality: WardrobeFormalityBand? = nil,
       warmth: WardrobeWarmthBand? = nil, requiresRainSuitability: Bool = false,
       requiresWalkingSuitability: Bool = false, includesPackedItems: Bool = false) throws {
    _ = try OutfitLocalDate.zone(timeZone)
    self.localDate = localDate
    self.timeZone = timeZone
    self.formality = formality
    self.warmth = warmth
    self.requiresRainSuitability = requiresRainSuitability
    self.requiresWalkingSuitability = requiresWalkingSuitability
    self.includesPackedItems = includesPackedItems
  }
}

nonisolated enum RecommendationReasonCode: String, Sendable {
  case realAvailableItems
  case completeSeparatePath
  case completeOnePiecePath
  case confirmedFormality
  case confirmedWarmth
  case confirmedRainShoes
  case confirmedWalkingShoes
}

nonisolated struct RecommendationReason: Equatable, Sendable {
  let code: RecommendationReasonCode
}

nonisolated enum RecommendationUncertaintyCode: String, Sendable {
  case someFormalityUnknown
  case someWarmthUnknown
  case someRainSuitabilityUnknown
  case someWalkingSuitabilityUnknown
}

nonisolated enum RecommendationGapCode: String, Sendable {
  case noAvailableItems
  case missingTopOrOnePiece
  case missingBottomForTop
  case missingShoes
  case confirmedConstraintsConflict
}

nonisolated struct RecommendationCandidate: Identifiable, Equatable, Sendable {
  let items: [WardrobeItem]
  let reasons: [RecommendationReason]
  let uncertainties: [RecommendationUncertaintyCode]

  var id: String { items.map { $0.id.uuidString.lowercased() }.joined(separator: ":") }
}

nonisolated enum RecommendationResult: Equatable, Sendable {
  case candidates([RecommendationCandidate])
  case noSolution(RecommendationGapCode)
}

nonisolated struct LocalRecommendationEngine: Sendable {
  static let policyVersion = "local-hard-constraints-v1"

  func generate(context: RecommendationContext, wardrobe: [WardrobeItem]) -> RecommendationResult {
    let available = wardrobe
      .filter { item in
        item.input.availability == .wearable
          || (context.includesPackedItems && item.input.availability == .packed)
      }
      .sorted { $0.id.uuidString < $1.id.uuidString }

    guard !available.isEmpty else { return .noSolution(.noAvailableItems) }
    if let gap = completePathGap(in: available) { return .noSolution(gap) }

    let eligible = available.filter { satisfiesCoreConstraints($0, context: context) }
    let tops = eligible.filter { $0.input.category == .top }
    let bottoms = eligible.filter { $0.input.category == .bottom }
    let onePieces = eligible.filter { $0.input.category == .onePiece }
    let shoes = eligible.filter { shoe in
      guard shoe.input.category == .shoes else { return false }
      if context.requiresRainSuitability && shoe.input.attributes.rainUse != .suitable { return false }
      if context.requiresWalkingSuitability && shoe.input.attributes.walkingUse != .suitable { return false }
      return true
    }

    var candidates: [RecommendationCandidate] = []
    appendOnePieceCandidates(onePieces: onePieces, shoes: shoes, context: context, to: &candidates)
    appendSeparateCandidates(tops: tops, bottoms: bottoms, shoes: shoes, context: context, to: &candidates)
    guard !candidates.isEmpty else { return .noSolution(.confirmedConstraintsConflict) }
    return .candidates(Array(candidates.prefix(3)))
  }

  private func completePathGap(in items: [WardrobeItem]) -> RecommendationGapCode? {
    let categories = Set(items.map(\.input.category))
    guard categories.contains(.shoes) else { return .missingShoes }
    if categories.contains(.onePiece) { return nil }
    guard categories.contains(.top) else { return .missingTopOrOnePiece }
    guard categories.contains(.bottom) else { return .missingBottomForTop }
    return nil
  }

  private func satisfiesCoreConstraints(_ item: WardrobeItem, context: RecommendationContext) -> Bool {
    if let formality = context.formality, item.input.attributes.formalityBand != formality { return false }
    if let warmth = context.warmth, item.input.attributes.warmthBand != warmth { return false }
    return true
  }

  private func appendOnePieceCandidates(onePieces: [WardrobeItem], shoes: [WardrobeItem],
                                        context: RecommendationContext,
                                        to candidates: inout [RecommendationCandidate]) {
    for onePiece in onePieces {
      for shoe in shoes {
        candidates.append(candidate(items: [onePiece, shoe], path: .completeOnePiecePath, context: context))
        if candidates.count == 3 { return }
      }
    }
  }

  private func appendSeparateCandidates(tops: [WardrobeItem], bottoms: [WardrobeItem], shoes: [WardrobeItem],
                                        context: RecommendationContext,
                                        to candidates: inout [RecommendationCandidate]) {
    guard candidates.count < 3 else { return }
    for top in tops {
      for bottom in bottoms {
        for shoe in shoes {
          candidates.append(candidate(items: [top, bottom, shoe], path: .completeSeparatePath, context: context))
          if candidates.count == 3 { return }
        }
      }
    }
  }

  private func candidate(items: [WardrobeItem], path: RecommendationReasonCode,
                         context: RecommendationContext) -> RecommendationCandidate {
    var reasons = [RecommendationReason(code: .realAvailableItems), RecommendationReason(code: path)]
    if context.formality != nil { reasons.append(.init(code: .confirmedFormality)) }
    if context.warmth != nil { reasons.append(.init(code: .confirmedWarmth)) }
    if context.requiresRainSuitability { reasons.append(.init(code: .confirmedRainShoes)) }
    if context.requiresWalkingSuitability { reasons.append(.init(code: .confirmedWalkingShoes)) }

    var uncertainties: [RecommendationUncertaintyCode] = []
    if context.formality == nil && items.contains(where: { $0.input.attributes.formalityBand == nil }) {
      uncertainties.append(.someFormalityUnknown)
    }
    if context.warmth == nil && items.contains(where: { $0.input.attributes.warmthBand == nil }) {
      uncertainties.append(.someWarmthUnknown)
    }
    if !context.requiresRainSuitability && items.contains(where: { $0.input.attributes.rainUse == nil }) {
      uncertainties.append(.someRainSuitabilityUnknown)
    }
    if !context.requiresWalkingSuitability && items.contains(where: { $0.input.attributes.walkingUse == nil }) {
      uncertainties.append(.someWalkingSuitabilityUnknown)
    }
    return RecommendationCandidate(items: items, reasons: reasons, uncertainties: uncertainties)
  }
}
