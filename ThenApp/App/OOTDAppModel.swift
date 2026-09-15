import Observation

@MainActor @Observable
final class OOTDAppModel {
  enum Phase { case starting, ready, failed }
  private let repository: any WardrobeRepository & WardrobePhotoRepository & OutfitPlanRepository
  let wardrobe: WardrobeViewModel
  let outfits: OutfitPlanViewModel
  let recommendations: RecommendationViewModel
  private(set) var phase: Phase = .starting
  private(set) var error: WardrobeError?
  private(set) var attempt = 0

  init(repository: any WardrobeRepository & WardrobePhotoRepository & OutfitPlanRepository,
       wearEvents: (any WearEventRepository)? = nil, feedback: (any OutfitFeedbackRepository)? = nil) {
    self.repository = repository
    wardrobe = WardrobeViewModel(repository: repository, wearEvents: wearEvents)
    outfits = OutfitPlanViewModel(repository: repository, wardrobe: repository, photos: repository,
      wearEvents: wearEvents, feedback: feedback)
    recommendations = RecommendationViewModel(repository: repository)
  }

  func requestRetry() {
    guard phase == .failed else { return }
    phase = .starting
    attempt += 1
  }

  func start() async {
    guard phase == .starting else { return }
    do {
      try await repository.prepare()
      try await wardrobe.load()
      try Task.checkCancellation()
      error = nil
      phase = .ready
    } catch is CancellationError {
      // The view owns this task and restarts it when it reappears.
    } catch {
      self.error = error as? WardrobeError ?? .storageUnavailable
      phase = .failed
    }
  }
}
