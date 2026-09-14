import Foundation
import Testing
@testable import ThenApp

@Suite("衣物单件图复核")
struct WardrobePhotoReviewTests {
  private func photo() throws -> WardrobePreparedPhoto {
    // Domain-only data, never presented as an encoded-image or Vision validation fixture.
    let image = try WardrobeEncodedImage(bytes: Data([1]), format: .png, width: 1, height: 1, maximumBytes: 1)
    return .init(normalized: image, thumbnail: image)
  }
  private var confirmation: WardrobePhotoConfirmation {
    .init(subject: .singleGarment, ownedByUser: true, noPersonInImage: true, mainItemIsComplete: true)
  }

  @Test("零检出仍需当前单件确认，重试复用照片命令 ID")
  func explicitConfirmation() throws {
    var review = WardrobePhotoReview()
    let id = review.beginSelection()
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.write(for: id) }
    try review.receive(photo(), for: id)
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.confirm(confirmation, for: id) }
    try review.analyze(.init(people: 0, faces: 0), for: id)
    #expect(review.phase == .needsConfirmation)
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.write(for: id) }
    try review.confirm(confirmation, for: id)
    let first = try review.write(for: id)
    #expect(first == (try review.write(for: id)))
    #expect(first.id != first.thumbnailID)
    #expect(first.quality == .catalogReady)
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.confirm(confirmation, for: id) }
    #expect(first == (try review.write(for: id)))
  }

  @Test("任一确认缺失不能保存", arguments: 0..<4)
  func missingConfirmation(_ missing: Int) throws {
    var review = WardrobePhotoReview()
    let id = review.beginSelection()
    try review.receive(photo(), for: id)
    try review.analyze(.init(people: 0, faces: 0), for: id)
    let incomplete = WardrobePhotoConfirmation(subject: missing == 0 ? nil : .singleGarment,
      ownedByUser: missing != 1, noPersonInImage: missing != 2, mainItemIsComplete: missing != 3)
    #expect(throws: WardrobePhotoReview.Failure.confirmationRequired) { try review.confirm(incomplete, for: id) }
    #expect(review.phase == .needsConfirmation)
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.write(for: id) }
  }

  @Test("允许用户明确一双鞋，但不把实例数量当成衣物数量")
  func shoePair() throws {
    var review = WardrobePhotoReview()
    let id = review.beginSelection()
    try review.receive(photo(), for: id)
    try review.analyze(.init(people: 0, faces: 0), for: id)
    try review.confirm(.init(subject: .pairOfShoes, ownedByUser: true, noPersonInImage: true, mainItemIsComplete: true), for: id)
    #expect(review.phase == .confirmed)
  }

  @Test("人物或面部任一检出均拒绝，清空候选", arguments: [(1, 0), (0, 1), (2, 3)])
  func personDetected(_ counts: (Int, Int)) throws {
    var review = WardrobePhotoReview()
    let id = review.beginSelection()
    try review.receive(photo(), for: id)
    try review.analyze(.init(people: counts.0, faces: counts.1), for: id)
    #expect(review.phase == .rejected(.personDetected))
    #expect(review.preview == nil)
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.confirm(confirmation, for: id) }
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.write(for: id) }
  }

  @Test("检测失败不等于零检出，不能用人工确认绕过")
  func analysisFailure() throws {
    var review = WardrobePhotoReview()
    let id = review.beginSelection()
    try review.receive(photo(), for: id)
    try review.failAnalysis(for: id)
    #expect(review.phase == .rejected(.analysisUnavailable))
    #expect(review.preview == nil)
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.analyze(.init(people: 0, faces: 0), for: id) }
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.confirm(confirmation, for: id) }
  }

  @Test("换图使旧同意与迟到结果失效", arguments: [false, true])
  func replacement(_ confirmed: Bool) throws {
    var review = WardrobePhotoReview()
    let old = review.beginSelection()
    try review.receive(photo(), for: old)
    if confirmed {
      try review.analyze(.init(people: 0, faces: 0), for: old)
      try review.confirm(confirmation, for: old)
    }
    let current = review.beginSelection()
    #expect(current != old)
    #expect(review.preview == nil)
    #expect(throws: WardrobePhotoReview.Failure.staleSelection) { try review.analyze(.init(people: 0, faces: 0), for: old) }
    #expect(throws: WardrobePhotoReview.Failure.staleSelection) { try review.failInput(for: old) }
    #expect(throws: WardrobePhotoReview.Failure.staleSelection) { try review.confirm(confirmation, for: old) }
    #expect(throws: WardrobePhotoReview.Failure.staleSelection) { try review.write(for: old) }
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.write(for: current) }
    #expect(review.phase == .loading)
    try review.receive(photo(), for: current)
    try review.analyze(.init(people: 0, faces: 0), for: current)
    #expect(review.phase == .needsConfirmation)
  }

  @Test("取消与接收失败不保留候选")
  func cancellationAndInputFailure() throws {
    var review = WardrobePhotoReview()
    let failed = review.beginSelection()
    try review.failInput(for: failed)
    #expect(review.phase == .rejected(.inputUnavailable))
    #expect(throws: WardrobePhotoReview.Failure.notReady) { try review.receive(photo(), for: failed) }
    let cancelled = review.beginSelection()
    try review.receive(photo(), for: cancelled)
    review.cancel()
    #expect(review.phase == .empty)
    #expect(review.selectionID == nil && review.preview == nil)
    #expect(throws: WardrobePhotoReview.Failure.staleSelection) { try review.analyze(.init(people: 0, faces: 0), for: cancelled) }
  }

  @Test("非法检测计数不进入复核", arguments: [(-1, 0), (0, -1)])
  func invalidCounts(_ counts: (Int, Int)) {
    #expect(throws: WardrobePhotoReview.Failure.invalidObservations) {
      try WardrobePhotoPersonObservations(people: counts.0, faces: counts.1)
    }
  }
}
