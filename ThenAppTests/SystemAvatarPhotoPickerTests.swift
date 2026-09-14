import CoreTransferable
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import ThenApp

@Suite("照片 POC 系统传输所有权", .timeLimit(.minutes(1)))
struct SystemAvatarPhotoPickerTests {
  private typealias Picker = SystemAvatarPhotoPicker
  private typealias Store = AvatarPhotoTemporarySessionStore

  private func limits() throws -> ImageIOAvatarPhotoSanitizer.Limits {
    try .init(maximumInputBytes: 1_000_000, maximumSourcePixels: 4096,
      maximumOutputDimension: 32, maximumRasterBytes: 4096,
      maximumOutputBytes: 100_000, maximumDuration: .seconds(5))
  }

  private func withFiles(_ format: AvatarPhotoInputFormat = .png,
                         body: (URL, URL, Data) async throws -> Void) async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .standardizedFileURL.resolvingSymlinksInPath()
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    defer {
      do { try manager.removeItem(at: root) }
      catch { Issue.record("Synthetic picker test cleanup failed") }
    }
    let fixtures: URL
    if let path = ProcessInfo.processInfo.environment["THEN_AVATAR_FIXTURE_DIRECTORY"] {
      fixtures = URL(fileURLWithPath: path)
    } else {
      fixtures = try #require(Bundle(for: PickerFixtureBundle.self)
        .url(forResource: "AvatarPhotoIntake", withExtension: nil))
    }
    let name = switch format { case .png: "png"; case .jpeg: "jpeg"; case .heic: "heic" }
    let bytes = try Data(contentsOf: fixtures.appendingPathComponent("metadata-\(name).fixture"))
    let source = root.appendingPathComponent("SYNTHETIC-system-source")
    try bytes.write(to: source)
    let container = root.appendingPathComponent("private", isDirectory: true)
    try manager.createDirectory(at: container, withIntermediateDirectories: false)
    try await body(container, source, bytes)
    #expect(try Data(contentsOf: source) == bytes)
  }

  private func expectEmpty(_ container: URL) throws {
    let root = container.appendingPathComponent(Store.directoryName)
    if FileManager.default.fileExists(atPath: root.path) {
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    } else {
      #expect(try FileManager.default.contentsOfDirectory(atPath: container.path).isEmpty)
    }
  }

  @Test("声明和预取消在系统加载前拒绝", arguments: [false, true])
  func preconditions(cancelled: Bool) async throws {
    try await withFiles { container, _, _ in
      let loader = ControlledPhotoLoader()
      let picker = try Picker(store: Store(container: container), limits: limits())
      if cancelled {
        await #expect(throws: CancellationError.self) {
          try await withThrowingTaskGroup(of: AvatarPhotoInputHandle.self) { group in
            group.cancelAll()
            group.addTask { try await picker.load(using: loader, confirmedAdultSelf: true) }
            _ = try await group.next()
          }
        }
      } else {
        await #expect(throws: Picker.Failure.declarationRequired) {
          try await picker.load(using: loader, confirmedAdultSelf: false)
        }
      }
      #expect(loader.operation == nil)
      try expectEmpty(container)
    }
  }

  @Test("同步结束和重复回调只交付一次安全错误", arguments: [false, true])
  func inlineCompletion(failed: Bool) async throws {
    try await withFiles { container, _, _ in
      let loader = ControlledPhotoLoader { _, callback in
        callback(failed ? .failure(ProbeError.provider) : .success(nil))
        callback(.failure(ProbeError.provider))
      }
      let picker = try Picker(store: Store(container: container), limits: limits())
      await #expect(throws: Picker.Failure.sourceUnavailable) {
        try await picker.load(using: loader, confirmedAdultSelf: true)
      }
      #expect(loader.progress.isCancelled)
      try expectEmpty(container)
    }
  }

  @Test("未批准或未知系统类型在请求传输前拒绝", arguments: 0..<5)
  func unsupportedSystemTypes(kind: Int) async throws {
    try await withFiles { container, _, _ in
      let types: [[UTType]] = [[], [.tiff], [.rawImage], [.gif], [.image]]
      let loader = ControlledPhotoLoader(contentTypes: types[kind])
      let picker = try Picker(store: Store(container: container), limits: limits())
      await #expect(throws: Picker.Failure.unsupportedFormat) {
        try await picker.load(using: loader, confirmedAdultSelf: true)
      }
      #expect(loader.operation == nil)
      try expectEmpty(container)
    }
  }

  @Test("Progress 注册前取消会取消迟到 Progress 且禁止复制")
  func cancelledDuringRegistration() async throws {
    try await withFiles { container, source, _ in
      let loader = ControlledPhotoLoader { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
      let picker = try Picker(store: Store(container: container), limits: limits())
      await #expect(throws: CancellationError.self) {
        try await withThrowingTaskGroup(of: AvatarPhotoInputHandle.self) { group in
          group.addTask { try await picker.load(using: loader, confirmedAdultSelf: true) }
          _ = try await group.next()
        }
      }
      #expect(loader.progress.isCancelled)
      let operation = try #require(loader.operation)
      await #expect(throws: CancellationError.self) { try await operation.copy(from: source, format: .png) }
      loader.finish(.success(nil))
      try expectEmpty(container)
    }
  }

  @Test("系统不回调仍可取消，迟到回调不复活文件", arguments: [false, true])
  func cancellationBeforeDelivery(copyFirst: Bool) async throws {
    try await withFiles { container, source, _ in
      let loader = ControlledPhotoLoader()
      let picker = try Picker(store: Store(container: container), limits: limits())
      try await withThrowingTaskGroup(of: AvatarPhotoInputHandle.self) { group in
        group.addTask { try await picker.load(using: loader, confirmedAdultSelf: true) }
        await loader.started.wait()
        let operation = try #require(loader.operation)
        let input = copyFirst ? try await operation.copy(from: source, format: .png) : nil
        group.cancelAll()
        do { _ = try await group.next(); Issue.record("Cancelled transfer delivered a handle") }
        catch { #expect(error is CancellationError) }
        #expect(loader.progress.isCancelled)
        try expectEmpty(container)
        if let input { loader.finish(.success(.init(operationID: operation.id, input: input))) }
        else { loader.finish(.success(nil)) }
        await #expect(throws: CancellationError.self) { try await operation.copy(from: source, format: .png) }
        try expectEmpty(container)
      }
    }
  }

  @Test("合法传输交付独立私有文件，后续取消不得删除已交付结果", arguments: [
    AvatarPhotoInputFormat.png, .jpeg, .heic,
  ])
  func ownershipTransfer(format: AvatarPhotoInputFormat) async throws {
    try await withFiles(format) { container, source, bytes in
      let store = try Store(container: container)
      let loader = ControlledPhotoLoader()
      let budget = try limits()
      let picker = Picker(store: store, limits: budget)
      try await withThrowingTaskGroup(of: AvatarPhotoInputHandle.self) { group in
        group.addTask { try await picker.load(using: loader, confirmedAdultSelf: true) }
        await loader.started.wait()
        let operation = try #require(loader.operation)
        let copied = try await operation.copy(from: source, format: format)
        loader.finish(.success(.init(operationID: operation.id, input: copied)))
        let delivered = try #require(try await group.next())
        #expect(delivered == copied)
        operation.cancel()
        loader.finish(.failure(ProbeError.provider))
        let original = Store.FileReference(sessionID: delivered.sessionID, fileID: delivered.inputID, purpose: .originalImport)
        #expect(try Data(contentsOf: await store.fileURL(for: original)) == bytes)
        let clean = try await ImageIOAvatarPhotoSanitizer(store: store, limits: budget).sanitize(delivered)
        #expect(clean.width == 16 && clean.height == 32)
        try await store.removeSession(delivered.sessionID)
        try expectEmpty(container)
      }
    }
  }

  @Test("错误请求标识或伪造输入不能交付且清理自己的副本", arguments: [false, true])
  func mismatchedResult(forgedHandle: Bool) async throws {
    try await withFiles { container, source, _ in
      let loader = ControlledPhotoLoader()
      let picker = try Picker(store: Store(container: container), limits: limits())
      try await withThrowingTaskGroup(of: AvatarPhotoInputHandle.self) { group in
        group.addTask { try await picker.load(using: loader, confirmedAdultSelf: true) }
        await loader.started.wait()
        let operation = try #require(loader.operation)
        let input = try await operation.copy(from: source, format: .png)
        loader.finish(.success(.init(operationID: forgedHandle ? operation.id : UUID(),
          input: forgedHandle ? .init(sessionID: UUID(), inputID: UUID(), format: .png) : input)))
        do { _ = try await group.next(); Issue.record("Unowned result was delivered") }
        catch { #expect(error as? Picker.Failure == .invalidTransferContext) }
        try expectEmpty(container)
      }
    }
  }

  @Test("缺少工厂上下文的 Transferable 不交付文件")
  func missingContext() async throws {
    try await withFiles { container, source, _ in
      // CoreTransferable wraps representation errors; no transport handle may escape.
      await #expect(throws: (any Error).self) {
        try await AvatarPhotoTransferredFile(importing: source, contentType: .png)
      }
      try expectEmpty(container)
    }
  }

  @Test("复制进行中取消必须等待清理且清理失败优先报告", arguments: [false, true])
  func cancellationDuringCopy(failRemove: Bool) async throws {
    try await withFiles { container, source, _ in
      let loader = ControlledPhotoLoader()
      let fs = PickerFaultFileSystem(failRemove: failRemove, afterCreate: { loader.operation?.cancel() })
      let store = try Store(container: container, fileSystem: fs)
      let picker = try Picker(store: store, limits: limits())
      try await withThrowingTaskGroup(of: AvatarPhotoInputHandle.self) { group in
        group.addTask { try await picker.load(using: loader, confirmedAdultSelf: true) }
        await loader.started.wait()
        let operation = try #require(loader.operation)
        do { _ = try await operation.copy(from: source, format: .png); Issue.record("Cancelled copy succeeded") }
        catch { loader.finish(.failure(ProbeError.provider)) }
        do { _ = try await group.next(); Issue.record("Cancelled transfer delivered") }
        catch {
          if failRemove { #expect(error as? Picker.Failure == .cleanupFailed) }
          else { #expect(error is CancellationError) }
        }
      }
      #expect(loader.progress.isCancelled)
      if failRemove {
        await #expect(throws: Store.Failure.sessionsInUse) { try await store.createSession() }
        try await Store(container: container).prepareForUse()
      }
      try expectEmpty(container)
    }
  }

  @Test("系统包装错误仍保留存储和清理故障", arguments: [false, true])
  func storageFailure(failRemove: Bool) async throws {
    try await withFiles { container, source, _ in
      let store = try Store(container: container, fileSystem: PickerFaultFileSystem(failRemove: failRemove))
      let loader = ControlledPhotoLoader()
      let picker = try Picker(store: store, limits: limits())
      try await withThrowingTaskGroup(of: AvatarPhotoInputHandle.self) { group in
        group.addTask { try await picker.load(using: loader, confirmedAdultSelf: true) }
        await loader.started.wait()
        let operation = try #require(loader.operation)
        do { _ = try await operation.copy(from: source, format: .png); Issue.record("Fault was ignored") }
        catch { loader.finish(.failure(ProbeError.provider)) }
        do { _ = try await group.next(); Issue.record("Failed copy delivered a handle") }
        catch { #expect(error as? Picker.Failure == (failRemove ? .cleanupFailed : .storageUnavailable)) }
      }
      if failRemove {
        await #expect(throws: Store.Failure.sessionsInUse) { try await store.createSession() }
        try await Store(container: container).prepareForUse()
      }
      try expectEmpty(container)
    }
  }
}

nonisolated private enum ProbeError: Error { case provider }

nonisolated private final class ControlledPhotoLoader: AvatarPhotoTransferLoading, Sendable {
  typealias Completion = @Sendable (Result<AvatarPhotoTransferredFile?, any Error>) -> Void
  let progress = Progress(totalUnitCount: 1)
  let contentTypes: [UTType]
  let started = PickerSignal()
  private let registered = Mutex<(AvatarPhotoTransferOperation?, Completion?)>((nil, nil))
  private let onStart: @Sendable (AvatarPhotoTransferOperation, Completion) -> Void
  init(contentTypes: [UTType] = [.png],
       onStart: @escaping @Sendable (AvatarPhotoTransferOperation, Completion) -> Void = { _, _ in }) {
    self.contentTypes = contentTypes
    self.onStart = onStart
  }
  var operation: AvatarPhotoTransferOperation? { registered.withLock { $0.0 } }
  func start(operation: AvatarPhotoTransferOperation, completion: @escaping Completion) -> Progress {
    registered.withLock { $0 = (operation, completion) }
    onStart(operation, completion)
    started.signal()
    return progress
  }
  func finish(_ result: Result<AvatarPhotoTransferredFile?, any Error>) {
    let callback = registered.withLock { $0.1 }
    callback?(result)
  }
}

nonisolated private final class PickerSignal: Sendable {
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

nonisolated private struct PickerFaultFileSystem: AvatarPhotoSessionFileSystem {
  let failRemove: Bool
  var afterCreate: @Sendable () throws -> Void = {
    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
  }
  private let real = FoundationAvatarPhotoSessionFileSystem()
  func kind(at url: URL) throws -> AvatarPhotoSessionEntryKind { try real.kind(at: url) }
  func createProtectedDirectory(at url: URL) throws { try real.createProtectedDirectory(at: url) }
  func applyProtection(at url: URL) throws { try real.applyProtection(at: url) }
  func createProtectedFile(at url: URL) throws {
    try real.createProtectedFile(at: url)
    try afterCreate()
  }
  func children(at url: URL) throws -> [URL] { try real.children(at: url) }
  func remove(at url: URL) throws {
    if failRemove { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
    try real.remove(at: url)
  }
}

private final class PickerFixtureBundle: NSObject {}
