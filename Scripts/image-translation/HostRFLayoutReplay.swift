import CoreGraphics
import CryptoKit
import Foundation

/// Exact host-only detector replay, including all retained mask logits.
/// Cached observations are keyed by source bytes and detector implementation;
/// no ground-truth labels, recognition results or image-specific rules enter it.
enum HostRFLayoutReplay {
    enum Failure: Error { case invalidRecord(String) }

    final class Context: @unchecked Sendable {
        let directory: URL
        let sourceSHA256: String
        let width: Int
        let height: Int
        private let lock = NSLock()
        private var predictions = 0
        private var hits = 0

        init(root: URL, cache: URL, sourceSHA256: String, width: Int, height: Int) throws {
            guard sourceSHA256.count == 64, sourceSHA256.allSatisfy({ $0.isHexDigit }), width > 0, height > 0 else {
                throw Failure.invalidRecord("Invalid RF source identity")
            }
            var contract = Data("host-rf-full-result-v1:".utf8)
            let weights = ProcessInfo.processInfo.environment["AIDOKU_HOST_RF_PACKAGE"] == nil
                ? NativeRFDETRLayoutResource.sourceWeightsSHA256 : NativeRFDETRLayoutResource.highresSourceWeightsSHA256
            contract.append(Data(weights.utf8))
            contract.append(Data("semantic-grid=\(NativeRFDETRSemanticGrid.enabled):\(NativeRFDETRSemanticGrid.schema)".utf8))
            for file in ["NativeRFDETRLayoutDetector.swift", "NativeRFDETRLayoutModels.swift", "NativeRFDETRSemanticGrid.swift"] {
                contract.append(try Data(contentsOf: root.appendingPathComponent("Aidoku/Core/Translation/NativeEngine/Layout/" + file)))
            }
            directory = cache.appendingPathComponent(HostRFLayoutReplay.digest(contract))
            self.sourceSHA256 = sourceSHA256
            self.width = width
            self.height = height
        }

        func observed(prediction: Bool) {
            lock.withLock {
                if prediction { predictions += 1 } else { hits += 1 }
            }
        }

        var statistics: [String: Any] {
            lock.withLock { ["RF_model_calls": predictions, "RF_replay_hits": hits, "RF_masks_preserved": true] }
        }
    }

    struct Primitive: Codable {
        let queryID: Int
        let semanticClass: Int
        let confidence: Float
        let normalizedBounds: CGRect
        let sourceBounds: CGRect
        let supportPolygon: [CGPoint]?
        let maskOffset: Int?
    }

    struct ClassEvidence: Codable {
        let queryID: Int
        let logits: [Float]
        let probabilities: [Float]
        let normalizedBounds: CGRect
        let sourceBounds: CGRect
        let maskOffset: Int?
    }

    struct Record: Codable {
        let version: Int
        let sourceSHA256: String
        let imageIdentity: String
        let width: Int
        let height: Int
        let maximumMaskQueries: Int
        let maskQueriesOmittedByBudget: Int
        let maskBytes: Int
        let maskSHA256: String
        let primitives: [Primitive]
        var classEvidence: [ClassEvidence]? = nil
        var semanticGridSHA256: String? = nil
        var semanticGridModelWeightsSHA256: String? = nil
    }

    @TaskLocal static var context: Context?
    private static let cells = NativeRFDETRLayoutResource.maskSide * NativeRFDETRLayoutResource.maskSide

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func folder(_ context: Context, maximumMasks: Int) -> URL {
        context.directory.appendingPathComponent("masks-\(maximumMasks)").appendingPathComponent(context.sourceSHA256)
    }

