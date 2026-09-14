import Foundation
import Testing
@testable import ThenApp

struct AvatarAssetCatalogTests {
  @Test("随包三维目录通过实际加载校验")
  func bundledCatalogLoads() throws {
    let catalog = try AvatarAssetCatalog.load()
    #expect(catalog.resources.count == 9)
    #expect(catalog.resources["body-neutral.glb"] != nil)
    #expect(catalog.resources["outerwear-blue-shirt.glb"] != nil)
  }

  @Test("非有限顶点在进入 renderer 前拒绝")
  func nonFiniteVertexIsRejected() throws {
    var data = try bundledModel(named: "body-neutral")
    let position = try accessorIndex(named: "POSITION", in: data)
    let offset = try binaryOffset(forAccessor: position, in: data)
    data.replaceSubrange(offset..<(offset + 4), with: [0x00, 0x00, 0xC0, 0x7F])

    #expect(throws: AvatarAssetCatalogError.assetInvalid) {
      try AvatarAssetCatalog.validateGLB(data)
    }
  }

  @Test("越界骨骼索引在进入 renderer 前拒绝")
  func outOfRangeJointIsRejected() throws {
    var data = try bundledModel(named: "body-neutral")
    let joints = try accessorIndex(named: "JOINTS_0", in: data)
    let offset = try binaryOffset(forAccessor: joints, in: data)
    data[offset] = 99

    #expect(throws: AvatarAssetCatalogError.assetInvalid) {
      try AvatarAssetCatalog.validateGLB(data)
    }
  }

  @Test("越界三角索引在进入 renderer 前拒绝")
  func outOfRangeTriangleIndexIsRejected() throws {
    var data = try bundledModel(named: "body-neutral")
    let json = try glTFJSON(in: data)
    let meshes = try #require(json["meshes"] as? [[String: Any]])
    let primitives = try #require(meshes.first?["primitives"] as? [[String: Any]])
    let indexAccessor = try #require(primitives.first?["indices"] as? Int)
    let offset = try binaryOffset(forAccessor: indexAccessor, in: data)
    data.replaceSubrange(offset..<(offset + 2), with: [0xFF, 0xFF])

    #expect(throws: AvatarAssetCatalogError.assetInvalid) {
      try AvatarAssetCatalog.validateGLB(data)
    }
  }

  @Test("与法线相反的三角绕序在进入 renderer 前拒绝")
  func reversedTriangleWindingIsRejected() throws {
    var data = try bundledModel(named: "body-neutral")
    let json = try glTFJSON(in: data)
    let meshes = try #require(json["meshes"] as? [[String: Any]])
    let primitives = try #require(meshes.first?["primitives"] as? [[String: Any]])
    let indexAccessor = try #require(primitives.first?["indices"] as? Int)
    let accessors = try #require(json["accessors"] as? [[String: Any]])
    let count = try #require(accessors[indexAccessor]["count"] as? Int)
    let componentType = try #require(accessors[indexAccessor]["componentType"] as? Int)
    let componentSize = try #require([5_121: 1, 5_123: 2, 5_125: 4][componentType])
    let offset = try binaryOffset(forAccessor: indexAccessor, in: data)
    for triangle in stride(from: 0, to: count, by: 3) {
      let second = offset + (triangle + 1) * componentSize
      let third = offset + (triangle + 2) * componentSize
      let secondBytes = data[second..<(second + componentSize)]
      let thirdBytes = data[third..<(third + componentSize)]
      data.replaceSubrange(second..<(second + componentSize), with: thirdBytes)
      data.replaceSubrange(third..<(third + componentSize), with: secondBytes)
    }

    #expect(throws: AvatarAssetCatalogError.assetInvalid) {
      try AvatarAssetCatalog.validateGLB(data)
    }
  }

  @Test("外部资源 URI 在进入 renderer 前拒绝")
  func externalResourceIsRejected() throws {
    let original = try bundledModel(named: "body-neutral")
    let data = try rebuildingGLB(original) { document in
      var buffers = try #require(document["buffers"] as? [[String: Any]])
      buffers[0]["uri"] = "https://invalid.example/body.bin"
      document["buffers"] = buffers
    }

    #expect(throws: AvatarAssetCatalogError.assetInvalid) {
      try AvatarAssetCatalog.validateGLB(data)
    }
  }

  @Test("未知扩展在进入 renderer 前拒绝")
  func unknownExtensionIsRejected() throws {
    let original = try bundledModel(named: "body-neutral")
    let data = try rebuildingGLB(original) { document in
      document["extensionsUsed"] = ["VENDOR_unknown"]
    }

    #expect(throws: AvatarAssetCatalogError.assetInvalid) {
      try AvatarAssetCatalog.validateGLB(data)
    }
  }

  private func bundledModel(named name: String) throws -> Data {
    let url = try #require(Bundle.main.url(
      forResource: name,
      withExtension: "glb",
      subdirectory: "AvatarStudio/Models"
    ))
    return try Data(contentsOf: url)
  }

  private func accessorIndex(named name: String, in data: Data) throws -> Int {
    let json = try glTFJSON(in: data)
    let meshes = try #require(json["meshes"] as? [[String: Any]])
    let primitives = try #require(meshes.first?["primitives"] as? [[String: Any]])
    let attributes = try #require(primitives.first?["attributes"] as? [String: Any])
    return try #require(attributes[name] as? Int)
  }

  private func binaryOffset(forAccessor index: Int, in data: Data) throws -> Int {
    let json = try glTFJSON(in: data)
    let accessors = try #require(json["accessors"] as? [[String: Any]])
    let bufferViews = try #require(json["bufferViews"] as? [[String: Any]])
    let accessor = accessors[index]
    let bufferViewIndex = try #require(accessor["bufferView"] as? Int)
    let viewOffset = bufferViews[bufferViewIndex]["byteOffset"] as? Int ?? 0
    let accessorOffset = accessor["byteOffset"] as? Int ?? 0
    let jsonLength = Int(littleEndianUInt32(data, at: 12))
    return 20 + jsonLength + 8 + viewOffset + accessorOffset
  }

  private func glTFJSON(in data: Data) throws -> [String: Any] {
    let jsonLength = Int(littleEndianUInt32(data, at: 12))
    let jsonData = data.subdata(in: 20..<(20 + jsonLength))
    return try #require(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
  }

  private func rebuildingGLB(
    _ data: Data,
    mutate: (inout [String: Any]) throws -> Void
  ) throws -> Data {
    var document = try glTFJSON(in: data)
    try mutate(&document)
    var jsonData = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    jsonData.append(contentsOf: repeatElement(UInt8(ascii: " "), count: (4 - jsonData.count % 4) % 4))

    let originalJSONLength = Int(littleEndianUInt32(data, at: 12))
    let binaryHeader = 20 + originalJSONLength
    let binaryLength = Int(littleEndianUInt32(data, at: binaryHeader))
    let binaryData = data.subdata(in: (binaryHeader + 8)..<(binaryHeader + 8 + binaryLength))

    var rebuilt = Data("glTF".utf8)
    rebuilt.append(littleEndianData(2))
    rebuilt.append(littleEndianData(UInt32(12 + 8 + jsonData.count + 8 + binaryData.count)))
    rebuilt.append(littleEndianData(UInt32(jsonData.count)))
    rebuilt.append(littleEndianData(0x4E4F_534A))
    rebuilt.append(jsonData)
    rebuilt.append(littleEndianData(UInt32(binaryData.count)))
    rebuilt.append(littleEndianData(0x004E_4942))
    rebuilt.append(binaryData)
    return rebuilt
  }

  private func littleEndianData(_ value: UInt32) -> Data {
    Data([
      UInt8(truncatingIfNeeded: value),
      UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 24),
    ])
  }

  private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].enumerated().reduce(0) { partial, byte in
      partial | UInt32(byte.element) << UInt32(byte.offset * 8)
    }
  }
}
