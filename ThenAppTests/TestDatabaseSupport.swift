import Foundation

@testable import ThenApp

func withTestDatabase(
  _ operation: (AppDatabase) throws -> Void
) throws {
  let fileManager = FileManager.default
  let directoryURL = fileManager.temporaryDirectory.appending(
    path: "ThenAppTests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  defer {
    try? fileManager.removeItem(at: directoryURL)
  }

  let database = try AppDatabase.make(at: directoryURL.appending(path: "test.sqlite"))
  try operation(database)
}

func withAsyncTestDatabase(
  _ operation: (AppDatabase) async throws -> Void
) async throws {
  let fileManager = FileManager.default
  let directoryURL = fileManager.temporaryDirectory.appending(
    path: "ThenAppTests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  defer {
    try? fileManager.removeItem(at: directoryURL)
  }

  let database = try AppDatabase.make(at: directoryURL.appending(path: "test.sqlite"))
  try await operation(database)
}

nonisolated final class RecordingFileManager: ProtectedFileManaging, @unchecked Sendable {
  enum WriteBehavior: Sendable {
    case normal
    case outOfSpaceAfterPartialFile
  }

  struct ProtectionOperation: Equatable {
    let path: String
    let protection: String?
  }

  private let operationLock = NSLock()
  private let fileManager = FileManager.default
  private let writeBehavior: WriteBehavior
  private var recordedDirectoryCreations: [ProtectionOperation] = []
  private var recordedAttributeUpdates: [ProtectionOperation] = []

  init(writeBehavior: WriteBehavior = .normal) {
    self.writeBehavior = writeBehavior
  }

  var directoryCreations: [ProtectionOperation] {
    operationLock.lock()
    defer { operationLock.unlock() }
    return recordedDirectoryCreations
  }

  var attributeUpdates: [ProtectionOperation] {
    operationLock.lock()
    defer { operationLock.unlock() }
    return recordedAttributeUpdates
  }

  var temporaryDirectory: URL {
    fileManager.temporaryDirectory
  }

  func createDirectory(
    at url: URL,
    withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]? = nil
  ) throws {
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: createIntermediates,
      attributes: attributes
    )
    let operation = ProtectionOperation(
      path: url.standardizedFileURL.path,
      protection: Self.protectionValue(in: attributes)
    )
    operationLock.lock()
    recordedDirectoryCreations.append(operation)
    operationLock.unlock()
  }

  func setAttributes(
    _ attributes: [FileAttributeKey: Any],
    ofItemAtPath path: String
  ) throws {
    try fileManager.setAttributes(attributes, ofItemAtPath: path)
    let operation = ProtectionOperation(
      path: URL(fileURLWithPath: path).standardizedFileURL.path,
      protection: Self.protectionValue(in: attributes)
    )
    operationLock.lock()
    recordedAttributeUpdates.append(operation)
    operationLock.unlock()
  }

  func removeItem(at url: URL) throws {
    try fileManager.removeItem(at: url)
  }

  func fileExists(atPath path: String) -> Bool {
    fileManager.fileExists(atPath: path)
  }

  func contentsOfDirectory(
    at url: URL,
    includingPropertiesForKeys keys: [URLResourceKey]?,
    options mask: FileManager.DirectoryEnumerationOptions
  ) throws -> [URL] {
    try fileManager.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: keys,
      options: mask
    )
  }

  func write(
    _ data: Data,
    to url: URL,
    options: Data.WritingOptions
  ) throws {
    switch writeBehavior {
    case .normal:
      try data.write(to: url, options: options)
    case .outOfSpaceAfterPartialFile:
      try Data("partial".utf8).write(to: url)
      throw CocoaError(.fileWriteOutOfSpace)
    }
  }

  private static func protectionValue(
    in attributes: [FileAttributeKey: Any]?
  ) -> String? {
    guard let value = attributes?[.protectionKey] else { return nil }
    if let protection = value as? FileProtectionType {
      return protection.rawValue
    }
    return value as? String
  }
}