    private static func restore(_ context: Context, imageIdentity: String, maximumMasks: Int) throws -> NativeRFDETRLayoutResult? {
        let directory = folder(context, maximumMasks: maximumMasks)
        let metadata = directory.appendingPathComponent("record.json")
        guard FileManager.default.fileExists(atPath: metadata.path) else { return nil }
        let bytes = try Data(contentsOf: metadata)
        guard bytes.count <= 512 * 1024 else { throw Failure.invalidRecord("Oversized RF record") }
        let record = try JSONDecoder().decode(Record.self, from: bytes)
        guard record.version == 1, record.sourceSHA256 == context.sourceSHA256,
              record.imageIdentity == imageIdentity, record.width == context.width, record.height == context.height,
              record.maximumMaskQueries == maximumMasks, record.primitives.count <= 160,
              (0...NativeRFDETRLayoutResource.queryCount).contains(record.maskQueriesOmittedByBudget),
              record.maskBytes >= 0, record.maskBytes <= maximumMasks * cells * 4,
              record.maskSHA256.count == 64, record.maskSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw Failure.invalidRecord("RF source, geometry or mask contract mismatch")
        }
        let masks = try Data(contentsOf: directory.appendingPathComponent(record.maskSHA256 + ".f32"))
        guard masks.count == record.maskBytes, digest(masks) == record.maskSHA256,
              masks.count % (cells * 4) == 0 else { throw Failure.invalidRecord("RF mask bytes changed") }
        let floats = masks.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard floats.allSatisfy(\.isFinite) else { throw Failure.invalidRecord("Nonfinite RF mask") }
        func valid(_ rect: CGRect) -> Bool {
            [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width >= 0 && rect.height >= 0
        }
        var primitives: [NativeRFDETRLayoutPrimitive] = []
        for primitive in record.primitives {
            guard (0..<NativeRFDETRLayoutResource.queryCount).contains(primitive.queryID),
                  let semanticClass = NativeRFDETRLayoutClass(rawValue: primitive.semanticClass),
                  primitive.confidence.isFinite, (0...1).contains(primitive.confidence),
                  valid(primitive.normalizedBounds), valid(primitive.sourceBounds),
                  primitive.supportPolygon.map({ $0.count == 4 && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) ?? true else {
                throw Failure.invalidRecord("Invalid RF primitive")
            }
            let mask: NativeRFDETRLayoutMask?
            if let offset = primitive.maskOffset {
                guard offset >= 0, offset % cells == 0, offset <= floats.count - cells else {
                    throw Failure.invalidRecord("RF mask offset outside retained payload")
                }
                mask = .init(queryID: primitive.queryID, sourceWidth: record.width, sourceHeight: record.height,
                             logits: Array(floats[offset..<(offset + cells)]))
            } else { mask = nil }
            var value = NativeRFDETRLayoutPrimitive(queryID: primitive.queryID, semanticClass: semanticClass,
                confidence: primitive.confidence, normalizedBounds: primitive.normalizedBounds,
                sourceBounds: primitive.sourceBounds, mask: mask)
            value.supportPolygon = primitive.supportPolygon
            primitives.append(value)
        }
        let raw = try (record.classEvidence ?? []).map { q -> NativeRFDETRClassEvidence in
            guard (0..<300).contains(q.queryID), q.logits.count == 5, q.probabilities.count == 5,
                  q.logits.allSatisfy(\.isFinite), q.probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  valid(q.normalizedBounds), valid(q.sourceBounds) else { throw Failure.invalidRecord("Invalid raw RF evidence") }
            var mask: NativeRFDETRLayoutMask?
            if let offset = q.maskOffset {
                guard offset >= 0, offset % cells == 0, offset <= floats.count - cells else {
                    throw Failure.invalidRecord("Raw RF mask offset outside payload")
                }
                mask = .init(queryID: q.queryID, sourceWidth: record.width, sourceHeight: record.height,
                    logits: Array(floats[offset..<(offset + cells)]))
            }
            return .init(queryID: q.queryID, logits: q.logits, probabilities: q.probabilities,
                normalizedBounds: q.normalizedBounds, sourceBounds: q.sourceBounds, mask: mask)
        }
        guard raw.count <= 300, Set(raw.map(\.queryID)).count == raw.count else { throw Failure.invalidRecord("Duplicate raw RF query") }
        var semanticGrid: NativeRFDETRSemanticGrid?
        if NativeRFDETRSemanticGrid.enabled {
            guard let checksum = record.semanticGridSHA256, checksum.count == 64,
                  checksum.allSatisfy({ $0.isHexDigit }) else { return nil }
            let bytes = try Data(contentsOf: directory.appendingPathComponent("semantic-" + checksum + ".f32"))
            guard bytes.count == 4*cells*MemoryLayout<Float>.size, digest(bytes) == checksum else {
                throw Failure.invalidRecord("RF semantic-grid payload changed")
            }
            let values = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let grid = NativeRFDETRSemanticGrid(width:record.width,height:record.height,side:162,probabilities:values,
                modelWeightsSHA256:record.semanticGridModelWeightsSHA256,imageIdentity:record.imageIdentity)
            guard grid.isValid else { throw Failure.invalidRecord("Invalid RF semantic grid") }
            semanticGrid = grid
        }
        return .init(imageIdentity: record.imageIdentity, sourceWidth: record.width, sourceHeight: record.height,
            primitives: primitives, maskQueriesOmittedByBudget: record.maskQueriesOmittedByBudget,
            preprocessingMilliseconds: 0, modelMilliseconds: 0, decodeMilliseconds: 0,
            computeUnits: "saved-rf-complete-result", fromCache: true, classEvidence: raw, semanticGrid: semanticGrid)
    }

    static func read(image: CGImage, maximumMasks: Int) throws -> NativeRFDETRLayoutResult? {
        guard let context else { return nil }
        guard image.width == context.width, image.height == context.height, (0...160).contains(maximumMasks) else {
            throw Failure.invalidRecord("RF replay image dimensions changed")
        }
        let identity = try NativeRFDETRSourceImage.decode(image).identity
        guard let result = try restore(context, imageIdentity: identity, maximumMasks: maximumMasks) else { return nil }
        context.observed(prediction: false)
        HostDump.capture("rf-layout-replay", ["inferenceCalls": 0, "masksPreserved": true, "imageIdentity": identity])
        return result
    }

    /// First complete writer wins. Content-addressed masks make an atomic
    /// record safe even if independent hosts predict the same cold page.
    static func store(_ result: NativeRFDETRLayoutResult, maximumMasks: Int) throws -> NativeRFDETRLayoutResult {
        guard let context else { return result }
        guard result.sourceWidth == context.width, result.sourceHeight == context.height, (0...160).contains(maximumMasks) else {
            throw Failure.invalidRecord("RF capture dimensions changed")
        }
        context.observed(prediction: true)
        let directory = folder(context, maximumMasks: maximumMasks)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var masks: [Float] = [], offsets: [Int: Int] = [:], records: [Primitive] = []
        for primitive in result.primitives {
            let offset: Int?
            if let mask = primitive.mask {
                guard mask.queryID == primitive.queryID, mask.sourceWidth == context.width, mask.sourceHeight == context.height,
                      mask.logits.count == cells, mask.logits.allSatisfy(\.isFinite) else { throw Failure.invalidRecord("Invalid RF capture mask") }
                if let existing = offsets[primitive.queryID] {
                    guard Array(masks[existing..<(existing + cells)]) == mask.logits else { throw Failure.invalidRecord("Conflicting RF query masks") }
                    offset = existing
                } else {
                    guard offsets.count < maximumMasks else { throw Failure.invalidRecord("RF capture exceeds mask budget") }
                    offset = masks.count
                    offsets[primitive.queryID] = masks.count
                    masks.append(contentsOf: mask.logits)
                }
            } else { offset = nil }
            records.append(.init(queryID: primitive.queryID, semanticClass: primitive.semanticClass.rawValue,
                confidence: primitive.confidence, normalizedBounds: primitive.normalizedBounds,
                sourceBounds: primitive.sourceBounds, supportPolygon: primitive.supportPolygon, maskOffset: offset))
        }
        let data = masks.withUnsafeBytes { Data($0) }
        let checksum = digest(data)
        let blob = directory.appendingPathComponent(checksum + ".f32")
        if !FileManager.default.fileExists(atPath: blob.path) { try data.write(to: blob, options: .atomic) }
        guard result.classEvidence.count <= 300 else { throw Failure.invalidRecord("Too many raw RF queries") }
        let raw = result.classEvidence.map { q in
            ClassEvidence(queryID: q.queryID, logits: q.logits, probabilities: q.probabilities,
                normalizedBounds: q.normalizedBounds, sourceBounds: q.sourceBounds, maskOffset: offsets[q.queryID])
        }
        var semanticChecksum: String?
        if let grid = result.semanticGrid {
            guard grid.isValid, grid.width == context.width, grid.height == context.height,
                  grid.imageIdentity == result.imageIdentity else { throw Failure.invalidRecord("RF semantic-grid source mismatch") }
            let bytes = grid.probabilities.withUnsafeBytes { Data($0) }
            let checksum = digest(bytes)
            let blob = directory.appendingPathComponent("semantic-" + checksum + ".f32")
            if !FileManager.default.fileExists(atPath:blob.path) { try bytes.write(to:blob,options:.atomic) }
            semanticChecksum = checksum
        }
        let record = Record(version: 1, sourceSHA256: context.sourceSHA256, imageIdentity: result.imageIdentity,
            width: result.sourceWidth, height: result.sourceHeight, maximumMaskQueries: maximumMasks,
            maskQueriesOmittedByBudget: result.maskQueriesOmittedByBudget, maskBytes: data.count, maskSHA256: checksum,
            primitives: records, classEvidence: raw, semanticGridSHA256:semanticChecksum,
            semanticGridModelWeightsSHA256:result.semanticGrid?.modelWeightsSHA256)
        let metadata = directory.appendingPathComponent("record.json")
        let temporary = directory.appendingPathComponent(".record-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try JSONEncoder().encode(record).write(to: temporary, options: .atomic)
        do { try FileManager.default.linkItem(at: temporary, to: metadata) }
        catch { guard FileManager.default.fileExists(atPath: metadata.path) else { throw error } }
        guard let stored = try restore(context, imageIdentity: result.imageIdentity, maximumMasks: maximumMasks) else {
            throw Failure.invalidRecord("Missing completed RF record")
        }
        HostDump.capture("rf-layout-replay", ["inferenceCalls": 1, "masksPreserved": true, "imageIdentity": stored.imageIdentity])
        return .init(imageIdentity: stored.imageIdentity, sourceWidth: stored.sourceWidth, sourceHeight: stored.sourceHeight,
            primitives: stored.primitives, maskQueriesOmittedByBudget: stored.maskQueriesOmittedByBudget,
            preprocessingMilliseconds: result.preprocessingMilliseconds, modelMilliseconds: result.modelMilliseconds,
            decodeMilliseconds: result.decodeMilliseconds, computeUnits: result.computeUnits, fromCache: false,
            classEvidence:stored.classEvidence,semanticGrid:stored.semanticGrid)
    }
}
