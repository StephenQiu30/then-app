import Foundation
import GRDB

nonisolated protocol ProtectedFileManaging: Sendable {
  var temporaryDirectory: URL { get }

  func createDirectory(
    at url: URL,
    withIntermediateDirectories createIntermediates: Bool,
    attributes: [FileAttributeKey: Any]?
  ) throws

  func setAttributes(
    _ attributes: [FileAttributeKey: Any],
    ofItemAtPath path: String
  ) throws

  func removeItem(at url: URL) throws
  func fileExists(atPath path: String) -> Bool
  func contentsOfDirectory(
    at url: URL,
    includingPropertiesForKeys keys: [URLResourceKey]?,
    options mask: FileManager.DirectoryEnumerationOptions
  ) throws -> [URL]
  func write(
    _ data: Data,
    to url: URL,
    options: Data.WritingOptions
  ) throws
}

nonisolated final class SystemProtectedFileManager: ProtectedFileManaging, @unchecked Sendable {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
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
  }

  func setAttributes(
    _ attributes: [FileAttributeKey: Any],
    ofItemAtPath path: String
  ) throws {
    try fileManager.setAttributes(attributes, ofItemAtPath: path)
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
    try data.write(to: url, options: options)
  }
}

nonisolated struct AppDatabase: Sendable {
  let pool: DatabasePool

  init(pool: DatabasePool) throws {
    self.pool = pool
    try DatabaseMigrations.migrate(pool)
  }

  static func make(at databaseURL: URL) throws -> AppDatabase {
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    var configuration = Configuration()
    configuration.label = "ThenApp.Database"
    configuration.journalMode = .wal
    configuration.busyMode = .timeout(5)

    let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
    return try AppDatabase(pool: pool)
  }

  static func makeProtected(
    at databaseURL: URL,
    fileManager: any ProtectedFileManaging = SystemProtectedFileManager()
  ) throws -> AppDatabase {
    let databaseDirectoryURL = databaseURL.deletingLastPathComponent()
    let protection = FileProtectionType.completeUntilFirstUserAuthentication
    try fileManager.createDirectory(
      at: databaseDirectoryURL,
      withIntermediateDirectories: true,
      attributes: [.protectionKey: protection]
    )
    try fileManager.setAttributes(
      [.protectionKey: protection],
      ofItemAtPath: databaseDirectoryURL.path
    )

    let database = try make(at: databaseURL)
    for protectedURL in databaseFileURLs(for: databaseURL)
    where fileManager.fileExists(atPath: protectedURL.path) {
      try fileManager.setAttributes(
        [.protectionKey: protection],
        ofItemAtPath: protectedURL.path
      )
    }
    return database
  }

  static func makeProduction() throws -> AppDatabase {
    let fileManager = SystemProtectedFileManager()
    let systemFileManager = FileManager.default
    guard
      let applicationSupportURL = systemFileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw AppDatabaseError.applicationSupportDirectoryUnavailable
    }

    let databaseDirectoryURL = applicationSupportURL.appending(
      path: "ThenApp",
      directoryHint: .isDirectory
    )
    let databaseURL = databaseDirectoryURL.appending(path: "then.sqlite")
    return try makeProtected(at: databaseURL, fileManager: fileManager)
  }

  #if DEBUG
    static func makeUITesting(storageID: UUID) throws -> AppDatabase {
      let fileManager = SystemProtectedFileManager()
      let systemFileManager = FileManager.default
      guard
        let applicationSupportURL = systemFileManager.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        ).first
      else {
        throw AppDatabaseError.applicationSupportDirectoryUnavailable
      }

      let databaseURL =
        applicationSupportURL
        .appending(path: "ThenAppUITests", directoryHint: .isDirectory)
        .appending(path: storageID.uuidString, directoryHint: .isDirectory)
        .appending(path: "then.sqlite")
      return try makeProtected(at: databaseURL)
    }
  #endif

  private static func databaseFileURLs(for databaseURL: URL) -> [URL] {
    [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
    ]
  }
}

nonisolated enum AppDatabaseError: Error, Equatable {
  case applicationSupportDirectoryUnavailable
  case invalidUITestStorageID
}
