import CoreGraphics
@preconcurrency import CoreML
import Foundation
import ImageIO

/// Host-only immutable source observations. One page references ONE actual raw
/// RF archive; dense RGB/RF feature arrays are reconstructed, never published.
/// No model acquisition, prediction, GT lookup or target-text dependency.
@available(macOS 15.0, *)
enum HostSourceInputBank {
    enum Failure: Error { case invalid(String) }
    static let schema = "source-input-bank-original-rgb-raw300-v1"
    static let rfSchema = "source27-native-order-f16-coarse4-u8-owner-affinity-f32-v1"

    struct Contract: Codable, Equatable {
        let producerSHA256: String
        let sourceFactorySHA256: String
        let pixelEvidenceSHA256: String
        let decoderSHA256: String
        let preprocessSHA256: String
        let installedRFModelSHA256: String
        let configurationSHA256: String
        let modelSetSHA256: String
        let rfWeightsSHA256: String
        let rfSourceRevision: String
        let rfFeatureSchema: String
    }
    struct RawReference: Codable {
        let recordPath: String
        let recordSHA256: String
        let identitySHA256: String
        let payloadSHA256: String
    }
    struct Word: Codable {
        let text: String
        let sourceIndex: Int
        let bboxBits: [String]
        let polygonBits: [[String]]
    }
    /// Exact row-major runs of equal eight-lane OCR observations. Omitted runs
    /// are known all-positive-zero lanes, not unknown or fabricated predictions.
    struct OCRRun: Codable {
        let startPixel: Int
        let pixelCount: Int
        let laneBits: [String]
    }
    struct Owner: Codable {
        let itemIndex: Int
        let ownerOrder: Int
        let width: Int
        let height: Int
        let cropBits: [String]
        let bboxBits: [String]
        let memberPolygonBits: [[[String]]]
        let rfSupportPolygonPageBits: [[[String]]]
        let mergedPolygonBits: [[String]]
        let fontPriorBits: String
        let affinityBits: [String]
        let sourceText: String
        let confidenceBits: String?
        let role: String?
        let wordEvidence: [Word]
        let ocrPixelCount: Int
        let ocrRuns: [OCRRun]
        let expectedHashes: [String: String]
    }
    struct Page: Codable {
        let schema: String
        let contract: Contract
        let originalPath: String
        let originalEncodedSHA256: String
        let sourceRGBIdentity: String
        let pageWidth: Int
        let pageHeight: Int
        let pageCohort: String
        let pageOrder: Int
        let rawRF: RawReference
        let owners: [Owner]
        let completeObservedOwnerInventory: Bool
    }

