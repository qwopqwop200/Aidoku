import CoreGraphics
import Foundation
import CryptoKit

// No production producer/model is linked. The stored stage declaration below
// mirrors the borrowed observer ABI; SourceNativeInput itself is compiled real.
enum NativeRFDETRLayoutResource { static let highresSourceWeightsSHA256 = String(repeating: "b", count: 64) }
enum NativeSourceSegmentationExecution {
    static var completedOnlyEnabled = false
    static let policySHA256 = String(repeating: "c", count: 64)
    static let policyRevision = "synthetic-no-model"
}
enum NativeSegmentationFinalPolicy {
    static let requiredJointRadius = 7
    static let jointModelSHA256 = String(repeating: "d", count: 64)
    static let auxiliaryModelSHA256 = String(repeating: "e", count: 64)
}
enum NativeSelectedSourceSegmentationProducer {
    static var connectedWeakEnabled = false
    struct ReplayStage {
        let width: Int; let height: Int; let fontPixels: Double
        let primary: [Float]; let boundary: [Float]; let rawNative: [UInt8]
        let completed: [UInt8]; let filledBase: [UInt8]; let jointCodes: [UInt16]
        let jointComputationRadius: Int; let weakPositions: [Int]; let auxiliaryCodes: [UInt16]
        let sourceStyle18: [Double]; let auxiliaryStyle18: [Double]; let finalMask: [UInt8]
    }
    typealias SourceReplayObserver = (SourceNativeInput, ReplayStage) throws -> Void
}

