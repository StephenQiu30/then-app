import CryptoKit
import Foundation

struct AvatarValidatedAssets: Sendable {
  let resources: [String: Data]
}

enum AvatarAssetCatalogError: Error, Equatable {
  case manifestMissing
  case manifestInvalid
  case unsupportedCatalog
  case assetSetMismatch
  case unsafeFileName
  case assetMissing
  case assetInvalid
  case hashMismatch
  case budgetExceeded
}

struct AvatarAssetCatalog {
  private struct Manifest: Decodable {
    struct Rig: Decodable {
      let id: String
      let joints: [String]
      let restPose: String
    }

    struct Parameter: Decodable {
      let id: String
      let minimum: Double
      let maximum: Double
      let `default`: Double
    }

    struct Asset: Decodable {
      let id: String
      let version: Int
      let file: String
      let slot: String
      let rig: String
      let morphs: [String]
      let coverage: [String]
      let sha256: String
      let bytes: Int
      let triangles: Int
      let materials: Int
      let joints: Int
      let source: String
      let license: String
    }

    let schemaVersion: Int
    let catalogVersion: String
    let rig: Rig
    let parameters: [Parameter]
    let assets: [Asset]
  }

  private static let expectedAssets: [String: (file: String, slot: String)] = [
    "body-neutral": ("body-neutral.glb", "body"),
    "face-hair-black": ("face-hair-black.glb", "bodyDetail"),
    "top-ivory-knit": ("top-ivory-knit.glb", "top"),
    "outerwear-blue-shirt": ("outerwear-blue-shirt.glb", "top"),
    "bottom-black-skirt": ("bottom-black-skirt.glb", "bottom"),
    "bottom-mint-skirt": ("bottom-mint-skirt.glb", "bottom"),
    "shoes-cream": ("shoes-cream.glb", "shoes"),
    "shoes-black-boots": ("shoes-black-boots.glb", "shoes"),
  ]

  static func load(bundle: Bundle = .main) throws -> AvatarValidatedAssets {
    guard let manifestURL = bundle.url(
      forResource: "asset-manifest",
      withExtension: "json",
      subdirectory: "AvatarStudio/Models"
    ) else {
      throw AvatarAssetCatalogError.manifestMissing
    }
    let manifestData = try boundedData(at: manifestURL, maximumBytes: 128 * 1_024)
    let manifest: Manifest
    do {
      manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
    } catch {
      throw AvatarAssetCatalogError.manifestInvalid
    }
    try validate(manifest)

    var resources = ["asset-manifest.json": manifestData]
    for asset in manifest.assets {
      let name = String(asset.file.dropLast(4))
      guard let url = bundle.url(
        forResource: name,
        withExtension: "glb",
        subdirectory: "AvatarStudio/Models"
      ) else {
        throw AvatarAssetCatalogError.assetMissing
      }
      let data = try boundedData(at: url, maximumBytes: 2 * 1_024 * 1_024)
      guard data.count == asset.bytes else { throw AvatarAssetCatalogError.assetInvalid }
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      guard digest == asset.sha256 else { throw AvatarAssetCatalogError.hashMismatch }
      try validateGLB(data)
      resources[asset.file] = data
    }
    return AvatarValidatedAssets(resources: resources)
  }

  private static func validate(_ manifest: Manifest) throws {
    guard manifest.schemaVersion == 1,
          manifest.catalogVersion == "then-avatar-assets-v1",
          manifest.rig.id == "then-template-v1",
          manifest.rig.joints.count == 18,
          manifest.rig.restPose == "standing-neutral-v1" else {
      throw AvatarAssetCatalogError.unsupportedCatalog
    }
    let expectedParameters = ["shoulderWidth", "torsoDepth"]
    guard manifest.parameters.map(\.id) == expectedParameters,
          manifest.parameters.allSatisfy({
            $0.minimum == -0.25 && $0.maximum == 0.25 && $0.default == 0
          }) else {
      throw AvatarAssetCatalogError.unsupportedCatalog
    }
    guard Set(manifest.assets.map(\.id)) == Set(expectedAssets.keys),
          Set(manifest.assets.map(\.file)).count == expectedAssets.count else {
      throw AvatarAssetCatalogError.assetSetMismatch
    }
    for asset in manifest.assets {
      guard let expected = expectedAssets[asset.id],
            asset.file == expected.file,
            asset.slot == expected.slot,
            asset.file.unicodeScalars.allSatisfy({
              CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
                .contains($0)
            }),
            !asset.file.contains(".."),
            asset.version == 1,
            asset.rig == "then-template-v1",
            asset.morphs == expectedParameters,
            !asset.source.isEmpty,
            !asset.license.isEmpty else {
        throw AvatarAssetCatalogError.unsafeFileName
      }
      guard (1...80_000).contains(asset.triangles),
            asset.materials == 1,
            (1...64).contains(asset.joints),
            (1...(2 * 1_024 * 1_024)).contains(asset.bytes),
            asset.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        throw AvatarAssetCatalogError.budgetExceeded
      }
    }
  }

  private static func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true,
          let size = values.fileSize,
          (1...maximumBytes).contains(size) else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count == size else { throw AvatarAssetCatalogError.assetInvalid }
    return data
  }

  private static func validateGLB(_ data: Data) throws {
    guard data.count >= 28,
          littleEndianUInt32(data, at: 0) == 0x4654_6C67,
          littleEndianUInt32(data, at: 4) == 2,
          littleEndianUInt32(data, at: 8) == UInt32(data.count),
          littleEndianUInt32(data, at: 16) == 0x4E4F_534A else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    let jsonLength = Int(littleEndianUInt32(data, at: 12))
    guard jsonLength > 0, 20 + jsonLength + 8 <= data.count else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    let jsonData = data.subdata(in: 20..<(20 + jsonLength))
    guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          json["extensionsUsed"] == nil,
          let buffers = json["buffers"] as? [[String: Any]],
          buffers.count == 1,
          buffers[0]["uri"] == nil,
          let meshes = json["meshes"] as? [[String: Any]],
          meshes.count == 1,
          let skins = json["skins"] as? [[String: Any]],
          skins.count == 1 else {
      throw AvatarAssetCatalogError.assetInvalid
    }
  }

  private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { return 0 }
    return data[offset..<(offset + 4)].enumerated().reduce(0) { partial, byte in
      partial | UInt32(byte.element) << UInt32(byte.offset * 8)
    }
  }
}
