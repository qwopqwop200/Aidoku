import CoreGraphics
import Foundation

@main struct NativePixelRFEvidenceReplay {
    struct Primitive: Decodable { let queryID: Int; let semanticClass: Int; let confidence: Float }
    struct Crop: Decodable {
        let bounds: [Int]
        let polygons: [[[Double]]]
        let coarseOutput: String
        let fullOutput: String
    }
    struct Input: Decodable {
        let width: Int
        let height: Int
        let imageIdentity: String
        let boxes: String
        let logits: String
        let masks: String
        let primitives: [Primitive]
        let crops: [Crop]
    }
    static func floats(_ path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count % 4 == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return data.withUnsafeBytes { bytes in
            (0..<(data.count / 4)).map { Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
    }
    static func main() throws {
        let input = try JSONDecoder().decode(Input.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let boxes = try floats(input.boxes), logits = try floats(input.logits), masks = try floats(input.masks)
        guard boxes.count == 1200, logits.count == 1500, masks.count == 300 * 162 * 162 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var queries = [NativeRFDETRClassEvidence]()
        for q in 0..<300 {
            let offset = q * 4
            let b = CGRect(x: Double(boxes[offset] - boxes[offset + 2] / 2),
                y: Double(boxes[offset + 1] - boxes[offset + 3] / 2),
                width: Double(boxes[offset + 2]), height: Double(boxes[offset + 3]))
            let raw = Array(logits[(q * 5)..<(q * 5 + 5)])
            let mask = NativeRFDETRLayoutMask(queryID: q, sourceWidth: input.width, sourceHeight: input.height,
                logits: Array(masks[(q * 162 * 162)..<((q + 1) * 162 * 162)]))
            queries.append(.init(queryID: q, logits: raw, probabilities: raw.map { 1 / (1 + exp(-$0)) },
                normalizedBounds: b, sourceBounds: CGRect(x: b.minX * CGFloat(input.width), y: b.minY * CGFloat(input.height),
                    width: b.width * CGFloat(input.width), height: b.height * CGFloat(input.height)), mask: mask))
        }
        let primitives = input.primitives.map { p -> NativeRFDETRLayoutPrimitive in
            let q = queries[p.queryID]
            return .init(queryID: p.queryID, semanticClass: NativeRFDETRLayoutClass(rawValue: p.semanticClass)!,
                confidence: p.confidence, normalizedBounds: q.normalizedBounds, sourceBounds: q.sourceBounds, mask: q.mask)
        }
        let result = NativeRFDETRLayoutResult(imageIdentity: input.imageIdentity, sourceWidth: input.width,
            sourceHeight: input.height, primitives: primitives, maskQueriesOmittedByBudget: 0,
            preprocessingMilliseconds: 0, modelMilliseconds: 0, decodeMilliseconds: 0,
            computeUnits: "verified-replay", fromCache: false, classEvidence: queries)
        let evidence = try NativePixelRFEvidence(result: result)
        for crop in input.crops {
            let x = crop.bounds[0], y = crop.bounds[1]
            let support = try evidence.support(crop: CGRect(x: x, y: y,
                width: crop.bounds[2] - x, height: crop.bounds[3] - y),
                polygons: crop.polygons.map { $0.map { CGPoint(x: $0[0] + Double(x), y: $0[1] + Double(y)) } },
                sourceIdentity: input.imageIdentity)
            try support.coarse.withUnsafeBytes {
                try Data($0).write(to: URL(fileURLWithPath: crop.coarseOutput), options: .atomic)
            }
            try support.full.withUnsafeBytes {
                try Data($0).write(to: URL(fileURLWithPath: crop.fullOutput), options: .atomic)
            }
            print(support.ownerQueries)
        }
    }
}
