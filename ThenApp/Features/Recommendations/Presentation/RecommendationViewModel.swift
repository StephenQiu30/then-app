import Foundation
import Observation

@MainActor @Observable
final class RecommendationViewModel {
  enum Phase: Equatable {
    case idle
    case loading
    case candidates([RecommendationCandidate])
    case noSolution(RecommendationGapCode)
    case failed
  }

  private let repository: any WardrobeRepository
  private let engine: LocalRecommendationEngine
  private var request = 0

  var formality: WardrobeFormalityBand?
  var warmth: WardrobeWarmthBand?
  var requiresRainSuitability = false
  var requiresWalkingSuitability = false
  var includesPackedItems = false
  private(set) var phase: Phase = .idle

  init(repository: any WardrobeRepository, engine: LocalRecommendationEngine = .init()) {
    self.repository = repository
    self.engine = engine
  }

  func generate(now: Date = .now, timeZone: String = TimeZone.current.identifier) async {
    request += 1
    let currentRequest = request
    phase = .loading
    do {
      let context = try RecommendationContext(
        localDate: OutfitLocalDate(instant: now, timeZone: timeZone),
        timeZone: timeZone,
        formality: formality,
        warmth: warmth,
        requiresRainSuitability: requiresRainSuitability,
        requiresWalkingSuitability: requiresWalkingSuitability,
        includesPackedItems: includesPackedItems
      )
      let wardrobe = try await repository.list(.init(availability: nil))
      try Task.checkCancellation()
      guard currentRequest == request else { return }
      switch engine.generate(context: context, wardrobe: wardrobe) {
      case .candidates(let candidates): phase = .candidates(candidates)
      case .noSolution(let gap): phase = .noSolution(gap)
      }
    } catch is CancellationError {
      if currentRequest == request { phase = .idle }
    } catch {
      if currentRequest == request { phase = .failed }
    }
  }

  func clearSession() {
    request += 1
    formality = nil
    warmth = nil
    requiresRainSuitability = false
    requiresWalkingSuitability = false
    includesPackedItems = false
    phase = .idle
  }
}
