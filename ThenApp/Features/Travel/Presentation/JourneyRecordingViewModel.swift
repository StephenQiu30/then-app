import Foundation
import Observation

@MainActor
@Observable
final class JourneyRecordingViewModel {
  private let service: JourneyRecordingService
  private let initialPlan: TripPlanSummary?

  var journey: JourneySnapshot?
  var isWorking = false
  var errorMessage: LocalizedStringResource?

  init(service: JourneyRecordingService, initialPlan: TripPlanSummary?) {
    self.service = service
    self.initialPlan = initialPlan
  }

  var canStart: Bool { journey == nil }

  func load() async {
    await perform { try await service.currentJourney() }
  }

  func start() async {
    await perform {
      try await service.start(
        tripPlanID: initialPlan?.id,
        transportMode: initialPlan?.transportMode ?? .walking
      )
    }
  }

  func pause() async {
    guard let journey else { return }
    await perform { try await service.pause(journeyID: journey.id) }
  }

  func resume() async {
    guard let journey else { return }
    await perform { try await service.resume(journeyID: journey.id) }
  }

  func end() async {
    guard let journey else { return }
    await perform { try await service.end(journeyID: journey.id) }
  }

  func retryFinalization() async {
    guard let journey else { return }
    await perform { try await service.retryFinalization(journeyID: journey.id) }
  }

  func confirm() async {
    guard let journey else { return }
    await perform { try await service.confirm(journeyID: journey.id) }
  }

  func discard() async {
    guard let journey else { return }
    await perform { try await service.discard(journeyID: journey.id) }
  }

  private func perform(_ operation: () async throws -> JourneySnapshot?) async {
    isWorking = true
    errorMessage = nil
    do {
      journey = try await operation()
    } catch JourneyRecordingError.activeJourneyExists {
      journey = try? await service.currentJourney()
      errorMessage = "已有未结束行程，请先恢复、完成或丢弃。"
    } catch JourneyRecordingError.locationStartFailed {
      journey = try? await service.currentJourney()
      errorMessage = "行程已安全保存，但定位未能开始。可以检查权限后继续，或保存无轨迹摘要。"
    } catch {
      do {
        if let recovered = try await service.currentJourney() { journey = recovered }
      } catch {}
      errorMessage = "行程操作失败，已有数据没有被静默删除。"
    }
    isWorking = false
  }
}