    static func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
    static func bits(_ value: Float) -> String { String(value.bitPattern, radix: 16) }
    static func double(_ text: String) throws -> Double {
        guard let b = UInt64(text, radix: 16), Double(bitPattern: b).isFinite else { throw Failure.invalid("Float64 bits") }
        return Double(bitPattern: b)
    }
    static func float(_ text: String) throws -> Float {
        guard let b = UInt32(text, radix: 16), Float(bitPattern: b).isFinite else { throw Failure.invalid("Float32 bits") }
        return Float(bitPattern: b)
    }
    static func rectBits(_ r: CGRect) -> [String] { [r.minX, r.minY, r.width, r.height].map { bits(Double($0)) } }
    static func polygonBits(_ p: [CGPoint]) -> [[String]] { p.map { [bits(Double($0.x)), bits(Double($0.y))] } }
    static func rect(_ b: [String]) throws -> CGRect {
        guard b.count == 4 else { throw Failure.invalid("rectangle") }
        let v = try b.map(double)
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
    static func polygon(_ b: [[String]]) throws -> [CGPoint] {
        try b.map { p in
            guard p.count == 2 else { throw Failure.invalid("polygon") }
            return try CGPoint(x: double(p[0]), y: double(p[1]))
        }
    }
    static func floatHash(_ values: [Float]) -> String {
        values.withUnsafeBytes(HostRFRawReplay.digest)
    }
    static func encodeOCR(_ values: [Float], pixelCount: Int) throws -> [OCRRun] {
        guard values.count == pixelCount * 8, values.allSatisfy({ $0.isFinite && (0...1.001).contains($0) }) else {
            throw Failure.invalid("complete actual OCR8 required")
        }
        var runs: [OCRRun] = [], p = 0
        while p < pixelCount {
            let lane = (0..<8).map { values[p * 8 + $0].bitPattern }
            if lane.allSatisfy({ $0 == 0 }) { p += 1; continue }
            let start = p
            p += 1
            while p < pixelCount, (0..<8).allSatisfy({ values[p * 8 + $0].bitPattern == lane[$0] }) { p += 1 }
            runs.append(.init(startPixel: start, pixelCount: p - start, laneBits: lane.map { String($0, radix: 16) }))
        }
        return runs
    }
    static func decodeOCR(_ runs: [OCRRun], pixelCount: Int) throws -> [Float] {
        guard pixelCount > 0, pixelCount <= 1_500_000, runs.count <= pixelCount else { throw Failure.invalid("OCR budget") }
        var result = [Float](repeating: 0, count: pixelCount * 8), end = 0
        for run in runs {
            guard run.startPixel >= end, run.pixelCount > 0, run.startPixel <= pixelCount - run.pixelCount,
                  run.laneBits.count == 8 else { throw Failure.invalid("OCR runs overlap or overflow") }
            let lane = try run.laneBits.map(float)
            guard lane.allSatisfy({ (0...1.001).contains($0) }) else { throw Failure.invalid("OCR confidence") }
            end = run.startPixel + run.pixelCount
            for p in run.startPixel..<end { for c in 0..<8 { result[p * 8 + c] = lane[c] } }
        }
        return result
    }

    static func rawReference(_ record: URL) throws -> RawReference {
        let bytes = try Data(contentsOf: record)
        let h = try JSONDecoder().decode(HostRFRawReplay.Header.self, from: bytes)
        let id = try HostRFRawReplay.objectSHA(h.identity)
        guard record.lastPathComponent == id + ".record.json", h.version == 2,
              h.encoding == "IEEE754-f32-le", h.payloadBytes == HostRFRawReplay.payloadBytes else {
            throw Failure.invalid("raw reference identity")
        }
        return .init(recordPath: record.path, recordSHA256: HostRFRawReplay.digest(bytes),
                     identitySHA256: id, payloadSHA256: h.payloadSHA256)
    }

    /// Call at the actual constructor boundary, BEFORE optional stage consumers.
    /// Required source OCR is captured losslessly, not reconstructed from GT.
    static func makePage(source: NativeRFDETRSourceImage, original: URL, rawRecord: URL,
                         owners: [NativeSourceInputFactory.Owner], contract: Contract,
                         pageCohort: String, pageOrder: Int, completeInventory: Bool) throws -> Page {
        guard completeInventory, contract.rfFeatureSchema == rfSchema,
              contract.rfWeightsSHA256 == NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
              contract.rfSourceRevision == NativeRFDETRLayoutResource.highresSourceRevision else {
            throw Failure.invalid("incomplete inventory or source contract")
        }
        let originalBytes = try Data(contentsOf: original)
        let decoded = try decodeOriginal(originalBytes)
        guard decoded.identity == source.identity else { throw Failure.invalid("original/source RGB differs") }
        let reference = try rawReference(rawRecord)
        let header = try JSONDecoder().decode(HostRFRawReplay.Header.self, from: Data(contentsOf: rawRecord))
        guard header.identity.base.sourceRGBIdentity == source.identity,
              header.identity.width == source.width, header.identity.height == source.height,
              header.identity.preprocessCodeSHA256 == contract.preprocessSHA256,
              header.identity.base.installedModelTreeSHA256 == contract.installedRFModelSHA256,
              header.identity.base.expectedWeightsSHA256 == contract.rfWeightsSHA256 else {
            throw Failure.invalid("raw/source differs")
        }
        let records = try owners.enumerated().map { order, owner -> Owner in
            let input = owner.input
            try input.validate(requirePredictions: false)
            guard input.sourceIdentity == source.identity, input.pageSize == CGSize(width: source.width, height: source.height),
                  input.ocr.count == input.width * input.height * 8, !owner.originalMemberPolygons.isEmpty else {
                throw Failure.invalid("owner/source/OCR/original polygon evidence")
            }
            // Preserve the actual GLOBAL clipped seed vertices. Translating a
            // local polygon back is not an authority for original Float64 bits.
            let globalMerged = input.mergedPolygon.map { CGPoint(x: $0.x + input.crop.minX, y: $0.y + input.crop.minY) }
            let supportGeometry = try NativeSourceInputFactory.featureGeometry(members: owner.originalMemberPolygons,
                merged: globalMerged, crop: input.crop)
            return Owner(itemIndex: owner.itemIndex, ownerOrder: order, width: input.width, height: input.height,
                cropBits: rectBits(input.crop), bboxBits: rectBits(input.bbox), memberPolygonBits: input.memberPolygons.map(polygonBits),
                rfSupportPolygonPageBits: supportGeometry.polygons.map(polygonBits),
                mergedPolygonBits: polygonBits(input.mergedPolygon), fontPriorBits: bits(input.fontPriorSourcePixels),
                affinityBits: input.affinityScores.map(bits), sourceText: input.sourceText,
                confidenceBits: input.confidence.map(bits), role: input.role,
                wordEvidence: input.wordEvidence.map { .init(text: $0.text, sourceIndex: $0.sourceIndex,
                    bboxBits: rectBits($0.bbox), polygonBits: polygonBits($0.polygon)) },
                ocrPixelCount: input.width * input.height, ocrRuns: try encodeOCR(input.ocr, pixelCount: input.width * input.height),
                expectedHashes: ["rgb": input.rgb.withUnsafeBytes(HostRFRawReplay.digest), "fullRF": floatHash(input.rf),
                    "coarseRF": floatHash(input.coarseRF), "affinity": floatHash(input.affinityScores), "ocr": floatHash(input.ocr)])
        }
        return Page(schema: schema, contract: contract, originalPath: original.path,
            originalEncodedSHA256: HostRFRawReplay.digest(originalBytes), sourceRGBIdentity: source.identity,
            pageWidth: source.width, pageHeight: source.height, pageCohort: pageCohort, pageOrder: pageOrder,
            rawRF: reference, owners: records, completeObservedOwnerInventory: completeInventory)
    }

    static func publish(_ page: Page, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(page)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == bytes else { throw Failure.invalid("immutable page collision") }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .withoutOverwriting)
    }

