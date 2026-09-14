import CoreTransferable
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import ThenApp

@Suite("衣物系统选图交接", .serialized)
struct SystemWardrobePhotoPickerTests {
  typealias Picker = SystemWardrobePhotoPicker

  private func limits(bytes: Int = 1_000_000) throws -> ImageIOWardrobePhotoPreparer.Limits {
    try .init(inputBytes: bytes, sourcePixels: 4096, normalizedDimension: 32, thumbnailDimension: 8,
              rasterBytes: 4096, normalizedBytes: 100_000, thumbnailBytes: 100_000, duration: .seconds(5))
  }
  private func picker(timeout: Duration = .seconds(5), bytes: Int = 1_000_000) throws -> Picker {
    try .init(limits: limits(bytes: bytes), transferTimeout: timeout)
  }
  private func withFile(format: WardrobePhotoSourceFormat = .png,
                        body: (URL, Data) async throws -> Void) async throws {
    let directory = try #require(Bundle(for: WardrobePickerFixtureBundle.self).url(forResource: "AvatarPhotoIntake", withExtension: nil))
    let suffix = switch format { case .png: "png"; case .jpeg: "jpeg"; case .heic: "heic" }
    let source = try Data(contentsOf: directory.appendingPathComponent("metadata-\(suffix).fixture"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer {
      do { try FileManager.default.removeItem(at: root) }
      catch { Issue.record("Could not clean owned picker fixture") }
    }
    let file = root.appendingPathComponent("source.fixture")
    try source.write(to: file)
    try await body(file, source)
    #expect(try Data(contentsOf: file) == source)
    let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(children == ["source.fixture"])
  }

  @Test("真实 FileRepresentation 三种格式交付净化结果且源由 provider 管理", arguments: [
    WardrobePhotoSourceFormat.png, .jpeg, .heic])
  func realRepresentation(_ format: WardrobePhotoSourceFormat) async throws {
    try await withFile(format: format) { file, _ in
      let type = try #require(UTType(format.rawValue))
      let loader = ControlledWardrobeLoader(contentTypes: [type])
      let picker = try picker()
      try await withThrowingTaskGroup(of: WardrobePreparedPhoto.self) { group in
        group.addTask { try await picker.load(using: loader) }
        await loader.started.wait()
        let operation = try #require(loader.operation)
        let token = try await WardrobePhotoTransferScope.$current.withValue(operation) {
          try await WardrobePhotoTransferredFile(importing: file, contentType: type)
        }
        loader.finish(.success(token))
        let output = try #require(try await group.next())
        #expect(output.normalized.width == 16 && output.normalized.height == 32)
        #expect(output.thumbnail.width == 4 && output.thumbnail.height == 8)
        #expect(output.normalized.bytes.range(of: Data("SYNTHETIC".utf8)) == nil)
        #expect(!loader.progress.isCancelled)
        // A later cancellation cannot take back the caller's value.
        operation.cancel()
        #expect(output.normalized.bytes.count > 0)
      }
    }
  }

  @Test("nil 和同步 provider 错误映射为可恢复输入失败", arguments: [false, true])
  func synchronousFailure(_ isError: Bool) async throws {
    let loader = ControlledWardrobeLoader(onStart: { _, completion in
      completion(isError ? .failure(WardrobePickerProbeError.provider) : .success(nil))
    })
    await #expect(throws: Picker.Failure.sourceUnavailable) { try await picker().load(using: loader) }
    // A callback may arrive before start returns its Progress.
    #expect(loader.progress.isCancelled)
  }

  @Test("不支持的类型与非法时限在启动 provider 前拒绝")
  func inputAdmission() async throws {
    let loader = ControlledWardrobeLoader(contentTypes: [.gif])
    await #expect(throws: Picker.Failure.unsupportedFormat) { try await picker().load(using: loader) }
    #expect(loader.operation == nil)
    #expect(throws: Picker.Failure.resourceLimitExceeded) { try picker(timeout: .zero) }
  }

  @Test("调用方提前取消不启动 provider")
  func preCancelled() async throws {
    let loader = ControlledWardrobeLoader()
    let picker = try picker()
    await withTaskGroup(of: Void.self) { group in
      group.cancelAll()
      group.addTask {
        await #expect(throws: CancellationError.self) { try await picker.load(using: loader) }
      }
    }
    #expect(loader.operation == nil)
  }

  @Test("等待期间取消会结束 continuation，迟到成功不能交付", arguments: [false, true])
  func cancellation(_ prepared: Bool) async throws {
    try await withFile { file, _ in
      let loader = ControlledWardrobeLoader()
      let picker = try picker()
      try await withThrowingTaskGroup(of: WardrobePreparedPhoto.self) { group in
        group.addTask { try await picker.load(using: loader) }
        await loader.started.wait()
        let operation = try #require(loader.operation)
        let token: WardrobePhotoTransferredFile
        if prepared { token = try await operation.prepare(from: file, format: .png) }
        else { token = .init(operationID: operation.id) }
        group.cancelAll()
        do { _ = try await group.next(); Issue.record("Cancelled selection delivered") }
        catch { #expect(error is CancellationError) }
        #expect(loader.progress.isCancelled)
        loader.finish(.success(token))
        loader.finish(.failure(WardrobePickerProbeError.provider))
        await #expect(throws: CancellationError.self) { try await operation.prepare(from: file, format: .png) }
      }
    }
  }

  @Test("同步取消发生在 Progress 返回前仍向 provider 传播")
  func synchronousCancellation() async throws {
    let loader = ControlledWardrobeLoader(onStart: { operation, _ in operation.cancel() })
    await #expect(throws: CancellationError.self) { try await picker().load(using: loader) }
    #expect(loader.progress.isCancelled)
  }

  @Test("无 provider 回调时总时限结束，不等待永远悬挂的 continuation")
  func timeout() async throws {
    let loader = ControlledWardrobeLoader()
    await #expect(throws: Picker.Failure.timedOut) { try await picker(timeout: .milliseconds(50)).load(using: loader) }
    #expect(loader.progress.isCancelled)
    let operation = try #require(loader.operation)
    loader.finish(.success(.init(operationID: operation.id)))
  }

  @Test("重复回调仅交付一次，每次 operation 只处理一份文件")
  func duplicateCallbacks() async throws {
    try await withFile { file, _ in
      let loader = ControlledWardrobeLoader()
      let picker = try picker()
      try await withThrowingTaskGroup(of: WardrobePreparedPhoto.self) { group in
        group.addTask { try await picker.load(using: loader) }
        await loader.started.wait()
        let operation = try #require(loader.operation)
        let token = try await operation.prepare(from: file, format: .png)
        await #expect(throws: Picker.Failure.invalidTransferContext) { try await operation.prepare(from: file, format: .png) }
        loader.finish(.success(token))
        loader.finish(.success(token))
        loader.finish(.failure(WardrobePickerProbeError.provider))
        let output = try #require(try await group.next())
        #expect(output.normalized.width == 16)
        #expect(try await group.next() == nil)
      }
    }
  }

  @Test("伪造结果或跨 operation token 无法交付", arguments: [false, true])
  func unownedResult(_ forgedOwner: Bool) async throws {
    let loader = ControlledWardrobeLoader()
    let picker = try picker()
    try await withThrowingTaskGroup(of: WardrobePreparedPhoto.self) { group in
      group.addTask { try await picker.load(using: loader) }
      await loader.started.wait()
      let operation = try #require(loader.operation)
      loader.finish(.success(.init(operationID: forgedOwner ? UUID() : operation.id)))
      do { _ = try await group.next(); Issue.record("Unprepared result delivered") }
      catch { #expect(error as? Picker.Failure == .invalidTransferContext) }
      #expect(loader.progress.isCancelled)
    }
  }

  @Test("格式或预算真实错误优先于 provider 包装错误", arguments: [false, true])
  func wrappedPreparationError(_ budget: Bool) async throws {
    try await withFile { file, _ in
      let loader = ControlledWardrobeLoader()
      let picker = try picker(bytes: budget ? 1 : 1_000_000)
      try await withThrowingTaskGroup(of: WardrobePreparedPhoto.self) { group in
        group.addTask { try await picker.load(using: loader) }
        await loader.started.wait()
        let operation = try #require(loader.operation)
        do {
          _ = try await operation.prepare(from: file, format: budget ? .png : .jpeg)
          Issue.record("Bad preparation succeeded")
        } catch { loader.finish(.failure(WardrobePickerProbeError.provider)) }
        do { _ = try await group.next(); Issue.record("Failed preparation delivered") }
        catch { #expect(error as? Picker.Failure == (budget ? .resourceLimitExceeded : .unsafeOrCorruptInput)) }
      }
    }
  }

  @Test("缺少绑定上下文不能从系统文件表示得到 token")
  func missingContext() async throws {
    try await withFile { file, _ in
      await #expect(throws: (any Error).self) {
        try await WardrobePhotoTransferredFile(importing: file, contentType: .png)
      }
    }
  }
  @Test("并行选择不能交付彼此 token，错误选择不取消有效选择")
  func concurrentSelections() async throws {
    try await withFile { file, _ in
      let first = ControlledWardrobeLoader(), second = ControlledWardrobeLoader()
      let picker = try picker()
      try await withThrowingTaskGroup(of: Int.self) { group in
        group.addTask {
          do { _ = try await picker.load(using: first); Issue.record("Cross-selection token delivered") }
          catch { #expect(error as? Picker.Failure == .invalidTransferContext) }
          return 1
        }
        group.addTask {
          let output = try await picker.load(using: second)
          #expect(output.normalized.width == 16 && output.thumbnail.height == 8)
          return 2
        }
        await first.started.wait()
        await second.started.wait()
        let firstOperation = try #require(first.operation)
        let secondOperation = try #require(second.operation)
        _ = try await firstOperation.prepare(from: file, format: .png)
        let token = try await secondOperation.prepare(from: file, format: .png)
        first.finish(.success(token))
        second.finish(.success(token))
        var finished: Set<Int> = []
        for try await value in group { finished.insert(value) }
        #expect(finished == [1, 2])
        #expect(first.progress.isCancelled)
        #expect(!second.progress.isCancelled)
      }
    }
  }
}

nonisolated private enum WardrobePickerProbeError: Error { case provider }
nonisolated private final class ControlledWardrobeLoader: WardrobePhotoTransferLoading {
  typealias Completion = @Sendable (Result<WardrobePhotoTransferredFile?, any Error>) -> Void
  let contentTypes: [UTType]
  let progress = Progress(totalUnitCount: 1)
  let started = WardrobePickerSignal()
  private let state = Mutex<(WardrobePhotoTransferOperation?, Completion?)>((nil, nil))
  private let onStart: @Sendable (WardrobePhotoTransferOperation, Completion) -> Void
  init(contentTypes: [UTType] = [.png], onStart: @escaping @Sendable (WardrobePhotoTransferOperation, Completion) -> Void = { _, _ in }) {
    self.contentTypes = contentTypes
    self.onStart = onStart
  }
  var operation: WardrobePhotoTransferOperation? { state.withLock { $0.0 } }
  func start(operation: WardrobePhotoTransferOperation, completion: @escaping Completion) -> Progress {
    state.withLock { $0 = (operation, completion) }
    onStart(operation, completion)
    started.signal()
    return progress
  }
  func finish(_ result: Result<WardrobePhotoTransferredFile?, any Error>) {
    let completion = state.withLock { $0.1 }
    completion?(result)
  }
}
nonisolated private final class WardrobePickerSignal: Sendable {
  private let state = Mutex<(Bool, [CheckedContinuation<Void, Never>])>((false, []))
  func wait() async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state in
        if state.0 { return true }
        state.1.append(continuation)
        return false
      }
      if ready { continuation.resume() }
    }
  }
  func signal() {
    let pending = state.withLock { state in
      state.0 = true
      let pending = state.1
      state.1 = []
      return pending
    }
    for continuation in pending { continuation.resume() }
  }
}
private final class WardrobePickerFixtureBundle: NSObject {}