@main enum Smoke {
    static let source = String(repeating: "a", count: 64)
    static func input(_ text: String = "observed", coarse: Float = Float(128)/255,
                      identity: String = source) -> SourceNativeInput {
        let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 2, y: 2)]
        return SourceNativeInput(width: 2, height: 2, rgb: Array(0..<12),
            rf: [Float](repeating: 0.25, count: 108), coarseRF: [Float](repeating: coarse, count: 16),
            affinityScores: [0, 0.25, 0.5, 0.75, 1], rfModelWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            memberPolygons: [polygon], mergedPolygon: polygon, bbox: CGRect(x: 0, y: 0, width: 2, height: 2),
            fontPriorSourcePixels: 12.5, crop: CGRect(x: 0, y: 0, width: 2, height: 2), pageSize: CGSize(width: 4, height: 4),
            sourceIdentity: identity, sourceText: text, confidence: nil, role: nil)
    }
    static func stage(weak: [Int] = [1], probabilities: [Float] = [0, 0.25, 0.5, 1]) -> NativeSelectedSourceSegmentationProducer.ReplayStage {
        .init(width: 2, height: 2, fontPixels: 12.5, primary: probabilities, boundary: [1, 0.5, 0.25, 0],
            rawNative: [0, 1, 255, 0], completed: [0, 255, 255, 0], filledBase: [0, 255, 255, 0],
            jointCodes: [65535, 0, 8191, 27], jointComputationRadius: 7, weakPositions: weak,
            auxiliaryCodes: [UInt16](repeating: 8191, count: weak.count), sourceStyle18: [Double](repeating: 0.25, count: 18),
            auxiliaryStyle18: [Double](repeating: 0.5, count: 18), finalMask: [0, 255, 0, 0])
    }
    static func mustThrow(_ body: () throws -> Void) {
        do { try body(); fatalError("expected rejection") } catch { }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func bank(_ name: String, budget: Int = 100_000) throws -> HostSourceSegmentationBank {
            try .init(directory: root.appendingPathComponent(name), contract: .init(
                sourceIdentity: source, sourceEncodedSHA256: source, compiledSourceFingerprint: source,
                compiledProducerSHA256: source, compiledSourceSHA256: ["synthetic": source],
                modelBinding: ["synthetic": true], rfClassCoordinateFeatureSchema: ["synthetic": true],
                additionalConfiguration: [:], maximumPageBytes: budget), references: {
                    ["sourceRGBIdentity": source, "sourceEncodedSHA256": source,
                     "sourceInputBank": ["path": "synthetic-not-real-input", "SHA256": source],
                     "rawRF": ["recordPath": "synthetic-not-real-rf", "recordSHA256": source,
                               "identitySHA256": source, "payloadSHA256": source]]
                }, inputDescriptor: { id, _, _, hashes in
                    ["ownerID": id, "hashes": hashes, "sourceInputBankOwnerIndex": 0,
                     "actualItemIndex": 7, "sourceInputBankSHA256": source, "ownerDescriptorSHA256": source]
                })
        }
        let a = input(), b = input("second")
        let good = try bank("good")
        mustThrow { try good.observer(a, stage()) }
        try good.prepare([.init(id: "actual-7", input: a), .init(id: "actual-3", input: b)])
        try good.observer(b, stage()) // Callback order is intentionally reversed.
        mustThrow { try good.finish() }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("good/page-manifest.json").path))
        try good.observer(a, stage())
        mustThrow { try good.observer(a, stage()) }
        let document = try good.finish()
        let actualBytes = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("good").path).reduce(0) { count, path in
            let url = root.appendingPathComponent("good").appendingPathComponent(path)
            return count + ((try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true) ? try Data(contentsOf: url).count : 0)
        }
        precondition(document["bytesWritten"] as? Int == actualBytes)
        precondition(document["expectedOwnerCount"] as? Int == 2)
        let owners = document["owners"] as! [[String: Any]]
        for owner in owners {
            let manifestURL = root.appendingPathComponent("good").appendingPathComponent(owner["manifest"] as! String)
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
            let fields = manifest["files"] as! [String: [String: Any]]
            precondition(fields.count == 14)
            for (_, field) in fields {
                let bytes = try Data(contentsOf: manifestURL.deletingLastPathComponent().appendingPathComponent(field["path"] as! String))
                precondition(bytes.count == field["bytes"] as! Int)
                precondition(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == field["SHA256"] as! String)
            }
            let joint = try Data(contentsOf: manifestURL.deletingLastPathComponent().appendingPathComponent("joint.u16"))
            precondition(Array(joint) == [255,255,0,0,255,31,27,0])
        }
        mustThrow { _ = try bank("good") }
        let empty = try bank("empty"); try empty.prepare([]); try empty.finish()
        let ambiguous = try bank("ambiguous")
        mustThrow { try ambiguous.prepare([.init(id: "a", input: a), .init(id: "b", input: a)]) }
        try ambiguous.prepare([.init(id: "a", input: a)]) // A failed prepare is transactional.
        let duplicate = try bank("duplicate")
        mustThrow { try duplicate.prepare([.init(id: "a", input: a), .init(id: "a", input: b)]) }
        let wrong = try bank("wrong")
        mustThrow { try wrong.prepare([.init(id: "a", input: input(identity: String(repeating: "f", count: 64)))]) }
        let small = try bank("small", budget: 411)
        mustThrow { try small.prepare([.init(id: "a", input: a)]) }
        let indexBudget = try bank("index-budget", budget: 1)
        try indexBudget.prepare([]); mustThrow { try indexBudget.finish() }
        let invalid = try bank("invalid"); try invalid.prepare([.init(id: "a", input: a)])
        mustThrow { try invalid.observer(a, stage(weak: [1,1])) }
        mustThrow { try invalid.observer(a, stage(probabilities: [.nan,0,0,0])) }
        mustThrow { try invalid.observer(b, stage()) }
        let badCoarse = input(coarse: 0.5)
        let coarse = try bank("coarse"); try coarse.prepare([.init(id: "a", input: badCoarse)])
        mustThrow { try coarse.observer(badCoarse, stage()) }
        NativeSourceSegmentationExecution.completedOnlyEnabled = true
        mustThrow { _ = try bank("completed-only") }
        NativeSourceSegmentationExecution.completedOnlyEnabled = false
        NativeSelectedSourceSegmentationProducer.connectedWeakEnabled = true
        mustThrow { _ = try bank("connected-weak") }
        print("PASS strict source stage bank: reordered owners, exact bytes/hashes/endian, completeness, quotas, invalid ABI, no model calls")
    }
}
