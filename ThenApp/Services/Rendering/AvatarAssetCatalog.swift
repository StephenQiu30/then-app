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
  private struct GLBInspection {
    let triangles: Int
    let materials: Int
    let jointNames: [String]
    let morphNames: [String]
    let activeMorphs: [Bool]
    let rigSignature: String
    let geometryHash: String
  }

  private struct AccessorView {
    let start: Int
    let count: Int
    let componentType: Int
    let components: Int

    var elementSize: Int {
      Self.componentSize(componentType) * components
    }

    var byteRange: Range<Int> {
      start..<(start + count * elementSize)
    }

    private static func componentSize(_ componentType: Int) -> Int {
      switch componentType {
      case 5_120, 5_121: 1
      case 5_122, 5_123: 2
      case 5_125, 5_126: 4
      default: 0
      }
    }
  }

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
    var inspections: [String: GLBInspection] = [:]
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
      inspections[asset.id] = try inspectGLB(data)
      resources[asset.file] = data
    }
    try validate(inspections, against: manifest)
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

  private static func validate(
    _ inspections: [String: GLBInspection],
    against manifest: Manifest
  ) throws {
    guard inspections.count == manifest.assets.count else {
      throw AvatarAssetCatalogError.assetSetMismatch
    }

    var referenceRigSignature: String?
    for asset in manifest.assets {
      guard let inspection = inspections[asset.id],
            inspection.triangles == asset.triangles,
            inspection.materials == asset.materials,
            inspection.jointNames == manifest.rig.joints,
            inspection.jointNames.count == asset.joints,
            inspection.morphNames == asset.morphs,
            !(["body", "top"].contains(asset.slot)) || inspection.activeMorphs.allSatisfy({ $0 }) else {
        throw AvatarAssetCatalogError.assetInvalid
      }
      if let referenceRigSignature {
        guard inspection.rigSignature == referenceRigSignature else {
          throw AvatarAssetCatalogError.assetInvalid
        }
      } else {
        referenceRigSignature = inspection.rigSignature
      }
    }

    let topGeometry = manifest.assets
      .filter { $0.slot == "top" }
      .compactMap { inspections[$0.id]?.geometryHash }
    guard topGeometry.count == 2, Set(topGeometry).count == 2 else {
      throw AvatarAssetCatalogError.assetInvalid
    }

    let maximumVisibleAssets = ["body", "bodyDetail", "top", "bottom", "shoes"].compactMap { slot in
      manifest.assets
        .filter { $0.slot == slot }
        .compactMap { inspections[$0.id] }
        .max { $0.triangles < $1.triangles }
    }
    guard maximumVisibleAssets.count == 5,
          maximumVisibleAssets.reduce(0, { $0 + $1.triangles }) <= 80_000,
          maximumVisibleAssets.reduce(0, { $0 + $1.materials }) <= 8 else {
      throw AvatarAssetCatalogError.budgetExceeded
    }
  }

  static func validateGLB(_ data: Data) throws {
    _ = try inspectGLB(data)
  }

  private static func inspectGLB(_ data: Data) throws -> GLBInspection {
    guard data.count >= 28,
          littleEndianUInt32(data, at: 0) == 0x4654_6C67,
          littleEndianUInt32(data, at: 4) == 2,
          littleEndianUInt32(data, at: 8) == UInt32(data.count),
          littleEndianUInt32(data, at: 16) == 0x4E4F_534A else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    let jsonLength = Int(littleEndianUInt32(data, at: 12))
    guard jsonLength > 0,
          jsonLength <= data.count - 28,
          20 + jsonLength + 8 <= data.count else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    let binaryHeader = 20 + jsonLength
    let binaryLength = Int(littleEndianUInt32(data, at: binaryHeader))
    let binaryStart = binaryHeader + 8
    guard littleEndianUInt32(data, at: binaryHeader + 4) == 0x004E_4942,
          binaryLength > 0,
          binaryStart <= data.count,
          binaryLength == data.count - binaryStart else {
      throw AvatarAssetCatalogError.assetInvalid
    }

    let jsonData = data.subdata(in: 20..<binaryHeader)
    guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let asset = json["asset"] as? [String: Any],
          asset["version"] as? String == "2.0",
          let buffers = json["buffers"] as? [[String: Any]],
          buffers.count == 1,
          buffers[0]["uri"] == nil,
          let declaredBufferLength = integer(buffers[0]["byteLength"]),
          declaredBufferLength <= binaryLength,
          binaryLength - declaredBufferLength <= 3,
          let bufferViews = json["bufferViews"] as? [[String: Any]],
          bufferViews.count == 8,
          let accessors = json["accessors"] as? [[String: Any]],
          accessors.count == 8,
          let meshes = json["meshes"] as? [[String: Any]],
          meshes.count == 1,
          let skins = json["skins"] as? [[String: Any]],
          skins.count == 1,
          let nodes = json["nodes"] as? [[String: Any]],
          !nodes.isEmpty,
          let materials = json["materials"] as? [[String: Any]],
          materials.count == 1 else {
      throw AvatarAssetCatalogError.assetInvalid
    }

    for key in ["extensionsUsed", "extensionsRequired", "images", "textures", "animations"] {
      if let value = json[key] {
        guard let array = value as? [Any], array.isEmpty else {
          throw AvatarAssetCatalogError.assetInvalid
        }
      }
    }
    for bufferView in bufferViews {
      guard (integer(bufferView["buffer"]) ?? 0) == 0,
            bufferView["byteStride"] == nil,
            let viewLength = integer(bufferView["byteLength"]),
            let viewOffset = nonnegativeInteger(bufferView["byteOffset"], default: 0),
            viewLength > 0,
            viewOffset <= declaredBufferLength,
            viewLength <= declaredBufferLength - viewOffset else {
        throw AvatarAssetCatalogError.assetInvalid
      }
    }
    for accessorIndex in accessors.indices {
      _ = try accessorView(
        at: accessorIndex,
        accessors: accessors,
        bufferViews: bufferViews,
        binaryStart: binaryStart,
        bufferLength: declaredBufferLength
      )
    }

    guard let primitives = meshes[0]["primitives"] as? [[String: Any]],
          primitives.count == 1,
          let attributes = primitives[0]["attributes"] as? [String: Any],
          Set(attributes.keys) == Set(["POSITION", "NORMAL", "JOINTS_0", "WEIGHTS_0"]),
          let positionIndex = integer(attributes["POSITION"]),
          let normalIndex = integer(attributes["NORMAL"]),
          let jointsIndex = integer(attributes["JOINTS_0"]),
          let weightsIndex = integer(attributes["WEIGHTS_0"]),
          let indicesIndex = integer(primitives[0]["indices"]),
          let materialIndex = integer(primitives[0]["material"]),
          materialIndex == 0,
          (integer(primitives[0]["mode"]) ?? 4) == 4,
          let targets = primitives[0]["targets"] as? [[String: Any]],
          targets.count == 2,
          let extras = meshes[0]["extras"] as? [String: Any],
          let morphNames = extras["targetNames"] as? [String],
          morphNames == ["shoulderWidth", "torsoDepth"] else {
      throw AvatarAssetCatalogError.assetInvalid
    }

    let position = try accessorView(
      at: positionIndex,
      accessors: accessors,
      bufferViews: bufferViews,
      binaryStart: binaryStart,
      bufferLength: declaredBufferLength,
      componentType: 5_126,
      type: "VEC3"
    )
    let normal = try accessorView(
      at: normalIndex,
      accessors: accessors,
      bufferViews: bufferViews,
      binaryStart: binaryStart,
      bufferLength: declaredBufferLength,
      componentType: 5_126,
      type: "VEC3"
    )
    let joints = try accessorView(
      at: jointsIndex,
      accessors: accessors,
      bufferViews: bufferViews,
      binaryStart: binaryStart,
      bufferLength: declaredBufferLength,
      allowedComponentTypes: [5_121, 5_123],
      type: "VEC4"
    )
    let weights = try accessorView(
      at: weightsIndex,
      accessors: accessors,
      bufferViews: bufferViews,
      binaryStart: binaryStart,
      bufferLength: declaredBufferLength,
      componentType: 5_126,
      type: "VEC4"
    )
    let indices = try accessorView(
      at: indicesIndex,
      accessors: accessors,
      bufferViews: bufferViews,
      binaryStart: binaryStart,
      bufferLength: declaredBufferLength,
      allowedComponentTypes: [5_121, 5_123, 5_125],
      type: "SCALAR"
    )
    guard normal.count == position.count,
          joints.count == position.count,
          weights.count == position.count,
          indices.count.isMultiple(of: 3) else {
      throw AvatarAssetCatalogError.assetInvalid
    }

    try validateFiniteFloats(position, in: data)
    try validatePositionBounds(position, metadata: accessors[positionIndex], in: data)
    try validateFiniteFloats(normal, in: data)

    var activeMorphs: [Bool] = []
    for target in targets {
      guard Set(target.keys) == Set(["POSITION"]),
            let morphIndex = integer(target["POSITION"]) else {
        throw AvatarAssetCatalogError.assetInvalid
      }
      let morph = try accessorView(
        at: morphIndex,
        accessors: accessors,
        bufferViews: bufferViews,
        binaryStart: binaryStart,
        bufferLength: declaredBufferLength,
        componentType: 5_126,
        type: "VEC3"
      )
      guard morph.count == position.count else {
        throw AvatarAssetCatalogError.assetInvalid
      }
      try validateFiniteFloats(morph, in: data)
      try validatePositionBounds(morph, metadata: accessors[morphIndex], in: data)
      activeMorphs.append(containsNonzeroFloat(morph, in: data))
    }

    guard let skinJointsValue = skins[0]["joints"] as? [Any] else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    let skinJoints = skinJointsValue.compactMap(integer)
    guard skinJoints.count == skinJointsValue.count,
          !skinJoints.isEmpty,
          Set(skinJoints).count == skinJoints.count,
          skinJoints.allSatisfy({ nodes.indices.contains($0) }),
          integer(skins[0]["skeleton"]) == skinJoints[0],
          let inverseBindIndex = integer(skins[0]["inverseBindMatrices"]) else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    let inverseBindMatrices = try accessorView(
      at: inverseBindIndex,
      accessors: accessors,
      bufferViews: bufferViews,
      binaryStart: binaryStart,
      bufferLength: declaredBufferLength,
      componentType: 5_126,
      type: "MAT4"
    )
    guard inverseBindMatrices.count == skinJoints.count else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    try validateFiniteFloats(inverseBindMatrices, in: data)
    try validateSkinning(joints: joints, weights: weights, jointCount: skinJoints.count, in: data)
    try validateIndices(indices, vertexCount: position.count, in: data)
    try validateTriangleWinding(positions: position, normals: normal, indices: indices, in: data)

    var parentByNode: [Int: Int] = [:]
    for (parentIndex, node) in nodes.enumerated() {
      try validateNodeTransform(node)
      guard let childValues = node["children"] else { continue }
      guard let children = childValues as? [Any] else {
        throw AvatarAssetCatalogError.assetInvalid
      }
      for childValue in children {
        guard let child = integer(childValue),
              nodes.indices.contains(child),
              parentByNode.updateValue(parentIndex, forKey: child) == nil else {
          throw AvatarAssetCatalogError.assetInvalid
        }
      }
    }
    for joint in skinJoints {
      var seen: Set<Int> = []
      var current: Int? = joint
      while let nodeIndex = current {
        guard seen.insert(nodeIndex).inserted else {
          throw AvatarAssetCatalogError.assetInvalid
        }
        current = parentByNode[nodeIndex]
      }
    }

    let jointNames = try skinJoints.map { joint -> String in
      guard let name = nodes[joint]["name"] as? String, !name.isEmpty else {
        throw AvatarAssetCatalogError.assetInvalid
      }
      return name
    }
    guard Set(jointNames).count == jointNames.count else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    let jointOrdinalByNode = Dictionary(uniqueKeysWithValues: skinJoints.enumerated().map { ($1, $0) })
    var rigData = Data()
    for (ordinal, joint) in skinJoints.enumerated() {
      rigData.append(Data("\(ordinal):\(jointNames[ordinal]);".utf8))
      let parentOrdinal = parentByNode[joint].flatMap { jointOrdinalByNode[$0] } ?? -1
      rigData.append(Data("parent:\(parentOrdinal);".utf8))
      for field in ["matrix", "translation", "rotation", "scale"] {
        rigData.append(Data("\(field):".utf8))
        if let values = nodes[joint][field] as? [NSNumber] {
          for value in values {
            rigData.append(Data(String(format: "%.17g,", value.doubleValue).utf8))
          }
        }
        rigData.append(0x3B)
      }
    }
    rigData.append(data.subdata(in: inverseBindMatrices.byteRange))

    let meshNodes = nodes.enumerated().filter { integer($0.element["mesh"]) == 0 }
    guard meshNodes.count == 1, integer(meshNodes[0].element["skin"]) == 0 else {
      throw AvatarAssetCatalogError.assetInvalid
    }

    var geometryData = Data()
    geometryData.append(data.subdata(in: position.byteRange))
    geometryData.append(data.subdata(in: indices.byteRange))
    return GLBInspection(
      triangles: indices.count / 3,
      materials: materials.count,
      jointNames: jointNames,
      morphNames: morphNames,
      activeMorphs: activeMorphs,
      rigSignature: sha256(rigData),
      geometryHash: sha256(geometryData)
    )
  }

  private static func accessorView(
    at index: Int,
    accessors: [[String: Any]],
    bufferViews: [[String: Any]],
    binaryStart: Int,
    bufferLength: Int,
    componentType expectedComponentType: Int? = nil,
    allowedComponentTypes: Set<Int>? = nil,
    type expectedType: String? = nil
  ) throws -> AccessorView {
    guard accessors.indices.contains(index) else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    let accessor = accessors[index]
    guard accessor["sparse"] == nil,
          accessor["normalized"] == nil || (accessor["normalized"] as? Bool) == false,
          let bufferViewIndex = integer(accessor["bufferView"]),
          bufferViews.indices.contains(bufferViewIndex),
          let componentType = integer(accessor["componentType"]),
          let count = integer(accessor["count"]),
          count > 0,
          let type = accessor["type"] as? String,
          let components = componentCount(for: type),
          let componentSize = componentSize(for: componentType),
          expectedComponentType.map({ componentType == $0 }) ?? true,
          allowedComponentTypes.map({ $0.contains(componentType) }) ?? true,
          expectedType.map({ type == $0 }) ?? true else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    let bufferView = bufferViews[bufferViewIndex]
    guard let viewLength = integer(bufferView["byteLength"]),
          let viewOffset = nonnegativeInteger(bufferView["byteOffset"], default: 0),
          let accessorOffset = nonnegativeInteger(accessor["byteOffset"], default: 0),
          viewOffset <= bufferLength,
          viewLength <= bufferLength - viewOffset else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    let (elementSize, elementOverflow) = componentSize.multipliedReportingOverflow(by: components)
    let (byteCount, countOverflow) = elementSize.multipliedReportingOverflow(by: count)
    guard !elementOverflow,
          !countOverflow,
          accessorOffset <= viewLength,
          byteCount <= viewLength - accessorOffset else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    return AccessorView(
      start: binaryStart + viewOffset + accessorOffset,
      count: count,
      componentType: componentType,
      components: components
    )
  }

  private static func validateFiniteFloats(
    _ accessor: AccessorView,
    in data: Data
  ) throws {
    guard accessor.componentType == 5_126 else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    for offset in stride(from: accessor.start, to: accessor.byteRange.upperBound, by: 4) {
      let value = Float(bitPattern: littleEndianUInt32(data, at: offset))
      guard value.isFinite else {
        throw AvatarAssetCatalogError.assetInvalid
      }
    }
  }

  private static func containsNonzeroFloat(_ accessor: AccessorView, in data: Data) -> Bool {
    stride(from: accessor.start, to: accessor.byteRange.upperBound, by: 4).contains { offset in
      abs(Float(bitPattern: littleEndianUInt32(data, at: offset))) > 0.000_001
    }
  }

  private static func validatePositionBounds(
    _ accessor: AccessorView,
    metadata: [String: Any],
    in data: Data
  ) throws {
    guard accessor.componentType == 5_126,
          let declaredMinimum = metadata["min"] as? [NSNumber],
          let declaredMaximum = metadata["max"] as? [NSNumber],
          declaredMinimum.count == accessor.components,
          declaredMaximum.count == accessor.components else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    var actualMinimum = Array(repeating: Float.greatestFiniteMagnitude, count: accessor.components)
    var actualMaximum = Array(repeating: -Float.greatestFiniteMagnitude, count: accessor.components)
    for element in 0..<accessor.count {
      for component in 0..<accessor.components {
        let offset = accessor.start + element * accessor.elementSize + component * 4
        let value = Float(bitPattern: littleEndianUInt32(data, at: offset))
        actualMinimum[component] = min(actualMinimum[component], value)
        actualMaximum[component] = max(actualMaximum[component], value)
      }
    }
    guard declaredMinimum.enumerated().allSatisfy({
      Float($0.element.doubleValue) == actualMinimum[$0.offset]
    }), declaredMaximum.enumerated().allSatisfy({
      Float($0.element.doubleValue) == actualMaximum[$0.offset]
    }) else {
      throw AvatarAssetCatalogError.assetInvalid
    }
  }

  private static func validateSkinning(
    joints: AccessorView,
    weights: AccessorView,
    jointCount: Int,
    in data: Data
  ) throws {
    for vertex in 0..<joints.count {
      var weightTotal: Float = 0
      for component in 0..<4 {
        let jointOffset = joints.start + vertex * joints.elementSize + component * componentSize(for: joints.componentType)!
        guard let joint = unsignedInteger(in: data, at: jointOffset, componentType: joints.componentType),
              joint < jointCount else {
          throw AvatarAssetCatalogError.assetInvalid
        }
        let weightOffset = weights.start + vertex * weights.elementSize + component * 4
        let weight = Float(bitPattern: littleEndianUInt32(data, at: weightOffset))
        guard weight.isFinite, (0...1).contains(weight) else {
          throw AvatarAssetCatalogError.assetInvalid
        }
        weightTotal += weight
      }
      guard (0.999...1.001).contains(weightTotal) else {
        throw AvatarAssetCatalogError.assetInvalid
      }
    }
  }

  private static func validateIndices(
    _ accessor: AccessorView,
    vertexCount: Int,
    in data: Data
  ) throws {
    for index in 0..<accessor.count {
      let offset = accessor.start + index * accessor.elementSize
      guard let value = unsignedInteger(in: data, at: offset, componentType: accessor.componentType),
            value < vertexCount else {
        throw AvatarAssetCatalogError.assetInvalid
      }
    }
  }

  private static func validateTriangleWinding(
    positions: AccessorView,
    normals: AccessorView,
    indices: AccessorView,
    in data: Data
  ) throws {
    var assessedTriangles = 0
    for triangle in stride(from: 0, to: indices.count, by: 3) {
      guard let first = unsignedInteger(
        in: data,
        at: indices.start + triangle * indices.elementSize,
        componentType: indices.componentType
      ), let second = unsignedInteger(
        in: data,
        at: indices.start + (triangle + 1) * indices.elementSize,
        componentType: indices.componentType
      ), let third = unsignedInteger(
        in: data,
        at: indices.start + (triangle + 2) * indices.elementSize,
        componentType: indices.componentType
      ) else {
        throw AvatarAssetCatalogError.assetInvalid
      }
      let a = float3(positions, element: first, in: data)
      let b = float3(positions, element: second, in: data)
      let c = float3(positions, element: third, in: data)
      let ab = (b.0 - a.0, b.1 - a.1, b.2 - a.2)
      let ac = (c.0 - a.0, c.1 - a.1, c.2 - a.2)
      let faceNormal = (
        ab.1 * ac.2 - ab.2 * ac.1,
        ab.2 * ac.0 - ab.0 * ac.2,
        ab.0 * ac.1 - ab.1 * ac.0
      )
      let na = float3(normals, element: first, in: data)
      let nb = float3(normals, element: second, in: data)
      let nc = float3(normals, element: third, in: data)
      let vertexNormal = (
        (na.0 + nb.0 + nc.0) / 3,
        (na.1 + nb.1 + nc.1) / 3,
        (na.2 + nb.2 + nc.2) / 3
      )
      let faceMagnitude = faceNormal.0 * faceNormal.0
        + faceNormal.1 * faceNormal.1
        + faceNormal.2 * faceNormal.2
      let normalMagnitude = vertexNormal.0 * vertexNormal.0
        + vertexNormal.1 * vertexNormal.1
        + vertexNormal.2 * vertexNormal.2
      guard faceMagnitude.isFinite, normalMagnitude.isFinite else {
        throw AvatarAssetCatalogError.assetInvalid
      }
      if faceMagnitude * normalMagnitude <= 0.000_000_000_001 { continue }
      assessedTriangles += 1
      let alignment = faceNormal.0 * vertexNormal.0
        + faceNormal.1 * vertexNormal.1
        + faceNormal.2 * vertexNormal.2
      guard alignment > 0 else {
        throw AvatarAssetCatalogError.assetInvalid
      }
    }
    guard assessedTriangles > 0 else {
      throw AvatarAssetCatalogError.assetInvalid
    }
  }

  private static func float3(
    _ accessor: AccessorView,
    element: Int,
    in data: Data
  ) -> (Float, Float, Float) {
    let offset = accessor.start + element * accessor.elementSize
    return (
      Float(bitPattern: littleEndianUInt32(data, at: offset)),
      Float(bitPattern: littleEndianUInt32(data, at: offset + 4)),
      Float(bitPattern: littleEndianUInt32(data, at: offset + 8))
    )
  }

  private static func validateNodeTransform(_ node: [String: Any]) throws {
    let fields = [("matrix", 16), ("translation", 3), ("rotation", 4), ("scale", 3)]
    let hasMatrix = node["matrix"] != nil
    guard !hasMatrix || fields.dropFirst().allSatisfy({ node[$0.0] == nil }) else {
      throw AvatarAssetCatalogError.assetInvalid
    }
    for (field, expectedCount) in fields where node[field] != nil {
      guard let values = node[field] as? [NSNumber],
            values.count == expectedCount,
            values.allSatisfy({ $0.doubleValue.isFinite }) else {
        throw AvatarAssetCatalogError.assetInvalid
      }
    }
  }

  private static func unsignedInteger(
    in data: Data,
    at offset: Int,
    componentType: Int
  ) -> Int? {
    switch componentType {
    case 5_121:
      guard data.indices.contains(offset) else { return nil }
      return Int(data[offset])
    case 5_123:
      return Int(littleEndianUInt16(data, at: offset))
    case 5_125:
      return Int(littleEndianUInt32(data, at: offset))
    default:
      return nil
    }
  }

  private static func componentCount(for type: String) -> Int? {
    switch type {
    case "SCALAR": 1
    case "VEC2": 2
    case "VEC3": 3
    case "VEC4", "MAT2": 4
    case "MAT3": 9
    case "MAT4": 16
    default: nil
    }
  }

  private static func componentSize(for componentType: Int) -> Int? {
    switch componentType {
    case 5_120, 5_121: 1
    case 5_122, 5_123: 2
    case 5_125, 5_126: 4
    default: nil
    }
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    guard double.isFinite,
          double >= 0,
          double.rounded() == double,
          double <= Double(Int.max) else {
      return nil
    }
    return Int(double)
  }

  private static func nonnegativeInteger(_ value: Any?, default defaultValue: Int) -> Int? {
    value == nil ? defaultValue : integer(value)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= data.count else { return 0 }
    return data[offset..<(offset + 2)].enumerated().reduce(0) { partial, byte in
      partial | UInt16(byte.element) << UInt16(byte.offset * 8)
    }
  }

  private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { return 0 }
    return data[offset..<(offset + 4)].enumerated().reduce(0) { partial, byte in
      partial | UInt32(byte.element) << UInt32(byte.offset * 8)
    }
  }
}