    static func decodeOriginal(_ bytes: Data) throws -> NativeRFDETRSourceImage {
        guard let decoder = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil) else { throw Failure.invalid("original decode") }
        return try NativeRFDETRSourceImage.decode(image)
    }

    /// Original archive values feed the EXISTING native decoder. Canonical IDs
    /// are never mistaken for physical tensor/native class indices here.
    static func replayRF(reference: RawReference, source: NativeRFDETRSourceImage,
                         expected: Contract) throws -> NativeRFDETRLayoutResult {
        let record = URL(fileURLWithPath: reference.recordPath)
        let metadata = try Data(contentsOf: record)
        let h = try JSONDecoder().decode(HostRFRawReplay.Header.self, from: metadata)
        guard HostRFRawReplay.digest(metadata) == reference.recordSHA256,
              try HostRFRawReplay.objectSHA(h.identity) == reference.identitySHA256,
              h.version == 2, h.identity.schema == "rf-actual-f32-all300-le-v2",
              h.encoding == "IEEE754-f32-le", h.payloadBytes == HostRFRawReplay.payloadBytes,
              h.payloadSHA256 == reference.payloadSHA256,
              h.identity.base.sourceRGBIdentity == source.identity,
              h.identity.width == source.width, h.identity.height == source.height,
              h.identity.preprocessCodeSHA256 == expected.preprocessSHA256,
              h.identity.base.installedModelTreeSHA256 == expected.installedRFModelSHA256,
              h.identity.base.expectedWeightsSHA256 == expected.rfWeightsSHA256,
              h.identity.base.sourceRevision == expected.rfSourceRevision else { throw Failure.invalid("RF header binding") }
        let data = try Data(contentsOf: record.deletingLastPathComponent().appendingPathComponent(h.payloadSHA256 + ".f32le"))
        guard data.count == HostRFRawReplay.payloadBytes, HostRFRawReplay.digest(data) == h.payloadSHA256,
              HostRFRawReplay.tensorHashes(data) == h.tensorSHA256 else { throw Failure.invalid("RF payload binding") }
        var arrays: [String: MLFeatureValue] = [:], offset = 0
        for (name, shape, bytes) in HostRFRawReplay.specs {
            let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
            let to = array.dataPointer.assumingMemoryBound(to: Float.self)
            try data.withUnsafeBytes { raw in
                for i in 0..<(bytes / 4) {
                    let value = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + i * 4, as: UInt32.self)))
                    guard value.isFinite else { throw Failure.invalid("RF nonfinite") }
                    to[i] = value
                }
            }
            arrays[name] = MLFeatureValue(multiArray: array); offset += bytes
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: arrays)
        let snapshot = try NativeRFRawSnapshot(actualOutput: provider, preprocessingMilliseconds: 0, modelMilliseconds: 0,
            weightsSHA256: expected.rfWeightsSHA256, sourceIdentity: source.identity)
        return try snapshot.materialize(source: source, maximumMaskQueries: 160, retainAllQueryMasks: true,
            computeUnits: "cpu-offline-no-model", reused: true)
    }

    static func reconstruct(_ page: Page, expected: Contract) throws -> [SourceNativeInput] {
        guard page.schema == schema, page.completeObservedOwnerInventory, page.contract == expected,
              expected.rfFeatureSchema == rfSchema else { throw Failure.invalid("page/current contract") }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: page.originalPath))
        guard HostRFRawReplay.digest(bytes) == page.originalEncodedSHA256 else { throw Failure.invalid("encoded source changed") }
        let source = try decodeOriginal(bytes)
        guard source.identity == page.sourceRGBIdentity, source.width == page.pageWidth,
              source.height == page.pageHeight else { throw Failure.invalid("decoded source changed") }
        let evidence = try NativePixelRFEvidence(result: replayRF(reference: page.rawRF, source: source, expected: expected))
        return try page.owners.enumerated().map { order, owner in
            guard owner.ownerOrder == order, owner.width > 0, owner.height > 0,
                  owner.width <= 1_500_000 / owner.height else { throw Failure.invalid("owner order/budget") }
            let crop = try rect(owner.cropBits), members = try owner.memberPolygonBits.map(polygon)
            guard crop == crop.integral, crop.width == CGFloat(owner.width), crop.height == CGFloat(owner.height),
                  crop.minX >= 0, crop.minY >= 0, crop.maxX <= CGFloat(source.width), crop.maxY <= CGFloat(source.height),
                  owner.ocrPixelCount == owner.width * owner.height else { throw Failure.invalid("crop") }
            let global = try owner.rfSupportPolygonPageBits.map(polygon)
            let support = try evidence.support(crop: crop, polygons: global, sourceIdentity: source.identity)
            var rgb = [UInt8](repeating: 0, count: owner.width * owner.height * 3)
            source.rgb.withUnsafeBytes { raw in
                for y in 0..<owner.height { for x in 0..<(owner.width * 3) {
                    rgb[y * owner.width * 3 + x] = raw[((Int(crop.minY) + y) * source.width + Int(crop.minX)) * 3 + x]
                } }
            }
            let affinity = try owner.affinityBits.map(float)
            guard floatHash(support.affinityScores) == floatHash(affinity) else { throw Failure.invalid("owner affinity differs") }
            var input = SourceNativeInput(width: owner.width, height: owner.height, rgb: rgb, rf: support.full,
                coarseRF: support.coarse, affinityScores: support.affinityScores, rfModelWeightsSHA256: expected.rfWeightsSHA256,
                memberPolygons: members, mergedPolygon: try polygon(owner.mergedPolygonBits), bbox: try rect(owner.bboxBits),
                fontPriorSourcePixels: try double(owner.fontPriorBits), crop: crop,
                pageSize: CGSize(width: source.width, height: source.height), sourceIdentity: source.identity,
                sourceText: owner.sourceText, confidence: try owner.confidenceBits.map(double), role: owner.role)
            input.wordEvidence = try owner.wordEvidence.map { .init(text: $0.text, sourceIndex: $0.sourceIndex,
                bbox: try rect($0.bboxBits), polygon: try polygon($0.polygonBits)) }
            input.ocr = try decodeOCR(owner.ocrRuns, pixelCount: owner.ocrPixelCount)
            let actual = ["rgb": rgb.withUnsafeBytes(HostRFRawReplay.digest), "fullRF": floatHash(support.full),
                          "coarseRF": floatHash(support.coarse), "affinity": floatHash(support.affinityScores), "ocr": floatHash(input.ocr)]
            guard actual == owner.expectedHashes else { throw Failure.invalid("source arrays changed") }
            try input.validate(requirePredictions: false)
            return input
        }
    }
}
